# frozen_string_literal: true

module LlmProviders
  class ProviderError < StandardError
    attr_reader :code

    def initialize(message, code: nil)
      @code = code
      super(message)
    end
  end
end
