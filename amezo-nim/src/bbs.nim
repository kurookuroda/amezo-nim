# bbs.nim - あめぞう風掲示板の共通ライブラリ (amezo.py の main() 以外の移植)。
# ファイルパスは Python 版と同じく相対 ("./board/...")。CGI 側が起動時に
# アプリのフォルダへ chdir する前提。stdout に出すのは bbsError / redirect /
# resView の応答だけ。
import std/[os, strutils, unicode, tables, times, net, posix, algorithm]
import nimcrypto/[sha2, hmac, pbkdf2, hash]
import gz

# =========================================================================
# 設定 (既定値。applyConfig() が config.ini の値で上書きする)
# =========================================================================
const COPYRIGHT* = "<!--\n    Script for amezo-like BBS (Python Version)\n" &
    "    Original Copyright (C) 1999-2003 amezo_\n" &
    "    http://www17.big.or.jp/~amezo_/\n" &
    "    http://ame.x0.com/\n-->\n"

var AMEZO* = "＠あめぞう"
var URLBASE* = "http://ame.x0.com/"
var ADMIN* = "サポート"

var POST_INTERVAL* = 5
var GLOBAL_WINDOW* = 180        # 同じ IP の新規スレッド作成の間隔 (秒)。0 なら実質無制限
var MAX_THREADS* = 200          # この数を超えた古いスレッドは o数字.html に退避 (0 なら退避しない)
var JUMP_ENABLED* = true        # 投稿の URL を、署名つきの中継ページ (jump.cgi) 経由にする
var ARCHIVE_QUIET_SECONDS* = 600

const KAKO_FILE* = "kako.html"    # 退避したスレッド(過去ログ)の一覧ページ
const KAKO_LIST* = "kako.txt"     # 退避したスレッドの題名の一覧
const KAKO_SEP* = "<>"            # 題名はエスケープ済みなので <> は題名に現れない

var MAX_POST_BYTES* = 7500      # 送信全体の上限
var SUBJ_MAX* = 45              # 題名
var NAME_MAX* = 25              # 名前
var MAIL_MAX* = 50              # メール
var COMM_MAX* = 400             # 本文
var COMM_LINES_MAX* = 20        # 本文の改行の数
var PAGE_CACHE* = 10
const PER_PAGE* = 20            # 1ページに表示するスレッドの数
const HEADLINE_COUNT* = 100     # 見出し (HEAD LINE) の数
const TAIL_MIN_SIZE* = 262144   # このサイズを超えるスレッドは末尾だけ読む
const TAIL_CHUNK* = 131072      # 末尾から読む大きさ
var TRUSTED_PROXIES*: seq[string] = @["127.0.0.1", "::1"]
const DELCRYPTFILE* = "delpass.txt"

const HASH_SCHEME* = "pbkdf2_sha256"
var HASH_ITERATIONS* = 100000

const TRIP_SECRET_FILE* = "trip_secret.txt"
const ID_SECRET_FILE* = "id_secret.txt"
const ID_LEN* = 8
const SCRIPT_TAG* = "<script src=\"../hide.js\" defer></script>"
const ID_CTX* = "id:"           # ID 計算の接頭辞
const RL_CTX* = "rl:"           # 連続投稿制限 (global.mem) の接頭辞
const TRIP_PASS_MAX* = 100      # パスワードの最大文字数
const TRIP_MARK* = "◆"
const CAP_MARK* = "★"
const CAP_FILE* = "cap.txt"

# ---- 認証キー (鍵つきスレッド) ----
const KEY_SECRET_FILE* = "key_secret.txt"
const KEY_CTX* = "key:"         # 公開後に変えない
const KEYS_FILE* = "keys.txt"   # 板ごと: <板>/keys.txt
const KEY_ALPHABET* = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

# ---- 中継ページ (jump) ----
const JUMP_SECRET_FILE* = "jump_secret.txt"
const JUMP_CTX* = "jump:"       # 公開後に変えない
const JUMP_SIG_LEN* = 22        # 署名の長さ (base64url で22文字 = 132bit)
const URL_MAX_LEN* = 2000

const HEADER* = "Content-type: text/html; charset=UTF-8\r\n\r\n"

# =========================================================================
# 小物ユーティリティ
# =========================================================================

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len:
    result[i] = char(b[i])

const HexDigits = "0123456789abcdef"

proc toHexLower*(b: openArray[byte]): string =
  result = newStringOfCap(b.len * 2)
  for x in b:
    result.add(HexDigits[int(x) shr 4])
    result.add(HexDigits[int(x) and 15])

proc hexVal(c: char): int =
  case c
  of '0' .. '9': ord(c) - ord('0')
  of 'a' .. 'f': ord(c) - ord('a') + 10
  of 'A' .. 'F': ord(c) - ord('A') + 10
  else: -1

proc parseHexBytes(s: string): tuple[ok: bool, data: seq[byte]] =
  ## Python の bytes.fromhex 相当 (ASCII 空白は無視、壊れていれば ok=false)
  var digs = ""
  for c in s:
    if c in {' ', '\t', '\n', '\r', '\v', '\f'}:
      continue
    if hexVal(c) < 0:
      return (false, @[])
    digs.add(c)
  if digs.len mod 2 != 0:
    return (false, @[])
  result = (true, newSeq[byte](digs.len div 2))
  for i in 0 ..< result.data.len:
    result.data[i] = byte(hexVal(digs[2 * i]) * 16 + hexVal(digs[2 * i + 1]))

proc constTimeEq(a, b: string): bool =
  if a.len != b.len:
    return false
  var d = 0
  for i in 0 ..< a.len:
    d = d or (ord(a[i]) xor ord(b[i]))
  return d == 0

proc randomBytes(n: int): seq[byte] =
  result = newSeq[byte](n)
  if n == 0:
    return
  let f = open("/dev/urandom", fmRead)
  var got = 0
  while got < n:
    let r = f.readBuffer(addr result[got], n - got)
    if r <= 0:
      f.close()
      raise newException(CatchableError, "random source unavailable")
    got += r
  f.close()

proc isPySpace(cp: int): bool =
  ## Python の str.isspace() が真になる文字 (strip 用)
  case cp
  of 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x1C, 0x1D, 0x1E, 0x1F, 0x85,
     0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
    return true
  else:
    return 0x2000 <= cp and cp <= 0x200A

proc stripPy*(s: string): string =
  ## Python の str.strip() 相当 (両端の空白を落とす)
  let rs = s.toRunes()
  var a = 0
  var b = rs.len
  while a < b and isPySpace(int(rs[a])):
    inc a
  while b > a and isPySpace(int(rs[b - 1])):
    dec b
  if a == 0 and b == rs.len:
    return s
  result = ""
  for i in a ..< b:
    result.add($rs[i])

proc rstripCrLf(s: string): string =
  ## Python の rstrip('\r\n') 相当
  var n = s.len
  while n > 0 and s[n - 1] in {'\r', '\n'}:
    dec n
  return s[0 ..< n]

proc allDigits(s: string): bool =
  if s.len == 0:
    return false
  for c in s:
    if c notin {'0' .. '9'}:
      return false
  return true

proc isDigitsLen(s: string, mn: int, mx: int): bool =
  s.len >= mn and s.len <= mx and allDigits(s)

proc parseIntSafe(s: string): tuple[ok: bool, val: int64] =
  try:
    (true, parseBiggestInt(s))
  except ValueError:
    (false, 0)

proc padNum(n: int64, w: int): string =
  let s = $n
  if s.len >= w:
    return s
  return repeat('0', w - s.len) & s

proc utf8Lossy*(b: string): string =
  ## UTF-8 として読み、壊れた部分は U+FFFD にする (Python の errors='replace' 近似)
  var i = 0
  result = ""
  while i < b.len:
    let c = ord(b[i])
    if c < 0x80:
      result.add(b[i])
      inc i
      continue
    var size = 0
    var lo = 0x80
    var hi = 0xBF
    if c >= 0xC2 and c <= 0xDF:
      size = 2
    elif c == 0xE0:
      size = 3; lo = 0xA0
    elif c >= 0xE1 and c <= 0xEC:
      size = 3
    elif c == 0xED:
      size = 3; hi = 0x9F
    elif c >= 0xEE and c <= 0xEF:
      size = 3
    elif c == 0xF0:
      size = 4; lo = 0x90
    elif c >= 0xF1 and c <= 0xF3:
      size = 4
    elif c == 0xF4:
      size = 4; hi = 0x8F
    var ok = size > 0 and i + size <= b.len
    if ok:
      let c1 = ord(b[i + 1])
      if c1 < lo or c1 > hi:
        ok = false
      else:
        for j in 2 ..< size:
          let cj = ord(b[i + j])
          if cj < 0x80 or cj > 0xBF:
            ok = false
            break
    if ok:
      result.add(b[i ..< i + size])
      i += size
    else:
      result.add("\uFFFD")
      inc i

