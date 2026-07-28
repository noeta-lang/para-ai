# para/ai — design

An agent harness for Noeta: model calls, tool calling, MCP, structured responses, guardrails, rolling context, streaming (AG-UI over SSE), and OpenTelemetry — in the shape the rest of the `para` suite already has.

Status: **phases 1, 2, 3, 4 and 8 are built and merged** — the codec seam, all five providers, the run loop with tool calling, GenAI telemetry, streaming, and the `@prompt` tier with automatic cache breakpoints. Phase 6 (MCP) is in flight; 5 (structured output + guardrails) and 7 (AG-UI) are queued. Every toolchain prerequisite this document named has landed (§17); the questions are settled or corrected in place.

---

## 1. Scope

| In | Out (deliberately) |
| --- | --- |
| A `Provider` seam with Anthropic, OpenAI, Google, OpenRouter, and Ollama adapters | Every other provider — third parties write one `impl` |
| Tool calling derived from Noeta function signatures | A tool-definition DSL |
| An MCP **client** (stdio + streamable HTTP) | An MCP server — the toolchain already ships `noeta mcp` |
| Structured responses decoded into typed Noeta values | A schema DSL — the type *is* the schema |
| Guardrails at four run stages | A hosted moderation service |
| Context strategies (window, summarize, pin) | A vector store or a retrieval engine |
| Streaming events, AG-UI encoding, an SSE responder | A frontend |
| GenAI-semconv OTel spans and metrics | A new telemetry stack — `std.tracing`/`std.metrics` already exist |
| **Memory as an MCP server** | A memory subsystem of our own |

The last row is the goose model and it is the right one: memory that lives behind MCP is swappable, inspectable, and shared with every other agent the user runs. para/ai ships no store, no embedder, no recall heuristic. It ships the client that talks to whichever one you point it at, and a documented pattern for injecting recalled memory into the context (§10).

---

## 2. Three load-bearing decisions

### 2.1 Providers are codecs, not clients

The obvious design gives `Provider` a `generate(req)` method that performs HTTP. That design is wrong here, for the same reason `std.http` stops at `prepare`/`send` and `para/api` owns the onion: **the thing that varies between providers is the wire format, not the transport.** Auth headers, retries, timeouts, mocking, recording, and tracing are identical across all of them.

So a provider implements a **pure codec**:

```noeta
trait Provider {
    fn name(): string                                       // "anthropic" | "openai" | "ollama" | …
    fn encode(req: ModelRequest): Result<Wire, AiError>     // → { url, headers, body, framing }
    fn decode_reply(body: string): Result<ModelReply, AiError>
    fn decode_error(status: int, body: string): AiError     // the vendor's own typed error body
    fn decoder(): dyn StreamDecoder                         // fresh, stateful, per request
    fn estimate_tokens(msgs: List<Message>): ?int
}

trait StreamDecoder {
    fn push(frame: Frame): Result<List<Delta>, AiError>     // provider frame → neutral deltas
    fn finish(): Result<Usage, AiError>
}
```

Everything that follows falls out of this:

- **Transport is written once.** One run loop, over a `para/api` `Api`. Retry with `Retry-After`, `Mock`, `Record`, `Cache`, and `Logging` come from that package for free — a 429 backoff is not para/ai code.
- **A provider is trivially testable.** `encode` and `decode_reply` are pure string-in/string-out functions. A provider's whole test suite is a table of fixtures with no network and no clock.
- **Adding a fourth provider is a pure-Noeta afternoon.** No async, no HTTP, no telemetry, no guard plumbing to re-implement.
- **The Mock provider is not a special case.** It is a `Provider` whose `encode` ignores the request and whose `decode_reply` returns a scripted reply.

Two of those signatures were corrected by building it. `encode` returns a `Result` because §4 requires a codec to reject what its vendor cannot express, loudly, naming the part — which is an encode-side failure the original sketch had nowhere to put (hence the `AiError.Encode` variant in §13). And `decode_error` joined the trait because a vendor's typed error body is codec-shaped knowledge like any other: without it, §13's promise that `code == "rate_limit_error"` is matchable would have had to be met by the run loop guessing at three different error envelopes.

`StreamDecoder` is stateful because every provider's streaming protocol is (Anthropic's indexed `content_block_delta`, OpenAI's `choices[].delta` accumulation, Google's partial `candidates`). It is a fresh object per request, lives inside the run loop's task, and never crosses a boundary.

**Five providers, three codec families.** OpenRouter and Ollama are the cases that prove the seam rather than strain it, because neither is a new wire format:

| Provider | Family | Delta from the family codec |
| --- | --- | --- |
| Anthropic | `anthropic` | — |
| Google | `google` | — |
| OpenAI | `openai_compat` | — |
| OpenRouter | `openai_compat` | base URL, `HTTP-Referer`/`X-Title` headers, `provider` routing preferences, a `models` fallback array, and reasoning-token accounting |
| Ollama | `openai_compat` (`/v1`) or `ollama` (`/api/chat`) | no auth, `keep_alive`, `options`, and an **NDJSON** stream on the native endpoint |

`OpenAiCompat` is therefore a *parameterized* codec — base URL, auth scheme, and a hook for extra body keys — and OpenRouter and Ollama are configurations of it plus small deltas, not new files of JSON-shuffling. That is the strongest available evidence the codec boundary is drawn in the right place, and it is why a sixth OpenAI-compatible provider (Groq, Together, vLLM, LM Studio, an internal gateway) is a constructor call rather than a pull request.

Two consequences worth naming now:

- **Ollama's native endpoint streams newline-delimited JSON, not SSE.** So the streaming primitive in the native half is a *framed line stream* with SSE and NDJSON as two framings over it, not an SSE reader with NDJSON bolted on later (§3). Getting this wrong in phase 3 is expensive; getting it right costs one enum.
- **Ollama makes CI honest.** Every other provider needs a paid key, so real end-to-end coverage lands in the "nice to have, never runs" bucket. A local Ollama gives the examples and the run loop a genuine non-mock integration test in CI with no secret, which is worth more to this package's reliability than a fourth cloud provider.

OpenRouter earns its place for a second reason: `Summarize` (§10) and `Judge` (§9) both want a *cheap* model alongside the main one, and one OpenRouter key covers both without a second credential path.

### 2.1.1 What phase 4 built, and where it diverges

Built as specified: five providers across three codec families, `OpenAiCompat` parameterized on base URL, vendor name, auth scheme, extra headers, and a raw-JSON body hook, with the pure-codec rule and the `estimate_tokens(): ?int` honesty rule holding throughout.

**The pass condition held.** `OpenAi`, `OpenRouter`, and `OllamaCompat` are field-less structs whose only members are constructors returning an `OpenAiCompat`; not one of them declares a `Provider` impl, an `encode`, a decoder, or a `decode_error`. The evidence is a test rather than a claim — `a_configuration_is_fields_not_code` compares each constructor's result against a literal `OpenAiCompat` — and the payoff the section predicted is real: a sixth compatible provider is `OpenAiCompat.at(url, key, vendor)`, asserted in the same test against a Groq base URL.

Four divergences from the table above, each with its reason:

- **Reasoning-token accounting is not an OpenRouter delta.** The table lists it as one. OpenRouter reports it in `usage.completion_tokens_details.reasoning_tokens`, which is OpenAI's own field, so the family base reads it and OpenRouter contributed no code for it. Its real deltas are three field values plus three helpers that set body keys and headers through the hook.
- **Three capability flags joined the parameterization**, beyond the base URL, auth scheme, and body hook the section names: `max_tokens_key` (OpenAI's reasoning models reject the deprecated `max_tokens`; everyone else normalizes it), `documents` (the `file` content part is OpenAI's and OpenRouter's, not Ollama's `/v1`), and `reasoning_back` (OpenRouter and Ollama accept a reasoning block on input, OpenAI does not). Each is a fact about what an endpoint can *express*, which is exactly the axis a codec's `encode` must refuse along — so they are configuration, not branching.
- **Ollama's native endpoint is a genuinely separate codec**, as the table's second row allows. It is not a delta from `openai_compat`: `arguments` is an object rather than a string, a tool result is addressed by `tool_name` rather than a call id, images are bare base64 on the message, sampling lives under `options` with different key names, and the stream is NDJSON. Sharing one codec across that many disagreements would have meant a mode switch inside it, which is the thing this section exists to prevent.
- **Two vendors report an ordinary stop reason for a tool call.** Gemini's `finishReason` is `STOP` and Ollama's `done_reason` is `"stop"` on a turn whose only content is a function call. Both codecs therefore *derive* `StopReason.ToolUse` from the presence of a call part. Nothing in §2.1 anticipated this, and it is the single most consequential per-vendor fact in the phase: a codec that trusted the vendor's word would end every tool loop on its first turn, with the model's request unanswered and the run reported as complete.

