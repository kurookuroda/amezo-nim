## bbsindex.nim - 板の index 再生成 (amezo.py の scan_threads / read_thread_tail /
## read_thread_excerpt / write_index_page / regen_index の移植)
##
## Python との対応:
## - 並び順: 更新日時の新しい順、同じ秒ならファイル名の新しい順
## - 退避 (o数字.html への改名) は1ページ目の再生成のときだけ
## - kako.txt の作り直しは、無い (または空の) ときだけ。退避済みの名前もそのときだけ集める
## - 書き出しは一時ファイル + rename で、元のファイルの権限を引き継ぐ

import std/[os, strutils, algorithm, times, posix]
import bbs

type
  ThreadEntry = tuple[ts, name: string]

proc threadCmpDesc(a, b: ThreadEntry): int =
  ## 更新日時の新しい順。同じ秒ならファイル名の新しい順
  if a.ts != b.ts: cmp(b.ts, a.ts) else: cmp(b.name, a.name)

type
  BoardView* = object
    title0*, amezoName*, suffix*, bgAttr*, color*, textAttr*, title*: string

# ---------------------------------------------------------------------------
# 小物
# ---------------------------------------------------------------------------

proc tsStr(m: int64): string =
  ## Python の f"{mtime:011d}"
  let s = $m
  if s.len >= 11: s else: repeat('0', 11 - s.len) & s

proc fileMtime(path: string): int64 =
  try:
    getFileInfo(path).lastWriteTime.toUnix()
  except OSError:
    0

proc nowSec(): int64 =
  getTime().toUnix()

proc isThreadFile(name: string): bool =
  ## ^\d+\.html$ (ASCII の数字だけを見る)
  if not name.endsWith(".html"): return false
  let base = name[0 ..< name.len - 5]
  base.len > 0 and allCharsInSet(base, {'0' .. '9'})

proc oldBaseName(name: string): string =
  ## ^(o\d+\.html)(?:\.gz)?$ に合えば 'o数字.html'、合わなければ ""
  var n = name
  if n.endsWith(".gz"): n = n[0 ..< n.len - 3]
  if n.len >= 7 and n[0] == 'o' and n.endsWith(".html"):
    let digits = n[1 ..< n.len - 5]
    if digits.len > 0 and allCharsInSet(digits, {'0' .. '9'}):
      return n
  return ""

proc splitKeepNl(data: string): seq[string] =
  ## 改行を各行の末尾に残したまま分ける (Python の行イテレーション相当)
  result = @[]
  var start = 0
  for i in 0 ..< data.len:
    if data[i] == '\n':
      result.add(data[start .. i])
      start = i + 1
  if start < data.len:
    result.add(data[start .. ^1])

proc extractTitle(firstLine: string): string =
  ## <b>([^<]*)</b> の最初の一致の中身。無ければ ""
  var pos = 0
  while true:
    let b = firstLine.find("<b>", pos)
    if b < 0: return ""
    var i = b + 3
    let start = i
    while i < firstLine.len and firstLine[i] != '<':
      inc i
    if i + 4 <= firstLine.len and firstLine[i .. i + 3] == "</b>":
      return firstLine[start ..< i]
    pos = b + 3

# ---------------------------------------------------------------------------
# スレッドの走査
# ---------------------------------------------------------------------------

proc scanThreads*(folder: string, wantOld: bool): tuple[
    files: seq[tuple[ts, name: string]], oldNames: seq[string]] =
  ## 板のフォルダを調べる。戻り値: (スレッド [(更新時刻の文字列, ファイル名)] を新しい順,
  ## 退避済みのファイル名の一覧)。同じ秒のときはファイル名の新しい順。
  var files: seq[tuple[ts, name: string]] = @[]
  var oldNames: seq[string] = @[]
  var oldSeen: seq[string] = @[]
  try:
    for kind, name in walkDir("./" & folder, relative = true):
      discard kind
      if isThreadFile(name):
        files.add((tsStr(fileMtime("./" & folder & "/" & name)), name))
      elif wantOld:
        let base = oldBaseName(name)   # 平文と gz が両方あっても1つ。.gz.tmp* は含まない
        if base != "" and base notin oldSeen:
          oldSeen.add(base)
          oldNames.add(base)
  except OSError:
    discard
  files.sort(threadCmpDesc)
  result = (files: files, oldNames: oldNames)

