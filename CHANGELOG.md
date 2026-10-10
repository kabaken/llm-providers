# Changelog

## [0.3.0] - 2026-10-10

### Breaking

- `temperature` now defaults to `nil` and is sent only when given (it used to default to 0.7). Pass it explicitly to keep the old behavior on models that still accept it.
- OpenAI reasoning detection is now "everything except the `gpt-3.5*` / `gpt-4*` families". Ids that do not start with those prefixes, such as `ft:gpt-4o-*` fine-tunes, `chatgpt-4o-latest` and `gpt-oss-*`, are now treated as reasoning models: they get `max_completion_tokens` and no `temperature`. OpenRouter is unaffected.

### Changed

- Anthropic non-streaming responses join all text blocks instead of taking the first.
- Anthropic debug output goes through `LlmProviders.logger.debug` instead of `puts`.

### Added

- `effort:` option (`low`, `medium`, `high`, `xhigh`, `max`; `nil` for the provider default). Anthropic sends `output_config.effort`, OpenAI sends `reasoning_effort` (clamped to `high` below gpt-6), Google sends `thinkingConfig.thinkingLevel` (Gemini 3 and later only; xhigh and max become high), OpenRouter sends `reasoning.effort` (xhigh and max become high). Unknown values raise `ArgumentError`.

### Fixed

- GPT-6 and gpt-5.x models now get `max_completion_tokens` instead of `max_tokens`.
- Claude 5.x no longer fails with "`temperature` is deprecated for this model".
- Gemini usage `output` now includes thought tokens, so it is never nil; a response that hits MAX_TOKENS with no text returns empty content instead of raising.
- Anthropic thinking blocks and `thinking_delta` / `signature_delta` events are ignored in results; Gemini thought-summary parts are left out of content.

## [0.2.2] - 2026-02-27

### Fixed

- Update READMEs: remove experimental label from OpenRouter, add OpenRouter usage docs (headers, routing, models API, error handling)

## [0.2.1] - 2026-02-27

### Fixed

- Fix `examples/simple_chat.rb` crash when provider name is passed as argument (`gets` → `$stdin.gets`)
- All examples now accept optional model name argument (e.g., `ruby examples/simple_chat.rb openrouter google/gemini-2.5-flash`)

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
