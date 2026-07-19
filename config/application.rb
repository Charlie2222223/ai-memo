require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module App
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # ========================================================================
    # 非同期ジョブの実行方式
    # ========================================================================
    # 【Active Job と Sidekiq の関係】
    #   Active Job … Railsが用意した「ジョブの共通の書き方」
    #   Sidekiq    … 実際にジョブを動かす実装
    #
    #   ジョブのコードは Active Job の書き方で書き、
    #   実際に動かす実装をここで指定する。
    #   将来別の実装に乗り換えるとき、この1行を変えるだけで済む。
    #
    # 【既定値との違い】
    #   指定しない場合の既定は :async で、
    #   「Railsと同じプロセスの中のスレッドで実行する」動きになる。
    #   これだと:
    #     ・Railsを再起動すると実行待ちのジョブが消える
    #     ・Railsのプロセスが重い処理に占有される
    #   ため、非同期にした意味が薄れる。
    #
    #   :sidekiq にすると Redis に積まれ、別プロセスが処理する。
    #   Railsが再起動してもジョブは残る。
    config.active_job.queue_adapter = :sidekiq

    # ========================================================================
    # タイムゾーン
    # ========================================================================
    # 【なぜ設定するか】
    #   既定はUTC。DBにはUTCで保存されるが、
    #   画面やログに出すときは日本時間の方が読みやすい。
    #
    # 【DBはUTCのまま保存される】
    #   config.active_record.default_timezone を変えていないため。
    #   これが正しい。DBは常にUTCで持ち、表示のときだけ変換する。
    #   DBにローカル時刻で保存すると、
    #   サマータイムのある地域や海外からのアクセスで破綻する。
    config.time_zone = "Asia/Tokyo"

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
