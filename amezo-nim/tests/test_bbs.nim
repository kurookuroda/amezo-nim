# test_bbs.nim - bbs.nim のベクトルテスト。
# tests/vectors.json (Python 実装から生成) を読み、固定の秘密鍵で全セクションを照合する。
# 実行: プロジェクトのルートで `nim c -r tests/test_bbs.nim`
import std/[os, json, strutils, tables, base64]
import bbs
import gz

var okCount = 0
var ngCount = 0

proc chk(name: string, cond: bool, extra: string = "") =
  if cond:
    inc okCount
    echo "OK ", name
  else:
    inc ngCount
    echo "NG ", name, (if extra.len > 0: " " & extra else: "")

proc chkStr(name, got, want: string) =
  chk(name, got == want, "got=" & got & " want=" & want)

proc hexBytes(s: string): seq[byte] =
  result = @[]
  for i in countup(0, s.len - 2, 2):
    result.add(byte(parseHexInt(s[i .. i + 1])))

# vectors は chdir の前に読む (実行はプロジェクトルートから)
let vectors = parseJson(readFile("tests/vectors.json"))

let work = getTempDir() / ("amezo_bbs_test_" & $getCurrentProcessId())
if dirExists(work):
  removeDir(work)
createDir(work)
writeFile(work / "trip_secret.txt", repeat("11", 32) & "\n")
writeFile(work / "id_secret.txt", repeat("22", 32) & "\n")
writeFile(work / "key_secret.txt", repeat("33", 32) & "\n")
writeFile(work / "jump_secret.txt", repeat("44", 32) & "\n")
setCurrentDir(work)

let salt = hexBytes("00112233445566778899aabbccddeeff")

for pw, want in vectors["trip"].pairs:
  chkStr("trip: " & pw, makeTrip(pw), want.getStr())

let idNow = jstDateTime(2026, 10, 31, 12, 0, 0)
for key, want in vectors["id"].pairs:
  let idx = key.rfind('|')
  let ip = key[0 ..< idx]
  let board = key[idx + 1 ..< key.len]
  chkStr("id: " & key, makeId(ip, board, idNow), want.getStr())

for ip, want in vectors["ip_unit"].pairs:
  chkStr("ip_unit: " & ip, ipUnit(ip), want.getStr())

for pw, want in vectors["clean_trip"].pairs:
  chkStr("clean_trip: " & pw, cleanTripPassword(pw), want.getStr())

for s, want in vectors["escape"].pairs:
  chkStr("escape: " & s, htmlEscape(s), want.getStr())

for s, want in vectors["chars_len"].pairs:
  chk("chars_len: " & s, htmlCharsLen(s) == want.getInt(),
      "got=" & $htmlCharsLen(s))

for key, want in vectors["ccut"].pairs:
  let idx = key.rfind('|')
  let s = key[0 ..< idx]
  let n = parseInt(key[idx + 1 ..< key.len])
  chkStr("ccut: " & key, ccut(s, n), want.getStr())

let hv = vectors["hash"]
chkStr("hash: make", makeHash("adminpw", 1000, salt), hv["stored"].getStr())
chk("hash: verify_ok",
    verifyHash("adminpw", hv["stored"].getStr()) == hv["verify_ok"].getBool())
chk("hash: verify_ng",
    verifyHash("wrong", hv["stored"].getStr()) == hv["verify_ng"].getBool())

writeFile("cap.txt", "テストキャップ," & makeHash("capass", 1000, salt) & "\n")
let cv = vectors["cap"]
chk("cap: hit", isCap("テストキャップ", "capass") == cv["hit"].getBool())
chk("cap: miss_pw", isCap("テストキャップ", "x") == cv["miss_pw"].getBool())
chk("cap: miss_name", isCap("他人", "capass") == cv["miss_name"].getBool())

for u, want in vectors["jump_sign"].pairs:
  chkStr("jump_sign: " & u, jumpSign(u), want.getStr())

for s, want in vectors["b64url"].pairs:
  chkStr("b64url: " & s, b64urlEncode(s), want.getStr())
  let (okd, data) = b64urlDecode(want.getStr())
  chk("b64url decode: " & s, okd and data == s)

for u, want in vectors["url_valid"].pairs:
  chk("url_valid: " & u[0 ..< min(u.len, 30)],
      urlIsValid(u) == want.getBool())

for i, entry in vectors["linkify"].elems:
  chkStr("linkify jump " & $i, linkifyUrls(entry["in"].getStr(), true),
         entry["jump"].getStr())
  chkStr("linkify direct " & $i, linkifyUrls(entry["in"].getStr(), false),
         entry["direct"].getStr())

for hx, want in vectors["base32"].pairs:
  chkStr("base32: " & hx, base32EncodeBytes(hexBytes(hx)), want.getStr())

