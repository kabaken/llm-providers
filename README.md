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
  temperature: 0.7,
  max_tokens: 4096
)
```

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
