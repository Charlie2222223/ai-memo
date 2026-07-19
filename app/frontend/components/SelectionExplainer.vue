<!--
  ============================================================================
  SelectionExplainer.vue — 解説を読んでいて分からない語を、その場で調べる

  【この機能の位置づけ】
    このアプリの動機は「調べる手間を消す」こと。
    ところが解説の中に知らない語が出てくると、結局そこで手が止まり、
    別の場所で調べ直すことになっていた。動機の穴を塞ぐための機能。

  ----------------------------------------------------------------------------
  【選択が消える問題】← この機能で最初に踏む落とし穴
  ----------------------------------------------------------------------------
    テキストを選択した状態で画面上の何かをクリックすると、
    多くのブラウザで選択が解除される。
    「ボタンを押した瞬間に選択が消えて、何も取れない」が普通に起きる。

    対策は2つ:
      ① 選択が確定した時点（selectionchange）で文字列を控えておく
      ② ボタンの mousedown を抑止して、選択解除そのものを起こさせない

    どちらか片方でも動くが、両方やっておく。
    ①だけだと、押した瞬間にバーが消えて押せないことがある。

  ----------------------------------------------------------------------------
  【なぜ画面下部の固定バーなのか】
  ----------------------------------------------------------------------------
    選択箇所の近くに浮かせる方が見た目は洗練される。
    しかしスマホでは、選択した瞬間にOSの標準メニュー
    （コピー／検索／共有）が選択箇所のすぐ近くに出るため、
    同じ場所に自前のボタンを置くと重なるか隠れる。

    下部固定なら場所が競合せず、PC・スマホで挙動が1つで済み、
    スマホでは親指が届く位置に来る。
  ============================================================================
-->
<script setup>
import { ref, onMounted, onUnmounted, computed, watch } from 'vue'
import { useRouter } from 'vue-router'
import { useTermsStore } from '../stores/terms'
import { useFoldersStore } from '../stores/folders'
import { api } from '../lib/api'

const props = defineProps({
  // 今読んでいる単語。出自（source_term）として記録する。
  sourceTerm: { type: Object, required: true },
})

const store = useTermsStore()
const folders = useFoldersStore()
const router = useRouter()

// 選択された文字列。selectionchange の時点で控える。
const selected = ref('')
// 選択箇所を含む段落。AIに渡す文脈になる。
const paragraph = ref('')

// 確認欄を開いているか。
const confirming = ref(false)
const word = ref('')
const submitting = ref(false)
const errorMessage = ref('')

// 同じ語が既に登録済みだった場合、その単語。
const existing = ref(null)
const checking = ref(false)

// 【30文字を上限にする理由】
//   これを超える選択は「解説してほしい語」ではなく、文の選択であることが
//   ほとんど。単語カラムの上限は100文字だが、それに合わせると
//   文がそのまま単語帳に並ぶ。実用的な語の長さで切る。
const MAX_SELECTION = 30

const canExplain = computed(
  () => selected.value.length > 0 && selected.value.length <= MAX_SELECTION
)

// ----------------------------------------------------------------------------
// 選択を監視する
// ----------------------------------------------------------------------------
function handleSelectionChange() {
  // 確認欄を開いている間は選択を追わない。
  // 【なぜ】確認欄の入力を触ると選択が変わり、
  //   入力中に対象の語が書き換わってしまう。
  if (confirming.value) return

  const sel = window.getSelection()
  const text = sel ? sel.toString().trim() : ''

  if (!text) {
    selected.value = ''
    return
  }

  // 【操作要素の中を除外する理由】
  //   「再生成」「削除」ボタンや「← 一覧に戻る」の上をドラッグで
  //   通過したとき、`削除` が登録候補になるのは明らかに事故。
  if (isInsideInteractive(sel)) {
    selected.value = ''
    return
  }

  selected.value = text
  paragraph.value = enclosingParagraph(sel)
}

// 選択の起点が button / a / input の中にあるかを見る。
function isInsideInteractive(sel) {
  const node = sel.anchorNode
  if (!node) return false

  const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement
  return Boolean(element?.closest('button, a, input, textarea, select'))
}

// 選択箇所を含む段落のテキストを取り出す。
// 【なぜ段落まで渡すのか】
//   同じ語でも文脈で意味が変わる（セッション、トークンなど）。
//   その文の中でどう使われていたかが分かれば、AIは適切な方を選べる。
function enclosingParagraph(sel) {
  const node = sel.anchorNode
  if (!node) return ''

  const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement
  // p / li が段落の単位。見つからなければ選択文字列だけで諦める。
  const block = element?.closest('p, li')
  return (block?.textContent || sel.toString()).trim()
}

onMounted(() => document.addEventListener('selectionchange', handleSelectionChange))
onUnmounted(() => document.removeEventListener('selectionchange', handleSelectionChange))

// ----------------------------------------------------------------------------
// 確認欄を開く
// ----------------------------------------------------------------------------
async function openConfirm() {
  word.value = selected.value
  errorMessage.value = ''
  existing.value = null
  confirming.value = true

  await checkExisting()
}