proc pyHtmlEscape(s: string): string =
  ## Python の html.escape(quote=True) 相当 (' は &#x27;)
  result = ""
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '"': result.add("&quot;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '\'': result.add("&#x27;")
    else: result.add(c)

# =========================================================================
# エラー / リダイレクト
# =========================================================================

proc bbsError*(msg: string) {.noreturn.} =
  stdout.write(HEADER)
  stdout.write(
    "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">" &
    "</head><body><h2>" & pyHtmlEscape(msg) & "</h2></body></html>")
  stdout.flushFile()
  quit(0)

proc redirect*(folder, indexName: string) {.noreturn.} =
  let target = pyHtmlEscape(folder & "/" & indexName)
  stdout.write("Status: 303 See Other\r\n")
  stdout.write("Location: ../" & target & "\r\n")
  stdout.write(HEADER)
  stdout.write(
    "<html><head><meta http-equiv=\"refresh\" content=\"0;url=../" & target &
    "\"></head><body>Redirecting to <a href=\"../" & target & "\">" & target &
    "</a>...</body></html>")
  stdout.flushFile()
  quit(0)

# =========================================================================
# 設定ファイル (config.ini)
# =========================================================================

proc isValidUtf8Strict(data: string): bool   # 実体はユーティリティ節

type
  CfgKind* = enum cvInt, cvBool, cvStr, cvList
  CfgValue* = object
    case kind*: CfgKind
    of cvInt: i*: int
    of cvBool: b*: bool
    of cvStr: s*: string
    of cvList: l*: seq[string]
  RawKind* = enum rvStr, rvList
  RawVal* = object
    case kind*: RawKind
    of rvStr: s*: string
    of rvList: l*: seq[string]
  CfgSpec = tuple[typ: string, def: CfgValue, mn: int, mx: int]

proc cfgInt(n: int): CfgValue = CfgValue(kind: cvInt, i: n)
proc cfgBool(v: bool): CfgValue = CfgValue(kind: cvBool, b: v)
proc cfgStr(v: string): CfgValue = CfgValue(kind: cvStr, s: v)
proc cfgList(v: seq[string]): CfgValue = CfgValue(kind: cvList, l: v)

proc configSchema*(): OrderedTable[string, CfgSpec] =
  ## 名前 => (型, 既定値, 最小, 最大)。最小・最大は、int なら値、text なら文字数、ips なら個数
  result = initOrderedTable[string, CfgSpec]()
  result["AMEZO"] = ("text", cfgStr("＠あめぞう"), 0, 40)
  result["URLBASE"] = ("url", cfgStr("http://ame.x0.com/"), 0, 200)
  result["ADMIN"] = ("text", cfgStr("サポート"), 1, 20)
  result["POST_INTERVAL"] = ("int", cfgInt(5), 0, 3600)
  result["GLOBAL_WINDOW"] = ("int", cfgInt(180), 0, 86400)
  result["MAX_THREADS"] = ("int", cfgInt(200), 0, 100000)
  result["PAGE_CACHE"] = ("int", cfgInt(10), 0, 3600)
  result["MAX_POST_BYTES"] = ("int", cfgInt(7500), 1000, 1000000)
  result["SUBJ_MAX"] = ("int", cfgInt(45), 1, 500)
  result["NAME_MAX"] = ("int", cfgInt(25), 1, 200)
  result["MAIL_MAX"] = ("int", cfgInt(50), 1, 500)
  result["COMM_MAX"] = ("int", cfgInt(400), 1, 10000)
  result["COMM_LINES_MAX"] = ("int", cfgInt(20), 1, 1000)
  result["HASH_ITERATIONS"] = ("int", cfgInt(100000), 1000, 5000000)
  result["TRUSTED_PROXIES"] = ("ips", cfgList(@["127.0.0.1", "::1"]), 0, 16)
  result["JUMP_ENABLED"] = ("bool", cfgBool(true), 0, 1)
  result["ARCHIVE_QUIET_SECONDS"] = ("int", cfgInt(600), 0, 604800)

proc isIp*(s: string): bool =
  try:
    discard parseIpAddress(s)
    return true
  except ValueError:
    return false

proc parseCfgInt(s0: string): tuple[ok: bool, val: int64] =
  ## Python の int 照合: -?\d{1,12} (全角数字も \d として受理されるので寄せる)
  var t = stripPy(s0)
  var neg = false
  if t.startsWith("-"):
    neg = true
    t = t[1 ..< t.len]
  if t.len < 1 or t.len > 12:
    return (false, 0)
  var n: int64 = 0
  for r in t.toRunes():
    let cp = int(r)
    var d = -1
    if cp >= ord('0') and cp <= ord('9'):
      d = cp - ord('0')
    elif cp >= 0xFF10 and cp <= 0xFF19:
      d = cp - 0xFF10
    if d < 0:
      return (false, 0)
    n = n * 10 + d
  return (true, if neg: -n else: n)

proc configCheckRaw*(typ: string, raw: RawVal, mn: int,
                     mx: int): tuple[ok: bool, val: CfgValue, reason: string] =
  ## 1つの値を検査する。通れば (true, 型を直した値)、外れれば (false, _, 理由)
  case typ
  of "int":
    if raw.kind != rvStr:
      return (false, cfgInt(0), "整数ではありません")
    let (okp, n) = parseCfgInt(raw.s)
    if not okp:
      return (false, cfgInt(0), "整数ではありません")
    if n < mn or n > mx:
      return (false, cfgInt(0), $mn & "〜" & $mx & " の範囲外です")
    return (true, cfgInt(int(n)), "")
  of "bool":
    let l = if raw.kind == rvStr: stripPy(raw.s).toLowerAscii() else: ""
    if l in ["1", "true", "yes", "on"]:
      return (true, cfgBool(true), "")
    if l in ["0", "false", "no", "off"]:
      return (true, cfgBool(false), "")
    return (false, cfgBool(false), "true / false ではありません")
  of "text":   # 画面にそのまま出す文字列。HTML や展開に使われうる文字は入れさせない
    if raw.kind != rvStr:
      return (false, cfgStr(""), "文字列ではありません")
    for r in raw.s.toRunes():
      let cp = int(r)
      if cp <= 0x1F or cp == 0x7F or cp in {ord('<'), ord('>'), ord('"'),
                                           ord('\''), ord('&'), ord('$'),
                                           ord('\\')}:
        return (false, cfgStr(""),
                "使えない文字 (制御文字 < > \" ' & $ \\) を含みます")
    let n = raw.s.runeLen()
    if n < mn or n > mx:
      return (false, cfgStr(""), $mn & "〜" & $mx & " 文字ではありません")
    return (true, cfgStr(raw.s), "")
  of "url":
    if raw.kind != rvStr or raw.s.len > mx:
      return (false, cfgStr(""),
              "http:// か https:// で始まる URL ではありません")
    let v = raw.s
    if v != "":
      var rest = ""
      if v.startsWith("https://"):
        rest = v[8 ..< v.len]
      elif v.startsWith("http://"):
        rest = v[7 ..< v.len]
      else:
        return (false, cfgStr(""),
                "http:// か https:// で始まる URL ではありません")
      if rest.len == 0 or rest[0] notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}:
        return (false, cfgStr(""),
                "http:// か https:// で始まる URL ではありません")
      for c in rest:
        if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '-', ':', '/',
                    '_'}:
          return (false, cfgStr(""),
                  "http:// か https:// で始まる URL ではありません")
    return (true, cfgStr(v), "")
  of "ips":
    if raw.kind == rvStr:
      if raw.s == "":
        return (true, cfgList(@[]), "")   # 「TRUSTED_PROXIES =」 は、どのプロキシも信用しない
      return (false, cfgList(@[]), "IP アドレスの並びではありません")
    if raw.l.len > mx:
      return (false, cfgList(@[]), "IP アドレスの並びではありません")
    var outList: seq[string] = @[]
    for ip in raw.l:
      let t = stripPy(ip)
      if not isIp(t):
        return (false, cfgList(@[]), "IP アドレスではない値があります")
      outList.add(t)
    return (true, cfgList(outList), "")
  else:
    return (false, cfgInt(0), "未対応の型です")

