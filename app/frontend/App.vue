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
    ③ サイドバーと本文の骨格を組む
    ④ 通知（トースト）の置き場所
  ============================================================================
-->
<script setup>
// 【<script setup> とは】Vue 3 の簡潔な書き方。
//   ここで定義した変数や関数は、そのまま <template> から使える。
//   export する必要がない。
import { onMounted, onUnmounted, watch, ref, computed } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useSessionStore } from './stores/session'
import { useTermsStore } from './stores/terms'
import { useToastsStore } from './stores/toasts'
import { subscribeToTerms } from './lib/cable'
import TermSidebar from './components/TermSidebar.vue'

const session = useSessionStore()
const termsStore = useTermsStore()
const toasts = useToastsStore()
const router = useRouter()
const route = useRoute()

// WebSocketの購読オブジェクト。切断のために保持しておく。
const subscription = ref(null)

// ----------------------------------------------------------------------------
// スマホでサイドバーと本文のどちらを見せるか
// ----------------------------------------------------------------------------
// 【なぜURLで決めるのか】
//   ドロワー（重なって出てくるメニュー）にすると、
//   開閉状態という「URLに現れない状態」が増える。
//   その状態は再読み込みで消えるし、ブラウザの戻るでも復元されない。
//
//   URLと1対1にしておけば、
//   ・戻るボタンがそのまま「一覧に戻る」になる
//   ・詳細のURLを共有すれば、その単語が開いた状態で始まる
//   が自動的に成立する。状態を持たないのが一番壊れない。
//
//   広い画面では両方出すので、このクラスはCSS側で無視される。
const shellClass = computed(() =>
  route.name === 'term' ? 'showing-detail' : 'showing-list'
)

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

      // 【ログイン画面にいるときだけトップへ送る】
      //   以前は無条件で router.push('/') していたため、
      //   /terms/5 を直接開くと必ずトップへ弾かれていた。
      //
      //   起動時は「未ログイン → 確認完了でログイン済み」と
      //   状態が必ず1回変化するので、この watch は毎回発火する。
      //   そこで無条件に飛ばすと、URLで開いた単語が必ず失われる。
      //
      //   ブックマークや共有されたURLがそのまま開けることは、
      //   SPAでURLを普通の形（createWebHistory）にした意味そのもの。
      if (route.name === 'login') router.push('/')
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
    // 【更新前の状態を先に控える理由】
    //   applyUpdate でストアを書き換えた後だと、
    //   「さっきまで生成中だったのか、元から完了していたのか」が
    //   分からなくなる。通知を出すべきかの判断ができない。
    const before = termsStore.terms.find((t) => t.id === updatedTerm.id)

    termsStore.applyUpdate(updatedTerm)

    // 【生成が完了した瞬間だけ通知する】
    //   サイドバーと本文に分けたことで、別の単語を読んでいる最中に
    //   生成が終わるケースが普通に起きるようになった。
    //   一覧の行は変わるが、視線がそこに無いと気付けない。
    //
    //   逆に、今まさに開いている単語なら本文が目の前で変わるので、
    //   通知は重複になる。その場合は出さない。
    const justCompleted = before?.status === 'pending' && updatedTerm.status === 'completed'
    const isOpen = route.params.id === String(updatedTerm.id)

    if (justCompleted && !isOpen) {
      toasts.show(`「${updatedTerm.word}」の解説ができました`)
    }
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
</script>

<template>
  <!-- 【v-if / v-else の意味】条件によって描画を切り替える。
       条件が偽なら、その要素はDOMに存在すらしない。 -->
  <div v-if="session.loading" class="empty-state">
    <p class="muted">読み込み中…</p>
  </div>

  <!-- 【ログイン前はサイドバーを出さない】
       単語一覧を取りに行っても401で弾かれるだけで、
       見せる中身が無い。骨格そのものを出し分ける。 -->
  <div v-else-if="!session.isLoggedIn" class="main-panel" style="margin: 0 auto">
    <RouterView />
  </div>

  <template v-else>
    <div class="app-shell" :class="shellClass">
      <!-- 【<aside> を使う理由】
           主要な内容の傍らにある補助的な領域、という意味を持つタグ。
           <div> でも見た目は同じだが、スクリーンリーダーが
           「補助領域」として読み分けられる。 -->
      <aside class="sidebar">
        <TermSidebar />
      </aside>

      <!-- 【RouterView とは】
           現在のURLに対応するコンポーネントがここに描画される。
           / なら TermList、/terms/5 なら TermDetail。

           サイドバーは共通なので、切り替わるのはこの中だけ。
           これがSPAの「ページ全体を再読み込みしない」の実体。 -->
      <main class="main-panel">
        <RouterView />
      </main>
    </div>

    <!-- ======================================================================
         通知
         ======================================================================
         【TransitionGroup とは】
           リストの要素が increased/decreased したときに
           アニメーションを付けられるVueの仕組み。

         【ここにアニメーションを付ける理由】
           通知は自分が操作していないのに現れる。
           突然出ると驚くし、突然消えると見落とす。
           動きで「現れた／去った」を伝える。
           規則（見落とすと困る変化にだけ付ける）に合致する。 -->
    <TransitionGroup tag="div" name="toast" class="toast-area">
      <div v-for="toast in toasts.toasts" :key="toast.id" class="toast">
        {{ toast.message }}
      </div>
    </TransitionGroup>
  </template>
</template>