for s, want in vectors["key_normalize"].pairs:
  let (okn, canon) = keyNormalize(s)
  if want.kind == JNull:
    chk("key_normalize ng: " & s, not okn)
  else:
    chk("key_normalize: " & s, okn and canon == want.getStr(),
        "got=" & canon)

for s, want in vectors["key_display"].pairs:
  chkStr("key_display", keyDisplay(s), want.getStr())

for s, want in vectors["key_hash"].pairs:
  chkStr("key_hash", keyHash(s), want.getStr())

for key, want in vectors["pager"].pairs:
  let idx = key.find('|')
  let p = parseInt(key[0 ..< idx])
  let t = parseInt(key[idx + 1 ..< key.len])
  chkStr("pager: " & key, pagerHtml("main", p, t), want.getStr())

for b64, want in vectors["to_utf8"].pairs:
  let raw = base64.decode(b64)
  chkStr("to_utf8: " & b64, toUtf8(raw), want.getStr())

for s, want in vectors["strip_invisible"].pairs:
  chkStr("strip_invisible", stripInvisible(s), want.getStr())

# ---- config (入力は Python 版 unit_test.py のケースと同じ) ----
let cfgInputs = {
  "basic": "; c\nPOST_INTERVAL = 7 ; 行末\nMAX_THREADS = \"50\"\n" &
           "JUMP_ENABLED = off\nAMEZO = ＠テスト\n" &
           "TRUSTED_PROXIES[] = 127.0.0.1\nTRUSTED_PROXIES[] = ::1\n" &
           "URLBASE = http://example.com/\n",
  "empty_proxies": "TRUSTED_PROXIES =\n",
  "syntax": "POST_INTERVAL = 3\n[bad\n",
  "dup": "POST_INTERVAL = 3\nPOST_INTERVAL = 99999\nMAX_THREADS = 10\n",
  "bad_admin": "ADMIN = \"${HOME}\"\n",
  "bad_int": "POST_INTERVAL = 1.5\n",
  "unknown": "UNKNOWN_KEY = 1\n",
}.toTable

proc cfgMatches(got: CfgValue, want: JsonNode): bool =
  case want.kind
  of JInt:
    got.kind == cvInt and got.i == want.getInt()
  of JBool:
    got.kind == cvBool and got.b == want.getBool()
  of JString:
    got.kind == cvStr and got.s == want.getStr()
  of JArray:
    if got.kind != cvList or got.l.len != want.elems.len:
      return false
    for i, e in want.elems:
      if got.l[i] != e.getStr():
        return false
    return true
  else:
    false

for name, ini in cfgInputs.pairs:
  let path = "cfg_" & name & ".ini"
  writeFile(path, ini)
  let (values, errors) = configLoad(path)
  let wantPair = vectors["config"][name]
  let wantVals = wantPair[0]
  let wantErrs = wantPair[1]
  var okAll = values.len == wantVals.len
  if okAll:
    for k, wv in wantVals.pairs:
      if not values.hasKey(k) or not cfgMatches(values[k], wv):
        okAll = false
        break
  chk("config values: " & name, okAll)
  var okErr = errors.len == wantErrs.elems.len
  if okErr:
    for i, e in wantErrs.elems:
      if errors[i] != e.getStr():
        okErr = false
        break
  chk("config errors: " & name, okErr, "got=" & $errors)

# ---- gz の往復とストリーム ----
let gzSrc = "中身テスト123 gzip 圧縮"
chkStr("gz: roundtrip", gzUncompress(gzCompress(gzSrc)), gzSrc)
let bigSrc = repeat("あめぞう掲示板", 5000)
chkStr("gz: roundtrip big", gzUncompress(gzCompress(bigSrc)), bigSrc)
var corruptOk = false
try:
  var bad = gzCompress(gzSrc)
  bad[15] = char(ord(bad[15]) xor 0xFF)
  discard gzUncompress(bad)
except CatchableError:
  corruptOk = true
chk("gz: corrupt raises", corruptOk)
chk("gz: crc32", gzipCrc32("abc") == 891568578'u32)
block:
  let path = "stream_test.gz"
  var wf = open(path, fmWrite)
  var w = newGzWriter(wf, 6)
  w.write(bigSrc[0 ..< 100])
  w.write(bigSrc[100 ..< 3000])
  w.write(bigSrc[3000 ..< bigSrc.len])
  w.close()
  wf.close()
  var rf = open(path, fmRead)
  var r = newGzReader(rf)
  var back = ""
  while true:
    let chunk = r.readChunk()
    if chunk == "":
      break
    back.add(chunk)
  r.close()
  rf.close()
  chkStr("gz: stream roundtrip", back, bigSrc)

echo "== OK ", okCount, " / NG ", ngCount
try:
  setCurrentDir(getTempDir())
  removeDir(work)
except CatchableError:
  discard
if ngCount > 0:
  quit(1)
