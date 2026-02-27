# Changelog

## [0.2.0] - 2026-02-27

### Added

- OpenRouter provider is now fully supported (no longer experimental)
  - Custom headers: `X-Title`, `HTTP-Referer` via `app_name:` / `app_url:` options or ENV
  - Provider routing: `provider:` option for order, fallback, data collection preferences
  - `Openrouter.models` class method for model discovery
  - Improved error handling with upstream provider name from OpenRouter metadata

### Changed

- Extracted `request_headers` method in OpenAI provider for extensibility
- Extracted `format_stream_error` / `parse_sync_error` methods in OpenAI provider for extensibility

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