proc parseIniRaw(text: string): tuple[ok: bool,
                                      raw: OrderedTable[string, RawVal]] =
  ## INI の生の値を読む (展開はしない)。書き方の誤りがあれば ok=false。
  ## 同じキーが複数あれば最後の値 (KEY[] は積む)。
  result = (true, initOrderedTable[string, RawVal]())
  for line in text.splitLines():
    let s = stripPy(line)
    if s == "" or s.startsWith(";") or s.startsWith("#"):
      continue
    if s.startsWith("[") or '=' notin s:
      return (false, initOrderedTable[string, RawVal]())
    let eq = s.find('=')
    var k = stripPy(s[0 ..< eq])
    var v = stripPy(s[eq + 1 ..< s.len])
    if k == "":
      return (false, initOrderedTable[string, RawVal]())
    var isList = false
    if k.endsWith("[]"):
      isList = true
      k = stripPy(k[0 ..< k.len - 2])
    if v.startsWith("\""):
      let e = v.find('"', 1)
      if e > 0:
        v = v[1 ..< e]
    else:
      # 行末コメント: 空白/タブ + ';' で切る
      var cut = -1
      for i in 0 ..< v.len - 1:
        if v[i] in {' ', '\t'} and v[i + 1] == ';':
          cut = i
          break
      if cut >= 0:
        v = stripPy(v[0 ..< cut])
    if isList:
      if result.raw.hasKey(k):
        let prev = result.raw[k]
        if prev.kind == rvList:
          var nl = prev.l
          nl.add(v)
          result.raw[k] = RawVal(kind: rvList, l: nl)
        else:
          result.raw[k] = RawVal(kind: rvList, l: @[prev.s, v])
      else:
        result.raw[k] = RawVal(kind: rvList, l: @[v])
    else:
      result.raw[k] = RawVal(kind: rvStr, s: v)

proc configLoad*(file: string): tuple[values: OrderedTable[string, CfgValue],
                                      errors: seq[string]] =
  ## config.ini を読み、検査を通った値だけを返す
  result = (initOrderedTable[string, CfgValue](), @[])
  if not fileExists(file):
    return
  var text: string
  try:
    text = readFile(file)
  except CatchableError:
    return (initOrderedTable[string, CfgValue](),
            @["読み込めません (書き方の誤り)"])
  if not isValidUtf8Strict(text):
    return (initOrderedTable[string, CfgValue](),
            @["読み込めません (書き方の誤り)"])
  let (okParse, raw) = parseIniRaw(text)
  if not okParse:
    return (initOrderedTable[string, CfgValue](),
            @["読み込めません (書き方の誤り)"])
  let schema = configSchema()
  for k, v in raw.pairs:
    if k notin schema:
      result.errors.add("不明なキー: " & k)
      continue
    let spec = schema[k]
    let (okc, val, reason) = configCheckRaw(spec.typ, v, spec.mn, spec.mx)
    if okc:
      result.values[k] = val
    else:
      result.errors.add(k & ": " & reason)

proc applyConfig*() =
  ## config.ini を読み、検査を通った値をグローバルへ反映する。
  ## 無視した値と理由は標準エラーに出る。
  let (values, errors) = configLoad("config.ini")
  for e in errors:
    stderr.writeLine("amezo: config.ini の " & e &
                     " (無視して、既定値を使います)")
  if fileExists("config.php"):
    stderr.writeLine("amezo: config.php は読み込みません " &
                     "(実行される形式の設定は使いません)。" &
                     "config.ini に移してください")
  for k, v in values.pairs:
    case k
    of "AMEZO": AMEZO = v.s
    of "URLBASE": URLBASE = v.s
    of "ADMIN": ADMIN = v.s
    of "POST_INTERVAL": POST_INTERVAL = v.i
    of "GLOBAL_WINDOW": GLOBAL_WINDOW = v.i
    of "MAX_THREADS": MAX_THREADS = v.i
    of "PAGE_CACHE": PAGE_CACHE = v.i
    of "MAX_POST_BYTES": MAX_POST_BYTES = v.i
    of "SUBJ_MAX": SUBJ_MAX = v.i
    of "NAME_MAX": NAME_MAX = v.i
    of "MAIL_MAX": MAIL_MAX = v.i
    of "COMM_MAX": COMM_MAX = v.i
    of "COMM_LINES_MAX": COMM_LINES_MAX = v.i
    of "HASH_ITERATIONS": HASH_ITERATIONS = v.i
    of "TRUSTED_PROXIES": TRUSTED_PROXIES = v.l
    of "JUMP_ENABLED": JUMP_ENABLED = v.b
    of "ARCHIVE_QUIET_SECONDS": ARCHIVE_QUIET_SECONDS = v.i
    else: discard


# =========================================================================
# ユーティリティ関数
# =========================================================================

proc isValidUtf8Strict(data: string): bool =
  ## UTF-8 として正しいか (サロゲートや範囲外の符号化も壊れているとみなす)
  var i = 0
  while i < data.len:
    let b = ord(data[i])
    if b < 0x80:
      inc i
      continue
    var need = 0
    var lo2 = 0x80
    var hi2 = 0xBF
    if 0xC2 <= b and b <= 0xDF:
      need = 1
    elif b == 0xE0:
      need = 2
      lo2 = 0xA0
    elif 0xE1 <= b and b <= 0xEC:
      need = 2
    elif b == 0xED:
      need = 2
      hi2 = 0x9F              # サロゲート範囲を弾く
    elif 0xEE <= b and b <= 0xEF:
      need = 2
    elif b == 0xF0:
      need = 3
      lo2 = 0x90
    elif 0xF1 <= b and b <= 0xF3:
      need = 3
    elif b == 0xF4:
      need = 3
      hi2 = 0x8F
    else:
      return false
    if i + need >= data.len:
      return false
    let b2 = ord(data[i + 1])
    if b2 < lo2 or b2 > hi2:
      return false
    for k in 2 .. need:
      let bk = ord(data[i + k])
      if bk < 0x80 or bk > 0xBF:
        return false
    i += need + 1
  return true

# CP932 の厳密なデコード (iconv を直接使い、変換できないバイト列は失敗にする)。
# Python の cp932 コーデックは単独バイト 0xA0, 0xFD-0xFF を私用領域
# U+F8F0-U+F8F3 に対応づけるが glibc の iconv はエラーにするので、
# その4バイトだけは文字の区切りで切り分けて自前で対応づける。
proc iconvOpen(tocode, fromcode: cstring): pointer {.
    importc: "iconv_open", header: "<iconv.h>".}
proc iconvConv(cd: pointer, inbuf: ptr ptr char, inbytesleft: ptr csize_t,
               outbuf: ptr ptr char, outbytesleft: ptr csize_t): csize_t {.
    importc: "iconv", header: "<iconv.h>".}
proc iconvClose(cd: pointer): cint {.importc: "iconv_close",
    header: "<iconv.h>".}

proc iconvCp932Strict(seg: string): tuple[ok: bool, text: string] =
  if seg.len == 0:
    return (true, "")
  let cd = iconvOpen("UTF-8", "CP932")
  if cd == nil:
    return (false, "")
  defer:
    discard iconvClose(cd)
  var outStr = newString(seg.len * 3 + 16)
  var inPtr: ptr char = cast[ptr char](seg.cstring)
  var inLeft = csize_t(seg.len)
  var outPtr: ptr char = cast[ptr char](outStr.cstring)
  var outLeft = csize_t(outStr.len)
  let r = iconvConv(cd, addr inPtr, addr inLeft, addr outPtr, addr outLeft)
  if r == csize_t(-1) or inLeft != 0:
    return (false, "")
  outStr.setLen(outStr.len - int(outLeft))
  return (true, outStr)

proc cp932Decode(data: string): tuple[ok: bool, text: string] =
  var outText = ""
  var seg = ""
  var i = 0
  while i < data.len:
    let b = ord(data[i])
    if (0x81 <= b and b <= 0x9F) or (0xE0 <= b and b <= 0xFC):
      # 2バイト文字: 後続バイトの範囲も Python のコーデックに合わせて確かめる
      if i + 1 >= data.len:
        return (false, "")
      let t = ord(data[i + 1])
      if not ((0x40 <= t and t <= 0x7E) or (0x80 <= t and t <= 0xFC)):
        return (false, "")
      seg.add(data[i])
      seg.add(data[i + 1])
      i += 2
    elif b == 0xA0 or b == 0xFD or b == 0xFE or b == 0xFF:
      let (okf, txt) = iconvCp932Strict(seg)
      if not okf:
        return (false, "")
      outText.add(txt)
      seg = ""
      outText.add(case b
                  of 0xA0: "\uF8F0"
                  of 0xFD: "\uF8F1"
                  of 0xFE: "\uF8F2"
                  else: "\uF8F3")
      inc i
    else:
      seg.add(data[i])
      inc i
  let (okf, txt) = iconvCp932Strict(seg)
  if not okf:
    return (false, "")
  outText.add(txt)
  return (true, outText)

proc toUtf8*(b: string): string =
  if b.len == 0:
    return ""
  if isValidUtf8Strict(b):
    return b
  let (okc, text) = cp932Decode(b)
  if okc:
    return text
  result = ""
  for c in b:
    if ord(c) < 0x80:
      result.add(c)

