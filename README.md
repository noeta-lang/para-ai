# para/ai

An agent harness for Noeta: a **provider codec seam**, one run loop over `para/api`, and OpenTelemetry GenAI spans and metrics you cannot forget to wire up.

The split that decides everything else: **a provider is a codec, not a client.** The thing that varies between model vendors is the wire format; auth headers, retries, timeouts, mocking, recording, and tracing are identical across all of them. So a `Provider` turns a neutral `ModelRequest` into a request description and a response body back into a neutral `ModelReply` — and never performs I/O. The transport is written once, over a `para.api.Api`, which means a 429 backoff is not para/ai code.

> **Status: phases 1–4, 6, 7, and 8.** Core data model, the `Provider` seam, the run loop, errors, telemetry, **tool calling**, **streaming** (`StreamDecoder`, the neutral `Event` enum, `agent.stream(conv, tx)`, and a scripted `FrameStream` so a streaming test needs no socket), the **`@prompt` expression tier with automatic provider prompt caching**, the **MCP client** (stdio and streamable HTTP, tools as a `ToolSource`, resources, prompts, and a sampling seam that is off by default), **AG-UI over SSE** (`agui.respond(agent, req)` over `std.http.server.sse`, and a `Tape` so the served frames are assertable without a socket) — and **all five provider codecs**: Anthropic, OpenAI, OpenRouter, Google, and Ollama, across three codec families. Guardrails, context strategies, and structured output are later phases; [DESIGN.md](DESIGN.md) is the whole plan and §18 is the order. What is *not* here is not stubbed — it is absent, and the seams it will attach to are marked in the source.

## What it provides

| module | contents |
| --- | --- |
| `para.ai` | `Agent`, `AgentConfig`, `Conversation`, `Run`, `Message`, `Part`, `Role`, `AiError` — the data model, the run loop, and the errors; plus `Event`, `EventSink`, `Frames`, and `Streamer` — the streaming surface |
| `para.ai.provider` | `Provider`, `StreamDecoder`, `ModelRequest`, `ModelReply`, `Delta`, `Usage`, `StopReason`, `Wire`, `Framing` — the codec seam and the delta accumulator |
| `para.ai.tools` | `Tool`, `Arg`, `ToolSpec`, `ToolSource`, `Local`, `Toolbox`, `dispatch` — the signature-is-the-spec pipeline — plus `Output` and `schema_for`, the structured-output door onto the same schema walk |
| `para.ai.guard` | `Guard`, `Stage`, `Verdict`, `GuardCtx`, `OnDeny`, `Fired`, `decide`, and nine standard guards — `ToolAllowlist`, `Approval`, `MaxTurns`, `TokenBudget`, `Redact`, `Blocklist`, `SchemaGuard`, `Recall`, `Judge` |
| `para.ai.prompt` | `render`, `Prompt`, `Resolved` — the `@prompt` expression tier, and the stable/volatile split a prompt cache is placed from |
| `para.ai.mcp` | `McpClient`, `Stdio`, `Http`, `Transport`, `Events`, `Sampler`, `Capabilities`, `Resource`, `PromptSpec` — the MCP client, and `impl ToolSource for McpClient` |
| `para.ai.providers.anthropic` | `Anthropic` — the Anthropic Messages API codec |
| `para.ai.providers.openai` | `OpenAiCompat` — the Chat Completions codec — and `OpenAi`, `OpenRouter`, `OllamaCompat`, which are *configurations* of it |
| `para.ai.providers.google` | `Google` — the Gemini `generateContent` codec |
| `para.ai.providers.ollama` | `Ollama` — Ollama's native `/api/chat` codec, over NDJSON |
| `para.ai.mock` | `Mock`, `Scripted`, `ScriptedCall`, `Collector`, `ScriptedFrames`, `Replay` — the hermetic test double, codec *and* both transports |

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

pub struct Message { role: Role  parts: List<Part>  name: ?string  cache_breakpoint: bool }
```

Three of those are decisions rather than shapes:

- **`ToolCall.args` is a raw JSON string, not a decoded map.** Vendors stream tool arguments as partial JSON fragments, so keeping the raw text puts the accumulate-then-decode boundary in one place, and a malformed argument blob is a recoverable error with a path rather than a half-built value.
- **`Thinking.signature` is round-tripped verbatim.** Anthropic requires the signature back on the next turn for the block to remain valid; discarding it silently degrades multi-turn reasoning. Nothing in para/ai interprets it.
- **`cache_breakpoint` is a hint, exactly like `name`.** It means "everything up to and including this turn may be served from the vendor's prompt cache". A codec whose vendor caches implicitly ignores it and still produces a correct request; Anthropic's turns it into `cache_control`. `AgentConfig` sets it on the system prompt's stable prefix for you — see [`@prompt`](#prompt-a-prompt-is-a-value-and-prompt-caching-falls-out-of-it) — and `Message.cached()` is the hand door.

`Message.system/user/assistant/tool` are the constructors, `Message.text()` is the plain-string view (thinking and tool calls are deliberately absent — they are not what the message *said*), and `Conversation` is an immutable builder over a `List<Message>`.

A completed run gives back more than the answer:

```noeta
pub struct Run { messages: List<Message>  usage: Usage  turns: int  stop: StopReason }
```

## `@prompt`: a prompt is a value, and prompt caching falls out of it

`@prompt { … }` is an **expression tier** — a typed value built from the block's text, not a string:

```noeta
use para.ai.prompt.render          // the one import that makes `@prompt { … }` exist here

cfg = AgentConfig.new("claude-opus-5").with_system_prompt(@prompt {
    You are a support agent. Answer in at most three sentences and never promise a refund.

    Customer: ${account.company}, on the ${account.plan} plan since ${account.opened}.
}.trimmed())
```

The block desugars to `render(statics, holes)`, where `statics` is the literal text split at every `${…}` and `holes` are the interpolations as **zero-argument closures**. Three things follow, and the third is the reason this module exists.

**1. A malformed prompt variable is a compile error pointing inside the prompt.** A hole is real Noeta, parsed by the full grammar, closed over the enclosing scope, and type-checked — so `${acount.plan}` is E0007 at that column rather than a `${undefined}` that ships to production.

**2. Holes are thunks, so an expensive interpolation runs only if something asks for it.** `p.stable()`, `p.is_static()`, and `p.trimmed()` all read the prompt's cache prefix without evaluating a single hole, which is what makes a caching decision free even when a hole is a memory recall or a database read. `p.resolve()` evaluates each hole **exactly once** and hands back a `Resolved`.

**3. Statics always number holes + 1** — so the prompt arrives *pre-split into its stable and its volatile part*, which is precisely the input a prompt cache wants.

```noeta
p = @prompt { You work for ${company}. Be brief. }

