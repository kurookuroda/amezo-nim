# -*- coding: utf-8 -*-
#
# admin.nim - あめぞう風掲示板の管理画面 (CGI)  ※ admin.py の移植
#
#   板 → スレッド → レス の順にたどり、レスの削除・スレッドの非表示/復元を行う。
#   認証は各画面のフォームにパスワードを持たせ、送信のたびに delpass.txt と照合する
#   (セッション/クッキーは使わない)。失敗が続いたら一定時間は照合せずに拒否する。

import std/[os, strutils, unicode, tables, times, posix, algorithm, math]
import nimcrypto/[sha2, hmac]
import bbs
import bbsindex

const
  MAX_BODY = 64 * 1024        # POST の上限
  MAX_FAILS = 5               # この回数失敗したら
  LOCK_SEC = 15 * 60          # この時間 (秒) 受け付けない
  FAIL_FILE = "admin_fail.mem"
  LIST_LIMIT = 100            # スレッド一覧に出す最大件数 (新しい順)
  BODY_PREVIEW = 60           # レス一覧に出す本文の文字数

const STYLE = """<style>
body { font-family: sans-serif; margin: 12px; }
table { border-collapse: collapse; }
th, td { border: 1px solid #999; padding: 4px 8px; vertical-align: top; }
td.body { max-width: 32em; word-break: break-all; }
form.inline { display: inline; }
.msg { padding: 6px 10px; border: 1px solid #c33; margin: 8px 0; }
.msg.ok { border-color: #393; }
.keybox { border: 2px solid #c60; padding: 10px 14px; margin: 10px 0; background: #fff8e8; }
.keybox code { font-size: 1.3em; letter-spacing: 0.05em; user-select: all; }
button { padding: 4px 12px; }
</style>"""

proc E(s: string): string =
  ## Python の html.escape(s, quote=True) 相当 (' は &#x27;)
  result = ""
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&#x27;")
    else: result.add(c)

proc unescapeHtml(s: string): string =
  ## Python の html.unescape の近似 (名前付きは主要なもの + 数値参照に対応)
  result = ""
  var i = 0
  while i < s.len:
    if s[i] != '&':
      result.add(s[i])
      inc i
      continue
    let semi = s.find(';', i + 1)
    var rep = ""
    var okEnt = false
    if semi > i + 1 and semi - i <= 12:
      let ent = s[i + 1 ..< semi]
      if ent.len >= 2 and ent[0] == '#' and (ent[1] == 'x' or ent[1] == 'X'):
        var v = 0
        var valid = ent.len > 2
        for c in ent[2 ..< ent.len]:
          if c notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
            valid = false
            break
          v = v * 16 + (if c in {'0' .. '9'}: ord(c) - 48
                        elif c in {'a' .. 'f'}: ord(c) - 87
                        else: ord(c) - 55)
          if v > 0x110000:
            valid = true
            v = 0x110000
            break
        if valid:
          rep = if v == 0 or v > 0x10FFFF or (0xD800 <= v and v <= 0xDFFF):
                  "\uFFFD"
                else:
                  toUTF8(Rune(v))
          okEnt = true
      elif ent.len >= 1 and ent[0] == '#':
        var v = 0
        var valid = ent.len > 1
        for c in ent[1 ..< ent.len]:
          if c notin {'0' .. '9'}:
            valid = false
            break
          v = v * 10 + (ord(c) - 48)
          if v > 0x110000:
            break
        if valid:
          rep = if v == 0 or v > 0x10FFFF or (0xD800 <= v and v <= 0xDFFF):
                  "\uFFFD"
                else:
                  toUTF8(Rune(v))
          okEnt = true
      else:
        case ent
        of "amp": rep = "&"; okEnt = true
        of "lt": rep = "<"; okEnt = true
        of "gt": rep = ">"; okEnt = true
        of "quot": rep = "\""; okEnt = true
        of "apos": rep = "'"; okEnt = true
        of "nbsp": rep = "\u00A0"; okEnt = true
        else: discard
    if okEnt:
      result.add(rep)
      i = semi + 1
    else:
      result.add('&')
      inc i

proc stripTags(s: string): string =
  ## re.sub(r'<[^>]*>', '', s) 相当
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '<':
      let j = s.find('>', i + 1)
      if j < 0:
        result.add(s[i ..< s.len])
        break
      i = j + 1
    else:
      result.add(s[i])
      inc i

proc allDigitsA(s: string): bool =
  if s.len == 0:
    return false
  for c in s:
    if c notin {'0' .. '9'}:
      return false
  return true

proc parseDigitsCapped(s: string): int =
  ## 数字だけの文字列を int にする (あふれそうなら途中で止める)
  result = 0
  for c in s:
    if result > 100_000_000_000:
      break
    result = result * 10 + (ord(c) - 48)

proc pad2(n: int): string =
  if n < 10: "0" & $n else: $n

proc pad4(n: int): string =
  let s = $n
  if s.len >= 4: s else: repeat('0', 4 - s.len) & s

# ---- 行内検索 (Python の re.search の手作業版) --------------------------------

