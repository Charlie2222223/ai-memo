# Web基礎 — HTTP・オリジン・Cookie・セッション

このアプリの通信まわりを理解するための土台。

---

## 1. HTTPはステートレス

**1回のやり取りが終わると、サーバーは相手が誰だったかを完全に忘れます。**

```
[ブラウザ] GET /api/terms  →  [サーバー] 「どちら様？」
[ブラウザ] GET /api/terms  →  [サーバー] 「どちら様？」（さっきと同一人物か分からない）
```

これは欠陥ではなく設計です。サーバーが全接続の状態を覚えていると、
何百万人が使うサービスは成立しません。

**だから毎回「私はこれです」と証明する必要がある。** その仕組みがCookieです。

---

## 2. Cookie

サーバーがブラウザに預ける小さなメモ。ブラウザは**同じドメイン宛のリクエストに自動で付けます**。

```
[サーバー] Set-Cookie: _memo_session=abc123...   ← 渡す
[ブラウザ] Cookie: _memo_session=abc123...       ← 以降、毎回自動で送る
```

### 重要な非対称性

> **攻撃者はCookieを「送らせる」ことはできるが、「読む」ことはできない。**

- 送らせる → 別サイトから `/api/terms` へPOSTさせれば、ブラウザは自動でCookieを付ける（→ **CSRF**）
- 読めない → 別オリジンのJavaScriptからは `document.cookie` にアクセスできない

この非対称性が、CSRF対策の仕組みそのものです（→ `02-認証.md`）。

### Cookieに付ける属性

| 属性 | 効果 | 無いとどうなるか |
|---|---|---|
| `HttpOnly` | JavaScriptから読めなくする | XSSで即座に盗まれる |
| `Secure` | HTTPS通信でのみ送る | 公衆Wi-Fiで盗聴される |
| `SameSite=Lax` | 他サイト発のPOSTには付けない | CSRFが成立する |

このアプリの設定は `config/initializers/session_store.rb` にあります。

---

## 3. セッション

Cookieに入れられる情報は限られ、書き換えられても困ります。
そこで**「番号だけ渡して、中身はサーバーが持つ」**のがセッションです。

```ruby
session[:user_id] = user.id   # ← Railsが暗号化してCookieに書く
```

### なぜユーザーが偽装できないのか

Railsはセッションの中身に**署名**を付けます。署名の鍵はサーバーだけが持っています（`config/master.key`）。

```
ユーザーがCookieを user_id=999 に書き換える
  → 署名が合わなくなる
  → Railsは丸ごと無効として捨てる
  → 未ログイン扱いになる
```

### なぜ「IDだけ」入れて毎回DBを引くのか

ユーザー情報そのものをCookieに入れると：
- メールアドレスを変えても古い値が残り続ける
- アカウントを削除しても、そのCookieを持つ人は使い続けられる

IDだけ入れて毎回DBから引けば、常に最新かつ、DBから消せば即座に無効化できます。

該当コード：`app/controllers/concerns/authentication.rb`

---

## 4. オリジン

**オリジン = スキーム + ホスト + ポート**

```
https://memo.fly.dev:443
~~~~~   ~~~~~~~~~~~~ ~~~
スキーム    ホスト     ポート
```

**3つすべてが一致して初めて「同じオリジン」**です。

| URL | `http://localhost:3000` と同じ？ |
|---|---|
| `http://localhost:3000/api/terms` | ✅ 同じ |
| `http://localhost:3036` | ❌ ポートが違う |
| `https://localhost:3000` | ❌ スキームが違う |
| `http://127.0.0.1:3000` | ❌ ホスト名の文字列が違う |

### 同一オリジンポリシー

ブラウザの基本的な安全装置。**別オリジンのページの中身をJavaScriptから読めません。**

これがあるおかげで、攻撃者のサイトを開いても、
あなたが別タブで開いている銀行サイトの中身は読み取られません。

### このアプリが同一オリジンにした理由

```
https://memo.fly.dev
  ├─ /              → Vue SPA
  ├─ /api/terms     → Rails API
  └─ /cable         → WebSocket
     すべて同じオリジン
```

| | 同一オリジン | 別オリジン |
|---|---|---|
| Cookie | 自動で飛ぶ | `credentials: 'include'` が必要 |
| CSRF対策 | `SameSite=Lax` が使える | `SameSite=None` にせざるを得ない（防御が弱まる） |
| CORS設定 | 不要 | 必須 |
| WebSocket | 同じホスト | クロスオリジン許可が必要 |
| デプロイ | 1回 | 2回 |

**「SPA = フロントとバックを分ける」は誤解です。**
SPAは「画面遷移をJavaScriptがやる」という意味で、配信元とは無関係です。

---

## 5. HTTPステータスコード

このアプリで使い分けているもの：

| コード | 意味 | このアプリでの使用箇所 |
|---|---|---|
| 200 OK | 成功 | 一覧・詳細の取得 |
| 201 Created | 新規作成された | 単語の登録 |
| 202 Accepted | 受け付けた（処理はこれから） | 再生成 |
| 204 No Content | 成功、返す本文なし | ログアウト・削除 |
| 401 Unauthorized | **誰か分からない** | 未ログイン |
| 403 Forbidden | 誰かは分かるが権限がない | （**あえて使わない**） |
| 404 Not Found | 存在しない | 他人の単語 |
| 409 Conflict | 現在の状態と矛盾する | 生成中の単語に再生成 |
| 422 Unprocessable | 形式は正しいが内容が不正 | バリデーションエラー・CSRF不一致 |

### なぜ他人のデータに 403 ではなく 404 を返すのか

403 は「そのIDは実在する。ただしあなたのものではない」と教えてしまいます。
IDを1から順に試せば、他人のデータが何件あるか分かってしまう（**列挙攻撃**）。

404 で統一すれば、存在しないのか他人のものなのか区別できません。

---

## 6. リクエストの一生（このアプリの場合）

```
[ブラウザ] POST /api/terms
   │  Cookie: _memo_session=...        ← ブラウザが自動で付ける
   │  X-CSRF-Token: aRBvzoo...         ← JavaScriptが付ける
   ▼
[Rack ミドルウェア]
   │  Host Authorization … Hostヘッダを検査（DNSリバインディング対策）
   │  Session            … Cookieを復号して session を組み立てる
   ▼
[ApplicationController]
   │  protect_from_forgery      … CSRFトークンを照合
   │  before_action :require_authentication … session[:user_id] からユーザーを復元
   ▼
[TermsController#create]
   │  current_user.terms.build  … user_id はサーバーが決める
   │  term.save!
   │  ExplainTermJob.perform_later
   ▼
[201 Created + JSON]
```

途中のどこか1つでも欠けると、認証が素通りしたり、CSRFが成立したりします。

---

## 自分で確かめる

```bash
# Cookieの属性を見る
curl -i http://localhost:3000/api/session | grep -i set-cookie

# CSRFトークン無しでPOST → 422 になるはず
curl -o /dev/null -w "%{http_code}\n" -X POST http://localhost:3000/api/terms \
  -H "Content-Type: application/json" -d '{"term":{"word":"test"}}'
```

ブラウザの開発者ツール → Application → Cookies でも、
`HttpOnly` `SameSite` の列を実際に確認できます。
