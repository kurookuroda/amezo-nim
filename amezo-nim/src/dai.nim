# dai.cgi の Nim 版 (板一覧 + 各板の HEAD LINE 表示) — dai.py の移植
import os, strutils
import bbs

const HEADLINE_MAX = 20

const PAGE_HEAD =
  "<!DOCTYPE html>\n" &
  "<html lang=\"ja\"><head>\n" &
  "<meta charset=\"UTF-8\">\n" &
  "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" &
  "<base target=\"naka\">\n" &
  "<link rel=\"stylesheet\" href=\"style.css\">\n" &
  "<title>板一覧</title>\n" &
  "</head><body>\n"
const PAGE_FOOT = "</body></html>\n"

proc isValidUtf8(s: string): bool =
  ## 厳密な UTF-8 検査 (Python の utf-8 デコードが失敗するものは失敗させる)
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

proc htmlEscapeStd(s: string): string =
  ## Python の html.escape(s, quote=True) 相当 (dai.py は標準の html モジュールを使う。' は &#x27;)
  result = ""
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    of '\'': result.add("&#x27;")
    else: result.add(c)

proc rstripCrLfLocal(s: string): string =
  ## Python の rstrip('\r\n') 相当
  var e = s.len
  while e > 0 and (s[e - 1] == '\r' or s[e - 1] == '\n'):
    dec e
  return s[0 ..< e]

proc linkFirst(line, folderEscaped: string): string =
  ## 最初の1箇所だけ 1234.html -> folder/1234.html (Perl の s/// と同じ)
  var i = 0
  while i < line.len:
    if line[i] in {'0' .. '9'}:
      var j = i
      while j < line.len and line[j] in {'0' .. '9'}:
        inc j
      if line[j ..< min(line.len, j + 5)] == ".html":
        return line[0 ..< i] & folderEscaped & "/" & line[i ..< line.len]
      i = j
    else:
      inc i
  return line

proc rawLines(data: string): seq[string] =
  ## 改行を残したまま行に分ける (最後の行は改行が無いこともある)
  result = @[]
  var start = 0
  var i = 0
  while i < data.len:
    if data[i] == '\n':
      result.add(data[start .. i])
      start = i + 1
    inc i
  if start < data.len:
    result.add(data[start ..< data.len])

proc readHeadline(folder, folderEscaped: string): seq[string] =
  ## ./<folder>/index.html の HEAD LINE 部分 (最大20行) を返す
  result = @[]
  var data: string
  try:
    data = readFile("./" & folder & "/index.html")
  except OSError, IOError:
    return
  if not isValidUtf8(data):
    return
  let lines = rawLines(data)
  var i = 0
  var found = false
  while i < lines.len:
    let line = lines[i]
    inc i
    if "<!-- HEAD LINE -->" in line:
      found = true
      break
  if not found:
    return
  while i < lines.len:
    let line = lines[i]
    if result.len >= HEADLINE_MAX or "<!-- HEAD LINE END -->" in line:
      break
    inc i
    result.add(linkFirst(line, folderEscaped))

proc main() =
  try:
    setCurrentDir(getAppDir())
  except OSError:
    discard
  applyConfig()
  stdout.write("Content-type: text/html; charset=UTF-8\r\n\r\n")
  stdout.write(PAGE_HEAD)

  var bf: File
  try:
    bf = open("./blist.txt", fmRead)
  except OSError, IOError:
    stdout.write(PAGE_FOOT)
    stdout.flushFile()
    return

  for rawLine in bf.lines:
    let line = rstripCrLfLocal(rawLine)
    if line == "":
      continue
    let parts = line.split(',')
    let folder = parts[0]
    var color = if parts.len > 1: parts[1] else: ""
    var title = if parts.len > 2: parts[2] else: ""

    if folder == "" or folder.startsWith('.') or '/' in folder or ".." in folder:
      continue

    let bang = color.find('!')
    if bang >= 0:
      color = color[0 ..< bang]          # 背景画像の指定は使わない
    while color.endsWith('*'):
      color.setLen(color.len - 1)        # 白文字指定の * は色ではない
    title = title.replace("#c#", ",")    # #c# をカンマに戻す

    let folderEscaped = htmlEscapeStd(folder)
    let colorEscaped = htmlEscapeStd(color)

    stdout.write("<table border=0 cellspacing=1 cellpadding=2 width=100% bgcolor=\"" &
      colorEscaped & "\"><tr><td>\n" &
      "<a href=\"" & folderEscaped & "/\"><b><font size=\"3\" color=\"#F92500\">" &
      title & "</font></b></a>\n")
    for hl in readHeadline(folder, folderEscaped):
      stdout.write(hl)
    stdout.write("</td></tr></table>\n")

  bf.close()
  stdout.write(PAGE_FOOT)
  stdout.flushFile()

main()
