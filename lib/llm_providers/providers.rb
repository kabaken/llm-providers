# frozen_string_literal: true

require_relative "providers/base"
require_relative "providers/anthropic"
require_relative "providers/openai"
require_relative "providers/google"
require_relative "providers/openrouter"

module LlmProviders
  module Providers
    def self.build(name, **options)
      klass = case name.to_s
              when "openai" then Openai
              when "anthropic" then Anthropic
              when "google" then Google
              when "openrouter" then Openrouter
              else
                raise ArgumentError, "Unknown provider: #{name}"
              end

      klass.new(**options)
    end
  end
end
