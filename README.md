# LlmProviders

[![Gem Version](https://badge.fury.io/rb/llm_providers.svg)](https://rubygems.org/gems/llm_providers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.txt)

A lightweight, unified interface for multiple LLM providers. Only depends on `faraday` — no ActiveSupport required.

[日本語版 README](README.ja.md)

## Features

- **Lightweight** — Single dependency (`faraday`), no ActiveSupport
- **Unified interface** — Same API for all providers
- **Streaming** — Real-time token streaming with block syntax
- **Tool calling** — Consistent tool/function calling across providers
- **Token tracking** — Usage stats (input, output, cached) in every response

## Supported Providers

| Provider | ENV Variable | Default Model |
|----------|-------------|---------------|
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-sonnet-4-5-20250929` |
| `openai` | `OPENAI_API_KEY` | `gpt-5-mini` |
| `google` | `GOOGLE_API_KEY` | `gemini-2.5-flash` |
| `openrouter` | `OPENROUTER_API_KEY` | `anthropic/claude-sonnet-4.5` |

## Installation

Add to your Gemfile:

```ruby
gem "llm_providers"
```

## Quick Start

```ruby
require "llm_providers"

provider = LlmProviders::Providers.build(:anthropic)

# Synchronous
result = provider.chat(
  messages: [{ role: "user", content: "Hello!" }],
  system: "You are a helpful assistant."
)
puts result[:content]

# Streaming
provider.chat(messages: [{ role: "user", content: "Hello!" }]) do |chunk|
  print chunk[:content]
end
```

## Usage

### Configuration

```ruby
LlmProviders.configure do |config|
  config.logger = Rails.logger  # or any Logger instance
end
```

### Provider Options

```ruby
provider = LlmProviders::Providers.build(
  :openai,
  model: "gpt-4.1",
  temperature: 0.7,   # optional; defaults to nil (not sent)
  max_tokens: 4096,
  effort: "medium"    # optional; "low", "medium", "high", "xhigh" or "max"
)
```

- `temperature` defaults to `nil` and is sent only when you set it. Versions up to 0.2.x always sent 0.7. Claude 5.x and OpenAI reasoning models reject the parameter.
- `effort` sets how hard the model thinks (`nil` means the provider default). Any other value raises `ArgumentError`.
  - Anthropic: sent as `output_config: { effort: ... }`.
  - OpenAI: sent as `reasoning_effort`. `gpt-6*` gets the value unchanged; older reasoning models (gpt-5*, o-series) get `xhigh` / `max` clamped to `high`. Ignored for `gpt-3.5*` / `gpt-4*`.
  - Google: mapped to `thinkingConfig.thinkingLevel` (low, medium, high; xhigh and max become high).
  - OpenRouter: not forwarded for now.
- OpenAI treats every model except `gpt-3.5*` / `gpt-4*` as a reasoning model: it uses `max_completion_tokens` and sends no temperature. OpenRouter ids look like `vendor/model`, so it keeps using `max_tokens` and sends temperature only when given.
- For Google, usage `output` includes thinking tokens.

### Tool Calling

```ruby
tools = [
  {
    name: "get_weather",
    description: "Get the current weather",
    parameters: {
      type: "object",
      properties: {
        location: { type: "string", description: "City name" }
      },
      required: ["location"]
    }
  }
]

result = provider.chat(
  messages: [{ role: "user", content: "What's the weather in Tokyo?" }],
  tools: tools
)

result[:tool_calls].each do |tc|
  puts "#{tc[:name]}: #{tc[:input]}"
end
```

### Response Format

Every `chat` call returns a hash with:

```ruby
{
  content: "Response text",
  tool_calls: [
    { id: "...", name: "...", input: {...} }
  ],
  usage: {
    input: 100,           # Input tokens
    output: 50,           # Output tokens
    cached_input: 80      # Cached input tokens (Anthropic only)
  },
  latency_ms: 1234,
  raw_response: {...}
}
```

### OpenRouter

OpenRouter gives you access to 300+ models through a single API — ideal for providers not directly supported by this gem (DeepSeek, Meta Llama, Mistral, Qwen, etc.).

```ruby
provider = LlmProviders::Providers.build(
  :openrouter,
  model: "deepseek/deepseek-chat",
  app_name: "MyApp",
  app_url: "https://myapp.example.com",
  provider: { order: ["DeepSeek", "Together"], allow_fallbacks: true }
)

# List available models
models = LlmProviders::Providers::Openrouter.models
models.each { |m| puts "#{m[:id]} (ctx: #{m[:context_length]})" }
```

### Error Handling

```ruby
begin
  result = provider.chat(messages: messages)
rescue LlmProviders::ProviderError => e
  puts "Error: #{e.message}"  # OpenRouter: "[DeepSeek] Model is unavailable"
  puts "Code: #{e.code}"      # e.g., "anthropic_error", "openrouter_error"
end
```

## Examples

```bash
# Interactive chat
ANTHROPIC_API_KEY=your-key ruby examples/simple_chat.rb

# One-shot
ANTHROPIC_API_KEY=your-key ruby examples/one_shot.rb "Hello!"

# With tools
ANTHROPIC_API_KEY=your-key ruby examples/with_tools.rb

# Other providers
OPENAI_API_KEY=your-key ruby examples/simple_chat.rb openai
GOOGLE_API_KEY=your-key ruby examples/simple_chat.rb google

# OpenRouter (DeepSeek, Llama, Mistral, etc.)
OPENROUTER_API_KEY=your-key ruby examples/simple_chat.rb openrouter deepseek/deepseek-chat
OPENROUTER_API_KEY=your-key ruby examples/with_tools.rb openrouter meta-llama/llama-3.3-70b-instruct
```

## License

MIT
