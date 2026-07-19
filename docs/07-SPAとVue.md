# SPAとVue — 画面がどう動いているか

---

## 1. SPAとは（よくある誤解から）

**SPA（Single Page Application）= 画面遷移をブラウザ側のJavaScriptがやる方式。**

```
従来:  リンクをクリック → サーバーへ → HTMLを受け取る → 画面が白くなって再描画
SPA:   リンクをクリック → JSが画面を書き換える（サーバーへは行かない）
       データが必要なときだけ JSON を取りに行く
```

### 誤解：「SPA = フロントとバックを別サーバーに分ける」

**これは別の話です。**
SPAは「画面遷移の方式」であって、**どこから配信されるかとは無関係**です。

このアプリは Rails が Vue を配信していますが、完全にSPAです。

分けなかった理由は `01-web基礎.md` の「オリジン」を参照。
（Cookie・CORS・CSRF・wss・デプロイが全部素直になります）

### SPAの代償も理解しておく

| 利点 | 欠点 |
|---|---|
| 画面切り替えが速い | 最初にJSを読み込むまで何も表示されない |
| サーバーはデータだけ返せばよい | 検索エンジンがJSを実行しないと中身を読めない |
| リアルタイム更新と相性が良い | ブラウザ側のコード量が増える |

このアプリは自分専用なので、どちらの欠点も問題になりません。

---

## 2. リアクティブ（Vueの核心）

```javascript
const count = ref(0)     // ← Vueが変化を監視できる箱
count.value++            // ← 画面が自動で更新される
```

**普通の変数との違い：**

```javascript
let count = 0
count++        // 画面は変わらない（Vueは変化を知りようがない）
```

`ref()` で包むと、Vueが「この値が読まれた場所」を記憶し、
値が変わったとき**その場所だけ**を描き直します。

**この考え方がSPAフレームワークの根幹です。**
「データを変えれば画面が追従する」ので、DOM操作を手で書く必要がありません。

```javascript
// jQuery時代（手でDOMを触る）
$('#count').text(count)

// Vue（データを変えるだけ）
count.value++
```

### `.value` について

コード内では `.value` が必要ですが、テンプレート内では自動的に外れます。

```javascript
const word = ref('冪等性')
console.log(word.value)   // コード内
```
```html
<p>{{ word }}</p>          <!-- テンプレート内（.value 不要） -->
```

---

## 3. .vue ファイルの構造

```vue
<script setup>   // ロジック
<template>       // 見た目
<style>          // スタイル（このアプリでは未使用）
```

3つが1ファイルにまとまります。
**「この画面に関するものは、この1ファイルを見れば全部ある」**状態になります。

---

## 4. コンポーネント間のデータの流れ

### props（親 → 子）

```vue
<!-- 親 -->
<TermCard :term="t" detailed />

<!-- 子 -->
const props = defineProps({
  term: { type: Object, required: true },
  detailed: { type: Boolean, default: false },
})
```

**型と `required` を明示する理由**：渡し忘れたときコンソールに警告が出ます。
書かないと `undefined` のまま描画され、「なぜか空のカードが出る」状態になります。

### ストア（どこからでも）

props は親から子へ**一方向**にしか流れません。
複数階層を跨ぐと、途中の階層が使わないデータを受け取って渡すだけになります（バケツリレー）。

```
App → TermList → TermCard   ← TermListは使わないのに受け渡しが必要
```

**ストア（Pinia）に置けば、必要な場所が直接読めます。**

```javascript
const store = useTermsStore()
store.terms       // どのコンポーネントからでも
```

このアプリのストア：
- `stores/session.js` … ログイン状態
- `stores/terms.js` … 単語一覧・検索条件

---

## 5. ストアがWebSocketで効く理由

```javascript
// App.vue
subscribeToTerms((updatedTerm) => {
  termsStore.applyUpdate(updatedTerm)   // ← ここだけ
})
```

一覧データを1箇所に集約しているので、
**WebSocketで届いた更新をストアに適用するだけで、
それを表示している画面すべてに反映されます。**