# ---------------------------------------------------------------------------
# スレッドの抜粋
# ---------------------------------------------------------------------------

proc readThreadTail*(path: string, size: int): tuple[
    ok: bool, first: string, tail: seq[string], count: int] =
  ## 大きなスレッドのファイルから、先頭行と最後の7レスだけを読む。
  ## 形が想定と違えば ok=false (呼び出し側が全部読む)。
  ## 想定: 改行が \n だけで、最後に <form で始まる行が1つあり、その前の行が <dl><dt> で始まる。
  ## レス行の総数は、ファイル全体の改行を数えて求める (少しずつ読むので、メモリは増えない。
  ## 管理画面でレスを消すと番号に飛びが出るので、最後の番号からは数えない)。
  result = (ok: false, first: "", tail: @[], count: 0)
  var
    head = ""
    tailData = ""
    firstEnd = -1
    chunkStart = 0
  try:
    var f = open(path, fmRead)
    defer: f.close()
    let headLen = min(65536, size)
    if headLen > 0:
      head = newString(headLen)
      let got = f.readBuffer(head[0].addr, headLen)
      head.setLen(got)
    firstEnd = head.find('\n')
    if firstEnd < 0 or '\r' in head:
      return
    chunkStart = max(firstEnd + 1, size - TAIL_CHUNK)
    f.setFilePos(chunkStart)
    tailData = f.readAll()
  except OSError, IOError:
    return
  if '\r' in tailData:
    return
  if chunkStart > firstEnd + 1:             # 読み始めが行の途中なので、最初の1行は捨てる
    let cut = tailData.find('\n')
    if cut < 0:
      return
    tailData = tailData[cut + 1 .. ^1]
  let lines = splitKeepNl(tailData)
  var formIdx: seq[int] = @[]
  for i, l in lines:
    if l.startsWith("<form"):
      formIdx.add(i)
  if formIdx.len != 1:
    return
  let reply = lines[0 ..< formIdx[0]]
  if reply.len < 7:
    return
  let last7 = reply[^7 .. ^1]
  for l in last7:
    if not l.startsWith("<dl><dt>"):
      return
  var totalNl = 0
  try:
    var f = open(path, fmRead)
    defer: f.close()
    var buf = newString(65536)
    while true:
      let n = f.readBuffer(buf[0].addr, buf.len)
      if n <= 0:
        break
      for i in 0 ..< n:
        if buf[i] == '\n':
          inc totalNl
  except OSError, IOError:
    return
  let totalLines = totalNl + (if tailData.endsWith('\n'): 0 else: 1)
  let afterForm = lines.len - formIdx[0]        # <form の行から最後までの行数
  result = (ok: true, first: head[0 .. firstEnd], tail: last7,
            count: totalLines - 1 - afterForm)  # 先頭行と、<form 以降を除いた、レス行の数

proc readThreadExcerpt*(path: string): tuple[
    ok: bool, first: string, tail: seq[string], count: int] =
  ## スレッドのファイルから、表示に使う部分を取り出す。
  ## 戻り値: (先頭行, 最後の7レス, レス行の総数)。読めなければ ok=false。
  result = (ok: false, first: "", tail: @[], count: 0)
  var size: int
  try:
    size = int(getFileSize(path))
  except OSError:
    return
  if size > TAIL_MIN_SIZE:
    let r = readThreadTail(path, size)
    if r.ok:
      return r
  var data: string
  try:
    data = readFile(path)
  except OSError, IOError:
    return
  let parts = splitKeepNl(data)
  let first = if parts.len > 0: parts[0] else: ""
  var lines: seq[string] = @[]
  for i in 1 ..< parts.len:
    if parts[i].startsWith("<form"):
      break
    lines.add(parts[i])
  let tail = if lines.len == 0: newSeq[string]()
             else: lines[max(lines.len - 7, 0) .. ^1]
  result = (ok: true, first: first, tail: tail, count: lines.len)

# ---------------------------------------------------------------------------
# index ページの書き出し
# ---------------------------------------------------------------------------

proc removeTagPattern(s: string, names: openArray[string],
                      allowSlash: bool): string =
  ## </?(?:名前|名前)[^>]*> を取り除く (Python の re.sub 相当。[ ^>]* は < を含んでもよい)
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '<':
      var j = i + 1
      if allowSlash and j < s.len and s[j] == '/':
        inc j
      var matched = false
      for name in names:
        if s.continuesWith(name, j):
          let gt = s.find('>', j + name.len)
          if gt >= 0:
            i = gt + 1
            matched = true
          break
      if matched:
        continue
    result.add(s[i])
    inc i

