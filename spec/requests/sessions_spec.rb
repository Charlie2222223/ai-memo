# ============================================================================
# ログイン・ログアウトのテスト
#
# 【リクエストスペックとは】
#   実際にHTTPリクエストを送り、返ってきた応答を検証するテスト。
#   コントローラのメソッドを直接呼ぶのではなく、
#   ルーティング → ミドルウェア → コントローラ → 応答
#   という本番と同じ経路を通る。
#
#   経路の途中（ルーティングの書き間違い、認証の掛け忘れ）まで
#   まとめて検証できるので、費用対効果が高い。
#
# 【RSpecの読み方】
#   describe … 何についてのテストか
#   context  … どういう状況のときか
#   it       … そのとき何が起きるべきか
#
#   繋げて読むと英文になる:
#     "POST /api/session ... 正しい認証情報のとき ... ログインできる"
# ============================================================================
require "rails_helper"

RSpec.describe "Sessions", type: :request do
  # let! は「各テストの実行前に必ず作る」という意味。
  # 【let（!なし）との違い】let は「初めて参照されたときに作る」遅延評価。
  #   ここではテスト本体が user を参照しない場合でも
  #   DBにユーザーが存在していてほしいので let! を使う。
  let!(:user) { create(:user, email: "owner@example.com") }

  # ==========================================================================
  describe "POST /api/session（ログイン）" do
    context "正しいメールアドレスとパスワードのとき" do
      it "200を返し、ユーザー情報が含まれる" do
        post "/api/session", params: {
          email: user.email,
          password: AuthHelper::TEST_PASSWORD
        }

        expect(response).to have_http_status(:ok)
        expect(json_body[:user][:email]).to eq("owner@example.com")
      end

      it "パスワードのハッシュ値が応答に含まれない" do
        # 【なぜこれをテストするか】
        #   user.to_json のような書き方をすると全カラムが出力され、
        #   password_digest まで漏れる。
        #   今は許可リスト方式で書いているので漏れないが、
        #   将来うっかり書き換えたときに気付けるよう固定しておく。
        #
        #   「今は正しい」ではなく「将来も壊れない」ようにするのがテストの役目。
        post "/api/session", params: {
          email: user.email, password: AuthHelper::TEST_PASSWORD
        }

        expect(response.body).not_to include("password_digest")
        expect(response.body).not_to include(user.password_digest)
      end

      it "ログイン後はセッションが有効になり、認証必須のAPIが叩ける" do
        post "/api/session", params: {
          email: user.email, password: AuthHelper::TEST_PASSWORD
        }

        # ログイン確認用のAPIを叩いて、ログイン状態が保持されているか見る。
        # 【ここで検証している本質】
        #   Set-Cookie でセッションCookieが発行され、
        #   次のリクエストでそれが送り返され、
        #   Railsが署名を検証してユーザーを復元できている——
        #   という一連の流れがすべて動いていること。
        get "/api/session"
        expect(json_body[:user][:id]).to eq(user.id)
      end
    end

    context "パスワードが間違っているとき" do
      it "401を返す" do
        post "/api/session", params: {
          email: user.email, password: "wrong-password-xxxx"
        }
        expect(response).to have_http_status(:unauthorized)
      end

      it "ログイン状態にならない" do
        post "/api/session", params: {
          email: user.email, password: "wrong-password-xxxx"
        }

        get "/api/session"
        expect(json_body[:user]).to be_nil
      end
    end

    context "存在しないメールアドレスのとき" do
      it "401を返す" do
        post "/api/session", params: {
          email: "nobody@example.com", password: AuthHelper::TEST_PASSWORD
        }
        expect(response).to have_http_status(:unauthorized)
      end

      it "パスワード間違いのときと同じメッセージを返す" do
        # ------------------------------------------------------------------
        # 【このテストが守っているもの】← セキュリティ上の要件
        #   「メールアドレスが存在しません」と区別できるメッセージを返すと、
        #   攻撃者はアドレスを次々送るだけで
        #   「どのアドレスが登録済みか」を調べられる（列挙攻撃）。
        #
        #   登録済みと分かれば、そのアドレスに的を絞って
        #   パスワードの総当たりやフィッシングができてしまう。
        #
        #   将来「親切にしよう」としてメッセージを分けてしまう改変を、
        #   このテストが機械的に止めてくれる。
        #   ——セキュリティ要件は人の記憶ではなくテストで守る。
        # ------------------------------------------------------------------
        post "/api/session", params: {
          email: "nobody@example.com", password: "whatever-1234"
        }
        message_for_unknown_email = json_body[:error]

        post "/api/session", params: {
          email: user.email, password: "wrong-password-xxxx"
        }
        message_for_wrong_password = json_body[:error]

        expect(message_for_unknown_email).to eq(message_for_wrong_password)
      end
    end

    context "メールアドレスの大文字・小文字や余分な空白があるとき" do
      it "正規化されてログインできる" do
        # 【なぜこれが必要か】メールアドレスは仕様上、大文字小文字を区別しない。
        #   スマホの自動大文字化や、コピペで混入する末尾の空白は日常的に起きる。
        #   「打ち間違えていないのにログインできない」は
        #   ユーザーが最も理不尽に感じる不具合なので、テストで固定する。
        post "/api/session", params: {
          email: "  OWNER@Example.COM  ",
          password: AuthHelper::TEST_PASSWORD
        }
        expect(response).to have_http_status(:ok)
      end
    end
  end

  # ==========================================================================
  describe "GET /api/session（ログイン状態の確認）" do
    context "未ログインのとき" do
      it "200かつ user が null を返す" do
        get "/api/session"

        # 【なぜ401ではなく200なのか】
        #   「ログインしているか？」への「していない」は、
        #   エラーではなく正常な回答。
        #   401にするとブラウザのコンソールが赤くなり、
        #   本物の異常と区別がつかなくなる。
        expect(response).to have_http_status(:ok)
        expect(json_body[:user]).to be_nil
      end
    end

    context "ログイン済みのとき" do
      it "ユーザー情報を返す" do
        sign_in_as(user)
        get "/api/session"
        expect(json_body[:user][:email]).to eq(user.email)
      end
    end
  end

  # ==========================================================================
  describe "DELETE /api/session（ログアウト）" do
    it "204を返し、セッションが無効になる" do
      sign_in_as(user)

      delete "/api/session"
      expect(response).to have_http_status(:no_content)

      # ログアウト後は未ログイン状態に戻っていること。
      get "/api/session"
      expect(json_body[:user]).to be_nil
    end
  end

  # ==========================================================================
  describe "認証が必要なエンドポイントの保護" do
    it "未ログインで /api/terms を叩くと401になる" do
      # ----------------------------------------------------------------------
      # 【このテストの意味】← 設計そのものを守るテスト
      #   ApplicationController に before_action :require_authentication を
      #   書いたことで、明示的に外さない限り全コントローラが保護される。
      #
      #   将来コントローラを追加したとき、
      #   誰かが誤って skip_before_action を書いてしまったら
      #   このテストが落ちて気付ける。
      #
      #   「セキュアバイデフォルト」という設計判断を、
      #   コメントではなくテストで担保している。
      # ----------------------------------------------------------------------
      get "/api/terms"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
