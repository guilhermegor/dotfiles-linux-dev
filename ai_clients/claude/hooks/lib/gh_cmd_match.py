#!/usr/bin/env python3
"""Find and tokenize one `gh <noun> create|edit|merge` invocation inside a raw shell command
string.

Used by pr_template_guard.sh and issue_template_guard.sh (via resolve_gh_command() in
gh_body_guard_common.sh) to replace regex scraping of the raw command text with real argv
parsing. The regex approach could not tell a genuine invocation from the same text appearing
inside a quoted argument, and only ever looked at the START of the whole command string —
missing every invocation chained after `;`, `&&`, `||`, `|`, `&`, or a newline (dotfiles-dev,
CodeRabbit review on PR #371).

`merge` was added for pr_merge_threads_guard.sh (dotfiles-linux-dev#462): it needs to know whether
`--auto` is present on `gh pr merge`, off the same real argv, for the identical reason — a
`--auto` INSIDE a quoted `--title`/`--body` value must not count, and the same chaining rule
applies.

Reads the raw command string on stdin, takes the noun ("pr" or "issue") as argv[1], and prints
one line of JSON to stdout:

    {"matched": false}
    {"matched": true, "repo": "...", "has_body": true, "body": "...",
     "has_body_file": false, "body_file": null, "labels": ["state:blocked"], "auto": false,
     "head": null}

Exit code 0 on success (matched or not — "not matched" is a normal, common outcome, not a
failure). Exit code 1 if the command could not be tokenized at all (an unbalanced quote or an
unterminated heredoc) — the caller MUST treat this as "unknown" and fail OPEN, never as "no gh
command found", per this repo's hook contract (a verdict from unparseable input is a guess).
"""
import json
import re
import shlex
import sys

SEPARATORS = set(";&|\n")
HEREDOC_START = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")


def split_segments(command):
    """Split a shell command string into simple-command segments on unquoted ; && || | & and
    newlines, skipping heredoc bodies entirely (their content is data, not a command).

    Raises ValueError if a quote or heredoc is never closed — the input cannot be trusted to
    mean what it looks like, so the caller must refuse to judge it rather than guess.

    ponytail: does not track `(...)`/`{...}` subshell or group nesting — a command chained
    inside one of those is still scanned as flat text. Acceptable ceiling until it produces a
    real miss; the operators this was actually asked to fix (`;`, `&&`, `||`, `|`, `&`, `\\n`)
    are all handled.
    """
    segments = []
    buf = []
    i, n = 0, len(command)
    quote = None
    while i < n:
        c = command[i]
        if quote:
            buf.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                buf.append(command[i + 1])  # `\"` inside double quotes does not close them
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ("'", '"'):
            quote = c
            buf.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            buf.append(c)
            buf.append(command[i + 1])
            i += 2
            continue
        if c == "<" and i + 1 < n and command[i + 1] == "<":
            m = HEREDOC_START.match(command, i)
            if m:
                buf.append(m.group(0))
                i = m.end()
                nl = command.find("\n", i)
                if nl == -1:
                    raise ValueError("unterminated heredoc")
                word = m.group(2)
                term = re.compile(r"^\t*" + re.escape(word) + r"\s*$", re.M)
                mt = term.search(command, nl + 1)
                if not mt:
                    raise ValueError("unterminated heredoc")
                i = mt.end()
                continue
        if c in SEPARATORS:
            if buf:
                segments.append("".join(buf))
                buf = []
            while i < n and (command[i] in SEPARATORS or command[i].isspace()):
                i += 1
            continue
        buf.append(c)
        i += 1
    if quote:
        raise ValueError("unbalanced quote")
    if buf:
        segments.append("".join(buf))
    return segments


WRAPPERS = {"timeout", "nice", "ionice", "setsid", "stdbuf", "rtk", "proxy", "env", "command", "exec", "nohup", "time", "sudo", "xargs", "builtin"}
# Options that take a SEPARATE value, per wrapper: a shared list let `timeout -s KILL 5 gh ...`
# leave KILL as the "command" and miss the real gh call. A `--long=value` form needs no entry.
WRAPPER_VALUE_FLAGS = {
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid", "--pgid", "--uid"},
    "env": {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"},
    "sudo": {"-u", "-g", "-C", "-I", "-L", "-h", "-p", "-r", "-t", "-T", "-U",
             "--user", "--group", "--host", "--prompt", "--role", "--type"},
    "xargs": {"-n", "-I", "-L", "-P", "-d", "-E", "-s", "-a", "--max-args", "--max-procs",
              "--delimiter", "--arg-file", "--max-lines", "--max-chars"},
}
NESTED_ERRORS = []
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}


