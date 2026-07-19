# ============================================================================
# Llm::Client のテスト — リトライと異常系
#
# 【このテストが最も価値のある部分】
#   ここで検証するのは、本物のAPIでは絶対に再現できないこと:
#     ・APIが429（レート制限）を返したら、待って再試行するか
#     ・3回失敗したら諦めるか
#     ・401（認証エラー）ならリトライせず即座に諦めるか
#     ・壊れたJSONが返ってきても落ちないか
#
#   本物のAPIは、頼んでもレート制限を返してくれない。
#   WebMockで「今回はこう返す」を作れるから検証できる。
#
# 【WebMock とは】
#   HTTP通信を横取りして、指定した応答を返す仕組み。
#   実際にネットワークへは出ていかない。
#   → 課金されず、一瞬で終わり、結果が毎回同じ。
# ============================================================================
require "rails_helper"

RSpec.describe Llm::Client do
  # Anthropic APIのエンドポイント。
  let(:api_url) { "https://api.anthropic.com/v1/messages" }
  let(:client)  { described_class.new(api_key: "sk-ant-test-key") }

  # 正常な応答の形。
  # 【本物と同じ形にすることが重要】
  #   形が違うと、テストは通るのに本番で落ちる、という
  #   最悪の状態になる。実際の応答構造に合わせる。
  let(:success_body) do
    {
      id: "msg_test",
      type: "message",
      role: "assistant",
      model: "claude-opus-4-8",
      content: [
        {
          type: "text",
          text: {
            meaning: "同じ操作を何回行っても結果が変わらない性質のこと。",
            examples: [ "注文APIを2回叩いても注文が二重にならない" ],
            usage_note: "API設計やリトライ処理の文脈で使う。",
            suggested_tags: [ "API設計" ]
          }.to_json
        }
      ],
      stop_reason: "end_turn",
      usage: { input_tokens: 350, output_tokens: 500 }
    }.to_json
  end

  # 【sleep を無効化する】
  #   リトライは 1秒 → 2秒 と待つ設計なので、
  #   そのままだとテストが3秒以上かかる。
  #   待ち時間そのものは検証対象ではないので、飛ばす。
  #
  #   【注意】sleep を消していいのは「待つこと自体が仕様ではない」場合だけ。
  #   待ち時間の長さを検証したいなら、逆に呼ばれた引数を確認する。
  before { allow_any_instance_of(described_class).to receive(:sleep) }

  def generate
    client.generate_json(
      system: "テスト用システムプロンプト",
      user_message: "冪等性を解説してください",
      schema: { type: "object" },
      prompt_version: "test_v1"
    )
  end

  # ==========================================================================
  describe "正常系" do
    it "JSONと使用量を返す" do
      stub_request(:post, api_url).to_return(
        status: 200, body: success_body, headers: { "Content-Type" => "application/json" }
      )

      parsed, usage = generate

      expect(parsed["meaning"]).to include("同じ操作")
      expect(usage.input_tokens).to eq(350)
      expect(usage.output_tokens).to eq(500)
      expect(usage.attempt).to eq(1)
    end

    it "コストが正しく計算される" do
      # ----------------------------------------------------------------------
      # 【計算の確認】Opus 4.8 の単価は
      #   入力 5マイクロUSD/トークン、出力 25マイクロUSD/トークン。
      #     350 × 5  = 1,750
      #     500 × 25 = 12,500
      #     合計       14,250 マイクロUSD = $0.01425 ≒ 2.1円
      #
      # 【なぜ単価計算をテストするのか】
      #   間違っていても画面には何も出ないので、誰も気付かない。
      #   気付くのは請求額を見たときで、そのときには手遅れ。
      # ----------------------------------------------------------------------
      stub_request(:post, api_url).to_return(
        status: 200, body: success_body, headers: { "Content-Type" => "application/json" }
      )

      _parsed, usage = generate
      expect(usage.cost_micro_usd).to eq(14_250)
    end
  end

  # ==========================================================================
  describe "リトライ（一時的な障害）" do
    it "429（レート制限）なら再試行して、成功すれば結果を返す" do
      # ----------------------------------------------------------------------
      # 【to_return を複数並べる意味】
      #   1回目は429、2回目は200を返す、という順序を作れる。
      #   「一時的に失敗したが、待ったら通った」状況の再現。
      # ----------------------------------------------------------------------
      stub_request(:post, api_url)
        .to_return(status: 429, body: '{"type":"error","error":{"type":"rate_limit_error","message":"rate limited"}}',
                   headers: { "Content-Type" => "application/json" })
        .then
        .to_return(status: 200, body: success_body,
                   headers: { "Content-Type" => "application/json" })

      parsed, usage = generate

      expect(parsed["meaning"]).to be_present
      # 2回目で成功したことが記録されている。
      # 【なぜ試行回数を記録するのか】
      #   「1回で成功」と「3回目でようやく成功」は同じ成功でも意味が違う。
      #   後者が増えていれば、API側が不安定になっている兆候。
      expect(usage.attempt).to eq(2)
    end

    it "500（サーバー障害）でも再試行する" do
      stub_request(:post, api_url)
        .to_return(status: 500, body: '{"type":"error","error":{"type":"api_error","message":"oops"}}',
                   headers: { "Content-Type" => "application/json" })
        .then
        .to_return(status: 200, body: success_body,
                   headers: { "Content-Type" => "application/json" })

      _parsed, usage = generate
      expect(usage.attempt).to eq(2)
    end

    it "3回失敗したら諦めてエラーになる" do
      stub_request(:post, api_url).to_return(
        status: 429,
        body: '{"type":"error","error":{"type":"rate_limit_error","message":"rate limited"}}',
        headers: { "Content-Type" => "application/json" }
      )

      expect { generate }.to raise_error(Llm::Client::Error, /3回試行/)

      # ----------------------------------------------------------------------
      # 【呼び出し回数の検証が重要】
      #   ちょうど3回であることを確認する。
      #   もしSDK側のリトライを切り忘れていたら（max_retries: 0 の指定漏れ）、
      #   ここが9回になって、このテストが落ちて気付ける。
      #
      #   課金は呼んだ回数だけ発生するので、
      #   「何回呼ぶか」はコストに直結する仕様。
      # ----------------------------------------------------------------------
      expect(WebMock).to have_requested(:post, api_url).times(3)
    end
  end

  # ==========================================================================
  describe "リトライしない失敗（設定の問題）" do
    it "401（認証エラー）は1回で諦める" do
      # ----------------------------------------------------------------------
      # 【なぜリトライしてはいけないか】
      #   APIキーが間違っているなら、何回送っても結果は同じ。
      #   3回試すのは時間の無駄で、
      #   本当の原因が「3回試したがダメ」というログに埋もれる。
      #
      #   「直せば通る問題」と「待てば通る問題」を区別するのが
      #   エラー分類の目的。
      # ----------------------------------------------------------------------
      stub_request(:post, api_url).to_return(
        status: 401,
        body: '{"type":"error","error":{"type":"authentication_error","message":"invalid key"}}',
        headers: { "Content-Type" => "application/json" }
      )

      expect { generate }.to raise_error(Llm::Client::Error, /認証/)
      expect(WebMock).to have_requested(:post, api_url).times(1)
    end

    it "400（不正なリクエスト）もリトライしない" do
      stub_request(:post, api_url).to_return(
        status: 400,
        body: '{"type":"error","error":{"type":"invalid_request_error","message":"bad schema"}}',
        headers: { "Content-Type" => "application/json" }
      )

      expect { generate }.to raise_error(Llm::Client::Error)
      expect(WebMock).to have_requested(:post, api_url).times(1)
    end
  end

  # ==========================================================================
  describe "壊れた応答への耐性" do
    it "JSONとして解釈できない本文なら、内容を添えてエラーにする" do
      # ----------------------------------------------------------------------
      # 【structured output を使っていてもテストする理由】
      #   スキーマ指定により壊れたJSONはほぼ返らないが、
      #   max_tokens に達して途中で切れる可能性は残る。
      #
      #   そのときに「JSON::ParserError」とだけ出ると、
      #   何が返ってきたのか分からず原因を追えない。
      #   応答の冒頭をエラーメッセージに含めているのは、そのため。
      # ----------------------------------------------------------------------
      broken = {
        id: "msg_test", type: "message", role: "assistant", model: "claude-opus-4-8",
        content: [ { type: "text", text: '{"meaning": "途中で切れ' } ],
        stop_reason: "max_tokens",
        usage: { input_tokens: 10, output_tokens: 10 }
      }.to_json

      stub_request(:post, api_url).to_return(
        status: 200, body: broken, headers: { "Content-Type" => "application/json" }
      )

      expect { generate }.to raise_error(Llm::Client::Error, /JSONとして解釈できません/)
    end
  end

  # ==========================================================================
  describe "設定の検証" do
    it "APIキーが無ければ、呼び出す前にエラーになる" do
      # 【なぜ起動時に落とすのか】
      #   キーが無いまま呼ぶと、401を受けてから
      #   （分類上リトライしないとはいえ）無駄な通信が発生する。
      #   分かっている問題は、分かった時点で止める。
      expect { described_class.new(api_key: nil) }
        .to raise_error(described_class::Error, /ANTHROPIC_API_KEY/)
    end
  end
end
