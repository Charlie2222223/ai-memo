# ============================================================================
# FoldersController — フォルダのCRUD API
#
# 【タグに index しか無いのに、フォルダには全部ある理由】
#   タグはAIが自動で付けるもので、利用者が直接作ったり消したりしない。
#   フォルダは利用者が所有し、名前を変え、要らなくなれば消す。
#   誰が管理する概念かの違いが、そのままAPIの広さの違いになっている。
# ============================================================================
class FoldersController < ApplicationController
  # ApplicationController で before_action :require_authentication を
  # 掛けてあるので、ここでは何も書かなくても全アクションが保護される。

  before_action :set_folder, only: [ :update, :destroy ]

  # ==========================================================================
  # GET /api/folders — 一覧
  # ==========================================================================
  def index
    # ------------------------------------------------------------------------
    # 【left_joins + group + count で件数を取る理由】← N+1対策
    #   素直に書くと
    #     folders.map { |f| { name: f.name, count: f.terms.count } }
    #   となるが、これはフォルダの数だけ COUNT のSQLが飛ぶ。
    #
    #   left_joins(:terms).group(:id).count は1回のSQLで
    #   全フォルダの件数を取ってくる。
    #
    # 【inner join ではなく left join を使う理由】
    #   inner join だと、単語が0件のフォルダが結果から消える。
    #   作ったばかりの空のフォルダが一覧に出てこないと、
    #   「作ったのに反映されない」という不具合に見える。
    #
    # 【count("terms.id") と列を指定する理由】← ここでテストに助けられた
    #   引数なしの count は「結合後の行数」を数える。
    #   LEFT JOIN は一致する単語が無くても、
    #   terms 側が全部 NULL の行を1行作るため、
    #   空のフォルダなのに件数が 1 になる。
    #
    #   列を指定すると、その列が NULL の行は数えられないので
    #   正しく 0 になる。LEFT JOIN で件数を取るときの定石。
    # ------------------------------------------------------------------------
    counts = current_user.folders.left_joins(:terms).group(:id).count("terms.id")

    folders = current_user.folders.alphabetical.map do |folder|
      {
        id: folder.id,
        name: folder.name,
        terms_count: counts[folder.id] || 0
      }
    end

    render json: {
      folders: folders,
      # ----------------------------------------------------------------------
      # 【未分類の件数を一緒に返す理由】
      #   未分類はフォルダではないので folders には入らない。
      #   しかし画面では「未分類 (3)」という同じ形の行として出したい。
      #
      #   画面側で件数を数えようとすると、全単語を取得する必要があり、
      #   絞り込み中は正しい数にならない。サーバーが数えて返す。
      # ----------------------------------------------------------------------
      unfiled_count: current_user.terms.where(folder_id: nil).count,

      # AIの提案が付いていて、まだ承認も却下もしていない単語の数。
      # 画面はこれが0より大きいときだけ「提案があります」を出す。
      pending_suggestion_count: current_user.terms
                                            .where.not(suggested_folder_name: nil)
                                            .count
    }
  end

  # ==========================================================================
  # POST /api/folders — 新規作成
  # ==========================================================================
  def create
    # 【current_user.folders.build から始める】
    #   user_id をサーバー側が決めるので、
    #   他人の名義でフォルダを作られる余地が無い。
    folder = current_user.folders.build(folder_params)

    if folder.save
      render json: { folder: folder_json(folder) }, status: :created
    else
      render json: { errors: folder.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  # ==========================================================================
  # PATCH /api/folders/:id — 名前の変更
  # ==========================================================================
  # 【リネームで所属単語を触らなくてよい理由】
  #   単語は folder_id で参照しているので、
  #   名前を変えても紐付きは切れない。
  #   文字列で持っていたら、ここで全単語の更新が必要だった。
  #   テーブルに分けた利点がそのまま出ている箇所。
  def update
    if @folder.update(folder_params)
      render json: { folder: folder_json(@folder) }
    else
      render json: { errors: @folder.errors.full_messages },
             status: :unprocessable_entity
    end
  end

  # ==========================================================================
  # DELETE /api/folders/:id — 削除
  # ==========================================================================
  # 【中の単語は消えない】
  #   Folder モデルの has_many :terms, dependent: :nullify と、
  #   DB側の on_delete: :nullify により、所属していた単語は
  #   未分類に戻るだけで残る。
  #
  #   利用者の意図は「この分類をやめたい」であって
  #   「この単語たちを捨てたい」ではない。
  #   1件3.4円かけて生成した解説を、整理の巻き添えで失わせない。
  def destroy
    @folder.destroy!
    head :no_content
  end

  private

  def set_folder
    # 【ここが権限チェックそのもの】
    #   current_user.folders.find(id) が発行するSQLは
    #     WHERE user_id = 1 AND id = 999
    #   他人のフォルダのIDを指定しても WHERE で除外され、見つからない。
    #
    # 【なぜ403ではなく404なのか】
    #   403 を返すと「そのIDは実在するが他人のもの」と教えることになり、
    #   IDを順に試して他人のデータの有無を調べられてしまう。
    #   404 で統一すれば、存在しないのか他人のものなのか区別できない。
    @folder = current_user.folders.find(params[:id])
  end

  def folder_params
    # 【user_id を許可しない】
    #   許可すると他人の名義でフォルダを作れてしまう。
    #   持ち主はサーバーが current_user から決める。
    params.expect(folder: [ :name ])
  end

  def folder_json(folder)
    {
      id: folder.id,
      name: folder.name,
      # 作成・更新直後は、その場で数え直す。
      # 一覧と違い1件だけなので、N+1にはならない。
      terms_count: folder.terms.count
    }
  end
end
