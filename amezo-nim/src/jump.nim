# jump.nim - 外部サイトへの中継ページ (jump.py の移植。/jump.cgi も、ここに向く)
# 署名の照合・URL の検査・base64url の復号は bbs.nim の
# jumpVerify / urlIsValid / b64urlDecode を使う (jump.php が lib.php を使うのと同じ分担)。
import os, strutils, tables, sets
import bbs

const STYLE =
  ":root{color-scheme:light dark}body{font-family:sans-serif;max-width:40em;margin:1.5em auto;padding:0 1em;line-height:1.6}" &
  ".url{word-break:break-all;border:1px solid #888;padding:.6em .8em;margin:.8em 0;font-family:monospace}" &
  ".host{font-size:1.4em;font-weight:bold;word-break:break-all}" &
  ".btns{margin:1.2em 0}.go,.back{display:inline-block;padding:.5em 1.6em;margin-right:.8em;border:1px solid #888;border-radius:6px;" &
  "font-size:1em;text-decoration:none;cursor:pointer;background:transparent;color:inherit}.go{font-weight:bold}" &
  ".note{font-size:.9em;opacity:.85}.warn{border:1px solid #c60;padding:.4em .7em;margin:.6em 0}" &
  ".ad{margin:1.5em 0}.ad small{display:block;opacity:.7}.ad iframe{width:100%;height:260px;border:1px solid #888}"

proc E(s: string): string =
  return htmlEscape(s)

proc isValidUtf8(s: string): bool =
  ## 厳密な UTF-8 検査 (Python の bytes.decode('utf-8') が失敗するものは失敗させる)
  var i = 0
  let n = s.len
  while i < n:
    let b = ord(s[i])
    if b < 0x80:
      inc i
      continue
    var need = 0
    var lo = 0x80
    var hi = 0xBF
    case b
    of 0xC2 .. 0xDF: need = 1
    of 0xE0: need = 2; lo = 0xA0
    of 0xE1 .. 0xEC: need = 2
    of 0xED: need = 2; hi = 0x9F
    of 0xEE .. 0xEF: need = 2
    of 0xF0: need = 3; lo = 0x90
    of 0xF1 .. 0xF3: need = 3
    of 0xF4: need = 3; hi = 0x8F
    else: return false
    if i + need >= n:
      return false
    let b1 = ord(s[i + 1])
    if b1 < lo or b1 > hi:
      return false
    for k in 2 .. need:
      let bk = ord(s[i + k])
      if bk < 0x80 or bk > 0xBF:
        return false
    i += need + 1
  return true

proc makeNonce(): string =
  ## secrets.token_hex(12) と同じ24桁の16進数 (/dev/urandom から読む)
  let f = open("/dev/urandom", fmRead)
  var buf = newString(12)
  var got = 0
  while got < 12:
    let r = f.readBuffer(addr buf[got], 12 - got)
    if r <= 0:
      f.close()
      raise newException(CatchableError, "random source unavailable")
    got += r
  f.close()
  const Hex = "0123456789abcdef"
  result = ""
  for ch in buf:
    result.add(Hex[ord(ch) shr 4])
    result.add(Hex[ord(ch) and 0x0F])

proc jumpHeaders(nonce: string): string =
  return "Content-Type: text/html; charset=UTF-8\r\n" &
    "Cache-Control: no-store\r\n" &
    "X-Robots-Tag: noindex, nofollow\r\n" &
    "Referrer-Policy: no-referrer\r\n" &
    "X-Content-Type-Options: nosniff\r\n" &
    "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-" & nonce & "'; " &
    "frame-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n" &
    "\r\n"

proc jumpPage(title, body, nonce: string, withBack: bool = true) {.noreturn.} =
  var outp = jumpHeaders(nonce)
  outp.add("<!DOCTYPE html><html lang=\"ja\"><head><meta charset=\"UTF-8\">" &
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" &
    "<meta name=\"robots\" content=\"noindex, nofollow\"><meta name=\"referrer\" content=\"no-referrer\">" &
    "<title>" & E(title) & "</title>" &
    "<style>" & STYLE & "</style>" &
    "</head><body><h2>" & E(title) & "</h2>" & body)
  if withBack:
    outp.add("<script nonce=\"" & nonce & "\">document.getElementById(\"back\").addEventListener(\"click\",function(){" &
      "if(history.length>1){history.back();}else{window.close();}});</script>")
  outp.add("</body></html>")
  stdout.write(outp)
  stdout.flushFile()
  quit(0)

type Params = object
  values: Table[string, string]
  arrKeys: HashSet[string]      # u[]=... で来たキー (文字列ではないとして扱う)