p.statics            // [" You work for ", ". Be brief. "]   — holes + 1, always
p.holes.len()        // 1                                     — still unevaluated
p.stable()           // " You work for "                      — the longest part that cannot vary
p.resolve().volatile()   // "Acme. Be brief. "                — everything from the first hole on
```

`stable()` is the cache breakpoint, computed by the compiler. **No other agent framework can do this**, because in every other language a prompt is one opaque string by the time the SDK sees it — so a framework has to guess at the boundary, ask you to mark it by hand, or skip caching.

### Where the breakpoint lands, per vendor

`AgentConfig.with_system_prompt` resolves the prompt once and stores it **split** (`AgentConfig.system` is a `Resolved`, not a `string`). The run loop turns the split into two system turns — the stable prefix, then the volatile tail — and marks the first with `Message.cache_breakpoint`. Two turns rather than one turn with two parts, because a vendor's breakpoint attaches to a *content block* and the cached prefix ends where that block ends.

| vendor | mechanism | what the codec does |
| --- | --- | --- |
| Anthropic | explicit | `cache_control: {"type": "ephemeral"}` on the marked turn's last content block; at most four per request, and a fifth is `AiError.Encode` at encode time rather than a vendor 400 that names no message |
| OpenAI | implicit prefix match | nothing — the marker is ignored; what it needs is the stable text **first and byte-identical**, which the split guarantees |
| Google | implicit prefix match | the same |
| Ollama | implicit prefix match | the same — the server keeps a KV cache for the prefix it last served |

Marking is on by default (`AgentConfig.cache`), which is the point: caching is correct *by default* because the language handed us the split. `.uncached()` removes the marker and changes no other byte — the prefix is still first and still identical, so an implicitly-caching vendor is unaffected. That is the switch for the one shape where a marker costs: a single-call workload with a large system prompt that never repeats inside the cache's TTL, where a cache *write* is priced above a plain read.

### The rest of the surface

- **`with_system("…")` is unchanged.** A plain string is a prompt with no holes, so it is stable in its entirety and gets the *maximal* cache prefix. Nothing an existing caller wrote had to change. (It is a separate method from `with_system_prompt` rather than an overload because a trait cannot be implemented for `string` — E0013 — so no bound can span the two.)
- **`Conversation.system_prompt(p)` / `.user_prompt(p)`** take a `@prompt` as naturally as the string doors do, resolving once on the way in. They do **not** mark by default: a conversation turn is not reliably a prefix, and breakpoints are a scarce per-request resource. Pass `true`, or use `Message.cached()`, when a turn really is a long stable prefix worth caching — a retrieved corpus, a code base, a transcript.
- **Resolution happens at configuration time, once.** Every turn of a run re-sends the system prompt, and implicit prefix caching keys on the bytes being identical; a hole re-evaluated per call would break the match silently, with nothing downstream able to notice.
- **`text: "markdown"`** on the tier declaration is why the body highlights as Markdown in an editor and why hovering `@prompt` reports `expression tier @prompt — markdown body, evaluates to Prompt`. One line in `para.ai.prompt`, and every consumer picks it up.
- **The body is verbatim**, including the whitespace the braces introduce — because the bytes a vendor's cache is keyed on are not something a handler should quietly rewrite. `.trimmed()` removes the block's outer edges when you want it; interior layout is content.

[`examples/prompt_cache/`](examples/prompt_cache) is the whole of the above, asserted.

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

1. `attributes_of::<Tool>()` finds every `#[Tool]` in the program and its target name. Reflection is closed-world and whole-program, so this crosses the package boundary: the query runs in para/ai, your tools live in your program, and it still sees them. Split them across as many modules as you like — a sibling module the entry file never imports is found too, and so is a dependency package's.

   **The other direction is the one to keep in mind: whole-program means your dependencies too.** A `#[Tool]` declared at module level inside a *library* is discovered from your program and offered to your model, with nothing in your code naming it. So if you write a library, keep its `#[Tool]` fixtures inside a `@test` block (this package does; see `tools.noe`), and ship real tools through a `ToolSource` your caller constructs rather than through a `#[Tool]` that `Local` picks up uninvited. `roles_of::<Semantic>()` is how you audit what actually got in — see below.

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

**The same attribute annotates a struct field**, because the type door walks fields through the walk the parameter door walks parameters and a description is not a property of which door you came through:

```noeta
@derive(Deserialize<Json>)
struct Triage {
    #[Arg(help: "One of `billing`, `shipping`, `technical`, `other` — exactly those words.")]
    category: string
    #[Arg(help: "1 (a question) to 5 (money is on fire). 4 and 5 always need a human.")]
    severity: int
}
```

That line is worth more than it looks on a structured output. Without it a model is sent `{"type": "string"}` for `category` and invents a value — measured against a live Gemini, which answered `"Lost order"` three runs running, was refused by `Validate` at the decode door, and cost a repair round each time to be told what the schema could have said for free. A field's annotation is read through `attributes_of::<Arg>()` rather than off its `FieldSpec` (which carries name, type and optionality only), so nothing about a field's *declaration* changes to make this work.

### Tools are a trust boundary, and the package says so

```noeta
@attribute(Function, Method)
@role(Semantic.TrustBoundary)
pub struct Tool { about: string = ""  name: string = "" }
```

That one line turns "which functions in this program can a language model reach?" into a query rather than a code review:

```noeta
for r in roles_of::<Semantic>() {
    if r.role == Semantic.TrustBoundary {
        echo r.target                                  // noeta.tools.weather, …
    }
}
```

For a program where a model can call code, that is not a nicety; it is the review surface, and no other language's agent SDK can answer it without a bespoke linter. Run it over your own program and read the list: whole-program reflection means a dependency's module-level `#[Tool]` is on it too, and this is where you would see it.

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
| a declared **struct** or **class** | a nested `{"type":"object", …, "additionalProperties":false}`, recursively, to any depth |
| a declared **enum** | `{"type":"string","enum":[…]}` — its *backings* when it is a backed enum, its case names when it is not |

Every remaining variant is a **loud, actionable message** naming the parameter, the type, and what to write instead — never an empty schema. `bytes`, `void`, `Result`, a function type, a `dyn Trait`, a `Map` not keyed by `string`, and the fixed-width numerics (`i32`, `f32`, `f64` in container position — their packed storage cannot be built from JSON) are all refused, and the refusal reaches you at `Toolbox` construction rather than at the first model call. So is a **recursive** type, by name and with the cycle printed: a JSON Schema for a cycle needs `$ref`, which no vendor's strict mode accepts uniformly.

The nominal rows are asked as a **pair**, and that is the whole trick. `field_specs_of` answers an enum with the empty list — and a field-less struct with the empty list too, so through that query alone an enum is *indistinguishable from an empty struct*, and a walk that recursed on fields would emit `{"type":"object","properties":{}}` for an enum and be silently wrong. `variants_of` is the other half: fields present means a struct, variants present means an enum, and both empty is the one honest "nothing is known about this name".

One nominal shape is still refused, and the reason is narrower than it used to be:

- **An enum-typed parameter.** Its `{"enum": […]}` schema derives perfectly well now — what is missing is a way to *build* the value. Four doors, all measured: `@derive(Deserialize<Json>)` on a struct with an enum-typed field is a check-time error, `construct` takes structs and classes only, `json.decode_typed` needs the recipe that derive would have registered, and `Enum.from` takes a case name and aborts on an unknown one. Deriving the schema and failing at dispatch would teach a model to send arguments the function cannot accept, so the refusal stays. Declare the parameter `string` and name the accepted values in `#[Arg(help: …)]`.

**A struct-typed parameter works end to end**, and every field is coerced before the value is built: `construct` validates a field's presence and its *scalar* type only, so a raw object handed to a struct-typed field would otherwise be stored as-is and abort at the first field read. The coercion layer is the type check, and nothing reaches the builder around it.

### `ToolSource` and `Toolbox`

Local `#[Tool]` functions and an MCP server are the same thing to the agent:

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

