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
import inspect
import json
import os
import posixpath
import re
import shlex
import sys
import urllib.parse

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
SHELL_KEYWORDS = {"if", "elif", "while", "until", "do", "then", "else", "coproc"}  # (#870) `!`, `{`, `(` are stripped by _word
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
        elif word == "" or re.match(r"^\w+=", word) or word in SHELL_KEYWORDS:
            continue  # `do gh api ...` / `then gh ...`: not the command (#870)
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


# Stand-ins for a `$`/backtick the shell expands: inside double quotes (one word, but the shell
# writes its text) and unquoted (the shell also word-splits it into extra arguments). Private-use
# code points are ordinary word characters to shlex, so the marked text splits into the same words.
SHELL_QUOTED, SHELL_SPLIT, QUOTED_GT = "\ue000", "\ue001", "\ue002"


def mark_expansions(segment):
    """Replace every `$`/backtick bash would expand with SHELL_QUOTED/SHELL_SPLIT (#908).

    shlex drops quoting, so after it a single-quoted `$x` (text) and a double-quoted `$x` (the
    shell's) are the same string; marking first keeps that fact. A backslash-escaped `$` is text.
    `$'...'` is marked too: fail closed on a quoting form nobody writes a query in.
    """
    out, quote, i = [], None, 0
    while i < len(segment):
        c = segment[i]
        if quote == "'":
            quote = None if c == "'" else quote
            c = QUOTED_GT if c in "<>" else c  # a quoted `>` is text, never a redirect
        elif c == "\\" and i + 1 < len(segment):
            out.append(segment[i] + (QUOTED_GT if segment[i + 1] in "<>" else segment[i + 1]))
            i += 2
            continue
        elif c == '"':
            quote = None if quote else '"'
        elif c == "'" and quote is None:
            quote = "'"
        elif c in "$`":
            c = SHELL_QUOTED if quote else SHELL_SPLIT
        elif c in "<>" and quote:
            c = QUOTED_GT
        elif c == "{" and not quote and re.match(r"\{[^{}]*(,|\.\.)", segment[i:]):
            c = SHELL_SPLIT  # `-t {x,-Fquery=@f}`: bash brace-expands it into extra arguments
        out.append(c)
        i += 1
    return "".join(out)


def _nested_script(argv):
    """Where `bash -c S` / `env -S S` / `eval ...` keeps its script: (start, stop, prefix), so
    the same cut can be taken from the marked argv; None when argv runs no nested script."""
    for i, w in enumerate(_word(t) for t in argv):
        base = w.rsplit("/", 1)[-1]
        if base in SHELLS:
            for j in range(i + 1, len(argv) - 1):
                if re.match(r"^-[a-zA-Z]*c[a-zA-Z]*$", argv[j]):
                    return j + 1, j + 2, 0
            return None
        if base == "env":
            # `env -S 'cmd args'` / `--split-string=...` splits its one argument into a
            # command line: nested shell text, like `bash -c`.
            for j in range(i + 1, len(argv)):
                a = argv[j]
                if a in ("-S", "--split-string") and j + 1 < len(argv) and argv[j + 1]:
                    return j + 1, j + 2, 0
                if a.startswith("--split-string=") and len(a) > len("--split-string="):
                    return j, j + 1, len("--split-string=")
                if a.startswith("-S") and len(a) > 2:
                    return j, j + 1, 2
        if base == "eval":
            return i + 1, len(argv), 0
        if (w not in WRAPPERS and w not in SHELL_KEYWORDS
                and not re.match(r"^\w+=", w) and w != ""):
            return None
    return None


