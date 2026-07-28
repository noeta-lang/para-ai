# para/ai

An agent harness for Noeta: a **provider codec seam**, one run loop over `para/api`, and OpenTelemetry GenAI spans and metrics you cannot forget to wire up.

The split that decides everything else: **a provider is a codec, not a client.** The thing that varies between model vendors is the wire format; auth headers, retries, timeouts, mocking, recording, and tracing are identical across all of them. So a `Provider` turns a neutral `ModelRequest` into a request description and a response body back into a neutral `ModelReply` — and never performs I/O. The transport is written once, over a `para.api.Api`, which means a 429 backoff is not para/ai code.

> **Status: phase 2.** Core data model, the `Provider` seam, the Anthropic codec, the `Mock` provider, the run loop, errors, telemetry — and **tool calling**: `#[Tool]`/`#[Arg]`, `Type` → JSON Schema, argument coercion, `invoke` dispatch, the trust-boundary role, and bounded concurrent dispatch inside a multi-turn loop. Streaming, MCP, guardrails, context strategies, structured output, AG-UI, and the OpenAI/Google/OpenRouter/Ollama codecs are later phases; [DESIGN.md](DESIGN.md) is the whole plan and §18 is the order. What is *not* here is not stubbed — it is absent, and the seams it will attach to are marked in the source.

## What it provides

| module | contents |
| --- | --- |
| `para.ai` | `Agent`, `AgentConfig`, `Conversation`, `Run`, `Message`, `Part`, `Role`, `AiError` — the data model, the run loop, and the errors |
| `para.ai.provider` | `Provider`, `ModelRequest`, `ModelReply`, `Delta`, `Usage`, `StopReason`, `Wire`, `Framing` — the codec seam and the delta accumulator |
| `para.ai.tools` | `Tool`, `Arg`, `ToolSpec`, `ToolSource`, `Local`, `Toolbox`, `dispatch` — the signature-is-the-spec pipeline |
| `para.ai.providers.anthropic` | `Anthropic` — the Anthropic Messages API codec |
| `para.ai.mock` | `Mock`, `Scripted`, `ScriptedCall` — the hermetic test double, codec *and* transport |

## Installation

```toml
[dependencies]
para = [
    { version = "^0.1", package = "para/ai" },
    { version = "^0.1", package = "para/api" },
]

[trust]
native = ["para/api"]
```

The package is keyed `para`, so its modules address as `para.ai.*`. **para/ai itself is pure Noeta and ships no native code** — the `[trust]` line is `para/api`'s, whose native half is the `@openapi` directive and the `para.url` percent-encoder. A native grant is per package and is never self-authorized, not even by the dependency that pulls it in, so a consumer names it even though it never writes `use para.api`. An honest extra line beats a hidden duplicate implementation of retry, mocking, and recording.

## Hello, model

```noeta
use para.ai.{Agent, AgentConfig}
use para.ai.providers.anthropic.Anthropic

cfg = AgentConfig.new("claude-opus-5")
    .with_system("You are terse. Answer in one short sentence.")
    .with_max_tokens(256)

agent = Agent.from(cfg, Anthropic.from_env() ?? panic("set ANTHROPIC_API_KEY"))
echo agent.run_sync("Say hello in Swedish.")?
```

`Agent.from` builds the default transport: a plain client wrapped in `para/api`'s `Retry`, which honors a vendor's `Retry-After` and backs off on 429/502/503/504. `Agent.over(cfg, provider, api)` takes a chain you composed yourself.

API keys come from `std.env`. para/ai never reads a config file and never writes one.

## `Provider` is a bound, never a trait object

`Agent<P: Provider>` pins the codec in the type. That buys three things over `dyn Provider`: the codec stays a value type and therefore `Send`, dispatch is static, and the bound types the body — a wrong argument or return against a `Provider` method is a check-time error at the definition, before any call site exists. It is also the spelling that works today: `async` trait methods are correct under a bound and unsound through `dyn`.

The cost is real and accepted: `Agent<Anthropic>` and `Agent<Mock>` are different types, so no single binding can hold either. **Runtime provider selection is therefore the caller's `match`,** pushed to the outermost point where the arms still agree:

```noeta
// The arms diverge at construction and re-converge at the result type,
// because run/run_sync return provider-independent values.
answer = match env.get("AI_PROVIDER") ?? "anthropic" {
    "mock" => Mock.new().reply_text("…").agent(cfg).run_sync(text),
    _      => Agent.from(cfg, Anthropic.from_env() ?? Anthropic.new("")).run_sync(text),
}
```

