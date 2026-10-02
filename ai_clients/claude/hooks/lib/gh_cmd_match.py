#!/usr/bin/env python3
"""Find and tokenize one `gh <noun> create|edit|merge` invocation inside a raw shell command
string.

Used by pr_template_guard.sh and issue_template_guard.sh (via resolve_gh_command() in
gh_body_guard_common.sh) to replace regex scraping of the raw command text with real argv
parsing. The regex approach could not tell a genuine invocation from the same text appearing
inside a quoted argument, and only ever looked at the START of the whole command string —
missing every invocation chained after `;`, `&&`, `||`, `|`, `&`, or a newline (dotfiles-dev,
CodeRabbit review on PR #371).

`merge` was added for pr_merge_threads_guard.sh (dotfiles-dev#462): it needs to know whether
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


def matching_argv(segments, noun):
    """Return the argv of the first segment shaped like `[rtk] gh <noun> create|edit|merge`, or
    None.
    """
    for segment in segments:
        argv = shlex.split(segment, posix=True)  # ValueError propagates: caller must fail open
        idx = 1 if argv[:1] == ["rtk"] else 0
        if (
            len(argv) >= idx + 3
            and argv[idx] == "gh"
            and argv[idx + 1] == noun
            and argv[idx + 2] in ("create", "edit", "merge")
        ):
            return argv[idx + 3:]
    return None


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
        elif tok.startswith("-H") and len(tok) > 2:
            # pflag also takes `-H=<b>` and the attached `-H<b>`; `=` is stripped, as in pflag
            head = tok[3:] if tok[2] == "=" and len(tok) > 3 else tok[2:]
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


def main():
    noun = sys.argv[1] if len(sys.argv) > 1 else ""
    if noun not in ("pr", "issue"):
        print(json.dumps({"matched": False}))
        return 0

    command = sys.stdin.read()
    try:
        segments = split_segments(command)
        argv = matching_argv(segments, noun)
    except ValueError:
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
