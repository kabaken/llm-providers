# frozen_string_literal: true

require "faraday"

module LlmProviders
  module Providers
    class Base
      EFFORT_LEVELS = %w[low medium high xhigh max].freeze

      # temperature: nil means "provider default" (not sent).
      # effort: nil means "provider default"; otherwise one of EFFORT_LEVELS.
      def initialize(model: nil, temperature: nil, max_tokens: nil, effort: nil)
        @model = model || default_model
        @temperature = temperature
        @effort = effort&.to_s
        unless @effort.nil? || EFFORT_LEVELS.include?(@effort)
          raise ArgumentError, "effort must be one of #{EFFORT_LEVELS.join(", ")} (got #{effort.inspect})"
        end
        @max_tokens = max_tokens || 16_384
      end

      def chat(messages:, system: nil, tools: nil, &block)
        raise NotImplementedError
      end

      protected

      def default_model
        raise NotImplementedError
      end

      def api_key
        raise NotImplementedError
      end

      def stringify_keys(hash)
        hash.transform_keys(&:to_s)
      end

      def http_client
        @http_client ||= Faraday.new do |f|
          f.request :json
          f.response :json
          f.options.open_timeout = 10
          f.options.read_timeout = 120
          f.options.write_timeout = 30
          f.adapter Faraday.default_adapter
        end
      end
    end
  end
end
