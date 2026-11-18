---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.js"
  - "**/*.jsx"
  - "**/package.json"
  - "**/tsconfig.json"
---

# JavaScript / TypeScript Preferences

> **Priority rule:** These are personal JS/TS defaults — they apply to JavaScript and
> TypeScript files alike, including JSX/TSX. Whenever a project-level CLAUDE.md (or any
> instruction inside the active repository) conflicts with anything here, the project context
> takes precedence. Treat this file as a fallback, not a mandate — and never let
> "best practice in general" silently override a project-specific rule.

## `ls`-after-save filename verification

Immediately after a user reports "done" for a step that created or renamed
files, run `ls` (or its RTK equivalent) on the affected directory and
visually confirm every filename matches the expected name **before**
running linters/tests or marking the step complete.

**Why this is TS/JS-specific.** In compiled languages with eager
resolution (Rust, Go), a typo'd filename fails at compile time. In
languages with runtime imports (Python), it fails at first execution.
TS/JS hides filename typos behind several layers of tolerance:

- Ambient `*.module.css` / `*.css` declarations in `declarations.d.ts`
  accept any wildcard-matching string as "typed", so `tsc` passes.
- Jest's `moduleNameMapper` regexes use catch-all patterns for CSS, so
  unit tests pass.
- ESLint's `import/no-unresolved` (when configured) catches JS/TS path
  typos but **not** CSS path typos, because of the ambient declarations
  above.
- Webpack-resolve catches them only at `npm start` / build time, which
  is after the lint stack has already given a green light.