各画面が独自にデータを持っていたら、全画面に更新処理を書く必要があり、
書き漏らしが必ず出ます。

---

## 6. ルーティング

```javascript
const routes = [
  { path: '/', component: TermList },
  { path: '/terms/:id', component: TermDetail },
]
```

### サーバー側との対応が必要

`createWebHistory()`（URLに `#` が入らない方式）を使う場合、
ブラウザで直接 `/terms/5` を開かれると、サーバーに「/terms/5 をください」と届きます。

サーバーがそのURLを知らないと404になるので、Rails側に受け皿が要ります。

```ruby
# config/routes.rb（必ず最後に置く）
match "*path", to: "pages#index", via: :all, format: false,
      constraints: ->(req) { !req.path.start_with?("/api/") }
```

**フロントとサーバーの設定が対になっています。**
片方だけ変えると「リロードしたときだけ壊れる」という気付きにくい不具合になります。

`/api/` を除外しているのは、存在しないAPIにHTMLを返すと
`Unexpected token '<'` という原因の分かりにくいエラーになるためです。

---

## 7. ライフサイクル

```javascript
onMounted(() => { ... })    // 画面に表示された直後（1回だけ）
watch(() => x, () => {...}) // 値が変わるたび
onUnmounted(() => { ... })  // 画面から消えるとき
```

### `watch` が必要になる場面

```javascript
// TermDetail.vue
watch(() => route.params.id, load)
```

`/terms/1` から `/terms/2` へ移動しても、**同じコンポーネントが再利用される**ため
`onMounted` は呼ばれません。

これを忘れると「別の単語を開いたのに前の内容が出る」となります。

### `onUnmounted` で後片付け

```javascript
onUnmounted(stopCable)   // WebSocketを閉じる
```

閉じ忘れると接続が残り続けます（リソースリーク）。

---

## 8. `:key` の意味

```vue
<TermCard v-for="term in store.terms" :key="term.id" :term="term" />
```

Vueがリストの各要素を識別するための目印です。

無いと、並び替えや一部更新のときに**間違った要素を再利用して表示が崩れます。**
WebSocketで一部のカードだけが更新されるこのアプリでは特に重要です。

**インデックス（`:key="i"`）は避けてください。** 並び替えで壊れます。
IDのような安定した値を使います。

---

## 9. セキュリティ：`v-html` を使わない

```vue
<p>{{ term.meaning }}</p>       <!-- ✅ 自動エスケープされる -->
<p v-html="term.meaning" />     <!-- ❌ HTMLとして解釈される -->
```

このアプリは**AIの出力をそのまま画面に出しています。**
`v-html` だと、AIの応答に `<script>` が混ざっていれば実行されます（XSS）。

**AIの出力は「信用できない入力」として扱う。**
ユーザー入力を信用しないのと同じ理由です。

---

## 10. デバウンス（検索欄の定番）

```javascript
let timer = null
watch([() => store.query], () => {
  clearTimeout(timer)
  timer = setTimeout(() => store.fetchTerms(), 300)
})
```

1文字打つたびにAPIを呼ぶと、「冪等性」の4文字で4回リクエストが飛びます。
しかも**応答の順序は保証されない**ので、古い結果が後から届いて表示が入れ替わります。

入力が止まって300ms経ってから1回だけ呼ぶようにします。

---

## 読むべきコード

| ファイル | 内容 |
|---|---|
| `app/frontend/entrypoints/application.js` | 起動点 |
| `app/frontend/App.vue` | 最上位・WebSocket接続の管理 |
| `app/frontend/router.js` | URLと画面の対応 |
| `app/frontend/stores/terms.js` | 状態管理・WebSocket更新の適用 |
| `app/frontend/lib/api.js` | fetch のラッパー（CSRF・Cookie） |
| `app/frontend/lib/cable.js` | WebSocket購読 |
| `app/frontend/components/TermCard.vue` | カード表示 |