proc removePaired(s: string, openTag: string, closeTag: string): string =
  ## <title>.*?</title> のような組を取り除く (Python の re.sub 相当)
  result = s
  while true:
    let a = result.find(openTag)
    if a < 0:
      return
    let b = result.find(closeTag, a + openTag.len)
    if b < 0:
      return
    if '\n' in result[a ..< b]:
      return                       # Python の . は改行を越えない
    result = result[0 ..< a] & result[b + closeTag.len .. ^1]

proc removeScript(s: string): string =
  ## <script[^>]*></script> を取り除く (Python の re.sub 相当)
  result = ""
  var i = 0
  while i < s.len:
    if s.continuesWith("<script", i):
      let gt = s.find('>', i + 7)
      if gt >= 0 and s.continuesWith("</script>", gt + 1):
        i = gt + 1 + "</script>".len
        continue
    result.add(s[i])
    inc i

proc stripFirstLine(s: string): string =
  ## スレッドの先頭行から html/head/body/meta/title/link/script を削る
  result = s.removeTagPattern(["html", "head", "body"], true)
  result = result.removeTagPattern(["meta", "link"], false)
  result = result.removePaired("<title>", "</title>")
  result = result.removeScript()

proc writeIndexPage*(W: File, folder: string, page, total: int,
                     files: seq[tuple[ts, name: string]], v: BoardView) =
  ## index の内容を W に書く。v: 板の見た目の情報 (regenIndex が作る)
  let pager = pagerHtml(folder, page, total)
  W.write("<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">\n" &
          "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" &
          "<link rel=\"stylesheet\" href=\"../style.css\">" & SCRIPT_TAG & "\n" &
          "<title>" & v.title0 & v.amezoName & v.suffix & "</title></head>\n" &
          COPYRIGHT & "\n" &
          "<body" & v.bgAttr & " bgcolor=\"" & v.color & "\"" & v.textAttr & ">\n" &
          "<font size=+2>" & v.title & v.amezoName & v.suffix & "</font>\n")

  if fileExists("./header.html"):
    try:
      W.write(readFile("./header.html"))
    except OSError, IOError:
      discard

  W.write(pager & "<font size=2>\n<!-- HEAD LINE -->\n")

  let startIdx = (page - 1) * PER_PAGE
  for i in startIdx ..< startIdx + HEADLINE_COUNT:
    if i >= files.len:
      break
    let fName = files[i].name
    var ttl = ""
    try:
      var rf = open("./" & folder & "/" & fName, fmRead)
      var firstLine = ""
      if rf.readLine(firstLine):
        ttl = extractTitle(firstLine)
      rf.close()
    except OSError, IOError:
      ttl = ""
    W.write(" " & $(i + 1) & "<a href=\"" & fName & "\">" & ttl & "</a>\n")

  W.write("<!-- HEAD LINE END -->\n</font>\n")
  if kakoListSize(folder) > 0:
    W.write("<div class=\"row links\"><a href=\"" & KAKO_FILE & "\">過去ログ</a></div>\n")

  # 各スレッドの内容表示
  for i in startIdx ..< startIdx + PER_PAGE:
    if i >= files.len:
      break
    let fName = files[i].name
    W.write("<table border=1 cellspacing=1 cellpadding=2 width=100% bgcolor=\"#efefef\"><tr><td><font color=\"#000000\">\n")

    var
      lines: seq[string] = @[]
      nLines = 0
    let ex = readThreadExcerpt("./" & folder & "/" & fName)
    if ex.ok:
      lines = ex.tail
      nLines = ex.count
      W.write(stripFirstLine(ex.first))

    # 最後の7レスのみを抜粋して表示
    for line in lines:
      W.write(line)

    let resId = fName.replace(".html", "")
    var subTag = ""
    if nLines > 200:
      let kIdx = nLines - 98
      subTag = "<input type=text name=\"from\" value=\"" & $kIdx &
               "\" size=\"4\"><input type=submit name=\"sub\" value=\"〜\"> "

    let links = "<div class=\"row links\"><a href=\"" & resId &
                ".html\">レス全部を見る</a> " & subTag &
                "<a href=\"#top\">上へ</a> <a href=\"./\">リロード</a></div>"

    W.write("</font></td></tr></table>\n" &
            replyForm(resId, links, threadIsLocked(folder, resId)) & "<hr>\n")

  W.write(pager & "<hr></body></html>\n")

