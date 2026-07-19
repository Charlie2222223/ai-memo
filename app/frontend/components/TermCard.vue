<!--
  ============================================================================
  TermCard.vue — 単語1件を表示するカード

  【コンポーネントに切り出す理由】
    一覧と詳細で同じ見た目を使いたい。
    共通化しておけば、表示の修正が1箇所で済む。
  ============================================================================
-->
<script setup>
import { useRouter } from 'vue-router'
import { useTermsStore } from '../stores/terms'

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
const router = useRouter()

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
      <h3 class="grow">
        <!-- 詳細画面では見出しをリンクにしない（既にそのページにいるため） -->
        <RouterLink v-if="!detailed" :to="`/terms/${term.id}`">{{ term.word }}</RouterLink>
        <span v-else>{{ term.word }}</span>
      </h3>

      <span v-if="term.status !== 'completed'" class="status" :class="term.status">
        {{ statusLabel[term.status] }}
      </span>
    </div>

    <p v-if="term.context" class="muted" style="margin:0 0 0.5rem">
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
      <p class="error-box" style="margin-bottom:0.6rem">
        {{ term.error_message || '生成に失敗しました' }}
      </p>
      <button @click="handleRegenerate">再生成する</button>
    </div>

    <!-- ======================================================================
         完了
         ====================================================================== -->
    <div v-else>
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
      <p style="margin:0.3rem 0">{{ term.meaning }}</p>

      <template v-if="detailed || term.examples?.length">
        <p class="muted" style="margin:0.8rem 0 0.2rem"><strong>例</strong></p>
        <ul class="examples">
          <!-- 【:key が必要な理由】
               Vueがリストの各要素を識別するための目印。
               無いと、並び替えや削除のときに
               間違った要素を再利用して表示が崩れることがある。 -->
          <li v-for="(ex, i) in term.examples" :key="i">{{ ex }}</li>
        </ul>
      </template>

      <template v-if="detailed && term.usage_note">
        <p class="muted" style="margin:0.8rem 0 0.2rem"><strong>使い方</strong></p>
        <p style="margin:0">{{ term.usage_note }}</p>
      </template>
    </div>

    <!-- ======================================================================
         タグ
         ====================================================================== -->
    <div v-if="term.tags?.length" style="margin-top:0.7rem">
      <span v-for="tag in term.tags" :key="tag.id" class="tag">{{ tag.name }}</span>
    </div>

    <!-- ======================================================================
         操作（詳細画面のみ）
         ====================================================================== -->
    <div v-if="detailed" class="row" style="margin-top:1rem">
      <button v-if="term.status === 'completed'" @click="handleRegenerate">再生成</button>
      <button class="danger" @click="handleDelete">削除</button>
    </div>
  </article>
</template>