def _iter_marked(segments, marked, depth):
    if len(segments) != len(marked):
        raise ValueError("marking changed the segment split")  # never expected: refuse to judge
    for segment, mseg in zip(segments, marked):
        argv = shlex.split(segment, posix=True)
        marks = shlex.split(mark_expansions(mseg), posix=True)
        if len(marks) != len(argv):
            raise ValueError("marking changed the word split")  # never expected: refuse to judge
        yield argv, marks
        spec = _nested_script(argv)
        if not spec:
            continue
        start, stop, prefix = spec
        if depth >= 3:  # too deep to inspect: refuse to judge rather than skip it
            NESTED_ERRORS.append(" ".join(argv[start:stop]))
            continue
        inner = " ".join(argv[start:stop])[prefix:]
        # Text the outer shell wrote is re-parsed by the inner one, which may split it anywhere.
        minner = (" ".join(marks[start:stop])[prefix:].replace(SHELL_QUOTED, SHELL_SPLIT)
                  .replace(QUOTED_GT, ">"))
        # `eval "... \"\$Q\""`: the outer shell turns `\$` into the `$` the inner shell expands.
        minner = re.sub(r"\\[$`]", SHELL_SPLIT, minner)
        try:
            yield from _iter_marked(split_segments(inner), split_segments(minner), depth + 1)
        except ValueError:
            # The inner script is broken but the outer shell still runs what follows it.
            NESTED_ERRORS.append(inner)


def iter_argvs_marked(segments):
    """Yield (argv, marked argv) for every simple command, descending into `bash -c '...'` /
    `eval ...`; the marked argv carries SHELL_QUOTED/SHELL_SPLIT where the shell expands.

    ValueError (unbalanced quote) propagates from any level, so nothing is skipped silently.
    """
    yield from _iter_marked(segments, segments, 0)


def iter_argvs(segments):
    """Yield the argv of every simple command, descending into `bash -c '...'` / `eval ...`."""
    for argv, _ in iter_argvs_marked(segments):
        yield argv


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


def only_repo_segment_is_dynamic(path):
    """True when every `$`/backtick in a `repos/...` path sits in the owner/repo segment(s)
    and the resource after them is a literal other than `issues` (dotfiles-linux-dev#822).

    `repos/$R/pulls/816/merge` is plainly a pull-request write whatever `$R` expands to, so it
    is judged like its literal twin instead of failing closed as an unknown issue write.
    `$R` may stand for `owner/name` (one segment) or `$O/$N` two, so every plausible split
    must agree; a variable in the resource segment itself, or any split whose resource is
    `issues`, stays fail-closed. A variable only AFTER a literal `repos/O/R/<resource>` prefix
    (`repos/o/r/pulls/$n/merge`, a loop id) is the same: the resource is already known (#870).
    """
    segs = path.lstrip("/").split("/")
    if segs[0] != "repos" or len(segs) < 3:
        return False
    var_at = [i for i, seg in enumerate(segs) if "$" in seg or "`" in seg]
    if not var_at:
        return False
    if min(var_at) > 3 and "issues" not in path.lower() and not {".", ".."} & set(segs):
        return True  # literal repos/O/R/<resource>/...: the variable is a loop id (#870)
    verdicts = []
    for width in (1, 2):  # owner/name segments: `$R` (one) or `$O/$N` / `o/$N` (two)
        resource_at = 1 + width
        if resource_at >= len(segs) or max(var_at) >= resource_at:
            continue  # no resource segment, or a variable lies at/after it: split not plausible
        # A variable may also expand to `owner/name/issues`; then the literal tail must not
        # complete an issue endpoint (`repos/$R/comments/5`, `repos/$R/5/labels`).
        probe = "repos/o/r/issues/" + "/".join(segs[resource_at:])
        verdicts.append(segs[resource_at] != "issues"
                        and not API_ISSUE_ENDPOINT.match(probe)
                        and not API_ISSUE_SUBRESOURCE.match(probe))
    return bool(verdicts) and all(verdicts)


GRAPHQL_ISSUE_MUTATION = re.compile(r"\b(createIssue|updateIssue)\s*\(")
GRAPHQL_STR = r'"""(?:\\"""|(?!""")[\s\S])*"""|"(?:[^"\\]|\\[\s\S])*"'
GRAPHQL_BODY_KEY = re.compile(r"\bbody\s*:")
GRAPHQL_LEADING_STRING = re.compile(r"\s*(" + GRAPHQL_STR + ")")
GRAPHQL_IGNORED = re.compile("(" + GRAPHQL_STR + r")|#[^\n\r]*|[,\ufeff]")
GRAPHQL_STRING = re.compile(GRAPHQL_STR)
GRAPHQL_BODY_VAR = re.compile(r"\bbody\s*:\s*\$\s*(\w+)")
GRAPHQL_INPUT_VAR = re.compile(r"\binput\s*:\s*\$\s*(\w+)")


