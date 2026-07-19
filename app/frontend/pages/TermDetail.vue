<!--
  ============================================================================
  TermDetail.vue — 単語1件の詳細画面

  一覧との違いは「使い方」まで全文表示し、操作ボタンを出すこと。
  ============================================================================
-->
<script setup>
import { onMounted, ref, watch, computed } from 'vue'
import { useRoute } from 'vue-router'
import { api } from '../lib/api'
import { useTermsStore } from '../stores/terms'
import TermCard from '../components/TermCard.vue'

const route = useRoute()
const store = useTermsStore()

const term = ref(null)
const error = ref('')
const loading = ref(true)

async function load() {
  loading.value = true
  error.value = ''
  try {
    const data = await api.getTerm(route.params.id)
    term.value = data.term
  } catch (e) {
    // 他人の単語や存在しないIDは404が返る。
    error.value = e.status === 404 ? '単語が見つかりません' : e.message
  } finally {
    loading.value = false
  }
}

onMounted(load)

// 【route.params.id の変化を監視する理由】
//   /terms/1 から /terms/2 へ移動しても、
//   同じコンポーネントが再利用されるため onMounted は呼ばれない。
//   URLの変化を見て読み直す必要がある。
//   これを忘れると「別の単語を開いたのに前の内容が出る」となる。
watch(() => route.params.id, load)

// --------------------------------------------------------------------------
// ストア側の更新を詳細画面にも反映する
// --------------------------------------------------------------------------
// 【なぜ必要か】
//   詳細画面を開いたまま生成が完了した場合、
//   WebSocketの更新はストアに届くが、
//   この画面が持っている term はAPIで取得した別の実体なので変わらない。
//
//   ストアの中に同じIDがあれば、そちらを優先して表示する。
const displayed = computed(() => {
  const fromStore = store.terms.find((t) => t.id === Number(route.params.id))
  return fromStore || term.value
})
</script>

<template>
  <!-- 【スマホでだけ出す理由】
       広い画面では左に一覧が常に見えているので、
       「一覧に戻る」は押す意味が無い上に、
       毎回同じ位置を占有して本文の開始位置を下げる。

       スマホでは一覧と詳細が排他表示になるため、戻る導線が要る。
       表示の出し分けは CSS（.back-link）で行っている。

       【RouterLink とは】<a> の代わり。
       クリックしてもページ全体を再読み込みせず、
       ブラウザ内で画面だけ切り替える。 -->
  <p class="back-link">
    <RouterLink to="/">← 一覧に戻る</RouterLink>
  </p>

  <p v-if="loading" class="muted">読み込み中…</p>
  <p v-else-if="error" class="error-box">{{ error }}</p>

  <TermCard v-else-if="displayed" :term="displayed" detailed />
</template>