proc isInvisible(cp: int): bool =
  if (0x80 <= cp and cp <= 0x9F) or (0x180B <= cp and cp <= 0x180E) or
     (0x2028 <= cp and cp <= 0x202E) or (0x2060 <= cp and cp <= 0x206F) or
     (0xFFF9 <= cp and cp <= 0xFFFB):
    return true
  case cp
  of 0xAD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x200B,
     0x200C, 0x200E, 0x200F, 0x3164, 0xFEFF, 0xFFA0:
    return true
  else:
    return false

proc stripInvisible*(s: string): string =
  result = ""
  for r in s.toRunes():
    if not isInvisible(int(r)):
      result.add($r)

proc htmlEscape*(s: string): string =
  result = ""
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '"': result.add("&quot;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '\'': result.add("&#39;")
    else: result.add(c)

const EntityStrs = ["&amp;", "&quot;", "&lt;", "&gt;", "&#39;"]

proc entityTokens(s: string): seq[string] =
  ## html_chars_len / ccut 用: エンティティを1文字として数える分割
  let rs = s.toRunes()
  result = @[]
  var i = 0
  while i < rs.len:
    var matched = 0
    if rs[i] == Rune('&'):
      for e in EntityStrs:
        let er = e.toRunes()
        if i + er.len <= rs.len and rs[i ..< i + er.len] == er:
          matched = er.len
          break
    if matched > 0:
      var tok = ""
      for j in i ..< i + matched:
        tok.add($rs[j])
      result.add(tok)
      i += matched
    else:
      result.add($rs[i])
      inc i

proc htmlCharsLen*(s: string): int =
  return entityTokens(s).len

proc ccut*(s: string, maxLen: int): string =
  let toks = entityTokens(s)
  result = ""
  let n = min(maxLen, toks.len)
  if n <= 0:
    return ""
  for i in 0 ..< n:
    result.add(toks[i])

proc urlDecode*(s: string): string =
  var b = ""
  for r in s.toRunes():
    if int(r) <= 0xFF:
      b.add(char(int(r)))
  b = b.replace('+', ' ')
  var outb = ""
  var i = 0
  while i < b.len:
    if b[i] == '%' and i + 2 < b.len and hexVal(b[i + 1]) >= 0 and
        hexVal(b[i + 2]) >= 0:
      outb.add(char(hexVal(b[i + 1]) * 16 + hexVal(b[i + 2])))
      i += 3
    else:
      outb.add(b[i])
      inc i
  return toUtf8(outb)

proc clientIp*(): string =
  let raddr = getEnv("REMOTE_ADDR", "")
  if raddr notin TRUSTED_PROXIES:
    return raddr
  let cf = getEnv("HTTP_CF_CONNECTING_IP", "")
  if cf.len > 0 and isIp(cf):
    return cf
  let parts = getEnv("HTTP_X_FORWARDED_FOR", "").split(',')
  var xff: seq[string] = @[]
  for p in parts:
    xff.add(stripPy(p))
  if xff.len > 0 and isIp(xff[^1]):
    return xff[^1]
  return raddr

# ---- パスワードハッシュ (admin からも使う) --------------------------------

proc hmacSha256(key: openArray[byte], msg: string): seq[byte] =
  let h = hmac(sha256, key, msg)
  result = newSeq[byte](h.data.len)
  for i in 0 ..< h.data.len:
    result[i] = h.data[i]

proc makeHash*(password: string, iterations: int = -1,
               salt: seq[byte] = @[]): string =
  let iters = if iterations < 0: HASH_ITERATIONS else: iterations
  let slt = if salt.len == 0: randomBytes(16) else: salt
  let dk = pbkdf2(sha256, password, slt, iters, 32)
  return HASH_SCHEME & "$" & $iters & "$" & toHexLower(slt) & "$" &
         toHexLower(dk)

proc verifyHash*(password, stored: string): bool =
  let parts = stored.strip().split('$')
  if parts.len != 4 or parts[0] != HASH_SCHEME:
    return false
  let (okI, iters64) = parseIntSafe(parts[1])
  if not okI or iters64 < 1 or iters64 > 5000000:
    return false
  let (okS, salt) = parseHexBytes(parts[2])
  let (okE, expected) = parseHexBytes(parts[3])
  if not okS or not okE:
    return false
  let dk = pbkdf2(sha256, password, salt, int(iters64), 32)
  if dk.len != expected.len:
    return false
  return constTimeEq(strOf(dk), strOf(expected))

# ---- トリップ / キャップ -----------------------------------------------------

proc readKeyFile(path: string): seq[byte] =
  try:
    let s = stripPy(readFile(path))
    if s.len == 64:
      var allHex = true
      for c in s:
        if c notin {'0' .. '9', 'a' .. 'f'}:
          allHex = false
          break
      if allHex:
        let (okh, data) = parseHexBytes(s)
        if okh:
          return data
  except CatchableError:
    discard
  return @[]

proc loadSecret*(path: string): seq[byte] =
  ## 秘密鍵 (32バイト) をファイル path から読む。無ければ作る。
  ## 同時に作られても、最初に置かれた鍵が全員に使われるよう createHardlink で置く。
  ## どうしても保存できないときは空 (鍵が投稿のたびに変わってしまうので、使わせない)。
  let k0 = readKeyFile(path)
  if k0.len > 0:
    return k0
  let key = randomBytes(32)
  let data = toHexLower(key) & "\n"
  let tmp = path & ".tmp" & $getCurrentProcessId()
  defer:
    try:
      removeFile(tmp)
    except CatchableError:
      discard
  try:
    let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_EXCL,
                        Mode(0o600))
    if fd >= 0:
      discard posix.write(fd, data.cstring, data.len)
      discard posix.close(fd)
      var linked = true
      var linkErr = 0
      try:
        createHardlink(tmp, path)
      except OSError as e:
        linked = false
        linkErr = int(e.errorCode)
      if linked:
        discard
      elif linkErr == int(EEXIST):
        let other = readKeyFile(path)
        if other.len > 0:
          return other
        moveFile(tmp, path)      # 壊れた鍵ファイルは置き換える
      else:
        # ハードリンクが使えない環境: 最終のファイルを直接 (既にあれば失敗する形で) 作る
        let fd2 = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL,
                             Mode(0o600))
        if fd2 >= 0:
          discard posix.write(fd2, data.cstring, data.len)
          discard posix.close(fd2)
        elif errno == EEXIST:
          var done = false
          for _ in 1 .. 20:                # 他のプロセスが書いている途中かもしれないので少し待つ
            os.sleep(50)
            let other = readKeyFile(path)
            if other.len > 0:
              return other
          if not done:
            moveFile(tmp, path)  # 壊れたままなら置き換える
  except CatchableError:
    discard
  return readKeyFile(path)

proc cleanTripPassword*(password: string): string =
  ## 空白を除き、全角の英数字・記号を半角にそろえ、長さを制限する
  var rs: seq[Rune] = @[]
  for r in password.toRunes():
    let cp = int(r)
    if cp == ord(' ') or cp == 0x3000:
      continue
    if 0xFF01 <= cp and cp <= 0xFF5E:
      rs.add(Rune(cp - 0xFEE0))
    else:
      rs.add(r)
  if rs.len > TRIP_PASS_MAX:
    rs = rs[0 ..< TRIP_PASS_MAX]
  result = ""
  for r in rs:
    result.add($r)

const B64Std = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" &
               "0123456789+/"

proc b64EncodeStd(b: openArray[byte]): string =
  result = ""
  var i = 0
  while i + 3 <= b.len:
    let n = (int(b[i]) shl 16) or (int(b[i + 1]) shl 8) or int(b[i + 2])
    result.add(B64Std[(n shr 18) and 63])
    result.add(B64Std[(n shr 12) and 63])
    result.add(B64Std[(n shr 6) and 63])
    result.add(B64Std[n and 63])
    i += 3
  let rem = b.len - i
  if rem == 1:
    let n = int(b[i]) shl 16
    result.add(B64Std[(n shr 18) and 63])
    result.add(B64Std[(n shr 12) and 63])
    result.add("==")
  elif rem == 2:
    let n = (int(b[i]) shl 16) or (int(b[i + 1]) shl 8)
    result.add(B64Std[(n shr 18) and 63])
    result.add(B64Std[(n shr 12) and 63])
    result.add(B64Std[(n shr 6) and 63])
    result.add("=")

proc makeTrip*(password: string): string =
  ## パスワードからトリップの10文字を作る。パスワードが空なら ""
  let pw = cleanTripPassword(password)
  if pw == "":
    return ""
  let key = loadSecret(TRIP_SECRET_FILE)
  if key.len == 0:
    bbsError("トリップ用の鍵を保存できません.")
  let digest = hmacSha256(key, pw)
  return b64EncodeStd(digest)[0 ..< 10].replace('+', '.').replace('/', '_')

proc ipUnit*(ip: string): string =
  ## IPv6 は上位64bitでまとめる (下位は端末が勝手に変えるので)。IPv4 はそのまま。
  if ':' in ip:
    try:
      let a = parseIpAddress(ip)
      if a.family == IpAddressFamily.IPv6:
        return toHexLower(a.address_v6[0 ..< 8])
    except ValueError:
      return ip
  return ip