# ---------------------------------------------------------------------------
# 再生成
# ---------------------------------------------------------------------------

proc boardView(folder: string): BoardView =
  ## blist.txt から板の背景色とタイトル取得
  var
    color = ""
    title = ""
  try:
    var rf = open("./blist.txt", fmRead)
    defer: rf.close()
    for raw in rf.lines:
      let line = raw.strip(leading = false, trailing = true, chars = {'\r', '\n'})
      if line == "":
        continue
      let parts = line.split(',')
      if parts[0] == folder:
        color = if parts.len > 1: parts[1] else: ""
        title = if parts.len > 2: parts[2] else: ""
        break
  except OSError, IOError:
    discard

  result.suffix = if folder == "main": "(メイン)" else: ""

  let colorParts = color.split('!')
  color = colorParts[0]
  if colorParts.len > 1:
    result.bgAttr = " background=\"" & colorParts[1] & "\""

  if color.endsWith('*'):
    result.textAttr = " text=\"#ffffff\" link=\"red\" vlink=\"orange\""
    color = color[0 ..< color.len - 1]
  result.color = color

  title = title.replace("#c#", ",")
  result.title = title
  result.title0 = title
  result.amezoName = AMEZO
  let altPos = title.find("alt=\"")
  if altPos >= 0:
    let start = altPos + 5
    let close = title.find('"', start)
    if close > start:               # Python の正規表現 alt="([^"]+) は1文字以上が要る
      result.title0 = title[start ..< close]
      result.amezoName = ""

proc replaceIndex(tmpPath, indexPath: string) =
  ## 一時ファイルを index に置き換える。元のファイルの権限を引き継ぐ (無ければ 0644)
  try:
    var mode: int
    if fileExists(indexPath):
      var st: Stat
      if stat(indexPath.cstring, st) == 0:
        mode = int(st.st_mode) and 0o7777
      else:
        mode = 0o644
    else:
      mode = 0o644
    if chmod(tmpPath.cstring, Mode(mode)) != 0:
      raise newException(OSError, "chmod failed")
    moveFile(tmpPath, indexPath)
  except OSError:
    try:
      removeFile(tmpPath)
    except OSError:
      discard
    bbsError("indexを更新できません.")

proc isOldIndexPage(name: string): bool =
  ## glob の index[0-9]*.html 相当
  name.len >= 11 and name.startsWith("index") and name[5] in {'0' .. '9'} and
    name.endsWith(".html")

