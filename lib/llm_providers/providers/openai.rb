# frozen_string_literal: true

require "set"

module LlmProviders
  module Providers
    class Openai < Base
      API_URL = "https://api.openai.com/v1/chat/completions"

      def chat(messages:, system: nil, tools: nil, &block)
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
        reasoning_model = @model.match?(/^(o1|o3|o4|gpt-5)/)

        payload = {
          model: @model,
          messages: formatted
        }

        payload[:temperature] = @temperature unless reasoning_model

        if @model.match?(/^(gpt-4o|gpt-5|o1|o3|o4)/)
          payload[:max_completion_tokens] = @max_tokens
        else
          payload[:max_tokens] = @max_tokens
        end

        payload[:tools] = format_tools(tools) if tools && !tools.empty?
        payload
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

      def stream_response(payload, &block)
        payload[:stream] = true
        payload[:stream_options] = { include_usage: true }
        started_at = Time.now

        full_content = ""
        tool_calls = {}
        usage = {}
        raw_chunks = ""
        stream_error = nil

        conn = Faraday.new do |f|
          f.options.open_timeout = 10
          f.options.read_timeout = 300
          f.options.write_timeout = 30
          f.adapter Faraday.default_adapter
        end

        response = conn.post(self.class::API_URL) do |req|
          req.headers["Content-Type"] = "application/json"
          req.headers["Authorization"] = "Bearer #{api_key}"
          req.body = payload.to_json
          req.options.on_data = proc do |chunk, _|
            raw_chunks += chunk
            process_stream_chunk(chunk, full_content, tool_calls) do |parsed|
              if parsed[:content]
                full_content += parsed[:content]
                block.call(content: parsed[:content])
              end
              stream_error = parsed[:error] if parsed[:error]
              usage = parsed[:usage] if parsed[:usage]
            end
          end
        end

        raise ProviderError.new(stream_error, code: "openai_error") if stream_error

        unless response.success?
          error_body = begin
            JSON.parse(raw_chunks.empty? ? response.body : raw_chunks)
          rescue StandardError
            {}
          end
          error_msg = error_body.dig("error", "message") || (raw_chunks.empty? ? nil : raw_chunks) || response.body.to_s
          raise ProviderError.new(
            error_msg[0, 500],
            code: "openai_error"
          )
        end

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

      def process_stream_chunk(chunk, _full_content, tool_calls)
        chunk.each_line do |line|
          next unless line.start_with?("data: ")

          data = line.sub("data: ", "").strip
          next if data == "[DONE]"

          begin
            event = JSON.parse(data)

            if event["error"]
              yield(error: event.dig("error", "message") || event["error"].to_s)
              next
            end

            if event["usage"]
              yield(usage: {
                input: event.dig("usage", "prompt_tokens"),
                output: event.dig("usage", "completion_tokens"),
                cached_input: event.dig("usage", "prompt_tokens_details", "cached_tokens")
              })
            end

            choice = event.dig("choices", 0)
            next unless choice

            delta = choice["delta"]
            next unless delta

            yield(content: delta["content"]) if delta["content"]

            delta["tool_calls"]&.each do |tc|
              idx = tc["index"]
              tool_calls[idx] ||= { id: "", name: "", arguments: "" }
              tool_calls[idx][:id] = tc["id"] if tc["id"]
              tool_calls[idx][:name] = tc.dig("function", "name") if tc.dig("function", "name")
              tool_calls[idx][:arguments] += tc.dig("function", "arguments").to_s
            end
          rescue JSON::ParserError
            # Skip invalid JSON
          end
        end
      end

      def sync_response(payload)
        started_at = Time.now

        response = http_client.post(self.class::API_URL) do |req|
          req.headers["Authorization"] = "Bearer #{api_key}"
          req.body = payload
        end

        unless response.success?
          raise ProviderError.new(
            response.body.dig("error", "message") || "API error",
            code: "openai_error"
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

      def parse_tool_input(arguments)
        return {} if arguments.nil? || arguments.empty?

        JSON.parse(arguments)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