proc idKey*(): seq[byte] =
  let key = loadSecret(ID_SECRET_FILE)
  if key.len == 0:
    bbsError("ID用の鍵を保存できません.")
  return key

proc jstNow*(): DateTime =
  ## 日本時間の壁時計 (OS のタイムゾーンに依存しない固定 +9 時間)
  return (getTime() + initDuration(hours = 9)).utc()

proc jstDateTime*(y, mo, d, h, mi, s: int): DateTime =
  return dateTime(y, Month(mo), MonthdayRange(d), HourRange(h),
                  MinuteRange(mi), SecondRange(s), 0, utc())

proc makeId*(ip, board: string, now: DateTime): string =
  ## ID (8文字)。now は日本時間の日時。日付が変わると変わる。
  let msg = ID_CTX & ipUnit(ip) & "|" &
            padNum(now.year, 4) & padNum(ord(now.month), 2) &
            padNum(now.monthday, 2) & "|" & board
  let digest = hmacSha256(idKey(), msg)
  return b64EncodeStd(digest)[0 ..< ID_LEN].replace('+', '.').replace('/',
      '_')

proc isCap*(nameEscaped, password: string): bool =
  ## 名前とパスワードが cap.txt の組と一致するか (名前が一致したときだけ重い計算をする)
  if password == "":
    return false
  try:
    for lineRaw in readFile(CAP_FILE).splitLines():
      let line = rstripCrLf(lineRaw)
      if line == "" or line.startsWith("#") or ',' notin line:
        continue
      let idx = line.rfind(',')
      let capName = line[0 ..< idx]
      let stored = line[idx + 1 ..< line.len]
      var stripped = ""
      for r in capName.toRunes():
        let cp = int(r)
        if cp == ord(' ') or cp == 0x3000 or cp == 0x200D:
          continue
        stripped.add($r)
      if htmlEscape(stripped) == nameEscaped and
          verifyHash(password, stored):
        return true
  except CatchableError:
    discard
  return false

proc loadDelcrypt*(): string =
  try:
    return stripPy(readFile(DELCRYPTFILE))
  except CatchableError:
    return ""


# ---- flock (std/posix に無いので importc で宣言) ----------------------------

const LOCK_EX = 2
const LOCK_NB = 4
const LOCK_UN = 8

proc c_flock(fd: cint, op: cint): cint {.importc: "flock",
    header: "<sys/file.h>".}

proc lockFile*(f: File) =
  discard c_flock(cint(f.getFileHandle()), LOCK_EX)

proc tryLockFile*(f: File): bool =
  return c_flock(cint(f.getFileHandle()), LOCK_EX or LOCK_NB) == 0

proc unlockFile*(f: File) =
  discard c_flock(cint(f.getFileHandle()), LOCK_UN)

# ---- 板処理・制限 -----------------------------------------------------------

proc isBoard*(folder: string): bool =
  try:
    for line in readFile("./blist.txt").splitLines():
      if line.len > 0:
        let idx = line.find(',')
        let head = if idx < 0: line else: line[0 ..< idx]
        if head == folder:
          return true
  except CatchableError:
    discard
  return false

proc postIntervalLeft*(folder: string): int =
  if POST_INTERVAL <= 0:
    return 0
  var last: int64 = 0
  try:
    let content = stripPy(readFile("./" & folder & "/lasttime.txt"))
    if allDigits(content):
      let (okp, v) = parseIntSafe(content)
      if okp:
        last = v
  except CatchableError:
    discard
  let left = int64(POST_INTERVAL) - (getTime().toUnix() - last)
  return if left > 0: int(left) else: 0

proc touchLasttime*(folder: string) =
  if POST_INTERVAL <= 0:
    return
  try:
    writeFile("./" & folder & "/lasttime.txt", $getTime().toUnix())
  except CatchableError:
    discard

proc readAllFd(fd: cint): string =
  result = ""
  var buf = newString(8192)
  while true:
    let r = posix.read(fd, cast[pointer](buf.cstring), buf.len)
    if r <= 0:
      break
    result.add(buf[0 ..< r])

proc writeAllFd(fd: cint, s: string) =
  var off = 0
  while off < s.len:
    let w = posix.write(fd, cast[pointer](cast[int](s.cstring) + off),
                        s.len - off)
    if w <= 0:
      break
    off += w

proc checkGlobalIp*(ip: string) =
  ## 同じ接続元の新規スレッドを GLOBAL_WINDOW 秒止める。IP は保存せず、鍵つきハッシュで覚える。
  let who = toHexLower(hmacSha256(idKey(), RL_CTX & ipUnit(ip)))[0 ..< 24]
  let fd = posix.open("global.mem", O_RDWR or O_CREAT, Mode(0o600))
  if fd < 0:
    return
  defer:
    discard posix.close(fd)
  discard c_flock(fd, LOCK_EX)
  let now = getTime().toUnix()
  var iplist = initOrderedTable[string, int64]()
  for line in splitLines(readAllFd(fd)):
    let parts = strutils.splitWhitespace(line)
    if parts.len == 2 and allDigits(parts[1]):
      let (okp, t) = parseIntSafe(parts[1])
      if okp and now - t < int64(GLOBAL_WINDOW):
        iplist[parts[0]] = t
  if iplist.hasKey(who):
    let remain = int64(GLOBAL_WINDOW) - (now - iplist[who])
    bbsError("あと " & $remain & " 秒たってから投稿してください")
  iplist[who] = now
  discard posix.lseek(fd, 0, SEEK_SET)
  discard posix.ftruncate(fd, 0)
  var buf = ""
  for k, v in iplist.pairs:
    buf.add(k & " " & $v & "\n")
  writeAllFd(fd, buf)

# ---- 過去ログの判定 ---------------------------------------------------------

proc archivedPath*(folder, name: string): string =
  ## 過去ログ (退避済みのスレッド) の実体のパス。name は 'o数字.html'。
  ## 平文があれば平文、無ければ .gz。どちらも無ければ ""。
  let p = "./" & folder & "/" & name
  if fileExists(p):
    return p
  return if fileExists(p & ".gz"): p & ".gz" else: ""

proc archivedExists*(folder, res: string): bool =
  ## この番号のスレッドが、過去ログとして (平文でも .gz でも) 残っているか
  return allDigits(res) and archivedPath(folder, "o" & res & ".html") != ""

proc threadMissing*(folder, res, verb: string) {.noreturn.} =
  ## スレッドが見つからないとき。過去ログに退避済みなら、その旨を知らせる
  if archivedExists(folder, res):
    bbsError("このスレッドは過去ログになったため" & verb & "できません.")
  bbsError("スレッドがありません.")

# ---- 中継ページ (jump) の署名 ------------------------------------------------

const B64Url = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" &
               "0123456789-_"

proc b64urlEncode*(b: string): string =
  let bytes = bytesOf(b)
  result = ""
  var i = 0
  while i + 3 <= bytes.len:
    let n = (int(bytes[i]) shl 16) or (int(bytes[i + 1]) shl 8) or
            int(bytes[i + 2])
    result.add(B64Url[(n shr 18) and 63])
    result.add(B64Url[(n shr 12) and 63])
    result.add(B64Url[(n shr 6) and 63])
    result.add(B64Url[n and 63])
    i += 3
  let rem = bytes.len - i
  if rem == 1:
    let n = int(bytes[i]) shl 16
    result.add(B64Url[(n shr 18) and 63])
    result.add(B64Url[(n shr 12) and 63])
  elif rem == 2:
    let n = (int(bytes[i]) shl 16) or (int(bytes[i + 1]) shl 8)
    result.add(B64Url[(n shr 18) and 63])
    result.add(B64Url[(n shr 12) and 63])
    result.add(B64Url[(n shr 6) and 63])

proc b64urlVal(c: char): int =
  case c
  of 'A' .. 'Z': ord(c) - ord('A')
  of 'a' .. 'z': ord(c) - ord('a') + 26
  of '0' .. '9': ord(c) - ord('0') + 52
  of '-': 62
  of '_': 63
  else: -1

proc b64urlDecode*(s: string): tuple[ok: bool, data: string] =
  ## base64url を文字列に戻す。文字種が違う・形が壊れていれば ok=false
  if s.len == 0:
    return (false, "")
  for c in s:
    if b64urlVal(c) < 0:
      return (false, "")
  if s.len mod 4 == 1:
    return (false, "")
  var outb = ""
  var acc = 0
  var nbits = 0
  for c in s:
    acc = (acc shl 6) or b64urlVal(c)
    nbits += 6
    if nbits >= 8:
      nbits -= 8
      outb.add(char((acc shr nbits) and 0xFF))
  return (true, outb)

