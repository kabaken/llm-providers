# frozen_string_literal: true

module LlmProviders
  module Providers
    class Openrouter < Openai
      API_URL = "https://openrouter.ai/api/v1/chat/completions"
      MODELS_URL = "https://openrouter.ai/api/v1/models"

      def self.models
        api_key = ENV.fetch("OPENROUTER_API_KEY")
        conn = Faraday.new do |f|
          f.response :json
          f.adapter Faraday.default_adapter
        end

        response = conn.get(MODELS_URL) do |req|
          req.headers["Authorization"] = "Bearer #{api_key}"
        end

        unless response.success?
          error_msg = response.body.dig("error", "message") || "Failed to fetch models"
          raise ProviderError.new(error_msg, code: "openrouter_error")
        end

        (response.body["data"] || []).map do |model|
          {
            id: model["id"],
            name: model["name"],
            context_length: model["context_length"],
            pricing: {
              prompt: model.dig("pricing", "prompt"),
              completion: model.dig("pricing", "completion")
            }
          }
        end
      end

      def initialize(app_name: nil, app_url: nil, provider: nil, **options)
        super(**options)
        @app_name = app_name || ENV["OPENROUTER_APP_NAME"]
        @app_url = app_url || ENV["OPENROUTER_APP_URL"]
        @provider_preferences = provider
      end

      protected

      def default_model
        "anthropic/claude-sonnet-4.5"
      end

      def api_key
        ENV.fetch("OPENROUTER_API_KEY")
      end

      private

      def build_payload(messages, system, tools)
        payload = super
        payload[:provider] = @provider_preferences if @provider_preferences
        payload
      end

      def request_headers
        headers = super
        headers["X-Title"] = @app_name if @app_name
        headers["HTTP-Referer"] = @app_url if @app_url
        headers
      end

      def error_code
        "openrouter_error"
      end

      def format_stream_error(event)
        message = event.dig("error", "message") || event["error"].to_s
        provider_name = event.dig("error", "metadata", "provider_name")
        provider_name ? "[#{provider_name}] #{message}" : message
      end

      def parse_sync_error(response)
        body = response.body
        body = begin
          JSON.parse(body)
        rescue StandardError
          {}
        end if body.is_a?(String)
        message = body.dig("error", "message") || "API error"
        provider_name = body.dig("error", "metadata", "provider_name")
        provider_name ? "[#{provider_name}] #{message}" : message
      end
    end
  end
end