def graphql_call_args(query, start):
    """Return the balanced `( ... )` argument text of the call whose `(` ends just before `start`.

    A sibling field after the mutation (`addComment(input:{body:...})`) is not this call's body
    (#906 review); an unbalanced list runs to the end, which only widens what is judged.
    """
    depth = 0
    masked = mask_graphql_strings(query)
    for i in range(start, len(masked)):
        depth += {"(": 1, ")": -1}.get(masked[i], 0)
        if depth < 0:
            return query[start:i]
    return query[start:]


def mask_graphql_strings(text):
    """Blank every string literal, keeping offsets, so keywords inside a literal never match."""
    return GRAPHQL_STRING.sub(lambda m: " " * len(m.group(0)), text)


def read_graphql_file(path, shifted):
    """Return a regular file's text (capped), or None when it cannot be judged statically.

    A pipe, tty or device (`/dev/stdin`, `/dev/zero`) is never the file the shell will feed gh,
    and a relative path after a `cd` or a redirect may name a different file than the hook sees.
    """
    moved, written, opaque = shifted
    real = os.path.realpath(path)
    if opaque or (moved and not os.path.isabs(path)) or any(
            real == w or real.startswith(w.rstrip(os.sep) + os.sep) for w in written):
        return None
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as fh:
        text = fh.read((1 << 20) + 1)
    return text if len(text) <= 1 << 20 else None  # over the cap: the tail is unseen


