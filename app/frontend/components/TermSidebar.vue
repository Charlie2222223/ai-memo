<!--
  ============================================================================
  TermSidebar.vue — 左側の常設パネル（探す場所）

  【役割の分担】
    サイドバー … 追加する・探す・選ぶ
    本文       … 選んだ1件を読む

  【なぜ一覧を本文から追い出したのか】
    以前は登録フォームと一覧と解説が全部1画面に縦積みだった。
    解説は1件で画面の大半を占めるため、単語が増えるほど
    「探す」ためのスクロール量が増え続ける構造になっていた。

    探す場所を固定し、読む場所だけを差し替えれば、
    何件になっても探す手間は変わらない。
  ============================================================================
-->
<script setup>
import { onMounted, ref, watch } from 'vue'
import { useTermsStore } from '../stores/terms'
import { useSessionStore } from '../stores/session'
import { useFoldersStore } from '../stores/folders'
import TermRow from './TermRow.vue'
import FolderNav from './FolderNav.vue'

const store = useTermsStore()
const session = useSessionStore()
const folders = useFoldersStore()

const newWord = ref('')
const newContext = ref('')
const submitting = ref(false)
const formError = ref('')

// 【文脈欄を最初は隠す理由】
//   任意項目であり、実際にはほとんどの場合そのまま登録する。
//   常に出しておくとサイドバーの縦を食い、一覧が下へ押し出される。
//   「必要な人だけ開く」形にすれば、普段の入力は1行で済む。
const showContext = ref(false)

onMounted(() => {
  store.fetchTerms(folders.selectedFolderId)
  folders.fetchFolders()
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
watch(() => store.query, () => {
  clearTimeout(timer)
  timer = setTimeout(() => store.fetchTerms(folders.selectedFolderId), 300)
})

// 【フォルダの切り替えにデバウンスを掛けない理由】
//   検索は1文字ごとに値が変わるが、フォルダはクリック1回で1度だけ変わる。
//   遅延させると「押したのに反応しない」という体感になるだけで、
//   抑制できるリクエストが無い。
watch(() => folders.selectedFolderId, (id) => {
  store.fetchTerms(id)
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
    showContext.value = false
  } catch (e) {
    formError.value = e.message
  } finally {
    submitting.value = false
  }
}

async function handleLogout() {
  await session.logout()
}
</script>

<template>
  <!-- ======================================================================
       ブランドと登録フォーム
       ====================================================================== -->
  <div class="stack">
    <h1 style="margin:0; font-size: var(--text-lg)">単語メモ</h1>

    <form class="stack" @submit.prevent="handleCreate">
      <p v-if="formError" class="error-box" style="margin:0">{{ formError }}</p>

      <label>
        <input
          v-model="newWord"
          placeholder="調べたい単語"
          required
          aria-label="調べたい単語"
        />
      </label>

      <!-- 【任意項目は開いたときだけ出す】
           書くと解説の精度は上がるが、無くても成立する。
           常設すると毎回「書かなくていいのか」と judgement を強いる。 -->
      <label v-if="showContext">
        <input
          v-model="newContext"
          placeholder="どこで見たか（任意）"
          aria-label="どこで見たか"
        />
      </label>

      <div class="row">
        <button class="primary grow" type="submit" :disabled="submitting">
          {{ submitting ? '登録中…' : 'AIに解説させる' }}
        </button>

        <button
          v-if="!showContext"
          class="ghost"
          type="button"
          @click="showContext = true"
        >＋文脈</button>
      </div>
    </form>
  </div>

  <!-- ======================================================================
       検索
       ======================================================================
       【タグの絞り込み帯を置いていない理由】
         かつてここに「すべて / API設計2 / Git1 / …」という帯があった。
         しかしタグは1単語あたり3個ほど付くため、単語が30件になると
         ユニークなタグは40〜50個に膨らむ。
         帯が何行にもわたって一覧を下へ押し下げ、
         ナビゲーションとして機能しなくなる。

         「絞り込む」用途はフォルダ（1単語1つ・少数で安定）が担い、
         タグは検索と、詳細画面での分類の手掛かりとして残す。
         → フォルダはフェーズ2で実装する。 -->
  <input
    v-model="store.query"
    placeholder="検索"
    type="search"
    aria-label="単語・意味・文脈から検索"
  />

  <!-- ======================================================================
       フォルダによる絞り込み
       ====================================================================== -->
  <FolderNav />

  <!-- ======================================================================
       単語一覧
       ====================================================================== -->
  <!-- 【grow を付ける理由】
       一覧を伸ばして、ログアウトを常に最下部へ押し下げる。
       件数が少ないときにログアウトが一覧の直下に来ると、
       単語を消そうとして誤って押す事故が起きる。 -->
  <div class="grow">
    <p v-if="store.error" class="error-box">{{ store.error }}</p>
    <p v-if="store.loading" class="muted">読み込み中…</p>

    <!-- 【0件の理由で文言を変える】
         検索の結果0件なのか、フォルダが空なのか、そもそも1件も無いのかで
         次にやるべきことが違う。同じ文言だと
         「検索語を消す」のか「絞り込みを外す」のか「登録する」のか分からない。 -->
    <p v-else-if="store.terms.length === 0" class="muted">
      <template v-if="store.query">「{{ store.query }}」に一致する単語がありません</template>
      <template v-else-if="folders.selectedFolderId">このフォルダは空です</template>
      <template v-else>まだ単語がありません。上の欄から登録してみてください。</template>
    </p>

    <!-- 【:key に term.id を使う理由】
         WebSocketで一部の行だけが更新されるとき、
         Vueがどの行を描き直せばよいかを id で判断する。
         key が無いと、全部を描き直したり、
         別の行の内容を誤って再利用したりする。 -->
    <div v-else class="term-list">
      <TermRow v-for="term in store.terms" :key="term.id" :term="term" />
    </div>
  </div>

  <!-- ======================================================================
       アカウント
       ====================================================================== -->
  <div class="stack" style="border-top: 1px solid var(--border); padding-top: var(--space-3)">
    <span class="muted" style="overflow-wrap:anywhere">{{ session.user?.email }}</span>
    <button @click="handleLogout">ログアウト</button>
  </div>
</template>
