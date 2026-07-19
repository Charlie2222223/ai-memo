# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # ==========================================================================
  # Host Authorization（ホスト名の検査）をテストでは無効化する
  # ==========================================================================
  # 【Host Authorization とは】
  #   Rails は届いたリクエストの Host ヘッダを見て、
  #   許可リストにないホスト名なら 403 で拒否する。
  #
  # 【何を防いでいるのか — DNSリバインディング攻撃】
  #   ① 攻撃者が evil.example というドメインを用意し、
  #      DNSの応答を一瞬だけ 127.0.0.1 に書き換える
  #   ② 被害者がそのページを開くと、ブラウザから見れば
  #      「evil.example へのアクセス」だが、実際の接続先は
  #      被害者のPC内で動いている開発サーバー
  #   ③ ブラウザの同一オリジンポリシーは
  #      「evil.example 同士の通信」と誤認して許してしまう
  #   ④ 攻撃者のJavaScriptから、被害者のローカル環境の
  #      画面やAPIの中身を読み取れてしまう
  #
  #   Railsは Host ヘッダを直接見ることでこれを弾く。
  #   （DNSがどう解決されようと、ブラウザが送るHostは evil.example のため）
  #
  # 【なぜテストでは無効にするのか】
  #   リクエストスペックは既定で "www.example.com" を名乗るが、
  #   既定の許可リストは .localhost / .test / 各IPアドレスのみ。
  #   一致しないため、全てのリクエストが 403 で弾かれてしまう。
  #
  #   テストにはそもそもブラウザも攻撃者も存在せず、
  #   この防御が守る対象が無い。
  #   ホスト名を許可リストに足していく手もあるが、
  #   テストのたびに増える設定を管理する意味がないので、
  #   テスト環境でのみ検査ごと外す。
  #
  #   【重要】development と production では有効なまま。
  #   ここで消しているのは test 環境だけであり、
  #   実際に外部からアクセスされる環境の防御には影響しない。
  config.hosts.clear

  # ==========================================================================
  # テストではジョブをRedisに積まない
  # ==========================================================================
  # 【なぜ必要か】
  #   config/application.rb で queue_adapter を :sidekiq にしたため、
  #   何もしないとテスト中にも本物のRedisへジョブが積まれる。
  #
  #   すると:
  #     ・テストにRedisの起動が必要になる
  #     ・積まれたジョブが後で本当に実行され、テスト用データを触る
  #     ・「ジョブが積まれたか」を検証する手段が無い
  #
  # 【:test アダプタの動き】
  #   ジョブを実際には実行せず、メモリ上の配列に記録するだけ。
  #   そのおかげで
  #     expect { ... }.to have_enqueued_job(ExplainTermJob)
  #   のように「積まれたこと」を検証できる。
  #
  #   実際に動かして中身を確かめたいときは
  #     perform_now
  #   を使って明示的に実行する（ジョブのテストがそうしている）。
  #
  #   「積まれたか」と「動いたか」を分けて検証できるのが利点。
  config.active_job.queue_adapter = :test

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