- **All the results ride one tool turn, in the order the model asked for them.** A guard splits the turn into the calls it approved (dispatched concurrently, and returned in *their* order) and the ones it denied (answered on the spot), and the two are merged back on call id rather than concatenated — a model that asks for `find_order` and then `open_refund` must not be handed the refusal first. A message per result would produce consecutive same-role turns, which several vendors reject outright — and it would make it possible for a context strategy to split a `ToolCall` from its `ToolResult`, the single most common bug in hand-rolled trimming. One message makes that unrepresentable.
- **Dispatch is concurrent and bounded**, over `std.task.map_bounded`, which gives per-item order and a concurrency cap for free. `AgentConfig.tool_concurrency` defaults to 4. Unbounded parallel dispatch is a good way to get rate-limited by your own agent: a model that asks for twelve web fetches should not open twelve sockets.
- **`AgentConfig.max_turns` (default 8) is a hard rail, and exceeding it is `AiError.MaxTurns`** rather than a truncated `Ok`. A run that stops mid-loop has an assistant turn whose last word was a tool call nobody answered; handing that back as an answer is the silent-truncation failure §10 refuses for context strategies, for the same reason. (The `MaxTurns` *guard* of phase 5 is a different thing at a different layer — a policy a caller opts into, reported as `Guard(...)`. This is the loop's own rail, always on.)

An agent with **no** toolbox that receives a tool-use stop finishes the run and hands the requested calls back in `Run.messages`, exactly as phase 1 did. That is the only behavior that cannot spin.

## Structured responses: ask for a type, get a type

```noeta
use para.ai.{extract}
use para.ai.tools.{Output}

@derive(Deserialize<Json>)
struct Extraction {
    company: string
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

out = Output.of(type_name::<Extraction>())?
e   = extract::<Extraction>(agent, conv, out)?
```

The schema is **derived from the declaration** by the same walk the table above describes — there is nothing to write and nothing to keep in sync. Each codec then spells it its own vendor's way: Anthropic a forced single tool (`tool_choice` naming it, with the document arriving as that call's arguments), OpenAI `response_format: json_schema` with `strict`, Google `responseSchema` alongside `responseMimeType`, Ollama a bare `format`.

**One vendor cannot do this with tools attached.** Gemini refuses `functionDeclarations` and `responseMimeType: application/json` in the same request, so `extract::<T>` from an agent that still carries its toolbox is a 400 there and works everywhere else. The Google codec turns that into a refusal at `encode` naming the fix rather than a vendor error naming nothing: run the tool loop first, then ask for the document from `agent.with_toolbox(Toolbox.new())` — which is also the cheaper shape, since the lookups already happened and their answers are in the conversation being handed over.

### The best output guardrail is already in the language

`json.try_parse::<T>` runs `Validate` **automatically, bottom-up, at the decode door**. para/ai does not call it and could not do it better: a nested failure arrives as `items[2]: confidence out of range: 1.4` — the field, its path, and the invariant in the words its author wrote.

What para/ai does is notice that this is also an excellent repair prompt. On a decode or validation failure the message goes back as a correction turn and the call is made again, `repair: int = 1` by default, one span event per attempt. One repair fixes the overwhelming majority of real failures; an unbounded loop against a model that has misunderstood the schema is a way to spend money. A budget that runs out returns **the last typed failure with its path**, never a half-built value.

A **refusal is not a decode failure**: `StopReason.Refusal` is `AiError.Refused` and is never repaired. Conflating them makes "the model declined" look like "your schema is wrong", which sends you to debug the wrong thing.

### Why `extract` is a function and names the type twice

`agent.extract::<Extraction>(conv)` would be nicer and the language cannot express it. A generic *method* cannot forward its type parameter into `json.try_parse::<T>` (E0058, "call-site-typed forwarding is supported in top-level generic functions only"), and a turbofish must supply *every* parameter of what it instantiates — so the provider is erased behind a `dyn Structured` seam to leave exactly one to name. And `type_name::<T>()` over a type parameter is E0058 too, which is why the schema is reflected at the call site and passed in; the diagnostic's own advice is to do exactly that. Both are filed upstream.

## Guardrails: one trait, four stages, no privileged guard

```noeta
use para.ai.guard.{Approval, Approve, Blocklist, OnDeny, Recall}

agent = Agent.from(cfg.denying(OnDeny.Feedback(max: 2)), provider)
    .tools(mem)?
    .with(Blocklist.new(["ignore previous instructions"]))
    .with(Recall.new(mem, "search", 5))
    .with(Approval.new(Approve.Allowlist(names: ["search", "read"])))
```

A guard sees content at one of four points — `Input`, `Output`, `ToolCall`, `ToolResult` — and answers `Allow`, `Deny(reason)` or `Rewrite(parts)`. Guards run in **registration order** and the **first non-`Allow` wins**, so put the cheap structural checks before the expensive judgement.

`Deny` is handled by the run's policy, which is explicit rather than something to guess at:

| `on_deny` | behavior |
| --- | --- |
| `Stop` (default) | the run ends with `AiError.Guard(stage, guard, reason)` |
| `Feedback(max)` | the reason goes back as a correction — a user turn at `Output`, a failed `ToolResult` at the two tool stages — up to `max` times |
| `Replace(parts)` | the denied content is swapped for a canned reply |

At `Stage.Input` there is nobody to give feedback to, so `Feedback` reads as `Stop` there and `Replace` is the policy with a real answer: it ends the run with the canned reply.

**`Rewrite` is why redaction, memory injection and prompt hardening are one mechanism rather than three features.** `Redact` replaces text with the secrets removed, `Recall` prepends what a memory server remembered, and a hardening guard wraps a user turn in a delimiter block — the same verdict three times, and none of them needed a hook of its own.

**No guard is privileged by the framework.** `Judge` calls a cheap model over a `dyn Asking` that `Agent` implements; `ToolAllowlist` compares two strings; to the run loop they are the same kind of value. That is the para/api middleware principle, and it is what makes the trait worth having.

Ships with `ToolAllowlist`, `Approval` (`Auto` / `Deny` / `Allowlist(names)` / `Ask(callback)` — the callback sees the arguments, because approving `delete` without seeing what it will delete is not approval), `MaxTurns`, `TokenBudget`, `Redact(pattern, replacement)`, `Blocklist`, `SchemaGuard`, `Recall`, and `Judge`.

**Approval attaches above `Toolbox.call`**, per call rather than per turn, which is what makes one mechanism cover local `#[Tool]` functions and MCP tools alike — a model that asks for one approved tool and one denied one gets its approved answer, and both results land in the same tool turn.

Every non-`Allow` verdict is a span carrying its reason, a counter (`para.ai.guard.denials`, `para.ai.guard.rewrites`, keyed by stage and guard name only — a reason is unbounded text), and an entry in `Run.verdicts`. "The guardrails are configured" and "the guardrails are firing" have to be distinguishable without reading logs, which is the distinction `Cache.hits()` draws in para/api.

## MCP: a server's tools are just tools

`para.ai.mcp` is a **client**. The toolchain already ships an MCP *server* (`noeta mcp`), and this package has no interest in being a second one.

```noeta
use para.ai.mcp.{McpClient, Stdio}

mem = McpClient.connect(Stdio.new("mcp-memory", ["--db", "./memory.db"]))?
agent = Agent.from(cfg, provider).tools(mem)?
```

That is the whole integration. `McpClient` is a `ToolSource`, so a server's tools go into the same `Toolbox` as local `#[Tool]` functions, collide on the same names, dispatch through the same `dispatch`, and come back as the same `ToolResult` parts. **There is deliberately no MCP-only call path**: the phase-5 approval guard attaches above `Toolbox.call` and therefore covers a memory server's `remember` exactly as it covers a local `weather`, which it could not do if this module dispatched on its own.

`connect` is the whole handshake — `initialize`, capability negotiation, `notifications/initialized`, and the first `tools/list` — so a client you hold is one an agent can use, and a broken server says so there rather than at the first model call.

