# ============================================================================
# フォルダAPIのテスト
#
# 【権限境界のテストを最優先で書く理由】
#   フォルダは「利用者が所有するもの」なので、
#   他人のフォルダが見えたり操作できたりしてはならない。
#
#   この種の不具合は画面を触っていても気付けない。
#   自分のデータしか無い開発環境では、境界を越えたことに気付く手段が無い。
#   テストで固定しておく以外に守る方法が無い。
#
#   CLAUDE.md の「権限境界のテストは削除しない」はこのこと。
# ============================================================================
require "rails_helper"

RSpec.describe "Folders", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  before { sign_in_as(user) }

  # ==========================================================================
  # 一覧
  # ==========================================================================
  describe "GET /api/folders" do
    it "自分のフォルダだけが返り、他人のものは混ざらない" do
      mine = user.folders.create!(name: "Web・HTTP")
      other_user.folders.create!(name: "他人のフォルダ")

      get "/api/folders"

      expect(response).to have_http_status(:ok)
      names = json_body[:folders].map { |f| f[:name] }
      expect(names).to eq([ mine.name ])
    end

    it "フォルダごとの単語数を返す" do
      folder = user.folders.create!(name: "Web・HTTP")
      create(:term, user: user, word: "冪等性", folder: folder)
      create(:term, user: user, word: "CORS", folder: folder)

      get "/api/folders"

      expect(json_body[:folders].first[:terms_count]).to eq(2)
    end

    it "単語が0件のフォルダも一覧に出る" do
      # 【left join を使っている理由の検証】
      #   inner join だと空のフォルダが結果から消え、
      #   「作ったのに一覧に出ない」という不具合になる。
      user.folders.create!(name: "空のフォルダ")

      get "/api/folders"

      expect(json_body[:folders].length).to eq(1)
      expect(json_body[:folders].first[:terms_count]).to eq(0)
    end

    it "未分類の件数と、未承認の提案がある単語の数を返す" do
      create(:term, user: user, word: "冪等性")
      create(:term, user: user, word: "CORS", suggested_folder_name: "Web・HTTP")

      get "/api/folders"

      expect(json_body[:unfiled_count]).to eq(2)
      expect(json_body[:pending_suggestion_count]).to eq(1)
    end
  end

  # ==========================================================================
  # 作成
  # ==========================================================================
  describe "POST /api/folders" do
    it "フォルダを作成できる" do
      post "/api/folders", params: { folder: { name: "Web・HTTP" } }, as: :json

      expect(response).to have_http_status(:created)
      expect(user.folders.pluck(:name)).to eq([ "Web・HTTP" ])
    end

    it "同じ名前は作れない" do
      user.folders.create!(name: "Web・HTTP")

      post "/api/folders", params: { folder: { name: "Web・HTTP" } }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.folders.count).to eq(1)
    end

    it "user_id を送りつけても、持ち主は自分になる" do
      # 【なりすまし防止の検証】
      #   Strong Parameters が user_id を弾き、
      #   current_user.folders.build が持ち主を決めている。
      post "/api/folders",
           params: { folder: { name: "Web・HTTP", user_id: other_user.id } },
           as: :json

      expect(response).to have_http_status(:created)
      expect(user.folders.count).to eq(1)
      expect(other_user.folders.count).to eq(0)
    end
  end

  # ==========================================================================
  # 更新・削除（権限境界）
  # ==========================================================================
  describe "PATCH /api/folders/:id" do
    it "名前を変えても、所属している単語は外れない" do
      folder = user.folders.create!(name: "Web")
      term = create(:term, user: user, folder: folder)

      patch "/api/folders/#{folder.id}",
            params: { folder: { name: "Web・HTTP" } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(term.reload.folder).to eq(folder)
      expect(folder.reload.name).to eq("Web・HTTP")
    end

    it "他人のフォルダは 403 ではなく 404 になる" do
      # 【403 を返してはいけない理由】
      #   403 は「実在するが権限が無い」と教えることになり、
      #   IDを順に試せば他人のデータの有無を調べられる。
      #   404 なら、存在しないのか他人のものなのか区別できない。
      folder = other_user.folders.create!(name: "他人のフォルダ")

      patch "/api/folders/#{folder.id}",
            params: { folder: { name: "乗っ取り" } }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(folder.reload.name).to eq("他人のフォルダ")
    end
  end

  describe "DELETE /api/folders/:id" do
    it "フォルダを消しても中の単語は消えず、未分類に戻る" do
      # 【この挙動が最重要】
      #   1件3.4円かけて生成した解説を、
      #   フォルダ整理の巻き添えで失わせてはいけない。
      folder = user.folders.create!(name: "Web・HTTP")
      term = create(:term, user: user, folder: folder)

      delete "/api/folders/#{folder.id}"

      expect(response).to have_http_status(:no_content)
      expect(Term.exists?(term.id)).to be(true)
      expect(term.reload.folder_id).to be_nil
    end

    it "他人のフォルダは削除できず 404 になる" do
      folder = other_user.folders.create!(name: "他人のフォルダ")

      delete "/api/folders/#{folder.id}"

      expect(response).to have_http_status(:not_found)
      expect(Folder.exists?(folder.id)).to be(true)
    end
  end

  # ==========================================================================
  # 未ログイン
  # ==========================================================================
  describe "未ログインのとき" do
    it "401 が返る" do
      # 【DELETE /api/session でログアウトする理由】
      #   セッションを直接いじる近道もあるが、
      #   本番と同じ経路を通した方が、ログアウト処理自体の
      #   不具合も一緒に検知できる（AuthHelper のコメント参照）。
      delete "/api/session"

      get "/api/folders"

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