That is the pattern, not a workaround — one line per provider, not a duplicated program. If a use case ever appears where the arms cannot re-converge, adding a `DynProvider` wrapper later is additive and breaks nothing.

## The data model

Every type that crosses a run boundary is a value `struct` or `enum`, never a `class`. That is not incidental: value types are `Send`, reference types are not, and a run's messages have to be able to cross a channel and an isolate boundary. `bytes` is `Send`, so inline images are fine.

```noeta
pub enum Role { System; User; Assistant; Tool }

pub enum Part {
    Text(text: string)
    Image(mime: string, data: bytes)
    File(mime: string, name: string, data: bytes)
    ToolCall(id: string, name: string, args: string)     // args: raw JSON, decoded at dispatch
    ToolResult(id: string, content: string, is_error: bool)
    Thinking(text: string, signature: string)            // opaque; round-tripped verbatim
}

pub struct Message { role: Role  parts: List<Part>  name: ?string }
```

Two of those are decisions rather than shapes:

- **`ToolCall.args` is a raw JSON string, not a decoded map.** Vendors stream tool arguments as partial JSON fragments, so keeping the raw text puts the accumulate-then-decode boundary in one place, and a malformed argument blob is a recoverable error with a path rather than a half-built value.
- **`Thinking.signature` is round-tripped verbatim.** Anthropic requires the signature back on the next turn for the block to remain valid; discarding it silently degrades multi-turn reasoning. Nothing in para/ai interprets it.

`Message.system/user/assistant/tool` are the constructors, `Message.text()` is the plain-string view (thinking and tool calls are deliberately absent — they are not what the message *said*), and `Conversation` is an immutable builder over a `List<Message>`.

A completed run gives back more than the answer:

```noeta
pub struct Run { messages: List<Message>  usage: Usage  turns: int  stop: StopReason }
```

## Tools: the function signature is the spec

There is no tool-definition DSL, because the language already answers every question one would ask. Annotate an ordinary function:

```noeta
use para.ai.tools.{Tool, Arg, Local}

#[Tool(about: "Current weather for a city")]
fn weather(
    #[Arg(help: "City name, e.g. 'Malmö'")] city: string,
    #[Arg(help: "`metric` for °C or `imperial` for °F")] units: string = "metric",
): Result<string, string> {
    return Ok("18°C, clear in ${city}")
}

agent = Agent.from(cfg, provider).tools(Local.new())?
echo agent.run_sync("What's the weather in Malmö?")?
```

The whole pipeline is four reflection primitives and no codegen:

1. `attributes_of::<Tool>()` finds every `#[Tool]` in the program and its target name. Whole-program reflection is closed-world, so this crosses the package boundary: the query runs in para/ai, your tools live in your program, and it still sees them.
2. `params_of(target)` gives each parameter's name, declared `Type`, whether it is `optional` (it declared a default), and its own `#[Arg]` metadata. That is the JSON Schema.
3. The model's argument blob is decoded and each value coerced to the declared parameter type.
4. `invoke(target, args)` calls it. It returns `Result<dyn, dyn>` and never aborts on a resolution failure.

`weather`'s schema is derived, not written twice:

```json
{"additionalProperties":false,
 "properties":{"city":{"description":"City name, e.g. 'Malmö'","type":"string"},
               "units":{"description":"`metric` for °C or `imperial` for °F","type":"string"}},
 "required":["city"],"type":"object"}
```

`#[Arg(help)]` becomes the parameter's `description`, which is the only place a model learns what a bare `string` is *for*. A parameter with a default is absent from `required`; so is an `?T`, because an omitted optional argument means `none`.

### Tools are a trust boundary, and the package says so

```noeta
@attribute(Function, Method)
@role(Semantic.TrustBoundary)
pub struct Tool { about: string = ""  name: string = "" }
```

That one line turns "which functions in this program can a language model reach?" into a query rather than a code review:

```noeta
for r in roles_of::<Semantic>() {
    match r.role {
        Semantic.TrustBoundary => { echo r.target },   // noeta.tools.weather, …
        _ => {},
    }
}
```

For a program where a model can call code, that is not a nicety; it is the review surface, and no other language's agent SDK can answer it without a bespoke linter. (Match the role rather than comparing it with `==`: the prelude `Semantic` enum has no expression form today — see [AGENTS.md](AGENTS.md).)

