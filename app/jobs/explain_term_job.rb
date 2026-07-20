# ============================================================================
# ExplainTermJob — AI解説を生成する非同期ジョブ
#
# このアプリで最も重要なファイル。Q3で決めた設計がここに集約される。
#
# ----------------------------------------------------------------------------
# 【全体の流れ】
# ----------------------------------------------------------------------------
#   [ブラウザ] POST /api/terms                      … 単語を送信
#        ↓
#   [Rails]   term を保存(status: pending) → 即座に201を返す（0.05秒）
#        ↓    perform_later でジョブをRedisに積む
#        │
#        │    ※ ここでHTTPリクエストは終わっている。
#        │       ブラウザは待たされない。
#        ↓
#   [Redis]   ジョブの待ち行列に入る
#        ↓
#   [Sidekiq] 別プロセスが取り出して実行 ← このファイルの中身
#        ↓    Claude API を呼ぶ（10秒）
#        ↓    term を更新(status: completed)
#        ↓    api_call_logs に記録
#        ↓    Action Cable で「できたよ」と放送
#        ↓
#   [Redis]   pub/sub で中継
#        ↓
#   [Rails]   WebSocketで繋がっているブラウザへ転送
#        ↓
#   [ブラウザ] カードが自動で解説入りに変わる（リロード不要）
#
# ----------------------------------------------------------------------------
# 【なぜプロセスを分けるのか】
# ----------------------------------------------------------------------------
#   Railsのプロセスは同時に処理できるリクエスト数に限りがある（既定5本程度）。
#   もしAI呼び出し（10秒）をリクエストの中で行うと、
#   5人が同時に登録しただけで全プロセスが埋まり、
#   他のページを開くことすらできなくなる。
#
#   重くて待たされる処理を別プロセスに逃がすことで、
#   Webサーバーは常に軽いリクエストだけを捌ける状態を保てる。
# ============================================================================
class ExplainTermJob < ApplicationJob
  # ==========================================================================
  # キューの指定
  # ==========================================================================
  # 【キューを分ける意味】
  #   今は1種類しか無いが、将来
  #     ・メール送信（軽い・急ぎ）
  #     ・AI生成（重い・待てる）
  #   が混ざったとき、同じ待ち行列だとAI生成の後ろで
  #   メールが何分も待たされる。
  #   キューを分けて、それぞれに割り当てるワーカー数を変えられるようにする。
  queue_as :ai_generation

  # ==========================================================================
  # ジョブレベルのリトライは行わない
  # ==========================================================================
  # 【なぜ discard_on / retry_on を使わないのか】← 重要な設計判断
  #
  #   Active Job にもリトライ機能がある。しかしここでは使わない。
  #   理由は「リトライが二重になる」から。
  #
  #     Llm::Client   … 3回リトライする（実装済み）
  #     Active Job    … さらに5回リトライ（既定）
  #     → 最大 3 × 5 = 15回 APIを呼ぶことになる
  #
  #   1回3.4円なので、1単語で50円。
  #   APIが数時間不調なら、その間ずっと課金され続ける。
  #
  #   【リトライは1つの層でだけ行う】
  #   ここでは Llm::Client の層に一本化し、
  #   ジョブは「失敗したら failed として記録して終わる」だけにする。
  #   ユーザーは画面の「再生成」ボタンで、自分の意思で再実行できる。
  #
  #   自動リトライを増やすより、
  #   「失敗したことが見えて、手で押し直せる」方が
  #   コストも制御でき、原因にも気付きやすい。
  # ==========================================================================

  def perform(term_id)
    # ------------------------------------------------------------------------
    # 【なぜ term オブジェクトではなく term_id を渡すのか】← 頻出の設計判断
    #
    #   perform_later(term) とオブジェクトを渡すこともできるが、
    #   ジョブの引数はRedisにJSONとして保存される（＝シリアライズされる）。
    #
    #   問題は「積んだ時点」と「実行される時点」に時間差があること。
    #   その間にレコードが更新されていると、
    #   古い状態のオブジェクトで処理してしまう。
    #
    #   IDだけ渡して、実行時にDBから読み直せば必ず最新の状態が得られる。
    #   Redisに保存されるデータも小さくなる。
    #
    #   【原則】ジョブの引数は「識別子」を渡し、実体は実行時に取得する。
    # ------------------------------------------------------------------------
    term = Term.find_by(id: term_id)

    # 【なぜ find ではなく find_by なのか】
    #   ジョブがRedisで待っている間に、ユーザーが単語を削除したかもしれない。
    #   find だと例外になり、Sidekiqの管理画面が
    #   「失敗したジョブ」で埋まる。
    #   これは異常ではなく想定内の事象なので、静かに終える。
    if term.nil?
      Rails.logger.info("[ExplainTermJob] term_id=#{term_id} は既に削除されています。処理を中止します。")
      return
    end

    # 【二重実行の防止】
    #   Sidekiqは「少なくとも1回は実行する」保証（at-least-once）。
    #   ワーカーが処理の途中で強制終了すると、
    #   同じジョブがもう一度実行されることがある。
    #
    #   すでに completed になっているものを再生成すると、
    #   無駄に課金され、内容も入れ替わってしまう。
    #   pending でなければ何もしない、としておく。
    unless term.pending?
      Rails.logger.info("[ExplainTermJob] term_id=#{term_id} は #{term.status} のため処理をスキップします。")
      return
    end

    explainer = Llm::Explainer.build
    started_at = Time.current

    begin
      # ----------------------------------------------------------------------
      # AIを呼ぶ（本番は ClaudeExplainer、テストは FakeExplainer）
      # ----------------------------------------------------------------------
      # 【フォルダ一覧を毎回渡す理由】
      #   AIは前回の呼び出しを覚えていない。
      #   「どんな置き場所が既にあるか」を知らないと、
      #   毎回新しい分類名を発明してしまい、フォルダが際限なく増える。
      #
      #   pluck を使うのは、名前しか要らないため。
      #   folders.map(&:name) だとレコード全体を組み立てるが、
      #   pluck は SELECT name だけを発行してその配列を返す。
      explanation, usage = explainer.call(
        word: term.word,
        context: term.context,
        folders: term.user.folders.alphabetical.pluck(:name)
      )

      # ----------------------------------------------------------------------
      # 結果を保存する（1つのトランザクションにまとめる）
      # ----------------------------------------------------------------------
      # 【なぜトランザクションで囲むのか】
      #   ここでは3つの更新を行う:
      #     ① 単語に解説を入れて completed にする
      #     ② タグを作って紐付ける
      #     ③ API呼び出しの記録を残す
      #
      #   もし②の途中で失敗すると、
      #   「解説は入っているがタグが半分だけ付いている」という
      #   中途半端な状態が残る。
      #
      #   トランザクションで囲むと「全部成功」か「全部無かったこと」の
      #   どちらかにしかならない（原子性）。
      #   中途半端な状態がDBに残らないことが保証される。
      Term.transaction do
        term.apply_explanation!(
          reading: explanation.reading,
          full_form: explanation.full_form,
          meaning: explanation.meaning,
          examples: explanation.examples,
          usage_note: explanation.usage_note
        )

        attach_tags(term, explanation.suggested_tags)

        assign_folder(term, explanation.folder)

        record_success(term, usage)
      end

      Rails.logger.info(
        "[ExplainTermJob] 生成完了 term_id=#{term.id} word=#{term.word} " \
        "tokens=#{usage.input_tokens}/#{usage.output_tokens} " \
        "cost=$#{usage.cost_usd.round(5)} #{usage.latency_ms}ms"
      )

    # ------------------------------------------------------------------------
    # 生成に失敗した場合
    # ------------------------------------------------------------------------
    # 【なぜ StandardError まで拾うのか】
    #   Llm::Client::Error だけを拾うと、想定外の例外
    #   （nil参照、タイポによるNoMethodErrorなど）が漏れたとき、
    #   term は pending のまま残る。
    #   ユーザーの画面は永久に「生成中…」になり、
    #   再生成ボタンも押せない（pending は再生成不可のため）状態で詰む。
    #
    #   どんな失敗でも必ず failed に落として、
    #   ユーザーが再試行できる状態にする方が親切で、かつ安全。
    rescue StandardError => e
      Rails.logger.error("[ExplainTermJob] 生成失敗 term_id=#{term.id}: #{e.class} #{e.message}")

      # 【トランザクションを分ける理由】
      #   上の Term.transaction の中で失敗した場合、その中の更新は
      #   ロールバックされている。ここは別の新しいトランザクションとして
      #   「失敗した」という事実だけを確実に書き込む。
      term.apply_failure!("#{e.class}: #{e.message}")
      record_failure(term, e, started_at)

      # 【あえて再raiseしない】
      #   raise するとSidekiqが「失敗したジョブ」として扱い、
      #   既定の設定では自動リトライを始めてしまう（＝課金が増える）。
      #   失敗はDBに記録済みで、ユーザーも画面で確認できるので、
      #   ジョブとしては正常終了させる。
    ensure
      # ----------------------------------------------------------------------
      # 【ensure = 成功しても失敗しても必ず実行される】
      #   成功・失敗どちらの場合でも、ブラウザには結果を伝えたい。
      #   失敗したのに何も通知しないと、画面は「生成中…」のまま止まり、
      #   ユーザーは何が起きたか分からない。
      #
      #   「失敗を伝える」ことも機能のうち。
      # ----------------------------------------------------------------------
      broadcast_update(term)
    end
  end

  private

  # ==========================================================================
  # AIが提案したタグを紐付ける
  # ==========================================================================
  def attach_tags(term, tag_names)
    tag_names.each do |name|
      tag = Tag.find_or_create_for(term.user, name)
      next if tag.nil?

      # 【find_or_create_by を使う理由】
      #   同じ組み合わせが既にあれば作らない。
      #   再生成したときに同じタグを二重に付けるのを防ぐ。
      #   （DB側の複合ユニーク制約もあるが、
      #     例外を出さずに済ませる方が処理として素直）
      TermTag.find_or_create_by!(term: term, tag: tag)
    end
  rescue ActiveRecord::RecordInvalid => e
    # 【タグの失敗で全体を失敗させない】
    #   タグはあくまで補助的な機能。
    #   タグ付けに失敗したからといって、
    #   せっかく生成した解説まで捨てるのは損失が大きい。
    #   記録だけ残して処理は続行する。
    Rails.logger.warn("[ExplainTermJob] タグ付けに失敗 term_id=#{term.id}: #{e.message}")
  end

  # ==========================================================================
  # AIが選んだフォルダを反映する
  # ==========================================================================
  # 【2つの結果に分かれる】
  #   既存フォルダに一致 → その場で所属を確定（利用者の操作は不要）
  #   一致しない        → 提案として保持。所属は未分類のまま
  #
  #   判定と保存の中身は Term#apply_folder_suggestion! にある。
  #   ジョブ側は「呼ぶ」だけにして、判断のルールはモデルに置く。
  #
  # 【勝手に新しいフォルダを作らない理由】
  #   作ってしまうと、フォルダが単語のたびに増えてタグと同じ末路になる。
  #   フォルダの価値は「少なくて安定していること」なので、
  #   増やす判断は人間が行う。
  def assign_folder(term, folder_name)
    term.apply_folder_suggestion!(folder_name)
  rescue ActiveRecord::RecordInvalid => e
    # 【分類の失敗で全体を失敗させない】
    #   タグと同じ考え方。分類は補助的な機能であり、
    #   これに失敗したからといって、生成できた解説まで
    #   捨てるのは損失（1件3.4円）が大きい。
    Rails.logger.warn("[ExplainTermJob] フォルダの割り当てに失敗 term_id=#{term.id}: #{e.message}")
  end

  # ==========================================================================
  # API呼び出しの記録（成功）
  # ==========================================================================
  def record_success(term, usage)
    ApiCallLog.create!(
      term: term,
      model: usage.model,
      prompt_version: usage.prompt_version,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cost_micro_usd: usage.cost_micro_usd,
      latency_ms: usage.latency_ms,
      attempt: usage.attempt,
      success: true
    )
  end

  # ==========================================================================
  # API呼び出しの記録（失敗）
  # ==========================================================================
  def record_failure(term, error, started_at)
    # 失敗時は Usage が得られないので、分かる範囲だけ記録する。
    ApiCallLog.create!(
      term: term,
      model: Llm::Client::DEFAULT_MODEL,
      prompt_version: Llm::Prompts::ExplainTermV1::VERSION,
      input_tokens: 0,
      output_tokens: 0,
      cost_micro_usd: 0,
      latency_ms: ((Time.current - started_at) * 1000).round,
      # 【元の例外クラス名を記録する】
      #   Llm::Client::Error は自前のラッパーなので、
      #   そのまま記録すると全部同じ名前になって集計できない。
      #   中身の本当の原因（RateLimitError など）を取り出す。
      error_class: error.respond_to?(:original_class_name) ? error.original_class_name : error.class.name,
      error_detail: error.message.to_s.truncate(1000),
      attempt: error.respond_to?(:attempts) ? error.attempts : 1,
      success: false
    )
  rescue StandardError => e
    # 【ログの記録に失敗しても本処理は止めない】
    #   記録は運用のための補助機能。
    #   ここで例外を投げると、失敗処理そのものが失敗して
    #   term が pending のまま残ってしまう。
    Rails.logger.error("[ExplainTermJob] ログ記録に失敗: #{e.message}")
  end

  # ==========================================================================
  # ブラウザへ結果を通知する（WebSocket）
  # ==========================================================================
  def broadcast_update(term)
    # ------------------------------------------------------------------------
    # 【broadcast_to の仕組み】
    #   TermsChannel を「購読している」ブラウザに対してデータを送る。
    #
    #   第1引数の term.user が「宛先」になる。
    #   ユーザーごとに別々の配信路になるので、
    #   他人の単語の更新が自分の画面に流れてくることはない。
    #
    # 【ここで何が起きているか（プロセスを跨ぐ部分）】
    #   このコードは Sidekiq のプロセスで動いている。
    #   ブラウザとWebSocketで繋がっているのは Rails のプロセス。
    #   両者はメモリを共有していないので、直接は渡せない。
    #
    #   そこで broadcast_to は Redis に publish する。
    #   Rails 側が subscribe していて受け取り、ブラウザへ流す。
    #
    #   config/cable.yml の development を async から redis に変えたのは、
    #   まさにこのため。async のままだとここで送っても誰にも届かない。
    # ------------------------------------------------------------------------
    # 【TermSerializer に集約している理由】
    #   以前はここに変換処理を直接書いていたが、
    #   TermsController にも同じものがあり、二重管理になっていた。
    #   カラムを足したときに片方だけ直すと、
    #   「リロードすれば見えるのに自動更新では反映されない」という
    #   切り分けの難しい不具合になる。
    #
    # 【reload している理由】
    #   直前のトランザクションでタグとフォルダを付け替えている。
    #   関連はメモリ上にキャッシュされるため、読み直さないと
    #   付け替える前の内容を送ってしまう。
    TermsChannel.broadcast_to(
      term.user,
      {
        type: "term_updated",
        term: TermSerializer.call(term.reload)
      }
    )
  rescue StandardError => e
    # 【通知の失敗で処理を落とさない】
    #   Redisが一時的に落ちていても、
    #   解説の生成と保存は既に完了している。
    #   ユーザーはページを再読み込みすれば結果を見られる。
    #   通知できないことは不便だが、致命的ではない。
    Rails.logger.error("[ExplainTermJob] WebSocket通知に失敗 term_id=#{term.id}: #{e.message}")
  end
end
