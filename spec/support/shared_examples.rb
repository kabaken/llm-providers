# frozen_string_literal: true

RSpec.shared_examples "a provider" do
  describe "#chat" do
    context "with synchronous response" do
      it "returns content" do
        result = provider.chat(messages: messages)
        expect(result[:content]).to be_a(String)
        expect(result[:content]).not_to be_empty
      end

      it "returns usage info" do
        result = provider.chat(messages: messages)
        expect(result[:usage]).to include(:input, :output)
      end

      it "returns latency_ms" do
        result = provider.chat(messages: messages)
        expect(result[:latency_ms]).to be_a(Integer)
      end

      it "returns raw_response" do
        result = provider.chat(messages: messages)
        expect(result[:raw_response]).not_to be_nil
      end
    end
  end

  describe "default_model" do
    it "returns a non-empty string" do
      expect(provider.send(:default_model)).to be_a(String)
      expect(provider.send(:default_model)).not_to be_empty
    end
  end
end

RSpec.shared_examples "a provider with API error handling" do
  context "with 401 unauthorized" do
    it "raises ProviderError" do
      expect { provider.chat(messages: messages) }
        .to raise_error(LlmProviders::ProviderError)
    end
  end
end

RSpec.shared_examples "a provider with missing API key" do |env_var|
  context "when #{env_var} is not set" do
    before { ENV.delete(env_var) }

    it "raises KeyError" do
      expect { provider.chat(messages: messages) }
        .to raise_error(KeyError)
    end
  end
end
