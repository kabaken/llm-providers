# frozen_string_literal: true

module LlmProviders
  module Providers
    # Experimental: OpenRouter support is provided as-is.
    # It wraps the OpenAI-compatible API at openrouter.ai.
    # Not all features may work as expected with every model.
    class Openrouter < Openai
      API_URL = "https://openrouter.ai/api/v1/chat/completions"

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

      def request_headers
        headers = super
        headers["X-Title"] = @app_name if @app_name
        headers["HTTP-Referer"] = @app_url if @app_url
        headers
      end
    end
  end
end
