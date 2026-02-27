# OpenRouter Full Implementation Design

## Purpose

OpenRouter を experimental から正式実装に昇格させる。3 大メジャープロバイダー (OpenAI, Anthropic, Google) 以外の多数のモデルへの統一ゲートウェイとして利用する。

## Architecture

OpenAI 互換 API のため Openai 継承を維持。差分のみオーバーライド。

## Features

### 1. OpenRouter 固有ヘッダー

`initialize` に `app_name:` / `app_url:` オプションを追加。

- `X-Title` ヘッダー: アプリ名（OpenRouter ダッシュボード表示用）
- `HTTP-Referer` ヘッダー: アプリ URL
- ENV (`OPENROUTER_APP_NAME`, `OPENROUTER_APP_URL`) からのフォールバック

### 2. Provider routing

`initialize` に `provider:` オプションを追加。

- `{ order: ["Anthropic", "Google"] }` のようなハッシュを受け取る
- `build_payload` をオーバーライドし、payload に `provider` フィールドを挿入

### 3. エラーハンドリング改善

OpenRouter 固有のエラーフォーマットをパース。

- `error.metadata.provider_name` でどのプロバイダーで失敗したか明示
- 429 レート制限エラーの検出
- ストリーミング時のエラーも同様にハンドリング

### 4. モデル一覧取得

`self.models` クラスメソッドで `GET /api/v1/models` を呼び出し。

- モデル ID、名前、コンテキスト長、pricing 等を返す

### 5. テスト

- ストリーミング（テキスト + ツール呼び出し）
- チャンク境界分割
- 固有ヘッダー送信確認
- provider routing のペイロード確認
- OpenRouter 固有エラーフォーマットのハンドリング
- モデル一覧取得
- レート制限エラー

## Unchanged

- ストリーミング・同期の基本処理は Openai のまま
- `format_messages`, `format_tools` も Openai のまま
