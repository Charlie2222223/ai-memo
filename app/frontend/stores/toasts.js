// ============================================================================
// toasts.js — 画面右下に一時的に出る通知
//
// 【なぜ必要になったか】
//   AI生成は非同期で、完了するのは登録から10秒ほど後。
//   サイドバー＋本文の構成にしたことで、別の単語を読んでいる最中に
//   生成が終わるケースが普通に起きるようになった。
//
//   一覧の行は「生成中…」から解説に変わるが、
//   本文を読んでいる人の視線はそこに無いので気付けない。
//   「終わったよ」とだけ伝えるのがこの仕組みの役割。
//
// 【alert() を使わない理由】
//   alert は操作を止めてしまう。
//   ユーザーが何もしていないのに割り込んで止めるのは、
//   通知としてやり過ぎ。読んでいる作業を邪魔しない形にする。
//
// 【なぜストアに分けたか】
//   通知を出したい場所（WebSocketの受信点、フォルダの自動分類など）と、
//   表示する場所（画面の右下）が離れているため。
//   間にストアを挟めば、出す側は表示方法を知らなくて済む。
// ============================================================================
import { defineStore } from 'pinia'
import { ref } from 'vue'

// 通知を消すまでの時間。
// 【4秒の根拠】短い日本語1文を読むのに2〜3秒。
//   それより短いと読み切れず、長いと視界に残って邪魔になる。
const DEFAULT_DURATION = 4000

export const useToastsStore = defineStore('toasts', () => {
  const toasts = ref([])

  // 【idを連番で振る理由】
  //   Vueがリストの各要素を識別するための :key に使う。
  //   本文が同じ通知が2回出たとき、内容をkeyにすると
  //   同一の要素と見なされて2つ目が表示されない。
  let nextId = 1

  function show(message, duration = DEFAULT_DURATION) {
    const id = nextId++
    toasts.value.push({ id, message })

    // 【setTimeout の戻り値を保持していない理由】
    //   途中で取り消す必要が無いため。
    //   もし手動で閉じる機能を足すなら、ここでIDを保持して
    //   clearTimeout できるようにする。
    setTimeout(() => dismiss(id), duration)
    return id
  }

  function dismiss(id) {
    // 【filter で新しい配列を作る理由】
    //   splice で直接書き換えるより、配列そのものを入れ替える方が
    //   Vueの変更検知が確実に働く。terms.js と同じ方針。
    toasts.value = toasts.value.filter((t) => t.id !== id)
  }

  return { toasts, show, dismiss }
})
