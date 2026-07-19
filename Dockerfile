# ============================================================================
# 本番用 Dockerfile（Fly.io へのデプロイで使用）
#
# 【Dockerfile.dev との違い】
#   開発用 … コードをボリューム共有し、変更を即反映。デバッグツール入り
#   本番用 … コードをイメージに焼き込み、軽く・速く・安全に
#
# 【マルチステージビルドとは】
#   「ビルドするための環境」と「実行するための環境」を分ける手法。
#
#   Railsのビルドには gcc やヘッダファイルが必要ですが、
#   完成後の実行には不要です。
#   同じイメージに全部入れると 1GB を超え、
#   さらに攻撃者にコンパイラを与えることになります。
#
#   別ステージでビルドし、成果物だけを最終イメージへコピーすれば、
#   イメージは小さく、余計なツールも入りません。
# ============================================================================

# ----------------------------------------------------------------------------
# 共通のベース
# ----------------------------------------------------------------------------
ARG RUBY_VERSION=3.3
FROM ruby:$RUBY_VERSION-slim AS base

WORKDIR /app

# 【実行に必要な最小限のパッケージだけ】
#   libpq5 は libpq-dev（開発用）ではなく実行用のライブラリ。
#   ビルドに必要なヘッダファイルは含まれず、その分小さい。
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libpq5 postgresql-client && \
    rm -rf /var/lib/apt/lists/*

# 【本番用の環境変数】
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    # development / test の gem を入れない（イメージが小さく、攻撃面も減る）
    BUNDLE_WITHOUT="development:test" \
    # ログを標準出力へ。ファイルに書くとコンテナ内に溜まって消える
    RAILS_LOG_TO_STDOUT=true \
    # 静的ファイルをRails自身が配信する（Nginxを別に立てないため）
    RAILS_SERVE_STATIC_FILES=true

# ============================================================================
# ビルド用ステージ（このステージは最終イメージに含まれない）
# ============================================================================
FROM base AS build

# コンパイラとヘッダファイル。gem のビルドと Node のインストールに必要。
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git libpq-dev pkg-config ca-certificates && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install --no-install-recommends -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# 【依存関係を先に】Dockerfile.dev と同じ理由（キャッシュを効かせる）
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    # bundlerのキャッシュとgemに含まれる .git を削除してイメージを削る
    rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY package.json package-lock.json ./
RUN npm ci

# アプリのコードをコピー
COPY . .

# ----------------------------------------------------------------------------
# アセットのプリコンパイル（Vueのビルド）
# ----------------------------------------------------------------------------
# 【なぜビルド時にやるのか】
#   起動のたびにビルドすると、起動が数十秒遅くなり、
#   コンテナが増えるたびに同じ処理を繰り返すことになる。
#   イメージに焼き込めば、起動は一瞬で済む。
#
# 【SECRET_KEY_BASE_DUMMY=1 の意味】
#   Railsはアセットのプリコンパイル時にも秘密鍵を要求する。
#   しかしビルド時に本物の鍵を渡すと、イメージに焼き込まれて漏洩する。
#   この指定でダミーの鍵を使わせ、本物は実行時に環境変数から渡す。
RUN SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile

# ============================================================================
# 最終イメージ（実行用）
# ============================================================================
FROM base

# ビルドステージから「成果物だけ」をコピーする。
# gcc も node_modules も、ここには含まれない。
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /app /app

# ----------------------------------------------------------------------------
# 非root ユーザーで実行する
# ----------------------------------------------------------------------------
# 【なぜ必要か】
#   既定では root で動く。もしアプリに脆弱性があって侵入されたとき、
#   root だとコンテナ内で何でもできてしまう。
#
#   権限を落としておけば、被害の範囲を限定できる。
#   「最小権限の原則」と呼ばれる、セキュリティの基本。
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails /app/tmp /app/log /app/storage 2>/dev/null || true
USER 1000:1000

EXPOSE 3000

# 既定のプロセス。fly.toml の processes でワーカー側は上書きする。
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