proc getParams(): Params =
  ## QUERY_STRING を PHP の $_GET と同じ感覚で読む。
  ## 同じキーが複数あれば最後のものが勝ち、u[]=... のような配列形式は文字列ではないとして扱う
  result.values = initTable[string, string]()
  result.arrKeys = initHashSet[string]()
  let queryString = getEnv("QUERY_STRING")
  if queryString == "":
    return
  for pair in queryString.split('&'):
    if pair == "":
      continue
    var k, v: string
    let eq = pair.find('=')
    if eq >= 0:
      k = pair[0 ..< eq]
      v = pair[eq + 1 ..< pair.len]
    else:
      k = pair
      v = ""
    k = urlDecode(k)
    v = urlDecode(v)
    let br = k.find('[')
    if br >= 0:                       # u[]=... は配列 (PHP の is_string チェックで弾かれる形)
      let base = k[0 ..< br]
      result.arrKeys.incl(base)
      result.values[base] = ""
    else:
      result.arrKeys.excl(k)
      result.values[k] = v

proc getString(p: Params, key: string): string =
  if key in p.arrKeys:
    return ""
  return p.values.getOrDefault(key, "")

proc parseHost(url: string): string =
  ## PHP の parse_url($url, PHP_URL_HOST) に当たる部分を取り出す。読めなければ ""
  var rest = ""
  let p = url.find("://")
  if p >= 0:
    rest = url[p + 3 ..< url.len]
  var authEnd = rest.len
  for i in 0 ..< rest.len:
    if rest[i] in {'/', '?', '#'}:
      authEnd = i
      break
  var authority = rest[0 ..< authEnd]
  let at = authority.rfind('@')
  if at >= 0:
    authority = authority[at + 1 ..< authority.len]     # ユーザー情報は捨てる
  if authority.startsWith('['):                         # IPv6 は ] まで (括弧も含めて返す)
    let e = authority.find(']')
    if e >= 0:
      return authority[0 .. e]
    return authority
  let colon = authority.find(':')
  if colon >= 0:
    return authority[0 ..< colon]                       # ポートは捨てる
  return authority

proc run() =
  try:
    setCurrentDir(getAppDir())
  except OSError:
    discard
  applyConfig()

  let nonce = makeNonce()
  let params = getParams()
  let u = getString(params, "u")
  let s = getString(params, "s")

  var url = ""
  var hasUrl = false
  if u.len <= 3000:                     # 3000文字超の u は復号しない (jump.py と同じ)
    let (okd, data) = b64urlDecode(u)
    if okd and isValidUtf8(data):
      url = data
      hasUrl = true
    # URL として読めないバイト列は、表示もしない (PHP の url_is_valid で落ちるのと同じ)

  if not hasUrl or not jumpVerify(url, s):
    # 署名が合わない: リンクにはしない。URL として読めるなら、文字だけ見せる
    var body = "<p>このリンクは、署名が合わないため、自動では開きません。<br>" &
      "掲示板に投稿された URL ではないか、投稿のあとに署名の鍵が変わった可能性があります。</p>"
    if hasUrl and urlIsValid(url):
      body.add("<p class=\"note\">URL (リンクにはしていません。確かめてから、自分で開いてください):</p>" &
        "<div class=\"url\">" & E(url) & "</div>")
    body.add("<div class=\"btns\"><button type=\"button\" class=\"back\" id=\"back\">戻る</button></div>")
    jumpPage("このリンクは使えません", body, nonce)

  var host = parseHost(url)
  if host == "":
    host = "(ホスト名を読み取れません)"

  var body = "<p>この掲示板に投稿された、外部サイトへのリンクです。移動先を確かめてから、「進む」を押してください。</p>" &
    "<p class=\"note\">移動先のサイト</p><div class=\"host\">" & E(host) & "</div>" &
    "<p class=\"note\">URL 全体</p><div class=\"url\">" & E(url) & "</div>"
  if "xn--" in host.toLowerAscii():
    body.add("<div class=\"warn\">ドメイン名に <code>xn--</code> が含まれています。" &
      "見た目が似た別のサイトのことがあるので、特に注意してください。</div>")
  body.add("<div class=\"btns\"><a class=\"go\" href=\"" & E(url) & "\" rel=\"noopener noreferrer nofollow\" referrerpolicy=\"no-referrer\">進む</a>" &
    "<button type=\"button\" class=\"back\" id=\"back\">戻る</button></div>" &
    "<p class=\"note\">このページは自動では転送しません。リンク先の内容について、掲示板は責任を負いません。</p>")
  # 広告枠: ad.html があるときだけ。別オリジン扱い (allow-same-origin なし) の iframe に入れる
  if fileExists("ad.html"):
    body.add("<div class=\"ad\"><small>広告</small>" &
      "<iframe src=\"ad.html\" sandbox=\"allow-scripts allow-popups\" referrerpolicy=\"no-referrer\" loading=\"lazy\" title=\"広告\"></iframe></div>")
  jumpPage("外部サイトへ移動します", body, nonce)

try:
  run()
except CatchableError as e:             # jump.php が RuntimeException を受けて 500 にするのと同じ
  stderr.writeLine("jump: " & e.msg)
  stdout.write("Status: 500\r\n\r\nサーバーの設定に問題があります。")
  stdout.flushFile()
