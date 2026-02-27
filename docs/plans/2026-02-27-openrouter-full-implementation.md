# OpenRouter Full Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** OpenRouter を experimental から正式実装に昇格。固有ヘッダー、provider routing、エラーハンドリング改善、モデル一覧取得を追加。

**Architecture:** Openai 継承を維持し、`initialize`, `build_payload`, ヘッダー設定、エラー処理のみオーバーライド。`self.models` クラスメソッドを新規追加。

**Tech Stack:** Ruby, Faraday, RSpec, WebMock

---

### Task 1: initialize オーバーライドと固有ヘッダー

**Files:**
- Modify: `lib/llm_providers/providers/openrouter.rb`
- Test: `spec/llm_providers/providers/openrouter_spec.rb`

**Step 1: Write the failing tests**

`spec/llm_providers/providers/openrouter_spec.rb` に以下を追加:

```ruby
describe "custom headers" do
  before do
    stub_request(:post, api_url)
      .to_return(
        status: 200,
        body: {
          choices: [{ message: { role: "assistant", content: "Hi" } }],
          usage: { prompt_tokens: 10, completion_tokens: 5 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  context "with app_name and app_url options" do
    let(:provider) { described_class.new(app_name: "MyApp", app_url: "https://myapp.example.com") }

    it "sends X-Title header" do
      provider.chat(messages: messages)
      expect(WebMock).to have_requested(:post, api_url)
        .with(headers: { "X-Title" => "MyApp" })
    end

    it "sends HTTP-Referer header" do
      provider.chat(messages: messages)
      expect(WebMock).to have_requested(:post, api_url)
        .with(headers: { "HTTP-Referer" => "https://myapp.example.com" })
    end
  end

  context "with ENV fallback" do
    before do
      ENV["OPENROUTER_APP_NAME"] = "EnvApp"
      ENV["OPENROUTER_APP_URL"] = "https://envapp.example.com"
    end

    after do
      ENV.delete("OPENROUTER_APP_NAME")
      ENV.delete("OPENROUTER_APP_URL")
    end

    it "uses ENV values for headers" do
      provider.chat(messages: messages)
      expect(WebMock).to have_requested(:post, api_url)
        .with(headers: { "X-Title" => "EnvApp", "HTTP-Referer" => "https://envapp.example.com" })
    end
  end

  context "without app_name or app_url" do
    it "does not send X-Title or HTTP-Referer headers" do
      provider.chat(messages: messages)
      expect(WebMock).to have_requested(:post, api_url)
        .with { |req| !req.headers.key?("X-Title") && !req.headers.key?("Http-Referer") }
    end
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/llm_providers/providers/openrouter_spec.rb`
Expected: FAIL (Openrouter.new does not accept app_name/app_url)

**Step 3: Implement initialize and header injection**

`lib/llm_providers/providers/openrouter.rb`:

```ruby
class Openrouter < Openai
  API_URL = "https://openrouter.ai/api/v1/chat/completions"

  def initialize(app_name: nil, app_url: nil, provider: nil, **options)
    super(**options)
    @app_name = app_name || ENV["OPENROUTER_APP_NAME"]
    @app_url = app_url || ENV["OPENROUTER_APP_URL"]
    @provider_preferences = provider
  end

  # ... (headers applied in later steps via stream_response/sync_response override)
```

ヘッダー注入は `extra_headers` メソッドを定義し、`stream_response` と `sync_response` をオーバーライドして適用:

```ruby
private

def extra_headers
  headers = {}
  headers["X-Title"] = @app_name if @app_name
  headers["HTTP-Referer"] = @app_url if @app_url
  headers
end
```

Openai の `stream_response` と `sync_response` でヘッダーを設定している箇所をオーバーライドする必要がある。最もシンプルなアプローチは Openai 側に `request_headers` メソッドを抽出し、Openrouter でオーバーライドすること。

