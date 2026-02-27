# Changelog

## [0.1.1] - 2026-02-27

### Fixed

- Fix SSE streaming parser losing data when HTTP chunk boundaries split SSE data lines mid-line
  - Added line buffering to `stream_response` in Anthropic, OpenAI, and OpenRouter providers
  - Fixes tool call `input_json_delta` events being dropped, which caused tool calls with empty `{}` input

## [0.1.0] - 2026-02-13

- Initial release
- Support for OpenAI, Anthropic, Google, and OpenRouter providers
- Streaming responses
- Tool calling support
- Token usage tracking
- Configurable logging