One thing the neutral model could not carry, named rather than dropped: Gemini can return **generated media** in a candidate part, and `Delta` has no increment for an image. That decodes to a loud `AiError.Decode` naming the path, not a picture quietly missing from an answer.

**Ollama did make CI honest.** `examples/providers` runs the whole loop against a local Ollama, buffered and streamed, with no credential — skipped when nothing is listening, and un-skippable in CI via `OLLAMA_REQUIRED=1`, because `noeta test` captures a passing test's stdout and a skip nobody can see is a check that has quietly stopped running.

### 2.2 Reflection is the schema, everywhere

para/cli established that the function signature is the CLI spec. para/aether established that the handler signature is the DI spec. para/ai says: **the function signature is the tool spec, and the struct is the output schema.**

`params_of(name)` already returns each parameter's *declared* `Type` at full fidelity (generic arguments intact), whether it is optional, and its own `#[…]` attributes. `attributes_of::<Tool>()` finds the functions. `invoke(name, args)` calls one by name. That is the entire tool-calling machinery, in the language, with no codegen — see §6.

Both halves of that are already reachable: `field_specs_of::<T>()` answers *"what fields does the type `T` have?"* from a type, with no instance, which is what an output schema needs. This design originally claimed otherwise and was wrong — see §8.5, kept as written because the way it went wrong is instructive.

What reflection genuinely cannot do today is enumerate an **enum's variants** at runtime. There is no `variants_of` mirroring `field_specs_of`, and `params_of` reports a declared enum as `Type.Named`, never `Type.Enum` — so an enum-typed tool parameter is refused rather than half-derived (§6).

### 2.3 The wire is value types, so parallelism works

`class` and `dyn` are `!Send`; value types are `Send`. Since a run's events flow over a `channel` and a parallel-served app runs handlers in isolates, **every type that crosses a run boundary is a `struct` or an `enum`** — `Message`, `Part`, `Delta`, `Event`, `Usage`, `ModelRequest`, `ModelReply`. `bytes` is `Send`, so inline images are fine.

**A provider is a bound, not a trait object.** An agent has exactly one provider, so the slot is homogeneous and can be a type parameter:

```noeta
pub struct Agent<P: Provider> { provider: P  … }
```

That buys three things over `dyn Provider`: the provider stays `Send` (codecs are value structs), dispatch is static, and the bound types the body — a wrong argument or return against a `Provider` method is E0007 at the definition, before any call site exists.

The heterogeneous slots cannot follow it. `List<dyn Guard>` and `List<dyn ToolSource>` hold different concrete types by construction, so those stay trait objects and stay `!Send`. So the practical rule is unchanged but its reason is smaller than it was: **an `Agent` with guards or tool sources is `!Send`; build it per worker** from a `Send` `AgentConfig`, exactly as para/db's connections are.

**Decided (O-7): the bound is the only spelling.** `Provider` never appears as a trait object anywhere in the public surface. The cost is real and is accepted: a bound pins the provider in the type, so `match env.get("PROVIDER") { … }` cannot produce one `Agent` value — each arm is a different type. Runtime provider selection is therefore the *caller's* match, pushed to the outermost point where the arms still agree:

```noeta
// The arms diverge at construction and re-converge at the result type,
// so the duplication is one line each, not a duplicated program.
reply = match env.get("AI_PROVIDER") ?? "anthropic" {
    "openai"     => Agent.from(cfg, OpenAi.new(key)).run_sync(text),
    "openrouter" => Agent.from(cfg, OpenRouter.new(key)).run_sync(text),
    "ollama"     => Agent.from(cfg, Ollama.local()).run_sync(text),
    _            => Agent.from(cfg, Anthropic.new(key)).run_sync(text),
}
```

This is the pattern the README leads with, so nobody discovers the constraint by hitting E0007. It works because `run`/`run_sync`/`stream` all return provider-independent types — the generic parameter never escapes into a result. If a use case ever appears where the arms *cannot* re-converge, adding a `DynProvider` wrapper later is additive and breaks nothing.

**This decision was, it turned out, unimplementable when it was made.** A type parameter did not satisfy the bounds its own declaration gives it, so inside `Agent<P: Provider>` one method calling another failed the callee's `P: Provider` bound against the very declaration that states it — `Agent<P>` could not have had more than one method. Fixed in the toolchain while building phase 1. The design was right and the language did not support it yet; nothing about the sketch revealed that, and only writing the code did.

A note on the two spellings, since the distinction is not obvious and it decided this section. `Provider` is one interface; **`<P: Provider>` and `dyn Provider` are two ways of holding a value that satisfies it** — a bound resolves the concrete type at the call site, a trait object defers it to runtime. Noeta requires the `dyn` keyword in type position precisely so the two are never confused (the same reason Rust added it in 2018). Beyond `Send`, the choice turned out to have teeth: `async` trait methods currently work correctly under a bound and are **unsound** through `dyn` (§17, O-2). The spelling this package standardized on is the one that already works.

---

## 3. Module map

One package, keyed `para`, addressing as `para.ai.*`:

| Module | Contents |
| --- | --- |
| `para.ai` | `Agent`, `AgentConfig`, `Conversation`, `Run`, `Message`, `Part`, `Role`, `AiError` |
| `para.ai.provider` | `Provider`, `StreamDecoder`, `ModelRequest`, `ModelReply`, `Delta`, `Usage`, `StopReason`, `Wire` |
| `para.ai.providers.anthropic` / `.google` | the two bespoke codecs |
| `para.ai.providers.openai` | `OpenAiCompat` (the parameterized family codec) plus `OpenAi`, `OpenRouter`, and `Ollama` as configurations of it |
| `para.ai.providers.ollama` | the native `/api/chat` codec, for the Ollama features `/v1` does not expose |

> **Namespaces are nested; files are flat.** `anthropic.noe` at the repo root declares `namespace para.ai.providers.anthropic`. A `providers/` subdirectory would be wrong: an entry file's sibling scan is **flat**, so a `.noe` one level down can neither see its siblings above it nor link when run as an entry — its `@test` blocks would silently never run. (Recursive walking applies to a *consuming* package's view of a dependency, not to the package's own test run.) Since a namespace is declared rather than derived from the path, nothing public changes. Discovered building phase 1.
| `para.ai.tools` | `Tool`, `Arg`, `Toolbox`, `ToolSource`, schema derivation, dispatch |
| `para.ai.mcp` | `McpClient`, `Stdio`, `Http`, MCP-as-`ToolSource`, approval seam |
| `para.ai.guard` | `Guard`, `Verdict`, `Stage`, the standard guards |
| `para.ai.context` | `ContextStrategy`, `Full`, `Window`, `TokenWindow`, `Summarize`, `Pinned` |
| `para.ai.agui` | `Event`, AG-UI encoding, `respond(agent, req)` |
| `para.ai.mock` | `Mock` provider, `Script` |
| `para.ai.prompt` | the `@prompt` expression tier and its `Prompt` value (§14) |

Telemetry is not a module. It is emitted from the run loop directly onto `std.tracing`/`std.metrics`, so it cannot be forgotten (§12).