Real examples from this user's projects (recurring across weeks of
tutoring): `inedx.tsx` (transposed letters), `styles.,module.css`
(stray comma), `CountDown.modules.css` (extra `s`), `MainFrom.tsx`
(typo'd word). All four passed the full lint stack.

**The rule.** A 50ms `ls` is the cheapest mitigation for an entire bug
class no static tool reliably catches. Run it before the lint stack,
not after.

## Function ordering within a file

Default to **caller above callee** (the "newspaper rule"): the file's
primary export appears first, helpers below. JavaScript function
declarations hoist, so this is purely a readability choice — readers
get the file's intent before its mechanism. Existing files in the
codebase set the local convention; respect it. Cross-file calls don't
trigger this rule — it applies within a single file.

```ts
// ✅ Top-down: intent (the exported entry) first, mechanism below
export function MainForm() {
  /* uses startTask, interruptTask */
}

function startTask() { /* ... */ }
function interruptTask() { /* ... */ }

// ❌ Bottom-up: reader hits unfamiliar helpers before knowing why
function startTask() { /* ... */ }
function interruptTask() { /* ... */ }

export function MainForm() {
  /* "what does this file do?" — answered last */
}
```

## Extract pure validation functions

When a function (or hook) carries **both** "validate raw input" AND
"act on the validated result", extract validation into its own pure
function. The hook stays focused on orchestration; the validator
becomes reusable, testable, and React-free. Place it in `domain/` if
the rules are domain knowledge ("what counts as valid Settings"), in
`application/task-utils.ts` if they're pragmatic helpers, or below the
hook in the same file if the validator has no second caller.

Return a discriminated-union result so TypeScript narrows access:

```ts
// ✅ Pure validator returns a typed result
export type SettingsValidationResult =
  | { ok: true; value: UpdateSettingsDto }
  | { ok: false; errors: string[] };

export function validateSettings(workRaw, shortRaw, longRaw): SettingsValidationResult {
  /* ...rules.../ */
  if (errors.length > 0) return { ok: false, errors };
  return { ok: true, value: { workTime, shortBreakTime, longBreakTime } };
}

// Use-case hook becomes orchestration-only
export function useChangeSettingsWithValidation(dispatch, notifier) {
  return useCallback((wRaw, sRaw, lRaw) => {
    const result = validateSettings(wRaw, sRaw, lRaw);
    if (!result.ok) { result.errors.forEach(notifier.error); return; }
    dispatch({ type: ActionTypes.CHANGE_SETTINGS, payload: result.value });
  }, [dispatch, notifier]);
}
```

**Why a discriminated union over throwing or returning null:** the
caller can't accidentally use `result.value` when validation failed —
TypeScript prevents it. Throwing forces try/catch ceremony at every
call site; returning `null` loses the error reasons.

## Module resolution and import hygiene

- Prefer `eslint-plugin-import` with `import/no-unresolved`,
  `import/no-duplicates`, `import/no-cycle`, and `import/order`. If a
  project lacks these, suggest installing them at the first import-typo
  bug.
- The `*.css` wildcard ambient is intentional — needed for side-effect
  CSS imports like `import '@/shared/styles/global.css'`. Don't try to
  remove it to "catch CSS typos"; the cure is worse than the disease.
  The `ls`-after-save convention above is the right mitigation.
- Path aliases (`@/` etc.) must include the slash. `@/shared/...`
  resolves to the project's source root; `@shared/...` (no slash) is
  interpreted by TS as an npm-scoped package and fails resolution.

## Test scoping

- Unit-test framework: prefer Jest with `@testing-library/react` for
  React projects, configured via `babel-jest` so the test transform
  matches the build transform.
- Co-locate component tests as `*.test.tsx` next to the component.
- E2E framework: prefer Playwright. Namespace scripts as
  `test:e2e:frontend` / `test:e2e:api` / `test:e2e:db` so a static SPA
  layout can grow into a fullstack one without renaming. Visual
  regression via `toHaveScreenshot` baselines committed to the repo.

## Browser MCP routing

Playwright MCP is the default for navigate, test and screenshot work. Use
the `chrome-devtools` MCP only for what Playwright cannot do: performance
traces (LCP/CLS/INP), CPU/network throttling and DevTools-grade network
detail.

## CSS Modules pitfalls

CSS Modules accept unitless non-zero lengths silently (e.g.
`border-radius: 50` instead of `50%` — invalid, browser drops the rule,
renders the wrong shape). Neither stylelint-config-standard nor any
type checker catches this class. Visual inspection in a browser is the
only reliable check; a Playwright `toHaveScreenshot` baseline is the
automated proxy.

The other CSS-Modules pitfall: importing `styles` then writing a
literal string like `className="className"` instead of
`className={styles.className}`. The DevTools-inspect class is
`"className"` (literal), not the hashed CSS-Module class. Easy to miss
without a render check.

## Boundary rules (FSD + DDD — classical hexagonal)

When a project ships `eslint-plugin-boundaries` (e.g. blueprintx-based
React projects), respect the layer hierarchy:

- `domain` → nothing (pure ports + entity types)
- `application` → `domain` ONLY (use cases depend on port interfaces,
  not concrete adapters)
- `infrastructure` → `domain` ONLY (adapters implement ports, never
  reach into `shared/` or `ui/`)
- `ui` → `application`, `domain`, `composition-root`, `shared`
- `composition-root` → `domain`, `application`, `infrastructure`,
  `shared` (this is the DI assembly point — it knows about everything
  because that IS its job)
- `shared` → `shared`
- `routes` → `barrel`, `shared`

**`application → infrastructure` is the most common boundary leak.**
Avoid it by introducing a port (interface in `domain/ports.ts`) that
the use-case hook accepts as a parameter, and an adapter
(implementation in `infrastructure/`) that satisfies the port. The
composition root wires the concrete adapter into the hook's argument
list when the UI calls it.

```ts
// ✅ Classical hexagonal
// domain/ports.ts
export interface INotifier { info(msg: string): void; /* ... */ }

// infrastructure/show-message.ts
export const showMessage: INotifier = { /* ... */ };

// application/use-cases.ts — depends on the port, not the adapter
export function useDoSomething(notifier: INotifier) { /* ... */ }

// composition-root (context.tsx) — wires the concrete instance
import { showMessage } from './infrastructure/show-message';
<Context.Provider value={{ notifier: showMessage }}>
```

**`infrastructure → shared` is the second-most-common leak** and is a
DDD anti-pattern if `shared/` holds UI primitives. An adapter that
needs a UI component (e.g. react-toastify's `toast(Component, ...)` API)
should accept the component via **constructor DI** from the
composition root, not import it directly:

```ts
// ✅ Constructor DI — adapter is shared-agnostic
export class ToastConfirmPrompt implements IConfirmPrompt {
  constructor(private readonly DialogComponent: ToastContent<string>) {}
  ask(question, onResponse) { toast(this.DialogComponent, ...); }
}

// composition-root instantiates with the concrete Dialog
import { Dialog } from '@/shared/components/Dialog';
const confirmPrompt = useMemo(() => new ToastConfirmPrompt(Dialog), []);
```

**Why call it "composition-root", not "context"?** The file that owns
React's `<Context.Provider>` happens to also be the DI assembly point —
but the latter is the architectural identity, the former is just one
implementation detail. Naming the ESLint boundary category
"composition-root" makes the intent explicit and matches DDD
terminology.

## When in doubt

If a TS/JS step produced surprising behavior despite a clean lint
stack, suspect:

1. Filename typo (run `ls` first — see top of this file)
2. CSS Modules misuse (literal class string, missing unit, wrong file
   extension)
3. Semantic JSX bug (missing element, wrong icon/handler pairing —
   write a `@testing-library/react` spec before guessing further)
4. Boundary violation (a use-case importing UI, an adapter importing
   shared/components/, etc.)
