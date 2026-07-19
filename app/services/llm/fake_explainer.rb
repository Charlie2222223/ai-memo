# ============================================================================
# Llm::FakeExplainer — テスト・開発用。APIを呼ばずに即座に結果を返す
#
# 【なぜこれが必要か】
#   本物のAPIをテストで使うと:
#     ① 実行のたびに課金される（テストは1日に何十回も走る）
#     ② 1回10秒かかる → テストが遅い → 誰も走らせなくなる
#     ③ AIの返答は毎回違う → 同じコードなのに通ったり落ちたりする
#     ④ ネットが無い場所で開発できない
#     ⑤ 「APIが500を返したとき」を再現できない（わざと壊してくれない）
#
#   ⑤が特に重要。異常系こそテストしたいのに、
#   本物のAPIでは異常を起こせない。
#   Fakeなら「今回は失敗する」を自由に作れる。
#
# 【これはモック（mock）と呼ばれるものの一種】
#   本物の代わりに振る舞う偽物。
#   テストの世界では stub / mock / fake などと呼び分けるが、
#   要点は「本物の代わりに、都合よく制御できるものを差し込む」こと。
# ============================================================================
module Llm
  class FakeExplainer < Explainer
    # 呼び出し履歴。テストから「何回呼ばれたか」を検証できる。
    attr_reader :calls

    # --------------------------------------------------------------------------
    # @param raise_error [Exception, nil]
    #   指定すると、呼ばれたときにその例外を投げる。
    #   異常系のテスト（失敗したら status が failed になるか）で使う。
    # @param delay [Float] わざと遅延させたい場合の秒数
    # --------------------------------------------------------------------------
    def initialize(raise_error: nil, delay: 0)
      @raise_error = raise_error
      @delay = delay
      @calls = []
    end

    def call(word:, context: nil)
      # 何を渡されたかを記録しておく。
      # 【何に使うか】テストで
      #   「context がちゃんとAIに渡されているか」を検証できる。
      #   渡し忘れは画面上は分からないので、ここで担保する。
      @calls << { word: word, context: context }

      sleep(@delay) if @delay.positive?

      # 異常系テスト用。指定された例外を投げる。
      raise @raise_error if @raise_error

      explanation = Explanation.new(
        meaning: "「#{word}」のテスト用の意味です。",
        examples: [
          "「#{word}」の例文1",
          "「#{word}」の例文2"
        ],
        usage_note: "「#{word}」のテスト用の使い方です。",
        suggested_tags: [ "テスト" ]
      )

      # 【Usage も本物と同じ形で返す理由】
      #   api_call_logs への記録処理もテストで通したいため。
      #   Fakeが nil を返すと、記録部分だけテストされないまま残る。
      #   「Fakeは本物と同じ形を返す」が原則。
      usage = Usage.new(
        model: "fake-model",
        prompt_version: Prompts::ExplainTermV1::VERSION,
        input_tokens: 100,
        output_tokens: 200,
        latency_ms: 5,
        attempt: 1
      )

      [ explanation, usage ]
    end
  end
end
