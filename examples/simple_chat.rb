#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple chat example / シンプルなチャット例
#
# Usage / 使い方:
#   cd llm-providers
#   ANTHROPIC_API_KEY=your-key ruby examples/simple_chat.rb
#   OPENAI_API_KEY=your-key ruby examples/simple_chat.rb openai
#   GOOGLE_API_KEY=your-key ruby examples/simple_chat.rb google
#   OPENROUTER_API_KEY=your-key ruby examples/simple_chat.rb openrouter meta-llama/llama-3.3-70b-instruct

require "bundler/setup"
require "llm_providers"

# Configure logger (optional) / ロガー設定（任意）
LlmProviders.configure do |config|
  config.logger = Logger.new($stderr, level: Logger::WARN)
end

# Select provider and model from command line / コマンドラインからプロバイダー・モデル選択
provider_name = ARGV[0] || "anthropic"
model_name = ARGV[1]

# Build provider / プロバイダーを構築
options = { temperature: 0.7, max_tokens: 1024 }
options[:model] = model_name if model_name
provider = LlmProviders::Providers.build(provider_name, **options)

puts "=== LlmProviders Simple Chat ==="
puts "Provider: #{provider_name}#{model_name ? " (#{model_name})" : ""}"
puts "Type 'exit' to quit / 'exit' で終了"
puts

messages = []

loop do
  print "You: "
  input = $stdin.gets&.chomp
  break if input.nil? || input == "exit"
  next if input.empty?

  messages << { role: "user", content: input }

  print "Assistant: "

  # Streaming response / ストリーミングレスポンス
  response = provider.chat(
    messages: messages,
    system: "You are a helpful assistant. Be concise."
  ) do |chunk|
    print chunk[:content] if chunk[:content]
  end

  puts
  puts "(tokens: in=#{response[:usage][:input]}, out=#{response[:usage][:output]}, #{response[:latency_ms]}ms)"
  puts

  messages << { role: "assistant", content: response[:content] }
end

puts "Bye!"
