# ============================================================================
# Tag モデル — 単語を分類するラベル
# ============================================================================
class Tag < ApplicationRecord
  belongs_to :user

  # Term と同じく、中間テーブル経由の多対多。
  #
  # 【dependent: :destroy の向きに注意】
  #   タグを削除したら、その結び付き（term_tags）は消す。
  #   しかし単語（terms）は消さない。
  #   「インフラ」タグを消しただけで単語が消えたら大惨事になる。
  has_many :term_tags, dependent: :destroy
  has_many :terms, through: :term_tags

  # --------------------------------------------------------------------------
  # タグ名の正規化
  # --------------------------------------------------------------------------
  # 【なぜ小文字化しないのか】← 意図的な判断
  #   メールアドレスと違い、タグ名は大文字小文字に意味がある。
  #   "Rails" を "rails" にすると、画面に出たとき違和感が出る。
  #   "DB" が "db" になるのはさらに具合が悪い。
  #
  #   そこで「表示は入力どおり、比較は小文字で」という方針にする。
  #   ここでは空白の除去だけ行い、重複判定は下の検証で
  #   大文字小文字を無視して行う。
  normalizes :name, with: ->(name) { name.strip }

  validates :name,
            presence: true,
            length: { maximum: 30 },
            uniqueness: { scope: :user_id, case_sensitive: false }

  # --------------------------------------------------------------------------
  # 名前からタグを引く（無ければ作る）
  # --------------------------------------------------------------------------
  # 【なぜクラスメソッドとして用意するのか】
  #   AIがタグを提案してくるとき、そのタグが既にあるか無いか
  #   呼び出し側は知らない。毎回
  #     tag = user.tags.find_by(name: n) || user.tags.create!(name: n)
  #   と書くのは冗長で、書き漏らすと重複が生まれる。
  #
  # 【self.（クラスメソッド）の意味】
  #   Tag.find_or_create_for(...) のように、
  #   個別のタグではなく Tag クラス自体に対して呼ぶメソッド。
  #
  # 【大文字小文字を無視して探す理由】
  #   AIは "Rails" と "rails" を揺れて返す。
  #   小文字で比較して既存を見つけられれば、
  #   表記揺れによる重複タグの乱立を防げる。
  #
  # 【LOWER(name) = LOWER(?) という書き方】
  #   PostgreSQLで大文字小文字を無視した比較をする。
  #   なお、この書き方は name カラムの索引を使えなくする
  #   （関数を通した値は索引と一致しないため）。
  #   タグの件数はたかが知れているので今は問題にならないが、
  #   本来は「小文字化した値の索引」を別途作るのが正攻法。
  def self.find_or_create_for(user, name)
    normalized = name.to_s.strip
    return nil if normalized.blank?

    existing = user.tags.where("LOWER(name) = LOWER(?)", normalized).first
    existing || user.tags.create!(name: normalized)
  end
end
