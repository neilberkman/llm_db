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
    filters: %{
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
{:ok, snapshot} = LLMDb.reload()
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

Get capability keys for filtering:

```elixir
LLMDb.capabilities(model)
# => [:chat, :tools, :json_native, :streaming_text, ...]

LLMDb.capabilities({:openai, "gpt-4"})
LLMDb.capabilities("openai:gpt-4")
```

## Model Selection

Select models by requirements:

```elixir
# Basic requirements
models = LLMDb.select(require: [tools: true])

models = LLMDb.select(
  require: [json_native: true, chat: true]
)

# Forbid capabilities
models = LLMDb.select(
  require: [tools: true],
  forbid: [streaming_tool_calls: true]
)

# Provider preference
models = LLMDb.select(
  require: [chat: true],
  prefer: [:anthropic, :openai]
)

# Scope to provider
models = LLMDb.select(
  require: [tools: true],
  scope: :openai
)

# Combined
models = LLMDb.select(
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
    filters: %{
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
- Empty allow map denies all unless explicitly allowed
- `:all` allows all models from provider
- Patterns: exact strings or globs with `*`

### Check Availability

```elixir
LLMDb.allowed?(:openai, "gpt-4")           # => true
LLMDb.allowed?(:openai, "gpt-4-deprecated") # => false
```

## Spec Parsing

```elixir
# Parse provider
{:ok, :openai} = LLMDb.Spec.parse_provider("openai")
LLMDb.Spec.parse_provider("unknown")  # => {:error, :unknown_provider}

# Parse spec
{:ok, {:openai, "gpt-4"}} = LLMDb.Spec.parse_spec("openai:gpt-4")
LLMDb.Spec.parse_spec("invalid")  # => {:error, :invalid_spec}

# Resolve (handles Bedrock inference profiles)
{:ok, {:openai, "gpt-4"}} = LLMDb.Spec.resolve("openai:gpt-4", snapshot)

{:ok, {:bedrock, "us.anthropic.claude-3-sonnet-20240229-v1:0"}} =
  LLMDb.Spec.resolve("bedrock:us.anthropic.claude-3-sonnet-20240229-v1:0", snapshot)
```

## Runtime Overrides

Runtime overrides **only** affect filters and preferences, not provider/model data.

```elixir
{:ok, _} = LLMDb.load(
  runtime_overrides: %{
    filters: %{allow: %{openai: ["gpt-4"]}, deny: %{}},
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
models = LLMDb.select(
  require: [json_native: true],
  forbid: [streaming_tool_calls: true],
  prefer: [:openai]
)
model = List.first(models)
```

### List Anthropic models with tools

```elixir
models = LLMDb.select(require: [tools: true], scope: :anthropic)
Enum.each(models, fn m -> IO.puts("#{m.id}: #{m.name}") end)
```

### Check spec availability

```elixir
case LLMDb.model("openai:gpt-4") do
  {:ok, model} ->
    if LLMDb.allowed?(model.provider, model.id) do
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
models = LLMDb.select(require: [chat: true, tools: true])

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
