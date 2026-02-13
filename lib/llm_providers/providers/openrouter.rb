# frozen_string_literal: true

module LlmProviders
  module Providers
    # Experimental: OpenRouter support is provided as-is.
    # It wraps the OpenAI-compatible API at openrouter.ai.
    # Not all features may work as expected with every model.
    class Openrouter < Openai
      API_URL = "https://openrouter.ai/api/v1/chat/completions"

      protected

      def default_model
        "anthropic/claude-sonnet-4.5"
      end

      def api_key
        ENV.fetch("OPENROUTER_API_KEY")
      end
    end
  end
end
