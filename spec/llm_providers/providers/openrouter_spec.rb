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