def graphql_issue_write(fields, input_file, shifted=(False, frozenset(), False), quoted=frozenset()):
    """Return the match dict for a `gh api graphql` createIssue/updateIssue mutation, or None.

    The GraphQL twin of the REST issue write (dotfiles-linux-dev#903): the mutation text comes
    from a `query=` field (or the `query` member of an --input JSON file); its body is a
    `body=` variables field, a `variables.body`/`variables.input.body` member, or an inline
    `body: "..."` literal. Reads (no such mutation) return None and stay allowed; an input the hook cannot see (stdin,
    `--input -`, an unreadable file, a shell-built query) is judged blind, which blocks.
    """
    blind = {"matched": True, "repo": None, "head": None, "has_body": False, "body": None,
             "has_body_file": True, "body_file": "-", "body_json": True,
             "labels": [], "auto": False, "method": "POST"}
    query, values = "", {}
    for typed, field in fields:
        key, _, val = field.partition("=")
        from_file = typed and val.startswith("@")
        if from_file:  # -F key=@file: gh reads the value from the file
            if val == "@-":
                return blind  # stdin is never visible to the hook
            try:
                val = read_graphql_file(val[1:], shifted)
            except (OSError, ValueError):
                val = None
            if val is None:
                return blind  # unreadable / binary / stdin / device: the value is unseen
        if not from_file and val:
            val = re.sub(r"\\([$`])", r"\1", val)  # shlex keeps `\$` in "..."; bash drops the `\`
        if key == "query":
            query = val
        else:
            values[key] = val
    if input_file == "-":
        return blind
    if input_file:
        try:
            raw = read_graphql_file(input_file, shifted)
            if raw is None:
                return blind
            data = json.loads(raw)
            query = str(data.get("query", ""))
            variables = data.get("variables") or {}
            values = {k: v for k, v in variables.items() if isinstance(v, str)}  # -f is query-string
            values.update({k + "[body]": v["body"] for k, v in variables.items()
                           if isinstance(v, dict) and isinstance(v.get("body"), str)})
            values.update({k + "[]": "" for k, v in variables.items()
                           if isinstance(v, dict) and "body" not in v})  # object, no body: left alone
        except (OSError, ValueError, AttributeError, RecursionError):
            return blind  # unreadable / stdin / not an object / too deep: the mutation is unseen
    # GraphQL treats `,` and `#...` comments as whitespace; blank them outside strings (#906 review)
    query = GRAPHQL_IGNORED.sub(lambda m: m.group(1) or " ", query)
    muts = list(GRAPHQL_ISSUE_MUTATION.finditer(mask_graphql_strings(query)))
    if not muts:
        return None
    body = None  # only the mutation's own body source counts: a stray `-f body=` is never GitHub's
    seg = graphql_call_args(query, muts[0].end())
    masked = mask_graphql_strings(seg)  # keywords inside a string literal are not syntax
    refs = GRAPHQL_BODY_VAR.findall(masked)  # `body: $name`: the variable may be named anything
    inp = GRAPHQL_INPUT_VAR.search(masked)  # `input: $name`: gh's `name[body]=` or a JSON value
    lits = [m.group(1) for k in GRAPHQL_BODY_KEY.finditer(masked)
            if (m := GRAPHQL_LEADING_STRING.match(seg, k.end()))]
    if lits:  # the literal in the mutation itself is what GitHub stores: judge it first
        lit = lits[0]
        if lit.startswith('"""'):
            # ponytail: cleandoc also strips the first line's indent, which GraphQL keeps
            body = inspect.cleandoc(lit[3:-3].replace('\\"""', '"""'))
        else:
            try:
                body = json.loads(lit)
            except ValueError:
                body = lit[1:-1]
    elif refs:
        body = values.get(refs[0], "")  # unsupplied (a default may apply): fail closed
    elif inp:
        name = inp.group(1)
        body = values.get(name + "[body]")
        # gh `name[k]=` fields without a body: the update leaves the body alone
        if body is None and not any(k.startswith(name + "[") for k in values):
            try:
                body = json.loads(values.get(name, "")).get("body")
                body = body if body is None or isinstance(body, str) else ""
            except (ValueError, AttributeError, RecursionError):
                body = ""  # input object unresolved: fail closed, body unknown
    body_keys = {refs[0]} if refs else ({inp.group(1), inp.group(1) + "[body]"} if inp else set())
    if not lits and body_keys & quoted:
        body = ""  # `-f b="${X:-ok}"`: the shell rewrites the very text judged, GitHub stores another
    if body is None and re.search(r"\bbody\b", GRAPHQL_STRING.sub('""', seg)):
        body = ""  # a `body` no branch resolved (a list, an object, a bare `$`): fail closed
    if len(muts) > 1 or len(lits) + len(refs) > 1:
        body = ""  # several mutations / decoy `body:` literals: ambiguous, fail closed
    creating = muts[0].group(1) == "createIssue" or len(muts) > 1
    has_body = body is not None or creating  # a create with no body IS an empty body
    return {"matched": True, "repo": None, "head": None, "has_body": has_body,
            "body": body if body is not None else ("" if creating else None),
            "has_body_file": False, "body_file": None, "body_json": False,
            "labels": [], "auto": False, "method": "POST" if creating else "PATCH"}


def without_redirects(words):
    """Drop `> out` and `2>&1`: bash consumes them, so gh never sees them as arguments.

    Works on marked words, where a quoted `>` is QUOTED_GT and so never matches.
    """
    kept, skip = [], False
    for word in words:
        m = None if skip else REDIRECT.match(word)
        if not skip and not m:
            kept.append(word)
        skip = bool(m and not m.group(1))
    return kept


ATTACHED_REDIRECT = re.compile(r"^([^<>]*?)[0-9&]*[<>]+[|&]?(?!\()(.*)$", re.S)


def strip_redirects(words, marked):
    """Cut redirects out of a gh argv (and its marked twin) the way bash does, attached or not.

    `graphql>/dev/null` is the word `graphql` plus a redirect; `-t>/dev/null` is `-t`. A redirect
    with no attached target eats the next word. Quoted `<`/`>` are QUOTED_GT, never redirects.
    """
    out_w, out_m, skip = [], [], False
    for word, mark in zip(words, marked):
        if skip:
            skip = False
            continue
        m = ATTACHED_REDIRECT.match(mark)
        if not m:
            out_w.append(word)
            out_m.append(mark)
            continue
        head = len(m.group(1))
        if head:
            out_w.append(word[:head])
            out_m.append(mark[:head])
        skip = not m.group(2)
    return out_w, out_m


