# Docker — イメージ・コンテナ・ボリューム・ネットワーク

---

## 1. 用語

料理でたとえると：

| 用語 | たとえ | 実際 |
|---|---|---|
| **Dockerfile** | レシピ | 「何をどの順に入れるか」の手順書 |
| **イメージ** | 冷凍された完成品 | レシピから作られた、起動可能な状態 |
| **コンテナ** | 皿に盛ったもの | イメージを起動して動いている実体 |
| **ボリューム** | 別の保存容器 | コンテナを消しても残るデータ置き場 |

**1つのイメージから、コンテナを何個でも起動できます。**
このアプリの `web` と `worker` は同じイメージから起動していて、
違いは「起動時に何を実行するか」だけです。

---

## 2. Dockerfileの鉄則：変わりにくいものを先に

```dockerfile
COPY Gemfile Gemfile.lock ./     # ← 先に依存だけコピー
RUN bundle install
COPY . .                          # ← コードは後
```

Dockerは各命令の結果をキャッシュし、**前の行が変わらなければ再利用**します。

もしコード全部を先にコピーすると、
**1文字直すたびに `bundle install` が最初からやり直し**になります（毎回3〜5分）。

Gemfileだけ先にコピーしておけば、gemを追加したときだけ再実行されます。

---

## 3. ボリュームの罠（実際にハマった箇所）

```yaml
volumes:
  - .:/app                        # ホストのコードを共有
  - bundle_data:/usr/local/bundle # ← gem置き場を保護
  - node_modules:/app/node_modules
```

### なぜ2行目以降が必要か

1行目でホスト側を丸ごと被せると、コンテナ内で**ビルド時にインストールした
gem や node_modules も、ホスト側の（存在しない）中身で上書きされて消えます。**

名前付きボリュームを重ねると、その場所だけホストと繋がらず保護されます。

### そして次の罠

> **ボリュームは「空のときだけ」イメージの中身で初期化され、以後は同期されません。**

実際に起きたこと：

```
Gemfileに redis を追加
→ docker compose build（イメージには入った）
→ 起動 → "Could not find gem 'redis'"
```

イメージには入っているのに、ボリュームが古いまま被さっていたためです。

**正しい手順：**

```bash
# ❌ イメージを作り直しても反映されない
docker compose build

# ✅ ボリューム側にインストールする
docker compose exec web bundle install
docker compose restart web worker
```

### 副次的な利点

`node_modules`（数万ファイル）がホスト側に出てこないので、
OneDriveの同期対象にならず、Windowsでの動作が劇的に速くなります。

---

## 4. ネットワーク — 「中から見た世界」と「外から見た世界」

composeは全サービスを1つの仮想ネットワークに入れ、
**サービス名がそのままホスト名**になります。

```yaml
DATABASE_URL: postgres://postgres:password@db:5432/memo_development
                                           ~~
                                        サービス名
```

IPアドレスを調べる必要はありません。

### ここが最初に必ず混乱する

| どこから | DBへの接続先 |
|---|---|
| コンテナの中（Rails） | `db:5432` |
| ホストPC（GUIツール） | `localhost:5432` |

`db` という名前はコンテナの中でしか解決できません。
ブラウザで `http://db:3000` と打っても繋がりません。

### ports は「扉を開ける」宣言

```yaml
ports:
  - "3000:3000"   # ホスト側 : コンテナ側
```

コンテナは既定で外部から隔離されています。
明示的に宣言しないと、ホストから一切繋がりません（安全側が既定）。

**注意**：`redis` には `ports` を書いていません。
コンテナ間からは繋がるので、外に開ける必要がないからです。
**不要な扉は開けない**のが原則です。

### 0.0.0.0 の意味

```dockerfile
CMD ["sh", "-c", "... rails server -b 0.0.0.0 -p 3000"]
```

Railsの既定は `127.0.0.1`（localhost）だけを見ます。
しかし「コンテナの中のlocalhost」はコンテナ内部しか指さないので、
ホストPCから繋がりません。

`0.0.0.0` は「どのネットワーク経由の接続も受ける」の意味です。

---

## 5. 起動順の制御

```yaml
depends_on:
  db:
    condition: service_healthy
```

単なる `depends_on` は「コンテナが起動したら」次へ進むだけで、
**「PostgreSQLが接続を受け付ける状態になったか」までは見ません。**

起動直後のPostgreSQLは内部初期化で数秒間ビジーなので、
Railsが先に起動して接続に失敗します。

```yaml
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U postgres"]
  interval: 5s
  retries: 10
```

`pg_isready` が成功して初めて `healthy` と判定され、`web` の起動が始まります。

---

## 6. 1コンテナ1プロセス

このアプリは開発時5コンテナに分けています。

```
web    Rails
vite   Vite開発サーバー（HMR）※開発のみ
worker Sidekiq
db     PostgreSQL
redis  Redis
```

**なぜ web の中で Sidekiq も動かさないのか**：
片方が落ちてもコンテナは生きたままになり、
**「起動しているのに動かない」**状態の切り分けが難しくなります。

分けておけば `docker compose ps` でどれが落ちたか一目で分かります。

**vite を分けているのも同じ理由**です。
`docker compose logs -f vite` でフロントのビルドエラーだけを追えます。
Rails のリクエストログに混ざると、Vue の構文エラーを見落とします。

なお `vite` は開発専用です。本番では事前にビルドした静的ファイルを配信するため、
このコンテナは存在しません。

### スケールさせる

```bash
docker compose up -d --scale worker=3
```

ワーカーを3プロセスに増やせます。
Redisが待ち行列を管理しているので、複数のワーカーが同じジョブを二重に取ることはありません。

---

## 7. .dockerignore

```
node_modules/
tmp/
.git/
.env          # ← 特に重要
```

`docker build` は最初にフォルダの中身を丸ごとDockerエンジンへ送ります。
`node_modules` を除外しないと、ビルドのたびに数百MBを毎回転送します。

**`.env` の除外は必須**です。イメージに焼き込むと、
そのイメージを共有した相手にAPIキーが渡ります（イメージの中身は誰でも展開できます）。

---

## よく使うコマンド

```bash
docker compose up -d                    # 起動（バックグラウンド）
docker compose ps                       # 状態確認
docker compose logs -f worker           # ログを追う
docker compose exec web bash            # コンテナに入る
docker compose restart web              # 再起動
docker compose down                     # 停止して削除（ボリュームは残る）
docker compose down -v                  # ボリュームごと削除（DBが消える）

# ディスクを食ってきたら
docker system df                        # 使用量を見る
docker system prune                     # 未使用のイメージ等を削除
```

---

## トラブルシューティング

| 症状 | 原因の候補 |
|---|---|
| gemが見つからない | ボリュームが古い → `docker compose exec web bundle install` |
| ホストから繋がらない | `0.0.0.0` でバインドしていない / `ports` の書き忘れ |
| DB接続エラー | ホスト名を `localhost` にしている（`db` にする） |
| 起動直後だけ落ちる | `healthcheck` を設定していない |
| 保存しても反映されない | `volumes` の `.:/app` が抜けている |
| ビルドが毎回遅い | `COPY . .` を `bundle install` より前に書いている |