### A failing tool is a turn, not an outage

An unknown tool name, a missing argument, an argument that will not coerce, an unknown argument, and a tool that returns `Err` all become `Part.ToolResult(is_error: true)` fed back to the model, which then gets to try something else. That is the behavior that makes agents recover instead of stopping. A panic *inside* a tool body is still a panic, and that is correct: `invoke` catches by-name resolution, not the callee.

The coercion layer is load-bearing here rather than a convenience. `invoke` validates a callable's **name and arity and nothing else**, so a string handed to an `int` parameter reaches the function body and aborts *there* — a crashed process, not a turn. Nothing reaches `invoke` that did not come through coercion first. Coercion is lenient in one direction only: `"5"` for an `int`, `5` for a `string`, and a whole `2.0` for an `int` are accepted, because models do that constantly; a fractional `2.5` for an `int` is refused, because that conversion loses information.

### Schema derivation is total over the `Type` ADT

| declared type | schema |
| --- | --- |
| `int` | `{"type":"integer"}` |
| `float` | `{"type":"number"}` |
| `bool` | `{"type":"boolean"}` |
| `string` | `{"type":"string"}` |
| `dyn` | `{}` — declared to accept anything, so the empty schema is the honest reading |
| `List<T>` | `{"type":"array","items":…}` |
| `Set<T>` | the same, plus `"uniqueItems":true` |
| `Map<string, T>` | `{"type":"object","additionalProperties":…}` |
| `?T` | `T`'s schema, and absent from `required` |
| `A\|B` | `{"anyOf":[…]}` |

Every remaining variant is a **loud, actionable message** naming the parameter, the type, and what to write instead — never an empty schema. `bytes`, `void`, `Result`, a function type, a `dyn Trait`, a `Map` not keyed by `string`, and the fixed-width numerics (`i32`, `f32`, `f64` in container position — their packed storage cannot be built from JSON) are all refused, and the refusal reaches you at `Toolbox` construction rather than at the first model call.

Two nominal shapes get their own messages, because they are different gaps with different fixes:

- **A struct or class parameter** — a nested-object schema is [DESIGN.md](DESIGN.md) §8.5's slice, closed by `@schema`. Declare its fields as separate parameters in the meantime.
- **An enum parameter** — an enum's variants are not reflectable at runtime (there is no `variants_of` to mirror `field_specs_of`), so the `{"enum": […]}` §6 sketches cannot be derived today. Declare the parameter `string` and name the accepted values in `#[Arg(help: …)]` — which is what §6's own example does.

### `ToolSource` and `Toolbox`

Local `#[Tool]` functions and (from phase 6) an MCP server are the same thing to the agent:

```noeta
pub trait ToolSource {
    fn source_name(): string                                        // "local" | "mcp:memory"
    fn tool_type(): string                                          // gen_ai.tool.type
    fn specs(): Result<List<ToolSpec>, AiError>
    fn call(name: string, args: string): Result<string, AiError>
}
```

`specs` returns a `Result` where [DESIGN.md](DESIGN.md) §6's sketch does not, and for the same reason `Provider.encode` does: a source has to be able to refuse what it cannot express, loudly, naming the offending part. An underivable schema is a bug in the tool, and reporting it as an empty schema would send a model arguments the function cannot accept.

A `Toolbox` is every tool across every source. **A name collision is a construction-time error naming both sources**, never a last-one-wins — a silently shadowed tool is the kind of bug that shows up as a wrong answer three weeks later:

```noeta
box = Toolbox.of(Local.new())?.with(mcp)?     // Err naming both if a name repeats
agent = Agent.from(cfg, provider).with_toolbox(box)
```

`agent.tools(src)` is the one-source shorthand and returns the same `Result`. A `Toolbox` holds `List<dyn ToolSource>`, so an agent with tools is `!Send` — the same trade `api`'s middleware stack already makes. Ship the `AgentConfig`, build the `Agent` per worker.

Two smaller rules, both loud:

- **A model-facing tool name defaults to the function's last name segment**, not its qualified reflection key: `#[Tool] fn weather` inside `namespace app.tools` is keyed `app.tools.weather` but offered as `weather`, because every vendor constrains a tool name to `[A-Za-z0-9_-]`. Two tools that shorten to the same name are refused at construction; `#[Tool(name: "…")]` breaks the tie.
- **`#[Tool]` on a method is refused**, naming it. `invoke(name, args)` resolves top-level functions only and `Local` has no receiver to supply. `Method` stays in the attribute's target list because `invoke(recv, name, args)` can dispatch one and a future source over an object is a real shape — but an advertised tool that can never run would be worse than a refusal.

