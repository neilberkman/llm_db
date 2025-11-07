#!/usr/bin/env elixir

# Test script to verify LLMDb catalog loads automatically on application start

# Ensure all dependencies are on the code path
Path.wildcard("_build/dev/lib/*/ebin")
|> Enum.each(&Code.prepend_path/1)

IO.puts("Starting LLMDb application...")

# Start the application
result = Application.ensure_all_started(:llm_db)
case result do
  {:ok, _} -> :ok
  {:error, reason} ->
    IO.puts("✗ Failed to start application: #{inspect(reason)}")
    System.halt(1)
end

IO.puts("✓ Application started")

# Test 1: Verify snapshot is loaded
IO.puts("\nTest 1: Snapshot loaded?")
snapshot = LLMDb.snapshot()
if snapshot != nil do
  IO.puts("✓ Snapshot is loaded")
else
  IO.puts("✗ FAIL: Snapshot is nil")
  System.halt(1)
end

# Test 2: Query a model without calling load()
IO.puts("\nTest 2: Query model without explicit load()")
case LLMDb.model("openai:gpt-4o-mini") do
  {:ok, model} ->
    IO.puts("✓ Successfully retrieved: #{model.id}")
    IO.puts("  Provider: #{model.provider}")
    IO.puts("  Name: #{model.name}")
  {:error, reason} ->
    IO.puts("✗ FAIL: #{inspect(reason)}")
    System.halt(1)
end

# Test 3: Get all providers
IO.puts("\nTest 3: Get all providers")
providers = LLMDb.provider()
if length(providers) > 0 do
  IO.puts("✓ Found #{length(providers)} providers:")
  Enum.each(providers, fn p -> IO.puts("  - #{p.id}") end)
else
  IO.puts("✗ FAIL: No providers found")
  System.halt(1)
end

# Test 4: Select a model
IO.puts("\nTest 4: Select a model with requirements")
case LLMDb.select(require: [chat: true, tools: true], prefer: [:openai]) do
  {:ok, {provider, model_id}} ->
    IO.puts("✓ Selected: #{provider}:#{model_id}")
  {:error, reason} ->
    IO.puts("✗ FAIL: #{inspect(reason)}")
    System.halt(1)
end

# Test 5: Model struct API support
IO.puts("\nTest 5: Model struct API support")
case LLMDb.model("openai:gpt-4o-mini") do
  {:ok, model} ->
    # Test allowed? with Model struct
    if LLMDb.allowed?(model) do
      IO.puts("✓ allowed?(model) works")
    else
      IO.puts("✗ FAIL: allowed?(model) returned false")
      System.halt(1)
    end
    
    # Test capabilities with Model struct
    caps = LLMDb.capabilities(model)
    if caps != nil and caps.chat == true do
      IO.puts("✓ capabilities(model) works")
    else
      IO.puts("✗ FAIL: capabilities(model) failed")
      System.halt(1)
    end
  {:error, reason} ->
    IO.puts("✗ FAIL: Could not retrieve model: #{inspect(reason)}")
    System.halt(1)
end

IO.puts("\n✓ All tests passed! Catalog loaded automatically on startup.")
