# frozen_string_literal: true

RSpec.describe LlmProviders::Providers::Base do
  let(:klass) do
    Class.new(described_class) do
      protected

      def default_model = "test-model"
    end
  end

  it "defaults temperature to nil" do
    expect(klass.new.instance_variable_get(:@temperature)).to be_nil
  end

  it "keeps an explicit temperature" do
    expect(klass.new(temperature: 0.3).instance_variable_get(:@temperature)).to eq(0.3)
  end

  it "defaults effort to nil" do
    expect(klass.new.instance_variable_get(:@effort)).to be_nil
  end

  %w[low medium high xhigh max].each do |level|
    it "accepts effort #{level}" do
      expect(klass.new(effort: level).instance_variable_get(:@effort)).to eq(level)
    end
  end

  it "accepts a symbol effort and normalizes it to a string" do
    expect(klass.new(effort: :high).instance_variable_get(:@effort)).to eq("high")
  end

  it "raises ArgumentError for unknown effort" do
    expect { klass.new(effort: "extreme") }.to raise_error(ArgumentError, /effort/)
  end

  it "keeps the max_tokens default" do
    expect(klass.new.instance_variable_get(:@max_tokens)).to eq(16_384)
  end
end
