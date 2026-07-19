# ============================================================================
# 単語APIのテスト
#
# 最も重要なのは「他人の単語が見えないこと」の検証。
# 認可（権限）の不具合は、動作確認では絶対に気付けない。
# 自分のアカウントで触っている限り、常に正しく動いて見えるからだ。
# ============================================================================
require "rails_helper"

RSpec.describe "Terms", type: :request do
  let!(:owner)     { create(:user, email: "owner@example.com") }
  let!(:other)     { create(:user, email: "other@example.com") }
  let!(:own_term)  { create(:term, user: owner, word: "冪等性") }
  let!(:other_term) { create(:term, user: other, word: "他人の単語") }

  # ==========================================================================
  describe "認可（他人のデータへのアクセス）" do
    before { sign_in_as(owner) }

    it "一覧には自分の単語だけが含まれる" do
      get "/api/terms"

      words = json_body[:terms].map { |t| t[:word] }
      expect(words).to include("冪等性")
      expect(words).not_to include("他人の単語")
    end

    it "他人の単語を取得しようとすると404" do
      # ----------------------------------------------------------------------
      # 【なぜ403ではなく404を期待するのか】← 設計の意図をテストで固定する
      #   403（権限が無い）を返すと、
      #   「そのIDは実在する。ただしあなたのものではない」と教えることになる。
      #   IDを1から順に試せば、他人のデータが何件あるか調べられてしまう。
      #
      #   404で統一すれば、存在しないのか他人のものなのか区別できない。
      #   将来「親切にしよう」として403に変える改変を、
      #   このテストが止めてくれる。
      # ----------------------------------------------------------------------
      get "/api/terms/#{other_term.id}"
      expect(response).to have_http_status(:not_found)
    end

    it "他人の単語を更新しようとすると404" do
      patch "/api/terms/#{other_term.id}", params: { term: { word: "書き換え" } }

      expect(response).to have_http_status(:not_found)
      # 実際に書き換わっていないことも確認する。
      # 【なぜステータスだけでは不十分か】
      #   404を返しつつ更新はしてしまう、という実装ミスがありうる。
      #   「結果がどうなったか」まで見て初めて検証になる。
      expect(other_term.reload.word).to eq("他人の単語")
    end

    it "他人の単語を削除しようとすると404で、実際に消えない" do
      delete "/api/terms/#{other_term.id}"

      expect(response).to have_http_status(:not_found)
      expect(Term.exists?(other_term.id)).to be(true)
    end

    it "他人の単語を再生成しようとすると404" do
      post "/api/terms/#{other_term.id}/regenerate"
      expect(response).to have_http_status(:not_found)
    end
  end

  # ==========================================================================
  describe "POST /api/terms（登録）" do
    before { sign_in_as(owner) }

    it "201を返し、status は pending になる" do
      post "/api/terms", params: { term: { word: "ミドルウェア", context: "Railsの記事で見た" } }

      expect(response).to have_http_status(:created)
      # 【登録直後は必ず pending】
      #   AI生成は非同期なので、この時点で解説は入っていない。
      #   ここが completed になっていたら、
      #   同期的に生成してしまっている（＝設計が崩れている）ことになる。
      expect(json_body[:term][:status]).to eq("pending")
      expect(json_body[:term][:meaning]).to be_nil
    end

    it "AI生成ジョブが登録される" do
      # ----------------------------------------------------------------------
      # 【have_enqueued_job とは】
      #   「ジョブが待ち行列に積まれたか」だけを検証する。
      #   ジョブの中身は実行しない。
      #
      # 【なぜ実行まで見ないのか】
      #   ここで確かめたいのは「コントローラがジョブを積んだか」だけ。
      #   ジョブの中身の正しさは、ジョブ自身のテストで確かめる。
      #
      #   1つのテストで多くを見ようとすると、
      #   落ちたときにどこが悪いのか分からなくなる。
      #   検証範囲は狭く保つ。
      # ----------------------------------------------------------------------
      expect {
        post "/api/terms", params: { term: { word: "ロードバランサ" } }
      }.to have_enqueued_job(ExplainTermJob)
    end

    it "空の単語は422で拒否される" do
      post "/api/terms", params: { term: { word: "" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body[:errors]).to be_present
    end

    it "同じ単語の二重登録は422で拒否される" do
      # 【なぜこれを防ぐか】
      #   同じ単語をもう一度登録すると、AIをもう一度呼ぶことになる。
      #   気付かないまま何度も登録すると、その分だけ課金される。
      post "/api/terms", params: { term: { word: "冪等性" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "他人が同じ単語を登録するのは許される" do
      # 【一意性の範囲がユーザー単位であることの確認】
      #   もし word 単独でユニークにしていたら、
      #   誰かが「冪等性」を登録した時点で他の全員が登録できなくなる。
      sign_in_as(other)
      post "/api/terms", params: { term: { word: "冪等性" } }
      expect(response).to have_http_status(:created)
    end

    it "user_id を送りつけても他人の名義にはできない" do
      # ----------------------------------------------------------------------
      # 【Mass Assignment 脆弱性のテスト】
      #   Strong Parameters で :word と :context しか許可していないので、
      #   user_id を送っても無視される。
      #
      #   もし permit に user_id を足してしまうと、
      #   他人の名義で単語を作れるようになる。
      #   このテストがその改変を検知する。
      # ----------------------------------------------------------------------
      post "/api/terms", params: {
        term: { word: "なりすまし確認", user_id: other.id }
      }

      expect(response).to have_http_status(:created)
      expect(Term.find(json_body[:term][:id]).user_id).to eq(owner.id)
    end

    it "status を直接指定しても completed にはできない" do
      # 【なぜ重要か】status を外から書き換えられると、
      #   AIを呼ばずに「生成済み」にできてしまう。
      #   状態はサーバー側だけが変えられる必要がある。
      post "/api/terms", params: {
        term: { word: "状態改ざん確認", status: "completed" }
      }

      expect(json_body[:term][:status]).to eq("pending")
    end
  end

  # ==========================================================================
  describe "GET /api/terms（検索・絞り込み）" do
    before do
      sign_in_as(owner)
      create(:term, :completed, user: owner, word: "ロードバランサ",
                                meaning: "負荷を分散させる仕組み")
    end

    it "キーワードで単語名を検索できる" do
      get "/api/terms", params: { q: "ロード" }

      words = json_body[:terms].map { |t| t[:word] }
      expect(words).to eq([ "ロードバランサ" ])
    end

    it "キーワードで意味の本文も検索できる" do
      # 【なぜ本文も検索対象にするか】
      #   「負荷分散の話、なんて単語だったっけ」という探し方をするため。
      #   単語名を思い出せないから調べたい、が実際の使い方。
      get "/api/terms", params: { q: "負荷を分散" }
      expect(json_body[:terms].size).to eq(1)
    end

    it "検索文字列に % が含まれても全件返らない" do
      # ----------------------------------------------------------------------
      # 【sanitize_sql_like の効果を確認する】
      #   % はSQLのLIKEでは「任意の文字列」を意味するワイルドカード。
      #   エスケープしないと、"%" で検索したときに全件が返ってしまう。
      #
      #   ユーザーから見ると「100%」で検索したのに
      #   全単語が出てくる、という挙動になる。
      # ----------------------------------------------------------------------
      get "/api/terms", params: { q: "%" }
      expect(json_body[:terms]).to be_empty
    end

    it "タグで絞り込める" do
      tag = create(:tag, user: owner, name: "インフラ")
      target = create(:term, user: owner, word: "コンテナ")
      TermTag.create!(term: target, tag: tag)

      get "/api/terms", params: { tag: "インフラ" }

      words = json_body[:terms].map { |t| t[:word] }
      expect(words).to eq([ "コンテナ" ])
    end

    it "複数タグが付いた単語も重複せず1件で返る" do
      # ----------------------------------------------------------------------
      # 【多対多のJOINで必ず踏む落とし穴】
      #   JOINすると、タグを2つ持つ単語は2行として返る。
      #   distinct を書き忘れると、画面に同じカードが2枚出る。
      #
      #   モデルの with_tag スコープに書いた distinct が
      #   効いていることを、ここで担保する。
      # ----------------------------------------------------------------------
      tag_a = create(:tag, user: owner, name: "API設計")
      tag_b = create(:tag, user: owner, name: "HTTP")
      target = create(:term, user: owner, word: "冪等な操作")
      TermTag.create!(term: target, tag: tag_a)
      TermTag.create!(term: target, tag: tag_b)

      get "/api/terms", params: { tag: "API設計" }

      ids = json_body[:terms].map { |t| t[:id] }
      expect(ids).to eq([ target.id ])   # 2件になっていないこと
    end
  end

  # ==========================================================================
  describe "POST /api/terms/:id/regenerate（再生成）" do
    before { sign_in_as(owner) }

    it "失敗した単語は再生成できる" do
      failed = create(:term, :failed, user: owner)

      expect {
        post "/api/terms/#{failed.id}/regenerate"
      }.to have_enqueued_job(ExplainTermJob)

      expect(response).to have_http_status(:accepted)
      # 状態が pending に戻り、前回のエラーが消えていること。
      expect(failed.reload).to be_pending
      expect(failed.error_message).to be_nil
    end

    it "生成中の単語は再生成できない（409）" do
      # ----------------------------------------------------------------------
      # 【なぜ止める必要があるか】
      #   pending（生成中）に再生成を掛けると、
      #   同じ単語に対してジョブが2つ走る。
      #   AIを2回呼ぶので課金が2倍になり、
      #   どちらの結果が最後に残るかも不定になる。
      # ----------------------------------------------------------------------
      pending_term = create(:term, user: owner, status: :pending)

      expect {
        post "/api/terms/#{pending_term.id}/regenerate"
      }.not_to have_enqueued_job(ExplainTermJob)

      expect(response).to have_http_status(:conflict)
    end
  end

  # ==========================================================================
  describe "GET /api/tags（タグ一覧）" do
    before { sign_in_as(owner) }

    it "自分のタグだけが、単語件数付きで返る" do
      my_tag = create(:tag, user: owner, name: "Rails")
      create(:tag, user: other, name: "他人のタグ")
      TermTag.create!(term: own_term, tag: my_tag)

      get "/api/tags"

      names = json_body[:tags].map { |t| t[:name] }
      expect(names).to include("Rails")
      expect(names).not_to include("他人のタグ")

      rails_tag = json_body[:tags].find { |t| t[:name] == "Rails" }
      expect(rails_tag[:terms_count]).to eq(1)
    end

    it "単語が0件のタグも件数0で表示される" do
      # ----------------------------------------------------------------------
      # 【left_joins を使った理由の確認】
      #   内部結合（joins）にすると、結び付きの無いタグは消える。
      #   使われていないタグが一覧から見えないと、
      #   「不要なタグを消す」という操作ができなくなる。
      # ----------------------------------------------------------------------
      create(:tag, user: owner, name: "未使用タグ")

      get "/api/tags"

      unused = json_body[:tags].find { |t| t[:name] == "未使用タグ" }
      expect(unused).to be_present
      expect(unused[:terms_count]).to eq(0)
    end
  end

  # ==========================================================================
  # フォルダ（所属の変更・AI提案の承認/却下）
  # ==========================================================================
  describe "フォルダ" do
    before { sign_in_as(owner) }

    describe "PATCH /api/terms/:id（フォルダの移動）" do
      it "自分のフォルダへ移動できる" do
        folder = owner.folders.create!(name: "Web・HTTP")
        term = create(:term, user: owner)

        patch "/api/terms/#{term.id}",
              params: { term: { folder_id: folder.id } }, as: :json

        expect(response).to have_http_status(:ok)
        expect(term.reload.folder).to eq(folder)
      end

      it "他人のフォルダへは移動できない" do
        # ------------------------------------------------------------------
        # 【ここが権限の穴になりうる箇所】
        #   folder_id は「単語を別のフォルダへ移す」ために
        #   Strong Parameters で許可せざるを得ない。
        #
        #   許可した以上、他人のフォルダのIDを送りつけられる。
        #   通ってしまうと、自分の単語が他人のフォルダに所属し、
        #   そのフォルダを開いた他人の画面に現れてしまう。
        #
        #   Term モデルの folder_must_belong_to_same_user が防いでいる。
        # ------------------------------------------------------------------
        others_folder = other.folders.create!(name: "他人のフォルダ")
        term = create(:term, user: owner)

        patch "/api/terms/#{term.id}",
              params: { term: { folder_id: others_folder.id } }, as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(term.reload.folder_id).to be_nil
      end
    end

    describe "POST /api/terms/:id/accept_folder（提案の承認）" do
      it "提案されたフォルダが作られ、単語がそこに入る" do
        term = create(:term, user: owner, suggested_folder_name: "Web・HTTP")

        post "/api/terms/#{term.id}/accept_folder"

        expect(response).to have_http_status(:ok)
        term.reload
        expect(term.folder.name).to eq("Web・HTTP")
        # 承認したら提案は残さない。残ると承認UIが出続ける。
        expect(term.suggested_folder_name).to be_nil
      end

      it "提案が無いときは 422 になる" do
        term = create(:term, user: owner)

        post "/api/terms/#{term.id}/accept_folder"

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "他人の単語は承認できず 404 になる" do
        term = create(:term, user: other, suggested_folder_name: "Web・HTTP")

        post "/api/terms/#{term.id}/accept_folder"

        expect(response).to have_http_status(:not_found)
        expect(other.folders.count).to eq(0)
      end
    end

    describe "DELETE /api/terms/:id/suggested_folder（提案の却下）" do
      it "提案が消え、フォルダは作られない" do
        term = create(:term, user: owner, suggested_folder_name: "Web・HTTP")

        delete "/api/terms/#{term.id}/suggested_folder"

        expect(response).to have_http_status(:ok)
        expect(term.reload.suggested_folder_name).to be_nil
        expect(owner.folders.count).to eq(0)
      end
    end

    describe "GET /api/terms?folder_id=" do
      # 【own_term（"冪等性"）が最初から未分類で存在する】
      #   ファイル冒頭の let! で作られている。
      #   フォルダに入れた単語と対比する材料としてそのまま使う。

      it "指定したフォルダの単語だけが返る" do
        folder = owner.folders.create!(name: "Web・HTTP")
        create(:term, user: owner, word: "CORS", folder: folder)

        get "/api/terms", params: { folder_id: folder.id }

        expect(json_body[:terms].map { |t| t[:word] }).to eq([ "CORS" ])
      end

      it "unfiled を指定すると未分類だけが返る" do
        folder = owner.folders.create!(name: "Web・HTTP")
        create(:term, user: owner, word: "CORS", folder: folder)

        get "/api/terms", params: { folder_id: "unfiled" }

        words = json_body[:terms].map { |t| t[:word] }
        expect(words).to include("冪等性")
        expect(words).not_to include("CORS")
      end
    end
  end

  # ==========================================================================
  # 出自（解説の中の語を選んで登録したときの親子関係）
  # ==========================================================================
  describe "出自（source_term）" do
    before { sign_in_as(owner) }

    it "出自を指定して登録できる" do
      post "/api/terms",
           params: { term: { word: "プリフライト", source_term_id: own_term.id } },
           as: :json

      expect(response).to have_http_status(:created)
      expect(owner.terms.find_by(word: "プリフライト").source_term).to eq(own_term)
    end

    it "詳細に「ここから調べた語」が含まれる" do
      child = create(:term, user: owner, word: "プリフライト", source_term: own_term)

      get "/api/terms/#{own_term.id}"

      derived = json_body[:term][:derived_terms]
      expect(derived.map { |t| t[:word] }).to eq([ child.word ])
    end

    it "子の詳細に出自の単語名が含まれる" do
      child = create(:term, user: owner, word: "プリフライト", source_term: own_term)

      get "/api/terms/#{child.id}"

      expect(json_body[:term][:source_term_id]).to eq(own_term.id)
      expect(json_body[:term][:source_term_word]).to eq(own_term.word)
    end

    it "他人の単語を出自にはできない" do
      # ------------------------------------------------------------------
      # 【folder_id と同じ形の穴】
      #   通ってしまうと、他人の単語の詳細に
      #   「ここから調べた語」として自分の単語が並ぶ。
      #   相手の画面に自分のデータが現れることになる。
      # ------------------------------------------------------------------
      post "/api/terms",
           params: { term: { word: "プリフライト", source_term_id: other_term.id } },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(owner.terms.find_by(word: "プリフライト")).to be_nil
    end

    it "自分自身を出自にはできない" do
      term = create(:term, user: owner, word: "自己参照テスト")

      patch "/api/terms/#{term.id}",
            params: { term: { source_term_id: term.id } }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(term.reload.source_term_id).to be_nil
    end

    it "親を削除しても子は残り、出自だけが外れる" do
      # ------------------------------------------------------------------
      # 【この挙動が最重要】
      #   1件3.4円かけて生成した解説を、
      #   親を消しただけで失わせてはいけない。
      # ------------------------------------------------------------------
      child = create(:term, user: owner, word: "プリフライト", source_term: own_term)

      delete "/api/terms/#{own_term.id}"

      expect(response).to have_http_status(:no_content)
      expect(Term.exists?(child.id)).to be(true)
      expect(child.reload.source_term_id).to be_nil
    end
  end
end
