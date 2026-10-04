#!/bin/bash
# PreToolUse (Bash matcher) hook: reflow the BODY of a file-fed `git commit` message to <= 72
# characters per line, in place, BEFORE the commit runs — so gitlint's B1 (body-max-line-length)
# passes on the first attempt.
#
# Why this exists: "wrap the body at 72" is a convention, and a convention is probabilistic — it
# holds only while the author remembers it. gitlint is the deterministic catcher, but it fires at
# the commit-msg stage, i.e. after the whole pre-commit gate, costing a full retry per miss. A
# hook that merely *validates* would just duplicate gitlint; only a hook that *fixes* removes the
# retry. This one rewrites the message file the commit is about to read.
#
# Complements commit_title_length_guard.sh: the title is BLOCKED (shortening it is an editorial
# decision only the author can make), the body is AUTO-WRAPPED (reflowing prose is mechanical).
#
# Hook I/O contract (same as the other guards): no status output, no lib/common.sh. It fails OPEN
# everywhere — an unparseable command, a missing or unwritable message file, or an unreadable
# payload all exit 0 and let the commit proceed untouched.

set -u

# jq parses the hook payload; without it we cannot inspect the command, so fail open.
command -v jq >/dev/null 2>&1 || exit 0

# Shared with commit_title_length_guard.sh and commit_secret_guard.sh (dotfiles-linux-dev#324) — one
# `git commit` detection regex, not three that can drift apart.
# shellcheck source=lib/commit_command_matcher.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/commit_command_matcher.sh"

# 72, not the repo's gitlint setting: 72 is safe under both the git convention (72) and gitlint's
# default (80), so the hook never has to read each repo's .gitlint to pick a target.
BODY_MAX_LENGTH=72