def unread_short_flag(tok):
    """True for `-if`-shaped words: pflag clusters them, so a value flag can hide inside."""
    return (tok.startswith("-") and not tok.startswith("--") and len(tok) > 2
            and tok[:2] not in API_VALUE_FLAGS and tok[:2] not in API_OTHER_VALUE_FLAGS)


def graphql_shell_built(rest, mrest):
    """True when the hook cannot see what a `gh api graphql` call sends.

    An unquoted expansion can add whole arguments (`$ARGS`, `"$@"` aside, both split); a quoted
    one rewrites the word it sits in, so a field key, a query, an --input path or a stray
    positional is unseen. A quoted expansion inside another field's VALUE is only a value
    (`-f owner="$OWNER"`): the mutation text the hook judges is unchanged by it, unless it is a
    command substitution next to a file read: bash runs it before gh opens the file.
    A word the parser could not place (a stray, a flag cluster, a brace expansion) or a query
    in the URL hides the real call just the same.
    """
    mrest = without_redirects(mrest)
    if any(SHELL_SPLIT in t for t in mrest):
        return True
    endpoint, _, fields, input_file, stray = parse_api_args(mrest)
    if stray or "?" in (endpoint or "") or any(
            unread_short_flag(t) or (t.startswith("-") and SHELL_QUOTED in t) for t in mrest):
        return True
    pairs = [f.partition("=") for _, f in fields]
    if any("{" in key or (val.startswith("@") and "{" in val) for key, _, val in pairs):
        return True  # `-F{a=1,query=@f}`: bash expands it into fields the parser never saw
    reads_file = input_file or any(val.startswith("@") for _, _, val in pairs)
    if reads_file and any(m in t for t in rest for m in ("$(", "`", "<(", ">(")):
        return True
    keys_and_queries = [f if f.partition("=")[0] == "query" else f.partition("=")[0]
                        for _, f in fields]
    return any(SHELL_QUOTED in t for t in (endpoint or "", input_file or "", *stray,
                                           *keys_and_queries))


GRAPHQL_RAW_VARIABLE = re.compile(r"variables\[([^\]]*)\](.*)$")


def ungrouped_graphql_fields(fields):
    """Fields as GitHub sees them when gh does not group them into `variables`.

    gh groups fields into `variables` only for the literal endpoint `graphql`; `/graphql` or a
    full URL sends each field as a top-level JSON member (measured with GH_DEBUG=api), so there
    the real variables are `variables[k]...` fields and any other field is not a variable.
    """
    out = []
    for typed, field in fields:
        key, eq, val = field.partition("=")
        m = GRAPHQL_RAW_VARIABLE.match(key)
        if key == "query" or m:
            out.append((typed, (m.group(1) + m.group(2) if m else key) + eq + val))
    return out


DIR_CHANGERS = {"cd", "pushd", "popd"}
REDIRECT = re.compile(r"[0-9&]*>[>|]?(.*)$")


GH_NO_FILE_WRITE = {"api", "auth", "search", "status"}  # not issue: `issue develop --checkout`
HARMLESS_BEFORE_GH = {"export", "echo", "printf", "set", "true", "false", ":", "unset", "declare",
                      "local", "readonly", "test", "[", "[["}


