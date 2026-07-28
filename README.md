# para/ai

An agent harness for Noeta: a **provider codec seam**, one run loop over `para/api`, and OpenTelemetry GenAI spans and metrics you cannot forget to wire up.

The split that decides everything else: **a provider is a codec, not a client.** The thing that varies between model vendors is the wire format; auth headers, retries, timeouts, mocking, recording, and tracing are identical across all of them. So a `Provider` turns a neutral `ModelRequest` into a request description and a response body back into a neutral `ModelReply` — and never performs I/O. The transport is written once, over a `para.api.Api`, which means a 429 backoff is not para/ai code.

> **Status: phase 1.** Core data model, the `Provider` seam, the Anthropic codec, the `Mock` provider, the non-streaming run loop, errors, and telemetry. Streaming, tools, MCP, guardrails, context strategies, structured output, AG-UI, and the OpenAI/Google/OpenRouter/Ollama codecs are later phases; [DESIGN.md](DESIGN.md) is the whole plan and §18 is the order. What is *not* here is not stubbed — it is absent, and the seams it will attach to are marked in the source.

## What it provides

| module | contents |
| --- | --- |
| `para.ai` | `Agent`, `AgentConfig`, `Conversation`, `Run`, `Message`, `Part`, `Role`, `AiError` — the data model, the run loop, and the errors |
| `para.ai.provider` | `Provider`, `ModelRequest`, `ModelReply`, `Delta`, `Usage`, `StopReason`, `Wire`, `Framing` — the codec seam and the delta accumulator |
| `para.ai.providers.anthropic` | `Anthropic` — the Anthropic Messages API codec |
| `para.ai.mock` | `Mock`, `Scripted` — the hermetic test double, codec *and* transport |

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

`m.agent(cfg)` wires both halves in one call. `Scripted` covers the four things a turn can be — `reply_text`, `reply_tool`, `refuse`, `fail(status, code, message)` — and the script is consumed in order, one entry per model call. A run that outlasts its script gets a loud `mock_script_exhausted` error rather than a plausible-looking answer.

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
    Tool(name: string, message: string)               // phase 2
    ContextOverflow(needed: int, budget: int)         // phase 5
    Cancelled
}
```

A language constraint shapes this: **a type carries at most one `From` impl** (a second is a coherence conflict). So `AiError` declares `impl From<HttpError>` — the conversion that appears at the most `?` sites — and `JsonError` is mapped explicitly at its handful of decode points into `Decode(path, message)`, preserving the path. That is a decision, not an omission.

The `para/api` line holds: `Err` means the call failed, while an HTTP error *status* from a vendor is an answer.

`Guard(stage, guard, reason)` and `Mcp(server, code, message)` join the enum in phases 5 and 6, with the types they name.

## Telemetry

Telemetry is not a module. The run loop emits onto `std.tracing`/`std.metrics` directly, so it cannot be forgotten: nothing when no endpoint is set, everything when one is, and no configuration API of our own. Point `OTEL_EXPORTER_OTLP_ENDPOINT` at a collector and traces appear.

Following the OpenTelemetry **GenAI semantic conventions, v1.37.0**:

| span | attributes |
| --- | --- |
| `invoke_agent {agent}` | `gen_ai.operation.name`, `gen_ai.agent.name`, `gen_ai.provider.name`, `gen_ai.request.model`, aggregate `gen_ai.usage.*`, `gen_ai.response.finish_reasons`, `para.ai.run.turns` |
| `chat {model}` | `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.request.max_tokens`, `gen_ai.request.temperature`, `gen_ai.response.model`, `gen_ai.response.finish_reasons`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens` |

| metric | kind | attributes |
| --- | --- | --- |
| `gen_ai.client.token.usage` | histogram | `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.token.type` |
| `gen_ai.client.operation.duration` | histogram (seconds) | the same, plus `error.type` on a failure |

`execute_tool {name}`, `para.ai.tool.calls`, and `para.ai.guard.denials` arrive with phases 2 and 5.

Three commitments:

- **Message content is off by default.** Prompts and completions in spans are a privacy and compliance hazard. Opt in with `OTEL_GENAI_CAPTURE_MESSAGES=true`, matching the OTel convention rather than inventing a knob.
- **No high-cardinality metric attributes.** `error.type` is the error's *class* (`rate_limit_error`, `decode`, `timeout`) and never its message; no user ids, no thread ids, no prompt text.
- **The semconv version is pinned and stated** — right here. GenAI conventions are still moving, and a package that claims "OTel support" without naming a version is claiming nothing.

## What the run loop does today

`run(conv)` performs **exactly one model call**. The only thing that continues a loop is a tool-use stop, and phase 1 sends no tools. When the model *does* answer `ToolUse` — a scripted `Mock`, or a vendor that volunteers one — the run finishes and hands the requested calls back in `Run.messages` rather than spinning against a dispatcher that does not exist yet. Phase 2 replaces that arm with dispatch-and-continue, and that is also where the guard stages and the context strategy attach.

`run` is `async` and `run_sync` is not. That is deliberate in both directions: phase 3's streaming makes `run` genuinely async — its body becomes a fold over `stream` — and a caller written today should not have to change then; while `run_sync(text) -> Result<string, AiError>` stays synchronous because a plain string-in/string-out entry point is what makes a framework testable from an ordinary `fn`. In phase 1 the work inside is synchronous, because `para/api`'s transport is.

## Examples

- [`examples/ask/`](examples/ask) — one question, one answer: the runtime-provider `match`, the config/agent split, and a hermetic `@test` block over `Mock`.

The design's other examples (`chat-cli`, `agui-server`, `mcp-memory`, `structured`, `local-ollama`) arrive with the phases they exercise.

## Requirements

The `noeta` toolchain, and `para/api` (declared as a path dependency during pre-release development). This package is pure Noeta — no `crates/`, no `native/`.

## Development

`examples/ask` is its own small package depending on this repo by path; run `noeta check` / `noeta test` there and at the repo root. See [AGENTS.md](AGENTS.md) for the repo layout and the toolchain-composition note.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT>)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
