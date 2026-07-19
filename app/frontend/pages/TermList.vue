<!--
  ============================================================================
  TermList.vue — トップ（/）で本文側に出る案内

  【一覧はどこへ行ったのか】
    以前はこのファイルが登録フォーム・検索・一覧・解説の全部を持っていた。
    サイドバー構成にしたことで、それらは TermSidebar.vue へ移した。

    一覧を常設パネルに置いた結果、本文側は「選ばれた1件を読む場所」に
    専念できるようになった。まだ何も選ばれていない状態が、この画面。

  【空白のままにしない理由】
    何も出さないと「壊れているのか、まだ何も無いのか」が区別できない。
    次に何をすればいいかを書く。
  ============================================================================
-->
<script setup>
import { useTermsStore } from '../stores/terms'

const store = useTermsStore()
</script>

<template>
  <div class="empty-state">
    <!-- まだ1件も登録していない人と、既に持っている人とでは
         次にやるべきことが違うので、案内を出し分ける。 -->
    <template v-if="store.terms.length === 0 && !store.loading">
      <p style="font-size: var(--text-lg); margin: 0">まだ単語がありません</p>
      <p class="muted" style="margin: 0">
        左の欄に気になった単語を入れると、AIが意味・具体例・使い方を書きます。
      </p>
    </template>

    <template v-else>
      <p style="font-size: var(--text-lg); margin: 0">単語を選んでください</p>
      <p class="muted" style="margin: 0">
        左の一覧から選ぶと、ここに解説が出ます。
      </p>
    </template>
  </div>
</template>
