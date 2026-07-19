<!--
  ============================================================================
  TermRow.vue — サイドバーの一覧に並ぶ、単語1件分の行

  【TermCard と分けた理由】
    TermCard は解説全文・例・操作ボタンまで出す「読む」ための表示。
    こちらは「探す」ための表示で、目的が違う。

    1つのコンポーネントに detailed / compact の分岐を足していくと、
    条件が絡み合って、片方を直すともう片方が壊れるようになる。
    目的が違う表示は、分けた方が結果的に安く済む。
  ============================================================================
-->
<script setup>
import { computed } from 'vue'

const props = defineProps({
  term: { type: Object, required: true },
})

// ----------------------------------------------------------------------------
// 登録日を「7/19」の形にする
// ----------------------------------------------------------------------------
// 【なぜ年を出さないか】
//   一覧では「いつ頃調べたか」が分かれば十分で、年まで出すと横幅を食う。
//   ただし年をまたぐと 1/5 が去年か今年か分からなくなるので、
//   今年でなければ「25/1/5」のように年を足す。
const dateLabel = computed(() => {
  const d = new Date(props.term.created_at)

  // 【Invalid Date のガード】
  //   created_at が想定外の形式だと画面に "NaN/NaN" と出る。
  //   日付は補助情報なので、表示を諦めた方が害が少ない。
  if (Number.isNaN(d.getTime())) return ''

  const md = `${d.getMonth() + 1}/${d.getDate()}`
  return d.getFullYear() === new Date().getFullYear()
    ? md
    : `${String(d.getFullYear()).slice(2)}/${md}`
})

const statusLabel = {
  pending: '生成中…',
  completed: '',
  failed: '失敗',
}
</script>

<template>
  <!--
    【RouterLink を使う理由】
      div に @click を付けても見た目は同じだが、
      ・ブラウザの「戻る」が効かない
      ・新しいタブで開けない
      ・キーボードで辿れない
      ・スクリーンリーダーがリンクとして読まない
      が全て失われる。リンクとして振る舞うものは <a> であるべき。

    【active クラス】
      マスター・ディテール型では「今どれを読んでいるか」が
      一覧側で分からないと、行き来したときに迷子になる。
      RouterLink は現在のURLと一致すると router-link-active が付くが、
      クラス名が長く意図も伝わりにくいので、自前で判定して付けている。
  -->
  <RouterLink
    class="term-row"
    :class="{ active: $route.params.id === String(term.id) }"
    :to="`/terms/${term.id}`"
  >
    <div class="term-row-head">
      <span class="term-row-word">{{ term.word }}</span>

      <!-- 完了時は何も出さない。
           全件に「完了」が並ぶと、異常な行を見つけにくくなる。 -->
      <span v-if="term.status !== 'completed'" class="status" :class="term.status">
        {{ statusLabel[term.status] }}
      </span>

      <span class="term-row-date">{{ dateLabel }}</span>
    </div>

    <!--
      【{{ }} を使い v-html を使わない】
        term.meaning はAIが生成した文字列で、信用できない入力として扱う。
        v-html だと <script> が混ざっていた場合に実行される（XSS）。
        {{ }} はVueが自動でエスケープするので、タグは文字として表示される。
        詳しい理由は TermCard.vue の同じ箇所のコメントを参照。

      【はみ出しをCSSで切る理由】
        JavaScriptで meaning.slice(0, 30) のように切ると、
        画面幅に関係なく固定文字数になり、狭い画面では溢れ、
        広い画面では余白が余る。
        CSS（term-row-excerpt）なら幅に応じて切れる。
    -->
    <p v-if="term.status === 'pending'" class="term-row-excerpt">
      AIが解説を生成しています…
    </p>
    <p v-else-if="term.status === 'failed'" class="term-row-excerpt">
      生成に失敗しました
    </p>
    <p v-else class="term-row-excerpt">{{ term.meaning }}</p>
  </RouterLink>
</template>
