#!/usr/bin/env ruby
# frozen_string_literal: true

# One-shot example (no streaming) / ワンショット例（ストリーミングなし）
#
# Usage / 使い方:
#   cd llm-providers
#   ANTHROPIC_API_KEY=your-key ruby examples/one_shot.rb "Hello!"
#   OPENAI_API_KEY=your-key ruby examples/one_shot.rb "Hello!" openai

require "bundler/setup"
require "llm_providers"

message = ARGV[0] || "Say hello in Japanese"
provider_name = ARGV[1] || "anthropic"

provider = LlmProviders::Providers.build(provider_name, max_tokens: 256)

result = provider.chat(
  messages: [{ role: "user", content: message }],
  system: "Be concise."
)

puts result[:content]
puts
puts "---"
puts "Provider: #{provider_name}"
puts "Tokens: input=#{result[:usage][:input]}, output=#{result[:usage][:output]}"
puts "Latency: #{result[:latency_ms]}ms"
