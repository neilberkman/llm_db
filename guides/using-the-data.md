# Using the Data

Query, filter, and access LLM model metadata at runtime.

## Loading

### Initial Load

```elixir
# Defaults
{:ok, snapshot} = LLMDb.load()

# Runtime overrides
{:ok, snapshot} = LLMDb.load(
  runtime_overrides: %{
    filter: %{
      allow: %{openai: :all, anthropic: ["claude-3*"]},
      deny: %{openai: ["*-deprecated"]}
    },
    prefer: [:anthropic, :openai]
  }
)
```

**Steps**:
1. Loads `LLMDb.Packaged.snapshot()` from `priv/llm_db/snapshot.json`
2. Normalizes IDs to atoms
3. Compiles filter patterns
4. Builds indexes (providers_by_id, models_by_key)
5. Applies runtime overrides
6. Stores in `:persistent_term` with epoch

### Reload

```elixir
# Reload with default configuration
{:ok, snapshot} = LLMDb.load()

# Reload with new runtime overrides
{:ok, snapshot} = LLMDb.load(runtime_overrides: %{filter: %{allow: :all, deny: %{}}})
```

### Storage

Stored in `:persistent_term` for O(1) lock-free reads, process-local caching, and epoch-based cache invalidation.

```elixir
LLMDb.epoch()           # => 1
LLMDb.snapshot()        # => %{providers: %{...}, ...}
```

## Listing and Lookup

### Providers

```elixir
# All providers
providers = LLMDb.providers()
# => [%LLMDb.Provider{id: :openai, ...}, ...]

# Specific provider
{:ok, provider} = LLMDb.provider(:openai)
LLMDb.provider(:unknown)  # => :error
```

### Models

```elixir
# All models
models = LLMDb.models()

# Models by provider
openai_models = LLMDb.models(:openai)

# Specific model
{:ok, model} = LLMDb.model(:openai, "gpt-4")
LLMDb.model(:openai, "unknown")  # => {:error, :not_found}

# From spec string
{:ok, model} = LLMDb.model("openai:gpt-4")
```

### Alias Resolution

Aliases auto-resolve:

```elixir
{:ok, model} = LLMDb.model(:openai, "gpt4")
# => {:ok, %LLMDb.Model{id: "gpt-4", ...}}

{:ok, model} = LLMDb.model("openai:gpt4")
```

## Capabilities

Get capabilities map for a model:

```elixir
{:ok, model} = LLMDb.model("openai:gpt-4o-mini")
LLMDb.capabilities(model)
# => %{chat: true, tools: %{enabled: true, ...}, json: %{native: true, ...}, ...}

LLMDb.capabilities({:openai, "gpt-4o-mini"})
# => %{chat: true, tools: %{enabled: true, ...}, ...}

LLMDb.capabilities("openai:gpt-4o-mini")
# => %{chat: true, ...}
```

## Model Selection

Select models by capability requirements:

```elixir
# Select first match
{:ok, {provider, id}} = LLMDb.select(require: [tools: true])

{:ok, {provider, id}} = LLMDb.select(
  require: [json_native: true, chat: true]
)

# Get all matches
specs = LLMDb.candidates(require: [tools: true])
# => [{:openai, "gpt-4o"}, {:openai, "gpt-4o-mini"}, ...]

# Forbid capabilities
{:ok, {provider, id}} = LLMDb.select(
  require: [tools: true],
  forbid: [streaming_tool_calls: true]
)

# Provider preference (uses configured prefer as default, or override)
{:ok, {provider, id}} = LLMDb.select(
  require: [chat: true],
  prefer: [:anthropic, :openai]
)

# Scope to provider
{:ok, {provider, id}} = LLMDb.select(
  require: [tools: true],
  scope: :openai
)

# Combined - select first match
{:ok, {provider, id}} = LLMDb.select(
  require: [chat: true, json_native: true, tools: true],
  forbid: [streaming_tool_calls: true],
  prefer: [:openai, :anthropic],
  scope: :all
)

# Combined - get all matches
specs = LLMDb.candidates(
  require: [chat: true, json_native: true, tools: true],
  forbid: [streaming_tool_calls: true],
  prefer: [:openai, :anthropic],
  scope: :all
)
```

## Allow/Deny Filters

### Runtime Filters

