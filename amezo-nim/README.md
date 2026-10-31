# あめぞう風掲示板 (Nim版) の動作説明

Python 版 (`amezo-python`) を Nim へ移植したものです。データ形式・URL・画面の文言・トリップ/ID/キャップ/認証キー/中継署名の計算値は Python 版と互換で、**同じデータフォルダを Python 版と共用できます** (秘密鍵ファイル、スレッド、鍵つきスレッドの `keys.txt`、圧縮済み過去ログ `.gz` を相互に読み書きできることをテストで確認済み)。振る舞いの詳細は Python 版の README がそのまま当てはまります。ここでは構成と Nim 版固有の事柄だけを書きます。

## 1. 全体像

**読む側は静的な HTML、書く側だけが CGI** という構成です。投稿があるたびに板の `index.html` を作り直し、閲覧者にはそのファイルをそのまま配信します。

| ファイル | 役割 |
|---|---|
| `server` (ビルド成果物) | 簡易 Web サーバー兼 CGI 実行器。ディレクトリ準備とトンネル公開もする (`src/server.nim`) |
| `index.html` | 親ページ。左に板一覧、右に板を並べたフレーム画面 |
| `dai.cgi` | 左側の板一覧と、各板の見出し (HEAD LINE) を出す (`src/dai.nim`) |
| `amezo.cgi` | 投稿の受付、スレッドファイルの更新、板の `index.html` の再生成 (`src/amezo.nim`) |
| `admin.cgi` | 管理画面。レスの削除、スレッドの非表示と復元、鍵つきスレッドの鍵の管理 (`src/admin.nim`) |
| `jump.cgi` | 署名つき中継ページ。投稿の URL は、まずここを表示して、押したときだけ移動する (`src/jump.nim`) |
| `archive` | 過去ログ (`o数字.html`) を gzip 圧縮するコマンドラインツール (CGI ではない、`src/archive.nim`) |
| `src/bbs.nim` | CGI 共通ライブラリ (設定、トリップ/ID/キャップ、鍵、過去ログ一覧、表示部品) |
| `src/bbsindex.nim` | 板の `index.html` 再生成とスレッドの退避 |
| `src/gz.nim` | gzip の読み書き (システムの libz への FFI) |
| `config.ini` (任意) | 設定ファイル。書式は `config.sample.ini` 参照。実行されない形式で、検査を通った値だけが効く |
| `run.sh` | トンネルなしでローカル起動するスクリプト (`./server --no-tunnel`) |
| `build.sh` | 全バイナリをビルドするスクリプト |
| `style.css`、`header.html`、`hide.js` | 共通の見た目と、板の上部 (リンク・注意書き・新規投稿フォーム)。`hide.js` は、ID・トリップの非表示 (ブラウザの中だけで動く) |

URL は Python 版と同じで、`/amezo.cgi` のほか `/amezo.py` のような `.py` 形式でも CGI が動きます (データフォルダを共用したままサーバーだけ入れ替えられます)。

## 2. ビルドと起動

必要なもの: **Nim 2.4.0** と、リンク時に使う **zlib のライブラリ** (`libz`)。暗号 (HMAC-SHA256 / PBKDF2) は `vendor/nimcrypto` に同梱した nimcrypto を使うので、パッケージのダウンロードは不要です (パッチから作った場合は `git clone https://github.com/cheatfate/nimcrypto vendor/nimcrypto` で置いてください。パッチには第三者ライブラリを含めていません)。

```sh
./build.sh   # amezo.cgi / dai.cgi / admin.cgi / jump.cgi / archive / server を作る
./run.sh     # ローカル起動 (http://localhost:8000、PORT 環境変数で変更可)
```

`./server` を引数なしで起動すると `cloudflared` でトンネルを張ります。他のフラグは Python 版と同じです: `--port N`、`--no-tunnel`、`--make-hash パスワード` (delpass.txt を作って終了)、`--verbose`。管理パスワードのハッシュは `./amezo.cgi --make-hash パスワード` でも作れます (Python 版と検証し合えます)。

## 3. データファイル

Python 版と完全に同じです (`blist.txt`、`ng.txt`、`delpass.txt`、`trip_secret.txt`、`id_secret.txt`、`key_secret.txt`、`jump_secret.txt`、`cap.txt`、`global.mem`、`admin_fail.mem`、`config.ini`、板フォルダ内のスレッド・`.lock`・`keys.txt`・過去ログ・`kako.txt` など)。秘密鍵ファイルはどれも権限 600 で自動生成され、意味も互換です。たとえば `trip_secret.txt` が変われば Python 版でも Nim 版でも全員のトリップが同じように変わります。

## 4. サーバー (`server`)

振る舞いは Python 版の `setup_expose.py` と同じです: 起動時に板フォルダと転送用 `index.html` を用意し、`flock` が使えるか確かめ、許可リストが効いているかを自己チェックして表示します。パスの検査 (空、`//`、`%`、バックスラッシュ、NUL、`..`、ドット区間、絶対形式は **400**) は振り分けの前に行い、静的配信は許可リスト方式、CGI は 30 秒で打ち切り、POST は 64KB 超で **413**、圧縮された過去ログは `o数字.html` の URL で gz のまま/伸長して配信します。

実装上の違い: 接続ごとにプロセスを fork する方式です (Python 版はスレッド)。`Server:` ヘッダは `NimCGI/1.1` です。`cloudflared` が起動できない場合は、Python 版は例外で終了しますが、Nim 版はローカル URL を表示して配信を続けます。

## 5. 過去ログの圧縮 (`archive`)

使い方は Python 版の `archive.py` と同じです。

```sh
./archive main            # 段階1: .gz を作る (平文は残る)。後日もう一度実行すると段階2で平文を消す
./archive --all           # blist.txt の全板
./archive --selftest main # 自己点検だけ
./archive --restore main o260101000000  # 平文に戻す
```

オプション (`--quiet=N`、`--limit=N`、`--dry-run`、`-v`)、終了コード (0/1/2)、`.bad` への退避、スキップ理由の集計も同じです。Python 版が作った `.gz` を Nim 版が段階2へ進めること、その逆もテストで確認しています。

## 6. テスト

```sh
nim c -r tests/test_bbs.nim   # Python 実装から生成した照合ベクトル 113 項目 (要: プロジェクトルートで実行)
python3 tests/archive_test.py # archive の段階1/2・restore・異常系 11 項目 (要: build.sh 済み)
python3 tests/port_test.py    # サーバーを立てての結合テスト 28 項目 (要: build.sh 済み)
python3 tests/interop_test.py # Python 版とデータフォルダを共用する相互運用テスト 12 項目 (隣に amezo-python が必要)
node tests/hide_test.js       # hide.js のテスト 28 項目 (要: jsdom)
```

## 7. 実装メモ

- 依存は nimcrypto のみ (vendor 同梱)。正規表現ライブラリ (PCRE) には依存しません (必要な照合はすべて手書き)。
- gzip は Nim 標準に zlib モジュールが無いため、システムの libz への薄い FFI で実装しています (`src/gz.nim`)。Python の `gzip` と相互に読み書きできます。
- CP932 の復号は iconv 経由で厳密に行い、Python の `cp932` が私用領域に対応づける 0xA0、0xFD–0xFF の4バイトだけを個別に対応づけています (`tests/vectors.json` の `to_utf8` で照合)。
- `flock` は Nim の `std/posix` に無いため、`sys/file.h` への宣言で使っています。Python 版との間でも同じファイルを同時に掴めます。
