<!--
  ============================================================================
  FolderNav.vue — サイドバーのフォルダ一覧（絞り込みの軸）

  【タグの絞り込み帯を置き換えたもの】
    以前はここにタグの帯があった。しかしタグは1単語あたり3個ほど付き、
    単語30件でユニークなタグが40〜50個に膨らむ。
    帯が何行にもわたって一覧を押し下げ、探せなくなっていた。

    フォルダは1単語につき1つで、増やす判断を人間が行うため、
    件数が増えても行数がほぼ変わらない。だから軸として使える。
  ============================================================================
-->
<script setup>
import { ref } from 'vue'
import { useFoldersStore } from '../stores/folders'

const store = useFoldersStore()

// 新規フォルダの入力欄を開いているか。
// 【常設しない理由】フォルダを作る操作は稀（提案を承認する方が主）。
//   常に入力欄があると、毎回視界に入って一覧を押し下げる。
const adding = ref(false)
const newName = ref('')
const errorMessage = ref('')

async function handleCreate() {
  const name = newName.value.trim()
  if (!name) return

  errorMessage.value = ''
  try {
    await store.createFolder(name)
    newName.value = ''
    adding.value = false
  } catch (e) {
    errorMessage.value = e.message
  }
}

async function handleRename(folder) {
  // 【prompt を使っている理由】
  //   フォルダ名の変更は稀な操作で、専用のUIを作るほどの頻度が無い。
  //   まず動く形にして、煩わしくなってから作り込む方針
  //   （CLAUDE.md の「使われない機能を作らない」と同じ考え方）。
  const name = window.prompt('新しいフォルダ名', folder.name)
  if (!name || name.trim() === folder.name) return

  try {
    await store.renameFolder(folder.id, name.trim())
  } catch (e) {
    alert(e.message)
  }
}

async function handleDelete(folder) {
  // 【中の単語が消えないことを明記する理由】
  //   「フォルダを削除」と言われたとき、中身も消えると考えるのが自然。
  //   実際は未分類に戻るだけなので、そう伝えないと
  //   怖くて削除できない（＝整理できない）。
  const message = folder.terms_count > 0
    ? `「${folder.name}」を削除しますか？\n中の${folder.terms_count}件は削除されず、未分類に戻ります。`
    : `「${folder.name}」を削除しますか？`

  if (!window.confirm(message)) return

  try {
    await store.deleteFolder(folder.id)
  } catch (e) {
    alert(e.message)
  }
}
</script>

<template>
  <nav class="folder-nav">
    <div class="row" style="justify-content: space-between">
      <span class="section-label" style="margin: 0">フォルダ</span>
      <button class="ghost" type="button" @click="adding = !adding">
        {{ adding ? 'やめる' : '＋ 追加' }}
      </button>
    </div>

    <form v-if="adding" @submit.prevent="handleCreate" style="margin-bottom: var(--space-2)">
      <p v-if="errorMessage" class="error-box" style="margin-bottom: var(--space-2)">
        {{ errorMessage }}
      </p>
      <input v-model="newName" placeholder="フォルダ名" aria-label="新しいフォルダ名" autofocus />
    </form>

    <!-- ======================================================================
         すべて / 未分類 / 各フォルダ
         ======================================================================
         【「すべて」と「未分類」を同じ見た目で並べる理由】
           利用者にとってはどれも「絞り込みの選択肢」で、
           内部的にフォルダかどうかは関係が無い。
           見た目が違うと、選べるものだと気付きにくくなる。 -->
    <button
      class="folder-row"
      :class="{ active: store.selectedFolderId === '' }"
      @click="store.selectedFolderId = ''"
    >
      <span class="grow">すべて</span>
    </button>

    <!-- 【未分類を常に出す（0件でも隠さない）理由】
         AIの提案待ちの単語はここに溜まる。
         0件のときに消えると、行の位置が動いて押し間違いが起きる。 -->
    <button
      class="folder-row"
      :class="{ active: store.selectedFolderId === 'unfiled' }"
      @click="store.selectedFolderId = 'unfiled'"
    >
      <span class="grow">未分類</span>

      <!-- 【提案の件数を目立たせる理由】
           承認しない限り単語は未分類のままで、フォルダが育たない。
           「やることがある」と分かる印が要る。 -->
      <span v-if="store.pendingSuggestionCount > 0" class="badge">
        提案 {{ store.pendingSuggestionCount }}
      </span>
      <span class="folder-count">{{ store.unfiledCount }}</span>
    </button>

    <div
      v-for="folder in store.folders"
      :key="folder.id"
      class="folder-row-wrap"
    >
      <button
        class="folder-row grow"
        :class="{ active: store.selectedFolderId === folder.id }"
        @click="store.selectedFolderId = folder.id"
      >
        <span class="grow">{{ folder.name }}</span>
        <span class="folder-count">{{ folder.terms_count }}</span>
      </button>

      <!-- 【操作ボタンをホバー時だけ出す理由】
           名前変更と削除は稀な操作。常に出ていると、
           探すたびに視界に入って一覧のノイズになる。 -->
      <span class="folder-actions">
        <button class="ghost" type="button" title="名前を変更" @click="handleRename(folder)">✎</button>
        <button class="ghost" type="button" title="削除" @click="handleDelete(folder)">×</button>
      </span>
    </div>

    <p v-if="store.folders.length === 0" class="muted" style="margin: var(--space-2) 0 0">
      まだフォルダがありません。単語を登録するとAIが分類を提案します。
    </p>
  </nav>
</template>
