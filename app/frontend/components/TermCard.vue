<!--
  ============================================================================
  TermCard.vue — 単語1件を表示するカード

  【コンポーネントに切り出す理由】
    一覧と詳細で同じ見た目を使いたい。
    共通化しておけば、表示の修正が1箇所で済む。
  ============================================================================
-->
<script setup>
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { useTermsStore } from '../stores/terms'
import { useFoldersStore } from '../stores/folders'

// 【defineProps とは】親コンポーネントから受け取る値の宣言。
//   <TermCard :term="t" /> のように渡される。
//
// 【型と必須を明示する理由】
//   渡し忘れたときに、ブラウザのコンソールに警告が出る。
//   何も書かないと、undefined のまま描画されて
//   「なぜか空のカードが出る」という状態になる。
const props = defineProps({
  term: { type: Object, required: true },
  // 詳細画面では全文を、一覧では概要だけを出す。
  detailed: { type: Boolean, default: false },
})

const store = useTermsStore()
const folders = useFoldersStore()
const router = useRouter()

// 【処理中フラグを持つ理由】
//   承認は「フォルダ作成 → 所属変更 → 一覧の取り直し」で1秒弱かかる。
//   その間ボタンを押せたままだと、連打で同じフォルダを2回作ろうとして
//   2回目が重複エラーになる。押した瞬間に無効化する。
const busy = ref(false)

const statusLabel = {
  pending: '生成中…',
  completed: '',
  failed: '生成に失敗',
}

async function handleRegenerate() {
  try {
    await store.regenerateTerm(props.term.id)
  } catch (e) {
    alert(e.message)
  }
}

// ----------------------------------------------------------------------------
// AIが提案したフォルダの承認・却下
// ----------------------------------------------------------------------------
// 【承認したらフォルダ一覧も取り直す理由】
//   承認は新しいフォルダを1つ作る操作。
//   単語側だけ更新すると、サイドバーに新しいフォルダが現れず
//   「承認したのに反映されない」ように見える。
//
//   未分類の件数と提案の件数も同時に減るので、いずれにせよ取り直しが要る。
async function handleAcceptFolder() {
  busy.value = true
  try {
    await store.acceptFolder(props.term.id)
    await folders.fetchFolders()
  } catch (e) {
    alert(e.message)
  } finally {
    busy.value = false
  }
}

// 【却下でも取り直す理由】
//   フォルダは増えないが、提案の件数（サイドバーの「提案 N」）が減る。
//   これが減らないと、対応済みなのに未対応に見え続ける。
async function handleRejectFolder() {
  busy.value = true
  try {
    await store.rejectFolder(props.term.id)
    await folders.fetchFolders()
  } catch (e) {
    alert(e.message)
  } finally {
    busy.value = false
  }
}

async function handleDelete() {
  // 【確認ダイアログを出す理由】
  //   削除は取り消せない。誤タップで消えると、
  //   AI生成に使った費用も無駄になる。
  if (!confirm(`「${props.term.word}」を削除しますか？`)) return
  try {
    await store.deleteTerm(props.term.id)
    if (props.detailed) router.push('/')
  } catch (e) {
    alert(e.message)
  }
}
</script>

