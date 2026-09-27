---
name: Feature or fix
about: Propose a change, with its expected file surface declared up front
title: ""
labels: []
---

## What / Why

<!-- What should change, and why. -->

## File surface

<!--
     List every path (or glob) a PR closing this issue is expected to touch, one per line,
     inside the fence below. bin/ci/check_issue_scope.py reads this block at PR time and
     checks that the PR's changed files stay inside it — see docs/issue-scope.md for the full
     design (declaration format, the undeclared/no-linked-issue/API-unreadable cases, and the
     `surface-override:` commit trailer for a PR that must legitimately widen its surface).

     Not sure yet, or the change is exploratory? Leave the block empty or delete it — an issue
     with no declared surface does not block a PR that closes it (UNDECLARED-SURFACE is
     non-blocking by design), but a declared surface is what makes "can these two issues be
     dispatched in parallel?" a query instead of a guess.

     `*` matches across `/`, so `docs/*` and `docs/**` are equivalent — use whichever reads
     clearer.
-->

```surface
# path/to/file/or/dir/** — replace this line; a commented or empty block means undeclared
```