### The loop

When the model answers `ToolUse`, the run loop dispatches the requested calls, appends the results, and goes round again:

```
loop:
  encode → send → decode
  a refusal is AiError.Refused, immediately
  append the assistant turn
  if the model asked for no tools (or there is no toolbox): finish
  dispatch the calls concurrently and bounded; append ONE tool turn with every result
  bounded by AgentConfig.max_turns
```

Three properties are decisions:

- **All the results ride one tool turn.** A message per result would produce consecutive same-role turns, which several vendors reject outright — and it would make it possible for a context strategy to split a `ToolCall` from its `ToolResult`, the single most common bug in hand-rolled trimming. One message makes that unrepresentable.
- **Dispatch is concurrent and bounded**, over `std.task.map_bounded`, which gives per-item order and a concurrency cap for free. `AgentConfig.tool_concurrency` defaults to 4. Unbounded parallel dispatch is a good way to get rate-limited by your own agent: a model that asks for twelve web fetches should not open twelve sockets.
- **`AgentConfig.max_turns` (default 8) is a hard rail, and exceeding it is `AiError.MaxTurns`** rather than a truncated `Ok`. A run that stops mid-loop has an assistant turn whose last word was a tool call nobody answered; handing that back as an answer is the silent-truncation failure §10 refuses for context strategies, for the same reason. (The `MaxTurns` *guard* of phase 5 is a different thing at a different layer — a policy a caller opts into, reported as `Guard(...)`. This is the loop's own rail, always on.)

An agent with **no** toolbox that receives a tool-use stop finishes the run and hands the requested calls back in `Run.messages`, exactly as phase 1 did. That is the only behavior that cannot spin.

## Writing a provider

A codec implements five functions and performs no I/O:

```noeta
pub trait Provider {
    fn name(): string                                             // "anthropic" — a span attribute
    fn encode(req: ModelRequest): Result<Wire, AiError>
    fn decode_reply(body: string): Result<ModelReply, AiError>
    fn decode_error(status: int, body: string): AiError
    fn estimate_tokens(msgs: List<Message>): ?int
}
```

Two of those differ from [DESIGN.md](DESIGN.md) §2.1's sketch, and both are forced by decisions elsewhere in it:

- **`encode` returns a `Result`.** §4 requires each codec to reject what its vendor cannot express — loudly, at `encode`, naming the part and the provider. A codec that silently drops an image is a bug we can prevent by construction, and that rejection needs somewhere to go (`AiError.Encode`).
- **`decode_error` exists.** §13 requires a vendor's error *status* to become a typed `AiError.Provider(status, code, message)` with the vendor's own error body decoded, and that body's shape is vendor-specific.

`decoder(): dyn StreamDecoder` joins the trait in phase 3.

### `estimate_tokens` returns `?int`, and `none` is a real answer

A provider with no local tokenizer says so, rather than returning a number that will be trusted absolutely and is wrong by a few percent — a failure that otherwise surfaces as a vendor-side context error in the middle of a run, which is the worst possible place to learn about it. **Anthropic returns `none`**: it publishes no local tokenizer, and exact counts need its count-tokens endpoint, which is a network round trip and therefore not something a pure codec may do. A caller that needs a budget names its own margin instead of inheriting a constant we picked.

### Deltas: one accumulator, shared with streaming

A `Delta` is one neutral increment of an assistant turn, and `provider.fold(deltas, model)` turns a list of them into a `ModelReply`. The non-streaming path goes through it too: `decode_reply` emits one delta per content block and folds them. That is deliberate — when phase 3 adds `StreamDecoder`, streaming and non-streaming share the accumulator rather than growing a second copy of it that can disagree.

## The Anthropic codec

`encode` and `decode_reply` are pure string-in/string-out functions, so the codec's whole test suite is a fixture table: the request half asserts on the **exact JSON** a known request produces, and the response half decodes captured Anthropic response bodies. No network, no clock, no key.

Three things about this wire format are easy to get wrong, and all three are handled:

- **`system` is a top-level field, not a message role.** System turns are hoisted out of `messages` — from anywhere in the conversation, not just the front, because a mid-conversation system reminder is a real pattern and leaving one in `messages` is a vendor-side 400 far from its cause.
- **There is no `tool` role.** A `Role.Tool` message becomes a `user` turn carrying `tool_result` blocks.
- **`max_tokens` is required.** A request that does not name one gets `Anthropic.default_max_tokens()` (4096) rather than a 400.

```noeta
Anthropic.new(key)                          // api.anthropic.com
Anthropic.at("https://gateway.internal", key)   // a proxy or gateway
Anthropic.from_env()                        // ?Anthropic from ANTHROPIC_API_KEY
Anthropic.new(key).with_beta("…")           // the anthropic-beta header
```

An error status is decoded into `AiError.Provider(429, "rate_limit_error", "…")`, so `code == "rate_limit_error"` is matchable and nobody has to regex a message string. A body that is *not* the documented envelope (an HTML error page from a proxy) is reported verbatim rather than swallowed.

An unmodeled content block type is a **loud** `AiError.Decode` naming the path (`content[1].type`), not a silent drop: dropping a block would turn a partial answer into one that looks complete.

## Testing: the `Mock` provider

`Mock` is not a special case in the framework. It is an ordinary `Provider` whose `encode` ignores what the request says and whose `decode_reply` reads back a scripted answer — **and** a `para.api.Middleware`, which is what closes the loop. The run loop still encodes, still sends through the chain, still decodes; the layer that would have opened a socket answers from the script instead. Nothing about the run is bypassed and nothing about it touches the network.

```noeta
use para.ai.mock.Mock

@test {
    fn answers_from_the_script(): void {
        m = Mock.new().reply_text("18°C and clear in Malmö.")
        agent = m.agent(AgentConfig.new("test-model"))
        assert(agent.run_sync("What's the weather in Malmö?") == Ok("18°C and clear in Malmö."))
        assert(m.call_count() == 1)
    }
}
```

`m.agent(cfg)` wires both halves in one call; `m.tool_agent(cfg, src)` does the same with a source of tools attached. `Scripted` covers the four things a turn can be — `reply_text`, `reply_tool` / `reply_tools`, `refuse`, `fail(status, code, message)` — and the script is consumed in order, one entry per model call. A run that outlasts its script gets a loud `mock_script_exhausted` error rather than a plausible-looking answer.

`reply_tools` scripts **several calls in one turn**, which is what every current vendor actually emits and the only shape that exercises the concurrency bound:

```noeta
m = Mock.new()
    .reply_tools([
        ScriptedCall { id: "a", name: "weather", args: "{\"city\": \"Malmö\"}" },
        ScriptedCall { id: "b", name: "distance_km", args: "{\"from\": \"Malmö\", \"to\": \"Lund\"}" },
    ])
    .reply_text("18°C in Malmö, and Lund is 18 km away.")
```

Nothing in the script says what the tools *return* — that comes from running the real functions, which is what makes a scripted tool test worth writing.

Because `Mock` is the codec as well as the transport, **`calls()` records the bytes the codec actually produced** rather than a re-derivation of them — which is what makes "assert on what was sent" mean something:

```noeta
sent = m.calls()[0]
assert(sent.contains("\"max_tokens\":32"))
assert(sent.contains("You are terse."))
```

`Mock` is a `class` where everything else here is a value, for the same reason `para/api`'s `Record` is: a recorder accumulates across calls, so it needs reference identity and mutable state. That makes a `Mock`-backed agent `!Send`, which is fine — a test is not an isolate.

## Errors

```noeta
@derive(Error)
pub enum AiError {
    Transport(inner: HttpError)                       // the request never produced a response
    Provider(status: int, code: string, message: string)  // the vendor answered with an error status
    Encode(provider: string, message: string)         // a codec cannot express part of the request
    Decode(path: string, message: string)             // a response body did not decode
    Refused(reason: string)                           // the model declined
    Tool(name: string, message: string)               // a tool could not be listed, or its schema not derived
    MaxTurns(turns: int)                              // the run exceeded AgentConfig.max_turns
    ContextOverflow(needed: int, budget: int)         // phase 5
    Cancelled
}
```

A language constraint shapes this: **a type carries at most one `From` impl** (a second is a coherence conflict). So `AiError` declares `impl From<HttpError>` — the conversion that appears at the most `?` sites — and `JsonError` is mapped explicitly at its handful of decode points into `Decode(path, message)`, preserving the path. That is a decision, not an omission.

The `para/api` line holds: `Err` means the call failed, while an HTTP error *status* from a vendor is an answer. The same line runs through `Tool`: a tool that merely *fails* is not an `AiError` at all — it is a `ToolResult(is_error: true)` turn the model can recover from. `AiError.Tool` is for what the model cannot be asked to fix: an underivable schema, a name collision across sources, a source that could not be listed.

`Guard(stage, guard, reason)` and `Mcp(server, code, message)` join the enum in phases 5 and 6, with the types they name.

## Telemetry

Telemetry is not a module. The run loop emits onto `std.tracing`/`std.metrics` directly, so it cannot be forgotten: nothing when no endpoint is set, everything when one is, and no configuration API of our own. Point `OTEL_EXPORTER_OTLP_ENDPOINT` at a collector and traces appear.

Following the OpenTelemetry **GenAI semantic conventions, v1.37.0**:

| span | attributes |
| --- | --- |
| `invoke_agent {agent}` | `gen_ai.operation.name`, `gen_ai.agent.name`, `gen_ai.provider.name`, `gen_ai.request.model`, aggregate `gen_ai.usage.*`, `gen_ai.response.finish_reasons`, `para.ai.run.turns` |
| `chat {model}` | `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.request.max_tokens`, `gen_ai.request.temperature`, `gen_ai.response.model`, `gen_ai.response.finish_reasons`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens` |
| `execute_tool {name}` | `gen_ai.operation.name`, `gen_ai.tool.name`, `gen_ai.tool.call.id`, `gen_ai.tool.type` (`function` / `mcp`) |

| metric | kind | attributes |
| --- | --- | --- |
| `gen_ai.client.token.usage` | histogram | `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.token.type` |
| `gen_ai.client.operation.duration` | histogram (seconds) | the same, plus `error.type` on a failure |
| `para.ai.tool.calls` | counter | `gen_ai.tool.name`, `para.ai.tool.outcome` (`ok` / `error`) |

`para.ai.guard.denials` arrives with phase 5.

**Tool dispatch is instrumented in the run loop, not at the tool.** A `#[Tool]` function contains zero telemetry code and still shows up as a span of the model call that requested it, with its outcome on the counter. That is the whole reason dispatch is the instrumentation point.

Three commitments:

- **Message content is off by default.** Prompts and completions in spans are a privacy and compliance hazard. Opt in with `OTEL_GENAI_CAPTURE_MESSAGES=true`, matching the OTel convention rather than inventing a knob.
- **No high-cardinality metric attributes.** `error.type` is the error's *class* (`rate_limit_error`, `decode`, `timeout`) and never its message; no user ids, no thread ids, no prompt text.
- **The semconv version is pinned and stated** — right here. GenAI conventions are still moving, and a package that claims "OTel support" without naming a version is claiming nothing.

## What the run loop does today

`run(conv)` calls the model, and keeps calling while the model asks for tools — see [The loop](#the-loop) above for the shape and the three decisions in it. The guard stages and the context strategy attach to the same loop in phase 5; phase 3 replaces the single `call` with a fold over `stream`.

`run` is `async` and `run_sync` is not. That is deliberate in both directions: phase 3's streaming makes `run` genuinely async — its body becomes a fold over `stream` — and a caller written today should not have to change then; while `run_sync(text) -> Result<string, AiError>` stays synchronous because a plain string-in/string-out entry point is what makes a framework testable from an ordinary `fn`. In phase 1 the work inside is synchronous, because `para/api`'s transport is.

## Examples

- [`examples/ask/`](examples/ask) — one question, one answer: the runtime-provider `match`, the config/agent split, and a hermetic `@test` block over `Mock`.
- [`examples/tools/`](examples/tools) — a full multi-turn tool loop: two `#[Tool]` functions, a scripted parallel tool turn, the exact derived JSON Schema, a failing tool that becomes a recoverable turn, and the `roles_of::<Semantic>()` query. Hermetic, no key.

The design's other examples (`chat-cli`, `agui-server`, `mcp-memory`, `structured`, `local-ollama`) arrive with the phases they exercise.

## Requirements

The `noeta` toolchain, and `para/api` (declared as a path dependency during pre-release development). This package is pure Noeta — no `crates/`, no `native/`.

## Development

Each directory under `examples/` is its own small package depending on this repo by path; run `noeta check` / `noeta test` there and at the repo root. See [AGENTS.md](AGENTS.md) for the repo layout and the toolchain-composition note.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT>)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