Openai の `stream_response` と `sync_response` のヘッダー設定を `request_headers` メソッドに抽出:

```ruby
# openai.rb に追加
def request_headers
  {
    "Content-Type" => "application/json",
    "Authorization" => "Bearer #{api_key}"
  }
end
```

各 `req.headers[...] = ...` を `request_headers.each { |k, v| req.headers[k] = v }` に置き換え。

Openrouter でオーバーライド:

```ruby
# openrouter.rb
def request_headers
  headers = super
  headers["X-Title"] = @app_name if @app_name
  headers["HTTP-Referer"] = @app_url if @app_url
  headers
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/llm_providers/providers/openrouter_spec.rb`
Expected: ALL PASS

**Step 5: Run full test suite**

Run: `bundle exec rspec`
Expected: ALL PASS (Openai tests also pass with refactored headers)

**Step 6: Commit**

```bash
git add lib/llm_providers/providers/openai.rb lib/llm_providers/providers/openrouter.rb spec/llm_providers/providers/openrouter_spec.rb
git commit -m "feat(openrouter): add custom headers (X-Title, HTTP-Referer)"
```

---

### Task 2: Provider routing

**Files:**
- Modify: `lib/llm_providers/providers/openrouter.rb`
- Test: `spec/llm_providers/providers/openrouter_spec.rb`

**Step 1: Write the failing tests**

```ruby
describe "provider routing" do
  before do
    stub_request(:post, api_url)
      .to_return(
        status: 200,
        body: {
          choices: [{ message: { role: "assistant", content: "Hi" } }],
          usage: { prompt_tokens: 10, completion_tokens: 5 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  context "with provider preferences" do
    let(:provider) do
      described_class.new(provider: { order: ["Anthropic", "Google"], allow_fallbacks: true })
    end

    it "includes provider field in request payload" do
      provider.chat(messages: messages)
      expect(WebMock).to have_requested(:post, api_url)
        .with { |req|
          body = JSON.parse(req.body)
          body["provider"] == { "order" => ["Anthropic", "Google"], "allow_fallbacks" => true }
        }
    end
  end

  context "without provider preferences" do
    it "does not include provider field in request payload" do
      provider.chat(messages: messages)
      expect(WebMock).to have_requested(:post, api_url)
        .with { |req| !JSON.parse(req.body).key?("provider") }
    end
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/llm_providers/providers/openrouter_spec.rb`
Expected: FAIL

**Step 3: Implement build_payload override**

