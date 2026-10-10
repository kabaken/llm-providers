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

  describe "generation config and usage" do
    def stub_ok(body = nil)
      body ||= {
        candidates: [{ content: { parts: [{ text: "ok" }], role: "model" } }],
        usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 4, thoughtsTokenCount: 6 }
      }
      stub_request(:post, api_url_pattern).to_return(
        status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" }
      )
    end

    def sent_config_for(**opts)
      config = nil
      described_class.new(**opts).chat(messages: messages)
      expect(WebMock).to(have_requested(:post, api_url_pattern).with { |req| config = JSON.parse(req.body)["generationConfig"] })
      config
    end

    it "omits temperature and thinkingConfig by default" do
      stub_ok
      config = sent_config_for
      expect(config).not_to have_key("temperature")
      expect(config).not_to have_key("thinkingConfig")
      expect(config["maxOutputTokens"]).to eq(16_384)
    end

    it "sends temperature when given" do
      stub_ok
      expect(sent_config_for(temperature: 0.1)["temperature"]).to eq(0.1)
    end

    { "low" => "low", "medium" => "medium", "high" => "high", "xhigh" => "high", "max" => "high" }.each do |effort, level|
      it "maps effort #{effort} to thinkingLevel #{level}" do
        stub_ok
        expect(sent_config_for(model: "gemini-3.8-flash", effort: effort).dig("thinkingConfig", "thinkingLevel")).to eq(level)
      end
    end

    %w[gemini-3.8-flash gemini-3.1-flash-lite gemini-4-pro gemini-flash-latest gemini-pro-latest].each do |model|
      it "sends thinkingConfig for #{model}" do
        stub_ok
        expect(sent_config_for(model: model, effort: "low").dig("thinkingConfig", "thinkingLevel")).to eq("low")
      end
    end

    %w[gemini-2.5-flash gemini-2.0-flash gemini-1.5-pro].each do |model|
      it "never sends thinkingConfig for #{model}" do
        stub_ok
        expect(sent_config_for(model: model, effort: "high")).not_to have_key("thinkingConfig")
      end
    end

    it "adds thought tokens to output usage" do
      stub_ok
      expect(provider.chat(messages: messages)[:usage]).to include(input: 3, output: 10)
    end

    it "treats missing token counts as zero" do
      stub_ok(candidates: [{ content: { parts: [{ text: "ok" }] } }], usageMetadata: { promptTokenCount: 3 })
      expect(provider.chat(messages: messages)[:usage][:output]).to eq(0)
    end

    it "treats a missing thoughtsTokenCount as zero" do
      stub_ok(candidates: [{ content: { parts: [{ text: "ok" }] } }],
              usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 5 })
      expect(provider.chat(messages: messages)[:usage][:output]).to eq(5)
    end

    it "returns empty content without raising when MAX_TOKENS is hit with no text" do
      stub_ok(candidates: [{ content: { role: "model" }, finishReason: "MAX_TOKENS" }],
              usageMetadata: { promptTokenCount: 3, thoughtsTokenCount: 64 })
      result = provider.chat(messages: messages)
      expect(result[:content]).to eq("")
      expect(result[:usage][:output]).to eq(64)
    end

    it "skips thought-summary parts in content" do
      stub_ok(candidates: [{ content: { parts: [{ text: "thinking...", thought: true }, { text: "Answer" }] } }],
              usageMetadata: {})
      expect(provider.chat(messages: messages)[:content]).to eq("Answer")
    end

    it "includes thought tokens in streamed usage and tolerates MAX_TOKENS with no text" do
      events = [
        { candidates: [{ content: { role: "model" }, finishReason: "MAX_TOKENS" }],
          usageMetadata: { promptTokenCount: 3, thoughtsTokenCount: 64 } }
      ]
      stub_request(:post, api_url_pattern).to_return(
        status: 200, body: events.map { |e| "data: #{JSON.generate(e)}\n\n" }.join,
        headers: { "Content-Type" => "text/event-stream" }
      )
      result = provider.chat(messages: messages) { |_| }
      expect(result[:content]).to eq("")
      expect(result[:usage]).to eq(input: 3, output: 64)
    end
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
