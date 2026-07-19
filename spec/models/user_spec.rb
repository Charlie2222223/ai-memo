# ============================================================================
# User モデルのテスト
#
# 【モデルスペックで何を検証するか】
#   HTTPを介さず、モデル単体の振る舞いを直接確かめる。
#   検証（バリデーション）・正規化・パスワードの扱いなど。
#
#   リクエストスペックより高速なので、
#   細かい条件の網羅はこちらで行うと効率が良い。
# ============================================================================
require "rails_helper"

RSpec.describe User, type: :model do
  # ==========================================================================
  describe "パスワードの扱い" do
    it "平文のパスワードはDBに保存されない" do
      # ----------------------------------------------------------------------
      # 【このテストが最も重要】
      #   認証の大前提は「平文パスワードをどこにも保存しない」こと。
      #   これが崩れると、DBが漏れた瞬間に全ユーザーの
      #   パスワードがそのまま流出する。
      #
      #   （多くの人がパスワードを使い回しているため、
      #     他のサービスへの侵入にも直結する）
      # ----------------------------------------------------------------------
      user = create(:user, password: "super-secret-1234")

      # DBに保存された生の値を直接読む。
      # 【reload の意味】メモリ上の値ではなくDBから読み直す。
      #   メモリ上には仮想属性 password が残っているので、
      #   DBの実際の中身を見るには読み直しが必要。
      raw = User.connection.select_value(
        "SELECT password_digest FROM users WHERE id = #{user.id}"
      )

      expect(raw).not_to include("super-secret-1234")
      # bcryptの形式であること（$2a$ または $2b$ で始まる）
      expect(raw).to match(/\A\$2[aby]\$/)
    end

    it "同じパスワードでもハッシュ値は毎回異なる" do
      # ----------------------------------------------------------------------
      # 【ソルトの効果を確認するテスト】
      #   bcryptはユーザーごとにランダムなソルト（塩）を混ぜてから
      #   ハッシュ化する。そのため同じパスワードでも保存値は毎回違う。
      #
      #   【なぜそれが重要か】
      #   もし同じパスワード → 同じハッシュ値になると:
      #     ・DBを見るだけで「この2人は同じパスワード」と分かる
      #     ・よくあるパスワードのハッシュ一覧表（レインボーテーブル）
      #       と突き合わせるだけで一括で解読できる
      #
      #   ソルトがあると、一覧表はソルトごとに作り直しになるため
      #   事実上使えなくなる。
      # ----------------------------------------------------------------------
      a = create(:user, password: "identical-password-1")
      b = create(:user, password: "identical-password-1")

      expect(a.password_digest).not_to eq(b.password_digest)
    end

    it "authenticate は正しいパスワードで自分自身を、誤りでfalseを返す" do
      user = create(:user, password: "correct-password-99")

      expect(user.authenticate("correct-password-99")).to eq(user)
      expect(user.authenticate("wrong-password-99")).to be(false)
    end

    it "12文字未満のパスワードは拒否される" do
      user = build(:user, password: "short123")
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end
  end

  # ==========================================================================
  describe "メールアドレスの正規化" do
    it "大文字は小文字に変換される" do
      user = create(:user, email: "MiXeD@Example.COM")
      expect(user.email).to eq("mixed@example.com")
    end

    it "前後の空白は取り除かれる" do
      user = create(:user, email: "  spaced@example.com  ")
      expect(user.email).to eq("spaced@example.com")
    end
  end

  # ==========================================================================
  describe "メールアドレスの一意性" do
    it "大文字小文字が違うだけの重複は拒否される" do
      # 【なぜこのテストが要るか】
      #   正規化（小文字化）とユニーク制約は別々の仕組み。
      #   どちらか片方が欠けると
      #   "user@example.com" と "USER@example.com" が
      #   別人として2件登録できてしまう。
      #   両方が噛み合っていることを確認する。
      create(:user, email: "dup@example.com")
      duplicate = build(:user, email: "DUP@EXAMPLE.COM")

      expect(duplicate).not_to be_valid
    end

    it "DB側の制約でも重複が防がれる（モデルの検証を迂回した場合）" do
      # ----------------------------------------------------------------------
      # 【なぜモデルの検証だけでは不十分なのか】
      #   validates uniqueness は「保存直前にSELECTして確認する」実装。
      #   確認と挿入の間に隙間があるため、同時アクセス時にすり抜ける
      #   （競合状態）。
      #
      #   ここでは検証を意図的に迂回して直接INSERTし、
      #   DB側のユニークインデックスが最後の砦として
      #   機能していることを確認する。
      #
      #   「モデルとDBの二重で守る」という設計判断の裏付けになる。
      #
      # 【insert_all と insert_all! の違い】← ここで一度間違えた箇所
      #   insert_all  … SQLに ON CONFLICT DO NOTHING が付く。
      #                 重複は「黙って無視」され、例外は発生しない。
      #                 大量データを投入して重複だけ飛ばしたいときに使う。
      #   insert_all! … 競合したらそのまま例外（RecordNotUnique）になる。
      #
      #   最初 insert_all で書いたため「例外が出ない」とテストが落ちた。
      #   テスト自体が誤っていた例。
      #   Rubyの ! は「失敗したら例外を投げる版」という慣習で、
      #   save/save!、create/create! も同じ関係にある。
      # ----------------------------------------------------------------------
      create(:user, email: "race@example.com")

      expect {
        User.insert_all!([ {
          email: "race@example.com",
          password_digest: "dummy",
          created_at: Time.current,
          updated_at: Time.current
        } ])
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  # ==========================================================================
  describe "メールアドレスの形式" do
    it "@を含まない文字列は拒否される" do
      expect(build(:user, email: "not-an-email")).not_to be_valid
    end

    it "空は拒否される" do
      expect(build(:user, email: "")).not_to be_valid
    end
  end
end
