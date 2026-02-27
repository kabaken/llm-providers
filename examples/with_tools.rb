#!/usr/bin/env ruby
# frozen_string_literal: true

# Tool calling example / ツール呼び出し例
#
# Usage / 使い方:
#   cd llm-providers
#   ANTHROPIC_API_KEY=your-key ruby examples/with_tools.rb
#   OPENROUTER_API_KEY=your-key ruby examples/with_tools.rb openrouter meta-llama/llama-3.3-70b-instruct

require "bundler/setup"
require "llm_providers"

provider_name = ARGV[0] || "anthropic"
model_name = ARGV[1]

tools = [
  {
    name: "get_weather",
    description: "Get the current weather for a location",
    parameters: {
      type: "object",
      properties: {
        location: { type: "string", description: "City name (e.g., Tokyo, London)" },
        unit: { type: "string", enum: %w[celsius fahrenheit], description: "Temperature unit" }
      },
      required: ["location"]
    }
  },
  {
    name: "get_time",
    description: "Get the current time for a timezone",
    parameters: {
      type: "object",
      properties: {
        timezone: { type: "string", description: "Timezone (e.g., Asia/Tokyo, UTC)" }
      },
      required: ["timezone"]
    }
  }
]

# Fake tool implementation / ダミーのツール実装
def execute_tool(name, input)
  case name
  when "get_weather"
    "#{input["location"]}: Sunny, 22#{input["unit"] == "fahrenheit" ? "F" : "C"}"
  when "get_time"
    "#{input["timezone"]}: #{Time.now.utc}"
  else
    "Unknown tool"
  end
end

options = { max_tokens: 1024 }
options[:model] = model_name if model_name
provider = LlmProviders::Providers.build(provider_name, **options)

messages = [
  { role: "user", content: "What's the weather in Tokyo and what time is it there?" }
]

puts "=== Tool Calling Example ==="
puts "Provider: #{provider_name}#{model_name ? " (#{model_name})" : ""}"
puts "User: #{messages.first[:content]}"
puts

# First call - may return tool calls
# 最初の呼び出し - ツール呼び出しを返す可能性あり
response = provider.chat(messages: messages, tools: tools)

if response[:tool_calls].any?
  puts "Tool calls requested:"
  response[:tool_calls].each do |tc|
    puts "  - #{tc[:name]}(#{tc[:input]})"
  end
  puts

  # Add assistant message with tool calls
  # ツール呼び出しを含むアシスタントメッセージを追加
  messages << {
    role: "assistant",
    content: response[:content],
    tool_calls: response[:tool_calls]
  }

  # Execute tools and add results
  # ツールを実行して結果を追加
  response[:tool_calls].each do |tc|
    result = execute_tool(tc[:name], tc[:input])
    puts "Tool result: #{tc[:name]} => #{result}"

    messages << {
      role: "tool",
      tool_call_id: tc[:id],
      tool_name: tc[:name],
      content: result
    }
  end
  puts

  # Second call with tool results
  # ツール結果を含む2回目の呼び出し
  response = provider.chat(messages: messages, tools: tools)
end

puts "Assistant: #{response[:content]}"