def _word(tok):
    """A command word stripped of group openers, `x=$(` prefixes and a leading backslash."""
    sub = re.match(r"^\w+=.*?(?:\$\(|`)(.*)$", tok)  # x=$(gh ...) / x=`gh ...`
    return (sub.group(1) if sub else tok).lstrip("$({`!\\")


def gh_start(argv):
    """Index of the `gh` token in a simple command, or -1.

    Skips `VAR=x` assignments, wrappers (`rtk [proxy]`, `env`, `command`, `sudo`, ...) together
    with whatever flags/values follow them, a `$(`/`(`/`{`/backtick group opener, a leading `\\`
    and accepts an absolute path to gh. With NO wrapper, `gh` must be the first word.
    """
    wrapped = False
    skip_next = False
    wrapper = ""
    for i, tok in enumerate(argv):
        word = _word(tok)
        if skip_next:
            skip_next = False
        elif word in WRAPPERS:
            wrapped, wrapper = True, word
        elif word == "" or re.match(r"^\w+=", word):
            continue
        elif wrapper == "timeout" and re.match(r"^\d+(\.\d+)?[smhd]?$", word):
            continue  # `timeout 5 gh ...`: the duration is timeout's operand, not the command
        elif wrapped and word.startswith("-"):
            skip_next = word in WRAPPER_VALUE_FLAGS.get(wrapper, ())  # `sudo -u root gh`
        elif word.rsplit("/", 1)[-1] == "gh":
            return i
        else:
            return -1  # the real command is not gh (`env echo gh issue create` only prints)
    return -1


def gh_sub(argv, idx):
    """Index of gh's subcommand after `idx`, skipping gh's global -R/--repo/-h flags."""
    i = idx + 1
    while i < len(argv) and argv[i].startswith("-"):
        i += 2 if argv[i] in ("-R", "--repo", "--hostname") else 1
    return i


def iter_argvs(segments, depth=0):
    """Yield the argv of every simple command, descending into `bash -c '...'` / `eval ...`.

    ValueError (unbalanced quote) propagates from any level, so nothing is skipped silently.
    """
    for segment in segments:
        argv = shlex.split(segment, posix=True)
        yield argv
        if depth >= 3:
            continue
        words = [_word(t) for t in argv]
        inner = None
        for i, w in enumerate(words):
            base = w.rsplit("/", 1)[-1]
            if base in SHELLS:
                for j in range(i + 1, len(argv) - 1):
                    if re.match(r"^-[a-zA-Z]*c[a-zA-Z]*$", argv[j]):
                        inner = argv[j + 1]
                        break
                break
            if base == "eval":
                inner = " ".join(argv[i + 1:])
                break
            if w not in WRAPPERS and not re.match(r"^\w+=", w) and w != "":
                break
        if inner:
            try:
                yield from iter_argvs(split_segments(inner), depth + 1)
            except ValueError:
                # The inner script is broken but the outer shell still runs what follows it.
                NESTED_ERRORS.append(inner)


def matching_argv(segments, noun):
    """Return the argv of the first command shaped like `[wrappers] gh [-R x] <noun>
    create|edit|merge`, or None.
    """
    for argv in iter_argvs(segments):  # ValueError propagates: caller must fail open
        idx = gh_start(argv)
        if idx < 0:
            continue
        sub = gh_sub(argv, idx)
        if len(argv) >= sub + 2 and argv[sub] == noun and argv[sub + 1] in ("create", "edit", "merge"):
            return argv[idx + 1:sub] + argv[sub + 2:]
    return None


SHORT_VALUE_FLAGS = "RHbFl"


def attached_short(tok):
    """Split an attached short value flag (`-bX`, `-b=X`) into `(letter, value)`, else None.

    gh uses spf13/pflag, whose parseSingleShortArg takes everything after the letter as the
    value, stripping one leading `=` (`-b=X` -> `X`) unless nothing follows it (`-b=` -> `=`).
    The separated form (`-b X`) is handled by the callers, which consume the next token.
    """
    if len(tok) < 3 or tok[0] != "-" or tok[1] not in SHORT_VALUE_FLAGS:
        return None
    return tok[1], tok[3:] if tok[2] == "=" and len(tok) > 3 else tok[2:]


