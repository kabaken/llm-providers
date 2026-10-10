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
| `openrouter` | `OPENROUTER_API_KEY` | `anthropic/claude-sonnet-4.5` |

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
  temperature: 0.7,   # 省略可。デフォルトは nil（送信しない）
  max_tokens: 4096,
  effort: "medium"    # 省略可。"low" / "medium" / "high" / "xhigh" / "max"
)
```

- `temperature` のデフォルトは `nil` で、指定したときだけ送信します。0.7 を固定で送っていた 0.2.x までと異なります。Claude 5.x や OpenAI の reasoning モデルは temperature を受け付けません。
- `effort` は思考の深さの指定です（`nil` ならプロバイダーのデフォルト）。範囲外の値は `ArgumentError` になります。
  - Anthropic: `output_config: { effort: ... }` にそのまま渡します。
  - OpenAI: `gpt-6*` は `reasoning: { effort: ... }` としてそのまま送ります（Responses API、下記参照）。ほかの reasoning モデル（gpt-5*、o 系）は `reasoning_effort` に渡し、`xhigh` / `max` は `high` に丸めます。`gpt-3.5*` / `gpt-4*` では無視されます。
  - Google: `thinkingConfig.thinkingLevel` に変換します（low→low、medium→medium、high/xhigh/max→high）。Gemini 3 以降（と `*-latest`）にだけ送り、Gemini 2.x では無視します。
  - OpenRouter: `reasoning: { effort: ... }` として送ります。`xhigh` / `max` は `high` に丸めます。
- OpenAI の `gpt-6*` は Responses API（`/v1/responses`）で呼びます。chat/completions ではこれらのモデルに function tools と `reasoning_effort` を同時に送れないためです。system プロンプトは `instructions`、上限トークン数は `max_output_tokens` で送り、tools には `strict: false` を付け、`store: false` でリクエストします。戻り値とストリーミングのチャンクの形は chat/completions のときと同じです。ほかの OpenAI モデルは chat/completions のままで、OpenRouter は常に chat/completions を使います。
- `gpt-6*` 以外の OpenAI モデルは、`gpt-3.5*` / `gpt-4*` 以外を reasoning モデルとして扱い、`max_completion_tokens` を使って temperature を送りません。OpenRouter は `vendor/model` 形式の ID なので従来どおり `max_tokens` を使い、temperature は指定時のみ送ります。
- Google の usage の `output` は思考トークンを含みます。

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

### OpenRouter

OpenRouter を使えば、単一の API で 300 以上のモデルにアクセスできます。この gem が直接サポートしていないプロバイダー（DeepSeek、Meta Llama、Mistral、Qwen など）に最適です。

```ruby
provider = LlmProviders::Providers.build(
  :openrouter,
  model: "deepseek/deepseek-chat",
  app_name: "MyApp",
  app_url: "https://myapp.example.com",
  provider: { order: ["DeepSeek", "Together"], allow_fallbacks: true }
)

# 利用可能なモデル一覧
models = LlmProviders::Providers::Openrouter.models
models.each { |m| puts "#{m[:id]} (ctx: #{m[:context_length]})" }
```

### エラーハンドリング

```ruby
begin
  result = provider.chat(messages: messages)
rescue LlmProviders::ProviderError => e
  puts "エラー: #{e.message}"  # OpenRouter: "[DeepSeek] Model is unavailable"
  puts "コード: #{e.code}"     # 例: "anthropic_error", "openrouter_error"
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

# OpenRouter (DeepSeek, Llama, Mistral など)
OPENROUTER_API_KEY=your-key ruby examples/simple_chat.rb openrouter deepseek/deepseek-chat
OPENROUTER_API_KEY=your-key ruby examples/with_tools.rb openrouter meta-llama/llama-3.3-70b-instruct
```

## ライセンス

MIT