proc urlIsValid*(url: string): bool =
  ## 中継ページに渡してよい URL か (http/https、ホスト名は英数字か [ で始まる、使える文字は ASCII の URL 文字だけ)
  if url == "" or url.len > URL_MAX_LEN:
    return false
  var rest = ""
  if url.startsWith("https://"):
    rest = url[8 ..< url.len]
  elif url.startsWith("http://"):
    rest = url[7 ..< url.len]
  else:
    return false
  if rest.len == 0:
    return false
  let c0 = rest[0]
  if not (c0 in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'} or c0 == '['):
    return false
  const RestChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '.', '_',
      '~', ':', '/', '?', '#', '[', ']', '@', '!', '$', '*', '+', ',', ';',
      '=', '%', '(', ')', '\'', '&'}
  for c in rest:
    if c notin RestChars:
      return false
  return true

proc jumpSecretKey(): seq[byte] =
  let key = loadSecret(JUMP_SECRET_FILE)
  if key.len == 0:
    bbsError("中継用の鍵を保存できません.")
  return key

proc jumpSign*(url: string): string =
  ## URL の署名: HMAC-SHA256(中継用の秘密鍵, 'jump:' + URL) の先頭132bit
  let digest = hmacSha256(jumpSecretKey(), JUMP_CTX & url)
  return b64urlEncode(strOf(digest))[0 ..< JUMP_SIG_LEN]

proc jumpVerify*(url, sig: string): bool =
  return urlIsValid(url) and constTimeEq(jumpSign(url), sig)

proc jumpHref*(url: string): string =
  ## スレッド HTML に書く中継リンクの href (板のフォルダの中から見た相対パス)
  return "../jump.cgi?u=" & b64urlEncode(url) & "&amp;s=" & jumpSign(url)

proc startsAt(s, sub: string, pos: int): bool =
  return pos + sub.len <= s.len and s[pos ..< pos + sub.len] == sub

proc isLinkChar(c: char): bool =
  const LinkChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '.', '_',
      '~', ':', '/', '?', '#', '[', ']', '@', '!', '$', '*', '+', ',', ';',
      '=', '%', '(', ')'}
  return c in LinkChars

proc linkifyRepl(m0: string, jump: bool): string =
  var dsp = m0
  var tail = ""
  while dsp.len > 0:
    var cut = 0
    if dsp.endsWith("&amp;") or dsp.endsWith("&#39;"):
      cut = 5
    else:
      let c = dsp[^1]
      if c in {'.', ',', ';', ':', '!', '?', '('}:
        cut = 1
      elif c == ')' and dsp.count(')') > dsp.count('('):
        cut = 1
      elif c == ']' and dsp.count(']') > dsp.count('['):
        cut = 1
      else:
        break
    if cut == 0:
      break
    tail = dsp[dsp.len - cut ..< dsp.len] & tail
    dsp = dsp[0 ..< dsp.len - cut]
  let url = dsp.replace("&amp;", "&").replace("&#39;", "'")
  if not urlIsValid(url):
    return m0
  let href = if jump: jumpHref(url) else: htmlEscape(url)
  return "<a href=\"" & href &
         "\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">" & dsp &
         "</a>" & tail

proc linkifyUrls*(escaped: string, jump: bool): string =
  ## エスケープ済みの本文から URL を探して、リンクにする。
  ## - URL に使える ASCII の文字と、エスケープされた &amp; &#39; だけを URL とみなす
  ## - 末尾の . , ; : ! ? ( と、対応のない ) ] は URL に含めない
  ## jump が true なら署名つきの中継ページ、false なら直リンク。
  result = ""
  var i = 0
  let n = escaped.len
  while i < n:
    var plen = 0
    if startsAt(escaped, "https://", i):
      plen = 8
    elif startsAt(escaped, "http://", i):
      plen = 7
    if plen == 0:
      result.add(escaped[i])
      inc i
      continue
    var j = i + plen
    var groups = 0
    while j < n:
      if startsAt(escaped, "&amp;", j):
        j += 5
        inc groups
      elif startsAt(escaped, "&#39;", j):
        j += 5
        inc groups
      elif isLinkChar(escaped[j]):
        inc j
        inc groups
      else:
        break
    if groups == 0:
      result.add(escaped[i])
      inc i
      continue
    result.add(linkifyRepl(escaped[i ..< j], jump))
    i = j

proc linkifyUrlsAuto*(escaped: string): string =
  ## JUMP_ENABLED に従うリンク化
  return linkifyUrls(escaped, JUMP_ENABLED)

proc replyForm*(res: string, links: string = "",
                locked: bool = false): string =
  ## レス用フォーム (1行で返す)。鍵つきスレッドは認証キーの欄が付く
  result = "<form method=post action=\"../amezo.cgi\" class=\"post\">" &
    "<input type=hidden name=\"res\" value=\"" & res & "\">" &
    "<div class=\"row\">投稿者 <input type=text name=\"name\" size=20> " &
    "メール <input type=text name=\"mail\" size=20 maxlength=50></div>"
  if locked:
    result.add("<div class=\"row\">🔒 認証キー " &
      "<input type=password name=\"key\" size=32 autocomplete=off required>" &
      " このスレッドは認証キーがないと書き込めません</div>")
  result.add("<textarea name=\"comm\" rows=4 cols=70 maxlength=400></textarea>" &
    "<div class=\"row\"><input type=submit value=\"↑へのレスカキコ\"></div>" &
    links & "</form>")

# ---- 認証キー (鍵つきスレッド) ----------------------------------------------

proc threadIsLocked*(folder, res: string): bool =
  return fileExists("./" & folder & "/" & res & ".lock")

proc base32EncodeBytes*(b: seq[byte]): string =
  result = ""
  var bits = 0
  var buf = 0
  for ch in b:
    buf = (buf shl 8) or int(ch)
    bits += 8
    while bits >= 5:
      bits -= 5
      result.add(KEY_ALPHABET[(buf shr bits) and 31])
    buf = buf and ((1 shl bits) - 1)
  if bits > 0:
    result.add(KEY_ALPHABET[(buf shl (5 - bits)) and 31])

proc keyNormalize*(s: string): tuple[ok: bool, canon: string] =
  ## 入力されたキーを正規の形 (大文字24文字) にそろえる。形が違えば ok=false
  var c = ""
  for r in s.toRunes():
    let cp = int(r)
    if cp >= ord('a') and cp <= ord('z'):
      c.add(char(cp - 32))
    elif (cp >= ord('A') and cp <= ord('Z')) or
         (cp >= ord('2') and cp <= ord('7')):
      c.add(char(cp))
  if c.len == 24:
    return (true, c)
  return (false, "")

proc keyDisplay*(canon: string): string =
  var parts: seq[string] = @[]
  var i = 0
  while i < canon.len:
    parts.add(canon[i ..< min(i + 4, canon.len)])
    i += 4
  return parts.join("-")

proc keySecretKey(): seq[byte] =
  let key = loadSecret(KEY_SECRET_FILE)
  if key.len == 0:
    bbsError("認証キー用の鍵を保存できません.")
  return key

proc keyHash*(canon: string): string =
  return toHexLower(hmacSha256(keySecretKey(), KEY_CTX & canon))

type
  KeyRow* = object
    id*, label*, hash*, scope*, status*: string
    created*: int

proc parseCreated(s: string): int =
  var i = 0
  var neg = false
  if i < s.len and s[i] == '-':
    neg = true
    inc i
  let start = i
  var v: int64 = 0
  while i < s.len and s[i] in {'0' .. '9'}:
    v = v * 10 + (ord(s[i]) - ord('0'))
    inc i
  if i == start:
    return 0
  return int(if neg: -v else: v)

proc parseKeyRow(line: string): tuple[ok: bool, row: KeyRow] =
  let p = rstripCrLf(line).split('\t')
  if p.len != 6:
    return (false, KeyRow())
  return (true, KeyRow(id: p[0], label: p[1], hash: p[2], scope: p[3],
                       created: parseCreated(p[4]), status: p[5]))

proc keysLoad*(folder: string): seq[KeyRow] =
  ## keys.txt の全行 (管理画面用。キーは板ごとに数が少ない前提)
  result = @[]
  try:
    for line in readFile("./" & folder & "/" & KEYS_FILE).split('\n'):
      let (okp, row) = parseKeyRow(line)
      if okp:
        result.add(row)
  except CatchableError:
    discard

proc keyFindRow*(folder, kid: string): tuple[found: bool, row: KeyRow] =
  ## 投稿のときの照合用: ID の行だけを、1行ずつ読んで探す
  try:
    for line in readFile("./" & folder & "/" & KEYS_FILE).split('\n'):
      if line.startsWith(kid & "\t"):
        let (okp, row) = parseKeyRow(line)
        return (okp, row)
  except CatchableError:
    discard
  return (false, KeyRow())

