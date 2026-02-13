# frozen_string_literal: true

RSpec.describe LlmProviders::Providers do
  describe ".build" do
    it "builds an Anthropic provider" do
      provider = described_class.build(:anthropic)
      expect(provider).to be_a(LlmProviders::Providers::Anthropic)
    end

    it "builds an OpenAI provider" do
      provider = described_class.build(:openai)
      expect(provider).to be_a(LlmProviders::Providers::Openai)
    end

    it "builds a Google provider" do
      provider = described_class.build(:google)
      expect(provider).to be_a(LlmProviders::Providers::Google)
    end

    it "builds an OpenRouter provider" do
      provider = described_class.build(:openrouter)
      expect(provider).to be_a(LlmProviders::Providers::Openrouter)
    end

    it "accepts string provider names" do
      provider = described_class.build("anthropic")
      expect(provider).to be_a(LlmProviders::Providers::Anthropic)
    end

    it "raises ArgumentError for unknown providers" do
      expect { described_class.build(:unknown) }.to raise_error(ArgumentError, /Unknown provider/)
    end

    it "passes options to the provider" do
      provider = described_class.build(:anthropic, model: "custom-model", temperature: 0.5)
      expect(provider.instance_variable_get(:@model)).to eq("custom-model")
      expect(provider.instance_variable_get(:@temperature)).to eq(0.5)
    end
  end
end
