# typewhisper.el

[English](README.md)

[TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) で Emacs に音声入力し、聞き間違いを Claude で直して、その修正を TypeWhisper に覚えさせるパッケージです。同じ間違いが次から起きにくくなります。

英語の技術用語が混ざる日本語の口述を想定しています。たとえば `リアクトのユーズエフェクト` を `ReactのuseEffect` に直します。他の言語でも使えるはずです。

## 機能

- 口述入力：Emacs から TypeWhisper の口述を開始・停止する。貼り付けられたテキストを覚えておき、あとから修正できる。
- 修正：直前の口述（またはリージョン）を Claude Code CLI 経由で Claude に送る。直すのは音声認識の誤りだけで、対象のテキストの外は変えない。前後の行は文脈として渡すだけ。すべての修正を 1 回の undo で戻せる。
- 学習：修正のあと、どれを TypeWhisper の Correction や Term に登録するかを選ぶ。短いひらがな語など、誤爆しやすいものは最初から選択を外しておく。
- 辞書の編集：Correction と Term の一覧・追加・編集・削除。

## 必要なもの

- macOS と TypeWhisper。**設定 > Advanced** で API サーバーを有効にしておく
- Emacs 29.1 以降
- `curl`
- ログイン済みの [Claude Code](https://claude.com/claude-code)（`claude`）。API キーは不要

## インストール

`use-package` と `:vc` を使う場合（Emacs 30 以降）：

```elisp
(use-package typewhisper
  :vc (:url "https://github.com/wakamenod/typewhisper.el")
  :config
  (typewhisper-mode 1))
```

または、リポジトリを clone して `load-path` に追加します。

```elisp
(add-to-list 'load-path "/path/to/typewhisper.el")
(require 'typewhisper)
(typewhisper-mode 1)
```

キーバインドは定義していません。設定例：

```elisp
(keymap-global-set "C-c d d" #'typewhisper-dictate)
(keymap-global-set "C-c d f" #'typewhisper-dictate-and-fix)
(keymap-global-set "C-c d x" #'typewhisper-fix)
(keymap-global-set "C-c d c" #'typewhisper-corrections)
(keymap-global-set "C-c d t" #'typewhisper-terms)
```

## 使い方

### 口述入力

`M-x typewhisper-dictate` でポイントの位置から口述を始め、もう一度実行すると止まります。TypeWhisper は文字起こしした結果を前面のアプリに貼り付けるので、Emacs を前面にしておいてください。

`M-x typewhisper-dictate-and-fix` も動きは同じですが、止めたあとに結果を `typewhisper-fix` で直します。

`typewhisper-mode` を有効にすると、モードラインに状態が出ます。録音中は `TW[REC]`、開始中と文字起こし中は `TW[…]` です。Claude が修正している間は `[fix]` が付きます。

Emacs と TypeWhisper の状態がずれたときは `M-x typewhisper-cancel` を実行してください。

### 修正

`M-x typewhisper-fix` はリージョンがあればリージョンを、なければ直前の口述を直します。Claude に渡すのは次のものです。

- 対象のテキスト
- 前後 `typewhisper-fix-context-lines` 行（文脈として渡すだけで、修正はしない）
- TypeWhisper に登録済みの Term と Correction（表記の参考）
- バッファのメジャーモード

直した箇所はしばらくハイライトされます。Claude の確信度が `typewhisper-fix-min-confidence` より低い修正は適用せず、エコーエリアに提案として表示します。

### 修正の登録

修正を適用すると `*TypeWhisper Register*` バッファが開きます。

| キー      | 操作                                                      |
|-----------|-----------------------------------------------------------|
| `m` / `u` | 選択 / 選択解除                                           |
| `t`       | Correction と Term を切り替え                             |
| `c`       | 大文字小文字の区別を切り替え                              |
| `C-c C-c` | 選択した行を登録                                          |
| `C-c C-k` | 破棄                                                      |

Correction は、文字起こしのあとで `wrong` を `right` に置き換えます。Term は `right` を音声認識エンジンへのヒントとして追加します。英語の技術用語には Term のほうが向いていることが多いです。

Notes 列には警告が出ます。次の行は最初から選択を外しています。

- 元の文字列が短すぎる（`typewhisper-register-min-length`）。ひらがなだけの場合は `typewhisper-register-min-hiragana-length` で判定する。
- 同じ Correction がすでに登録されている。
- TypeWhisper の生の文字起こし（Correction 適用前）に `wrong` が含まれない。既存の Correction が作った誤りの可能性が高いので、そちらを見直す。

次の行は選択したまま、警告だけ付けます。

- 大文字小文字だけが違う。
- 既存の Correction を別の置換先で上書きする。

この確認を省くには `typewhisper-fix-confirm-registration` を nil にします。

### 辞書

`M-x typewhisper-corrections` と `M-x typewhisper-terms` で辞書の一覧を開きます。

| キー | 操作                      |
|------|---------------------------|
| `a`  | 追加                      |
| `e`  | 編集                      |
| `d`  | 削除（確認あり）          |
| `s`  | 部分一致で絞り込み        |
| `g`  | 再読み込み                |

## 設定

| 変数                                  | 既定値     | 説明                                               |
|---------------------------------------|------------|----------------------------------------------------|
| `typewhisper-claude-program`          | `"claude"` | Claude Code CLI のパス                             |
| `typewhisper-claude-model`            | `"sonnet"` | 修正に使うモデル                                   |
| `typewhisper-claude-effort`           | `"low"`    | effort の指定。nil なら指定しない                  |
| `typewhisper-fix-context-lines`       | `3`        | 前後それぞれの文脈の行数                           |
| `typewhisper-fix-min-confidence`      | `medium`   | 適用する最低の確信度                               |
| `typewhisper-fix-include-dictionary`  | `t`        | Term と Correction を Claude に渡す                |
| `typewhisper-fix-highlight-duration`  | `3`        | 修正箇所をハイライトする秒数                       |
| `typewhisper-api-port`                | `nil`      | API のポート。nil なら TypeWhisper のファイルから読む |
| `typewhisper-api-token`               | `nil`      | API のトークン。nil なら TypeWhisper のファイルから読む |
| `typewhisper-workflow-id`             | `nil`      | 口述の開始時に使う Workflow                        |

ほかの設定は `M-x customize-group RET typewhisper` で確認できます。

`sonnet` と effort `low` の組み合わせでは、1 回の修正が 3 秒ほどで終わり、英語の技術用語も正しく直せます。試した範囲では、`haiku` のほうが遅く、精度も低めでした。

Dock から起動した Emacs では、`claude` を見つけられないことがよくあります。その場合は `typewhisper-claude-program` にフルパス（`~/.local/bin/claude` など）を設定してください。

## 仕組み

- ポートとトークンは `~/Library/Application Support/TypeWhisper/api-discovery.json` から読み取ります。このファイルは、API サーバーの動作中に TypeWhisper が書き出します。リクエストは `curl` で送ります。トークンは標準入力で渡すので、プロセス一覧には出ません。
- `POST /v1/dictation/start` はマイクの準備が終わるまで応答しないので、口述まわりのリクエストはすべて非同期で送ります。
- 口述を止めたあとは、文字起こしが終わるまで `GET /v1/dictation/transcription` をポーリングします。終わったら、口述を始めた位置で貼り付けられたテキストを探します。
- 修正では `claude -p` をツール・MCP サーバー・設定なしで実行し、構造化された JSON で答えを受け取ります。

## 開発

```sh
make test      # ERT のテストを実行
make compile   # 警告をエラーとしてバイトコンパイル
```

## ライセンス

GPL-3.0-or-later