proc regenIndex*(folder: string, page: int = 1, reloadFlag: bool = false,
                 useCache: bool = true): tuple[name: string, status: string] =
  ## 板の index.html (page=1) または index{page}.html を再生成する。
  ## 1ページ目は、投稿のたびに作り直し、古いスレッドの退避と過去ログの更新もする。
  ## 2ページ目以降は、ページ送りのリンクが押されたときだけ、読むだけで作る。
  ## status: 'done' 再生成した / 'cached' 直近に更新済み / 'busy' 他が再生成中 (1ページ目だけ)
  var curPage = max(1, page)
  let v = boardView(folder)

  # ---- 2ページ目以降: 読むだけで、そのページのファイルを作る ----
  if curPage > 1:
    var (files, _) = scanThreads(folder, false)
    if MAX_THREADS > 0 and files.len > MAX_THREADS:
      files.setLen(MAX_THREADS)          # 退避は1ページ目の再生成のときに行うので、ここでは数えないだけ
    let total = totalPages(files.len)
    if curPage > total:
      curPage = total
    if curPage == 1:                     # 範囲外のページは、最後のページに寄せる
      return regenIndex(folder, 1, true, useCache)
    let
      indexName = "index" & $curPage & ".html"
      indexPath = "./" & folder & "/" & indexName
    if useCache and PAGE_CACHE > 0 and fileExists(indexPath):
      if nowSec() - fileMtime(indexPath) < PAGE_CACHE:
        return (name: indexName, status: "cached")
    let tmpPath = indexPath & ".tmp" & $getCurrentProcessId()
    var W: File
    try:
      W = open(tmpPath, fmWrite)
    except OSError, IOError:
      bbsError("indexを書き込めません.")
    writeIndexPage(W, folder, curPage, total, files, v)
    W.close()
    replaceIndex(tmpPath, indexPath)
    return (name: indexName, status: "done")

  # ---- 1ページ目 ----
  let
    indexName = "index.html"
    indexPath = "./" & folder & "/" & indexName

  # キャッシュチェック
  if useCache and reloadFlag and POST_INTERVAL > 0 and fileExists(indexPath):
    if nowSec() - fileMtime(indexPath) < POST_INTERVAL:
      return (name: indexName, status: "cached")

  # ロック獲得とインデックス再生成
  let lockPath = "./" & folder & "/regen.lock"
  if not fileExists(lockPath):
    try:
      writeFile(lockPath, "")
    except OSError, IOError:
      bbsError("ロックファイルを作成できません.")
  var LK: File
  try:
    LK = open(lockPath, fmAppend)
  except OSError, IOError:
    bbsError("ロックファイルを作成できません.")

  var locked = tryLockFile(LK)
  if not locked and not reloadFlag:
    # ブロッキングロック (CGIタイムアウトを考慮し最大10秒)
    for _ in 1 .. 100:
      sleep(100)
      if tryLockFile(LK):
        locked = true
        break

  if not locked:
    LK.close()
    return (name: indexName, status: "busy")

  # ディレクトリ走査してヘッドラインをソート生成
  # 退避済みの名前は、過去ログ一覧を作り直すときだけ集める (何万本あっても普段は溜めない)
  var (files, oldNames) = scanThreads(folder, kakoListSize(folder) <= 0)
  var retiredNow: seq[tuple[ts, name: string]] = @[]

  # 古いスレッドを退避 (oスレッドID.html)
  if MAX_THREADS > 0:
    var
      nThr = 0
      filtered: seq[tuple[ts, name: string]] = @[]
    for (ts, fName) in files:
      inc nThr
      if nThr > MAX_THREADS:
        if not archivedExists(folder, fName[0 ..< fName.len - 5]):
          try:
            moveFile("./" & folder & "/" & fName, "./" & folder & "/o" & fName)
            retiredNow.add((ts, "o" & fName))
            try:
              removeFile("./" & folder & "/" & fName[0 ..< fName.len - 5] & ".lock")
            except OSError:
              discard
          except OSError:
            discard
      else:
        filtered.add((ts, fName))
    files = filtered

  # 過去ログの題名一覧 (kako.txt): 退避したスレッドの題名を追記していくので、
  # 退避済みのファイルを毎回開かずに済む。無い (または空の) ときだけ、今ある o〜.html から作る。
  var kakoChanged = false
  if kakoListSize(folder) <= 0:
    if oldNames.len > 0 or retiredNow.len > 0:
      var names = oldNames
      for (_, n) in retiredNow:
        names.add(n)
      kakoChanged = rebuildKakoList(folder, names)
  elif retiredNow.len > 0:
    kakoChanged = appendKakoList(folder, retiredNow)
  let hasKako = kakoListSize(folder) > 0

  let tmpPath = indexPath & ".tmp" & $getCurrentProcessId()
  var W: File
  try:
    W = open(tmpPath, fmWrite)
  except OSError, IOError:
    unlockFile(LK)
    LK.close()
    bbsError("indexを書き込めません.")

  writeIndexPage(W, folder, 1, totalPages(files.len), files, v)
  W.close()
  replaceIndex(tmpPath, indexPath)

  # 過去ログ一覧 (kako.html): 題名の一覧が変わったとき、またはまだ無いときだけ作り直す
  if hasKako and (kakoChanged or not fileExists("./" & folder & "/" & KAKO_FILE)):
    writeKako(folder, "<body" & v.bgAttr & " bgcolor=\"" & v.color & "\"" &
                      v.textAttr & ">",
              v.title0, v.amezoName, v.suffix, v.title)

  # 古い「次のページ」のファイルを掃除する
  try:
    for kind, name in walkDir("./" & folder, relative = true):
      discard kind
      if isOldIndexPage(name):
        let p = "./" & folder & "/" & name
        try:
          if nowSec() - fileMtime(p) > 600:
            removeFile(p)
        except OSError:
          discard
  except OSError:
    discard

  try:
    unlockFile(LK)
  except Exception:
    discard
  LK.close()

  result = (name: indexName, status: "done")
