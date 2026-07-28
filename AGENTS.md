# AGENTS.md

Guidance for coding agents working in this repo — the standalone repo of the **para/ai** Noeta package (an agent harness: the provider codec seam, the run loop, tool calling, and GenAI telemetry; pure Noeta). Toolchain issues (the language, the `noeta` binary, `std.*`) belong in the monorepo at github.com/noeta-lang/noeta, not here; `para/api` issues belong in its own repo.

**`DESIGN.md` is the spec.** It is the whole plan, phase by phase, with the reasoning behind each decision and the questions that were settled. Read the section you are about to touch before touching it, and if a language limitation forces a change, say so rather than diverging quietly.

## Repo layout

- `noeta.toml` — the package manifest (`name = "para/ai"`). **No `native` key: this package is pure Noeta.** The `[trust] native = ["para/api"]` line authorizes the *dependency's* native half, not ours.
- `ai.noe` — `para.ai`: the data model (`Message`/`Part`/`Role`/`Conversation`/`Run`), `AgentConfig`, `Agent<P: Provider>`, the run loop, `AiError`, and the GenAI telemetry emitted from the loop.
- `provider.noe` — `para.ai.provider`: the `Provider` trait, `ModelRequest`/`ModelReply`/`Wire`/`Framing`/`Usage`/`StopReason`, the `Delta` accumulator (`fold`), and the shared codec utilities (recoverable JSON, base64).
- `tools.noe` — `para.ai.tools`: the `Tool`/`Arg` attributes, `ToolSpec`, the `ToolSource` trait, `Local` (reflection over `#[Tool]`), `Toolbox`, `Type` → JSON Schema, argument coercion, and bounded concurrent `dispatch`.
- `anthropic.noe` — `para.ai.providers.anthropic`: the Anthropic Messages API codec.
- `mock.noe` — `para.ai.mock`: the scripted `Mock`, which is both a `Provider` and a `para.api.Middleware`.
- `examples/*/` — each a standalone package depending on this repo via `para = { path = "../.." }`, with its own committed `noeta.lock`. `ask` is the phase-1 surface; `tools` is the phase-2 tool loop.
- `.github/workflows/` — CI (`ci.yml`) and the tag-triggered registry publish (`release.yml`).

### Why the files are flat

DESIGN.md §16 sketches `providers/anthropic.noe`. The files are at the repo root instead, with the design's **namespaces** unchanged (`anthropic.noe` declares `namespace para.ai.providers.anthropic`). The reason is the module loader: a dependency package is walked recursively, but an entry file's sibling scan is **flat**, so a `.noe` file in a subdirectory can neither see its siblings one level up nor be linked when `noeta check`/`noeta test` runs it as an entry. That would make the package's own `@test` blocks unrunnable. Namespaces are declaration-based, so nothing about the public surface depends on the path — put new modules at the root and give them the namespace DESIGN.md names.

## Toolchain floor

> **This package needs three toolchain fixes that are not in `noeta 0.2.3`.** Two of them are hard blockers: a bounded generic type's methods could not call one another (`self.drive(…)` inside `Agent<P: Provider>` reported E0025 against the very declaration that states the bound), and an enum's `impl From<Source>` was shadowed by the built-in name-string `Enum.from(s)`, so `AiError`'s `From<HttpError>` type-checked and then aborted at runtime. The third closes a hole where `?` on an `Option` inside a non-`Option` function put a `none` in a slot the checker had promised held a `string`. Once they ship, raise `toolchain` in `noeta.toml` from `">=0.2"` to that release and delete this section.

## Build & test

Pure Noeta — no cargo anywhere in this repo. But note:

- **The first `noeta check` composes a toolchain** (several minutes), because `para/api` ships a native extension crate that has to be compiled in. Later runs reuse the cached binary. If a command seems to hang on `composing the toolchain with native dependencies [para/api]`, it is building; let it finish.
- `noeta check <file>.noe` and `noeta test <file>.noe` at the repo root run the package's own suite — the codec fixture tables, the delta fold, the base64 vectors, and the end-to-end run-loop tests over `Mock`.
- `noeta check` / `noeta test` in each `examples/*` directory run that example's suite.
- **Every test is hermetic.** `Mock` is both the codec and the transport, so no test opens a socket and none needs an API key. A suite that needs a key is a failed suite.

## Conventions

- `noeta.lock` files under `examples/` **are committed** — leave resolved locks in place; don't delete or regenerate them gratuitously. The root lock is not committed (it pins a developer-machine path dependency).
- Markdown never hard-wraps lines.
- **American English** throughout — code, comments, and docs (`behavior`, not `behaviour`).
- **Conventional commits** for all commit titles. Commit each green slice as it completes, but **never `git push` without explicit authorization**. Never move a published `v*` tag — a release is a new tag.
- Implement in full — no stubs or TODOs; new functionality lands with tests. A phase that is not built is *absent*, with the seam it attaches to named in a comment — not a function that returns nothing.
- Keep `README.md` and this file up to date when layout or behavior changes.

## Things the language makes you write a particular way

Collected here because each one cost a debugging round the first time:

- **A block-bodied `match` arm produces no value.** In value position every arm must be a single expression (E0055). Extract a helper rather than opening a block.
- **A `match` whose arms all `return` still "falls off the end"** (E0048). Write `return match { … }` with expression arms, or add a trailing `return`.
- **A method that never mentions `self` is an associated function** (E0047) and cannot be called on a value. Make it a module-level `fn` instead.
- **`.await` is not allowed in a synchronous `fn`.** A test that awaits `agent.run(...)` must be an `async fn` — and note the bug below: an `async fn` test is never driven, so its assertions are currently vacuous.
- **`json.parse` aborts on malformed input** and `json.try_parse::<T>` cannot build a `Map<string, dyn>`, so recoverable dynamic decoding goes through `provider.parse_object` / `provider.parse_value`. Never call `json.parse` on a body that came off the wire.
- **A whole-module import binds its last segment as a local name**, which collides with a field of the same name (E0020) — hence `use para.ai.provider.{Wire, …}` in `ai.noe`, where `Agent` has a `provider` field.
- **Reflection keys are qualified.** Under `namespace para.ai.tools`, `attributes_of` reports a free function's target as `para.ai.tools.shout`, and that is exactly the string `params_of`/`invoke` take — a bare `shout` finds nothing. So "does this target contain a dot?" says nothing about whether it is a method; what does is whether the key minus its last segment names a declared type (`field_specs_of(owner).len() > 0`), which is `is_method_target` in `tools.noe`.
- **`invoke` takes a positional `List<dyn>` and nothing else.** Unlike `construct`, it has no named-map form, so a *gap* — a defaulted parameter omitted while a later one is supplied — is not expressible. `bind` in `tools.noe` refuses it by name rather than guessing at the default, which reflection does not expose either.
- **`invoke` validates a callable's name and arity, and not its argument types.** `invoke("f", ["seven"])` against `fn f(n: int)` returns `Ok` and aborts *inside* the body. That is why `tools.noe` coerces every argument to its declared type first: the coercion layer is the type check, and nothing may reach `invoke` around it.

## Toolchain bugs this package works around

Each was reproduced minimally against `lang` at `7575aece`. They are worked around here rather than papered over; when one lands upstream, delete the workaround and the note together.

- **An `async fn` in a `@test` block is never driven.** The runner calls it, gets a `Future`, and drops it — so `assert(false)` in one *passes*. Every assertion in an async test is vacuous. Phase 2's tool-loop tests are therefore written synchronously, over `run_sync` plus `Mock.calls()`, which sees the exact bytes of the second model call and so the whole conversation including the tool turn. `ai.noe` and `mock.noe` still carry two phase-1 `async` tests; they are currently vacuous.
- **`attributes_of::<T>()` sees only the entry module's annotations.** A `#[Tool]` in a sibling `.noe` of the same package is invisible to a suite rooted elsewhere. So `tools.noe` and `mock.noe` each declare their own `#[Tool]` fixtures, named distinctly (`shout` vs `mock_shout`) so that when this is fixed they join rather than collide. The *consumer* case works today, because a consumer's tools live in its entry file.
- **`continue` clobbers a `mut` local assigned in the same block, inside a named `fn`.** `mut a = []; for x in xs { if p(x) { a = a ~ [x]; continue } }` leaves `a` unit on the next iteration, in both `for` and `while`. Correct at top level. `encode_messages` in `anthropic.noe` is written with `if`/`else if`/`else` for this reason; **do not add a `continue` after an assignment**.
- **The prelude `Type` and `Semantic` enums have no expression form at runtime.** `Type.Unit` and `Semantic.TrustBoundary` type-check clean and then abort with E0005 at run time (`Ordering.Less`, seeded by both backends, works). So a role query is `match r.role { Semantic.TrustBoundary => … }`, never `==`, and the schema-refusal tests read their `Type` values off `params_of` of real declarations rather than building them.
- **`noeta mcp`'s `reflect` does not report a role conferred by a *dependency's* `@role` attribute.** The in-language `roles_of::<Semantic>()` does see it (the example asserts this), and `reflect` reports the `#[Tool]` attribute itself — but the `role` list comes back empty, because the prepared program the MCP server reflects over does not include the package where `Tool` is declared. A same-file `@role` attribute reports correctly.

## Telemetry

The GenAI attribute and metric names live in two places — the run loop in `ai.noe` (`invoke_agent`, `chat`, the two histograms) and `dispatch` in `tools.noe` (`execute_tool`, `para.ai.tool.calls`) — and the README states the pinned semantic-conventions version. **A `#[Tool]` function contains no telemetry code**: dispatch is the instrumentation point precisely so it cannot be forgotten at the tool. If you add a span or a metric, add it to the README's tables in the same commit, and keep every metric attribute low-cardinality: `error.type` is an error's *class*, never its message.

## CI

`ci.yml` checks and tests the package and every example with a pinned released `noeta`; `release.yml` publishes the tag to the hosted registry (`noeta publish`, keyless Sigstore provenance via GitHub OIDC). Both go green only once the toolchain repo is published under github.com/noeta-lang/noeta and the pre-publish path dependency on `para/api` is flipped to a registry version.