def scan_flags(argv):
    """Read --repo/-R, --head/-H, --body/-b, --body-file/-F and --label/-l/--add-label out of a
    real argv.
    A later occurrence of a single-value flag overwrites an earlier one, matching how real CLI
    flag parsers behave — there is no more "first readable candidate" heuristic to fall back on
    once the input is real argv instead of scraped text.
    """
    repo = None
    head = None
    has_body, body = False, None
    has_body_file, body_file = False, None
    labels = []
    i, n = 0, len(argv)
    while i < n:
        tok = argv[i]
        if tok in ("--repo", "-R") and i + 1 < n:
            repo = argv[i + 1]
            i += 2
        elif tok.startswith("--repo="):
            repo = tok.split("=", 1)[1]
            i += 1
        elif tok in ("--head", "-H") and i + 1 < n:
            head = argv[i + 1]
            i += 2
        elif tok.startswith("--head="):
            head = tok.split("=", 1)[1]
            i += 1
        elif tok in ("--head", "-H"):
            head = ""  # flag with no value: gh rejects it; "" tells the caller not to guess HEAD
            i += 1
        elif (attached := attached_short(tok)) is not None:
            letter, value = attached
            if letter == "R":
                repo = value
            elif letter == "H":
                head = value
            elif letter == "b":
                has_body, body = True, value
            elif letter == "F":
                has_body_file, body_file = True, value
            else:
                labels.extend(p for p in value.split(",") if p)
            i += 1
        elif tok in ("--body", "-b") and i + 1 < n:
            has_body, body = True, argv[i + 1]
            i += 2
        elif tok.startswith("--body="):
            has_body, body = True, tok.split("=", 1)[1]
            i += 1
        elif tok in ("--body-file", "-F") and i + 1 < n:
            has_body_file, body_file = True, argv[i + 1]
            i += 2
        elif tok.startswith("--body-file="):
            has_body_file, body_file = True, tok.split("=", 1)[1]
            i += 1
        elif tok in ("--label", "-l", "--add-label") and i + 1 < n:
            labels.extend(p for p in argv[i + 1].split(",") if p)
            i += 2
        elif tok.startswith("--label=") or tok.startswith("--add-label="):
            labels.extend(p for p in tok.split("=", 1)[1].split(",") if p)
            i += 1
        else:
            i += 1
    return repo, head, has_body, body, has_body_file, body_file, labels


API_ISSUE_ENDPOINT = re.compile(r"^/?repos/([^/]+)/([^/]+)/issues(?:/(\d+))?$")
API_ISSUE_SUBRESOURCE = re.compile(
    r"^repos/[^/]+/[^/]+/issues/(?:\d+/(?:comments|labels|assignees|events|timeline|reactions|"
    r"lock|sub_issues|dependencies)(?:/.*)?|comments(?:/\d+(?:/reactions)?)?|events(?:/\d+)?)$"
)
API_VALUE_FLAGS = {
    "-X": "method", "--method": "method",
    "-f": "field", "--raw-field": "field", "-F": "field", "--field": "field",
    "--input": "input",
}
API_OTHER_VALUE_FLAGS = {"-H", "--header", "-q", "--jq", "-t", "--template", "--hostname",
                         "--cache", "-p", "--preview"}


