// ============================================================================
// terms.js — 単語の一覧と操作を保持するストア
//
// 【WebSocketとの連携がここで効く】
//   一覧データを1箇所に集約しているので、
//   WebSocketで届いた更新をここに適用するだけで、
//   その一覧を表示している画面すべてに反映される。
//
//   もし各画面がそれぞれ独自にデータを持っていたら、
//   全画面に更新処理を書く必要があり、書き漏らしが必ず出る。
// ============================================================================
import { defineStore } from 'pinia'
import { ref } from 'vue'
import { api } from '../lib/api'

export const useTermsStore = defineStore('terms', () => {
  const terms = ref([])
  const tags = ref([])
  const loading = ref(false)
  const error = ref(null)

  // 検索条件。画面の入力欄と双方向に結び付ける。
  const query = ref('')
  const selectedTag = ref('')

  // --------------------------------------------------------------------------
  // 一覧を取得する
  // --------------------------------------------------------------------------
  // 【folderId を引数で受け取る理由】
  //   フォルダの選択状態は folders ストアが持っている。
  //   ここから直接そちらを参照すると、2つのストアが相互に依存し、
  //   どちらが先に初期化されるかで挙動が変わる。
  //   呼び出し側（画面）が値を渡す形にすれば依存は一方向で済む。
  async function fetchTerms(folderId = '') {
    loading.value = true
    error.value = null
    try {
      const data = await api.listTerms({
        q: query.value,
        tag: selectedTag.value,
        folder_id: folderId,
      })
      terms.value = data.terms
    } catch (e) {
      error.value = e.message
    } finally {
      loading.value = false
    }
  }

  async function fetchTags() {
    try {
      const data = await api.listTags()
      tags.value = data.tags
    } catch {
      // タグの取得失敗で画面全体を止めない。
      // 【判断】タグは絞り込みの補助機能。
      //   取れなくても単語一覧は見られるので、エラー表示はしない。
      tags.value = []
    }
  }

  // --------------------------------------------------------------------------
  // 単語を登録する
  // --------------------------------------------------------------------------
  async function createTerm(word, context) {
    // 【throw し直している理由】
    //   ここでエラーを握り潰すと、画面側は成功したと思って
    //   入力欄を空にしてしまう。ユーザーは入力内容を失う。
    //   呼び出し側が判断できるよう、そのまま投げ直す。
    const data = await api.createTerm(word, context)

    // 【unshift（先頭に追加）を使う理由】
    //   一覧は新しい順なので、新規登録は先頭に来るのが自然。
    //   push（末尾に追加）だと、並び順と食い違う。
    //
    // 【この時点では status: pending】
    //   解説はまだ生成されていない。
    //   カードは「生成中…」で表示され、
    //   数秒後にWebSocket経由で中身が届く。
    terms.value.unshift(data.term)
    return data.term
  }

  async function deleteTerm(id) {
    await api.deleteTerm(id)
    // 【filter で新しい配列を作る理由】
    //   splice で元の配列を直接書き換えるより、
    //   新しい配列を代入する方がVueの変更検知が確実に働く。
    terms.value = terms.value.filter((t) => t.id !== id)
  }

  async function regenerateTerm(id) {
    const data = await api.regenerateTerm(id)
    applyUpdate(data.term)
  }

  // --------------------------------------------------------------------------
  // AIが提案したフォルダを承認する / 却下する
  // --------------------------------------------------------------------------
  // 【戻り値の term をそのまま applyUpdate に渡す理由】
  //   サーバーは操作後の単語を返してくる。
  //   手元で「suggested を消して folder を入れる」と書き換えると、
  //   サーバーの判断（既存フォルダに吸収された等）とずれる可能性がある。
  //   常にサーバーが返した状態を正とする。
  async function acceptFolder(id) {
    const data = await api.acceptFolder(id)
    applyUpdate(data.term)
    return data.term
  }

  async function rejectFolder(id) {
    const data = await api.rejectFolder(id)
    applyUpdate(data.term)
    return data.term
  }

  async function moveTerm(id, folderId) {
    const data = await api.moveTerm(id, folderId)
    applyUpdate(data.term)
    return data.term
  }

  // --------------------------------------------------------------------------
  // WebSocketで届いた更新を反映する
  // --------------------------------------------------------------------------
  // 【この関数が非同期処理の締めくくり】
  //   Sidekiqが生成完了 → Redis → Rails → WebSocket → ここ
  //   という長い経路の、最後の1歩。
  //
  //   ここで配列の中身を差し替えると、
  //   Vueが変化を検知して、該当のカードだけを描き直す。
  //   ユーザーは何も操作していないのに画面が更新される。
  function applyUpdate(updated) {
    const index = terms.value.findIndex((t) => t.id === updated.id)

    if (index >= 0) {
      // 【新しい配列を作って代入している理由】
      //   terms.value[index] = updated でも動くが、
      //   配列そのものを入れ替える方が変更検知が確実。
      const next = [...terms.value]
      next[index] = updated
      terms.value = next
    } else {
      // 一覧に無い単語の更新が届いた場合（別のタブで登録した等）。
      // 先頭に足しておく。
      terms.value.unshift(updated)
    }
  }

  return {
    terms, tags, loading, error, query, selectedTag,
    fetchTerms, fetchTags, createTerm, deleteTerm, regenerateTerm, applyUpdate,
    acceptFolder, rejectFolder, moveTerm,
  }
})
