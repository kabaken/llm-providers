# frozen_string_literal: true

require_relative "lib/llm_providers/version"

Gem::Specification.new do |spec|
  spec.name = "llm_providers"
  spec.version = LlmProviders::VERSION
  spec.authors = ["kaba"]
  spec.email = ["kabaken@gmail.com"]

  spec.summary = "Multi-provider LLM client for OpenAI, Anthropic, Google, OpenRouter"
  spec.description = "A unified interface for multiple LLM providers (OpenAI, Anthropic, Google, OpenRouter). " \
                     "Supports streaming, tool calling, and configurable logging."
  spec.homepage = "https://github.com/kabaken/llm-providers"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob("lib/**/*") + %w[README.md README.ja.md LICENSE.txt CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"

  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock", "~> 3.0"
end