// 【既に登録済みかを検索APIで調べる理由】
//   単語はユーザー内で一意なので、既にあると登録は422で失敗する。
//   しかし利用者の期待は「エラー」ではなく「もうあるよ、これ」。
//
//   一覧ストアで判定できないのは、絞り込み中は全件を持っていないため。
//   サーバーに聞くのが確実。
async function checkExisting() {
  const target = word.value.trim()
  if (!target) return

  checking.value = true
  try {
    const data = await api.listTerms({ q: target })
    // 検索は部分一致なので、完全一致だけを既存とみなす。
    existing.value = data.terms.find((t) => t.word === target) || null
  } catch {
    // 判定に失敗しても登録自体は試せる。ここで止めない。
    existing.value = null
  } finally {
    checking.value = false
  }
}

// ----------------------------------------------------------------------------
// 語を書き換えたら、既存判定を捨てる
// ----------------------------------------------------------------------------
// 【なぜ必要か】← 検証中に踏んだ不具合
//   判定は blur（入力欄から離れたとき）でしか走らない。
//   そのため「Cookie」で判定した後に「プリフライト」へ打ち替えても、
//   画面には Cookie の「既に登録されています／開く」が残り続け、
//   登録ボタンが出てこない。押せないまま固まったように見える。
//
//   打ち替えた瞬間に判定を捨てれば、少なくとも古い結果は出なくなる。
//   新しい判定は blur で走る。
watch(word, () => {
  existing.value = null
})

function closeConfirm() {
  confirming.value = false
  selected.value = ''
  existing.value = null
  window.getSelection()?.removeAllRanges()
}

function openExisting() {
  const id = existing.value.id
  closeConfirm()
  router.push(`/terms/${id}`)
}

// ----------------------------------------------------------------------------
// 登録する
// ----------------------------------------------------------------------------
async function handleSubmit() {
  const target = word.value.trim()
  if (!target || submitting.value) return

  errorMessage.value = ''
  submitting.value = true
  try {
    const created = await store.createTerm(target, buildContext(), props.sourceTerm.id)
    closeConfirm()
    // 【登録した単語へ移動する理由】
    //   生成が終わるまで10秒ほどかかる。
    //   その単語の画面にいれば、完了した瞬間に本文が現れるのが見える。
    //   元の解説に留まると、いつ終わったか分からない
    //   （トーストは出るが、結果を読むには結局移動が要る）。
    router.push(`/terms/${created.id}`)
    folders.fetchFolders()
  } catch (e) {
    errorMessage.value = e.message
  } finally {
    submitting.value = false
  }
}

// AIに渡す文脈を組み立てる。
// 【500文字で切る理由】context カラムの上限。
//   超えると検証で落ち、登録そのものが失敗する。
function buildContext() {
  const head = `「${props.sourceTerm.word}」の解説内で見た。`
  const body = paragraph.value ? `該当箇所:\n${paragraph.value}` : ''
  return `${head}\n${body}`.slice(0, 500)
}
</script>

<template>
  <!-- ======================================================================
       選択中に出る下部バー
       ====================================================================== -->
  <Transition name="selection-bar">
    <div v-if="canExplain && !confirming" class="selection-bar">
      <!--
        【@mousedown.prevent が必須】
          これが無いと、押した瞬間に選択が解除されてバーが消え、
          click まで到達しない。押せないボタンになる。
      -->
      <button class="primary grow" @mousedown.prevent @click="openConfirm">
        「{{ selected }}」を解説する
      </button>
      <button class="ghost" @mousedown.prevent @click="selected = ''">✕</button>
    </div>
  </Transition>

  <!-- ======================================================================
       確認欄
       ======================================================================
       【一段挟む理由】
         選択は事故が起きやすい操作（スクロール中の指の滑り、
         ダブルタップでの単語選択）。1タップ＝3.4円の課金かつ
         一覧に増えるので、そのまま登録すると事故が費用になる。

         またドラッグ選択には助詞や括弧が混ざる（「プリフライト)」など）。
         ここで削れるようにしておく。 -->
  <div v-if="confirming" class="selection-confirm">
    <p class="section-label" style="margin-top: 0">この語を解説する</p>

    <p v-if="errorMessage" class="error-box">{{ errorMessage }}</p>

    <form @submit.prevent="handleSubmit">
      <input
        v-model="word"
        aria-label="解説する語"
        autofocus
        @blur="checkExisting"
      />

      <!-- 既に登録済みなら、作らずにそちらへ送る。 -->
      <p v-if="checking" class="muted" style="margin: var(--space-2) 0 0">確認中…</p>

      <div v-else-if="existing" class="row" style="margin-top: var(--space-3)">
        <span class="muted grow">この語は既に登録されています</span>
        <button type="button" class="primary" @click="openExisting">開く</button>
        <button type="button" class="ghost" @click="closeConfirm">閉じる</button>
      </div>

      <div v-else class="row" style="margin-top: var(--space-3)">
        <span class="muted grow">
          「{{ props.sourceTerm.word }}」から調べたものとして記録します
        </span>
        <button type="submit" class="primary" :disabled="submitting">
          {{ submitting ? '登録中…' : 'AIに解説させる' }}
        </button>
        <button type="button" class="ghost" @click="closeConfirm">やめる</button>
      </div>
    </form>
  </div>
</template>
