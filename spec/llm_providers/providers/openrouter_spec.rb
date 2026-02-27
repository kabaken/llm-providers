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
