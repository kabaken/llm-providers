# frozen_string_literal: true

require "logger"

module LlmProviders
  class Configuration
    attr_accessor :logger

    def initialize
      @logger = Logger.new($stdout)
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def logger
      configuration.logger
    end
  end
end
