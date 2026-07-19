<!--
  ============================================================================
  TermList.vue — 単語一覧（このアプリのメイン画面）

  ここで「登録 → 生成中 → 自動で完成」の流れが見える。
  ============================================================================
-->
<script setup>
import { onMounted, ref, watch } from 'vue'
import { useTermsStore } from '../stores/terms'
import TermCard from '../components/TermCard.vue'

const store = useTermsStore()

const newWord = ref('')
const newContext = ref('')
const submitting = ref(false)
const formError = ref('')

onMounted(() => {
  store.fetchTerms()
  store.fetchTags()
})

// ----------------------------------------------------------------------------
// 検索欄の入力を監視して、少し待ってから検索する（デバウンス）
// ----------------------------------------------------------------------------
// 【なぜ遅延させるのか】
//   1文字打つたびにAPIを呼ぶと、「冪等性」の4文字で4回リクエストが飛ぶ。
//   しかも応答が返る順序は保証されないので、
//   古い検索結果が後から届いて表示が入れ替わることがある。
//
//   入力が止まって300ミリ秒経ってから1回だけ呼ぶようにする。
//   これをデバウンスと呼び、検索欄では定番の手法。
let timer = null
watch([() => store.query, () => store.selectedTag], () => {
  clearTimeout(timer)
  timer = setTimeout(() => store.fetchTerms(), 300)
})

async function handleCreate() {
  if (!newWord.value.trim()) return

  formError.value = ''
  submitting.value = true
  try {
    await store.createTerm(newWord.value.trim(), newContext.value.trim() || null)
    // 【成功時だけ入力欄を空にする】
    //   失敗したときに消すと、打ち直しになる。
    newWord.value = ''
    newContext.value = ''
    // タグはAIが後から付けるので、少し待ってから取り直す。
    setTimeout(() => store.fetchTags(), 3000)
  } catch (e) {
    formError.value = e.message
  } finally {
    submitting.value = false
  }
}

function selectTag(name) {
  // 同じタグをもう一度押したら解除する（トグル）。
  store.selectedTag = store.selectedTag === name ? '' : name
}
</script>

<template>
  <!-- ======================================================================
       登録フォーム
       ====================================================================== -->
  <form class="card" @submit.prevent="handleCreate">
    <p v-if="formError" class="error-box">{{ formError }}</p>

    <label>
      <strong>調べたい単語</strong>
      <input v-model="newWord" placeholder="例: 冪等性" required />
    </label>

    <label style="display:block; margin-top:0.6rem">
      <span class="muted">どこで見たか（任意・書くと解説の精度が上がります）</span>
      <input v-model="newContext" placeholder="例: API設計の記事で見た" />
    </label>

    <button class="primary" type="submit" :disabled="submitting" style="margin-top:0.8rem">
      {{ submitting ? '登録中…' : '登録してAIに解説させる' }}
    </button>
  </form>

  <!-- ======================================================================
       検索とタグ絞り込み
       ====================================================================== -->
  <div style="margin: 1.2rem 0 0.8rem">
    <input v-model="store.query" placeholder="単語・意味・文脈から検索" />

    <div v-if="store.tags.length" style="margin-top:0.6rem">
      <button
        class="tag"
        :class="{ active: store.selectedTag === '' }"
        @click="store.selectedTag = ''"
      >すべて</button>

      <button
        v-for="tag in store.tags"
        :key="tag.id"
        class="tag"
        :class="{ active: store.selectedTag === tag.name }"
        @click="selectTag(tag.name)"
      >{{ tag.name }} {{ tag.terms_count }}</button>
    </div>
  </div>

  <!-- ======================================================================
       一覧
       ====================================================================== -->
  <p v-if="store.error" class="error-box">{{ store.error }}</p>
  <p v-if="store.loading" class="muted">読み込み中…</p>

  <p v-else-if="store.terms.length === 0" class="muted">
    まだ単語がありません。上のフォームから登録してみてください。
  </p>

  <!-- 【:key に term.id を使う理由】
       WebSocketで一部のカードだけが更新されるとき、
       Vueがどのカードを描き直せばよいかを id で判断する。
       key が無いと、全部を描き直したり、
       別のカードの内容を誤って再利用したりする。 -->
  <TermCard v-for="term in store.terms" :key="term.id" :term="term" />
</template>
