# frozen_string_literal: true

RSpec.describe LlmProviders::Providers::Openrouter do
  let(:provider) { described_class.new }
  let(:messages) { [{ role: "user", content: "Hello" }] }
  let(:api_url) { "https://openrouter.ai/api/v1/chat/completions" }

  before do
    ENV["OPENROUTER_API_KEY"] = "test-key"
  end

  after do
    ENV.delete("OPENROUTER_API_KEY")
  end

  describe "#chat" do
    context "with synchronous response" do
      before do
        stub_request(:post, api_url)
          .to_return(
            status: 200,
            body: {
              choices: [{
                message: { role: "assistant", content: "Hi from OpenRouter!" }
              }],
              usage: { prompt_tokens: 10, completion_tokens: 20 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it_behaves_like "a provider"

      it "sends requests to OpenRouter API URL" do
        provider.chat(messages: messages)
        expect(WebMock).to have_requested(:post, api_url)
      end

      it "returns correct content" do
        result = provider.chat(messages: messages)
        expect(result[:content]).to eq("Hi from OpenRouter!")
      end
    end

    context "with API error" do
      before do
        stub_request(:post, api_url)
          .to_return(
            status: 401,
            body: { error: { message: "Unauthorized" } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it_behaves_like "a provider with API error handling"
    end

    it_behaves_like "a provider with missing API key", "OPENROUTER_API_KEY"

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
  end

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
          .to raise_error(LlmProviders::ProviderError, /\[DeepSeek\].*Model is unavailable/)
      end

      it "uses openrouter_error code" do
        expect { provider.chat(messages: messages) }
          .to raise_error(LlmProviders::ProviderError) { |e|
            expect(e.code).to eq("openrouter_error")
          }
      end
    end

    context "with error without metadata" do
      before do
        stub_request(:post, api_url)
          .to_return(
            status: 400,
            body: {
              error: { message: "Bad request" }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ProviderError without provider prefix" do
        expect { provider.chat(messages: messages) }
          .to raise_error(LlmProviders::ProviderError, "Bad request")
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

    context "with streaming error including provider metadata" do
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
          .to raise_error(LlmProviders::ProviderError, /\[Together\].*Provider failed/)
      end

      it "uses openrouter_error code for stream errors" do
        expect { provider.chat(messages: messages) { |_| } }
          .to raise_error(LlmProviders::ProviderError) { |e|
            expect(e.code).to eq("openrouter_error")
          }
      end
    end

    context "with streaming error without provider metadata" do
      let(:stream_data) do
        [
          "data: #{JSON.generate(error: { code: 500, message: "Internal error" })}\n\n"
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

      it "raises ProviderError without provider prefix" do
        expect { provider.chat(messages: messages) { |_| } }
          .to raise_error(LlmProviders::ProviderError, "Internal error")
      end
    end
  end

  describe "API URL" do
    it "uses OpenRouter endpoint" do
      expect(described_class::API_URL).to eq("https://openrouter.ai/api/v1/chat/completions")
    end
  end

  describe "default_model" do
    it "returns anthropic/claude-sonnet-4.5" do
      expect(provider.send(:default_model)).to eq("anthropic/claude-sonnet-4.5")
    end
  end

  describe "inheritance" do
    it "inherits from Openai" do
      expect(described_class.superclass).to eq(LlmProviders::Providers::Openai)
    end
  end
end
