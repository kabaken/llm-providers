# frozen_string_literal: true

RSpec.describe LlmProviders::Providers::Google do
  let(:provider) { described_class.new }
  let(:messages) { [{ role: "user", content: "Hello" }] }
  let(:api_url_pattern) { %r{https://generativelanguage\.googleapis\.com/v1beta/models/.+} }

  before do
    ENV["GOOGLE_API_KEY"] = "test-key"
  end

  after do
    ENV.delete("GOOGLE_API_KEY")
  end

  describe "#chat" do
    context "with synchronous response" do
      before do
        stub_request(:post, api_url_pattern)
          .to_return(
            status: 200,
            body: {
              candidates: [{
                content: {
                  parts: [{ text: "Hello! How can I help?" }],
                  role: "model"
                }
              }],
              usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 20 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it_behaves_like "a provider"

      it "returns correct content" do
        result = provider.chat(messages: messages)
        expect(result[:content]).to eq("Hello! How can I help?")
      end

      it "returns usage" do
        result = provider.chat(messages: messages)
        expect(result[:usage][:input]).to eq(10)
        expect(result[:usage][:output]).to eq(20)
      end
    end

    context "with tool calls response" do
      before do
        stub_request(:post, api_url_pattern)
          .to_return(
            status: 200,
            body: {
              candidates: [{
                content: {
                  parts: [{
                    functionCall: {
                      name: "get_weather",
                      args: { location: "Tokyo" }
                    }
                  }],
                  role: "model"
                }
              }],
              usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns tool_calls" do
        result = provider.chat(messages: messages)
        expect(result[:tool_calls]).not_to be_empty
        expect(result[:tool_calls].first[:name]).to eq("get_weather")
        expect(result[:tool_calls].first[:input]).to eq({ "location" => "Tokyo" })
      end

      it "generates an id for tool calls" do
        result = provider.chat(messages: messages)
        expect(result[:tool_calls].first[:id]).to be_a(String)
        expect(result[:tool_calls].first[:id]).not_to be_empty
      end
    end

    context "with streaming response (SSE)" do
      let(:stream_data) do
        [
          "data: #{JSON.generate(candidates: [{ content: { parts: [{ text: "Hello" }] } }])}\n\n",
          "data: #{JSON.generate(candidates: [{ content: { parts: [{ text: " world" }] } }])}\n\n",
          "data: #{JSON.generate(usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5 })}\n\n"
        ].join
      end

      before do
        stub_request(:post, api_url_pattern)
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

      it "returns usage from stream" do
        result = provider.chat(messages: messages) { |_| }
        expect(result[:usage][:input]).to eq(10)
        expect(result[:usage][:output]).to eq(5)
      end
    end

    context "with streaming tool calls" do
      let(:stream_data) do
        [
          "data: #{JSON.generate(candidates: [{ content: { parts: [{ functionCall: { name: "get_weather",
                                                                                     args: { location: "Tokyo" } } }] } }])}\n\n"
        ].join
      end

      before do
        stub_request(:post, api_url_pattern)
          .to_return(
            status: 200,
            body: stream_data,
            headers: { "Content-Type" => "text/event-stream" }
          )
      end

      it "collects tool calls from stream" do
        result = provider.chat(messages: messages) { |_| }
        expect(result[:tool_calls].first[:name]).to eq("get_weather")
        expect(result[:tool_calls].first[:input]).to eq({ "location" => "Tokyo" })
      end
    end

    context "with API error" do
      before do
        stub_request(:post, api_url_pattern)
          .to_return(
            status: 400,
            body: { error: { message: "Invalid request" } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ProviderError" do
        expect { provider.chat(messages: messages) }
          .to raise_error(LlmProviders::ProviderError, /Invalid request/)
      end
    end

    context "with 401 unauthorized" do
      before do
        stub_request(:post, api_url_pattern)
          .to_return(
            status: 401,
            body: { error: { message: "Unauthorized" } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it_behaves_like "a provider with API error handling"
    end

    context "with 500 server error" do
      before do
        stub_request(:post, api_url_pattern)
          .to_return(
            status: 500,
            body: { error: { message: "Internal server error" } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ProviderError" do
        expect { provider.chat(messages: messages) }
          .to raise_error(LlmProviders::ProviderError, /Internal server error/)
      end
    end

    it_behaves_like "a provider with missing API key", "GOOGLE_API_KEY"
  end

  describe "system instruction" do
    before do
      stub_request(:post, api_url_pattern)
        .to_return(
          status: 200,
          body: {
            candidates: [{
              content: { parts: [{ text: "I am helpful" }], role: "model" }
            }],
            usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "includes system_instruction in payload" do
      provider.chat(messages: messages, system: "You are helpful")

      expect(WebMock).to(have_requested(:post, api_url_pattern)
        .with do |req|
          body = JSON.parse(req.body)
          body["system_instruction"] == { "parts" => [{ "text" => "You are helpful" }] }
        end)
    end
  end

  describe "default_model" do
    it "returns gemini-2.5-flash" do
      expect(provider.send(:default_model)).to eq("gemini-2.5-flash")
    end
  end

  describe "#format_messages" do
    it "handles messages with symbol keys" do
      msgs = [{ role: "user", content: "Hi" }]
      result = provider.send(:format_messages, msgs)
      expect(result.first[:role]).to eq("user")
    end

    it "handles messages with string keys" do
      msgs = [{ "role" => "user", "content" => "Hi" }]
      result = provider.send(:format_messages, msgs)
      expect(result.first[:role]).to eq("user")
    end

    it "maps assistant role to model" do
      msgs = [{ role: "assistant", content: "Hi" }]
      result = provider.send(:format_messages, msgs)
      expect(result.first[:role]).to eq("model")
    end

    it "skips system messages" do
      msgs = [
        { role: "system", content: "Ignore" },
        { role: "user", content: "Hi" }
      ]
      result = provider.send(:format_messages, msgs)
      expect(result.size).to eq(1)
      expect(result.first[:role]).to eq("user")
    end

    it "formats tool messages as function responses" do
      msgs = [{ role: "tool", content: "result", tool_name: "get_weather" }]
      result = provider.send(:format_messages, msgs)
      expect(result.first[:role]).to eq("function")
      expect(result.first[:parts].first[:functionResponse][:name]).to eq("get_weather")
    end
  end
end