def chain_moves_files(segments):
    """Return (directory changed, real paths the chain may write, opaque): files a hook read may
    predate.

    Every word of a command other than gh counts as a path it may write, not a list of known
    writers: cp, mv, ln, install, sed -i, dd of=, curl -o, ... (#906 ladder review). Paths are
    resolved, so `> /abs/repo/q` and `@q` name the same file; the reader also treats a written
    directory as covering everything under it (`cp x . && ... @q`).
    `opaque` is a command before the last gh that can write files without naming them (tar,
    unzip, patch, a checkout, make, source, a function): a file read is then never trusted.
    ponytail: an attached short value (`curl -oq`) is not read; add it if a writer needs it.
    """
    moved, writes, opaque_at, last_gh = False, [], [], -1
    for n, argv in enumerate(iter_argvs(segments)):
        words = [_word(t) for t in argv]
        moved = moved or any(w in DIR_CHANGERS for w in words) or ("env" in words and any(
            t in ("-C", "--chdir") or t.startswith(("--chdir=", "-C")) for t in argv))
        is_gh = gh_start(argv) >= 0
        if is_gh:
            last_gh = n
            # `gh release download -O q`, `gh pr checkout`, `gh repo sync`, an extension: all can
            # rewrite the worktree, so only the subcommands known to touch no file are trusted.
            if (argv[gh_sub(argv, gh_start(argv)):][:1] or [""])[0] not in GH_NO_FILE_WRITE:
                opaque_at.append(n)
        else:
            command = next((w for w in words if not re.match(r"^\w+=", w)), None)
            substitutes = any(m in t for t in argv for m in ("$(", "`", "<(", ">("))
            if substitutes or (command is not None and command not in HARMLESS_BEFORE_GH):
                opaque_at.append(n)  # `X=$(cp evil q)` runs a writer inside a "harmless" word
        for i, tok in enumerate(argv):
            m = REDIRECT.search(tok)
            if m:
                target = m.group(1) or (argv[i + 1] if i + 1 < len(argv) else "")
            elif is_gh or (tok.startswith("-") and "=" not in tok):
                continue
            else:
                target = tok.split("=", 1)[-1]  # `of=path`, `--output=path`
            if target and (target.startswith("&") or any(c in target for c in "$~*?[{")):
                opaque_at.append(n)  # `>&q`, `> "${F}x"`, `> q.gr*`: the real path is the shell's
            elif target:
                try:
                    writes.append((n, os.path.realpath(target)))
                except ValueError:  # an embedded NUL: never let it fail the hook open
                    opaque_at.append(n)
    return moved, {w for n, w in writes if n < last_gh}, any(n < last_gh for n in opaque_at)


def parse_api_args(rest):
    """Return (endpoint, method, fields, input_file, stray) read off `gh api`'s argv tail.

    stray: 2nd+ positionals; gh takes one, so these are a flag value we misparsed.
    """
    endpoint, method, fields, input_file = None, None, [], None
    stray = []
    i = 0
    while i < len(rest):
        tok = rest[i]
        if tok == "--":  # end of options: the rest are positionals
            tail = rest[i + 1:]
            if endpoint:
                stray += tail
            else:
                endpoint, stray = (tail[0] if tail else None), stray + tail[1:]
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
            i += 1 if "=" in tok and tok.startswith("--") else 2  # `--template=` is complete
        elif tok.startswith("-"):
            i += 1
        else:
            if endpoint:
                stray.append(tok)
            endpoint = endpoint or tok
            i += 1
    return endpoint, method, fields, input_file, stray