```ruby
# openrouter.rb
def build_payload(messages, system, tools)
  payload = super
  payload[:provider] = @provider_preferences if @provider_preferences
  payload
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/llm_providers/providers/openrouter_spec.rb`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add lib/llm_providers/providers/openrouter.rb spec/llm_providers/providers/openrouter_spec.rb
git commit -m "feat(openrouter): add provider routing support"
```

---

### Task 3: エラーハンドリング改善

**Files:**
- Modify: `lib/llm_providers/providers/openrouter.rb`
- Test: `spec/llm_providers/providers/openrouter_spec.rb`

**Step 1: Write the failing tests**

```ruby
describe "error handling" do
  context "with OpenRouter error format including metadata" do
    before do
      stub_request(:post, api_url)
        .to_return(
          status: 502,
          body: {
            error: {
              code: 502,
              message: "Model is unavailable",
              metadata: { provider_name: "DeepSeek", raw: "upstream timeout" }
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "includes provider name in error message" do
      expect { provider.chat(messages: messages) }
        .to raise_error(LlmProviders::ProviderError, /DeepSeek.*Model is unavailable/)
    end
  end

  context "with 429 rate limit error" do
    before do
      stub_request(:post, api_url)
        .to_return(
          status: 429,
          body: {
            error: { code: 429, message: "Rate limit exceeded" }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "raises ProviderError with rate limit info" do
      expect { provider.chat(messages: messages) }
        .to raise_error(LlmProviders::ProviderError, /Rate limit/)
    end
  end

  context "with streaming error" do
    let(:stream_data) do
      [
        "data: #{JSON.generate(choices: [{ delta: { content: "Hello" } }])}\n\n",
        "data: #{JSON.generate(error: { code: 502, message: "Provider failed", metadata: { provider_name: "Together" } })}\n\n"
      ].join
    end

    before do
      stub_request(:post, api_url)
        .to_return(
          status: 200,
          body: stream_data,
          headers: { "Content-Type" => "text/event-stream" }
        )
    end

    it "raises ProviderError with provider name from stream error" do
      expect { provider.chat(messages: messages) { |_| } }
        .to raise_error(LlmProviders::ProviderError, /Together.*Provider failed/)
    end
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/llm_providers/providers/openrouter_spec.rb`
Expected: FAIL

**Step 3: Implement error handling overrides**

`sync_response` をオーバーライドして OpenRouter 固有エラーをパース:

```ruby
# openrouter.rb
def sync_response(payload)
  super
rescue ProviderError => e
  raise
rescue StandardError => e
  raise
end
```

実際にはエラーパースのロジックを入れる。Openai の `sync_response` はエラー時に `ProviderError` を raise するが、OpenRouter の `metadata.provider_name` を含めない。

アプローチ: `parse_error_message` メソッドを定義し、`sync_response` と `stream_response` でのエラー処理をオーバーライド。

```ruby
def parse_error_body(body)
  error = body.is_a?(Hash) ? body : JSON.parse(body) rescue {}
  message = error.dig("error", "message") || "API error"
  provider_name = error.dig("error", "metadata", "provider_name")
  provider_name ? "[#{provider_name}] #{message}" : message
end
```

同期レスポンスのオーバーライド:

```ruby
def sync_response(payload)
  started_at = Time.now
  response = http_client.post(self.class::API_URL) do |req|
    request_headers.each { |k, v| req.headers[k] = v }
    req.body = payload
  end

  unless response.success?
    raise ProviderError.new(
      parse_error_body(response.body),
      code: "openrouter_error"
    )
  end

  # ... rest is same as Openai (call super won't work cleanly here)
```

よりシンプルなアプローチ: super を呼び、rescue して再 raise:

```ruby
def sync_response(payload)
  super
rescue ProviderError => e
  raise # re-raise as-is for now; error formatting handled at stream level
end
```

最もクリーンなアプローチ: ストリーミングのエラーハンドリングを `process_sse_line` の `event["error"]` で処理し、`metadata.provider_name` を含める。同期はそのまま Openai に委譲しつつ、rescue で OpenRouter 固有情報を付加。

**同期エラー:** `sync_response` をオーバーライドし、エラー時に `parse_error_body` を使う。

**ストリーミングエラー:** Openai の `process_sse_line` 内の `event["error"]` 処理が Openrouter にも適用される。`stream_error` に metadata 含む provider 名を付加するために、`stream_response` をオーバーライドするか、シンプルに error メッセージのフォーマットを変える。

最もシンプルな実装: `stream_response` をオーバーライドせず、`sync_response` のみオーバーライド。ストリーミングは Openai の `stream_response` が `stream_error` をそのまま使うので、OpenRouter の error event に `metadata.provider_name` が含まれていても `event.dig("error", "message")` しか取らない問題がある。

→ `stream_response` もオーバーライドが必要だが、丸ごとコピーは DRY に反する。

→ 折衷案: Openai に `format_stream_error(event)` メソッドを抽出し、Openrouter でオーバーライド。

```ruby
# openai.rb の process_sse_line 内
if event["error"]
  stream_error = format_stream_error(event)
  next
end

def format_stream_error(event)
  event.dig("error", "message") || event["error"].to_s
end
```

```ruby
# openrouter.rb
def format_stream_error(event)
  message = event.dig("error", "message") || event["error"].to_s
  provider_name = event.dig("error", "metadata", "provider_name")
  provider_name ? "[#{provider_name}] #{message}" : message
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/llm_providers/providers/openrouter_spec.rb`
Expected: ALL PASS

**Step 5: Run full test suite**

Run: `bundle exec rspec`
Expected: ALL PASS

**Step 6: Commit**

```bash
git add lib/llm_providers/providers/openai.rb lib/llm_providers/providers/openrouter.rb spec/llm_providers/providers/openrouter_spec.rb
git commit -m "feat(openrouter): improve error handling with provider name"
```

---

### Task 4: モデル一覧取得

**Files:**
- Modify: `lib/llm_providers/providers/openrouter.rb`
- Test: `spec/llm_providers/providers/openrouter_spec.rb`

**Step 1: Write the failing tests**

```ruby
describe ".models" do
  let(:models_url) { "https://openrouter.ai/api/v1/models" }
  let(:models_response) do
    {
      data: [
        {
          id: "anthropic/claude-sonnet-4.5",
          name: "Claude Sonnet 4.5",
          context_length: 200000,
          pricing: { prompt: "0.000003", completion: "0.000015" }
        },
        {
          id: "meta-llama/llama-3.3-70b-instruct",
          name: "Llama 3.3 70B Instruct",
          context_length: 131072,
          pricing: { prompt: "0.0000004", completion: "0.0000004" }
        }
      ]
    }
  end

  before do
    stub_request(:get, models_url)
      .to_return(
        status: 200,
        body: models_response.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  it "returns a list of available models" do
    models = described_class.models
    expect(models.size).to eq(2)
    expect(models.first[:id]).to eq("anthropic/claude-sonnet-4.5")
  end

  it "includes model metadata" do
    model = described_class.models.first
    expect(model[:name]).to eq("Claude Sonnet 4.5")
    expect(model[:context_length]).to eq(200000)
    expect(model[:pricing]).to eq({ prompt: "0.000003", completion: "0.000015" })
  end

  context "when API returns error" do
    before do
      stub_request(:get, models_url)
        .to_return(status: 500, body: { error: { message: "Server error" } }.to_json)
    end

    it "raises ProviderError" do
      expect { described_class.models }
        .to raise_error(LlmProviders::ProviderError, /Server error/)
    end
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/llm_providers/providers/openrouter_spec.rb`
Expected: FAIL (NoMethodError: undefined method `models`)

**Step 3: Implement models class method**

```ruby
# openrouter.rb
MODELS_URL = "https://openrouter.ai/api/v1/models"

def self.models
  api_key = ENV.fetch("OPENROUTER_API_KEY")
  conn = Faraday.new do |f|
    f.response :json
    f.adapter Faraday.default_adapter
  end

  response = conn.get(MODELS_URL) do |req|
    req.headers["Authorization"] = "Bearer #{api_key}"
  end

  unless response.success?
    error_msg = response.body.dig("error", "message") || "Failed to fetch models"
    raise ProviderError.new(error_msg, code: "openrouter_error")
  end

  (response.body["data"] || []).map do |model|
    {
      id: model["id"],
      name: model["name"],
      context_length: model["context_length"],
      pricing: {
        prompt: model.dig("pricing", "prompt"),
        completion: model.dig("pricing", "completion")
      }
    }
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/llm_providers/providers/openrouter_spec.rb`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add lib/llm_providers/providers/openrouter.rb spec/llm_providers/providers/openrouter_spec.rb
git commit -m "feat(openrouter): add models class method for model discovery"
```

---

### Task 5: ストリーミング・ツール呼び出しテスト追加 + experimental コメント削除

**Files:**
- Modify: `lib/llm_providers/providers/openrouter.rb`
- Modify: `spec/llm_providers/providers/openrouter_spec.rb`

**Step 1: Write the streaming and tool call tests**

```ruby
context "with streaming response" do
  let(:stream_data) do
    [
      "data: #{JSON.generate(choices: [{ delta: { content: "Hello" } }])}\n\n",
      "data: #{JSON.generate(choices: [{ delta: { content: " world" } }])}\n\n",
      "data: #{JSON.generate(usage: { prompt_tokens: 10, completion_tokens: 5 })}\n\n",
      "data: [DONE]\n\n"
    ].join
  end

  before do
    stub_request(:post, api_url)
      .to_return(
        status: 200,
        body: stream_data,
        headers: { "Content-Type" => "text/event-stream" }
      )
  end

  it "yields chunks and returns full content" do
    chunks = []
    result = provider.chat(messages: messages) do |chunk|
      chunks << chunk[:content] if chunk[:content]
    end

    expect(chunks).to eq(["Hello", " world"])
    expect(result[:content]).to eq("Hello world")
  end
end

context "with streaming tool calls" do
  let(:stream_data) do
    [
      "data: #{JSON.generate(choices: [{ delta: { tool_calls: [{ index: 0, id: "call_1",
                                                                   function: { name: "get_weather", arguments: "" } }] } }])}\n\n",
      "data: #{JSON.generate(choices: [{ delta: { tool_calls: [{ index: 0,
                                                                   function: { arguments: '{"location"' } }] } }])}\n\n",
      "data: #{JSON.generate(choices: [{ delta: { tool_calls: [{ index: 0,
                                                                   function: { arguments: ':"Tokyo"}' } }] } }])}\n\n",
      "data: [DONE]\n\n"
    ].join
  end

  before do
    stub_request(:post, api_url)
      .to_return(
        status: 200,
        body: stream_data,
        headers: { "Content-Type" => "text/event-stream" }
      )
  end

  it "assembles tool calls from stream" do
    result = provider.chat(messages: messages) { |_| }
    expect(result[:tool_calls].first[:name]).to eq("get_weather")
    expect(result[:tool_calls].first[:input]).to eq({ "location" => "Tokyo" })
  end
end
```

**Step 2: Remove experimental comment from openrouter.rb**

削除対象:
```ruby
# Experimental: OpenRouter support is provided as-is.
# It wraps the OpenAI-compatible API at openrouter.ai.
# Not all features may work as expected with every model.
```

**Step 3: Run full test suite**

Run: `bundle exec rspec`
Expected: ALL PASS

**Step 4: Commit**

```bash
git add lib/llm_providers/providers/openrouter.rb spec/llm_providers/providers/openrouter_spec.rb
git commit -m "feat(openrouter): add streaming/tool call tests, remove experimental label"
```

---

### Task 6: バージョンバンプ、CHANGELOG、リリース

**Files:**
- Modify: `lib/llm_providers/version.rb`
- Modify: `CHANGELOG.md`

**Step 1: Bump version**

`0.1.1` → `0.2.0` (新機能追加なので minor bump)

**Step 2: Update CHANGELOG**

```markdown
## [0.2.0] - 2026-02-27

### Added

- OpenRouter provider is now fully supported (no longer experimental)
  - Custom headers: `X-Title`, `HTTP-Referer` via `app_name:` / `app_url:` options or ENV
  - Provider routing: `provider:` option for order, fallback, data collection preferences
  - `Openrouter.models` class method for model discovery
  - Improved error handling with provider name from OpenRouter metadata

### Changed

- Extracted `request_headers` method in OpenAI provider for extensibility
- Extracted `format_stream_error` method in OpenAI provider for extensibility
```

**Step 3: Run full test suite**

Run: `bundle exec rspec`
Expected: ALL PASS

**Step 4: Commit, tag, build, push**

```bash
git add -A
git commit -m "release: v0.2.0 - OpenRouter full implementation"
git tag v0.2.0
git push && git push --tags
gem build llm_providers.gemspec
gem push llm_providers-0.2.0.gem
```
