# frozen_string_literal: true

require "set"

module LlmProviders
  module Providers
    class Openai < Base
      API_URL = "https://api.openai.com/v1/chat/completions"
      RESPONSES_API_URL = "https://api.openai.com/v1/responses"

      def chat(messages:, system: nil, tools: nil, &block)
        return responses_chat(messages, system, tools, &block) if responses_api?

        payload = build_payload(messages, system, tools)

        if block_given?
          stream_response(payload, &block)
        else
          sync_response(payload)
        end
      end

      protected

      def default_model
        "gpt-5-mini"
      end

      def api_key
        ENV.fetch("OPENAI_API_KEY")
      end

      private

      def build_payload(messages, system, tools)
        formatted = format_messages(messages, system)
        payload = {
          model: @model,
          messages: formatted
        }

        if reasoning_model?
          payload[:max_completion_tokens] = @max_tokens
          effort = reasoning_effort
          payload[:reasoning_effort] = effort if effort
        else
          payload[:temperature] = @temperature if @temperature
          if @model.match?(/^gpt-4o/)
            payload[:max_completion_tokens] = @max_tokens
          else
            payload[:max_tokens] = @max_tokens
          end
        end

        payload[:tools] = format_tools(tools) if tools && !tools.empty?
        payload
      end

      # Everything except the legacy chat families (gpt-3.5*, gpt-4*) is a
      # reasoning model: gpt-5*, gpt-6*, o-series and whatever comes next.
      def reasoning_model?
        !@model.match?(/^(gpt-3\.5|gpt-4)/)
      end

      # gpt-6* accepts the full effort range; older reasoning models top out at "high".
      def reasoning_effort
        return nil unless @effort
        return @effort if @model.match?(/^gpt-6/)

        %w[xhigh max].include?(@effort) ? "high" : @effort
      end

      def format_messages(messages, system)
        result = []
        result << { role: "system", content: system } if system && !system.empty?

        valid_tool_call_ids = Set.new

        messages.each do |msg|
          msg = stringify_keys(msg)
          case msg["role"]
          when "tool"
            if msg["tool_call_id"] && !msg["tool_call_id"].empty? && valid_tool_call_ids.include?(msg["tool_call_id"])
              result << {
                role: "tool",
                content: msg["content"].to_s,
                tool_call_id: msg["tool_call_id"]
              }
            end
          when "assistant"
            entry = { role: "assistant", content: msg["content"] }
            if msg["tool_calls"] && !msg["tool_calls"].empty?
              valid_tool_calls = msg["tool_calls"].select do |tc|
                tc = stringify_keys(tc)
                tc["name"] && !tc["name"].empty? && tc["id"] && !tc["id"].empty?
              end
              if valid_tool_calls.any?
                entry[:tool_calls] = valid_tool_calls.map do |tc|
                  tc = stringify_keys(tc)
                  valid_tool_call_ids << tc["id"]
                  {
                    id: tc["id"],
                    type: "function",
                    function: {
                      name: tc["name"],
                      arguments: tc["input"].is_a?(String) ? tc["input"] : tc["input"].to_json
                    }
                  }
                end
              end
            end
            result << entry
          else
            result << { role: msg["role"], content: msg["content"] }
          end
        end

        result
      end

      def format_tools(tools)
        tools.map do |tool|
          {
            type: "function",
            function: {
              name: tool[:name],
              description: tool[:description],
              parameters: tool[:parameters]
            }
          }
        end
      end

      def request_headers
        {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{api_key}"
        }
      end

      def stream_response(payload, &block)
        payload[:stream] = true
        payload[:stream_options] = { include_usage: true }
        started_at = Time.now

        full_content = ""
        tool_calls = {}
        usage = {}
        stream_error = nil

        response, raw_chunks = stream_sse(self.class::API_URL, payload) do |event|
          if event["error"]
            stream_error = format_stream_error(event)
            next
          end

          if event["usage"]
            usage = {
              input: event.dig("usage", "prompt_tokens"),
              output: event.dig("usage", "completion_tokens"),
              cached_input: event.dig("usage", "prompt_tokens_details", "cached_tokens")
            }
          end

          choice = event.dig("choices", 0)
          next unless choice

          delta = choice["delta"]
          next unless delta

          if delta["content"]
            full_content += delta["content"]
            block.call(content: delta["content"])
          end

          delta["tool_calls"]&.each do |tc|
            idx = tc["index"]
            tool_calls[idx] ||= { id: "", name: "", arguments: "" }
            tool_calls[idx][:id] = tc["id"] if tc["id"]
            tool_calls[idx][:name] = tc.dig("function", "name") if tc.dig("function", "name")
            tool_calls[idx][:arguments] += tc.dig("function", "arguments").to_s
          end
        end

        raise ProviderError.new(stream_error, code: error_code) if stream_error

        raise_stream_http_error(response, raw_chunks) unless response.success?

        final_tool_calls = tool_calls.values.map do |tc|
          { id: tc[:id], name: tc[:name], input: parse_tool_input(tc[:arguments]) }
        end

        {
          content: full_content,
          tool_calls: final_tool_calls,
          usage: usage,
          latency_ms: ((Time.now - started_at) * 1000).to_i,
          raw_response: { content: full_content, tool_calls: final_tool_calls }
        }
      end

      # POSTs payload and yields each parsed SSE `data:` JSON event.
      # Returns [faraday_response, raw_body].
      def stream_sse(url, payload)
        raw_chunks = +""
        line_buffer = +""

        process_sse_line = proc do |line|
          next unless line.start_with?("data: ")

          data = line.sub("data: ", "").strip
          next if data == "[DONE]" || data.empty?

          begin
            event = JSON.parse(data)
          rescue JSON::ParserError
            next # Skip invalid JSON
          end
          yield event
        end

        conn = Faraday.new do |f|
          f.options.open_timeout = 10
          f.options.read_timeout = 300
          f.options.write_timeout = 30
          f.adapter Faraday.default_adapter
        end

        response = conn.post(url) do |req|
          request_headers.each { |k, v| req.headers[k] = v }
          req.body = payload.to_json
          req.options.on_data = proc do |chunk, _|
            raw_chunks << chunk
            line_buffer << chunk
            lines = line_buffer.split("\n", -1)
            line_buffer = lines.pop || +""

            lines.each(&process_sse_line)
          end
        end

        # Process any remaining data in the buffer
        process_sse_line.call(line_buffer) unless line_buffer.empty?

        [response, raw_chunks]
      end

      def raise_stream_http_error(response, raw_chunks)
        error_body = begin
          JSON.parse(raw_chunks.empty? ? response.body : raw_chunks)
        rescue StandardError
          {}
        end
        error_body = {} unless error_body.is_a?(Hash)
        error_msg = error_body.dig("error", "message") || (raw_chunks.empty? ? nil : raw_chunks) || response.body.to_s
        raise ProviderError.new(error_msg[0, 500], code: error_code)
      end

      def sync_response(payload)
        started_at = Time.now

        response = http_client.post(self.class::API_URL) do |req|
          request_headers.each { |k, v| req.headers[k] = v }
          req.body = payload
        end

        unless response.success?
          raise ProviderError.new(
            parse_sync_error(response),
            code: error_code
          )
        end

        body = response.body
        choice = body.dig("choices", 0, "message")

        content = choice&.dig("content") || ""
        tool_calls = (choice&.dig("tool_calls") || []).map do |tc|
          {
            id: tc["id"],
            name: tc.dig("function", "name"),
            input: parse_tool_input(tc.dig("function", "arguments"))
          }
        end

        {
          content: content,
          tool_calls: tool_calls,
          usage: {
            input: body.dig("usage", "prompt_tokens"),
            output: body.dig("usage", "completion_tokens"),
            cached_input: body.dig("usage", "prompt_tokens_details", "cached_tokens")
          },
          latency_ms: ((Time.now - started_at) * 1000).to_i,
          raw_response: body
        }
      end

      # --- Responses API (/v1/responses) -------------------------------------
      #
      # gpt-6* rejects function tools combined with reasoning_effort on
      # /v1/chat/completions, so those models go through /v1/responses.
      # Everything else (and every OpenRouter model) stays on chat/completions.
      def responses_api?
        @model.match?(/^gpt-6/)
      end

      def responses_chat(messages, system, tools, &block)
        payload = build_responses_payload(messages, system, tools)

        if block
          responses_stream(payload, &block)
        else
          responses_sync(payload)
        end
      end

      def build_responses_payload(messages, system, tools)
        payload = {
          model: @model,
          input: format_input_items(messages),
          max_output_tokens: @max_tokens,
          # chat/completions does not store by default; keep the same behavior.
          store: false
        }
        payload[:instructions] = system if system && !system.empty?
        payload[:reasoning] = { effort: @effort } if @effort
        payload[:tools] = format_responses_tools(tools) if tools && !tools.empty?
        payload
      end

      # Translates the gem's message format into Responses input items.
      # Assistant tool_calls become function_call items and tool results become
      # function_call_output items, linked by call_id (= the tool call id we
      # returned). Item ids (fc_...) are deliberately not sent: we don't replay
      # reasoning items, and the API rejects fc ids without their reasoning item.
      def format_input_items(messages)
        items = []
        valid_call_ids = Set.new

        messages.each do |msg|
          msg = stringify_keys(msg)
          case msg["role"]
          when "tool"
            call_id = msg["tool_call_id"]
            next unless call_id && !call_id.empty? && valid_call_ids.include?(call_id)

            output = msg["content"]
            items << {
              type: "function_call_output",
              call_id: call_id,
              output: output.is_a?(String) ? output : output.to_json
            }
          when "assistant"
            content = msg["content"]
            items << { role: "assistant", content: content } if content.is_a?(String) && !content.empty?

            (msg["tool_calls"] || []).each do |tc|
              tc = stringify_keys(tc)
              next unless tc["name"] && !tc["name"].empty? && tc["id"] && !tc["id"].empty?

              valid_call_ids << tc["id"]
              items << {
                type: "function_call",
                call_id: tc["id"],
                name: tc["name"],
                arguments: tc["input"].is_a?(String) ? tc["input"] : (tc["input"] || {}).to_json
              }
            end
          else
            items << { role: msg["role"], content: msg["content"] }
          end
        end

        items
      end

      # Responses function tools are flat. strict: false keeps the non-strict,
      # best-effort behavior of chat/completions (Responses would otherwise try
      # to coerce schemas into strict mode).
      def format_responses_tools(tools)
        tools.map do |tool|
          {
            type: "function",
            name: tool[:name],
            description: tool[:description],
            parameters: tool[:parameters],
            strict: false
          }
        end
      end

      def responses_stream(payload, &block)
        payload[:stream] = true
        started_at = Time.now

        full_content = +""
        calls = {} # item_id => { id: call_id, name:, arguments: }
        usage = {}
        stream_error = nil

        response, raw_chunks = stream_sse(RESPONSES_API_URL, payload) do |event|
          case event["type"]
          when "response.output_text.delta"
            delta = event["delta"].to_s
            next if delta.empty?

            full_content << delta
            block.call(content: delta)
          when "response.output_item.added", "response.output_item.done"
            item = event["item"] || {}
            next unless item["type"] == "function_call"

            call = (calls[item["id"]] ||= { id: "", name: "", arguments: +"" })
            call[:id] = item["call_id"] if item["call_id"]
            call[:name] = item["name"] if item["name"]
            call[:arguments] = +item["arguments"] if item["arguments"] && !item["arguments"].empty?
          when "response.function_call_arguments.delta"
            call = (calls[event["item_id"]] ||= { id: "", name: "", arguments: +"" })
            call[:arguments] << event["delta"].to_s
          when "response.function_call_arguments.done"
            call = (calls[event["item_id"]] ||= { id: "", name: "", arguments: +"" })
            call[:arguments] = +event["arguments"].to_s
          when "response.completed", "response.incomplete"
            usage = responses_usage(event.dig("response", "usage"))
          when "response.failed"
            stream_error = event.dig("response", "error", "message") || "Response failed"
          when "error"
            stream_error = event["message"] || event.dig("error", "message") || "Stream error"
          end
        end

        raise ProviderError.new(stream_error, code: error_code) if stream_error

        raise_stream_http_error(response, raw_chunks) unless response.success?

        tool_calls = calls.values.map do |tc|
          { id: tc[:id], name: tc[:name], input: parse_tool_input(tc[:arguments]) }
        end

        {
          content: full_content,
          tool_calls: tool_calls,
          usage: usage,
          latency_ms: ((Time.now - started_at) * 1000).to_i,
          raw_response: { content: full_content, tool_calls: tool_calls }
        }
      end

      def responses_sync(payload)
        started_at = Time.now

        response = http_client.post(RESPONSES_API_URL) do |req|
          request_headers.each { |k, v| req.headers[k] = v }
          req.body = payload
        end

        raise ProviderError.new(parse_sync_error(response), code: error_code) unless response.success?

        body = response.body
        if body["status"] == "failed"
          raise ProviderError.new(body.dig("error", "message") || "Response failed", code: error_code)
        end

        output = body["output"] || []
        content = output.select { |item| item["type"] == "message" }
                        .flat_map { |item| item["content"] || [] }
                        .select { |part| part["type"] == "output_text" }
                        .map { |part| part["text"].to_s }
                        .join
        tool_calls = output.select { |item| item["type"] == "function_call" }.map do |item|
          { id: item["call_id"], name: item["name"], input: parse_tool_input(item["arguments"]) }
        end

        {
          content: content,
          tool_calls: tool_calls,
          usage: responses_usage(body["usage"]),
          latency_ms: ((Time.now - started_at) * 1000).to_i,
          raw_response: body
        }
      end

      # output_tokens already includes reasoning tokens.
      def responses_usage(usage)
        return {} unless usage

        {
          input: usage["input_tokens"],
          output: usage["output_tokens"],
          cached_input: usage.dig("input_tokens_details", "cached_tokens")
        }
      end

      def error_code
        "openai_error"
      end

      def format_stream_error(event)
        event.dig("error", "message") || event["error"].to_s
      end

      def parse_sync_error(response)
        response.body.dig("error", "message") || "API error"
      end

      def parse_tool_input(arguments)
        return {} if arguments.nil? || arguments.empty?

        JSON.parse(arguments)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
