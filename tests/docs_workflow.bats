#!/usr/bin/env bats
#
# Pins the docs pipeline contract (dotfiles-linux-dev#659): the build job is a
# strict MkDocs build on push AND PR with read-only permissions, and the mike
# deploy job can only ever run for a push to master, after the build.
# Parses .github/workflows/docs.yml with python3+PyYAML (on ubuntu runners; the
# test skips where PyYAML is absent). `on:` parses as the boolean key True.
#
# Run locally: bats tests/docs_workflow.bats

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WF="$ROOT/.github/workflows/docs.yml"
    if ! python3 -c 'import yaml' 2>/dev/null; then
        # A gate that cannot run must not pass silently in CI.
        [ -z "${CI:-}" ] || { echo "PyYAML missing in CI" >&2; return 1; }
        skip "PyYAML not available"
    fi
}

wf() {
    python3 - "$WF" "$1" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
wf["on"] = wf.pop(True)
print(eval(sys.argv[2], {"wf": wf}))
PY
}

# #664: the deploy job holds contents:write, so a mutable third-party tag there is
# arbitrary code with a push token. Only GitHub-owned actions are allowed.
@test "every action used is GitHub-owned (no third-party uses:)" {
    run wf '[s["uses"] for j in wf["jobs"].values() for s in j["steps"] if "uses" in s and not s["uses"].startswith("actions/")]'
    [ "$output" = "[]" ]
}

@test "the build job's checkout does not persist credentials" {
    run wf '[s.get("with",{}).get("persist-credentials") for s in wf["jobs"]["build"]["steps"] if s.get("uses","").startswith("actions/checkout")]'
    [ "$output" = "[False]" ]
}

@test "triggers cover push and pull_request" {
    run wf '" ".join(sorted(wf["on"]))'
    [ "$output" = "pull_request push" ]
}

@test "workflow default permissions are read-only" {
    run wf 'wf["permissions"]'
    [ "$output" = "{'contents': 'read'}" ]
}

@test "build job runs a strict mkdocs build" {
    run wf '"mkdocs build --strict" in " ".join(s.get("run","") for s in wf["jobs"]["build"]["steps"])'
    [ "$output" = "True" ]
}

@test "deploy job is gated to master pushes only" {
    run wf 'wf["jobs"]["deploy"]["if"]'
    [ "$output" = "github.event_name == 'push' && github.ref == 'refs/heads/master'" ]
}

@test "deploy job needs build and is the only writer" {
    run wf 'wf["jobs"]["deploy"]["needs"]'
    [ "$output" = "build" ]
    run wf 'wf["jobs"]["deploy"]["permissions"]'
    [ "$output" = "{'contents': 'write'}" ]
    run wf '"permissions" in wf["jobs"]["build"]'
    [ "$output" = "False" ]
}

@test "deploy job has a concurrency group and mike deploys dev with latest" {
    run wf '"group" in wf["jobs"]["deploy"]["concurrency"]'
    [ "$output" = "True" ]
    grep -q 'mike deploy --push --update-aliases "\$DOCS_VERSION" latest' "$WF"
    grep -q 'mike set-default --push latest' "$WF"
}

@test "no expression interpolation inside run: scripts" {
    run wf 'any("${{" in s.get("run","") for j in wf["jobs"].values() for s in j["steps"])'
    [ "$output" = "False" ]
}

@test "mkdocs.yml declares the mike provider and excludes docs/backlog" {
    grep -Eq '^[[:space:]]*provider:[[:space:]]*mike' "$ROOT/mkdocs.yml"
    grep -Eq '^[[:space:]]*backlog/' "$ROOT/mkdocs.yml"
}

@test "enable_pages is a no-op when gh is unauthenticated" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/gh"
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$ROOT/lib/enable_pages.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not authenticated"* ]]
}

@test "enable_pages leaves Pages untouched until gh-pages exists" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
case "$*" in
    "auth status") exit 0 ;;
    "repo view"*) echo o/r ;;
    *) echo "$*" >> "$GH_LOG"; exit 1 ;;
esac
GH
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    run env GH_LOG="$BATS_TEST_TMPDIR/gh.log" PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
        bash "$ROOT/lib/enable_pages.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No 'gh-pages' branch yet"* ]]
    # only the branch probe ran: no POST/PUT to the pages endpoint
    run grep -c -e '-X' "$BATS_TEST_TMPDIR/gh.log"
    [ "$output" = "0" ]
}

# #662: `gh repo view` is GraphQL; under a rate limit it fails, and that empty answer
# used to be reported as "No GitHub remote resolved" with exit 0.
@test "enable_pages resolves the repo from origin when gh repo view fails" {
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/clone"
    cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$*" in
    "auth status") exit 0 ;;
    "repo view"*) exit 1 ;;
    "api repos/o/r/branches/gh-pages") exit 0 ;;
    "api repos/o/r/pages --jq .source.branch") exit 1 ;;
    "api -X POST repos/o/r/pages --input -") cat >/dev/null; exit 0 ;;
    *) exit 1 ;;
esac
GH
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    git -C "$BATS_TEST_TMPDIR/clone" init -q
    git -C "$BATS_TEST_TMPDIR/clone" remote add origin https://github.com/o/r.git
    cd "$BATS_TEST_TMPDIR/clone"
    run env GH_LOG="$BATS_TEST_TMPDIR/gh.log" PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
        bash "$ROOT/lib/enable_pages.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"now serves 'gh-pages' for o/r"* ]]
    grep -q -- '-X POST repos/o/r/pages' "$BATS_TEST_TMPDIR/gh.log"
}

@test "enable_pages fails loudly when no repo can be resolved" {
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/norepo"
    cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
case "$*" in
    "auth status") exit 0 ;;
    *) exit 1 ;;
esac
GH
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    cd "$BATS_TEST_TMPDIR/norepo"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$ROOT/lib/enable_pages.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not resolve the GitHub repo"* ]]
}