proc searchTitleIn(line: string): tuple[found: bool, title: string] =
  ## re.search(r'<b>([^<]*)</b>', line) 相当
  var i = line.find("<b>")
  while i >= 0:
    let start = i + 3
    let j = line.find('<', start)
    if j < 0:
      return (false, "")
    if line[j ..< line.len].startsWith("</b>"):
      return (true, line[start ..< j])
    i = line.find("<b>", j)
  return (false, "")

proc searchDt(line: string): tuple[found: bool, num: int] =
  ## re.search(r'<dt>(\d+)', line) 相当
  var i = line.find("<dt>")
  while i >= 0:
    var j = i + 4
    var v = 0
    var digits = 0
    while j < line.len and line[j] in {'0' .. '9'}:
      if v < 1_000_000_000_000_000:
        v = v * 10 + (ord(line[j]) - 48)
      inc j
      inc digits
    if digits > 0:
      return (true, v)
    i = line.find("<dt>", i + 1)
  return (false, 0)

proc searchNameIn(line: string): string =
  ## re.search(r'投稿者：<font[^>]*><b>(.*?) </b>', line) の group(1)。無ければ ""
  let key = "投稿者：<font"
  var i = line.find(key)
  while i >= 0:
    let gt = line.find('>', i + key.len)
    if gt < 0:
      return ""
    if line[gt + 1 ..< line.len].startsWith("<b>"):
      let start = gt + 4
      let e = line.find(" </b>", start)
      if e >= 0:
        return line[start ..< e]
    i = line.find(key, i + 1)
  return ""

proc searchDateIn(line: string): string =
  ## re.search(r'投稿日：([^<]*)</font>', line) の group(1)。無ければ ""
  let key = "投稿日："
  let i = line.find(key)
  if i < 0:
    return ""
  let start = i + key.len
  let j = line.find('<', start)
  if j < 0:
    return ""
  if line[j ..< line.len].startsWith("</font>"):
    return line[start ..< j]
  return ""

proc searchDataId(line: string): string =
  ## re.search(r'data-id="([^"]*)"', line) の group(1)。無ければ ""
  let key = "data-id=\""
  let i = line.find(key)
  if i < 0:
    return ""
  let start = i + key.len
  let j = line.find('"', start)
  if j < 0:
    return ""
  return line[start ..< j]

proc searchBodyIn(line: string): string =
  ## re.search(r'<dd>(.*?) </dl>', line) の group(1)。無ければ ""
  let i = line.find("<dd>")
  if i < 0:
    return ""
  let start = i + 4
  let e = line.find(" </dl>", start)
  if e < 0:
    return ""
  return line[start ..< e]

proc searchAlt(title: string): tuple[found: bool, val: string] =
  ## re.search(r'alt="([^"]+)', title) 相当
  let key = "alt=\""
  let i = title.find(key)
  if i < 0:
    return (false, "")
  let start = i + key.len
  let j = title.find('"', start)
  if j < 0 or j == start:
    return (false, "")
  return (true, title[start ..< j])

proc stripIdTail(date: string): string =
  ## re.sub(r' ID:[A-Za-z0-9._]+$', '', date) 相当
  let idx = date.rfind(" ID:")
  if idx >= 0:
    let rest = date[idx + 4 ..< date.len]
    if rest.len > 0:
      var allOk = true
      for c in rest:
        if c notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '.', '_'}:
          allOk = false
          break
      if allOk:
        return date[0 ..< idx]
  return date

proc parseDateAt(line: string, pos: int): tuple[ok: bool, y, mo, d, h, mi, s: int] =
  ## DATE_RE を pos から読む試み
  var p = pos
  proc takeDigits(n: int): tuple[ok: bool, val: int] =
    if p + n > line.len:
      return (false, 0)
    var v = 0
    for k in 0 ..< n:
      let c = line[p + k]
      if c notin {'0' .. '9'}:
        return (false, 0)
      v = v * 10 + (ord(c) - 48)
    p += n
    return (true, v)
  proc expect(lit: string): bool =
    if line[p ..< line.len].startsWith(lit):
      p += lit.len
      return true
    return false
  let (okY, y) = takeDigits(4)
  if not okY or not expect("年"):
    return (false, 0, 0, 0, 0, 0, 0)
  let (okMo, mo) = takeDigits(2)
  if not okMo or not expect("月"):
    return (false, 0, 0, 0, 0, 0, 0)
  let (okD, d) = takeDigits(2)
  if not okD or not expect("日"):
    return (false, 0, 0, 0, 0, 0, 0)
  if not expect("("):
    return (false, 0, 0, 0, 0, 0, 0)
  var q = p
  while q < line.len and line[q] != ')':
    inc q
  if q >= line.len or q == p:
    return (false, 0, 0, 0, 0, 0, 0)
  p = q + 1
  let (okH, h) = takeDigits(2)
  if not okH or not expect("時"):
    return (false, 0, 0, 0, 0, 0, 0)
  let (okMi, mi) = takeDigits(2)
  if not okMi or not expect("分"):
    return (false, 0, 0, 0, 0, 0, 0)
  let (okS, s) = takeDigits(2)
  if not okS or not expect("秒"):
    return (false, 0, 0, 0, 0, 0, 0)
  return (true, y, mo, d, h, mi, s)

