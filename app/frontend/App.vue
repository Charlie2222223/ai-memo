<!--
  ============================================================================
  App.vue — アプリ全体の最上位コンポーネント

  【.vue ファイルの構造】
    <script setup> … ロジック（JavaScript）
    <template>     … 見た目（HTML）
    <style>        … スタイル（CSS）※このファイルでは未使用

    3つが1ファイルにまとまるのがVueの特徴。
    「この画面に関するものは、この1ファイルを見れば全部ある」状態になる。

  【このコンポーネントの役割】
    ① ログイン状態の確認（起動時に1回）
    ② WebSocketの接続と切断の管理
    ③ ヘッダーの表示
    ④ 画面の切り替え先（RouterView）を置く
  ============================================================================
-->
<script setup>
// 【<script setup> とは】Vue 3 の簡潔な書き方。
//   ここで定義した変数や関数は、そのまま <template> から使える。
//   export する必要がない。
import { onMounted, onUnmounted, watch, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useSessionStore } from './stores/session'
import { useTermsStore } from './stores/terms'
import { subscribeToTerms } from './lib/cable'

const session = useSessionStore()
const termsStore = useTermsStore()
const router = useRouter()

// WebSocketの購読オブジェクト。切断のために保持しておく。
const subscription = ref(null)

// ----------------------------------------------------------------------------
// 起動時の処理
// ----------------------------------------------------------------------------
// 【onMounted とは】このコンポーネントが画面に表示された直後に呼ばれる。
//   「アプリが立ち上がったとき」に相当する。
onMounted(async () => {
  // セッションCookieは httpOnly でJavaScriptから読めないため、
  // サーバーに問い合わせてログイン状態を確認する。
  await session.fetchSession()

  if (session.isLoggedIn) {
    startCable()
  } else {
    router.push('/login')
  }
})

// ----------------------------------------------------------------------------
// ログイン状態の変化を監視する
// ----------------------------------------------------------------------------
// 【watch とは】指定した値が変わったときに処理を走らせる仕組み。
//
// 【なぜ必要か】ログイン／ログアウトはアプリ起動後にも起きる。
//   onMounted は起動時の1回しか動かないので、
//   ログイン後にWebSocketを繋ぐ処理が実行されない。
//   状態の変化を見張って、その都度対応する。
watch(
  () => session.isLoggedIn,
  (loggedIn) => {
    if (loggedIn) {
      startCable()
      router.push('/')
    } else {
      stopCable()
      router.push('/login')
    }
  }
)

function startCable() {
  if (subscription.value) return   // 二重に繋がないよう防ぐ

  // 【ここが非同期処理の受け口】
  //   Sidekiqワーカーが生成を終えると、
  //   Redis → Rails → WebSocket を経由してここに届く。
  //   届いたデータをストアに反映すると、
  //   それを表示している画面が自動で描き変わる。
  subscription.value = subscribeToTerms((updatedTerm) => {
    termsStore.applyUpdate(updatedTerm)
  })
}

function stopCable() {
  // 【購読を解除する理由】
  //   ログアウト後も繋がったままだと、
  //   ・サーバー側の接続が無駄に残る
  //   ・別のユーザーでログインし直したとき、
  //     前のユーザー宛の通知を受け取り続ける可能性がある
  subscription.value?.unsubscribe()
  subscription.value = null
}

// 【onUnmounted】コンポーネントが破棄されるときに呼ばれる。
//   ページを離れるときにWebSocketを閉じる。
//   閉じ忘れると接続が残り続ける（リソースリーク）。
onUnmounted(stopCable)

async function handleLogout() {
  await session.logout()
}
</script>

<template>
  <!-- 【v-if / v-else の意味】条件によって描画を切り替える。
       条件が偽なら、その要素はDOMに存在すらしない。 -->
  <div v-if="session.loading" class="container">
    <p class="muted">読み込み中…</p>
  </div>

  <template v-else>
    <header class="app-header">
      <h1>単語メモ</h1>

      <div v-if="session.isLoggedIn" class="row">
        <span class="muted">{{ session.user.email }}</span>
        <button @click="handleLogout">ログアウト</button>
      </div>
    </header>

    <main class="container">
      <!-- 【RouterView とは】
           現在のURLに対応するコンポーネントがここに描画される。
           / なら TermList、/terms/5 なら TermDetail。

           ヘッダーは共通なので、切り替わるのはこの中だけ。
           これがSPAの「ページ全体を再読み込みしない」の実体。 -->
      <RouterView />
    </main>
  </template>
</template>
