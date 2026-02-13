#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple chat example / シンプルなチャット例
#
# Usage / 使い方:
#   cd llm-providers
#   ANTHROPIC_API_KEY=your-key ruby examples/simple_chat.rb
#   OPENAI_API_KEY=your-key ruby examples/simple_chat.rb openai
#   GOOGLE_API_KEY=your-key ruby examples/simple_chat.rb google

require "bundler/setup"
require "llm_providers"

# Configure logger (optional) / ロガー設定（任意）
LlmProviders.configure do |config|
  config.logger = Logger.new($stderr, level: Logger::WARN)
end

# Select provider from command line / コマンドラインからプロバイダー選択
provider_name = ARGV[0] || "anthropic"

puts "=== LlmProviders Simple Chat ==="
puts "Provider: #{provider_name}"
puts "Type 'exit' to quit / 'exit' で終了"
puts

# Build provider / プロバイダーを構築
provider = LlmProviders::Providers.build(
  provider_name,
  temperature: 0.7,
  max_tokens: 1024
)

messages = []

loop do
  print "You: "
  input = gets&.chomp
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