def api_issue_match(segments):
    """Return the match dict for `[rtk] gh api repos/O/R/issues[/N]` writes, or None.

    The REST twin of `gh issue create|edit` (dotfiles-linux-dev#714): `gh api` creates an issue on
    POST (explicit `-X POST`/`--method POST`, or implicit when any field/--input is given and
    no method is) and edits one on PATCH, so a guard that only sees `gh issue ...` is bypassed
    by it. Body is read from a `body=` field (`-f`/`-F`/`--raw-field`/`--field`); `-F body=@f`
    and `--input f` are file-valued (`body_json` marks that the file is a JSON payload).
    """
    shifted = chain_moves_files(segments)
    found = None
    for argv, marks in iter_argvs_marked(segments):
        # Same command-word rule as the `gh issue` path: gh must be the command itself (after
        # wrappers), so printed text like `echo gh api ...` is not a write. The fail-closed part
        # lives below, in how an understood-vs-unknown `gh api` call is judged.
        gh_at = gh_start(argv)
        if gh_at < 0:
            continue
        sub = gh_sub(argv, gh_at)
        if argv[sub:sub + 1] != ["api"]:
            continue
        rest, mrest = argv[sub + 1:], marks[sub + 1:]
        rest, mrest = strip_redirects(rest, mrest)
        endpoint, method, fields, input_file, stray = parse_api_args(rest)
        path = re.sub(r"^https?://[^/]+/(api/v3/)?", "", re.split(r"[?#]", endpoint or "", maxsplit=1)[0],
                      flags=re.I)
        path = path.rstrip("/")
        if (re.search(r"[*\[]|\?(?!\w+=)|\{[^}]*,[^}]*\}", endpoint or "")
                and (fields or input_file or (method or "GET") != "GET")):
            return graphql_issue_write([], "-")  # `{graphql,}`, `gr[a]phql`: bash picks the endpoint
        if posixpath.normpath("/" + urllib.parse.unquote(path)).strip("/").lower() in (
                "graphql", "api/graphql"):  # `gr%61phql`, `x/../graphql`: the front end may decode
            if graphql_shell_built(rest, mrest):
                return graphql_issue_write([], "-")  # the shell writes part of the call: blind
            marked = parse_api_args(mrest)[2]
            if endpoint != "graphql":
                if any(f.startswith("variables[query") for _, f in fields):
                    return graphql_issue_write([], "-")  # would shadow the judged `query`
                fields, marked = ungrouped_graphql_fields(fields), ungrouped_graphql_fields(marked)
            quoted = {f.partition("=")[0] for _, f in marked if SHELL_QUOTED in f.partition("=")[2]}
            gql = graphql_issue_write(fields, input_file, shifted, quoted)
            if gql and found:
                return graphql_issue_write([], "-")  # one verdict cannot cover two writes
            found = found or gql
            continue
        dynamic = ("$" in path or "`" in path or not endpoint  # endpoint the shell builds / unseen
                   or any("$" in t or "`" in t for t in stray))  # stray may be the real endpoint
        if dynamic and endpoint and only_repo_segment_is_dynamic(path):
            dynamic = False  # judged by its literal resource, like the unparameterised twin
        m = API_ISSUE_ENDPOINT.match(path)
        # Endpoint path only: a `-f body=...issues...` value or an --input file never decides
        # (dotfiles-linux-dev#874). PR review-comment endpoints (pulls/N/comments[/ID/replies],
        # pulls/comments/ID, pulls/N/reviews) carry no `issues` segment, so they fall through.
        # Whole path segment, so a repo named `my-issues` does not turn its PR replies into issue
        # writes. The decision rests on `endpoint` above: a value flag missing from
        # API_VALUE_FLAGS/API_OTHER_VALUE_FLAGS lets its value be mistaken for the endpoint, so a
        # new `gh api` flag that takes a value must be added there.
        # A stray positional with an `issues` segment is the same hazard from the other side: the
        # parser took a flag value for the endpoint, so the real one is left over here.
        mentions = any("issues" in re.split(r"[?#]", p, maxsplit=1)[0].split("/")
                       for p in (path, *stray))
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
        if found:
            return graphql_issue_write([], "-")  # one verdict cannot cover two writes
        no_body = not (has_body or has_body_file)
        if no_body and (unknown_write or (method in ("POST", "?") and not number)):
            has_body, body = True, ""  # REST create has no editor mode: no body IS an empty body
        found = {
            "matched": True, "repo": repo, "head": None, "has_body": has_body, "body": body,
            "has_body_file": has_body_file, "body_file": body_file, "body_json": body_json,
            "labels": labels, "auto": False, "method": method,
        }
    return found


def looks_like_gh_api(text):
    """True when quote-stripped text still reads `gh ... api`: `gh a''pi` is the same command."""
    return bool(re.search(r"\bgh\b[\s\S]*\bapi\b", re.sub(r"['\"\\]", "", text), re.I))


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
            if any(looks_like_gh_api(e) for e in NESTED_ERRORS):
                match = {"matched": True, "unparseable": True}
            print(json.dumps(match or {"matched": False}))
            return 0
        argv = matching_argv(segments, noun)
    except ValueError:
        if noun == "api-issue" and looks_like_gh_api(command):
            # Fail CLOSED for `gh api` (#714): text that looks like an issues write but
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
