# ============================================================================
# ApplicationCable::Connection — WebSocket接続の入口
#
# 【HTTPとWebSocketの認証の違い】
#   HTTPは1リクエストごとに独立していて、毎回Cookieを検証する。
#   WebSocketは一度繋いだら繋ぎっぱなしなので、
#   「接続を確立する瞬間」に1回だけ認証する。
#
#   ここで身元を確定しておけば、以降その接続を通じて流れるデータは
#   すべてそのユーザーのものとして扱える。
#
# 【なぜ認証が必須なのか】
#   認証せずに繋がせると、誰でもWebSocketに接続でき、
#   他人の単語の更新通知を受け取れてしまう。
#   HTTPのAPIに認証を掛けても、WebSocketが素通しでは意味がない。
#   「入口は全部塞ぐ」——1つでも空いていれば穴になる。
# ============================================================================
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    # --------------------------------------------------------------------------
    # 【identified_by とは】
    #   この接続が「誰のものか」を表す目印を設定する。
    #   ここで指定した名前（current_user）が、
    #   各チャンネルの中から参照できるようになる。
    #
    #   また Action Cable は内部でこの値を使って
    #   「このユーザー宛の放送」を正しい接続に届ける。
    # --------------------------------------------------------------------------
    identified_by :current_user

    def connect
      # 接続時に1回だけ実行される。
      # ここで身元を確定できなければ、接続自体を拒否する。
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      # ----------------------------------------------------------------------
      # セッションCookieからユーザーIDを取り出す
      # ----------------------------------------------------------------------
      # 【なぜ session ではなく cookies から読むのか】
      #   Action Cable のコネクションは通常のコントローラではないため、
      #   session メソッドが使えない。
      #   セッションの実体はCookieなので、そこから直接読む。
      #
      # 【cookies.encrypted の意味】
      #   Railsはセッションを暗号化してCookieに保存している。
      #   .encrypted を通すと、サーバーの鍵（config/master.key）で
      #   復号した中身が得られる。
      #
      #   鍵はサーバーだけが持っているので、
      #   ユーザーがCookieを書き換えても復号に失敗し、nil になる。
      #   → 他人になりすますことができない。
      #
      # 【session_options[:key] を使う理由】
      #   Cookieの名前は config/initializers/session_store.rb で
      #   環境によって変えている（本番は __Host- 付き）。
      #   名前を直書きすると、本番でだけ認証が通らなくなる。
      #   設定から取れば必ず一致する。
      session_key = Rails.application.config.session_options[:key]
      session_data = cookies.encrypted[session_key]

      user_id = session_data&.dig("user_id") || session_data&.dig(:user_id)
      user = User.find_by(id: user_id)

      return user if user

      # ----------------------------------------------------------------------
      # 【reject_unauthorized_connection】
      #   接続を拒否して切断する。
      #
      #   ここで nil を返して処理を続けると、
      #   current_user が nil のまま接続が成立してしまい、
      #   後続のチャンネルで NoMethodError が多発する。
      #   入口できっぱり断る方が、原因も分かりやすい。
      # ----------------------------------------------------------------------
      reject_unauthorized_connection
    end
  end
end