<template>
  <article class="card">
    <div class="row" style="justify-content: space-between; align-items: flex-start">
      <!-- 【詳細では見出しを大きくする】
           本文側は「1件を読む」場所なので、
           どの単語の話かが視線の起点になる必要がある。
           以前は単語名と本文がほぼ同じ大きさで、起点が無かった。 -->
      <h3 class="grow" :style="detailed ? 'font-size: var(--text-xl)' : ''">
        <!-- 詳細画面では見出しをリンクにしない（既にそのページにいるため） -->
        <RouterLink v-if="!detailed" :to="`/terms/${term.id}`">{{ term.word }}</RouterLink>
        <span v-else>{{ term.word }}</span>
      </h3>

      <span v-if="term.status !== 'completed'" class="status" :class="term.status">
        {{ statusLabel[term.status] }}
      </span>
    </div>

    <!-- ======================================================================
         読み方と正式名称
         ======================================================================
         【見出しのすぐ下に置く理由】
           「この単語は何と読むか」は、意味を読む前に知りたい情報。
           解説の後ろに置くと、読み終わってから戻ることになる。

         【どちらか片方しか無い場合がある】
           「プリフライト」… 読み方は不要、英語表記はある
           「設計」        … 読み方は不要、略語でもない
           両方を1つの行にまとめ、あるものだけを出す。 -->
    <p v-if="term.reading || term.full_form" class="term-reading">
      <span v-if="term.reading">{{ term.reading }}</span>
      <!-- 【区切りを条件付きにする理由】
           片方しか無いときに「/」だけが浮くのを防ぐ。 -->
      <span v-if="term.reading && term.full_form" class="term-reading-sep">/</span>
      <span v-if="term.full_form">{{ term.full_form }}</span>
    </p>

    <p v-if="term.context" class="muted" style="margin: 0 0 var(--space-2)">
      文脈: {{ term.context }}
    </p>

    <!-- ======================================================================
         生成中
         ====================================================================== -->
    <p v-if="term.status === 'pending'" class="muted">
      AIが解説を生成しています。完了すると自動で表示されます（リロード不要）。
    </p>

    <!-- ======================================================================
         失敗
         ====================================================================== -->
    <div v-else-if="term.status === 'failed'">
      <p class="error-box" style="margin-bottom: var(--space-3)">
        {{ term.error_message || '生成に失敗しました' }}
      </p>
      <button @click="handleRegenerate">再生成する</button>
    </div>

    <!-- ======================================================================
         完了
         ====================================================================== -->
    <!--
      【Transition で包む理由】
        「生成中…」から解説への切り替えは、自分が操作していないのに起きる。
        瞬間的に入れ替わると変化を見落とすので、150ms かけて現れさせる。
        アニメーションを付ける基準（見落とすと困る変化）に合致する。
    -->
    <Transition name="reveal">
      <div v-if="term.status === 'completed'">
      <!--
        【{{ }} を使い、v-html を使わない — 極めて重要】

        {{ }} はVueが自動でHTMLエスケープする。
        つまり <script> という文字列が来ても、
        タグとしてではなく「そういう文字列」として表示される。

        v-html を使うと、渡された文字列をHTMLとして解釈してしまう。

        このアプリではAIの出力をそのまま画面に出している。
        もしAIの応答に <script> が混ざっていて v-html で描画すると、
        そのスクリプトがあなたのブラウザで実行される（XSS）。

        「AIの出力は信用できない入力である」と扱うのが正しい。
        ユーザーの入力を信用しないのと全く同じ理由。

        セッションCookieを httpOnly にしてあるので、
        仮にXSSが起きてもログイン情報は盗まれないが、
        画面の改ざんや別サイトへの誘導は可能になる。
        防御は多層で持つ。
      -->
        <p style="margin: var(--space-1) 0 0">{{ term.meaning }}</p>

        <template v-if="detailed || term.examples?.length">
          <!-- 【section-label を使う理由】
               「例」「使い方」は内容ではなく見出し。
               本文と同じ濃さで置くと、どこからが中身か分からない。
               小さく・色を落とし・字間を空けてラベルだと伝える。 -->
          <p class="section-label">例</p>
          <ul class="examples">
            <!-- 【:key が必要な理由】
                 Vueがリストの各要素を識別するための目印。
                 無いと、並び替えや削除のときに
                 間違った要素を再利用して表示が崩れることがある。 -->
            <li v-for="(ex, i) in term.examples" :key="i">{{ ex }}</li>
          </ul>
        </template>

        <template v-if="detailed && term.usage_note">
          <p class="section-label">使い方</p>
          <p style="margin:0">{{ term.usage_note }}</p>
        </template>
      </div>
    </Transition>

    <!-- ======================================================================
         タグ
         ======================================================================
         【tag-list で包む理由】
           以前は各タグの margin で間隔を取っていたため、
           折り返したときに間隔が崩れ「HTTPAPI設計設計」と
           一続きの文字列に見えていた。
           親に gap を置けば縦横どちらも均等になる。 -->
    <div v-if="term.tags?.length" class="tag-list" style="margin-top: var(--space-4)">
      <!-- 【フォルダをタグと並べて出す理由】
           どちらも「この単語がどこに属するか」の情報なので、
           離れた場所にあると関係が読み取れない。
           フォルダは1つだけなので先頭に置き、色で区別する。 -->
      <span v-if="term.folder_name" class="tag" style="border-color: var(--accent); color: var(--accent)">
        {{ term.folder_name }}
      </span>
      <span v-for="tag in term.tags" :key="tag.id" class="tag">{{ tag.name }}</span>
    </div>

    <!-- ======================================================================
         AIの分類提案（未承認のときだけ出る）
         ======================================================================
         【詳細画面だけに出す理由】
           承認は「新しいフォルダを作る」という結果を伴う判断。
           一覧の行に出すと、探している最中に判断を迫られて
           本来の目的（探す）が中断される。
           開いて読んでいるときなら、その単語について考えている最中なので
           分類の判断もしやすい。 -->
    <div v-if="detailed && term.suggested_folder_name" class="suggestion-box">
      <span class="grow">
        AIの提案: <strong>{{ term.suggested_folder_name }}</strong>
      </span>

      <button class="primary" :disabled="busy" @click="handleAcceptFolder">
        このフォルダを作る
      </button>
      <button class="ghost" :disabled="busy" @click="handleRejectFolder">
        いらない
      </button>
    </div>

    <!-- ======================================================================
         出自と派生（詳細画面のみ）
         ======================================================================
         【両方向を出す理由】
           子だけだと、親を開いたときに何を掘り下げたか分からない。
           親だけだと、子から読んでいた場所に戻れない。
           片方向では半分しか使えない。 -->
    <div v-if="detailed && (term.source_term_id || term.derived_terms?.length)" class="lineage">
      <p v-if="term.source_term_id" style="margin: 0 0 var(--space-2)">
        <span class="lineage-label">この語を見つけた場所: </span>
        <RouterLink :to="`/terms/${term.source_term_id}`">{{ term.source_term_word }}</RouterLink>
      </p>

      <div v-if="term.derived_terms?.length">
        <span class="lineage-label">ここから調べた語: </span>
        <!-- 【区切りを入れる理由】
             リンクが隣接すると、どこまでが1つの語か分からなくなる。
             タグと同じく gap で間隔を取る。 -->
        <span class="tag-list" style="display: inline-flex; vertical-align: middle">
          <RouterLink
            v-for="d in term.derived_terms"
            :key="d.id"
            :to="`/terms/${d.id}`"
          >{{ d.word }}</RouterLink>
        </span>
      </div>
    </div>

    <!-- ======================================================================
         操作（詳細画面のみ）
         ====================================================================== -->
    <div v-if="detailed" class="row" style="margin-top: var(--space-6)">
      <button v-if="term.status === 'completed'" @click="handleRegenerate">再生成</button>
      <button class="danger" @click="handleDelete">削除</button>
    </div>
  </article>
</template>