**There is no native half.** para/ai is pure Noeta, like para/cli, para/aether, and para/html — no `crates/`, no `native/`, and no `[trust]` grant for consumers.

That is a consequence of where the two missing transport capabilities land. Both are ordinary HTTP facilities with no AI in them, so both belong in `std.http` (§17.1, U-3):

```noeta
// std.http.client — read a response body incrementally, cut into frames
fn stream(req: Request, framing: Framing): Result<FrameStream, HttpError>
enum Framing { Sse; Ndjson; Lines }

// std.http.server — the twin of the `websocket` that is already there
fn sse(fn(SseSink) -> dyn): Response
```

`Framing` is one enum rather than an SSE reader with NDJSON bolted on, because Ollama's native endpoint is newline-delimited JSON while OpenAI-compatible endpoints are SSE — both are "read the body incrementally and cut it into frames", and only the cut differs. `FrameStream.recv(): Future<?Frame>` mirrors `std.http.Socket.recv()`, which is already in the registry.

Putting these in std is the right call on the merits independently of para/ai: a progress endpoint, a log tail, and a build-status stream all want incremental HTTP bodies, and none of them should have to depend on an AI package to get one. The sequencing cost is explicit — **phases 3 and 7 are gated on U-3**, where phases 1, 2, and 4 are not.

Everything else — including the whole MCP stdio transport, which `os.spawn` already supports — is pure Noeta today.

---

## 4. The data model

```noeta
namespace para.ai

pub enum Role { System; User; Assistant; Tool }

pub enum Part {
    Text(text: string)
    Image(mime: string, data: bytes)
    File(mime: string, name: string, data: bytes)
    ToolCall(id: string, name: string, args: string)          // args: raw JSON, decoded at dispatch
    ToolResult(id: string, content: string, is_error: bool)
    Thinking(text: string, signature: string)                 // opaque; round-tripped verbatim
}

@derive(Equatable, Display)
pub struct Message {
    role: Role
    parts: List<Part>
    name: ?string
}
```

Notes that are decisions, not incidental:

- **`ToolCall.args` is a raw JSON string, not a decoded map.** Providers stream tool arguments as partial JSON fragments; keeping the raw text means the accumulate-then-decode boundary is in one place, and a malformed argument blob is a recoverable `JsonError` with a path, not a half-built value.
- **`Thinking.signature` is round-tripped verbatim.** Anthropic requires the signature back on the next turn for the block to remain valid; discarding it silently degrades multi-turn reasoning. Nothing in para/ai interprets it.
- **`Part` covers what all three providers can express**, and each codec is responsible for rejecting what its provider cannot — loudly, at `encode`, with a message naming the part and the provider. A codec that silently drops an image is a bug we can prevent by construction.

```noeta
pub struct ModelRequest {
    model: string
    messages: List<Message>
    tools: List<ToolSpec> = []
    output: ?OutputSpec = none        // structured response, §8
    max_tokens: ?int = none
    temperature: ?float = none
    stop: List<string> = []
    extra: Map<string, string> = {}   // provider-specific escape hatch, passed through verbatim
}

pub struct Usage { input_tokens: int  output_tokens: int  cached_input_tokens: int  reasoning_tokens: int }

pub enum StopReason { EndTurn; ToolUse; MaxTokens; StopSequence; Refusal; Other(raw: string) }

pub struct ModelReply { parts: List<Part>  usage: Usage  stop: StopReason  model: string }
```

`extra` exists because a neutral model that cannot express a provider's newest knob forces a fork. It is a `Map<string, string>` of raw JSON fragments merged into the request body by the codec, documented as unchecked.

---

## 5. The run loop

One `async fn`, and it is the only place with I/O:

```
loop:
  1. context strategy fits the conversation to the budget      → §10
  2. input guards run over the pending user message            → §9
  3. encode the request through the provider codec
  4. send it through the para/api chain (retry/mock/telemetry)
  5. stream frames → decoder → Deltas → Events on the channel   → §11
  6. accumulate Deltas into a ModelReply
  7. output guards run over the assistant message               → §9
  8. if stop == ToolUse:
        tool-call guards run over each requested call           → §9
        dispatch calls concurrently (bounded)                   → §6
        tool-result guards run over each result                 → §9
        append the results and continue the loop
     else:
        decode structured output if requested, repairing on failure  → §8
        finish
```

Two things about the shape:

- **Streaming is the primitive; non-streaming is a fold.** `agent.run(...)` is `agent.stream(...)` collected. There is one code path, so a bug cannot exist in only one of them.
- **Tool calls dispatch concurrently, bounded.** `std.task.map_bounded(calls, n, dispatch)` gives per-item order and a concurrency cap for free. The cap defaults to 4 and is configurable; unbounded parallel tool dispatch is a good way to get rate-limited by your own agent.

The public surface:

```noeta
pub class Agent {
    fn from(cfg: AgentConfig): Agent
    fn with(g: dyn Guard): Agent                                     // immutable, returns a new Agent
    fn tools(src: dyn ToolSource): Agent
    async fn stream(conv: Conversation, out: Sender<Event>): Result<Run, AiError>
    async fn run(conv: Conversation): Result<Run, AiError>           // collects stream
    fn run_sync(text: string): Result<string, AiError>               // the string-testable door
}

pub struct Run { messages: List<Message>  usage: Usage  turns: int  stop: StopReason }
```

`run_sync(text) -> Result<string, AiError>` is deliberate: para/aether's `app.handle(method, path, body)` proved that a plain string-in/string-out entry point is what makes a framework testable in a `@test` block, and this is the same idea.

---

## 6. Tools — the signature is the spec

Exactly para/cli's model, and it needs no new machinery:

```noeta
use para.ai.tools.{Tool, Arg}

#[Tool(about: "Current weather for a city")]
fn weather(
    #[Arg(help: "City name, e.g. 'Malmö'")] city: string,
    #[Arg(help: "metric or imperial")] units: string = "metric",
): Result<string, string> {
    return Ok("18°C, clear")
}
```

The pipeline:

1. `attributes_of::<Tool>()` finds every annotated function and its `target` name.
2. `params_of(target)` yields each parameter's name, declared `Type`, `optional` flag, and its own `#[Arg]` attributes.
3. `Type` → JSON Schema is a total function over the ADT: `Type.Int` → `{"type":"integer"}`, `Type.List(inner)` → `{"type":"array","items":…}`, `Type.Option(inner)` → not in `required`, `Type.Enum(name, _)` → an enum of the variant names (resolved from the program's enums), and so on. `optional: false` drives `required`.
4. A tool call arrives; its `args` JSON is decoded and each value coerced to the declared parameter type (para/cli's coercion table, plus struct-typed parameters via `json.decode_typed`).
5. `invoke(name, args)` dispatches. It returns `Result<dyn, dyn>` — every resolution failure is an `Err`, never an abort — so an arity or name mismatch becomes a `ToolResult(is_error: true)` fed back to the model rather than a crashed process.
6. A tool returning `Err(e)` likewise becomes `ToolResult(is_error: true, content: "${e}")`. **A failing tool is a turn, not an outage** — the model gets to see the error and try something else, which is the behavior that makes agents recover.

### Tools are a trust boundary, and we say so

`Tool` is declared with a role:

```noeta
@attribute(Function, Method)
@role(Semantic.TrustBoundary)
pub struct Tool { about: string = ""  name: string = "" }
```

That one line makes "which functions in this program can a language model reach?" a query — `roles_of::<Semantic>()` in-language, and the architectural graph that `noeta mcp` and the VS Code extension already serve. For a program where a model can call code, that is not a nicety; it is the review surface. No other language's agent SDK can answer it without a bespoke linter.

**The corollary: a library may not declare a `#[Tool]` at module level.** Reflection reaching the whole program is what makes step 1 work across the package boundary — the query runs in para/ai and finds tools declared in the application. It reaches the other way too. A `#[Tool]` in *library* code is discovered from every application that depends on that library, and `Local` offers it to that application's model, with nothing in the application mentioning it. That is a trust-boundary crossing performed by a dependency, which is exactly what the role exists to make visible, so this is a rule rather than a style preference:

- A library's own `#[Tool]` **fixtures** belong in a `@test` block, which is stripped before lowering on every build that is not that module's own `noeta test`. A parameterized fixture additionally needs `#[std.test.Skip]`, because every `fn` in a top-level `@test` block is a test root; skipping affects the *runner* only, leaving the function discoverable by `attributes_of` and dispatchable by `invoke`.
- A library that means to *ship* tools — a package of ready-made ones — hands them over through a `ToolSource` the application constructs, never through `#[Tool]` on module-level declarations that `Local` picks up whether or not the application asked for them.

`examples/tools` asserts the property from the consuming side: its toolbox and its trust-boundary index each contain exactly its own two tools, and nothing from para/ai.

### `ToolSource`

Local `#[Tool]` functions and MCP servers are the same thing to the agent:

```noeta
trait ToolSource {
    fn specs(): List<ToolSpec>
    fn call(name: string, args: string): Result<string, AiError>
}
```

`Local` (reflection over `#[Tool]`) and `McpClient` both implement it. An agent holds a list. Name collisions across sources are a **construction-time error naming both sources**, not a last-one-wins — a silently shadowed tool is the kind of bug that shows up as a wrong answer three weeks later.

---

## 7. MCP

`para.ai.mcp` is a client over two transports:

- **stdio** — `os.spawn(cmd, args)` gives a `Process` with `write`, `read_line`, `read_err_line`, `try_wait`, `kill`. JSON-RPC framing over that is ordinary Noeta. **This transport needs no native code at all.**
- **streamable HTTP** — POST for requests, the native `EventStream` for the server→client channel. This is the one MCP piece that rides the native half.

Surface:

```noeta
use para.ai.mcp.{McpClient, Stdio}

mem = McpClient.connect(Stdio.new("npx", ["-y", "@modelcontextprotocol/server-memory"]))?
agent = Agent.from(cfg).tools(mem)
```

`connect` performs `initialize`, negotiates capabilities, and lists tools. Beyond tools:

- **Resources** — `client.resources()` / `client.read(uri)`. Resources are *not* auto-injected into the context; that is the caller's decision, because auto-injection is how context windows quietly fill up.
- **Prompts** — `client.prompt(name, args)` returns `List<Message>`, so a server-supplied prompt is a normal conversation prefix.
- **Sampling** — a server may ask the client to call a model. Supported through an `McpHost` seam the agent provides; **off by default**, because it hands a subprocess your API key. Turning it on is `cfg.allow_sampling(model, budget)` and it is rate- and token-budgeted.
- **Approval** — every MCP tool call passes through the same tool-call guard stage as a local one (§9). The standard `Approval` guard supports `Auto`, `Deny`, `Allowlist(names)`, and `Ask(callback)`.

### Memory

There is no `para.ai.memory`. Memory is an MCP server, and the documented pattern is two lines:

```noeta
mem = McpClient.connect(Stdio.new("mcp-memory", ["--db", "./memory.db"]))?
agent = Agent.from(cfg).tools(mem).with(Recall.new(mem, top_k: 5))
```

`Recall` is an *input guard* (§9) with `Verdict.Rewrite`: before each user turn it calls the memory server's search tool and prepends the hits as a pinned context block. So recall is a guard, storage is a tool, and para/ai owns neither. The agent can also just be told to call the memory tools itself — that is the zero-configuration path and it works with no `Recall` at all.

---

## 8. Structured responses

### 8.1 Ask for a type, get a type

```noeta
@derive(Deserialize<Json>)
struct Extraction {
    company: string
    sentiment: string
    confidence: float

    impl Validate {
        fn validate(): Result<void, string> {
            if self.confidence < 0.0 || self.confidence > 1.0 {
                return Err("confidence out of range: ${self.confidence}")
            }
            return Ok()
        }
    }
}

e = agent.extract::<Extraction>(conv)?
```

`extract::<T>` sets the provider's structured-output mode (Anthropic: a forced single tool; OpenAI: `response_format: json_schema` with `strict`; Google: `responseSchema` + `responseMimeType`), then decodes the reply with `json.try_parse::<T>`.

### 8.2 The best output guardrail is already in the language

Because decode runs `Validate` **automatically, bottom-up, at the door**, a structured response is validated before para/ai ever sees it — and the failure is a path-carrying `JsonError` reading `items[2].confidence: confidence out of range: 1.4`.

That message is also an *excellent repair prompt*. So:

### 8.3 Repair, bounded

On a decode or validation failure, para/ai feeds `e.message()` back as a tool/user correction turn and retries, up to `repair: int = 1`. The default of 1 is chosen deliberately: one repair fixes the overwhelming majority of real failures, and an unbounded repair loop against a model that has misunderstood the schema is just a way to spend money. Every repair attempt is a span event, so it shows up in the trace instead of hiding in latency.

### 8.4 Refusals are not decode failures

A model that refuses returns `StopReason.Refusal`, which surfaces as `AiError.Refused(reason)` — never as a JSON error. Conflating the two makes "the model declined" look like "your schema is wrong", which sends people debugging the wrong thing.

### 8.5 The gap that was not there

**This section was wrong, and the error is worth keeping visible.** It claimed a schema for `T` could not be derived without an instance of `T`, called that the design's single real toolchain dependency, and used it to justify a `@schema` directive.

`field_specs_of::<T>()` — and its runtime-string twin `field_specs_of(name)` — already existed when this was written. It returns each declared field's name, declared type, and whether it is optional, from a *type*, with no instance anywhere. `construct(name, fields)` is its inverse. Both landed on `main` four days before this design; `para/cli` already ships nested-struct expansion on exactly that pair (`build_struct_arg`).

The mistake was reading `content/docs/` in the docs-site repo — a **synced mirror** — instead of `docs/` in the language repo. The mirror was stale and had no mention of the primitive. A generated copy is not a source of truth, and this design knew that about that directory and read it anyway.

**So structured output needs no new toolchain surface.** The schema walk is ordinary Noeta, recursive through nested structs, sharing one `Type` → JSON Schema function with §6's tool schemas:

```noeta
for spec in field_specs_of::<Extraction>() {
    // spec.name, spec.type (the full declared Type), spec.optional
}
```

`@schema` is not needed and phase 5 is not gated. U-1 (`DirectiveCtx.fields`) still landed and is still worth having — compile-time codegen from a declaration's shape is a genuinely different capability from runtime reflection, and it arrived with a shared derivation and an E0013 fix — but it was **not** the blocker this section made it.

What remains genuinely missing is smaller and is in §6: there is no runtime reflection over an **enum's variants** (no `variants_of` mirroring `field_specs_of`), and `params_of` reports a declared enum as `Type.Named`, never `Type.Enum`. So an enum-typed tool parameter or output field is refused with a message naming the missing primitive rather than half-derived. That is the real ask, and it is one primitive, not a directive.

---

## 9. Guardrails

One trait, four stages:

```noeta
pub enum Stage { Input; Output; ToolCall; ToolResult }

pub enum Verdict {
    Allow
    Deny(reason: string)
    Rewrite(parts: List<Part>)
}

trait Guard {
    fn stages(): List<Stage>
    fn check(stage: Stage, ctx: GuardCtx): Verdict
}
```

Guards run in registration order; the first non-`Allow` wins. `Rewrite` replaces the content and continues — which is what makes redaction, memory injection, and prompt hardening all the same mechanism.

`Deny` is handled by the run's policy, which is explicit and not a default anyone should have to guess at:

| `on_deny` | behavior |
| --- | --- |
| `Stop` (default) | the run ends with `AiError.Guard(stage, reason)` |
| `Feedback(max)` | the reason is fed back as a correction turn, up to `max` times |
| `Replace(parts)` | the denied content is swapped for a canned reply |

Ships with: `ToolAllowlist`, `Approval`, `MaxTurns`, `TokenBudget`, `Redact(regex, replacement)` (over `std.regex`), `Blocklist`, `SchemaGuard` (output must decode to `T`), `Recall` (§7), and `Judge(model, rubric)` — a guard that calls a cheap model, which is exactly the shape the trait was designed to allow rather than a privileged built-in.

Two properties worth naming:

- **A guard is an ordinary Noeta value.** None is privileged by the framework — the para/api middleware principle. `Judge` and `ToolAllowlist` are the same kind of thing.
- **Every non-`Allow` verdict is a span event and a metric**, so "the guardrails are configured" and "the guardrails are firing" are distinguishable without reading logs. This is the same distinction `Cache.hits()` draws in para/api.

---

## 10. Context strategies

```noeta
trait ContextStrategy {
    fn fit(msgs: List<Message>, budget: Budget): Result<List<Message>, AiError>
}
```

| Strategy | Behavior |
| --- | --- |
| `Full` | pass through; `Err(ContextOverflow)` if over budget |
| `Window(turns)` | keep the last N turns |
| `TokenWindow(max)` | drop from the front until under `max` |
| `Summarize(model, keep_recent, trigger)` | when over `trigger`, summarize the dropped prefix with `model` and keep it as one pinned system part |
| `Pinned(inner)` | a combinator: system messages and explicitly pinned parts survive whatever `inner` does |

**The default is `Full`, and `Full` fails loudly.** This follows para/api's refusal to ship a default pagination strategy, for the same reason: a paginator that guesses reports page one as the whole result set, and a context strategy that guesses silently changes the model's answer. Overflow with no strategy is an error naming the budget, the need, and the three strategies that fix it — not a truncation nobody noticed.

Two invariants every built-in strategy upholds, and which the trait's documentation states as the contract for user strategies:

1. **A `ToolCall` and its `ToolResult` are never separated.** Dropping a boundary between them produces a conversation every provider rejects. This is the single most common bug in hand-rolled context trimming.
2. **The system message is never dropped** unless the strategy is explicitly constructed to allow it.

**Decided (O-5): `estimate_tokens` returns `?int`, and `none` is a real answer.** A provider with no local tokenizer says so rather than returning a number that will be trusted absolutely and is wrong by a few percent — a failure that surfaces as a provider-side context error in the middle of a run, which is the worst possible place to learn about it.

```noeta
fn estimate_tokens(msgs: List<Message>): ?int

budget = match provider.estimate_tokens(msgs) {
    some(n) => Budget.exact(n),
    none    => Budget.headroom(0.15),      // the caller must name its margin
}
```

The `?int` is doing real work: it makes the uncertainty visible in the type, and it makes `Budget.headroom` a decision the caller writes down instead of a constant we picked for them. Exactness would need a provider round trip (Anthropic has a count-tokens endpoint; the others do not), which is a network call per turn — that can be added later as an opt-in without changing this signature.

---

## 11. Streaming and AG-UI

The neutral event enum is shaped so that AG-UI encoding is a pure mapping, not a translation layer:

```noeta
pub enum Event {
    RunStarted(run_id: string, thread_id: string)
    TextStart(id: string)
    TextDelta(id: string, delta: string)
    TextEnd(id: string)
    ThinkingDelta(id: string, delta: string)
    ToolCallStart(id: string, name: string)
    ToolCallArgsDelta(id: string, delta: string)
    ToolCallEnd(id: string)
    ToolCallResult(id: string, content: string, is_error: bool)
    StateSnapshot(json: string)
    StateDelta(patch: string)          // JSON Patch
    StepStarted(name: string)
    StepFinished(name: string)
    RunFinished(run_id: string, usage: Usage)
    RunError(message: string, code: string)
    Custom(name: string, json: string)
}
```

Every variant is a value type, so `Sender<Event>` works across tasks *and* isolates and the whole thing composes with parallel serving.

Consumers:

```noeta
// AG-UI over SSE — one line inside an aether controller
#[Post("/agent")]
fn chat(req: Request): Response {
    return agui.respond(agent, req)
}
```

`agui.respond` is written over `std.http.server.sse` (§3, O-3). It decodes AG-UI's `RunAgentInput` (thread id, messages, state, forwarded props), opens the native SSE response, spawns the run, and drains its channel encoding each `Event` as an AG-UI frame. The two AG-UI facts that are easy to get wrong and will be handled explicitly: a **`RunError` must still be an SSE frame**, not a dropped connection, and every stream ends with exactly one terminal `RunFinished` or `RunError`.

A CLI renderer and a test collector are the other two consumers, and they are both just `while rx.recv().await` loops. `para.ai.mock` ships the collector, so asserting on the exact event sequence of a run is a `@test` block with no server and no socket — the same testability bar `keyed_op_stream` sets in para/html.


### 11.1 What phase 3 built, and where it diverges

Built as specified: `StreamDecoder` with Anthropic's indexed protocol behind it, the `Event` enum exactly as §11 lists it, `Sender<Event>`, the run loop emitting into it, and a scripted `FrameStream` so a streaming test is as hermetic as a buffered one (§17's O-4 answer). The Anthropic decoder is proved against three verbatim published SSE transcripts replayed frame by frame — text, a tool call whose arguments arrive as six partial-JSON fragments, and extended thinking with its signature delta.

Five divergences, each with its reason:

- **`Event`, `EventSink`, `Frames`, and `Streamer` live in `para.ai`, not `para.ai.agui`.** §3's table puts `Event` with the AG-UI encoder. But the neutral event type is the *run loop's output*; AG-UI is one consumer of it, alongside a CLI renderer and the test collector. Putting it with its producer means phase 7 imports it rather than owning it, and nothing has to move when a second encoder appears.
- **`Provider` gained `decode_deltas`, and `decode_reply` became a fold over it.** §2.1's sketch has the buffered door return a `ModelReply`. That would have given the two transports separate accumulators — the exact duplication §5 exists to prevent — so the buffered door now speaks the same delta vocabulary the streaming one does, and everything below them is one implementation.
- **`Delta` gained `ModelDelta(model)`.** Anthropic names the served model in `message_start`, so the streaming path has to carry it somewhere. In the vocabulary, a delta list is a complete description of a reply and `StreamDecoder` stays the two methods §2.1 specifies; on the decoder, it would have been a third method and a side channel the buffered path did not need.
- **Streaming is a flag, not the default.** §5 says "streaming is the primitive; non-streaming is a fold over it", and that holds for everything downstream of the deltas — one loop, one emitter, one accumulator, one tool loop. It cannot hold for the *transport*, because O-4 established that a `FrameStream` cannot flow through the para/api onion. `AgentConfig.stream` therefore defaults to `false`: the buffered path is the one `Retry`, `Cache`, `Record`, `Mock`, and `Logging` cover, and defaulting to streaming would take those away from every caller who never asked for it. `agent.stream(conv, out)` streams regardless.
- **A streamed vendor error has no status.** `std.http`'s `FrameStream` exposes `recv` and `close` and nothing else, so a 429 streams its JSON error body and frames into nothing rather than becoming `AiError.Provider(429, "rate_limit_error", …)`. Each codec's `finish()` refuses the empty stream and names the reason it cannot say more. Closing this needs `FrameStream.status()` in std — the real host has the value at `send_head` and discards it — which is a `lang`-side ABI addition rather than a package change.

`run_sync` stays synchronous over the now-async loop by driving it with `std.task.map_bounded` on a one-element list. That the only available spelling for "run this future to completion here" is a concurrency combinator is a std gap; the alternative was a second, synchronous copy of the run loop, which is precisely where a divergence between the two paths would have lived.

---

## 12. Telemetry

Noeta already has all three OTel signals with the standard env-var switch, auto-correlated logs, and automatic context propagation across `await`s, channels, and isolates. para/ai adds **no telemetry machinery** — it emits onto `std.tracing` and `std.metrics`, which means: nothing when no endpoint is set, everything when one is, and no configuration API of our own.

Following the OTel **GenAI semantic conventions**:

| Span | Attributes |
| --- | --- |
| `chat {model}` | `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.request.max_tokens`, `gen_ai.response.finish_reasons`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens` |
| `execute_tool {name}` | `gen_ai.tool.name`, `gen_ai.tool.call.id`, `gen_ai.tool.type` (`function` / `mcp`) |
| `invoke_agent {agent}` | the run root: turn count, aggregate usage |

| Metric | Kind |
| --- | --- |
| `gen_ai.client.token.usage` | histogram, keyed by provider/model/token type |
| `gen_ai.client.operation.duration` | histogram, keyed by provider/model/error type |
| `para.ai.guard.denials` | counter, keyed by stage and guard name |
| `para.ai.tool.calls` | counter, keyed by tool name and outcome |

Three commitments:

- **Message content is off by default.** Prompts and completions in spans are a privacy and compliance hazard. Opt in with `OTEL_GENAI_CAPTURE_MESSAGES=true`, matching the OTel convention rather than inventing a knob.
- **No high-cardinality metric attributes.** No user ids, no thread ids, no prompt text — the docs already warn that every distinct attribute set is a stored series, and an agent is exactly the workload that would blow it up.
- **The semconv version is pinned and stated in the README.** GenAI conventions are still moving; a package that claims "OTel support" without naming a version is claiming nothing.

Because tool dispatch is instrumented in the run loop and not at the tool, a `#[Tool]` function has zero telemetry code in it and still shows up as a child span of the model call that requested it. That is the "out of the box" the request asked for.

---

## 13. Errors

```noeta
@derive(Error, Display)
pub enum AiError {
    Transport(inner: HttpError)
    Provider(status: int, code: string, message: string)
    Decode(path: string, message: string)
    Encode(provider: string, message: string)   // the codec refused to express a part
    Refused(reason: string)
    Guard(stage: Stage, guard: string, reason: string)
    Tool(name: string, message: string)
    ContextOverflow(needed: int, budget: int)
    Mcp(server: string, code: int, message: string)
    Cancelled
}
```

`impl From<HttpError>` on an enum turned out not to work at all: the reserved built-in `Enum.from(string)` shadowed it in the checker, the compiler and the interpreter alike, so `?` resolved the conversion while an explicit `AiError.from(e)` was rejected as "not assignable to `string`" and the program aborted at runtime. Fixed upstream while building phase 1 — the builtin now yields to a declared method of that name. Worth recording because §13's error type is the reason it was found.

A language constraint shapes this: **a type carries at most one `From` impl** (a second is a coherence conflict, E0027). So `AiError` declares `impl From<HttpError>` — the conversion that appears at the most `?` sites — and `JsonError` is mapped explicitly at its handful of decode points into `Decode(path, message)`, preserving the path. Worth writing down so the first contributor who reaches for a second `From` knows it was a decision, not an omission.

The `para/api` line holds here too: `Err` means the call failed, while an HTTP error *status* from a provider is an answer — decoded into `Provider(status, code, message)` with the provider's own typed error body, so `code == "rate_limit_error"` is matchable and nobody has to regex a message string.

---

## 14. `@prompt` — an expression tier, and why it earns its place

Noeta's expression tiers turn a `@name { … }` block into a typed value built from **statics and hole thunks**, with `${…}` holes parsed by the full grammar, closed over the enclosing scope, and type-checked:

```noeta
use para.ai.prompt.render

sys = @prompt {
    You are a support agent for ${company.name}.
    The customer's plan is ${account.plan}, opened ${account.opened_at}.
}
```

This is not sugar over string interpolation. Three things fall out:

1. **A malformed prompt variable is a compile error pointing inside the prompt**, not a `${undefined}` that ships.
2. **Holes are thunks**, so an expensive interpolation (a database read, a memory recall) evaluates only if that fragment is used.
3. **Statics always number holes + 1** — which means the prompt arrives *pre-split into its stable and volatile parts*. That is precisely the input a prompt cache wants. para/ai can place the cache breakpoint at the last static boundary before the first hole automatically: Anthropic `cache_control`, OpenAI and Google implicit prefix caching. **You get provider prompt caching correct by default because the language handed us the split.**

No other agent framework can do (3), because in every other language a prompt is an opaque string by the time the SDK sees it. This is the feature that makes para/ai *a Noeta package* rather than a port.

`text: "markdown"` on the tier declaration gives editors highlighting and the LSP a hover, for free.

### 14.1 What phase 8 built, and where it diverges

Built as specified: `@tier(prompt, text: "markdown", expr: Prompt)` in `para.ai.prompt`, a handler that keeps the pieces, the split placed as a cache breakpoint by the run loop, and `cache_control` in the Anthropic codec. Measured rather than assumed at every step — the exact statics/holes decomposition of a known block, a recording thunk that proves reading the cache prefix evaluates nothing, and the exact encoded request body with the marker on the stable block and nowhere else.

Five divergences, each with its reason:

- **Two types, not one: `Prompt` (lazy) and `Resolved` (evaluated).** §14 speaks of "a `Prompt`". Laziness and value semantics cannot live in one struct: a field of function type derives neither `Equatable` nor `Display` and is not `Send`, so a `Prompt` that kept its thunks could not be stored in `AgentConfig` (which is the `Send` half of the API, by §5's design) and a `Prompt` that evaluated at construction would throw away point 2. So `Prompt` holds statics + thunks, `resolve()` calls each hole exactly once, and `Resolved` holds statics + evaluated holes — still split, still carrying the boundary, and an ordinary value.
- **`AgentConfig.system` is a `?Resolved`, not a `?string`.** Flattening the system prompt to text at configuration time would destroy the boundary before any codec could use it, which is the one thing this section says must not happen. `with_system("…")` is unchanged for callers — a plain string is a prompt with no holes — and `system_text()` is there for a caller who only wants to read it.
- **`with_system_prompt` is a second method rather than an overload of `with_system`.** A `trait IntoPrompt` with an `impl … for string` is **E0013** (`cannot implement a trait for `string`: it is not a record, class, or enum declared in this module`), so no bound can span the two types. Two named doors that agree on one internal representation beat a `dyn` parameter the checker cannot see through.
- **The breakpoint is carried by `Message.cache_breakpoint`, and the split becomes two turns.** §14 does not say how the boundary reaches a codec. A vendor's marker attaches to a *content block* and the cached prefix ends where that block ends, so the stable text has to be a block of its own; a defaulted `bool` on `Message` is the smallest neutral carrier that survives a codec's alternation merge, needs no change to `Provider` or `ModelRequest` (phase 4's floor), and lets a caller mark a long stable turn of their own with `Message.cached()`.
- **Marking is a default with a switch (`AgentConfig.cache`, true).** "Correct by default" is the section's claim, and a system prompt is re-sent on every turn of a run, so a tool loop repays the cache write on its second call. The one shape where a marker costs is a single-call workload with a large system prompt that never repeats inside the TTL, and `.uncached()` is that caller's answer — it removes the marker and changes no other byte, so an implicitly-caching vendor is unaffected.

Two things §14 does not claim, stated so nobody assumes them: the run loop marks **only** what the language proved stable, so a conversation's earlier turns are left unmarked even though they do repeat within one run (a breakpoint spent on a guess is one of the four Anthropic allows); and the block's body is **verbatim**, including the whitespace the braces introduce, because the bytes a cache is keyed on are not something a handler should quietly rewrite. `Prompt.trimmed()` removes the outer edges on request; a *dedent* of interior indentation is the obvious next combinator and is deliberately not guessed at here.

---

## 15. Testing

The suite's bar is hermetic tests with no socket, and para/ai clears it three ways:

```noeta
@test {
    fn calls_the_weather_tool(): void {
        m = Mock.new()
            .reply_tool("weather", {"city": "Malmö"})
            .reply_text("It is 18°C and clear in Malmö.")
        a = Agent.from(cfg.provider(m)).tools(Local.new())
        assert(a.run_sync("What's the weather in Malmö?")? .contains("18°C"))
        assert(m.calls().len() == 2)
    }
}
```

- **`Mock` provider** — a scripted `Provider`, including multi-turn tool-call scripts, with `calls()` for asserting on what was sent.
- **`para/api`'s `Record` → `to_mock()`** — record one real session against a live provider, replay it forever.
- **Event-sequence assertions** — collect a run's `Sender<Event>` into a list and assert the exact stream, which is how streaming bugs get caught before a user sees a half-rendered token.

Determinism comes free from the sandbox executor's logical clock, so a test can sleep past a retry backoff without waiting.

Above that sits **one real integration test, against a local Ollama**, run in CI with no secret. Mocks prove the run loop does what we told it to; only a live model proves the request we encode is one a server accepts. Every cloud provider puts that check behind a paid key and therefore behind "someone should set that up", so Ollama is the difference between having end-to-end coverage and intending to.

---

## 16. Repo layout and manifest

```
para-ai/
  noeta.toml               name = "para/ai"   (no `native` key — pure Noeta)
  ai.noe                   Agent, AgentConfig, Conversation, Run, Message, Part, AiError
  provider.noe             Provider, StreamDecoder, ModelRequest/Reply, Delta, Usage
  tools.noe                Tool, Arg, Toolbox, ToolSource, schema, dispatch
  mcp.noe                  McpClient, Stdio, Http, approval
  guard.noe                Guard, Verdict, Stage, the standard guards
  context.noe              ContextStrategy and the built-ins
  agui.noe                 Event, AG-UI encoding, respond()
  prompt.noe               the @prompt tier handler
  mock.noe                 Mock provider, Script, event collector
  providers/anthropic.noe  (a dependency package is walked recursively, so subdirs are fine)
  providers/openai.noe     OpenAiCompat + OpenAi + OpenRouter + Ollama(/v1)
  providers/ollama.noe     the native /api/chat codec (NDJSON)
  providers/google.noe
  examples/
    chat-cli/              streaming to a terminal, one tool
    agui-server/           aether + AG-UI SSE, hermetic @test over the event stream
    mcp-memory/            memory as an MCP server, Recall guard
    structured/            extract::<T>, Validate, bounded repair
    local-ollama/          keyless end-to-end run against a local Ollama; what CI actually executes
  AGENTS.md README.md LICENSE-APACHE LICENSE-MIT .github/workflows/
```

```toml
[dependencies]
para = [
    { version = "^0.1", package = "para/ai" },
    { version = "^0.1", package = "para/api" },   # the transport chain para/ai composes over
]

[trust]
native = ["para/api"]   # para/api's own native half; para/ai contributes none
```

API keys come from `std.env`; para/ai never reads a config file and never writes one.

**Decided (O-6): para/ai composes over para/api.** Retry-with-`Retry-After`, `Mock`, `Record`, `Cache`, and `Logging` are already written, already tested, and already the idiom this suite documents; re-implementing three of them inside para/ai to save a manifest line would be the wrong trade. If para/api's native grant turns out to propagate, consumers write two `[trust]` entries and the README says why — an honest extra line beats a hidden duplicate implementation.

---

## 17. Questions

### Settled

| | Decision | Where |
| --- | --- | --- |
| O-3 | Server-side SSE goes in `std.http.server.sse`, next to `websocket`. | §3, §11, U-3 |
| O-5 | `estimate_tokens(): ?int` — `none` is a real answer and forces an explicit `Budget.headroom`. | §10 |
| O-6 | para/ai composes over para/api; a second `[trust]` line beats a duplicated retry/mock/record. | §16 |
| O-7 | `Provider` is a bound only. Runtime selection is the caller's `match`, and the README leads with it. | §2.3 |

### Landed upstream

| | what | state |
| --- | --- | --- |
| U-1 | `DirectiveCtx.fields` — an expand hook sees the decorated declaration's shape | **merged** (`21ca0362`), unblocks `@schema` and phase 5 |
| U-2 | `async` through `dyn` typed correctly, plus the impl↔declaration parity rule | **merged** (`95ad4ab8`) |
| U-3 | streaming HTTP bodies + `server.sse` | **merged** (`f90f9053`) — `client.stream(req, framing)`, `Framing { Sse; Ndjson; Lines }`, `FrameStream`, `server.sse`; unblocks phases 3 and 7 |
| U-4 | a cross-module type cannot be a positional enum payload | **merged** (`79de7d35`) — fixed at the representation: a payload's type lives in the type slot, so `Leaf(App.Models.User)`, `Many(List<int>)`, `Maybe(?int)` and `Pair(string, int)` all parse now |
| — | method-receiver parity: a self-less trait method answers to both call forms | **merged** (`79de7d35`) |
| — | three checker fixes found building phase 1 (see §2.3, §13) | **merged** |

### O-1, O-2, O-4 — answered by inspection, and all three become build items

All three were checked against the toolchain at `../../lang`, not guessed. None is supported today; all three are to be built (§17.1). The results also changed two things about the package, both for the better.

**O-1 — `DirectiveCtx` does not expose the decorated declaration's fields.** It carries `args`, `named`, `target` (the name only), `site`, and `source_dir`, and its doc comment says the narrowness is deliberate: a hook sees "what the directive was written with and what it was written on — not the surrounding program — so its output depends only on inputs the compiler can key a memoized result on." A declaration's *own fields* are squarely "what it was written on", so adding them is inside that rationale rather than a departure from it. → **U-1.**

**O-2 — `async` trait methods work through a bound, and are unsound through `dyn`.** Verified by running both:

```noeta
trait Fetcher { async fn fetch(url: string): string }

async fn via_bound<F: Fetcher>(f: F): string {
    return f.fetch("x").await          // ✅ checks, runs, prints the body
}

fn via_dyn(f: dyn Fetcher): string {
    return f.fetch("y")                // ✅ checks clean as `string`…
}
echo via_dyn(Http {})                  // …and prints `<future>`
```

The bound path is right. The `dyn` path drops the `async_return` wrap during trait-object method resolution, so the checker promises `string`, hands back a `Future`, and the program compiles clean. That is a genuine soundness hole independent of this package. → **U-2.**

It also independently vindicates O-7: the spelling para/ai standardized on is the one that already works correctly.

**O-4 — asked too early (`std.http` had no streaming at all), and now answered by U-3: a streaming response cannot flow through the para/api onion.**

`Middleware.handle` is `(Request, Next) -> Result<Response, HttpError>`, and `Response` is a buffered value — cloneable, content-equal, storable in a map. Four of the six standard layers structurally require that: `Retry` calls `next` repeatedly and would discard a body mid-flight, `Cache` and `Record` store and re-serve the same `Response`, and `Mock` needs a whole buffered one to answer with. Only `Header` and `Logging` are streaming-safe. Pagination is worse still — it reads the body twice, once as the page and once for the strategy.

So `client.stream` returns `Result<FrameStream, HttpError>`, a type the onion cannot accept, which makes the incompatibility **a compile error rather than a runtime surprise**. Three consequences for phase 3:

- **The streaming path owns its retry.** It cannot inherit para/api's, so the run loop applies backoff for streamed calls itself, and the README states which layers cover which path instead of implying blanket coverage.
- **`Mock` cannot double as the streaming transport** the way it does for phase 1. Phase 3 needs a scripted `FrameStream` — a `Frame` list replayed through the real `StreamDecoder` — so streaming tests stay as hermetic as the buffered ones.
- **A layered streaming onion, if ever wanted, is a parallel `StreamMiddleware`** where the header-only layers work and the buffering ones structurally cannot be written. That is para's call; nothing in std presumes it.

### 17.1 Upstream work items

Three slices, in two other repos. Ordered by what unblocks the most.

**U-3 — streaming HTTP bodies (`lang`).** The largest, and the only one on the critical path for phase 3.

- `std.http.client`: `stream(req: Request, framing: Framing): Result<FrameStream, HttpError>`, with `FrameStream` an `ExtType` whose `recv(): Future<?Frame>` and `close()` mirror `std.http.Socket` exactly — the precedent is already in the registry.
- `Framing` is an `ExtEnum`: `Sse`, `Ndjson`, `Lines`. One enum covers OpenAI-compatible SSE, Ollama's native NDJSON, and everything else.
- `std.http.server.sse(fn(SseSink) -> dyn): Response`, the twin of `websocket` (O-3).
- Then answer O-4: whether a `FrameStream` response can flow through `para/api`'s `send`, or whether the onion needs a streaming-aware terminal. Decide it *as part of* this slice — retrofitting middleware around a streaming body afterwards is the expensive order.

**The consequence is worth stating loudly: with U-3 in `std.http`, para/ai ships no native crate at all.** It becomes pure Noeta, like para/cli, para/aether, and para/html — no `crates/`, no `native/`, no `[trust] native = ["para/ai"]` for consumers. That is a materially better package, and it is the right place for the code besides: a progress endpoint, a log tail, and a build-status stream all want incremental HTTP bodies, and none of them should depend on an AI package to get one.

**U-1 — `DirectiveCtx.fields` (`lang`).** Small, and precedented by code that already exists.

```rust
pub struct DirectiveCtx {
    // … args, named, target, site, source_dir …
    /// The decorated declaration's fields as (name, declared type spelling) pairs, in
    /// declaration order. Empty for Function/Method sites.
    pub fields: Vec<(String, String)>,
}
```

The compiler already computes exactly this shape and hands it to a native hook at check time: `ExtDerive::validate` is `fn(&str, &[(String, String)]) -> Option<String>`, documented as "the deriving type's name and its `(field name, field type spelling)` pairs". U-1 is that same data, delivered to the other extension hook. It joins the memoization key like any other input.

> **Corrected in hindsight:** this said U-1 "unlocks `@schema` and therefore phase 5". It does not — `field_specs_of` already covered that and phase 5 was never gated (§8.5). U-1 remains worth having on its own terms: compile-time generation from a declaration's shape is a different capability from runtime reflection, and it landed with a shared derivation both extension seams now read plus a fix for unvalidated positional enum-payload types. It just was not a prerequisite for anything here.

A runtime `fields_of_type(name)` was the alternative ask; U-1 is strictly better for this use — compile-time, zero runtime cost, and errors land at the declaration. If a runtime type-level reflection surface is wanted for its own sake, that is a separate conversation, not a para/ai dependency.

**U-2 — `async` through `dyn Trait` (`lang`).** para/ai does not need it — the package is bound-only — but a declared `string` that holds a `Future` is a hole that should not stay open. The fix is to apply the same `async_return` wrap the bound path uses when resolving a method through a trait-object receiver (`crates/noeta-check/src/expr/member.rs` is where the bound path reads `m.sig.is_async`). A regression test asserting `via_dyn` either types as `Future<string>` or is rejected belongs with it.

### 17.2 What core still owes phases 4–8

Measured against `lang` `ea9998c1a` (2026-07-28), by probe rather than by reading. Ordered by how much is blocked.

**U-5 — a standalone `impl T for X` is invisible to `dyn T` coercion across a module boundary.** The one *bug* left, and it touches every remaining phase.

```noeta
// pkg.lib
pub trait Codec { fn decoder(): dyn Decoder }
pub class MyDecoder { fn new(): MyDecoder { … } }
impl Decoder for MyDecoder { … }          // standalone
```

From another module: `expected dyn Decoder, found MyDecoder`. Writing the impl **inline in the class body** works. So the whole package is currently constrained to the inline spelling — `Provider.decoder(): dyn StreamDecoder`, `dyn Guard`, `dyn ToolSource`, `dyn ContextStrategy` and the MCP client are all this shape, which is phases 4, 5, 6 and 7. It is worse than a style constraint because the failure appears **only from a consuming package**: the library's own suite is green while every consumer breaks.

**U-6 — no runtime reflection over an enum's variants.** `variants_of` does not exist, and the consequence is sharper than a missing feature: an enum field reflects as `Type.Named("Sentiment", [])` and `field_specs_of("Sentiment")` returns **0 fields** — *indistinguishable from an empty struct*. A schema generator that recursed naively would emit `{"type":"object","properties":{}}` for an enum and be silently wrong, which is why §6 refuses an enum-typed parameter rather than half-deriving one. Blocks enum tool parameters (phase 2, refused today) and enum fields in structured output (phase 5). Nested **structs** are fine — recursion through `field_specs_of(name)` works to any depth.

**U-7 — `json.try_parse(text): Result<dyn, JsonError>`, a recoverable *dynamic* parse.** Only the typed turbofish `try_parse::<T>` exists, and it cannot build a `Map<string, dyn>`; `json.parse` aborts. Every codec decodes a body that came off a wire, so `provider.parse_object` does it in two steps behind a field-less witness struct. Phase 4 adds three more codecs on that workaround, phase 6 needs it for every JSON-RPC reply, phase 7 for AG-UI's `RunAgentInput`.

**U-8 — `std.base64`, and a per-byte read on `bytes`.** `provider.base64` currently encodes via `bytes.to_hex()` string arithmetic — correct against the RFC vectors, O(n) in the wrong way. Every codec inlines images and files (phase 4), and MCP resource contents are base64 (phase 6). The **decoder** is not merely slow but impossible: `b[0]` is `cannot index a value of type bytes`, so a `bytes`-typed tool parameter is refused outright.

**U-9 — a named-argument form for `invoke`.** Phase 2 called this its most valuable follow-up. `invoke` takes a positional `List<dyn>` only, so a tool call that omits a defaulted parameter *and* supplies a later one is inexpressible and is refused by name. `construct(name, fields)` already has the named-map form, so this is parity rather than new ground.

**Minor.** `ParamInfo`/`FieldSpec` cannot be written as struct literals — their `type` field collides with the keyword in literal position (reading `p.type` is fine), so a test cannot synthesize one and must reflect a real declaration.

**Confirmed *not* needed.** Phase 8's `@prompt` works today: a pure-Noeta `@tier(prompt, text: "markdown", expr: string)` declaration runs, with statics and hole thunks as documented — which is the whole prompt-caching story. Phase 6's stdio transport works today: `os.spawn` + `write`/`read_line` round-trips JSON-RPC with no core change. Phase 7's SSE responder landed with U-3.

## 18. Build order

Each phase is independently useful and independently shippable.

0. **The upstream slices (§17.1).** U-3 in `lang` gates phase 3 and phase 7 and removes para/ai's native crate entirely; U-1 gates phase 5; U-2 is independent and can land whenever. Phases 1, 2, and 4 need none of them, so package work and toolchain work run in parallel from day one.
1. **Core + Anthropic + Mock, non-streaming.** Data model, `Provider` codec, run loop over `para/api`, `AiError`, `run_sync`, telemetry spans. Proves the codec seam with one provider.
2. **Tools.** `#[Tool]`/`#[Arg]`, `params_of` → schema, coercion, `invoke` dispatch, the trust-boundary role, bounded concurrent dispatch.
3. **Streaming.** ~~The native frame reader (SSE + NDJSON)~~ (it went to `std.http` — U-3), `StreamDecoder`, the `Event` channel. Non-streaming becomes a fold over it. **Built**, with the divergences in §11.1.
4. **`OpenAiCompat` + Google, then OpenRouter and Ollama on top.** Should be pure codec work by now; if it is not, the seam in phase 1 was drawn wrong and this is where we find out. OpenRouter and Ollama arriving as *configurations* rather than files is the pass condition for phase 1's design — and Ollama unlocks keyless integration tests in CI for everything after this point. **Built, and the pass condition held**; the divergences are in §2.1.1.
5. **Structured responses + guardrails.** `extract::<T>`, `Validate` at the door, bounded repair, the `Guard` trait and standard guards.
6. **MCP.** stdio first (no native code), then streamable HTTP. Memory example lands here.
7. **AG-UI.** The SSE responder, the aether integration, the event-sequence test harness.
8. **`@prompt` tier + cache breakpoints.** Last, because it is the one piece nothing else depends on — and the one most worth getting right rather than early. **Built**, with the divergences in §14.1.
