# ============================================================================
# ExplainTermJob のテスト
#
# 非同期処理の要は「失敗したときにどうなるか」。
# 成功時の動作は手で確認しても分かるが、
# 「APIが落ちていたとき」は手では再現できない。
# ============================================================================
require "rails_helper"

RSpec.describe ExplainTermJob, type: :job do
  let(:user) { create(:user) }
  let(:term) { create(:term, user: user, word: "冪等性", context: "API設計の記事で見た") }

  # ==========================================================================
  describe "生成が成功したとき" do
    it "解説が保存され、status が completed になる" do
      described_class.perform_now(term.id)

      term.reload
      expect(term).to be_completed
      expect(term.meaning).to include("冪等性")
      expect(term.examples).to be_an(Array).and be_present
      expect(term.usage_note).to be_present
      # 生成完了時刻が記録されていること。
      expect(term.generated_at).to be_present
    end

    it "AIが提案したタグが紐付く" do
      described_class.perform_now(term.id)

      expect(term.reload.tags.map(&:name)).to include("テスト")
    end

    it "API呼び出しの記録が残る" do
      # ----------------------------------------------------------------------
      # 【なぜコスト記録をテストするのか】
      #   記録が抜けても画面上は何も変わらないので、
      #   壊れても誰も気付かない。
      #   気付いたときには「先月いくら使ったか分からない」となる。
      #
      #   目に見えない機能ほど、テストで守る価値が高い。
      # ----------------------------------------------------------------------
      expect { described_class.perform_now(term.id) }
        .to change(ApiCallLog, :count).by(1)

      log = ApiCallLog.last
      expect(log.success).to be(true)
      expect(log.input_tokens).to eq(100)    # FakeExplainer が返す値
      expect(log.output_tokens).to eq(200)
      expect(log.term_id).to eq(term.id)
    end

    it "WebSocketで完了が通知される" do
      # ----------------------------------------------------------------------
      # 【have_broadcasted_to とは】
      #   Action Cable の test アダプタを使い、
      #   「誰に対して放送されたか」を検証する。
      #
      #   config/cable.yml の test を adapter: test にしたのは、
      #   本物のRedisに繋がずにこれを検証できるようにするため。
      #
      # 【なぜ user 宛であることまで確認するのか】
      #   宛先を間違えると、他人の画面に自分の単語が流れる。
      #   HTTPのAPIには権限チェックを書いても、
      #   WebSocketの宛先を間違えるという事故は起きやすい。
      # ----------------------------------------------------------------------
      expect { described_class.perform_now(term.id) }
        .to have_broadcasted_to(user).from_channel(TermsChannel)
    end

    it "context がAIに渡される" do
      # ----------------------------------------------------------------------
      # 【なぜこれを確認するか】
      #   context（どこで見たか）を渡し忘れても、
      #   解説は普通に生成されるので画面上は正常に見える。
      #   ただ「文脈に沿った解説」にならないだけ。
      #
      #   気付けない不具合なので、テストで固定しておく。
      #   FakeExplainer が呼び出し履歴を記録しているのは、これを見るため。
      # ----------------------------------------------------------------------
      fake = Llm::FakeExplainer.new
      allow(Llm::Explainer).to receive(:build).and_return(fake)

      described_class.perform_now(term.id)

      # 【eq ではなく include を使う理由】
      #   eq はハッシュの完全一致を求めるため、AIに渡す情報を1つ足すたびに
      #   このテストが壊れる（実際 folders を足したときに壊れた）。
      #
      #   ここで確かめたいのは「context が渡っていること」だけ。
      #   include なら、他のキーが増えても意図した検証は生き続ける。
      expect(fake.calls.first).to include(word: "冪等性", context: "API設計の記事で見た")
    end

    it "既存フォルダの一覧がAIに渡される" do
      # ----------------------------------------------------------------------
      # 【なぜこれを確認するか】
      #   フォルダ一覧を渡し忘れても、AIは何らかの分類名を返すので
      #   画面上は「動いている」ように見える。
      #
      #   しかし既存を知らないAIは毎回新しい名前を発明するため、
      #   フォルダが単語の数だけ増え続ける。
      #   タグと同じ理由でナビゲーションとして破綻する。
      #
      #   壊れても気付けない類の不具合なので、テストで固定する。
      # ----------------------------------------------------------------------
      user.folders.create!(name: "Web・HTTP")
      user.folders.create!(name: "設計")

      fake = Llm::FakeExplainer.new
      allow(Llm::Explainer).to receive(:build).and_return(fake)

      described_class.perform_now(term.id)

      expect(fake.calls.first[:folders]).to contain_exactly("Web・HTTP", "設計")
    end
  end

  # ==========================================================================
  # フォルダの自動振り分け
  # ==========================================================================
  # 【この2つの分岐がフォルダ機能の本質】
  #   既存に当てはまれば黙って入れ、当てはまらなければ提案に留める。
  #   後者で勝手にフォルダを作ってしまうと、フォルダが際限なく増えて
  #   タグと同じ末路をたどる。
  describe "フォルダの割り当て" do
    # user / term はファイル冒頭の let をそのまま使う（既定で status: pending）。

    it "既存フォルダに当てはまるときは、そのフォルダに入り提案は残らない" do
      folder = user.folders.create!(name: "Web・HTTP")

      # FakeExplainer は「既存があればその先頭を選ぶ」振る舞いをする。
      described_class.perform_now(term.id)

      term.reload
      expect(term.folder).to eq(folder)
      expect(term.suggested_folder_name).to be_nil
    end

    it "既存フォルダが無いときは提案として保持し、勝手にフォルダを作らない" do
      described_class.perform_now(term.id)

      term.reload
      expect(term.folder).to be_nil
      expect(term.suggested_folder_name).to be_present
      # 【ここが最重要】提案の段階でフォルダを作ってはいけない。
      expect(user.folders.count).to eq(0)
    end
  end

  # ==========================================================================
  describe "生成が失敗したとき" do
    # 【allow(...).to receive(...) の意味】
    #   指定したメソッドの戻り値を差し替える（スタブ化）。
    #   ここでは Llm::Explainer.build が
    #   「必ず例外を投げるFake」を返すようにしている。
    #
    #   これにより「APIがレート制限を返した状況」を
    #   確実に、一瞬で、無料で再現できる。
    before do
      failing = Llm::FakeExplainer.new(
        raise_error: Llm::Client::Error.new("3回試行しましたが失敗しました: rate limited")
      )
      allow(Llm::Explainer).to receive(:build).and_return(failing)
    end

    it "status が failed になり、エラー内容が残る" do
      described_class.perform_now(term.id)

      term.reload
      expect(term).to be_failed
      expect(term.error_message).to include("rate limited")
    end

    it "失敗もAPI呼び出し記録に残る" do
      expect { described_class.perform_now(term.id) }
        .to change(ApiCallLog, :count).by(1)

      log = ApiCallLog.last
      expect(log.success).to be(false)
      expect(log.error_class).to be_present
    end

    it "失敗してもWebSocketで通知される" do
      # ----------------------------------------------------------------------
      # 【なぜ失敗時こそ通知が重要か】
      #   通知しないと、画面は「生成中…」のまま永久に止まる。
      #   ユーザーは待てばいいのか壊れているのか分からない。
      #
      #   ジョブの ensure ブロックで通知しているのは、これを保証するため。
      # ----------------------------------------------------------------------
      expect { described_class.perform_now(term.id) }
        .to have_broadcasted_to(user).from_channel(TermsChannel)
    end

    it "ジョブ自体は例外を投げない（Sidekiqのリトライを起こさない）" do
      # ----------------------------------------------------------------------
      # 【なぜ例外を投げてはいけないか】
      #   例外を投げるとSidekiqが自動リトライを開始する。
      #   Llm::Client で既に3回試しているので、
      #   さらに25回リトライされると 3 × 25 = 75回 APIを呼ぶ。
      #   1回3.4円なので、1単語で250円を超える。
      #
      #   「リトライは1つの層でだけ行う」という設計判断を、
      #   このテストが守っている。
      # ----------------------------------------------------------------------
      expect { described_class.perform_now(term.id) }.not_to raise_error
    end

    it "失敗後は再生成できる状態になる" do
      described_class.perform_now(term.id)
      expect(term.reload.regeneratable?).to be(true)
    end
  end

  # ==========================================================================
  describe "異常な状況への耐性" do
    it "単語が既に削除されていても落ちない" do
      # ----------------------------------------------------------------------
      # 【実際に起きる状況】
      #   ジョブがRedisで順番待ちしている間に、
      #   ユーザーがその単語を削除することがある。
      #
      #   find を使っていると例外になり、
      #   Sidekiqの管理画面が「失敗したジョブ」で埋まる。
      #   これは異常ではなく想定内なので、静かに終わるべき。
      # ----------------------------------------------------------------------
      deleted_id = term.id
      term.destroy!

      expect { described_class.perform_now(deleted_id) }.not_to raise_error
    end

    it "既に completed のものは再処理しない（二重実行の防止）" do
      # ----------------------------------------------------------------------
      # 【なぜ必要か】
      #   Sidekiqは「少なくとも1回実行する」保証（at-least-once）で、
      #   ワーカーが処理中に強制終了すると同じジョブが再実行されうる。
      #
      #   対策が無いと、完成済みの解説がもう一度生成され、
      #   無駄に課金された上、内容が入れ替わる。
      # ----------------------------------------------------------------------
      completed = create(:term, :completed, user: user)
      original_meaning = completed.meaning

      expect { described_class.perform_now(completed.id) }
        .not_to change(ApiCallLog, :count)

      expect(completed.reload.meaning).to eq(original_meaning)
    end
  end
end
