# frozen_string_literal: true

module LlmProviders
  module Providers
    class Anthropic < Base
      API_URL = "https://api.anthropic.com/v1/messages"
      API_VERSION = "2023-06-01"

      def chat(messages:, system: nil, tools: nil, &block)
        Time.now

        payload = build_payload(messages, system, tools)

        if block_given?
          stream_response(payload, &block)
        else
          sync_response(payload)
        end
      end

      protected

      def default_model
        "claude-sonnet-4-5-20250929"
      end

      def api_key
        ENV.fetch("ANTHROPIC_API_KEY")
      end

      private

      def build_payload(messages, system, tools)
        payload = {
          model: @model,
          max_tokens: @max_tokens,
          messages: format_messages(messages)
        }

        if system && !system.empty?
          payload[:system] = [
            {
              type: "text",
              text: system,
              cache_control: { type: "ephemeral" }
            }
          ]
        end

        payload[:temperature] = @temperature if @temperature

        if tools && !tools.empty?
          formatted_tools = format_tools(tools)
          payload[:tools] = formatted_tools.map.with_index do |tool, i|
            if i == formatted_tools.size - 1
              tool.merge(cache_control: { type: "ephemeral" })
            else
              tool
            end
          end
        end

        payload
      end

      def format_messages(messages)
        result = []

        messages.each do |msg|
          case msg[:role]
          when "tool"
            tool_result = {
              type: "tool_result",
              tool_use_id: msg[:tool_call_id],
              content: msg[:content]
            }

            if result.last && result.last[:role] == "user" && result.last[:content].is_a?(Array)
              result.last[:content] << tool_result
            else
              result << {
                role: "user",
                content: [tool_result]
              }
            end
          when "assistant"
            if msg[:tool_calls] && !msg[:tool_calls].empty?
              content = []
              content << { type: "text", text: msg[:content] } if msg[:content] && !msg[:content].empty?
              msg[:tool_calls].each do |tc|
                tc = stringify_keys(tc)
                content << {
                  type: "tool_use",
                  id: tc["id"],
                  name: tc["name"],
                  input: tc["input"]
                }
              end
              result << {
                role: "assistant",
                content: content
              }
            else
              result << {
                role: "assistant",
                content: msg[:content]
              }
            end
          else
            result << {
              role: msg[:role],
              content: msg[:content]
            }
          end
        end

        result
      end

      def format_tools(tools)
        tools.map do |tool|
          {
            name: tool[:name],
            description: tool[:description],
            input_schema: tool[:parameters]
          }
        end
      end

      def stream_response(payload, &block)
        payload[:stream] = true
        started_at = Time.now

        full_content = ""
        tool_calls = []
        usage = {}

        conn = Faraday.new do |f|
          f.options.open_timeout = 10
          f.options.read_timeout = 300
          f.options.write_timeout = 30
          f.adapter Faraday.default_adapter
        end

        response = conn.post(API_URL) do |req|
          req.headers["Content-Type"] = "application/json"
          req.headers["x-api-key"] = api_key
          req.headers["anthropic-version"] = API_VERSION
          req.body = payload.to_json
          req.options.on_data = proc do |chunk, _|
            process_stream_chunk(chunk, full_content, tool_calls) do |parsed|
              if parsed[:content]
                full_content += parsed[:content]
                block.call(content: parsed[:content])
              end
              usage = parsed[:usage] if parsed[:usage]
            end
          end
        end

        unless response.success?
          error_message = begin
            if response.body.is_a?(Hash)
              response.body["error"]&.dig("message")
            else
              response.body.to_s
            end
          rescue StandardError
            response.body.to_s
          end
          raise ProviderError.new(
            (error_message && !error_message.empty? ? error_message : nil) || "API error",
            code: "anthropic_error"
          )
        end

        {
          content: full_content,
          tool_calls: tool_calls,
          usage: usage,
          latency_ms: ((Time.now - started_at) * 1000).to_i,
          raw_response: { content: full_content, tool_calls: tool_calls }
        }
      end

      def process_stream_chunk(chunk, _full_content, tool_calls)
        chunk.each_line do |line|
          next unless line.start_with?("data: ")

          data = line.sub("data: ", "").strip
          next if data == "[DONE]"

          begin
            event = JSON.parse(data)

            case event["type"]
            when "content_block_delta"
              if event.dig("delta", "type") == "text_delta"
                yield(content: event.dig("delta", "text"))
              elsif event.dig("delta", "type") == "input_json_delta"
                if tool_calls.any?
                  tool_calls.last[:input_json] ||= ""
                  tool_calls.last[:input_json] += event.dig("delta", "partial_json").to_s
                end
              end
            when "content_block_start"
              if event.dig("content_block", "type") == "tool_use"
                tool_calls << {
                  id: event.dig("content_block", "id"),
                  name: event.dig("content_block", "name"),
                  input: {},
                  input_json: ""
                }
              end
            when "content_block_stop"
              if tool_calls.any? && tool_calls.last[:input_json] && !tool_calls.last[:input_json].empty?
                begin
                  tool_calls.last[:input] = JSON.parse(tool_calls.last[:input_json])
                rescue JSON::ParserError
                  # Keep empty on parse failure
                end
                tool_calls.last.delete(:input_json)
              end
            when "message_delta"
              if event["usage"]
                yield(usage: {
                  input: event.dig("usage", "input_tokens"),
                  output: event.dig("usage", "output_tokens"),
                  cached_input: event.dig("usage", "cache_read_input_tokens")
                })
              end
            end
          rescue JSON::ParserError
            # Skip invalid JSON
          end
        end
      end

      def sync_response(payload)
        started_at = Time.now

        response = http_client.post(API_URL) do |req|
          req.headers["x-api-key"] = api_key
          req.headers["anthropic-version"] = API_VERSION
          req.body = payload
        end

        unless response.success?
          raise ProviderError.new(
            response.body["error"]&.dig("message") || "API error",
            code: "anthropic_error"
          )
        end

        body = response.body
        content = body["content"]&.find { |c| c["type"] == "text" }&.dig("text") || ""

        tool_calls = body["content"]&.select { |c| c["type"] == "tool_use" }&.map do |tc|
          { id: tc["id"], name: tc["name"], input: tc["input"] }
        end || []

        {
          content: content,
          tool_calls: tool_calls,
          usage: {
            input: body.dig("usage", "input_tokens"),
            output: body.dig("usage", "output_tokens"),
            cached_input: body.dig("usage", "cache_read_input_tokens")
          },
          latency_ms: ((Time.now - started_at) * 1000).to_i,
          raw_response: body
        }
      end
    end
  end
end
