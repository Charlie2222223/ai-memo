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
import SelectionExplainer from '../components/SelectionExplainer.vue'

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
  if (!fromStore) return term.value

  // --------------------------------------------------------------------------
  // 【derived_terms だけ詳細取得の側を残す理由】← ここを間違えて一度踏んだ
  //   一覧API（/api/terms）は派生語を返さない。
  //   単語50件それぞれについて派生語を引くとN+1になるため、
  //   詳細API（/api/terms/:id）でしか含めていない。
  //
  //   ストア側を丸ごと優先すると、その空の配列で上書きされ、
  //   「ここから調べた語」が永久に表示されない。
  //   WebSocketの更新は反映しつつ、派生語だけは詳細取得の値を残す。
  // --------------------------------------------------------------------------
  return { ...fromStore, derived_terms: term.value?.derived_terms ?? [] }
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

  <template v-else-if="displayed">
    <TermCard :term="displayed" detailed />

    <!-- ======================================================================
         解説の中の語を選んで調べる
         ======================================================================
         【生成が完了しているときだけ出す理由】
           生成中・失敗のときは本文が無いので、選択する対象が存在しない。
           それでもバーの仕組みを動かすと、
           「生成中…」という文字列を選んで登録できてしまう。 -->
    <SelectionExplainer v-if="displayed.status === 'completed'" :source-term="displayed" />
  </template>
</template>
