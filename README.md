# 単語メモ

知らない技術用語を放り込むと、AI（Claude）が **意味・具体例・使い方** を自動で解説してくれる単語帳。
PC・スマホどちらからも見返せる。

```
[入力] 冪等性
   ↓ 0.05秒で登録完了（待たされない）
[画面] カードが「生成中…」で追加される
   ↓ 裏でAIが生成（約10秒）
[画面] リロードせずにカードが解説入りに変わる
```

---

## 必要なもの

| | 用途 |
|---|---|
| Docker Desktop | 実行環境。これ以外は不要（Ruby も Node も入れない） |
| Anthropic APIキー | AI解説の生成。従量課金 |

**コストの目安**：1単語あたり約 **3.4円**（Opus 4.8）。月30単語で約100円。

> ⚠️ Claude Code のサブスクリプションとは**別物**です。
> https://console.anthropic.com/ から API キーを発行し、$5 以上をチャージしてください。
> キーは発行時の1回しか全文が表示されません。

---

## セットアップ

```bash
# 1. 環境変数ファイルを作る
cp .env.example .env

# 2. .env を編集
#    ANTHROPIC_API_KEY    … 発行したAPIキー
#    SEED_USER_EMAIL      … ログインに使うメールアドレス
#    SEED_USER_PASSWORD   … 12文字以上のパスワード

# 3. 起動（初回は5分ほどかかります）
docker compose up -d

# 4. DBを作成
docker compose exec web rails db:create db:migrate

# 5. 自分のアカウントを作成
docker compose exec web rails db:seed
```

http://localhost:3000 を開き、`.env` に書いたメール・パスワードでログイン。

---

## 動作確認

```bash
docker compose exec web bundle exec rspec        # テスト（64件）
docker compose logs -f worker                    # AI生成の実行状況
```

- Sidekiq 管理画面: http://localhost:3000/sidekiq （要ログイン）
- 使用量とコスト:
  ```bash
  docker compose exec web rails runner 'pp ApiCallLog.monthly_summary'
  ```

---

## スマホから見る

**同じWi-Fi内なら**、PCのIPアドレスを調べてスマホのブラウザで開く。

```powershell
ipconfig | Select-String IPv4
# → 例: 192.168.1.15 なら http://192.168.1.15:3000
```

Rails の Host Authorization に弾かれる場合は
`config/environments/development.rb` に許可ホストを追記します。

**外出先からも見たい場合**は Fly.io へデプロイしてください（`docs/08-デプロイ.md`）。

---

## 構成

```
web    Rails（API・SPA入口・Viteビルド）   :3000
worker Sidekiq（AI呼び出しを別プロセスで）
db     PostgreSQL                        :5432
redis  ジョブキュー ＋ WebSocket の pub/sub
```

| 層 | 技術 |
|---|---|
| バックエンド | Rails 8.1 / Ruby 3.3 |
| フロントエンド | Vue 3 + Vite（SPA） |
| 非同期処理 | Sidekiq 8 + Redis |
| リアルタイム通知 | Action Cable（WebSocket） |
| AI | Claude Opus 4.8（structured output） |
| 認証 | has_secure_password + httpOnly セッションCookie |
| テスト | RSpec + FactoryBot + WebMock |

---

## 学習用ドキュメント

このプロジェクトは**学習目的**で作られており、
全コードに逐次コメントと「なぜそうしたか」の解説が入っています。

概念の解説は `docs/` にあります。

| ファイル | 内容 |
|---|---|
| [01-web基礎.md](docs/01-web基礎.md) | HTTP・オリジン・Cookie・セッション |
| [02-認証.md](docs/02-認証.md) | bcrypt・セッション・CSRF・SameSite |
| [03-非同期とWebSocket.md](docs/03-非同期とWebSocket.md) | ジョブキュー・pub/sub・Action Cable |
| [04-LLMハーネス.md](docs/04-LLMハーネス.md) | プロンプト設計・structured output・リトライ・コスト |
| [05-DB設計.md](docs/05-DB設計.md) | ER図・正規化・中間テーブル・N+1・インデックス |
| [06-Docker.md](docs/06-Docker.md) | イメージ・コンテナ・ボリューム・ネットワーク |
| [07-SPAとVue.md](docs/07-SPAとVue.md) | SPA・ルーティング・リアクティブ・状態管理 |
| [08-デプロイ.md](docs/08-デプロイ.md) | Fly.io への公開手順 |

**読む順序の推奨**：`05` → `01` → `02` → `03` → `06` → `07` → `04` → `08`
（データの形 → 通信 → 認証 → 非同期 → 環境 → 画面 → AI → 公開）

---

## よくある操作

```bash
# gemを追加したとき（イメージ再ビルドではなくこちら）
docker compose exec web bundle install
docker compose restart web worker

# DBを作り直す（データは全部消えます）
docker compose down -v
docker compose up -d
docker compose exec web rails db:create db:migrate db:seed

# 失敗した単語を一括で再生成
docker compose exec web rails runner 'Term.failed.each { |t| t.update!(status: :pending); ExplainTermJob.perform_later(t.id) }'
```

---

## 注意

- `.env` は **絶対にコミットしない**（`.gitignore` 済み）。
  公開リポジトリ上のAPIキーは、ボットに数分で発見され悪用されます。
- リトライ回数を増やす変更は、**呼び出し回数 × 3.4円** で試算してから行ってください。