proc keyVerify*(folder, res, input: string): bool =
  ## キーがこのスレッドに書き込めるか。失効・範囲外・存在しない・形が違う、はどれも false (区別しない)
  let (okn, canon) = keyNormalize(input)
  if not okn:
    return false
  let (found, row) = keyFindRow(folder, canon[0 ..< 4])
  if not found or row.status != "active":
    return false
  if not constTimeEq(row.hash, keyHash(canon)):
    return false
  return row.scope == "*" or row.scope == res

proc keysUpdate*(folder: string,
                 fn: proc(rows: seq[KeyRow]): seq[KeyRow]): bool =
  ## keys.txt を排他ロックして、fn(全行) の結果で書き直す (一時ファイル + rename)
  var lk: File
  try:
    lk = open("./" & folder & "/keys.lock", fmAppend)
  except CatchableError:
    return false
  defer:
    lk.close()
  lockFile(lk)
  let rows = fn(keysLoad(folder))
  let path = "./" & folder & "/" & KEYS_FILE
  let tmp = path & ".tmp" & $getCurrentProcessId()
  var ok = false
  try:
    let oldMask = umask(Mode(0o077))
    var W: File
    try:
      W = open(tmp, fmWrite)
    finally:
      discard umask(oldMask)
    try:
      for r in rows:
        W.write([r.id, r.label, r.hash, r.scope, $r.created,
                 r.status].join("\t") & "\n")
    finally:
      W.close()
    moveFile(tmp, path)
    ok = true
  except CatchableError:
    try:
      removeFile(tmp)
    except CatchableError:
      discard
  unlockFile(lk)
  return ok

proc keyIssue*(folder, label, scope: string): tuple[ok: bool, id: string,
                                                    display: string] =
  ## 管理者がキーを発行する。表示用のキーはこの1回しか見られない。
  var cleaned = ""
  for r in label.toRunes():
    let cp = int(r)
    if cp <= 0x1F or cp == 0x7F:
      cleaned.add(" ")
    else:
      cleaned.add($r)
  var lab = stripPy(cleaned)
  let lrs = lab.toRunes()
  if lrs.len > 40:
    lab = ""
    for i in 0 ..< 40:
      lab.add($lrs[i])
  if lab == "":
    lab = "(無題)"
  if scope != "*" and not isDigitsLen(scope, 1, 20):
    return (false, "", "")
  var newId = ""
  var newDisplay = ""
  let gen = proc(rowsIn: seq[KeyRow]): seq[KeyRow] =
    var rows = rowsIn
    var used: seq[string] = @[]
    for r in rows:
      used.add(r.id)
    var canon = ""
    while true:
      canon = base32EncodeBytes(randomBytes(15))  # 120bit = 24文字。先頭4文字が ID
      if canon[0 ..< 4] notin used:
        break
    rows.add(KeyRow(id: canon[0 ..< 4], label: lab, hash: keyHash(canon),
                    scope: scope, created: int(getTime().toUnix()),
                    status: "active"))
    newId = canon[0 ..< 4]
    newDisplay = keyDisplay(canon)
    return rows
  if not keysUpdate(folder, gen):
    return (false, "", "")
  return (true, newId, newDisplay)

proc keyRevoke*(folder, id: string): bool =
  var hit = false
  let fn = proc(rowsIn: seq[KeyRow]): seq[KeyRow] =
    var rows = rowsIn
    for i in 0 ..< rows.len:
      if rows[i].id == id and rows[i].status == "active":
        rows[i].status = "revoked"
        hit = true
    return rows
  return keysUpdate(folder, fn) and hit

proc threadSetLock*(folder, res: string, on: bool): bool =
  ## スレッドに鍵をかける/外す。返信フォームの行を差し替え、印 (.lock) を作る/消す。
  let path = "./" & folder & "/" & res & ".html"
  if not fileExists(path):
    return false
  var W: File
  try:
    W = open(path, fmReadWriteExisting)
  except CatchableError:
    return false
  defer:
    W.close()
  lockFile(W)
  let data = W.readAll()
  let idx = data.rfind("\n<form")
  let footer = if idx >= 0: idx + 1 else: data.len
  let newText = replyForm(res, "", on) & "</body></html>\n"
  W.setFilePos(footer)
  W.write(newText)
  W.flushFile()
  discard posix.ftruncate(cint(W.getFileHandle()),
                          int64(footer + newText.len))
  let lockfile = "./" & folder & "/" & res & ".lock"
  try:
    if on:
      let lf = open(lockfile, fmWrite)
      lf.close()
    elif fileExists(lockfile):
      removeFile(lockfile)
  except CatchableError:
    return false
  return true


# ---- 表示処理 ---------------------------------------------------------------

type
  LineReader = object
    f: File
    buf: string
    pos: int
    eof: bool

proc readLineRaw(r: var LineReader): tuple[ok: bool, line: string] =
  ## 改行を含む生の1行を返す (ファイル末尾の改行なし部分も1行)
  while true:
    let idx = r.buf.find('\n', r.pos)
    if idx >= 0:
      let line = r.buf[r.pos .. idx]
      r.pos = idx + 1
      return (true, line)
    if r.eof:
      if r.pos < r.buf.len:
        let line = r.buf[r.pos ..< r.buf.len]
        r.pos = r.buf.len
        return (true, line)
      return (false, "")
    if r.pos > 0:
      r.buf = r.buf[r.pos ..< r.buf.len]
      r.pos = 0
    let old = r.buf.len
    r.buf.setLen(old + 65536)
    let got = r.f.readBuffer(addr r.buf[old], 65536)
    r.buf.setLen(old + got)
    if got == 0:
      r.eof = true

proc dtNumber(line: string): int =
  ## 行の中の <dt>数字 を探す。無ければ -1
  var start = 0
  while true:
    let idx = line.find("<dt>", start)
    if idx < 0:
      return -1
    var j = idx + 4
    var v: int64 = 0
    var digits = 0
    while j < line.len and line[j] in {'0' .. '9'}:
      if v < 1_000_000_000_000:
        v = v * 10 + (ord(line[j]) - ord('0'))
      inc j
      inc digits
    if digits > 0:
      return int(v)
    start = idx + 1

proc parseFromIdx(s: string): int =
  ## Python の int() での変換 (失敗したら 1)
  let t = stripPy(s)
  var body = t
  var neg = false
  if body.startsWith("+"):
    body = body[1 ..< body.len]
  elif body.startsWith("-"):
    neg = true
    body = body[1 ..< body.len]
  if not allDigits(body):
    return 1
  let (okp, v) = parseIntSafe(body)
  if not okp:
    return 1
  let r = if neg: -v else: v
  if r < 1:
    return 1
  return int(min(r, int64(high(int))))

proc resView*(folder: string, form: Table[string, string]) {.noreturn.} =
  ## レス表示 (from 番号以降だけ出す)
  let res = form.getOrDefault("res", "")
  if not allDigits(res):
    bbsError("不正なスレッド指定です")
  var fromIdx = 1
  if form.hasKey("from"):
    fromIdx = parseFromIdx(form["from"])
  let filePath = "./" & folder & "/" & res & ".html"
  if not fileExists(filePath):
    threadMissing(folder, res, "表示")
  var rf: File
  try:
    rf = open(filePath, fmRead)
  except CatchableError:
    threadMissing(folder, res, "表示")
  defer:
    rf.close()
  stdout.write("Content-type: text/html; charset=UTF-8\r\n\r\n")
  let folTag = "<input type=\"hidden\" name=\"folder\" value=\"" &
               pyHtmlEscape(folder) & "\">"

  proc fixj(line: string): string =
    # / 直下から出力するので、中継リンクの相対パスを直す
    if "../jump.cgi?" in line:
      return line.replace("href=\"../jump.cgi?", "href=\"jump.cgi?")
    return line

  proc formLine(line: string): string =
    # 返信フォームの行は、action を板のない位置に直し、folder を足して出す
    return line.replace("action=\"../", "action=\"").replace("</form>",
        folTag & "</form>")

  var lr = LineReader(f: rf, buf: "", pos: 0, eof: false)
  while true:
    let (okl, rawLine) = lr.readLineRaw()
    if not okl:
      break
    var line = rawLine.replace("href=\"../style.css\"", "href=\"style.css\"")
    line = line.replace("src=\"../hide.js\"", "src=\"hide.js\"")
    line = line.replace("href=\"../jump.cgi?", "href=\"jump.cgi?")
    stdout.write(line)
    if "<dl>" in line or "<dt>" in line:
      break
  var matched = false
  var footer = ""
  var hasFooter = false
  while true:
    let (okl, line) = lr.readLineRaw()
    if not okl:
      break
    if line.startsWith("<form"):
      footer = line
      hasFooter = true
    let dt = dtNumber(line)
    if dt >= 0 and dt >= fromIdx:
      stdout.write(fixj(line))
      matched = true
      break
  if not matched and hasFooter:     # from が大きすぎても、返信フォームは出す
    stdout.write(formLine(footer))
  while true:
    let (okl, line) = lr.readLineRaw()
    if not okl:
      break
    if "</form>" in line:
      stdout.write(formLine(line))
    else:
      stdout.write(fixj(line))
  stdout.flushFile()
  quit(0)

