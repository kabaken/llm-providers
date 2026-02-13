# frozen_string_literal: true

require "securerandom"

module LlmProviders
  module Providers
    class Google < Base
      BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"

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
        "gemini-2.5-flash"
      end

      def api_key
        ENV.fetch("GOOGLE_API_KEY")
      end

      private

      def api_url(stream: false)
        action = stream ? "streamGenerateContent" : "generateContent"
        "#{BASE_URL}/#{@model}:#{action}?key=#{api_key}"
      end

      def build_payload(messages, system, tools)
        payload = {
          contents: format_messages(messages),
          generationConfig: {
            maxOutputTokens: @max_tokens,
            temperature: @temperature
          }
        }

        payload[:system_instruction] = { parts: [{ text: system }] } if system && !system.empty?

        payload[:tools] = format_tools(tools) if tools && !tools.empty?
        payload
      end

      def format_messages(messages)
        messages.filter_map do |msg|
          msg = stringify_keys(msg)
          next if msg["role"] == "system"

          role = msg["role"] == "assistant" ? "model" : msg["role"]

          if msg["role"] == "tool"
            {
              role: "function",
              parts: [{
                functionResponse: {
                  name: msg["tool_name"] || "function",
                  response: { content: msg["content"] }
                }
              }]
            }
          elsif msg["tool_calls"] && !msg["tool_calls"].empty?
            parts = []
            parts << { text: msg["content"] } if msg["content"] && !msg["content"].empty?
            msg["tool_calls"].each do |tc|
              tc = stringify_keys(tc)
              parts << {
                functionCall: {
                  name: tc["name"],
                  args: tc["input"]
                }
              }
            end
            { role: role, parts: parts }
          else
            { role: role, parts: [{ text: msg["content"] }] }
          end
        end
      end

      def format_tools(tools)
        [{
          functionDeclarations: tools.map do |tool|
            {
              name: tool[:name],
              description: tool[:description],
              parameters: tool[:parameters]
            }
          end
        }]
      end

      def stream_response(payload, &block)
        started_at = Time.now
        full_content = ""
        tool_calls = []
        usage = {}
        raw_chunks = ""
        line_buffer = ""

        conn = Faraday.new do |f|
          f.options.open_timeout = 10
          f.options.read_timeout = 300
          f.options.write_timeout = 30
          f.adapter Faraday.default_adapter
        end

        url = "#{api_url(stream: true)}&alt=sse"

        response = conn.post(url) do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = payload.to_json
          req.options.on_data = proc do |chunk, _|
            raw_chunks += chunk
            line_buffer += chunk

            while line_buffer.include?("\n")
              line, line_buffer = line_buffer.split("\n", 2)
              process_stream_line(line, tool_calls) do |parsed|
                if parsed[:content]
                  full_content += parsed[:content]
                  block.call(content: parsed[:content])
                end
                usage = parsed[:usage] if parsed[:usage]
              end
            end
          end
        end

        if line_buffer && !line_buffer.empty?
          process_stream_line(line_buffer, tool_calls) do |parsed|
            if parsed[:content]
              full_content += parsed[:content]
              block.call(content: parsed[:content])
            end
            usage = parsed[:usage] if parsed[:usage]
          end
        end

        LlmProviders.logger.debug "[Google] tool_calls: #{tool_calls.inspect}"
        LlmProviders.logger.debug "[Google] response.success?: #{response.success?}, status: #{response.status}"

        unless response.success?
          error_body = begin
            JSON.parse(raw_chunks)
          rescue StandardError
            begin
              JSON.parse(response.body)
            rescue StandardError
              {}
            end
          end
          error_msg = error_body.dig("error", "message") || (raw_chunks.empty? ? nil : raw_chunks) || response.body.to_s
          raise ProviderError.new(
            error_msg[0, 500],
            code: "google_error"
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

      def process_stream_line(line, tool_calls)
        return unless line.start_with?("data: ")

        data = line.sub("data: ", "").strip
        return if data.empty?

        begin
          event = JSON.parse(data)

          candidate = event.dig("candidates", 0)
          if candidate
            parts = candidate.dig("content", "parts") || []
            parts.each do |part|
              yield(content: part["text"]) if part["text"]
              next unless part["functionCall"]

              tool_calls << {
                id: SecureRandom.hex(12),
                name: part.dig("functionCall", "name"),
                input: part.dig("functionCall", "args") || {}
              }
            end
          end

          if event["usageMetadata"]
            yield(usage: {
              input: event.dig("usageMetadata", "promptTokenCount"),
              output: event.dig("usageMetadata", "candidatesTokenCount")
            })
          end
        rescue JSON::ParserError => e
          LlmProviders.logger.debug "[Google] JSON parse error: #{e.message}, data: #{data[0, 200]}"
        end
      end

      def sync_response(payload)
        started_at = Time.now

        response = http_client.post(api_url) do |req|
          req.body = payload
        end

        unless response.success?
          raise ProviderError.new(
            response.body.dig("error", "message") || "API error",
            code: "google_error"
          )
        end

        body = response.body
        candidate = body.dig("candidates", 0)
        parts = candidate&.dig("content", "parts") || []

        content = parts.filter_map { |p| p["text"] }.join
        tool_calls = parts.filter_map do |p|
          next unless p["functionCall"]

          {
            id: SecureRandom.hex(12),
            name: p.dig("functionCall", "name"),
            input: p.dig("functionCall", "args") || {}
          }
        end

        {
          content: content,
          tool_calls: tool_calls,
          usage: {
            input: body.dig("usageMetadata", "promptTokenCount"),
            output: body.dig("usageMetadata", "candidatesTokenCount")
          },
          latency_ms: ((Time.now - started_at) * 1000).to_i,
          raw_response: body
        }
      end
    end
  end
end
