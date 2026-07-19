# ============================================================================
# Llm::Client — Claude API を呼ぶ低レベル層
#
# 【このクラスの責務】
#   ・APIを呼ぶ
#   ・失敗したらリトライする
#   ・所要時間とトークン数を測る
#   ・エラーを「retryできる／できない」に分類する
#
# 【責務に含めないこと】
#   ・プロンプトの中身    → prompts/ が持つ
#   ・結果をどう保存するか → ClaudeExplainer が持つ
#
#   1クラスが1つのことだけをする形にしておくと、
#   「リトライの挙動を変えたい」ときに読む場所が1つに定まる。
# ============================================================================
module Llm
  class Client
    # ==========================================================================
    # リトライの設定
    # ==========================================================================
    # 【なぜ3回なのか】
    #   1回でやめると、一瞬の通信断で失敗してしまう。
    #   10回やると、本当に壊れているときに待ち時間が延々と伸び、
    #   しかもレート制限の場合は状況を悪化させる。
    #   3回は「一時的な問題は吸収し、恒久的な問題は早く諦める」現実的な線。
    MAX_ATTEMPTS = 3

    # 【指数バックオフ（exponential backoff）】
    #   リトライの間隔を 1秒 → 2秒 → 4秒 と倍々に伸ばす方式。
    #
    #   なぜ等間隔ではだめか:
    #     サーバーが高負荷で502を返しているとき、
    #     全クライアントが1秒ごとに再送すると負荷が下がらず、
    #     復旧をさらに遅らせる（「サンダリングハード問題」）。
    #     間隔を伸ばせば、時間とともに負荷が自然に下がる。
    BASE_DELAY_SECONDS = 1

    # 【1回のリクエストの制限時間】
    #   Opus 4.8 で数百トークンの生成なら通常10〜20秒。
    #   60秒を超えるのは異常事態なので、待ち続けずに諦めてリトライする。
    REQUEST_TIMEOUT_SECONDS = 60

    # 既定で使うモデル。
    # 【なぜ定数にするか】複数箇所に文字列を書くと、
    #   モデルを変えるときに変え漏れが出る。
    #
    # 【なぜ Opus 4.8 か】単語解説の品質がこのアプリの価値そのもの。
    #   1単語あたり約3.4円、月30単語で約100円なので、
    #   ここで安いモデルを選んで品質を落とす理由が無い。
    #   コストを抑えたくなったら "claude-sonnet-5" に変えて、
    #   api_call_logs で品質とコストの差を比較するとよい。
    DEFAULT_MODEL = "claude-opus-4-8".freeze

    # ==========================================================================
    # リトライすべきエラーの分類
    # ==========================================================================
    # 【この分類がハーネスの肝】
    #
    #   ■ リトライする価値があるもの（一時的な問題）
    #     ・429 レート制限        … 待てば通る
    #     ・500/529 サーバー障害  … 相手側の一時的な不調
    #     ・接続エラー・タイムアウト … ネットワークの揺れ
    #
    #   ■ リトライしても無駄なもの（こちら側の問題）
    #     ・401 認証エラー   … APIキーが違う。何度送っても同じ
    #     ・400 不正リクエスト … スキーマが壊れている。直すまで通らない
    #     ・404 モデルが無い  … モデル名の打ち間違い
    #
    #   分類せず全部リトライすると:
    #     ・APIキーを間違えただけで3倍の時間待たされる
    #     ・原因が「3回試したがダメ」に埋もれて分かりにくくなる
    #
    #   逆に全くリトライしないと、
    #   一瞬の通信断で解説が失敗し、ユーザーが手で押し直すことになる。
    RETRYABLE_ERRORS = [
      Anthropic::Errors::RateLimitError,      # 429
      Anthropic::Errors::InternalServerError, # 500番台
      Anthropic::Errors::APIConnectionError,  # 接続できない
      Anthropic::Errors::APITimeoutError      # 時間切れ
    ].freeze

    # 【設定ミス系のエラー】
    #   リトライしないだけでなく、ログに警告を出して
    #   運用者が気付けるようにしたいもの。
    FATAL_ERRORS = [
      Anthropic::Errors::AuthenticationError,  # 401 APIキーが不正
      Anthropic::Errors::PermissionDeniedError # 403 権限不足・残高不足
    ].freeze

    # 呼び出し側に返す独自の例外。
    # 【なぜ自前の例外を定義するのか】
    #   SDKの例外をそのまま外へ流すと、呼び出し側がSDKの型を知る必要が出る。
    #   将来SDKを差し替えたとき、呼び出し側まで修正が波及してしまう。
    #   境界で自前の型に変換しておけば、内側の変更が外に漏れない。
    class Error < StandardError
      attr_reader :original, :attempts

      def initialize(message, original: nil, attempts: 1)
        super(message)
        @original = original
        @attempts = attempts
      end

      # 元の例外のクラス名。api_call_logs に記録して集計に使う。
      def original_class_name
        @original&.class&.name || self.class.name
      end
    end

    def initialize(api_key: ENV["ANTHROPIC_API_KEY"], model: DEFAULT_MODEL)
      # 【ここで落とす理由】
      #   キーが無いまま呼び出すと、実際にAPIを叩く段になって
      #   401が返り、リトライを3回繰り返してから失敗する。
      #   起動時点で分かる問題は、起動時点で止める方がよい。
      raise Error, "ANTHROPIC_API_KEY が設定されていません" if api_key.blank?

      @model = model
      @client = Anthropic::Client.new(
        api_key: api_key,

        # ----------------------------------------------------------------
        # 【max_retries: 0 にしている理由】← 重要
        #   SDKは既定で2回リトライする。
        #   その上で自分でも3回リトライすると、
        #   最悪 3 × 3 = 9回 APIを叩くことになる。
        #
        #   課金は呼んだ回数だけ発生するので、
        #   気付かないうちに想定の3倍払うことになる。
        #
        #   「リトライは1箇所でだけ行う」——多層で重ねない。
        #   ここでSDK側を切り、自前の層に一本化している。
        #   （自前にする理由は、試行回数をログに残したいため）
        # ----------------------------------------------------------------
        max_retries: 0,
        timeout: REQUEST_TIMEOUT_SECONDS
      )
    end

    # ==========================================================================
    # 構造化された出力を得る
    # ==========================================================================
    # @return [Array(Hash, Llm::Usage)] 生成されたJSONと、計測結果
    def generate_json(system:, user_message:, schema:, prompt_version:, max_tokens: 4096)
      attempt = 0
      started = monotonic_now

      begin
        attempt += 1

        response = @client.messages.create(
          model: @model,
          max_tokens: max_tokens,

          # 【system_ の末尾のアンダースコアについて】
          #   Rubyには Kernel#system という組み込みメソッド（外部コマンド実行）が
          #   既にある。同名だと衝突するため、SDKが system_ という名前にしている。
          #   Ruby SDK 特有の書き方で、他言語では単に system。
          system_: system,

          messages: [ { role: "user", content: user_message } ],

          output_config: {
            # 【structured output】この形のJSONしか出力できないよう制約する。
            format: { type: "json_schema", schema: schema },

            # 【effort（思考の深さ）】
            #   low / medium / high / xhigh / max から選ぶ。
            #   高いほど賢いが、時間とトークン（＝お金）を使う。
            #
            #   単語の解説は「深い推論」より「正確で読みやすい説明」が求められる
            #   タスクなので medium を選択。
            #   もし解説の質に不満が出たら high に上げて比較するとよい。
            #   その効果は api_call_logs の prompt_version と
            #   トークン数の記録から測れる。
            effort: "medium"
          }
        )

        latency_ms = ((monotonic_now - started) * 1000).round

        # ----------------------------------------------------------------
        # 応答から本文を取り出す
        # ----------------------------------------------------------------
        # 【なぜ content[0].text と書かないのか】
        #   content は複数のブロックが並んだ配列で、
        #   text 以外のブロック（thinking など）が先頭に来ることがある。
        #   決め打ちで [0] を取ると、設定を変えた瞬間に壊れる。
        #
        # 【block.type がシンボルである点に注意】
        #   Ruby SDK では :text であって "text" ではない。
        #   文字列と比較すると常に false になり、
        #   「なぜか本文が取れない」という分かりにくい不具合になる。
        text_block = response.content.find { |b| b.type == :text }
        raise Error.new("応答にテキストが含まれていません", attempts: attempt) if text_block.nil?

        # ----------------------------------------------------------------
        # JSONとして解釈する
        # ----------------------------------------------------------------
        # 【structured output を使っていてもパースを保護する理由】
        #   スキーマ指定により壊れたJSONはほぼ返らないが、
        #   「ほぼ」であって「絶対」ではない。
        #   max_tokens に達して途中で切れた場合などは壊れうる。
        #
        #   ここで落ちると原因が「JSON::ParserError」としか出ず、
        #   何が返ってきたのか分からない。応答の冒頭を添えておく。
        parsed = begin
          JSON.parse(text_block.text)
        rescue JSON::ParserError => e
          raise Error.new(
            "AIの応答をJSONとして解釈できませんでした: #{e.message} / 応答冒頭: #{text_block.text.to_s[0, 200]}",
            original: e, attempts: attempt
          )
        end

        usage = Usage.new(
          model: @model,
          prompt_version: prompt_version,
          input_tokens: response.usage.input_tokens,
          output_tokens: response.usage.output_tokens,
          latency_ms: latency_ms,
          attempt: attempt
        )

        [ parsed, usage ]

      # --------------------------------------------------------------------
      # リトライする例外
      # --------------------------------------------------------------------
      rescue *RETRYABLE_ERRORS => e
        if attempt < MAX_ATTEMPTS
          delay = BASE_DELAY_SECONDS * (2**(attempt - 1))   # 1秒 → 2秒 → 4秒

          Rails.logger.warn(
            "[Llm::Client] #{e.class.name} により #{delay}秒後に再試行します " \
            "(#{attempt}/#{MAX_ATTEMPTS}): #{e.message}"
          )

          sleep(delay)
          retry   # begin まで戻ってやり直す
        end

        # 回数を使い切った。ここで諦める。
        raise Error.new(
          "#{MAX_ATTEMPTS}回試行しましたが失敗しました: #{e.message}",
          original: e, attempts: attempt
        )

      # --------------------------------------------------------------------
      # リトライしても無駄な例外（設定ミス）
      # --------------------------------------------------------------------
      rescue *FATAL_ERRORS => e
        # 【error ではなく警告レベルを上げて出す理由】
        #   これは「アプリのバグ」ではなく「設定の問題」。
        #   APIキーの期限切れや残高不足で起きるため、
        #   運用者が対処すべきものだと分かるメッセージにする。
        Rails.logger.error(
          "[Llm::Client] APIキーまたは権限に問題があります。" \
          "console.anthropic.com で残高とキーを確認してください: #{e.message}"
        )
        raise Error.new("APIの認証に失敗しました: #{e.message}", original: e, attempts: attempt)

      # --------------------------------------------------------------------
      # その他のAPIエラー（400番台など、こちらの送り方の問題）
      # --------------------------------------------------------------------
      rescue Anthropic::Errors::APIError => e
        raise Error.new("APIエラー: #{e.message}", original: e, attempts: attempt)
      end
    end

    private

    # ------------------------------------------------------------------------
    # 経過時間の計測に使う時刻
    # ------------------------------------------------------------------------
    # 【なぜ Time.now ではないのか】
    #   Time.now は「壁時計」で、NTPによる時刻同期や
    #   サマータイムの切り替えで急に巻き戻ることがある。
    #   その瞬間に計測すると、所要時間が負の値になる。
    #
    #   monotonic は「起動してからの経過秒数」で、
    #   決して巻き戻らないことが保証されている。
    #   時間の「差」を測る用途では必ずこちらを使う。
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
