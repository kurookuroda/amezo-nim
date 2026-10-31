#!/bin/sh
# amezo-nim のビルド: プロジェクトルートに CGI バイナリ (amezo.cgi など) と
# archive / server を作る。使い方: sh build.sh
cd "$(dirname "$0")" || exit 1
export PATH="$HOME/.nimble/bin:$PATH"
set -e
for t in amezo dai admin jump; do
  echo "nim c -> $t.cgi"
  nim c -d:release --path:src --path:vendor/nimcrypto -o:"$t.cgi" "src/$t.nim"
done
echo "nim c -> archive"
nim c -d:release --path:src --path:vendor/nimcrypto -o:archive src/archive.nim
echo "nim c -> server"
nim c -d:release --path:src --path:vendor/nimcrypto -o:server src/server.nim
echo "done."
