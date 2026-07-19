// ============================================================================
// folders.js — フォルダの一覧と操作を保持するストア
//
// 【terms.js と分けた理由】
//   単語とフォルダは更新のきっかけが違う。
//     単語   … WebSocketで随時届く
//     フォルダ … 利用者が操作したときと、提案を承認したときだけ変わる
//
//   1つのストアに混ぜると、単語が1件更新されるたびに
//   フォルダ一覧も再描画されることになり、
//   「なぜここが光ったのか」が追えなくなる。
//
// 【件数をサーバーから受け取る理由】
//   画面側で terms を数えると、絞り込み中は正しい数にならない
//   （絞り込んだ結果しか手元に無いため）。
//   サーバーが全体を数えて返す。
// ============================================================================
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { api } from '../lib/api'

export const useFoldersStore = defineStore('folders', () => {
  const folders = ref([])

  // 未分類（どのフォルダにも入っていない単語）の件数。
  const unfiledCount = ref(0)

  // AIの提案が付いたまま、承認も却下もしていない単語の数。
  // 0 より大きいときだけ画面に「提案があります」を出す。
  const pendingSuggestionCount = ref(0)

  // 現在選択中のフォルダ。
  // 【3つの状態を持つ】
  //   ''         … すべて（絞り込みなし）
  //   'unfiled'  … 未分類だけ
  //   数値のID    … そのフォルダだけ
  //
  // 【なぜ null ではなく空文字を「すべて」にするのか】
  //   URLSearchParams に載せるとき、null は "null" という文字列になる。
  //   空文字なら api.js 側のフィルタ（空の条件は送らない）で
  //   自動的に除外され、余計な分岐が要らない。
  const selectedFolderId = ref('')

  async function fetchFolders() {
    try {
      const data = await api.listFolders()
      folders.value = data.folders
      unfiledCount.value = data.unfiled_count
      pendingSuggestionCount.value = data.pending_suggestion_count
    } catch {
      // 【失敗しても画面全体を止めない】
      //   フォルダは絞り込みの補助機能。
      //   取れなくても単語一覧は見られるので、エラー表示はしない。
      //   terms.js の fetchTags と同じ方針。
      folders.value = []
    }
  }

  async function createFolder(name) {
    await api.createFolder(name)
    // 【作成後に取り直す理由】
    //   件数（terms_count）や並び順はサーバーが決めている。
    //   手元で配列に push すると、名前順の位置がずれる。
    await fetchFolders()
  }

  async function renameFolder(id, name) {
    await api.renameFolder(id, name)
    await fetchFolders()
  }

  async function deleteFolder(id) {
    await api.deleteFolder(id)

    // 【選択中のフォルダを消した場合の後始末】
    //   選択状態が「存在しないフォルダ」を指したままだと、
    //   一覧が常に0件になり、原因が分からず固まったように見える。
    if (selectedFolderId.value === id) selectedFolderId.value = ''

    await fetchFolders()
  }

  return {
    folders,
    unfiledCount,
    pendingSuggestionCount,
    selectedFolderId,
    fetchFolders,
    createFolder,
    renameFolder,
    deleteFolder,
  }
})
