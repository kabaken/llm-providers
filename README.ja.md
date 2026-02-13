# LlmProviders

[![Gem Version](https://badge.fury.io/rb/llm_providers.svg)](https://rubygems.org/gems/llm_providers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.txt)

複数の LLM プロバイダーに対応した軽量な統一インターフェース。依存は `faraday` のみ — ActiveSupport 不要。

[English README](README.md)

## 特徴

- **軽量** — 依存は `faraday` のみ、ActiveSupport 不要
- **統一インターフェース** — 全プロバイダーで同じ API
- **ストリーミング** — ブロック構文でリアルタイムトークンストリーミング
- **ツール呼び出し** — プロバイダー間で一貫したツール/関数呼び出し
- **トークン追跡** — 全レスポンスに使用量統計（入力、出力、キャッシュ）

## 対応プロバイダー

| プロバイダー | 環境変数 | デフォルトモデル |
|------------|---------|---------------|
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-sonnet-4-5-20250929` |
| `openai` | `OPENAI_API_KEY` | `gpt-5-mini` |
| `google` | `GOOGLE_API_KEY` | `gemini-2.5-flash` |
| `openrouter` *(実験的)* | `OPENROUTER_API_KEY` | `anthropic/claude-sonnet-4.5` |

## インストール

Gemfile に追加:

```ruby
gem "llm_providers"
```

## クイックスタート

```ruby
require "llm_providers"

provider = LlmProviders::Providers.build(:anthropic)

# 同期
result = provider.chat(
  messages: [{ role: "user", content: "こんにちは！" }],
  system: "あなたは親切なアシスタントです。"
)
puts result[:content]

# ストリーミング
provider.chat(messages: [{ role: "user", content: "こんにちは！" }]) do |chunk|
  print chunk[:content]
end
```

## 使い方

### 設定

```ruby
LlmProviders.configure do |config|
  config.logger = Rails.logger  # 任意の Logger インスタンス
end
```

### プロバイダーオプション

```ruby
provider = LlmProviders::Providers.build(
  :openai,
  model: "gpt-4.1",
  temperature: 0.7,
  max_tokens: 4096
)
```

### ツール呼び出し

```ruby
tools = [
  {
    name: "get_weather",
    description: "現在の天気を取得",
    parameters: {
      type: "object",
      properties: {
        location: { type: "string", description: "都市名" }
      },
      required: ["location"]
    }
  }
]

result = provider.chat(
  messages: [{ role: "user", content: "東京の天気は？" }],
  tools: tools
)

result[:tool_calls].each do |tc|
  puts "#{tc[:name]}: #{tc[:input]}"
end
```

### レスポンス形式

`chat` は常に以下のハッシュを返します:

```ruby
{
  content: "レスポンステキスト",
  tool_calls: [
    { id: "...", name: "...", input: {...} }
  ],
  usage: {
    input: 100,           # 入力トークン数
    output: 50,           # 出力トークン数
    cached_input: 80      # キャッシュされた入力トークン数（Anthropicのみ）
  },
  latency_ms: 1234,
  raw_response: {...}
}
```

### エラーハンドリング

```ruby
begin
  result = provider.chat(messages: messages)
rescue LlmProviders::ProviderError => e
  puts "エラー: #{e.message}"
  puts "コード: #{e.code}"  # 例: "anthropic_error", "openai_error"
end
```

## サンプル

```bash
# 対話チャット
ANTHROPIC_API_KEY=your-key ruby examples/simple_chat.rb

# ワンショット
ANTHROPIC_API_KEY=your-key ruby examples/one_shot.rb "Hello!"

# ツール呼び出し
ANTHROPIC_API_KEY=your-key ruby examples/with_tools.rb

# 他のプロバイダー
OPENAI_API_KEY=your-key ruby examples/simple_chat.rb openai
GOOGLE_API_KEY=your-key ruby examples/simple_chat.rb google
```

## ライセンス

MIT
