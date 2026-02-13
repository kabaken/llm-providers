# frozen_string_literal: true

RSpec.describe LlmProviders::Providers::Openai do
  let(:provider) { described_class.new }
  let(:messages) { [{ role: "user", content: "Hello" }] }
  let(:api_url) { "https://api.openai.com/v1/chat/completions" }

  before do
    ENV["OPENAI_API_KEY"] = "test-key"
  end

  after do
    ENV.delete("OPENAI_API_KEY")
  end

  describe "#chat" do
    context "with synchronous response" do
      before do
        stub_request(:post, api_url)
          .to_return(
            status: 200,
            body: {
              choices: [{
                message: { role: "assistant", content: "Hi there!" }
              }],
              usage: { prompt_tokens: 10, completion_tokens: 20 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it_behaves_like "a provider"

      it "returns correct content" do
        result = provider.chat(messages: messages)
        expect(result[:content]).to eq("Hi there!")
      end

      it "returns usage" do
        result = provider.chat(messages: messages)
        expect(result[:usage][:input]).to eq(10)
        expect(result[:usage][:output]).to eq(20)
      end
    end

    context "with tool calls response" do
      before do
        stub_request(:post, api_url)
          .to_return(
            status: 200,
            body: {
              choices: [{
                message: {
                  role: "assistant",
                  content: nil,
                  tool_calls: [{
                    id: "call_123",
                    type: "function",
                    function: {
                      name: "get_weather",
                      arguments: '{"location":"Tokyo"}'
                    }
                  }]
                }
              }],
              usage: { prompt_tokens: 10, completion_tokens: 15 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns parsed tool_calls" do
        result = provider.chat(messages: messages)
        expect(result[:tool_calls].first[:name]).to eq("get_weather")
        expect(result[:tool_calls].first[:input]).to eq({ "location" => "Tokyo" })
        expect(result[:tool_calls].first[:id]).to eq("call_123")
      end
    end

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

    context "with API error" do
      before do
        stub_request(:post, api_url)
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
        stub_request(:post, api_url)
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
        stub_request(:post, api_url)
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

    it_behaves_like "a provider with missing API key", "OPENAI_API_KEY"
  end

  describe "reasoning model handling" do
    let(:provider) { described_class.new(model: "o3-mini") }

    before do
      stub_request(:post, api_url)
        .to_return(
          status: 200,
          body: {
            choices: [{
              message: { role: "assistant", content: "Response" }
            }],
            usage: { prompt_tokens: 10, completion_tokens: 20 }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "excludes temperature for reasoning models" do
      provider.chat(messages: messages)

      expect(WebMock).to(have_requested(:post, api_url)
        .with do |req|
          body = JSON.parse(req.body)
          !body.key?("temperature") && body.key?("max_completion_tokens")
        end)
    end
  end

  describe "default_model" do
    it "returns gpt-5-mini" do
      expect(provider.send(:default_model)).to eq("gpt-5-mini")
    end
  end

  describe "#format_messages" do
    it "handles messages with symbol keys" do
      msgs = [{ role: "user", content: "Hi" }]
      result = provider.send(:format_messages, msgs, nil)
      expect(result.first[:role]).to eq("user")
    end

    it "handles messages with string keys" do
      msgs = [{ "role" => "user", "content" => "Hi" }]
      result = provider.send(:format_messages, msgs, nil)
      expect(result.first[:role]).to eq("user")
    end

    it "includes system message when provided" do
      msgs = [{ role: "user", content: "Hi" }]
      result = provider.send(:format_messages, msgs, "You are helpful")
      expect(result.first[:role]).to eq("system")
      expect(result.first[:content]).to eq("You are helpful")
    end

    it "handles tool call round-trip with string keys" do
      msgs = [
        { "role" => "user", "content" => "Hi" },
        {
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [{ "id" => "tc1", "name" => "func", "input" => '{"a":1}' }]
        },
        { "role" => "tool", "content" => "result", "tool_call_id" => "tc1" }
      ]
      result = provider.send(:format_messages, msgs, nil)
      tool_msg = result.find { |m| m[:role] == "tool" }
      expect(tool_msg[:tool_call_id]).to eq("tc1")
    end
  end
end