### Memory is a server, not a subsystem

There is no `para.ai.memory`, and there will not be one. para/ai ships no store, no embedder, and no recall heuristic; it ships the client that talks to whichever one you point it at. Memory behind MCP is swappable, inspectable, and shared with every other agent you run — and [`examples/memory/`](examples/memory) makes that concrete with a memory server written in sixty lines of POSIX shell.

The zero-configuration path is a system prompt and a `ToolSource`: tell the agent the memory tools exist and it calls them itself. Phase 5's `Recall` guard automates the recall half for callers who would rather not rely on the model remembering to look. Both use this same client.

### Two transports

| transport | request path | server→client channel |
| --- | --- | --- |
| `Stdio.new(cmd, args)` | one JSON document per line on the child's stdin | documents interleaved with a reply, on the same pipe |
| `Http.new(url)` | POST through a `para.api.Api` | `Events.drain` over `client.stream(req, Framing.Sse)` |

`Stdio` needs no native code at all: `os.spawn` gives a `Process` with `write`/`read_line`/`try_wait`/`kill`, and JSON-RPC framing over that is ordinary Noeta.

`Http` speaks streamable HTTP. Its POST half rides the `para/api` onion exactly as the run loop's buffered model call does, so `Retry`, `Record`, and `Logging` are available to an MCP session for free — and a scripted middleware answers it in the tests with no socket. Its server→client half cannot ride that onion (a `FrameStream` structurally cannot, [DESIGN.md](DESIGN.md) O-4), so it comes through the `Events` seam, which hands back **documents** rather than frames: SSE framing belongs to `std.http`, and a second copy of that decoder here would be worse than the seam. `HttpEvents` reads the response head before consuming a frame, so a 405 ("this server has no such channel") is an empty answer and every other non-2xx is a typed failure — neither waits on a frame that is never coming.

Three protocol details `Http` owns, because they are the difference between working against a real server and almost working: the **session id** (`Mcp-Session-Id`, carried on every later request, and a `404` once you hold one means `session_expired` — a reconnect, not a wrong URL); the **negotiated revision**, which goes back out as `MCP-Protocol-Version`; and a **POST answered with `text/event-stream`**, whose already-whole body is cut where it stands.

The server→client channel is drained by `client.listen(max)` rather than by a background reader, and that is forced rather than chosen: structured concurrency has no detached tasks — a `concurrent` block joins everything it spawned at its closing brace — so there is nowhere for a listener to live between calls. Over stdio `listen` returns 0: every read door blocks, so there is no way to probe for a pending message, and server→client requests are handled where they actually arrive, interleaved with a reply.

### What happens when a server crashes, hangs, or dies mid-call

The lifecycle is decided rather than emergent, and every claim below is measured against the toolchain (the measurements are in the source, next to the mechanism they justify):

| the server… | what happens |
| --- | --- |
| will not start | `AiError.Mcp(server, "spawn", …)`. `os.spawn` of a missing binary **aborts the process**, so `Stdio.start` resolves the command against `PATH` itself and refuses first. |
| crashes | its stdout closes, which ends the blocked read at once — a crashed server unblocks the agent rather than hanging it. The exit status and its last stderr line come back in `AiError.Mcp(server, "server_exited", …)`. |
| dies mid-call | that same path: the call in flight becomes a failed turn the model is told about. Every write is preceded by a `try_wait` liveness check, because `Process.write` to a dead child **aborts the process**. |
| hangs (alive, silent) | bounded only if you asked for it: `Stdio.new(…).with_deadline(ms)` kills the server and fails the call with `AiError.Mcp(server, "timeout", …)`. See below. |
| talks without answering | `read_budget` (64) intervening documents, then the exchange fails. No watchdog needed — the documents keep coming. |
| is asked for something it never advertised | `AiError.Mcp(server, "capability", …)` naming the capability and the server, rather than an empty list that reads like "this server has nothing". |

**Why the deadline is opt-in.** A blocked `Process.read_line` parks the whole scheduler — a sibling task `spawn`ed in the same isolate never runs while it is waiting, so a timeout cannot be a `race`. Re-measured on a toolchain where cancellation works, because that is the claim most worth doubting: a child that says nothing for 3 s and then speaks is killed at 300 ms by an isolate, and not at all by a `spawn`ed task, which never gets to run. The one thing that *does* run beside the read is a separate **isolate**, which needs a `concurrent` block, which is E0040 in a synchronous `fn` — and `ToolSource.call` is synchronous and must stay so, since it is held as `dyn` and `async` through `dyn` is unsound (DESIGN O-2). So the bounded read is driven through `map_bounded`, exactly as `run_sync` drives the run loop, and the watchdog lives in an isolate. When the reply arrives the watchdog is disarmed by `h.cancel()`, and that is why it sleeps its deadline in **5 ms slices** rather than in one long `sleep`: an isolate parked in a single sleep observes a cancel only when that sleep *ends*, so a whole-deadline sleep would make every timely reply pay the whole deadline. Sliced, a cancel 60 ms into a 3 s deadline joins `Err(Cancelled)` at once and the watchdog's side effect never lands — measured. The kill itself goes through `kill(1)`, because the `Process` handle is not `Send` and cannot cross into the isolate (E0042). That is an isolate and a POSIX dependency per call — worth it when a hang would otherwise be permanent, not worth it by default. Over HTTP none of this applies: `client.timeout(ms)` already bounds a request and a stream open, so `Http.new(url, timeout_ms)` is the whole story.

### Resources, prompts, and sampling

**Resources are never auto-injected.** `client.resources()` and `client.read(uri)` hand you the server's documents; putting one in the context is your decision, because auto-injection is how context windows quietly fill up.

```noeta
for r in client.resources()? {
    io.outln("${r.uri} — ${r.description}")
}
contents = client.read("memo://notes")?      // List<ResourceContent>: uri, mime, text, blob
```

A binary resource's `blob` is base64 **exactly as the server sent it**, undecoded: this package has a base64 encoder and no decoder, and handing back invented bytes would be worse than handing back what arrived.

**A prompt is an ordinary conversation prefix.** `client.prompt(name, args)` returns `List<Message>` — the same type `Conversation` holds — so a server-supplied prompt needs no special path:

```noeta
conv = Conversation { messages: client.prompt("review", {"file": "main.noe"})? }
```

A non-text prompt content block is refused by name rather than dropped, for the same base64 reason: a prompt quietly missing its image no longer says what the server wrote.

**Sampling is off by default**, because it hands a subprocess your API key. `connect` advertises no `sampling` capability at all and answers such a request with JSON-RPC's "method not found" — *answers* it, rather than ignoring it, because an ignored request is a server waiting forever on a reply that is not coming. Turning it on is explicit and budgeted:

```noeta
client = McpClient.connect_sampling(Stdio.new("mcp-thing", []), MySampler {}, 5)?
```

`Sampler` is one method — the request's `params` as JSON text in, the JSON-RPC `result` as JSON text out — so a caller can answer it with an `Agent`, a cheap model, or a canned reply. Every request is counted against the budget and the one past it is refused with a JSON-RPC error rather than quietly served.

### Testing MCP without a server

The suite spawns a real subprocess and speaks real JSON-RPC to it over real pipes — the fixture *is* a POSIX shell script the test writes to a temp path — so nothing depends on a published MCP server, an npm install, or a network. The HTTP half is scripted through a `para.api` middleware, and the server→client channel through the `Events` seam. Wire format is asserted as exact bytes for `initialize` and `tools/call`, the way the codec fixtures assert request bodies.

## Writing a provider

