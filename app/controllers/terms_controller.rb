# ============================================================================
# TermsController — 単語のCRUD API
#
# Vue（SPA）がここを叩いてデータをやり取りする。
# 返すのは常にJSONで、HTMLは返さない。
# ============================================================================
class TermsController < ApplicationController
  # ApplicationController で before_action :require_authentication を
  # 掛けてあるので、ここでは何も書かなくても全アクションが保護される。
  # （skip_before_action を書いていない＝保護されている、が読み取れる）

  # 個別の単語を扱うアクションの前に、対象を取得しておく。
  # 【before_action にまとめる理由】
  #   show/update/destroy/regenerate の4箇所に同じ取得処理を書くと、
  #   1箇所だけ権限チェックの書き方が違う、という事故が起きる。
  #   1箇所にまとめれば、そこだけ正しければ全部正しい。
  before_action :set_term,
                only: [ :show, :update, :destroy, :regenerate, :accept_folder, :reject_folder ]

  # ==========================================================================
  # GET /api/terms — 一覧
  # ==========================================================================
  def index
    # ------------------------------------------------------------------------
    # 【current_user.terms から始めるのが最重要】
    # ------------------------------------------------------------------------
    #   ここで Term.all と書くと、全ユーザーの単語が返る。
    #   current_user.terms と書けば、SQLに自動的に
    #     WHERE user_id = 現在のユーザーID
    #   が付くので、他人のデータが混ざる余地が構造的に無くなる。
    #
    #   権限チェックを「if文で書く」のではなく
    #   「そもそも取得できない形にする」のが安全な設計。
    #   if文は書き忘れるが、関連付けからの取得は書き忘れようがない。
    # ------------------------------------------------------------------------
    # 以下のチェーンで行っていること
    # ------------------------------------------------------------------------
    # includes(:tags) … N+1問題の対策
    #
    #   【N+1問題とは】← 実務で最頻出の性能問題
    #     一覧で単語を50件取り、それぞれのタグを表示するとき、
    #     includes が無いと次のSQLが発行される:
    #
    #       SELECT * FROM terms WHERE user_id = 1       … 1回
    #       SELECT * FROM tags  WHERE term_id = 1       … 1回目
    #       SELECT * FROM tags  WHERE term_id = 2       … 2回目
    #       ...
    #       SELECT * FROM tags  WHERE term_id = 50      … 50回目
    #
    #     合計 1 + 50 = 51回。これが「1 + N回」で N+1問題。
    #
    #     includes(:tags) を書くと、Railsは
    #       SELECT * FROM terms WHERE user_id = 1
    #       SELECT * FROM tags  WHERE term_id IN (1,2,...,50)
    #     の2回にまとめてくれる。
    #
    #     【なぜ深刻か】開発中はデータが5件しかないので気付かない。
    #     本番でデータが増えてから急に遅くなる。
    #     「開発では速いのに本番で遅い」の代表的な原因。
    #
    # search / with_tag / recent … モデルに定義したスコープ
    #
    #   【なぜ繋げられるのか】各スコープはSQLを即実行せず、
    #   条件を持った「未完成の問い合わせ」を返すため。
    #   実際にSQLが走るのは、値が必要になった瞬間（下の map）だけ。
    #   これを遅延評価と呼ぶ。
    #
    # 【メソッドチェーンとコメントの注意】
    #   行頭の . で繋ぐ書き方は、途中にコメント行を挟むと
    #   Rubyが構文エラーにすることがある（実際にここで踏んだ）。
    #   説明はチェーンの外に書き、チェーン自体は連続させる。
    # ------------------------------------------------------------------------
    # includes に :folder を足しているのもN+1対策。
    # フォルダ名を一覧に出すので、これが無いと単語の件数だけ
    # SELECT * FROM folders が発行される。
    terms = current_user.terms
                        .includes(:tags, :folder)
                        .search(params[:q])
                        .with_tag(params[:tag])
                        .in_folder(params[:folder_id])
                        .recent

    render json: { terms: terms.map { |t| TermSerializer.call(t) } }
  end

  # ==========================================================================
  # GET /api/terms/:id — 詳細
  # ==========================================================================
  def show
    render json: { term: TermSerializer.call(@term) }
  end

  # ==========================================================================
  # POST /api/terms — 新規登録
  # ==========================================================================
  def create
    # current_user.terms.build とすることで user_id が自動で入る。
    # 【なぜ Term.new(user_id: params[:user_id]) と書かないか】
    #   params から user_id を受け取ると、他人のIDを送りつけられて
    #   他人の名義で単語を作られてしまう。
    #   関連付け経由なら user_id はサーバー側が決めるので、
    #   なりすましが原理的に不可能になる。
    term = current_user.terms.build(term_params)

    if term.save
      # ----------------------------------------------------------------------
      # 【保存とAI生成の順序が重要】← Q10で例に挙げた箇所
      #
      #   AI生成は10秒かかり、失敗もする。
      #   先に保存しておけば、生成に失敗しても単語自体は残り、
      #   あとから再生成できる。
      #
      #   逆順（AI生成 → 保存）にすると:
      #     ・ユーザーは10秒待たされる
      #     ・生成に失敗したら単語ごと消える（入力し直し）
      #     ・タブを閉じたら何も残らない
      #
      #   「まず記録し、重い処理は後回し」が非同期設計の基本形。
      # ----------------------------------------------------------------------
      ExplainTermJob.perform_later(term.id)

      # 201 Created は「新しく作られた」ことを表すステータス。
      # 200 でも動くが、201 の方が意図が正確に伝わる。
      render json: { term: TermSerializer.call(term) }, status: :created
    else
      # 422 Unprocessable Entity は
      # 「リクエストの形式は正しいが、内容が検証に通らない」の意味。
      # 400 Bad Request は「形式そのものが壊れている」ときに使う。
      render json: { errors: term.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  # ==========================================================================
  # PATCH /api/terms/:id — 更新
  # ==========================================================================
  def update
    if @term.update(term_params)
      render json: { term: TermSerializer.call(@term) }
    else
      render json: { errors: @term.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  # ==========================================================================
  # DELETE /api/terms/:id — 削除
  # ==========================================================================
  def destroy
    @term.destroy!
    head :no_content
  end

  # ==========================================================================
  # POST /api/terms/:id/regenerate — AI解説をもう一度生成する
  # ==========================================================================
  def regenerate
    # 【この確認が必要な理由】
    #   すでに生成中（pending）のものに再生成を掛けると、
    #   同じ単語に対してジョブが2つ走る。
    #   AIを2回呼ぶので課金が2倍になり、
    #   どちらの結果が最後に残るかも不定になる。
    unless @term.regeneratable?
      return render json: { error: "生成中のため再実行できません" },
                    status: :conflict   # 409 = 現在の状態と矛盾する要求
    end

    # 状態を pending に戻してからジョブを積む。
    # 【順序が重要】先にジョブを積むと、ワーカーが即座に処理を始めて
    #   status を completed にした直後に、こちらが pending で上書きし、
    #   永久に「生成中」のまま止まる可能性がある（競合状態）。
    #   状態を先に確定させてから積む。
    @term.update!(status: :pending, error_message: nil)
    ExplainTermJob.perform_later(@term.id)

    render json: { term: TermSerializer.call(@term) }, status: :accepted  # 202 = 受け付けた
  end

  # ==========================================================================
  # POST /api/terms/:id/accept_folder — AIが提案したフォルダを承認する
  # ==========================================================================
  # 【なぜ update ではなく専用のURLにするのか】
  #   やっていることは「フォルダを作って、単語をそこへ入れて、提案を消す」
  #   という3段階の操作で、単なる属性の更新ではない。
  #
  #   update に folder_id を送る形にすると、画面側が
  #   「先にフォルダを作ってIDを得てから、それを送る」という
  #   2往復の手順を踏む必要がある。
  #   途中で失敗すると空のフォルダだけが残る。
  #
  #   1つの意味のある操作は、1つのURLにまとめる。
  def accept_folder
    if @term.suggested_folder_name.blank?
      return render json: { error: "承認できる提案がありません" },
                    status: :unprocessable_entity
    end

    @term.accept_suggested_folder!
    render json: { term: TermSerializer.call(@term) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: [ e.record.errors.full_messages.to_sentence ] },
           status: :unprocessable_entity
  end

  # ==========================================================================
  # DELETE /api/terms/:id/suggested_folder — 提案を破棄する
  # ==========================================================================
  # 【却下という操作が必要な理由】
  #   提案が気に入らない場合、承認しない限り「未分類」に残り続ける。
  #   却下できないと、承認したくない提案がいつまでも
  #   未分類の件数に乗り続け、本当に手つかずの単語が埋もれる。
  #
  #   却下しても単語自体は未分類に残るので、
  #   あとから手動で好きなフォルダへ移せる。
  def reject_folder
    @term.update!(suggested_folder_name: nil)
    render json: { term: TermSerializer.call(@term) }
  end

  private

  # ==========================================================================
  # 対象の単語を取得する
  # ==========================================================================
  def set_term
    # 【ここが権限チェックそのもの】
    #   current_user.terms.find(id) が発行するSQLは
    #     WHERE user_id = 1 AND id = 999
    #   他人の単語のIDを指定しても WHERE で除外され、見つからない。
    #
    #   見つからない場合 RecordNotFound が発生し、
    #   ApplicationController の rescue_from が 404 を返す。
    #
    # 【なぜ403ではなく404なのか】
    #   403（権限が無い）を返すと、
    #   「そのIDは存在する。ただし自分のものではない」と教えることになる。
    #   IDを順に試せば、他人のデータの有無を調べられてしまう。
    #   404で統一すれば、存在しないのか他人のものなのか区別できない。
    @term = current_user.terms.find(params[:id])
  end

  # ==========================================================================
  # 受け取ってよいパラメータの指定（Strong Parameters）
  # ==========================================================================
  # 【なぜ必要か — Mass Assignment 脆弱性】
  #   params をそのまま update に渡すと、
  #   送られてきたキー全部がカラムに書き込まれる。
  #
  #   攻撃者が
  #     { "word": "test", "user_id": 999 }
  #   を送ると user_id が書き換わり、他人に単語を押し付けられる。
  #
  #   さらに status を直接 completed にされると、
  #   AIを呼んでいないのに完了扱いにできてしまう。
  #
  #   permit で「受け取ってよいキー」を列挙しておけば、
  #   それ以外は無視される。
  #
  # 【許可リスト方式】
  #   「危ないものを禁止する」のではなく
  #   「安全なものだけ許可する」形にする。
  #   カラムを後から追加しても、ここに書かない限り
  #   自動的に受け付けられることはない。
  # 【folder_id を許可してよい理由】
  #   status や user_id と違い、folder_id は利用者が変更してよい値。
  #   単語を別のフォルダへ移すのは正当な操作なので、許可する必要がある。
  #
  # 【では他人のフォルダのIDを送られたらどうなるか】
  #   Term モデルの folder_must_belong_to_same_user が弾く。
  #   ここで許可することと、値が妥当かの検証は別の仕事。
  #
  #   コントローラで毎回チェックする方法もあるが、
  #   更新経路が増えるたびに書き忘れる。
  #   モデルに置けば、どの経路から保存しても必ず通る。
  def term_params
    params.expect(term: [ :word, :context, :folder_id ])
  end
end