proc searchDateStamp(line: string): tuple[found: bool, y, mo, d, h, mi, s: int] =
  ## DATE_RE の re.search 相当
  for pos in 0 ..< line.len:
    if line[pos] in {'0' .. '9'}:
      let r = parseDateAt(line, pos)
      if r.ok:
        return (true, r.y, r.mo, r.d, r.h, r.mi, r.s)
  return (false, 0, 0, 0, 0, 0, 0)

proc daysInMonth(y, m: int): int =
  case m
  of 1, 3, 5, 7, 8, 10, 12: 31
  of 4, 6, 9, 11: 30
  else:
    if (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0: 29 else: 28

proc stampToEpoch(y, mo, d, h, mi, s: int): tuple[ok: bool, ts: int64] =
  ## 日本時間で書かれた投稿日時を epoch 秒にする (datetime(..., tzinfo=JST).timestamp() 相当)
  if y < 1 or y > 9999 or mo < 1 or mo > 12 or d < 1 or d > daysInMonth(y, mo) or
     h < 0 or h > 23 or mi < 0 or mi > 59 or s < 0 or s > 59:
    return (false, 0)
  var yy = y
  if mo <= 2:
    yy -= 1
  let era = floorDiv(yy, 400)
  let yoe = yy - era * 400
  let mp = if mo > 2: mo - 3 else: mo + 9
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  let days = era * 146097 + doe - 719468
  return (true, int64(days) * 86400 + int64(h) * 3600 + int64(mi) * 60 + s -
          9 * 3600)

# ---- 出力 ---------------------------------------------------------------

proc page(title, body: string) {.noreturn.} =
  stdout.write("Content-type: text/html; charset=UTF-8\r\n" &
               "Cache-Control: no-store\r\n" &
               "X-Robots-Tag: noindex\r\n\r\n")
  stdout.write("<!DOCTYPE html>\n<html lang=\"ja\"><head><meta charset=\"UTF-8\">" &
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" &
    "<meta name=\"robots\" content=\"noindex\">" &
    "<title>" & E(title) & "</title>" & STYLE & "</head><body>\n" &
    "<h2>" & E(title) & "</h2>\n" & body & "\n</body></html>\n")
  stdout.flushFile()
  quit(0)

proc msgHtml(message: string, ok: bool = true): string =
  if message == "":
    return ""
  let cls = if ok: "msg ok" else: "msg"
  return "<div class=\"" & cls & "\">" & E(message) & "</div>"

proc hidden(pw: string, fields: openArray[(string, string)]): string =
  result = "<input type=\"hidden\" name=\"adminpass\" value=\"" & E(pw) & "\">"
  for (k, v) in fields:
    result.add("<input type=\"hidden\" name=\"" & E(k) & "\" value=\"" &
               E(v) & "\">")

proc btn(pw, label: string, fields: openArray[(string, string)],
         confirm: string = ""): string =
  var onclick = ""
  if confirm != "":
    onclick = " onclick=\"return confirm('" & E(confirm) & "')\""
  return "<form method=\"post\" action=\"admin.cgi\" class=\"inline\">" &
         hidden(pw, fields) &
         "<button type=\"submit\"" & onclick & ">" & E(label) &
         "</button></form>"

proc nav(pw: string, folder: string = ""): string =
  var s = btn(pw, "板一覧", [("act", "boards")])
  if folder != "":
    s.add(" " & btn(pw, "「" & folder & "」のスレッド一覧",
                    [("act", "threads"), ("folder", folder)]))
  return "<p>" & s & "</p>"

proc fatal(pw, message: string) {.noreturn.} =
  page("エラー", msgHtml(message, false) & nav(pw))

proc loginPage(message: string = "") {.noreturn.} =
  page("管理画面", msgHtml(message, false) &
    "<form method=\"post\" action=\"admin.cgi\">" &
    "<input type=\"hidden\" name=\"act\" value=\"boards\">" &
    "管理用パスワード <input type=\"password\" name=\"adminpass\" autocomplete=\"current-password\"> " &
    "<button type=\"submit\">ログイン</button></form>")

# ---- 認証 (失敗回数の制限つき) -----------------------------------------------

type FailMap = OrderedTable[string, tuple[c: int, t: int]]

proc admWho(ip: string): string =
  ## 接続元の鍵つきハッシュ (PHP/Python の hmac.new(id_key, 'adm:'+ip_unit) の先頭24桁)
  let h = hmac(sha256, idKey(), "adm:" & ipUnit(ip))
  result = ""
  for b in h.data:
    result.add(toHex(int(b), 2).toLowerAscii())
  result = result[0 ..< 24]

proc failStore(update: proc(fails: var FailMap, now: int): bool {.closure.}):
    tuple[opened: bool, res: bool] =
  ## admin_fail.mem を排他ロックして update(fails, now) を実行し、書き戻す。
  ## ファイルを開けなければ opened=false (呼び出し側は拒否する)
  let fd = posix.open(FAIL_FILE.cstring, O_RDWR or O_CREAT, 0o600)
  if fd < 0:
    return (false, false)
  var f: File
  if not open(f, FileHandle(fd), fmReadWriteExisting):
    discard posix.close(fd)
    return (false, false)
  lockFile(f)
  let now = int(getTime().toUnix())
  var fails = initOrderedTable[string, tuple[c: int, t: int]]()
  f.setFilePos(0)
  let content = f.readAll()
  for line in content.splitLines():
    let p = strutils.splitWhitespace(line)
    if p.len == 3 and allDigitsA(p[1]) and allDigitsA(p[2]):
      let t = parseDigitsCapped(p[2])
      if now - t < LOCK_SEC:
        fails[p[0]] = (parseDigitsCapped(p[1]), t)
  let res = update(fails, now)
  f.setFilePos(0)
  discard posix.ftruncate(cint(fd), 0)
  for k, v in fails.pairs:
    f.write(k & " " & $v.c & " " & $v.t & "\n")
  f.flushFile()
  unlockFile(f)
  f.close()
  return (true, res)

proc authenticate(pw: string): bool =
  var ip = clientIp()
  if ip == "":
    ip = "unknown"
  # IP は保存せず、鍵つきハッシュで数える (IPv6 は上位64bitでまとめる)
  let who = admWho(ip)

  let blockedR = failStore(proc(fails: var FailMap, now: int): bool =
    let e = fails.getOrDefault(who, (c: 0, t: 0))
    return e.c >= MAX_FAILS)
  if not blockedR.opened:
    page("管理画面", msgHtml("状態ファイル (admin_fail.mem) を開けないため、受け付けられません。", false))
  if blockedR.res:
    page("管理画面", msgHtml("失敗が続いたため、しばらく受け付けません。時間をおいてやり直してください。", false))

  let delcrypt = loadDelcrypt()
  if delcrypt == "":
    page("管理画面", msgHtml("管理用パスワード (delpass.txt) が設定されていません。", false))

  let ok = pw != "" and verifyHash(pw, delcrypt)

  discard failStore(proc(fails: var FailMap, now: int): bool =
    if ok:
      fails.del(who)
    else:
      let e = fails.getOrDefault(who, (c: 0, t: 0))
      fails[who] = (e.c + 1, now)
    return false)
  return ok

# ---- 板・スレッドの読み取り ------------------------------------------------------

proc readBoards(): seq[tuple[name, plain: string]] =
  result = @[]
  var content: string
  try:
    content = readFile("./blist.txt")
  except CatchableError:
    return
  for line in content.splitLines():
    let p = line.split(',')
    let name = p[0]
    if name == "" or name.startsWith(".") or '/' in name or '\\' in name:
      continue
    var title = if p.len > 2: p[2].replace("#c#", ",") else: ""
    let (found, alt) = searchAlt(title)
    let plain = if found: alt else: stripTags(title)
    result.add((name, plain))

type ThreadEntry = tuple[mt: int64, res: string, path: string]

proc parseThreadFileName(n: string): tuple[ok: bool, hidden: bool, res: string] =
  ## re.fullmatch(r'(x?)(\d+)\.html', n) 相当
  if not n.endsWith(".html"):
    return (false, false, "")
  var core = n[0 ..< n.len - 5]
  var hidden = false
  if core.startsWith("x"):
    hidden = true
    core = core[1 ..< core.len]
  if not allDigitsA(core):
    return (false, false, "")
  return (true, hidden, core)

proc listThreads(folder: string): tuple[active, hidden: seq[ThreadEntry]] =
  ## (表示中, 非表示中) のスレッドを更新の新しい順に返す
  result.active = @[]
  result.hidden = @[]
  var names: seq[string] = @[]
  try:
    for kind, name in walkDir("./" & folder, relative = true):
      names.add(name)
  except OSError:
    names = @[]
  for n in names:
    let (okFn, isHidden, res) = parseThreadFileName(n)
    if not okFn:
      continue
    let path = "./" & folder & "/" & n
    var mt: int64
    try:
      mt = getFileInfo(path).lastWriteTime.toUnix()
    except CatchableError:
      continue
    if isHidden:
      result.hidden.add((mt, res, path))
    else:
      result.active.add((mt, res, path))
  let cmpE = proc(a, b: ThreadEntry): int =
    if a.mt != b.mt:
      return cmp(a.mt, b.mt)
    if a.res != b.res:
      return cmp(a.res, b.res)
    return cmp(a.path, b.path)
  result.active.sort(cmpE, SortOrder.Descending)
  result.hidden.sort(cmpE, SortOrder.Descending)

proc threadSummary(path: string): tuple[title: string, count: int] =
  ## (題名, レス数)
  result = ("", 0)
  var content: string
  try:
    content = readFile(path)
  except CatchableError:
    return
  var i = 0
  for line in content.splitLines():
    if i == 0:
      let (found, t) = searchTitleIn(line)
      if found:
        result.title = stripPy(unescapeHtml(t))
    if searchDt(line).found:
      result.count += 1
    inc i

type PostRow = tuple[num: int, name, date, postId, body: string]

proc parseThread(path: string): tuple[title: string, rows: seq[PostRow]] =
  ## (題名, [(番号, 名前, 日時, ID, 本文), ...])
  result = ("", @[])
  var content: string
  try:
    content = readFile(path)
  except CatchableError:
    return
  var i = 0
  for line in content.splitLines():
    if i == 0:
      let (found, t) = searchTitleIn(line)
      if found:
        result.title = stripPy(unescapeHtml(t))
    inc i
    let dt = searchDt(line)
    if not dt.found:
      continue
    let nameRaw = searchNameIn(line)
    let name = if nameRaw != "":
                 stripPy(unescapeHtml(stripTags(nameRaw)))
               else:
                 ""
    var date = searchDateIn(line)
    let postId = searchDataId(line)
    date = stripPy(stripIdTail(date))     # ID は別の列に出す
    var body = searchBodyIn(line)
    body = body.replace("<br>", " ")
    body = unescapeHtml(stripTags(body))
    result.rows.add((dt.num, name, date, postId, body))

proc fmtTime(ts: int64): string =
  ## 日本時間で '%Y-%m-%d %H:%M'
  let dt = (fromUnix(ts) + initDuration(hours = 9)).utc()
  return pad4(dt.year) & "-" & pad2(ord(dt.month)) & "-" & pad2(dt.monthday) &
         " " & pad2(dt.hour) & ":" & pad2(dt.minute)

proc runesToStr(rs: openArray[Rune]): string =
  result = ""
  for r in rs:
    result.add(toUTF8(r))

# ---- 画面 ------------------------------------------------------------------

proc showBoards(pw: string) {.noreturn.} =
  var rows = ""
  for (name, plain) in readBoards():
    rows.add("<tr><td>" & E(name) & "</td><td>" & E(plain) & "</td><td>" &
             btn(pw, "開く", [("act", "threads"), ("folder", name)]) &
             "</td></tr>")
  var body: string
  if rows != "":
    body = "<table><tr><th>板</th><th>名称</th><th></th></tr>" & rows & "</table>"
  else:
    body = "<p>板がありません。</p>"
  page("板の一覧", body)

proc showThreads(pw, folder: string, message: string = "", ok: bool = true) {.noreturn.} =
  let (active, hiddenList) = listThreads(folder)

  var rows = ""
  for e in active[0 ..< min(active.len, LIST_LIMIT)]:
    let (title, count) = threadSummary(e.path)
    rows.add("<tr><td>" & (if E(title) != "": E(title) else: "(題名なし)") &
             "</td><td>" & $count & "</td><td>" & fmtTime(e.mt) & "</td><td>" &
             (if threadIsLocked(folder, e.res): "🔒" else: "") & "</td><td>" &
             btn(pw, "レスを見る", [("act", "replies"), ("folder", folder), ("res", e.res)]) & " " &
             btn(pw, "鍵の管理", [("act", "keys"), ("folder", folder), ("res", e.res)]) & " " &
             btn(pw, "非表示", [("act", "hide"), ("folder", folder), ("res", e.res)],
                 confirm = "このスレッドを非表示にします。よろしいですか?") &
             "</td></tr>")
  var body = msgHtml(message, ok) & nav(pw)
  if rows != "":
    body.add("<table><tr><th>題名</th><th>レス数</th><th>更新</th><th>鍵</th><th></th></tr>" &
             rows & "</table>")
    if active.len > LIST_LIMIT:
      body.add("<p>新しい順に " & $LIST_LIMIT & " 件だけ表示しています (全 " &
               $active.len & " 件)。</p>")
  else:
    body.add("<p>表示中のスレッドはありません。</p>")

  var hrows = ""
  for e in hiddenList[0 ..< min(hiddenList.len, LIST_LIMIT)]:
    let (title, count) = threadSummary(e.path)
    hrows.add("<tr><td>" & (if E(title) != "": E(title) else: "(題名なし)") &
              "</td><td>" & $count & "</td><td>" & fmtTime(e.mt) & "</td><td>" &
              btn(pw, "復元", [("act", "restore"), ("folder", folder), ("res", e.res)]) &
              "</td></tr>")
  if hrows != "":
    body.add("<h3>非表示中のスレッド</h3>" &
             "<table><tr><th>題名</th><th>レス数</th><th>更新</th><th></th></tr>" &
             hrows & "</table>")

  page("「" & folder & "」のスレッド", body)

proc showReplies(pw, folder, res: string, message: string = "",
                 ok: bool = true) {.noreturn.} =
  let path = "./" & folder & "/" & res & ".html"
  if not fileExists(path):
    fatal(pw, "スレッドがありません。(非表示中の場合は、スレッド一覧から復元してください)")
  let (title, rows) = parseThread(path)

  var trs = ""
  for r in rows:
    let cb = if r.num == 1: "—"
             else: "<input type=\"checkbox\" name=\"del\" value=\"" & $r.num & "\">"
    let runes = r.body.toRunes()
    var short: string
    if runes.len > BODY_PREVIEW:
      short = runesToStr(runes[0 ..< BODY_PREVIEW]) & "…"
    else:
      short = r.body
    trs.add("<tr><td>" & cb & "</td><td>" & $r.num & "</td><td>" & E(r.name) &
            "</td><td>" & E(r.date) & "</td><td>" & E(r.postId) &
            "</td><td class=\"body\">" & E(short) & "</td></tr>")

  let form = "<form method=\"post\" action=\"admin.cgi\">" &
    hidden(pw, [("act", "delete"), ("folder", folder), ("res", res)]) &
    "<table><tr><th>削除</th><th>No</th><th>名前</th><th>日時</th><th>ID</th><th>本文</th></tr>" &
    trs & "</table>" &
    "<p><button type=\"submit\" onclick=\"return confirm('選択したレスを削除します。よろしいですか?')\">" &
    "選択したレスを削除</button></p></form>"

  let body = msgHtml(message, ok) & nav(pw, folder) & form &
    "<p>1番は削除できません。スレッドごと消す場合は「非表示」を使ってください。</p>" &
    "<p>" & btn(pw, "このスレッドを非表示にする",
                [("act", "hide"), ("folder", folder), ("res", res)],
                confirm = "このスレッドを非表示にします。よろしいですか?") & "</p>"
  page((if title != "": title else: "(題名なし)") & " (" & folder & "/" & res & ")", body)

proc showKeys(pw, folder, res: string, message: string = "", ok: bool = true,
              issued: string = "") {.noreturn.} =
  ## 鍵の管理: 鍵のかけ外し、キーの発行・失効。発行したキーは、この画面に1度だけ出す
  let path = "./" & folder & "/" & res & ".html"
  if not fileExists(path):
    fatal(pw, "スレッドがありません。")
  let (title, _) = threadSummary(path)
  let locked = threadIsLocked(folder, res)

  var body = msgHtml(message, ok) & nav(pw, folder)
  if issued != "":
    body.add("<div class=\"keybox\"><b>キーを発行しました。この画面を閉じると、二度と表示されません。</b>" &
             "<br>いまのうちに控えて、書き込んでよい人に渡してください。<br><br>" &
             "<code>" & E(issued) & "</code></div>")
  body.add("<p>状態: <b>" & (if locked: "🔒 鍵つき (認証キーがないと書き込めません)"
                             else: "鍵なし (誰でも書き込めます)") & "</b></p><p>")
  if locked:
    body.add(btn(pw, "鍵を外す", [("act", "unlock"), ("folder", folder), ("res", res)],
                 confirm = "このスレッドの鍵を外して、誰でも書き込めるようにします。よろしいですか?") & " " &
             btn(pw, "書き込みフォームを作り直す", [("act", "lock"), ("folder", folder), ("res", res)]))
  else:
    body.add(btn(pw, "鍵をかける", [("act", "lock"), ("folder", folder), ("res", res)],
                 confirm = "このスレッドに鍵をかけます。キーを持たない人は書き込めなくなります。よろしいですか?"))
  body.add("</p><p>※ 鍵つきでも、読むのは誰でもできます。</p>")

  var rows = ""
  for r in keysLoad(folder):
    if r.scope != "*" and r.scope != res:
      continue        # このスレッドで使えるキーだけ
    let active = r.status == "active"
    rows.add("<tr><td>" & E(r.id) & "</td><td>" & E(r.label) & "</td><td>" &
             (if r.scope == "*": "この板の鍵つきスレッドどれでも" else: "このスレッドだけ") &
             "</td><td>" & fmtTime(int64(r.created)) & "</td><td>" &
             (if active: "有効" else: "失効") & "</td><td>" &
             (if active:
                btn(pw, "失効", [("act", "revoke"), ("id", r.id), ("folder", folder), ("res", res)],
                    confirm = (if r.scope == "*":
                                 "このキーは、この板の鍵つきスレッド全部で使えなくなります。よろしいですか?"
                               else:
                                 "このキーを失効します。よろしいですか?"))
              else: "") &
             "</td></tr>")
  body.add("<h3>キー</h3>")
  if rows != "":
    body.add("<table><tr><th>ID</th><th>ラベル</th><th>範囲</th><th>発行日時</th><th>状態</th><th></th></tr>" &
             rows & "</table>")
  else:
    body.add("<p>このスレッドで使えるキーはまだありません。</p>")
  body.add("<h3>キーを発行する</h3>" &
    "<form method=\"post\" action=\"admin.cgi\">" &
    hidden(pw, [("act", "issue"), ("folder", folder), ("res", res)]) &
    "ラベル (誰に渡すか。40文字まで) <input type=\"text\" name=\"label\" size=\"24\"><br>" &
    "範囲 <label><input type=\"radio\" name=\"scope\" value=\"thread\" checked> このスレッドだけ</label> " &
    "<label><input type=\"radio\" name=\"scope\" value=\"board\"> この板の鍵つきスレッドどれでも</label><br>" &
    "<button type=\"submit\">発行</button></form>" &
    "<p>鍵をかける前にキーを発行しても、あとから発行してもかまいません。" &
    "キーは発行したときに1度だけ表示されます (サーバーにはハッシュしか残りません)。</p>")
  page("鍵の管理: " & (if title != "": title else: "(題名なし)") &
       " (" & folder & "/" & res & ")", body)

# ---- 操作 ------------------------------------------------------------------

proc doSetLock(folder, res: string, on: bool): tuple[ok: bool, msg: string] =
  if not fileExists("./" & folder & "/" & res & ".html"):
    return (false, "スレッドがありません。")
  if not threadSetLock(folder, res, on):
    return (false, "鍵の印のファイルを更新できませんでした。")
  if on:
    return (true, "スレッド " & res & " に鍵をかけました。")
  return (true, "スレッド " & res & " の鍵を外しました。")

proc splitKeepEnds(s: string): seq[string] =
  ## Python の readlines() 相当 (改行を残して分割)
  result = @[]
  var start = 0
  for i in 0 ..< s.len:
    if s[i] == '\n':
      result.add(s[start .. i])
      start = i + 1
  if start < s.len:
    result.add(s[start ..< s.len])

proc doDelete(folder, res: string, nums: seq[int]): tuple[ok: bool, msg: string] =
  let path = "./" & folder & "/" & res & ".html"
  var targets: seq[int] = @[]
  for n in nums:
    if n != 1:
      targets.add(n)
  if targets.len == 0:
    return (false, "削除するレスが選ばれていません。(1番は削除できません)")
  if not fileExists(path):
    return (false, "スレッドがありません。")

  var removed = 0
  var stamp: tuple[found: bool, y, mo, d, h, mi, s: int] = (false, 0, 0, 0, 0, 0, 0)
  var origMtime: int64 = 0
  var f: File
  try:
    f = open(path, fmReadWriteExisting)
    lockFile(f)
    origMtime = getFileInfo(path).lastWriteTime.toUnix()
    f.setFilePos(0)
    let content = f.readAll()
    var keep: seq[string] = @[]
    for line in splitKeepEnds(content):
      let dt = searchDt(line)
      if dt.found and dt.num in targets:
        removed += 1
        continue
      let ds = searchDateStamp(line)
      if ds.found:
        stamp = ds
      keep.add(line)
    f.setFilePos(0)
    discard posix.ftruncate(cint(f.getFileHandle()), 0)
    for line in keep:
      f.write(line)
    f.flushFile()
    unlockFile(f)
    f.close()
  except OSError:
    try:
      f.close()
    except CatchableError:
      discard
    return (false, "削除中にファイルエラーが発生しました。")

  # 更新日時を「残った最後のレスの日時」に戻す (一覧の順位が変わらないように)
  var ts = origMtime
  if stamp.found:
    let (okE, ets) = stampToEpoch(stamp.y, stamp.mo, stamp.d, stamp.h,
                                  stamp.mi, stamp.s)
    if okE:
      ts = ets
  var tvs: array[2, Timeval]
  tvs[0].tv_sec = posix.Time(ts + 1)
  tvs[1].tv_sec = posix.Time(ts + 1)
  discard posix.utimes(path.cstring, addr tvs)
  return (true, $removed & "件のレスを削除しました。")

proc doHide(folder, res: string): tuple[ok: bool, msg: string] =
  let src = "./" & folder & "/" & res & ".html"
  let dst = "./" & folder & "/x" & res & ".html"
  if not fileExists(src):
    return (false, "スレッドがありません。")
  if fileExists(dst):
    return (false, "同じ番号の非表示スレッドが既にあるため、処理できません。")
  try:
    moveFile(src, dst)
    if posix.chmod(dst.cstring, Mode(0o600)) != 0:
      raise newException(OSError, "chmod failed")
  except OSError:
    return (false, "スレッドの非表示化に失敗しました。")
  return (true, "スレッド " & res & " を非表示にしました。")

proc doRestore(folder, res: string): tuple[ok: bool, msg: string] =
  let src = "./" & folder & "/x" & res & ".html"
  let dst = "./" & folder & "/" & res & ".html"
  if not fileExists(src):
    return (false, "非表示のスレッドがありません。")
  if fileExists(dst):
    return (false, "同じ番号の表示中スレッドが既にあるため、復元できません。")
  try:
    moveFile(src, dst)
    if posix.chmod(dst.cstring, Mode(0o644)) != 0:
      raise newException(OSError, "chmod failed")
  except OSError:
    return (false, "スレッドの復元に失敗しました。")
  return (true, "スレッド " & res & " を復元しました。")

proc regen(folder: string): string =
  ## 板の index を作り直す。戻り値は補足メッセージ (問題なければ空)
  let (_, status) = regenIndex(folder, 1, false, useCache = false)
  if status != "done":
    return " (他の処理が再生成中のため、板の一覧の更新は省略されました)"
  return ""

# ---- フォーム解析 (urllib.parse.parse_qs 相当) --------------------------------

type FormParams = OrderedTable[string, seq[string]]

proc hexValC(c: char): int =
  case c
  of '0' .. '9': ord(c) - 48
  of 'a' .. 'f': ord(c) - 87
  of 'A' .. 'F': ord(c) - 55
  else: -1

proc qsDecode(s: string): string =
  ## parse_qs の値の復号: '+' -> ' '、%XX -> バイト列、全体を UTF-8 (replace) に
  var raw = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '+':
      raw.add(' ')
      inc i
    elif c == '%' and i + 2 < s.len and hexValC(s[i + 1]) >= 0 and
         hexValC(s[i + 2]) >= 0:
      raw.add(char(hexValC(s[i + 1]) * 16 + hexValC(s[i + 2])))
      i += 3
    else:
      raw.add(c)
      inc i
  return utf8Lossy(raw)

proc parseForm(body: string): FormParams =
  result = initOrderedTable[string, seq[string]]()
  for pair in body.split('&'):
    if pair.len == 0:
      continue
    let eq = pair.find('=')
    var k, v: string
    if eq < 0:
      k = qsDecode(pair)
      v = ""
    else:
      k = qsDecode(pair[0 ..< eq])
      v = qsDecode(pair[eq + 1 ..< pair.len])
    if result.hasKey(k):
      result[k].add(v)
    else:
      result[k] = @[v]

proc getP(params: FormParams, key: string): string =
  if params.hasKey(key) and params[key].len > 0:
    return params[key][0]
  return ""

proc isResValid(res: string): bool =
  ## re.fullmatch(r'\d{1,20}', res) 相当
  return res.len >= 1 and res.len <= 20 and allDigitsA(res)

proc isKeyIdValid(s: string): bool =
  ## re.fullmatch(r'[A-Z2-7]{4}', s) 相当
  if s.len != 4:
    return false
  for c in s:
    if c notin {'A' .. 'Z', '2' .. '7'}:
      return false
  return true

proc parseContentLength(s: string): int =
  ## Python の int() 近似 (失敗したら 0)
  let t = s.strip()
  if t == "":
    return 0
  var i = 0
  var neg = false
  if t[0] == '+' or t[0] == '-':
    neg = t[0] == '-'
    i = 1
  if i >= t.len:
    return 0
  var v: int64 = 0
  while i < t.len:
    if t[i] notin {'0' .. '9'}:
      return 0
    if v < 1_000_000_000_000_000_000:
      v = v * 10 + (ord(t[i]) - 48)
    inc i
  if neg:
    v = -v
  if v > int64(high(int)):
    return high(int)
  if v < int64(low(int)):
    return low(int)
  return int(v)

# ---- メイン ----------------------------------------------------------------

proc main() =
  try:
    setCurrentDir(getAppDir())
  except CatchableError:
    discard
  applyConfig()

  let reqMethod = getEnv("REQUEST_METHOD", "GET")
  var params = initOrderedTable[string, seq[string]]()
  if reqMethod == "POST":
    let n = parseContentLength(getEnv("CONTENT_LENGTH", "0"))
    if n < 0 or n > MAX_BODY:
      page("エラー", msgHtml("送信内容が大きすぎます。", false))
    var raw = newString(n)
    var off = 0
    while off < n:
      let r = stdin.readBuffer(addr raw[off], n - off)
      if r <= 0:
        break
      off += r
    raw.setLen(off)
    params = parseForm(utf8Lossy(raw))

  let pw = getP(params, "adminpass")
  if reqMethod != "POST" or pw == "":
    loginPage()
  if not authenticate(pw):
    loginPage("パスワードが違います。")

  var act = getP(params, "act")
  if act == "":
    act = "boards"
  if act == "boards":
    showBoards(pw)

  let folder = getP(params, "folder")
  if folder == "" or '/' in folder or '\\' in folder or ".." in folder or
     not isBoard(folder):
    fatal(pw, "板名が不正です。")
  if act == "threads":
    showThreads(pw, folder)

  let res = getP(params, "res")
  if not isResValid(res):
    fatal(pw, "スレッド番号が不正です。")

  if act == "replies":
    showReplies(pw, folder, res)
  elif act == "keys":
    showKeys(pw, folder, res)
  elif act == "lock" or act == "unlock":
    let (ok, message0) = doSetLock(folder, res, act == "lock")
    var message = message0
    if ok:
      message.add(regen(folder))
    showKeys(pw, folder, res, message, ok)
  elif act == "issue":
    let scope = if getP(params, "scope") == "board": "*" else: res
    let r = keyIssue(folder, getP(params, "label"), scope)
    if not r.ok or r.display == "":
      showKeys(pw, folder, res, "キーを保存できませんでした。", false)
    showKeys(pw, folder, res, regen(folder), true, r.display)
  elif act == "revoke":
    let keyId = getP(params, "id")
    let ok = isKeyIdValid(keyId) and keyRevoke(folder, keyId)
    var message = if ok: "キー " & keyId & " を失効しました。"
                  else: "キーを失効できませんでした。"
    if ok:
      message.add(regen(folder))
    showKeys(pw, folder, res, message, ok)
  elif act == "delete":
    var nums: seq[int] = @[]
    if params.hasKey("del"):
      for x in params["del"]:
        if x.len >= 1 and x.len <= 6 and allDigitsA(x):
          nums.add(parseDigitsCapped(x))
    let (ok, message0) = doDelete(folder, res, nums)
    var message = message0
    if ok:
      message.add(regen(folder))
    showReplies(pw, folder, res, message, ok)
  elif act == "hide":
    let (ok, message0) = doHide(folder, res)
    var message = message0
    if ok:
      message.add(regen(folder))
    showThreads(pw, folder, message, ok)
  elif act == "restore":
    let (ok, message0) = doRestore(folder, res)
    var message = message0
    if ok:
      message.add(regen(folder))
    showThreads(pw, folder, message, ok)
  else:
    fatal(pw, "不明な操作です。")

main()