A codec implements five functions and performs no I/O:

```noeta
pub trait Provider {
    fn name(): string                                             // "anthropic" — a span attribute
    fn encode(req: ModelRequest): Result<Wire, AiError>
    fn decode_deltas(body: string): Result<List<Delta>, AiError>  // a whole body, as increments
    fn decode_reply(body: string): Result<ModelReply, AiError>    // = fold(decode_deltas(body), "")
    fn decoder(): dyn StreamDecoder                               // fresh and stateful, per request
    fn decode_error(status: int, body: string): AiError
    fn estimate_tokens(msgs: List<Message>): ?int
}
```

Three of those differ from [DESIGN.md](DESIGN.md) §2.1's sketch, and each is forced by a decision elsewhere in it:

- **`encode` returns a `Result`.** §4 requires each codec to reject what its vendor cannot express — loudly, at `encode`, naming the part and the provider. A codec that silently drops an image is a bug we can prevent by construction, and that rejection needs somewhere to go (`AiError.Encode`).
- **`decode_error` exists.** §13 requires a vendor's error *status* to become a typed `AiError.Provider(status, code, message)` with the vendor's own error body decoded, and that body's shape is vendor-specific.
- **`decode_deltas` exists, and `decode_reply` is a fold over it.** The streaming path has to produce deltas — that is what a `StreamDecoder` is. If the buffered path produced a `ModelReply` directly, the two would accumulate separately and could disagree. Making the buffered door speak the same vocabulary means everything below it is one implementation.

### `estimate_tokens` returns `?int`, and `none` is a real answer

A provider with no local tokenizer says so, rather than returning a number that will be trusted absolutely and is wrong by a few percent — a failure that otherwise surfaces as a vendor-side context error in the middle of a run, which is the worst possible place to learn about it. **Every codec in this package returns `none`, and each says why.** Anthropic and Google publish no local tokenizer — exact counts need their count-tokens endpoints, which are network round trips and therefore not something a pure codec may do. OpenAI's tokenizer is a library and a byte-pair table rather than anything reachable from here. Ollama's lives *inside the served model*, a different one per model, loaded on the server. A caller that needs a budget names its own margin instead of inheriting a constant we picked.

### Deltas: one accumulator, both transports

A `Delta` is one neutral increment of an assistant turn, and `provider.fold(deltas, fallback_model)` turns a list of them into a `ModelReply`. **Both transports produce deltas and nothing downstream of them knows which one ran** — a buffered body through `decode_deltas`, a streamed one through `decoder()`, and from there the event emission and the accumulation are the same code. A bug in "these increments make that message" cannot exist in only one of them, because there is only one of it.

`Delta.ModelDelta(model)` is what makes a delta list a *complete* description of a reply rather than most of one: Anthropic names the served model in `message_start`, so the streaming path has to carry it somewhere, and putting it in the vocabulary rather than on the decoder keeps `StreamDecoder` at the two methods §2.1 specifies. `fold`'s `model` argument is now the fallback for a stream that named none.

### `StreamDecoder`

```noeta
pub trait StreamDecoder {
    fn push(frame: Frame): Result<List<Delta>, AiError>
    fn finish(): Result<Usage, AiError>
}
```

Stateful, and a fresh object per request, because every vendor's streaming protocol is: Anthropic's frames are indexed (`content_block_start` opens block 3; later deltas only say "3"), OpenAI accumulates `choices[].delta`, Google sends partial `candidates`.

**`finish` is not a formality — it is where a truncated stream is caught.** The frames that did arrive decode perfectly well; only the missing terminator says the reply is half of one, and reporting half a reply as a complete answer is the worst failure this package could have. It returns the call's total usage for a second reason: a vendor that splits input and output token counts across two frames has no single frame to read them off, so the running total is the decoder's own state.

## The Anthropic codec

`encode` and `decode_reply` are pure string-in/string-out functions, so the codec's whole test suite is a fixture table: the request half asserts on the **exact JSON** a known request produces, and the response half decodes captured Anthropic response bodies. No network, no clock, no key.

Three things about this wire format are easy to get wrong, and all three are handled:

- **`system` is a top-level field, not a message role.** System turns are hoisted out of `messages` — from anywhere in the conversation, not just the front, because a mid-conversation system reminder is a real pattern and leaving one in `messages` is a vendor-side 400 far from its cause.
- **There is no `tool` role.** A `Role.Tool` message becomes a `user` turn carrying `tool_result` blocks.
- **`max_tokens` is required.** A request that does not name one gets `Anthropic.default_max_tokens()` (4096) rather than a 400.

It is also the one vendor here whose prompt cache is **explicit**: a `Message.cache_breakpoint` becomes `cache_control: {"type": "ephemeral"}` on that turn's last content block, stamped *before* the alternation merge so a merged turn keeps the marker on the block it was placed on. Four markers is a vendor limit, so a fifth is `AiError.Encode` at encode time.

```noeta
Anthropic.new(key)                          // api.anthropic.com
Anthropic.at("https://gateway.internal", key)   // a proxy or gateway
Anthropic.from_env()                        // ?Anthropic from ANTHROPIC_API_KEY
Anthropic.new(key).with_beta("…")           // the anthropic-beta header
```

An error status is decoded into `AiError.Provider(429, "rate_limit_error", "…")`, so `code == "rate_limit_error"` is matchable and nobody has to regex a message string. A body that is *not* the documented envelope (an HTML error page from a proxy) is reported verbatim rather than swallowed.

An unmodeled content block type is a **loud** `AiError.Decode` naming the path (`content[1].type`), not a silent drop: dropping a block would turn a partial answer into one that looks complete.

## Five providers, three codec families

DESIGN §2.1 makes a claim the code either supports or does not: **OpenRouter and Ollama's `/v1` are not new wire formats, so they should be configurations of the OpenAI-compatible codec rather than new files of JSON-shuffling.** They are.

| provider | family | module | what differs from the family codec |
| --- | --- | --- | --- |
| Anthropic | `anthropic` | `providers.anthropic` | — |
| Google | `google` | `providers.google` | — |
| OpenAI | `openai_compat` | `providers.openai` | — (the family base) |
| OpenRouter | `openai_compat` | `providers.openai` | **three field values** and two helpers: base URL, `max_tokens` rather than `max_completion_tokens`, reasoning accepted back on input; `OpenRouter.app` sets `HTTP-Referer`/`X-Title`, `OpenRouter.fallbacks`/`routing` set the `models` and `provider` body keys |
| Ollama (`/v1`) | `openai_compat` | `providers.openai` | **four field values**: base URL, no auth, no `file` content part, `max_tokens` |
| Ollama (`/api/chat`) | `ollama` | `providers.ollama` | its own codec — NDJSON, `keep_alive`, `options`, `think`, per-message `images` |

`OpenAiCompat` is a value struct with nine fields; `OpenAi`, `OpenRouter`, and `OllamaCompat` are field-less structs holding only constructors that return one. **None of the three declares a `Provider` impl, an `encode`, or a decoder** — there is one of each, and `a_configuration_is_fields_not_code` in `openai.noe` asserts it by comparing each constructor's result against a literal `OpenAiCompat`. The payoff is that a sixth compatible provider is a call:

```noeta
groq  = OpenAiCompat.at("https://api.groq.com/openai/v1", key, "groq")
vllm  = OpenAiCompat.at("http://gpu-01.internal:8000/v1", "", "vllm")
```

Two things DESIGN §2.1's table predicted and the code corrected:

- **Reasoning-token accounting is not an OpenRouter delta.** OpenRouter reports it in `usage.completion_tokens_details.reasoning_tokens` — OpenAI's own field — so the family base already reads it and OpenRouter needed no code for it.
- **Ollama's native endpoint genuinely needs its own codec**, exactly as the table's second Ollama row says. It is not a delta from `openai_compat`: `arguments` is an object rather than a string, a tool result is addressed by `tool_name` rather than by a call id, images are bare base64 on the message, sampling lives under `options` with different key names, and the stream is NDJSON. Sharing a codec with that many disagreements would have been a codec with a mode switch in it.

### Where the three families genuinely disagree

Worth knowing before writing a fourth, because each of these is a place a codec can be silently wrong:

| | Anthropic | `openai_compat` | Google | Ollama native |
| --- | --- | --- | --- | --- |
| system prompt | hoisted to `system` | a `system` message | hoisted to `systemInstruction` | a `system` message |
| assistant role | `assistant` | `assistant` | **`model`** | `assistant` |
| tool result addressed by | call id | call id | **the call's name** | **the call's name** (`tool_name`) |
| one tool turn becomes | one `user` turn | **one message per result** | one `user` turn | one message per result |
| tool arguments on the wire | a JSON object | **a JSON string** | a JSON object | a JSON object |
| "the model wants a tool" | `stop_reason: tool_use` | `finish_reason: tool_calls` | **`STOP` — derived from the parts** | **`stop` — derived from the parts** |
| tool schema dialect | JSON Schema | JSON Schema | **an OpenAPI-3.0 `Schema` subset — an unknown key is a 400** | JSON Schema |
| tools + structured output | fine (structured output *is* a forced tool) | fine | **refused by the vendor** | fine |
| stream framing | SSE | SSE | SSE (`?alt=sse`) | **NDJSON** |
| stream terminator | `message_stop` | `[DONE]`, but `finish_reason` is what means *complete* | none — `finishReason` is the only signal | `"done": true` |
| inline media | images, PDF | images, PDF | images, audio, video, PDF, text | **images only** |

The two derived stop reasons are the entries most worth staring at. Gemini and Ollama both report an ordinary "stopped" reason for a turn whose only content is a tool call, so a codec that trusted the vendor's word would end every tool loop on its first turn — with the model's request unanswered and the run reported as complete. Both codecs derive `StopReason.ToolUse` from the parts instead, and both have a test named for it.

### Every decoder is proved against a real transcript

Not against a fixture written to match the decoder — that proves nothing but its own consistency. Each codec holds verbatim published wire transcripts as raw lines and replays them frame by frame, asserting the **exact** delta list:

| codec | transcripts |
| --- | --- |
| `anthropic` | text with a `ping`; a tool call whose arguments arrive as six partial-JSON fragments; extended thinking with its signature delta; a stream that dies with `event: error` |
| `openai` | text with an `include_usage` chunk and `[DONE]`; a tool call whose id arrives once and whose arguments arrive as six fragments; an OpenRouter reasoning stream with `: OPENROUTER PROCESSING` keepalives |
| `google` | text with the cumulative `usageMetadata` repeated on every chunk and no terminator at all; a thinking-then-function-call turn whose `finishReason` is `STOP` |
| `ollama` | NDJSON text ending in `"done": true`; a thinking-then-tool-call stream whose tool call arrives **whole** in one line |


## Streaming

Three doors onto one run loop:

```noeta
agent.run_sync("What's the weather in Malmö?")?      // sync, string in, string out
agent.run(conv).await?                               // async, events discarded
agent.run_into(conv, sink).await?                    // async, events to a sink you supply
agent.stream(conv, tx).await?                        // async, events down a channel
```

```noeta
use para.ai.Event

(tx, rx) = channel::<Event>(64)
concurrent {
    reader = spawn render(rx)
    run = agent.stream(Conversation.of("Explain the Euclidean algorithm."), tx).await?
    tx.close()
    reader.await
}

async fn render(rx: Receiver<Event>): void {
    mut going = true
    while going {
        match rx.recv().await {
            some(e) => {
                match e {
                    Event.TextDelta(id, delta) => { print(delta) },
                    _ => {},
                }
            },
            none => { going = false },
        }
    }
}
```

Every `Event` variant is a value type, so a `Sender<Event>` crosses tasks **and** isolates and the whole thing composes with parallel serving. The run loop emits `RunStarted`, the text / thinking / tool-call deltas with their block starts and ends, one `ToolCallResult` per dispatched call, and **exactly one** terminal `RunFinished` or `RunError` on every path out — including the failing ones. A stream that merely stops is indistinguishable from one still thinking.

