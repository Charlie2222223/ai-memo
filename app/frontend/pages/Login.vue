<!--
  ============================================================================
  Login.vue — ログイン画面
  ============================================================================
-->
<script setup>
import { ref } from 'vue'
import { useSessionStore } from '../stores/session'

const session = useSessionStore()

// 【ref で入力値を保持する】
//   下の <input v-model="email"> と双方向に結び付く。
//   入力すると email.value が変わり、
//   コードから email.value を変えると入力欄の表示も変わる。
const email = ref('')
const password = ref('')
const error = ref('')
const submitting = ref(false)

async function handleSubmit() {
  error.value = ''
  submitting.value = true
  try {
    await session.login(email.value, password.value)
    // 成功後の画面遷移は App.vue の watch が行う。
    // 【なぜここで router.push しないのか】
    //   ログイン成功時にやることは「遷移」だけではなく、
    //   WebSocketの接続も必要。
    //   両方をここに書くと、他の場所からログインしたときに
    //   同じ処理を書き直すことになる。
    //   「ログイン状態が変わったら何をするか」を1箇所にまとめている。
  } catch (e) {
    error.value = e.message
    // 【パスワードだけ消す理由】
    //   メールアドレスは残しておいた方が打ち直しが楽。
    //   パスワードは残すと、画面を離れたときに覗き見される恐れがある。
    password.value = ''
  } finally {
    // 【finally が必要な理由】
    //   成功・失敗どちらでもボタンを再度押せる状態に戻す。
    //   ここを書き忘れると、1回失敗した後ボタンが
    //   押せないまま固まる。
    submitting.value = false
  }
}
</script>

<template>
  <!-- 【@submit.prevent の意味】
       フォーム送信時に handleSubmit を呼び、
       ブラウザ本来の送信動作（ページ遷移）を止める。
       .prevent が無いとページが再読み込みされ、SPAが壊れる。 -->
  <form class="card" @submit.prevent="handleSubmit" style="max-width: 24rem; margin: 2rem auto;">
    <h2 style="margin-top:0">ログイン</h2>

    <!-- v-if は条件が真のときだけ描画する -->
    <p v-if="error" class="error-box">{{ error }}</p>

    <label>
      メールアドレス
      <!-- 【type="email"】スマホでメール用のキーボードが出る。
           【autocomplete="username"】ブラウザの自動入力が働く。 -->
      <input v-model="email" type="email" required autocomplete="username" />
    </label>

    <label style="display:block; margin-top:0.75rem">
      パスワード
      <input v-model="password" type="password" required autocomplete="current-password" />
    </label>

    <!-- 【:disabled の : は v-bind の省略形】
         JavaScriptの式の結果を属性の値にする。
         送信中は二重送信を防ぐため押せなくする。 -->
    <button class="primary" type="submit" :disabled="submitting" style="width:100%; margin-top:1rem">
      {{ submitting ? '確認中…' : 'ログイン' }}
    </button>

    <p class="muted" style="margin-bottom:0">
      アカウントは <code>rails db:seed</code> で作成されます。
      メールとパスワードは <code>.env</code> の値です。
    </p>
  </form>
</template>