```elixir
{:ok, _} = LLMDb.load(
  runtime_overrides: %{
    filter: %{
      allow: %{
        openai: ["gpt-4*", "gpt-3.5*"],  # Globs
        anthropic: :all
      },
      deny: %{
        openai: ["*-deprecated"]
      }
    }
  }
)
```

**Rules**:
- Deny wins over allow
- Empty allow map `%{}` behaves like `:all` (allows all)
- `:all` allows all models from provider
- Patterns: exact strings, globs with `*`, or Regex `~r//`
- Unknown providers in filters are warned and ignored

### Check Availability

```elixir
LLMDb.allowed?("openai:gpt-4")               # => true
LLMDb.allowed?({:openai, "gpt-4"})           # => true
LLMDb.allowed?("openai:gpt-4-deprecated")    # => false

{:ok, model} = LLMDb.model("openai:gpt-4")
LLMDb.allowed?(model)                        # => true
```

## Spec Parsing

```elixir
# Parse spec string to {provider, id} tuple
{:ok, {:openai, "gpt-4"}} = LLMDb.parse("openai:gpt-4")
{:ok, {:anthropic, "claude-3-5-sonnet-20241022"}} = LLMDb.parse("anthropic:claude-3-5-sonnet-20241022")
LLMDb.parse("invalid")  # => {:error, :invalid_spec}

# Parse also accepts tuples (passthrough)
{:ok, {:openai, "gpt-4"}} = LLMDb.parse({:openai, "gpt-4"})

# Advanced: Use LLMDb.Spec for additional functionality
{:ok, :openai} = LLMDb.Spec.parse_provider("openai")
LLMDb.Spec.parse_provider("unknown")  # => {:error, :unknown_provider}

{:ok, {:openai, "gpt-4"}} = LLMDb.Spec.parse_spec("openai:gpt-4")
```

## Runtime Overrides

Runtime overrides **only** affect filters and preferences, not provider/model data.

```elixir
{:ok, _} = LLMDb.load(
  runtime_overrides: %{
    filter: %{allow: %{openai: ["gpt-4*"]}, deny: %{}},
    prefer: [:openai]
  }
)
```

Triggers `LLMDb.Runtime.apply/2`:
1. Recompiles filter patterns
2. Rebuilds indexes (excludes filtered models)
3. Stores snapshot with epoch + 1

## Recipes

### Pick JSON-native model, prefer OpenAI, forbid streaming tool calls

```elixir
{:ok, {provider, id}} = LLMDb.select(
  require: [json_native: true],
  forbid: [streaming_tool_calls: true],
  prefer: [:openai]
)
{:ok, model} = LLMDb.model({provider, id})
```

### List Anthropic models with tools

```elixir
specs = LLMDb.candidates(require: [tools: true], scope: :anthropic)
Enum.each(specs, fn {provider, id} ->
  {:ok, model} = LLMDb.model({provider, id})
  IO.puts("#{model.id}: #{model.name}")
end)
```

### Check spec availability

```elixir
case LLMDb.model("openai:gpt-4") do
  {:ok, model} ->
    if LLMDb.allowed?(model) do
      IO.puts("✓ Available: #{model.name}")
    else
      IO.puts("✗ Filtered by allow/deny")
    end
  {:error, :not_found} ->
    IO.puts("✗ Not in catalog")
end
```

### Find cheapest model with capabilities

```elixir
specs = LLMDb.candidates(require: [chat: true, tools: true])

models = 
  for {provider, id} <- specs,
      {:ok, model} <- [LLMDb.model({provider, id})],
      do: model

cheapest = 
  models
  |> Enum.filter(& &1.cost != nil)
  |> Enum.min_by(& &1.cost.input + &1.cost.output, fn -> nil end)

if cheapest do
  IO.puts("#{cheapest.provider}:#{cheapest.id}")
  IO.puts("$#{cheapest.cost.input}/M in + $#{cheapest.cost.output}/M out")
end
```

### Get vision models

```elixir
models = 
  LLMDb.models()
  |> Enum.filter(fn m -> :image in (m.modalities.input || []) end)
```

## Diagnostics

```elixir
LLMDb.epoch()                         # => 1
snapshot = LLMDb.snapshot()
LLMDb.providers() |> length()
LLMDb.models() |> length()
```

## Next Steps

- **[Schema System](schema-system.md)**: Data structures
- **[Release Process](release-process.md)**: Snapshot-based releases
