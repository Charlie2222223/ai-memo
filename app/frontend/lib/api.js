// ============================================================================
// api.js — Rails APIを呼ぶための共通処理
//
// 【なぜラッパーを作るのか】
//   各画面で直接 fetch() を書くと、
//     ・CSRFトークンの付与
//     ・Cookieを送る設定
//     ・エラー処理
//   を毎回書くことになり、1箇所でも書き忘れると動かない。
//   共通化しておけば、書き忘れようがない。
// ============================================================================

// ----------------------------------------------------------------------------
// CSRFトークンを取得する
// ----------------------------------------------------------------------------
// レイアウトの csrf_meta_tags が出力した <meta name="csrf-token"> から読む。
//
// 【なぜ毎回読み直すのか】
//   起動時に1回だけ読んで変数に持つと、
//   ログイン時の reset_session でトークンが変わったとき、
//   古い値を送り続けて 422 エラーになる。
//   （「ログイン直後だけ操作できない」という分かりにくい不具合）
function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || ''
}

// ----------------------------------------------------------------------------
// APIエラーを表すクラス
// ----------------------------------------------------------------------------
// 【なぜ専用クラスを作るのか】
//   呼び出し側で「HTTPのステータスに応じた処理」を書きたい。
//   401なら再ログイン、422なら入力エラーの表示、など。
//   ただの文字列だと、この判断ができない。
export class ApiError extends Error {
  constructor(status, body) {
    // body.error（単一メッセージ）か body.errors（配列）のどちらかが来る。
    super(body?.error || body?.errors?.join('\n') || `HTTPエラー ${status}`)
    this.status = status
    this.body = body
  }
}

// ----------------------------------------------------------------------------
// APIを呼ぶ本体
// ----------------------------------------------------------------------------
async function request(method, path, body = null) {
  const options = {
    method,
    headers: {
      'Content-Type': 'application/json',

      // 【この指定が無いとRailsがHTMLを返す】
      //   Railsは Accept ヘッダを見て応答形式を決める。
      //   指定しないとHTMLのエラー画面が返り、
      //   JSON.parse が「Unexpected token '<'」で落ちる。
      //   原因が非常に分かりにくいエラーになる。
      'Accept': 'application/json',

      // CSRFトークン。これが無いと POST/PATCH/DELETE は 422 で弾かれる。
      'X-CSRF-Token': csrfToken(),
    },

    // ------------------------------------------------------------------------
    // 【credentials: 'same-origin' の意味】← 認証の要
    //   fetch は既定でCookieを送らない設定になっている
    //   （古いブラウザでは送っていたが、安全性のため変更された）。
    //
    //   このアプリの認証はセッションCookieなので、
    //   これを書かないとサーバー側は常に「未ログイン」と判断する。
    //   ログインは成功するのに、次のリクエストで401になる、という
    //   典型的なハマり方をする。
    //
    //   'same-origin' は「同じオリジンへのリクエストならCookieを送る」。
    //   Q7で同一オリジン構成を選んだので、これで足りる。
    //   別オリジンなら 'include' が必要で、
    //   さらにサーバー側のCORS設定も要る（＝面倒が増える）。
    // ------------------------------------------------------------------------
    credentials: 'same-origin',
  }

  if (body) options.body = JSON.stringify(body)

  const response = await fetch(path, options)

  // 204 No Content（ログアウトなど）は本文が無いので、パースしない。
  if (response.status === 204) return null

  // 本文が空の場合に JSON.parse が落ちるのを防ぐ。
  const text = await response.text()
  const data = text ? JSON.parse(text) : null

  // 【response.ok の意味】ステータスが 200〜299 なら true。
  //   fetch は 404 や 500 でも例外を投げない（通信自体は成功しているため）。
  //   自分でステータスを見て判断する必要がある。ここは間違えやすい。
  if (!response.ok) throw new ApiError(response.status, data)

  return data
}

// ----------------------------------------------------------------------------
// 各APIの呼び出し口
// ----------------------------------------------------------------------------
// 【なぜ薄い関数で包むのか】
//   画面側が '/api/terms' のようなURLを直接書かなくて済む。
//   URLが変わったとき、直すのはこのファイルだけになる。
export const api = {
  // --- セッション ---
  getSession: () => request('GET', '/api/session'),
  login: (email, password) => request('POST', '/api/session', { email, password }),
  logout: () => request('DELETE', '/api/session'),

  // --- 単語 ---
  // 【URLSearchParams を使う理由】
  //   検索語に & や = が含まれていてもURLが壊れないよう、
  //   自動でエスケープしてくれる。
  //   文字列連結で組み立てると、「A&B」で検索したときに壊れる。
  listTerms: (params = {}) => {
    const query = new URLSearchParams(
      Object.entries(params).filter(([, v]) => v)   // 空の条件は送らない
    ).toString()
    return request('GET', `/api/terms${query ? `?${query}` : ''}`)
  },
  getTerm: (id) => request('GET', `/api/terms/${id}`),
  // 【sourceTermId が任意な理由】
  //   通常の登録（サイドバーの入力欄）には出自が無い。
  //   解説の中の語を選んで登録したときだけ、その親のIDが入る。
  createTerm: (word, context, sourceTermId = null) =>
    request('POST', '/api/terms', {
      term: { word, context, source_term_id: sourceTermId },
    }),
  deleteTerm: (id) => request('DELETE', `/api/terms/${id}`),
  regenerateTerm: (id) => request('POST', `/api/terms/${id}/regenerate`),

  // 単語を別のフォルダへ移す（null を渡すと未分類に戻る）
  moveTerm: (id, folderId) =>
    request('PATCH', `/api/terms/${id}`, { term: { folder_id: folderId } }),

  // --- AIが提案したフォルダ ---
  // 【承認が専用のURLになっている理由】
  //   「フォルダを作る → 単語を入れる → 提案を消す」の3段階を
  //   サーバー側で1つのトランザクションにまとめている。
  //   画面から2往復すると、途中で失敗したとき空のフォルダが残る。
  acceptFolder: (id) => request('POST', `/api/terms/${id}/accept_folder`),
  rejectFolder: (id) => request('DELETE', `/api/terms/${id}/suggested_folder`),

  // --- フォルダ ---
  listFolders: () => request('GET', '/api/folders'),
  createFolder: (name) => request('POST', '/api/folders', { folder: { name } }),
  renameFolder: (id, name) => request('PATCH', `/api/folders/${id}`, { folder: { name } }),
  deleteFolder: (id) => request('DELETE', `/api/folders/${id}`),

  // --- タグ ---
  listTags: () => request('GET', '/api/tags'),
}
