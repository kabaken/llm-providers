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

    context "with chunk boundary splitting SSE lines" do
      let(:line1) { "data: #{JSON.generate(choices: [{ delta: { tool_calls: [{ index: 0, id: "call_1", function: { name: "get_weather", arguments: "" } }] } }])}\n\n" }
      let(:line2) { "data: #{JSON.generate(choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: '{"location"' } }] } }])}\n\n" }
      let(:line3) { "data: #{JSON.generate(choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: ':"Tokyo"}' } }] } }])}\n\n" }
      let(:line4) { "data: [DONE]\n\n" }

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

  describe "model family handling" do
    before do
      stub_request(:post, api_url).to_return(
        status: 200,
        body: { choices: [{ message: { role: "assistant", content: "ok" } }],
                usage: { prompt_tokens: 1, completion_tokens: 1 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    def sent_body_for(**opts)
      body = nil
      described_class.new(**opts).chat(messages: messages)
      expect(WebMock).to(have_requested(:post, api_url).with { |req| body = JSON.parse(req.body) })
      body
    end

    %w[gpt-5.6-mini gpt-5-mini o3-mini o4-mini].each do |model|
      it "treats #{model} as a reasoning model" do
        body = sent_body_for(model: model, temperature: 0.5, max_tokens: 100)
        expect(body["max_completion_tokens"]).to eq(100)
        expect(body).not_to have_key("max_tokens")
        expect(body).not_to have_key("temperature")
      end
    end

    it "uses max_tokens and honors temperature for gpt-4.1" do
      body = sent_body_for(model: "gpt-4.1", temperature: 0.5, max_tokens: 100)
      expect(body["max_tokens"]).to eq(100)
      expect(body["temperature"]).to eq(0.5)
    end

    it "uses max_completion_tokens for gpt-4o (legacy chat model)" do
      body = sent_body_for(model: "gpt-4o", max_tokens: 100)
      expect(body["max_completion_tokens"]).to eq(100)
      expect(body).not_to have_key("temperature")
    end

    it "omits temperature for legacy models by default" do
      expect(sent_body_for(model: "gpt-3.5-turbo")).not_to have_key("temperature")
    end

    it "omits reasoning_effort by default" do
      expect(sent_body_for(model: "gpt-5.6-mini")).not_to have_key("reasoning_effort")
    end

    { "low" => "low", "medium" => "medium", "high" => "high", "xhigh" => "high", "max" => "high" }.each do |effort, mapped|
      it "maps effort #{effort} to reasoning_effort #{mapped} for gpt-5.x" do
        expect(sent_body_for(model: "gpt-5.6-mini", effort: effort)["reasoning_effort"]).to eq(mapped)
      end

      it "maps effort #{effort} to reasoning_effort #{mapped} for o-series" do
        expect(sent_body_for(model: "o3-mini", effort: effort)["reasoning_effort"]).to eq(mapped)
      end
    end

    it "does not send reasoning_effort to legacy models" do
      expect(sent_body_for(model: "gpt-4.1", effort: "high")).not_to have_key("reasoning_effort")
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

  describe "Responses API (gpt-6*)" do
    let(:responses_url) { "https://api.openai.com/v1/responses" }
    let(:provider) { described_class.new(model: "gpt-6.1-sol", effort: "xhigh", max_tokens: 500) }
    let(:tools) do
      [{ name: "get_weather", description: "Get weather",
         parameters: { type: "object", properties: { location: { type: "string" } }, required: ["location"] } }]
    end

    def sse(*events)
      events.map { |e| "event: #{e[:type]}\ndata: #{JSON.generate(e)}\n\n" }.join
    end

    def stub_stream(body)
      stub_request(:post, responses_url)
        .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })
    end

    def sent_body
      body = nil
      expect(WebMock).to(have_requested(:post, responses_url).with { |req| body = JSON.parse(req.body) })
      body
    end

    let(:completed_event) do
      { type: "response.completed",
        response: { id: "resp_1", status: "completed", output: [],
                    usage: { input_tokens: 42, input_tokens_details: { cached_tokens: 8 },
                             output_tokens: 17, output_tokens_details: { reasoning_tokens: 5 },
                             total_tokens: 59 } } }
    end

    let(:sync_body) do
      {
        id: "resp_1", object: "response", status: "completed",
        output: [
          { id: "rs_1", type: "reasoning", summary: [] },
          { id: "msg_1", type: "message", role: "assistant", status: "completed",
            content: [{ type: "output_text", text: "Hi ", annotations: [] },
                      { type: "output_text", text: "there", annotations: [] }] },
          { id: "fc_1", type: "function_call", call_id: "call_1", name: "get_weather",
            arguments: '{"location":"Tokyo"}', status: "completed" }
        ],
        usage: { input_tokens: 10, input_tokens_details: { cached_tokens: 0 },
                 output_tokens: 20, output_tokens_details: { reasoning_tokens: 4 }, total_tokens: 30 }
      }
    end

    %w[gpt-6-luna gpt-6.1-sol gpt-6-astra].each do |model|
      it "sends #{model} to /v1/responses, not chat/completions" do
        stub_stream(sse(completed_event))
        described_class.new(model: model).chat(messages: messages) { |_| }
        expect(WebMock).to have_requested(:post, responses_url)
        expect(WebMock).not_to have_requested(:post, api_url)
      end
    end

    it "builds the request with instructions, flat function tools, reasoning effort and max_output_tokens" do
      stub_stream(sse(completed_event))
      provider.chat(messages: messages, system: "Be brief", tools: tools) { |_| }

      body = sent_body
      expect(body["model"]).to eq("gpt-6.1-sol")
      expect(body["instructions"]).to eq("Be brief")
      expect(body["input"]).to eq([{ "role" => "user", "content" => "Hello" }])
      expect(body["tools"]).to eq([{
                                    "type" => "function", "name" => "get_weather", "description" => "Get weather",
                                    "parameters" => { "type" => "object",
                                                      "properties" => { "location" => { "type" => "string" } },
                                                      "required" => ["location"] },
                                    "strict" => false
                                  }])
      expect(body["reasoning"]).to eq({ "effort" => "xhigh" })
      expect(body["max_output_tokens"]).to eq(500)
      expect(body["stream"]).to be(true)
      expect(body["store"]).to be(false)
      %w[messages max_completion_tokens max_tokens reasoning_effort stream_options temperature].each do |key|
        expect(body).not_to have_key(key)
      end
    end

    it "omits instructions, tools and reasoning when not given" do
      stub_stream(sse(completed_event))
      described_class.new(model: "gpt-6-luna", temperature: 0.3).chat(messages: messages, tools: []) { |_| }

      body = sent_body
      %w[instructions tools reasoning temperature].each { |key| expect(body).not_to have_key(key) }
    end

    %w[low medium high xhigh max].each do |effort|
      it "passes effort #{effort} through unchanged" do
        stub_stream(sse(completed_event))
        described_class.new(model: "gpt-6-astra", effort: effort).chat(messages: messages) { |_| }
        expect(sent_body["reasoning"]).to eq({ "effort" => effort })
      end
    end

    it "streams text deltas and returns content and usage" do
      stub_stream(sse(
                    { type: "response.created", response: { id: "resp_1", status: "in_progress" } },
                    { type: "response.output_item.added", output_index: 0,
                      item: { id: "msg_1", type: "message", role: "assistant", content: [] } },
                    { type: "response.output_text.delta", item_id: "msg_1", output_index: 0, content_index: 0,
                      delta: "Hello" },
                    { type: "response.output_text.delta", item_id: "msg_1", output_index: 0, content_index: 0,
                      delta: " world" },
                    { type: "response.output_text.done", item_id: "msg_1", output_index: 0, content_index: 0,
                      text: "Hello world" },
                    completed_event
                  ))

      chunks = []
      result = provider.chat(messages: messages) { |chunk| chunks << chunk }

      expect(chunks).to eq([{ content: "Hello" }, { content: " world" }])
      expect(result[:content]).to eq("Hello world")
      expect(result[:tool_calls]).to eq([])
      expect(result[:usage]).to eq({ input: 42, output: 17, cached_input: 8 })
      expect(result[:latency_ms]).to be_a(Integer)
      expect(result[:raw_response]).not_to be_nil
    end

    it "assembles streamed function calls from argument deltas, keyed by call_id" do
      body = sse(
        { type: "response.output_item.added", output_index: 0,
          item: { id: "rs_1", type: "reasoning", summary: [] } },
        { type: "response.output_item.added", output_index: 1,
          item: { id: "fc_1", type: "function_call", call_id: "call_1", name: "get_weather", arguments: "" } },
        { type: "response.function_call_arguments.delta", item_id: "fc_1", output_index: 1, delta: '{"loca' },
        { type: "response.function_call_arguments.delta", item_id: "fc_1", output_index: 1, delta: 'tion":"Tokyo"}' },
        { type: "response.function_call_arguments.done", item_id: "fc_1", output_index: 1,
          arguments: '{"location":"Tokyo"}' },
        { type: "response.output_item.added", output_index: 2,
          item: { id: "fc_2", type: "function_call", call_id: "call_2", name: "get_time", arguments: "" } },
        { type: "response.function_call_arguments.delta", item_id: "fc_2", output_index: 2, delta: "{}" },
        { type: "response.output_item.done", output_index: 2,
          item: { id: "fc_2", type: "function_call", call_id: "call_2", name: "get_time", arguments: "{}" } },
        completed_event
      )
      stub_request(:post, responses_url)
        .to_return(status: 200, body: body, headers: { "Content-Type" => "text/event-stream" })

      chunks = []
      result = provider.chat(messages: messages, tools: tools) { |chunk| chunks << chunk }

      expect(chunks).to eq([])
      expect(result[:content]).to eq("")
      expect(result[:tool_calls]).to eq([
                                          { id: "call_1", name: "get_weather", input: { "location" => "Tokyo" } },
                                          { id: "call_2", name: "get_time", input: {} }
                                        ])
    end

    it "translates a multi-turn tool loop into function_call / function_call_output items" do
      stub_stream(sse(completed_event))
      msgs = [
        { role: "user", content: "Weather?" },
        { role: "assistant", content: nil,
          tool_calls: [{ id: "call_1", name: "get_weather", input: { "location" => "Tokyo" } },
                       { "id" => "call_2", "name" => "get_time", "input" => "{}" }] },
        { role: "tool", tool_call_id: "call_1", content: '{"temp":18}' },
        { "role" => "tool", "tool_call_id" => "call_2", "content" => { "now" => "noon" } },
        { role: "tool", tool_call_id: "orphan", content: "dropped" },
        { role: "assistant", content: "Let me check more.",
          tool_calls: [{ id: "call_3", name: "get_weather", input: { "location" => "Osaka" } }] },
        { role: "tool", tool_call_id: "call_3", content: "rain" },
        { role: "assistant", content: "It is 18C." },
        { role: "user", content: "Thanks" }
      ]

      provider.chat(messages: msgs, tools: tools) { |_| }

      expect(sent_body["input"]).to eq([
                                         { "role" => "user", "content" => "Weather?" },
                                         { "type" => "function_call", "call_id" => "call_1", "name" => "get_weather",
                                           "arguments" => '{"location":"Tokyo"}' },
                                         { "type" => "function_call", "call_id" => "call_2", "name" => "get_time",
                                           "arguments" => "{}" },
                                         { "type" => "function_call_output", "call_id" => "call_1",
                                           "output" => '{"temp":18}' },
                                         { "type" => "function_call_output", "call_id" => "call_2",
                                           "output" => '{"now":"noon"}' },
                                         { "role" => "assistant", "content" => "Let me check more." },
                                         { "type" => "function_call", "call_id" => "call_3", "name" => "get_weather",
                                           "arguments" => '{"location":"Osaka"}' },
                                         { "type" => "function_call_output", "call_id" => "call_3", "output" => "rain" },
                                         { "role" => "assistant", "content" => "It is 18C." },
                                         { "role" => "user", "content" => "Thanks" }
                                       ])
    end

    it "raises ProviderError on an error event" do
      stub_stream(sse({ type: "error", code: "server_error", message: "Something went wrong", param: nil }))
      expect { provider.chat(messages: messages) { |_| } }
        .to raise_error(LlmProviders::ProviderError, /Something went wrong/)
    end

    it "raises ProviderError on response.failed" do
      stub_stream(sse(
                    { type: "response.output_text.delta", item_id: "msg_1", output_index: 0, delta: "Hel" },
                    { type: "response.failed",
                      response: { id: "resp_1", status: "failed", output: [], usage: nil,
                                  error: { code: "server_error", message: "The model failed to generate a response." } } }
                  ))
      expect { provider.chat(messages: messages) { |_| } }
        .to raise_error(LlmProviders::ProviderError, /failed to generate/)
    end

    it "returns partial content on response.incomplete" do
      stub_stream(sse(
                    { type: "response.output_text.delta", item_id: "msg_1", output_index: 0, delta: "Partial" },
                    { type: "response.incomplete",
                      response: { id: "resp_1", status: "incomplete", incomplete_details: { reason: "max_output_tokens" },
                                  output: [], usage: { input_tokens: 3, output_tokens: 500 } } }
                  ))
      result = provider.chat(messages: messages) { |_| }
      expect(result[:content]).to eq("Partial")
      expect(result[:usage]).to include(input: 3, output: 500)
    end

    it "raises ProviderError with the API message on HTTP 400 while streaming" do
      stub_request(:post, responses_url).to_return(
        status: 400,
        body: { error: { message: "Unsupported parameter: 'foo'", type: "invalid_request_error" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      expect { provider.chat(messages: messages) { |_| } }
        .to raise_error(LlmProviders::ProviderError, /Unsupported parameter/)
    end

    context "without a block (synchronous)" do
      before do
        stub_request(:post, responses_url)
          .to_return(status: 200, body: sync_body.to_json, headers: { "Content-Type" => "application/json" })
      end

      it_behaves_like "a provider"

      it "parses text, function calls and usage from output items" do
        result = provider.chat(messages: messages, tools: tools)
        expect(result[:content]).to eq("Hi there")
        expect(result[:tool_calls]).to eq([{ id: "call_1", name: "get_weather", input: { "location" => "Tokyo" } }])
        expect(result[:usage]).to eq({ input: 10, output: 20, cached_input: 0 })
        expect(sent_body).not_to have_key("stream")
      end
    end

    it "raises ProviderError on a synchronous HTTP error" do
      stub_request(:post, responses_url).to_return(
        status: 400, body: { error: { message: "Bad input" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      expect { provider.chat(messages: messages) }.to raise_error(LlmProviders::ProviderError, /Bad input/)
    end

    it "raises ProviderError when a synchronous response has status failed" do
      stub_request(:post, responses_url).to_return(
        status: 200,
        body: { id: "resp_1", status: "failed", output: [], error: { code: "server_error", message: "boom" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      expect { provider.chat(messages: messages) }.to raise_error(LlmProviders::ProviderError, /boom/)
    end

    %w[gpt-5.6-mini gpt-5-mini gpt-4o o3-mini].each do |model|
      it "keeps #{model} on chat/completions" do
        stub_request(:post, api_url).to_return(
          status: 200,
          body: { choices: [{ message: { role: "assistant", content: "ok" } }],
                  usage: { prompt_tokens: 1, completion_tokens: 1 } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
        described_class.new(model: model).chat(messages: messages, tools: tools)
        expect(WebMock).to have_requested(:post, api_url)
        expect(WebMock).not_to have_requested(:post, responses_url)
      end
    end
  end
end
