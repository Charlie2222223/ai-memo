// ============================================================================
// router.js — URLと画面の対応表（Vue Router）
//
// 【サーバー側のルーティングとの違い】
//   config/routes.rb … サーバーが「どのコントローラを呼ぶか」を決める
//   ここ            … ブラウザが「どの画面を描くか」を決める
//
//   SPAでは画面切り替えがブラウザ内で完結するので、
//   URLと画面の対応もブラウザ側に必要になる。
// ============================================================================
import { createRouter, createWebHistory } from 'vue-router'
import TermList from './pages/TermList.vue'
import TermDetail from './pages/TermDetail.vue'
import Login from './pages/Login.vue'

const routes = [
  { path: '/', name: 'terms', component: TermList },

  // 【:id の意味】任意の値にマッチする部分。
  //   /terms/5 なら route.params.id が '5' になる。
  { path: '/terms/:id', name: 'term', component: TermDetail },

  { path: '/login', name: 'login', component: Login },

  // 【受け皿】上のどれにも当てはまらないURLは一覧へ戻す。
  //   これが無いと、打ち間違えたURLで真っ白な画面になる。
  { path: '/:pathMatch(.*)*', redirect: '/' },
]

export const router = createRouter({
  // --------------------------------------------------------------------------
  // 【createWebHistory とは】
  //   URLを /terms/5 のような普通の形にする方式（History API を使う）。
  //
  //   もう一つ createWebHashHistory という方式があり、
  //   そちらは /#/terms/5 のように # が入る。
  //   # 以降はサーバーに送られないため、サーバー側の設定が不要という利点がある。
  //
  // 【普通の形を選んだ場合に必要なこと】
  //   ブラウザで直接 /terms/5 を開かれると、
  //   サーバーに「/terms/5 をください」と届く。
  //   サーバーがそのURLを知らないと404になる。
  //
  //   config/routes.rb の最後に置いた
  //     match "*path", to: "pages#index"
  //   がこれを受け止め、SPAの入口HTMLを返している。
  //   その結果、Vueが起動してURLを見て正しい画面を描ける。
  //
  //   フロントとサーバーの設定が対になっている箇所。
  //   片方だけ変えるとリロード時だけ壊れる、という
  //   気付きにくい不具合になる。
  // --------------------------------------------------------------------------
  history: createWebHistory(),
  routes,
})
