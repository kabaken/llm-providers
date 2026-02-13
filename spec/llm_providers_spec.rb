# frozen_string_literal: true

RSpec.describe LlmProviders do
  it "has a version number" do
    expect(LlmProviders::VERSION).not_to be_nil
  end

  describe ".configure" do
    it "allows setting a custom logger" do
      custom_logger = Logger.new(StringIO.new)

      LlmProviders.configure do |config|
        config.logger = custom_logger
      end

      expect(LlmProviders.logger).to eq(custom_logger)
    end
  end

  describe ".logger" do
    it "returns a default logger when not configured" do
      LlmProviders.instance_variable_set(:@configuration, nil)
      expect(LlmProviders.logger).to be_a(Logger)
    end
  end
end
