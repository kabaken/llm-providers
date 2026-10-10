# frozen_string_literal: true

RSpec.describe LlmProviders::Providers::Anthropic do
  let(:provider) { described_class.new }
  let(:messages) { [{ role: "user", content: "Hello" }] }
  let(:api_url) { "https://api.anthropic.com/v1/messages" }

  before do
    ENV["ANTHROPIC_API_KEY"] = "test-key"
  end

  after do
    ENV.delete("ANTHROPIC_API_KEY")
  end

  describe "request parameters" do
    before do
      stub_request(:post, api_url).to_return(
        status: 200,
        body: { content: [{ type: "text", text: "ok" }], usage: { input_tokens: 1, output_tokens: 1 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    def sent_body
      body = nil
      expect(WebMock).to(have_requested(:post, api_url).with { |req| body = JSON.parse(req.body) })
      body
    end

    it "omits temperature by default" do
      described_class.new.chat(messages: messages)
      expect(sent_body).not_to have_key("temperature")
    end

    it "sends temperature when given" do
      described_class.new(temperature: 0.2).chat(messages: messages)
      expect(sent_body["temperature"]).to eq(0.2)
    end

    it "omits output_config and thinking by default" do
      described_class.new.chat(messages: messages)
      expect(sent_body).not_to have_key("output_config")
      expect(sent_body).not_to have_key("thinking")
    end

    it "sends output_config effort when set, and never thinking" do
      described_class.new(effort: "xhigh").chat(messages: messages)
      body = sent_body
      expect(body["output_config"]).to eq("effort" => "xhigh")
      expect(body).not_to have_key("thinking")
    end
  end

  describe "thinking blocks" do
    it "ignores thinking blocks in a synchronous response" do
      stub_request(:post, api_url).to_return(
        status: 200,
        body: {
          content: [
            { type: "thinking", thinking: "", signature: "sig" },
            { type: "text", text: "Answer" },
            { type: "tool_use", id: "t1", name: "get_weather", input: { a: 1 } }
          ],
          usage: { input_tokens: 1, output_tokens: 1 }
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      result = described_class.new.chat(messages: messages)
      expect(result[:content]).to eq("Answer")
      expect(result[:tool_calls].map { |t| t[:name] }).to eq(["get_weather"])
    end

    it "returns empty content when only a thinking block is present" do
      stub_request(:post, api_url).to_return(
        status: 200,
        body: { content: [{ type: "thinking", thinking: "hmm", signature: "s" }],
                usage: { input_tokens: 1, output_tokens: 1 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      expect(described_class.new.chat(messages: messages)[:content]).to eq("")
    end

    it "writes nothing to stdout while streaming" do
      stub_request(:post, api_url).to_return(
        status: 200,
        body: "data: #{JSON.generate(type: "content_block_start", index: 0, content_block: { type: "text", text: "" })}\n\n",
        headers: { "Content-Type" => "text/event-stream" }
      )
      expect { described_class.new.chat(messages: messages) { |_| } }.not_to output.to_stdout
    end

    it "ignores thinking events in a streaming response" do
      events = [
        { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "let me think" } },
        { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "abc" } },
        { type: "content_block_stop", index: 0 },
        { type: "content_block_start", index: 1, content_block: { type: "text", text: "" } },
        { type: "content_block_delta", index: 1, delta: { type: "text_delta", text: "Hi" } },
        { type: "content_block_stop", index: 1 },
        { type: "content_block_start", index: 2,
          content_block: { type: "tool_use", id: "t1", name: "get_weather", input: {} } },
        { type: "content_block_delta", index: 2, delta: { type: "input_json_delta", partial_json: '{"a":1}' } },
        { type: "content_block_stop", index: 2 },
        { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { input_tokens: 3, output_tokens: 4 } }
      ]
      stub_request(:post, api_url).to_return(
        status: 200,
        body: events.map { |e| "data: #{JSON.generate(e)}\n\n" }.join,
        headers: { "Content-Type" => "text/event-stream" }
      )
      chunks = []
      result = described_class.new.chat(messages: messages) { |c| chunks << c[:content] }
      expect(chunks).to eq(["Hi"])
      expect(result[:content]).to eq("Hi")
      expect(result[:tool_calls].first[:input]).to eq("a" => 1)
      expect(result[:usage][:output]).to eq(4)
    end
  end

  describe "#chat" do
    context "with synchronous response" do
      before do
        stub_request(:post, api_url)
          .to_return(
            status: 200,
            body: {
              content: [{ type: "text", text: "Hello! How can I help?" }],
              usage: { input_tokens: 10, output_tokens: 20, cache_read_input_tokens: 5 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it_behaves_like "a provider"

      it "returns cached_input in usage" do
        result = provider.chat(messages: messages)
        expect(result[:usage][:cached_input]).to eq(5)
      end
    end

    context "with tool calls response" do
      before do
        stub_request(:post, api_url)
          .to_return(
            status: 200,
            body: {
              content: [
                { type: "text", text: "Let me check the weather." },
                {
                  type: "tool_use",
                  id: "tool_123",
                  name: "get_weather",
                  input: { location: "Tokyo" }
                }
              ],
              usage: { input_tokens: 15, output_tokens: 30 }
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
    end

    context "with streaming response" do
      let(:stream_data) do
        [
          "data: #{JSON.generate(type: "content_block_start", index: 0,
                                 content_block: { type: "text", text: "" })}\n\n",
          "data: #{JSON.generate(type: "content_block_delta", index: 0,
                                 delta: { type: "text_delta", text: "Hello" })}\n\n",
          "data: #{JSON.generate(type: "content_block_delta", index: 0,
                                 delta: { type: "text_delta", text: " world" })}\n\n",
          "data: #{JSON.generate(type: "message_delta", delta: { stop_reason: "end_turn" },
                                 usage: { input_tokens: 10, output_tokens: 5 })}\n\n"
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

      it "returns usage from message_delta" do
        result = provider.chat(messages: messages) { |_| }
        expect(result[:usage][:output]).to eq(5)
      end
    end

    context "with streaming tool calls" do
      let(:stream_data) do
        [
          "data: #{JSON.generate(type: "content_block_start", index: 0,
                                 content_block: { type: "tool_use", id: "tool_1", name: "get_weather" })}\n\n",
          "data: #{JSON.generate(type: "content_block_delta", index: 0,
                                 delta: { type: "input_json_delta", partial_json: '{"loc' })}\n\n",
          "data: #{JSON.generate(type: "content_block_delta", index: 0,
                                 delta: { type: "input_json_delta", partial_json: 'ation":"Tokyo"}' })}\n\n",
          "data: #{JSON.generate(type: "content_block_stop", index: 0)}\n\n"
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

    context "with chunk boundary splitting SSE lines" do
      let(:line1) { "data: #{JSON.generate(type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "tool_1", name: "get_weather" })}\n\n" }
      let(:line2) { "data: #{JSON.generate(type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"location"' })}\n\n" }
      let(:line3) { "data: #{JSON.generate(type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: ':"Tokyo"}' })}\n\n" }
      let(:line4) { "data: #{JSON.generate(type: "content_block_stop", index: 0)}\n\n" }

      before do
        # Simulate chunks that split in the middle of an SSE data line
        chunk1 = line1 + line2[0, 20]
        chunk2 = line2[20..] + line3
        chunk3 = line4

        stub_request(:post, api_url)
          .to_return(
            status: 200,
            body: [chunk1, chunk2, chunk3].join,
            headers: { "Content-Type" => "text/event-stream" }
          )
      end

      it "correctly buffers and assembles tool call input across chunk boundaries" do
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

      it "raises ProviderError with message" do
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

    it_behaves_like "a provider with missing API key", "ANTHROPIC_API_KEY"
  end

  describe "default_model" do
    it "returns claude-sonnet-4-5" do
      expect(provider.send(:default_model)).to eq("claude-sonnet-4-5-20250929")
    end
  end

  describe "#format_messages" do
    it "handles messages with symbol keys" do
      msgs = [
        { role: "user", content: "Hi" },
        {
          role: "assistant",
          tool_calls: [{ id: "tc1", name: "func", input: { a: 1 } }],
          content: ""
        }
      ]
      result = provider.send(:format_messages, msgs)
      assistant_msg = result.find { |m| m[:role] == "assistant" }
      expect(assistant_msg[:content].last[:name]).to eq("func")
    end

    it "handles messages with string keys for tool_calls" do
      msgs = [
        { role: "user", content: "Hi" },
        {
          role: "assistant",
          tool_calls: [{ "id" => "tc1", "name" => "func", "input" => { "a" => 1 } }],
          content: ""
        }
      ]
      result = provider.send(:format_messages, msgs)
      assistant_msg = result.find { |m| m[:role] == "assistant" }
      expect(assistant_msg[:content].last[:name]).to eq("func")
    end
  end
end