# ---- 過去ログ一覧 -----------------------------------------------------------

proc titleOfFirstLine(first: string): string =
  var start = 0
  while true:
    let idx = first.find("<b>", start)
    if idx < 0:
      return ""
    var j = idx + 3
    var cap = ""
    while j < first.len and first[j] != '<':
      cap.add(first[j])
      inc j
    if startsAt(first, "</b>", j):
      return cap
    start = idx + 1

proc readThreadTitle*(path: string): string =
  ## スレッドのファイルの1行目から題名を取り出す (読めなければ "")。.gz も読む
  try:
    var first = ""
    if path.endsWith(".gz"):
      let raw = readFile(path)
      let plain = gzUncompress(raw)
      let nl = plain.find('\n')
      first = utf8Lossy(if nl < 0: plain else: plain[0 ..< nl])
    else:
      let raw = readFile(path)
      let nl = raw.find('\n')
      first = if nl < 0: raw else: raw[0 ..< nl]
    return titleOfFirstLine(first)
  except CatchableError:
    return ""

proc kakoListSize*(folder: string): int =
  ## kako.txt の大きさ。無ければ -1
  try:
    return int(getFileInfo("./" & folder & "/" & KAKO_LIST).size)
  except CatchableError:
    return -1

proc appendKakoList*(folder: string,
                     items: seq[tuple[ts, name: string]]): bool =
  ## 今回退避したスレッドの題名を kako.txt に追記する
  var buf = ""
  for (ts, name) in items.sorted:
    let p = archivedPath(folder, name)
    let tp = if p.len > 0: p else: "./" & folder & "/" & name
    buf.add(name & KAKO_SEP & readThreadTitle(tp) & "\n")
  try:
    let W = open("./" & folder & "/" & KAKO_LIST, fmAppend)
    defer:
      W.close()
    lockFile(W)
    W.write(buf)
    return true
  except CatchableError:
    return false

proc rebuildKakoList*(folder: string, names: seq[string]): bool =
  ## 今ある o数字.html から kako.txt を作り直す (更新日時の古い順)
  var items: seq[tuple[ts, name: string]] = @[]
  for name in names:
    let p = archivedPath(folder, name)
    let tp = if p.len > 0: p else: "./" & folder & "/" & name
    var mtime: int64 = 0
    try:
      mtime = getFileInfo(tp).lastWriteTime.toUnix()
    except CatchableError:
      mtime = 0
    items.add((padNum(mtime, 11), name))
  items.sort()
  let path = "./" & folder & "/" & KAKO_LIST
  let tmpPath = path & ".tmp" & $getCurrentProcessId()
  try:
    let W = open(tmpPath, fmWrite)
    try:
      for (ts, name) in items:
        let p = archivedPath(folder, name)
        let tp = if p.len > 0: p else: "./" & folder & "/" & name
        W.write(name & KAKO_SEP & readThreadTitle(tp) & "\n")
    finally:
      W.close()
    setFilePermissions(tmpPath, {fpUserRead, fpUserWrite, fpGroupRead,
                                 fpOthersRead})
    moveFile(tmpPath, path)
    return true
  except CatchableError:
    try:
      removeFile(tmpPath)
    except CatchableError:
      discard
    return false

iterator reverseLines*(path: string): string =
  ## ファイルを末尾から1行ずつ返す (全体をメモリに載せない)
  var fp: File
  var opened = true
  try:
    fp = open(path, fmRead)
  except CatchableError:
    opened = false
  if opened:
    var pos = 0
    try:
      pos = int(getFileSize(fp))
    except CatchableError:
      pos = 0
    var carry = ""
    while pos > 0:
      let n = min(65536, pos)
      pos -= n
      fp.setFilePos(pos)
      var chunk = newString(n)
      let got = fp.readBuffer(addr chunk[0], n)
      chunk.setLen(got)
      let parts = (chunk & carry).split('\n')
      carry = parts[0]
      for i in countdown(parts.len - 1, 1):
        if parts[i].len > 0:
          yield utf8Lossy(parts[i])
    if carry.len > 0:
      yield utf8Lossy(carry)
    fp.close()

proc isKakoName(name: string): bool =
  ## ^o\d+\.html$
  if name.len < 7 or name[0] != 'o' or not name.endsWith(".html"):
    return false
  let mid = name[1 ..< name.len - 5]
  return allDigits(mid)

proc writeKako*(folder, bodyTag, title0, amezoName, suffix,
                title: string) =
  ## 過去ログの一覧 板/kako.html を、kako.txt から作る (新しい退避が上)
  let listPath = "./" & folder & "/" & KAKO_LIST
  if not fileExists(listPath):
    return
  let kakoPath = "./" & folder & "/" & KAKO_FILE
  let tmpPath = kakoPath & ".tmp" & $getCurrentProcessId()
  try:
    let W = open(tmpPath, fmWrite)
    try:
      W.write(
        "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">\n" &
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" &
        "<link rel=\"stylesheet\" href=\"../style.css\">\n" &
        "<title>" & title0 & amezoName & suffix & " 過去ログ</title></head>\n" &
        COPYRIGHT & "\n" & bodyTag & "\n" &
        "<font size=+2>" & title & amezoName & suffix & " 過去ログ</font>\n" &
        "<div class=\"row links\"><a href=\"./\">板へ戻る</a></div>\n" &
        "<font size=2>\n")
      var i = 0
      for line in reverseLines(listPath):     # 新しい退避が上。全部は読み込まない
        let idx = line.find(KAKO_SEP)
        if idx < 0:
          continue
        let name = line[0 ..< idx]
        let ttl = line[idx + KAKO_SEP.len ..< line.len]
        if not isKakoName(name):    # 壊れた行は読み飛ばす
          continue
        inc i
        W.write(" " & $i & "<a href=\"" & name & "\">" & ttl & "</a>\n")
      W.write("</font>\n<hr></body></html>\n")
    finally:
      W.close()
    setFilePermissions(tmpPath, {fpUserRead, fpUserWrite, fpGroupRead,
                                 fpOthersRead})
    moveFile(tmpPath, kakoPath)
  except CatchableError:
    try:
      removeFile(tmpPath)
    except CatchableError:
      discard

# ---- ページ送り ---------------------------------------------------------------

proc countThreads*(folder: string): int =
  ## 表示中のスレッド数 (ファイル名を1つずつ見て数える)
  var n = 0
  try:
    for kind, name in walkDir("./" & folder, relative = true):
      if name.len > 0 and name[0] in {'0' .. '9'}:
        let dot = name.find(".html")
        if dot > 0 and dot + 5 == name.len and allDigits(name[0 ..< dot]):
          inc n
  except CatchableError:
    return 0
  return if MAX_THREADS > 0: min(n, MAX_THREADS) else: n

proc totalPages*(nThreads: int): int =
  return max(1, (nThreads + PER_PAGE - 1) div PER_PAGE)

proc pageClamp*(folder: string, page: int): int =
  ## ページ番号を、実在するページ (1〜最後のページ) に直す
  if page <= 1:
    return 1
  return min(page, totalPages(countThreads(folder)))

proc quoteFolder(s: string): string =
  ## urllib.parse.quote(s, safe='') 相当
  result = ""
  for c in s:
    if c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '.', '-', '~'}:
      result.add(c)
    else:
      result.add('%')
      result.add(toHex(ord(c), 2))

proc pagerHtml*(folder: string, page, total: int): string =
  ## ページ送りのリンク。1ページしか無いときは何も出さない。
  ## 10ページ以下なら全部の番号、11ページ以上なら 1・最後・現在の前後2つだけ。
  if total <= 1:
    return ""
  let q = quoteFolder(folder)

  proc href(p: int): string =
    if p == 1:
      return "./"
    return "../amezo.cgi?folder=" & q & "&amp;page=" & $p

  var nums: seq[string] = @[]
  var last = 0
  for p in 1 .. total:
    if total > 10 and p != 1 and p != total and abs(p - page) > 2:
      continue
    if last != 0 and p - last > 1:
      nums.add("…")
    if p == page:
      nums.add("<b>[" & $p & "]</b>")
    else:
      nums.add("<a href=\"" & href(p) & "\">" & $p & "</a>")
    last = p
  var segments: seq[string] = @[]
  if page > 1:
    segments.add("<a href=\"" & href(page - 1) & "\">← 前の" & $PER_PAGE &
                 "件</a>")
  segments.add(nums.join(" "))
  if page < total:
    segments.add("<a href=\"" & href(page + 1) & "\">次の" & $PER_PAGE &
                 "件 →</a>")
  return "<div class=\"row links pager\">" & segments.join("　") & "</div>\n"