def api_issue_match(segments):
    """Return the match dict for `[rtk] gh api repos/O/R/issues[/N]` writes, or None.

    The REST twin of `gh issue create|edit` (dotfiles-linux-dev#714): `gh api` creates an issue on
    POST (explicit `-X POST`/`--method POST`, or implicit when any field/--input is given and
    no method is) and edits one on PATCH, so a guard that only sees `gh issue ...` is bypassed
    by it. Body is read from a `body=` field (`-f`/`-F`/`--raw-field`/`--field`); `-F body=@f`
    and `--input f` are file-valued (`body_json` marks that the file is a JSON payload).
    """
    for argv in iter_argvs(segments):
        # Same command-word rule as the `gh issue` path: gh must be the command itself (after
        # wrappers), so printed text like `echo gh api ...` is not a write. The fail-closed part
        # lives below, in how an understood-vs-unknown `gh api` call is judged.
        gh_at = gh_start(argv)
        if gh_at < 0:
            continue
        sub = gh_sub(argv, gh_at)
        if argv[sub:sub + 1] != ["api"]:
            continue
        rest = argv[sub + 1:]
        endpoint, method, fields, input_file = None, None, [], None
        i = 0
        while i < len(rest):
            tok = rest[i]
            if tok == "--":  # end of options: the rest are positionals
                endpoint = endpoint or (rest[i + 1] if i + 1 < len(rest) else None)
                break
            name, _, inline = tok.partition("=") if tok.startswith("--") else (tok, "", "")
            if tok.startswith("-") and tok[1:2] != "-" and len(tok) > 2 and tok[:2] in API_VALUE_FLAGS:
                name, inline = tok[:2], tok[2:].lstrip("=")  # attached short value: -XPOST
            if name in API_VALUE_FLAGS:
                if inline or tok != name:
                    value, step = inline, 1
                elif i + 1 < len(rest):
                    value, step = rest[i + 1], 2
                else:
                    value, step = "", 1
                kind = API_VALUE_FLAGS[name]
                if kind == "method":
                    method = value.upper()
                elif kind == "field":
                    fields.append((name in ("-F", "--field"), value))
                else:
                    input_file = value
                i += step
            elif name in API_OTHER_VALUE_FLAGS:
                i += 1 if inline else 2
            elif tok.startswith("-"):
                i += 1
            else:
                endpoint = endpoint or tok
                i += 1
        path = re.sub(r"^https?://[^/]+/(api/v3/)?", "", (endpoint or "").split("?", 1)[0])
        path = path.rstrip("/")
        dynamic = "$" in path or "`" in path or not endpoint  # endpoint the shell builds / unseen
        m = API_ISSUE_ENDPOINT.match(path)
        mentions = any("issues" in t for t in rest)
        # Understood as NOT an issue write only when the endpoint is a literal that either does
        # not mention `issues` at all or is a known issue sub-resource (comments, labels, ...).
        # Anything else that mentions `issues` is judged as a write (unknown never means allowed).
        if not m and not dynamic and (not mentions or API_ISSUE_SUBRESOURCE.match(path)):
            continue
        # A shell-built endpoint is not statically known: with any body field/--input or a
        # non-GET method it is judged as a write even when `issues` appears nowhere (deliberate
        # cost: shell-built writes to non-issue endpoints are judged too).
        unknown_write = dynamic and (fields or input_file or (method or "GET") != "GET")
        if not m and not mentions and not unknown_write:
            continue
        dyn = None if m else re.search(r"(?:^|/)issues(?:/([^/]*))?$", path)
        method = method or ("POST" if fields or input_file else "GET")
        if "$" in method or "`" in method:
            method = "?"  # unreadable method: may be POST or PATCH, judged as either
        number = (m.group(3) if m else (dyn.group(1) if dyn else None)) or None
        is_write = (
            method == "?"
            or (unknown_write and method != "GET")  # endpoint not statically known
            or (method == "POST" and not number)
            or (method in ("PATCH", "PUT") and number)
        )
        if not is_write:
            continue
        if m:
            owner, name = m.group(1), m.group(2)
            repo = None if "{" in owner + name or "$" in owner + name else f"{owner}/{name}"
        else:
            repo = None
        has_body, body, has_body_file, body_file, labels = False, None, False, None, []
        for typed, field in fields:
            key, _, val = field.partition("=")
            if key == "body":
                # A later body= overwrites an earlier one (gh keeps the last), whatever its kind.
                if typed and val.startswith("@"):  # only -F/--field reads a file via @
                    has_body_file, body_file, has_body, body = True, val[1:], False, None
                else:
                    has_body, body, has_body_file, body_file = True, val, False, None
            elif key in ("labels[]", "labels"):
                labels.extend(p for p in val.split(",") if p)
        body_json = False
        if input_file is not None:
            has_body_file, body_file, body_json, has_body, body = True, input_file, True, False, None
        no_body = not (has_body or has_body_file)
        if no_body and (unknown_write or (method in ("POST", "?") and not number)):
            has_body, body = True, ""  # REST create has no editor mode: no body IS an empty body
        return {
            "matched": True, "repo": repo, "head": None, "has_body": has_body, "body": body,
            "has_body_file": has_body_file, "body_file": body_file, "body_json": body_json,
            "labels": labels, "auto": False, "method": method,
        }
    return None


def main():
    noun = sys.argv[1] if len(sys.argv) > 1 else ""
    if noun not in ("pr", "issue", "api-issue"):
        print(json.dumps({"matched": False}))
        return 0

    command = sys.stdin.read()
    try:
        segments = split_segments(command)
        if noun == "api-issue":
            match = api_issue_match(segments)
            if match is None and any("issues" in e for e in NESTED_ERRORS):
                match = {"matched": True, "unparseable": True}
            print(json.dumps(match or {"matched": False}))
            return 0
        argv = matching_argv(segments, noun)
    except ValueError:
        if noun == "api-issue" and re.search(r"\bapi\b[\s\S]*issues", command):
            # Fail CLOSED for the REST path (#714): text that looks like an issues write but
            # cannot be tokenized is reported, never silently allowed.
            print(json.dumps({"matched": True, "unparseable": True}))
            return 0
        return 1  # unparseable: caller must fail open, never guess

    if argv is None:
        print(json.dumps({"matched": False}))
        return 0

    repo, head, has_body, body, has_body_file, body_file, labels = scan_flags(argv)
    print(json.dumps({
        "matched": True,
        "repo": repo,
        "head": head,
        "has_body": has_body,
        "body": body,
        "has_body_file": has_body_file,
        "body_file": body_file,
        "labels": labels,
        "auto": "--auto" in argv,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