main() {
    local payload tool command msg_file reflowed

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    # Only act on an actual `git commit`. Every accepted spelling — and the per-segment anchor
    # that keeps a mere *mention* of "git commit" from tripping this — lives in the shared
    # matcher; see its header for the four shapes the old inline regex missed.
    command_has_git_commit "$command" || exit 0

    msg_file="$(extract_message_file "$command")" || exit 0

    # `git -C <dir> commit -F <relative>` resolves the path against <dir>, because git chdirs
    # there first — so a relative path must be re-anchored or this rewrites the wrong file (or,
    # more often, silently finds nothing and no-ops). COMMIT_COMMAND_GIT_DIR is set by the matcher.
    if [[ -n "$COMMIT_COMMAND_GIT_DIR" && "$msg_file" != /* ]]; then
        msg_file="$COMMIT_COMMAND_GIT_DIR/$msg_file"
    fi

    [[ -f "$msg_file" && -w "$msg_file" ]] || exit 0

    reflowed="$(reflow_body "$msg_file")" || exit 0
    [[ "$reflowed" == "$(cat "$msg_file")" ]] && exit 0   # already within the limit → no-op

    printf '%s\n' "$reflowed" > "$msg_file" || exit 0
    announce "$msg_file"
}

extract_message_file() {
    # Emit the sole `-F` / `--file` path, or return 1 when there is not exactly one. ponytail: this
    # only handles the file-fed form, which is what /commit-code emits (`git commit -F
    # /tmp/commit_msg.txt`). An inline `-m "<body>"` would have to be rewritten through the hook's
    # `updatedInput`, i.e. re-quoting a shell command from a regex match — not worth the blast
    # radius; gitlint still catches those. Add it only if inline bodies start showing up.
    local s=" $1" re raw matched val
    local files=()
    re='[[:space:]](-F|--file)[[:space:]=]*("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]+)'
    while [[ "$s" =~ $re ]]; do
        raw="${BASH_REMATCH[2]}"
        matched="${BASH_REMATCH[0]}"
        s="${s#*"$matched"}"          # advance past this candidate, keep looking
        val="${raw#[\"\']}"
        val="${val%[\"\']}"
        files+=("$val")
    done

    [[ ${#files[@]} -eq 1 ]] || return 1

    # A path built from shell expansion cannot be resolved statically — fail open rather than
    # rewrite the wrong file.
    case "${files[0]}" in
        *'$'* | *'`'* | '-') return 1 ;;
    esac

    printf '%s' "${files[0]}"
}

reflow_body() {
    # Emit the message reflowed PARAGRAPH by paragraph (via Python's textwrap), not line by line:
    # a paragraph whose lines are all already <= the limit is left byte-for-byte unchanged (so a
    # hand-wrapped body is never disturbed), and a paragraph that has any over-long line is refilled
    # as a whole — which is what stops the old per-line splitter from spilling a single orphan word
    # onto its own line. A widow-control pass pulls a lone trailing word back up when it fits.
    #
    # Left untouched: the subject (line 1), fenced and indented code, trailer lines
    # (Co-Authored-By:, Signed-off-by:, …), blank-line separators, and any single token longer than
    # the limit (a URL/path is kept whole and over-length rather than broken).
    #
    # python3 is a hook prerequisite; if it is somehow absent we fail open and emit the body
    # unchanged (the commit proceeds; gitlint remains the backstop).
    command -v python3 >/dev/null 2>&1 || { cat "$1"; return; }
    MSG_FILE="$1" BODY_MAX_LENGTH="$BODY_MAX_LENGTH" python3 - <<'PY' 2>/dev/null || cat "$1"
import os, re, sys, textwrap

MAX = int(os.environ.get("BODY_MAX_LENGTH", "72"))
with open(os.environ["MSG_FILE"], encoding="utf-8") as fh:
    lines = fh.read().split("\n")

TRAILER = re.compile(r"^[A-Za-z][A-Za-z-]*:\s")
MARKER = re.compile(r"^(\s*)([-*+]|\d+[.)])(\s+)")


def leading_ws(s):
    return s[: len(s) - len(s.lstrip())]


def is_special(s):
    # A line that must pass through verbatim and never be folded into a paragraph.
    stripped = s.strip()
    if stripped == "":
        return True
    if stripped.startswith("```") or stripped.startswith("~~~"):
        return True
    if s.startswith("\t") or s.startswith("    "):  # indented code (4+ spaces)
        return True
    return bool(TRAILER.match(s))


def widow_control(wrapped, cont_indent):
    # If the last line holds a single word, pull the previous line's last word down beside it,
    # provided the merged line still fits. Otherwise leave it (a lone long token is acceptable).
    if len(wrapped) < 2:
        return wrapped
    last = wrapped[-1][len(cont_indent):] if wrapped[-1].startswith(cont_indent) else wrapped[-1].lstrip()
    if " " in last.strip() or last.strip() == "":
        return wrapped
    prev = wrapped[-2]
    pw = prev.split()
    if len(pw) < 2:
        return wrapped
    merged = cont_indent + pw[-1] + " " + last.strip()
    if len(merged) > MAX:
        return wrapped
    wrapped[-2] = leading_ws(prev) + " ".join(pw[:-1])
    wrapped[-1] = merged
    return wrapped


out = []
i = 0
n = len(lines)
if n:                       # subject: the author owns its length
    out.append(lines[0])
    i = 1

in_fence = False
while i < n:
    line = lines[i]
    stripped = line.strip()

    if stripped.startswith("```") or stripped.startswith("~~~"):
        in_fence = not in_fence
        out.append(line); i += 1; continue
    if in_fence or is_special(line):
        out.append(line); i += 1; continue

    m = MARKER.match(line)
    if m:                                       # list item + its indented continuation lines
        first_prefix = m.group(0)
        cont_indent = " " * len(first_prefix)
        block = [line]
        text = line[m.end():].strip()
        i += 1
        while i < n and not is_special(lines[i]) and not MARKER.match(lines[i]) \
                and len(leading_ws(lines[i])) > len(m.group(1)):
            block.append(lines[i]); text += " " + lines[i].strip(); i += 1
    else:                                       # plain paragraph
        indent = leading_ws(line)
        first_prefix = cont_indent = indent
        block = [line]
        text = stripped
        i += 1
        while i < n and not is_special(lines[i]) and not MARKER.match(lines[i]):
            block.append(lines[i]); text += " " + lines[i].strip(); i += 1

    if all(len(b) <= MAX for b in block):       # already compliant → leave it exactly as written
        out.extend(block)
        continue

    wrapped = textwrap.wrap(
        text, width=MAX, initial_indent=first_prefix, subsequent_indent=cont_indent,
        break_long_words=False, break_on_hyphens=False,
    )
    out.extend(widow_control(wrapped, cont_indent) if wrapped else block)

sys.stdout.write("\n".join(out))
PY
}

announce() {
    # Tell the model the file it is about to commit no longer matches what it wrote. stdout JSON is
    # only read on exit 0, which is exactly the path we are on.
    jq -n --arg file "$1" --argjson max "$BODY_MAX_LENGTH" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            additionalContext: ("commit_body_wrap: reflowed the commit body in \($file) to <= \($max) chars per line (gitlint B1). The committed message differs slightly from the one you composed; the subject is unchanged.")
        }
    }' 2>/dev/null || true
}

main "$@"
