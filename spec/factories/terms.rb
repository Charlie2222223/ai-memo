# ============================================================================
# Term / Tag のファクトリ
# ============================================================================
FactoryBot.define do
  factory :term do
    # 【association の意味】
    #   create(:term) としたとき、紐づく User も自動で作る。
    #   belongs_to :user は必須なので、これが無いと毎回
    #   create(:term, user: create(:user)) と書く必要がある。
    association :user

    # 単語は (user_id, word) で一意なので、毎回違う値にしておく。
    # 【なぜ sequence が要るか】固定値だと、
    #   同じユーザーに2件作るテストで必ず失敗する。
    sequence(:word) { |n| "テスト用語#{n}" }
    context { "テスト用の文脈メモ" }

    # 既定は「生成待ち」。登録直後の状態を表す。
    status { :pending }

    # ------------------------------------------------------------------------
    # trait（状態のバリエーション）
    # ------------------------------------------------------------------------
    # 【trait とは】ファクトリの「派生形」に名前を付ける仕組み。
    #   create(:term, :completed) のように書ける。
    #
    # 【なぜ便利か】
    #   毎回 create(:term, status: :completed, meaning: "...", ...) と
    #   全項目を書くのは冗長で、項目が増えたとき全テストの修正が要る。
    #   「完成済みの単語」という意味に名前を付けておけば、
    #   中身が変わっても呼び出し側は変えなくてよい。
    trait :completed do
      status { :completed }
      meaning { "テスト用の意味の説明です。" }
      examples { [ "例文1", "例文2" ] }
      usage_note { "テスト用の使い方の説明です。" }
      generated_at { Time.current }
    end

    trait :failed do
      status { :failed }
      error_message { "Anthropic::Errors::RateLimitError: レート制限に達しました" }
    end
  end

  factory :tag do
    association :user
    sequence(:name) { |n| "タグ#{n}" }
  end
end