`StateSnapshot`, `StateDelta`, `StepStarted`, `StepFinished`, and `Custom` are in the enum but nothing in the loop emits one. They are for consumers to produce, and [AG-UI](#ag-ui-serving-a-run-to-a-front-end) encodes every one of them — a `StateSnapshot` a caller emits reaches a front end as `STATE_SNAPSHOT` without the loop having an opinion about what state is.

### Which layers cover which path

**This is the part to read before turning streaming on.** `std.http.client.stream` returns a `FrameStream`, and that is a type the `para/api` onion structurally cannot accept: `Retry` calls `next` again and a second call means a second body, `Cache` and `Record` would have to store one, and `Mock` answers with a whole buffered `Response`. Only `Header` and `Logging` are streaming-safe at all. So the two transports do not share a chain, and coverage is not blanket:

| | buffered (`run_sync`, and `run` by default) | streamed (`stream`, and `run` with `AgentConfig.stream`) |
| --- | --- | --- |
| Transport | `para.api.Api` — `prepare` then `send` | `std.http.client.stream` through a `Streamer` |
| Retry / `Retry-After` | `para/api`'s `Retry` middleware | **the run loop's own**, `AgentConfig.stream_retries` (2) and `stream_backoff_ms` (500, doubling) |
| `Cache`, `Record` → `to_mock()` | yes | no — they need a whole `Response` |
| `Mock` as transport | `para.api.Middleware` | `para.ai.Streamer`, replaying scripted frames |
| Vendor error status | `AiError.Provider(status, code, message)` | **see the caveat below** |
| Telemetry | identical — the `chat {model}` span and both GenAI metrics wrap either |
| Events, accumulation, tool loop | identical — one implementation |

Streaming is therefore **off by default**: `AgentConfig.stream` is `false`, so `run` and `run_sync` take the covered path, and turning it on is `cfg.streamed()` — a deliberate choice with the trade written down. `agent.stream(conv, tx)` streams regardless, because a caller who asked for events as they happen has said what they want.

### The one caveat: a streamed vendor error has no status

`client.stream` reads the response head and then hands back a reader; it exposes **no way to read the status back**. A 429 or a 400 therefore streams its JSON error body like any other body, and an SSE reader frames a plain JSON document into nothing at all — so a rate limit arrives at the decoder as an *empty stream* rather than as `AiError.Provider(429, "rate_limit_error", …)`.

What this package does about it: each codec's `finish()` refuses an empty stream with a message that names the likely cause and says the status is unavailable, so the failure is loud and points at the right thing. What it cannot do is give you the matchable `code`. The streaming retry consequently fires on transport failures and on any status a `Streamer` *can* report — which the scripted one can, and the live one cannot yet. **`FrameStream.status()` has since landed in `std.http`** — along with `ok()`, `header(name)`, and `error_for_status()`, all readable before the first `recv()` — so the gap is now on this side: `para.ai.Streamer.open` returns frames and nothing else, and surfacing the status means widening that trait and its four implementations. Until that lands, a workload that needs typed vendor errors should stay on the buffered path.

### Testing a stream

`Mock` is both transports. The middleware answers a buffered call; a `para.ai.Streamer` implementation replays scripted frames for a streamed one, derived from the same script so the two cannot drift. `Collector` is the event sink §11 asks for:

```noeta
m = Mock.new().chunked(4).reply_text("18°C and clear in Malmö.")
c = Collector.new()
run = m.agent(AgentConfig.new("test-model").streamed())
    .run_into(Conversation.of("weather?"), c).await?

assert(c.events() == [
    Event.RunStarted(run_id: c.run_id(), thread_id: ""),
    Event.TextStart(id: "0"),
    Event.TextDelta(id: "0", delta: "18°C"),
    …
    Event.TextEnd(id: "0"),
    Event.RunFinished(run_id: c.run_id(), usage: run.usage),
])
```

`chunked(n)` delivers text and tool arguments in runs of `n` characters, so a scripted stream behaves like a real one — a sentence arriving as a dozen frames. `Replay` is the lower-level door for the shapes a script cannot express: a stream that stops mid-message, or one that carries nothing at all.

## AG-UI: serving a run to a front end

[AG-UI](https://docs.ag-ui.com) is the protocol a chat front end speaks to an agent: the client posts a `RunAgentInput` — the thread, the conversation so far, its state — and reads back a server-sent event stream of what the agent is doing, token by token and tool call by tool call. `para.ai.agui` is the encoding of `Event` onto that wire, and the responder that serves it. The endpoint is one line:

```noeta
use para.ai.agui

#[Post("/agent")]
fn chat(req: Request): Response {
    return agui.respond(agent, req)
}
```

`respond` decodes the input, opens a `text/event-stream` response with **`std.http.server.sse`**, spawns the run, and drains its channel encoding each event as a frame. Nothing in it builds a response, sets a header, or manages a connection — `server.sse` is the one-way twin of `server.websocket`, so a long-lived stream is an ordinary in-flight handler to the serve loop and interleaves with other requests rather than blocking them.

**The encoding is a pure, total, variant-local mapping**: one `Event` in, one `Frame` out, no state carried between calls. That is what §11 shaped the enum for, and it is why an AG-UI bug here is a table row rather than a state machine.

| `Event` | AG-UI |
| --- | --- |
| `RunStarted` | `RUN_STARTED` `{threadId, runId}` |
| `TextStart` / `TextDelta` / `TextEnd` | `TEXT_MESSAGE_START` / `_CONTENT` / `_END` `{messageId, …}` |
| `ThinkingDelta` | `REASONING_MESSAGE_CHUNK` `{messageId, delta}` |
| `ToolCallStart` / `ToolCallArgsDelta` / `ToolCallEnd` | `TOOL_CALL_START` / `_ARGS` / `_END` `{toolCallId, …}` |
| `ToolCallResult` | `TOOL_CALL_RESULT` `{messageId, toolCallId, content, role}` |
| `StateSnapshot` / `StateDelta` | `STATE_SNAPSHOT` `{snapshot}` / `STATE_DELTA` `{delta}` |
| `StepStarted` / `StepFinished` | `STEP_STARTED` / `STEP_FINISHED` `{stepName}` |
| `RunFinished` | `RUN_FINISHED` `{threadId, runId, result, outcome}` |
| `RunError` | `RUN_ERROR` `{message, code}` |
| `Custom` | `CUSTOM` `{name, value}` |

Four rows are decisions rather than transcription, and the source says so at each:

- **A thinking delta is a `REASONING_MESSAGE_CHUNK`.** AG-UI's streaming reasoning message is bracketed by four other events; `Event.ThinkingDelta` has no start or end, deliberately. The `*_CHUNK` form is self-delimiting — the first chunk with a `messageId` implicitly opens the message and the next non-reasoning event closes it — so the bracket is the client's to synthesize and the mapping stays one-to-one. (`THINKING_*` is the older spelling, deprecated in favor of `REASONING_*` and removed in AG-UI 1.0.)
- **A `ToolCallResult`'s `messageId` is its call id with `-result` appended.** AG-UI's event carries two ids where `Event` carries one; deriving the first from the second keeps it stable and collision-free, and it is what the protocol's own Claude Agent SDK integration does.
- **`is_error` rides in `rawEvent`, and only when true.** `TOOL_CALL_RESULT` has no error field at all, so a failing tool would otherwise be indistinguishable from a succeeding one. `rawEvent` is the protocol's documented escape hatch; the alternative in the wild is to rewrite `content` into `{"error": true, "content": …}`, which corrupts the payload the model actually saw.
- **`RunFinished` carries its usage under `result`.** `result` is `any` in the protocol, and the run's token usage is the only thing the event carries besides the run id.

**The two AG-UI facts that are easy to get wrong** are handled explicitly and asserted from both ends. A `RunError` is a **frame**, not a dropped connection — the run loop emits one on every failing path, and the responder drains its channel to exhaustion so the run cannot outrun its reader. And every stream ends with **exactly one** terminal `RUN_FINISHED` or `RUN_ERROR`.

A body that is not a `RunAgentInput` is a `400` naming the reason rather than a stream: AG-UI requires every stream to open with `RUN_STARTED`, which carries a thread id and a run id, and a body that did not decode has neither. Everything that goes wrong *after* that point is a `RUN_ERROR` frame, because by then there is a run to report on.

`RunAgentInput.threadId` and `runId` reach the run itself — `agent.stream(conv, tx, thread_id, run_id)` takes both, defaulted — so the events a client reads carry the identifiers that client sent, and the run's `para.ai.run.id` span attribute correlates a trace with the caller's own record.

`decode_input` also hands back `state`, `forwardedProps`, `context`, and the client's own `tools`. `state` and `forwardedProps` stay **raw JSON text**, because they are `any` in the protocol and text is the representation that survives a round trip byte for byte — the same form `Event.StateSnapshot(json)` takes, so echoing state back is `Event`'s own vocabulary rather than a conversion. `respond_to(agent, input)` is the door for a caller who wants to read any of them before the run starts.

### Testing an AG-UI stream

`stream_sync` drives the **same** session `respond` hands to the serve loop, writing into a `Tape` instead of a socket. So the exact frames a browser would have received are a `@test` block with no port and no key:

```noeta
tape = agui.Tape.new()
n = agui.stream_sync(agent, agui.RunInput { thread_id: "t7", run_id: "r7", messages: [Message.user("shout hej")] }, tape)

assert(tape.payloads()[0] == "{\"runId\":\"r7\",\"threadId\":\"t7\",\"type\":\"RUN_STARTED\"}")
assert(tape.wire().starts_with("data: " ~ tape.payloads()[0] ~ "\n\n"))
```

`Tape.payloads()` is the JSON documents a client would have parsed; `Tape.wire()` is the bytes, so the SSE framing is assertable too, and `wire_of(frame)` mirrors std's own encoder for a single frame. Between `mock.Collector` and `agui.Tape` a streaming bug has nowhere to hide: the first catches a wrong event, the second a wrong encoding of a right one, and `wire()` a wrong framing of a right encoding.

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

`m.with_cache_reads(n)` scripts what a vendor reports about its prompt cache — a scripted transport has no cache of its own, so the figure is declared rather than earned, and what it demonstrates is that a vendor's number reaches `Run.usage` and `gen_ai.usage.cached_input_tokens`. A request's `cache_breakpoint` is rendered into the mock's own flat request JSON, so a test can watch the marker reach the wire without a vendor's dialect.

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
    Mcp(server: string, code: string, message: string)    // an MCP server failed as a server
    MaxTurns(turns: int)                              // the run exceeded AgentConfig.max_turns
    ContextOverflow(needed: int, budget: int)         // phase 5
    Cancelled
}
```

A language constraint shapes this: **a type carries at most one `From` impl** (a second is a coherence conflict). So `AiError` declares `impl From<HttpError>` — the conversion that appears at the most `?` sites — and `JsonError` is mapped explicitly at its handful of decode points into `Decode(path, message)`, preserving the path. That is a decision, not an omission.

The `para/api` line holds: `Err` means the call failed, while an HTTP error *status* from a vendor is an answer. The same line runs through `Tool`: a tool that merely *fails* is not an `AiError` at all — it is a `ToolResult(is_error: true)` turn the model can recover from. `AiError.Tool` is for what the model cannot be asked to fix: an underivable schema, a name collision across sources, a source that could not be listed.

`AiError.Mcp` draws the same line one layer down. A *tool* that fails on an MCP server is `Tool(name, message)`, exactly as a local one is, so the model gets its recoverable turn either way; `Mcp(server, code, message)` is the server failing *as a server* — it would not start, it exited, it broke the protocol, it was asked for a capability it never advertised, or its session expired. `code` is drawn from a fixed set (`spawn`, `server_exited`, `eof`, `timeout`, `protocol`, `capability`, `http_status`, `session_expired`, `read_budget`, `closed`, `sampling`), so `error.type` stays a class rather than a message.

`Guard(stage, guard, reason)` joins the enum in phase 5, with the types it names.

## Telemetry

Telemetry is not a module. The run loop emits onto `std.tracing`/`std.metrics` directly, so it cannot be forgotten: nothing when no endpoint is set, everything when one is, and no configuration API of our own. Point `OTEL_EXPORTER_OTLP_ENDPOINT` at a collector and traces appear.

Following the OpenTelemetry **GenAI semantic conventions, v1.37.0**:

| span | attributes |
| --- | --- |
| `invoke_agent {agent}` | `gen_ai.operation.name`, `gen_ai.agent.name`, `gen_ai.provider.name`, `gen_ai.request.model`, aggregate `gen_ai.usage.*`, `gen_ai.response.finish_reasons`, `para.ai.run.turns` |
| `chat {model}` | `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.request.max_tokens`, `gen_ai.request.temperature`, `gen_ai.response.model`, `gen_ai.response.finish_reasons`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.cached_input_tokens` |
| `execute_tool {name}` | `gen_ai.operation.name`, `gen_ai.tool.name`, `gen_ai.tool.call.id`, `gen_ai.tool.type` (`function` / `mcp`) |

| metric | kind | attributes |
| --- | --- | --- |
| `gen_ai.client.token.usage` | histogram | `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.token.type` |
| `gen_ai.client.operation.duration` | histogram (seconds) | the same, plus `error.type` on a failure |
| `para.ai.tool.calls` | counter | `gen_ai.tool.name`, `para.ai.tool.outcome` (`ok` / `error`) |

`gen_ai.usage.cached_input_tokens` is set **only when a vendor reported a cache read** — on both the `chat` span and the aggregate on `invoke_agent`. `Usage.cached_input_tokens` is `0` both for "the cache missed" and for "this vendor does not report it", and those are not the same claim, so the attribute's *presence* is what means "served from the cache". It is a subset of `gen_ai.usage.input_tokens`, never an addition.

`para.ai.guard.denials` arrives with phase 5.

**Tool dispatch is instrumented in the run loop, not at the tool.** A `#[Tool]` function contains zero telemetry code and still shows up as a span of the model call that requested it, with its outcome on the counter. That is the whole reason dispatch is the instrumentation point.

Three commitments:

- **Message content is off by default.** Prompts and completions in spans are a privacy and compliance hazard. Opt in with `OTEL_GENAI_CAPTURE_MESSAGES=true`, matching the OTel convention rather than inventing a knob.
- **No high-cardinality metric attributes.** `error.type` is the error's *class* (`rate_limit_error`, `decode`, `timeout`) and never its message; no user ids, no thread ids, no prompt text.
- **The semconv version is pinned and stated** — right here. GenAI conventions are still moving, and a package that claims "OTel support" without naming a version is claiming nothing.

## What the run loop does today

`run(conv)` calls the model, and keeps calling while the model asks for tools — see [The loop](#the-loop) above for the shape and the three decisions in it. The four guard stages hang off the same loop; the context strategy is the one step still to come.

`run`, `run_into`, and `stream` are `async`; `run_sync` is not. That is deliberate in both directions: streaming makes the loop genuinely async, while `run_sync(text) -> Result<string, AiError>` stays synchronous because a plain string-in/string-out entry point is what makes a framework testable from an ordinary `fn`. There is still only **one** loop — `run_sync` drives the async one to completion rather than duplicating it, and a second, synchronous copy is exactly where a divergence would live.

## Examples

- [`examples/ask/`](examples/ask) — one question, one answer: the runtime-provider `match`, the config/agent split, and a hermetic `@test` block over `Mock`.
- [`examples/tools/`](examples/tools) — a full multi-turn tool loop: two `#[Tool]` functions, a scripted parallel tool turn, the exact derived JSON Schema, a failing tool that becomes a recoverable turn, and the `roles_of::<Semantic>()` query. Hermetic, no key.
- [`examples/memory/`](examples/memory) — **memory as an MCP server**: a sixty-line POSIX-shell memory server the example spawns over stdio, an agent whose entire tool vocabulary came from that subprocess, and a fact that survives between runs because it left the process. Declares no `#[Tool]` of its own, and a test asserts that from the trust-boundary index. Hermetic, no key, no npm install.
- [`examples/prompt_cache/`](examples/prompt_cache) — a `@prompt` system prompt with a stable preamble and a per-customer tail: the exact statics/holes decomposition, a recall that proves reading the cache prefix never evaluated it, and the encoded Anthropic body with `cache_control` on the stable block and nowhere else. Hermetic, no key.

- [`examples/structured/`](examples/structured) — **`extract::<T>` end to end**: a struct with a `Validate` invariant, the exact JSON Schema derived from its five field declarations, a first answer that breaks the invariant and a second that is accepted after the invariant's own message goes back as the correction, and a guard that denies an input before any model call. Hermetic, no key.
- [`examples/agui/`](examples/agui) — **an AG-UI server**: `server.sse` behind a plain `(Request) -> Response` router, the endpoint as one line, and a hermetic `@test` block asserting the exact frame sequence of a tool-calling run and of a failing one through `agui.stream_sync`. No port, no key.
- [`examples/providers/`](examples/providers) — five vendors, three codec families, one program: the runtime-selection `match` at six arms, the whole run loop driven over each real codec from a captured vendor body (buffered through `para/api`'s `Mock`, streamed through `Replay`) — and **two live checks against a local Ollama**, which skip when none is running and are made un-skippable in CI by `OLLAMA_REQUIRED=1`. They are the only tests in the repo that open a socket, so they are also the only ones carrying a deadline — `OLLAMA_TIMEOUT_MS` (default 120 s) and no retry layer, because a suite that can wait forever reports nothing when something goes wrong. `OLLAMA_MODEL` defaults to `qwen3:0.6b`, matching CI, and a thinking-capable model is asked not to think: a token budget spent entirely on reasoning produces an empty answer, which is honest and is not what these checks are asking about.

The design's remaining example (`chat-cli`) arrives with the phase it exercises; `structured` is `examples/structured` above and `agui-server` is `examples/agui`; `local-ollama` is folded into `examples/providers` above, since the example that selects a provider at runtime is already the one that has an Ollama to talk to.

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
