# -*- coding: utf-8 -*-
#
# server.nim - amezo/dai/admin/jump の CGI バイナリを動かす簡易サーバー + Cloudflare Tunnel
# (Python 版 setup_expose.py の移植)
#
#   - /amezo.cgi と /amezo.py はどちらも amezo.cgi バイナリを実行する
#     (フォームの action="../amezo.cgi" のまま動く)
#   - 静的ファイルは「許可リスト方式」で配信する。許可するのは次のものだけ:
#       /  /index.html  /style.css  /hide.js  /ad.html
#       blist.txt に載っている板フォルダの index.html / index2.html / 数字.html
#     delpass.txt, global.mem, ng.txt, x〜.html (非表示スレッド), ソースなどは 404 になる
#   - 許可リスト判定の前に、不正な形のパス ('//' '%' '\' NUL '..' '.' の区間、'/' で始まらない形) は 400 で止める
#     (PHP 版 router.php と同じ。判定はデコードする前の生のパスで行う)
#   - 圧縮済みの過去ログ (o数字.html.gz) は、o数字.html の URL のまま配信する
#
# 接続ごとに fork して処理する (CGI 実行が最大30秒ブロックするのと、
# スレッド間で GC 管理オブジェクトを共有しないため)。

import std/[os, net, nativesockets, strutils, sequtils, tables, times,
            monotimes, osproc, selectors, posix, algorithm, streams, strtabs]
import bbs
import gz

const DefaultPort = 8000

# POST ボディの上限 (amezo 側の上限は 7500 バイト)
const MaxPostBytes = 64 * 1024

# CGI として実行するスクリプト名 (拡張子なし)
const AllowedCgi = ["amezo", "dai", "admin", "jump"]

# 板フォルダの外で配信を許可するパス
const StaticRootFiles = ["/", "/index.html", "/style.css", "/hide.js", "/ad.html"]

const DefaultBoards = ["main", "zatsu", "test"]

var gVerbose = false    # --verbose のとき true (要求行も出す)
var gStop = false       # Ctrl+C で true

# ---- C の小物 (flock の事前確認と signal 用) -----------------------------------
proc cOpen(path: cstring, flags: cint, mode: cint): cint {.
    importc: "open", header: "<fcntl.h>".}
proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}
proc cFlock(fd: cint, op: cint): cint {.importc: "flock",
    header: "<sys/file.h>".}
proc cSignal(sig: cint, handler: pointer): pointer {.
    importc: "signal", header: "<signal.h>".}
proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
var myErrno {.importc: "errno", header: "<errno.h>".}: cint

const O_RDWR_C: cint = 0o2
const O_CREAT_C: cint = 0o100
const LOCK_EX_C: cint = 2
const LOCK_NB_C: cint = 4
const SIGINT_C: cint = 2
const SIGCHLD_C: cint = 17
let SIG_DFL_C = cast[pointer](0)
let SIG_IGN_C = cast[pointer](1)
const EAGAIN_C: cint = 11
const EINTR_C: cint = 4


proc loadBoards(): seq[string] =
  ## blist.txt に載っている板フォルダ名の一覧を返す (毎回読む。小さいファイルなので十分速い)
  result = @[]
  try:
    for line in readFile("blist.txt").splitLines():
      let name = line.strip().split(",")[0]
      if name.len > 0 and not name.startsWith(".") and '/' notin name and
          '\\' notin name:
        if name notin result:
          result.add(name)
  except CatchableError:
    discard


proc checkFlock() =
  ## このディレクトリで flock が効くか確かめる (Google Drive のマウント上では効かないことがある)
  let path = getCurrentDir() / ".flock_test"
  var fd1: cint = -1
  var fd2: cint = -1
  var effective = false
  var failed = false
  var errMsg = ""
  try:
    fd1 = cOpen(path.cstring, O_RDWR_C or O_CREAT_C, 0o600)
    if fd1 < 0:
      raiseOSError(osLastError())
    fd2 = cOpen(path.cstring, O_RDWR_C, 0)
    if fd2 < 0:
      raiseOSError(osLastError())
    discard cFlock(fd1, LOCK_EX_C)
    # fd2 からは (ノンブロッキングでは) 取れないのが正常
    if cFlock(fd2, LOCK_EX_C or LOCK_NB_C) != 0:
      effective = true
  except CatchableError as e:
    failed = true
    errMsg = e.msg
  if fd1 >= 0:
    discard cClose(fd1)
  if fd2 >= 0:
    discard cClose(fd2)
  try:
    removeFile(path)
  except CatchableError:
    discard
  if failed:
    echo "  ⚠️ ロックの確認ができませんでした: " & errMsg
    return
  if not effective:
    echo "  ⚠️ このディレクトリでは flock が効いていません (Google Drive 上など)。"
    echo "     同時に投稿されるとファイルが壊れるおそれがあります。/content などのローカルディスクに置いてください。"


# ---- 1. BBSの初期ディレクトリ・パーミッション設定 ------------------------------
proc setupBbsDirectories() =
  echo "📂 BBS用のディレクトリとパーミッションを設定しています..."

  for cgiBin in ["amezo.cgi", "dai.cgi", "admin.cgi", "jump.cgi"]:
    if fileExists(cgiBin):
      setFilePermissions(cgiBin, {fpUserRead, fpUserWrite, fpUserExec,
          fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
      echo "  - 実行権限付与: " & cgiBin
    else:
      echo "  ⚠️ " & cgiBin & " が見つかりません"

  # フレーム構成に必要なファイルの確認
  for needed in ["index.html", "style.css", "hide.js", "header.html", "blist.txt"]:
    if not fileExists(needed):
      echo "  ⚠️ " & needed & " が見つかりません"

  if not fileExists("delpass.txt"):
    echo "  ℹ️ delpass.txt がありません。削除機能を使うなら次で作成してください:"
    echo "     ./server --make-hash 合言葉"
    echo "     (または: ./amezo.cgi --make-hash 合言葉 > delpass.txt)"

  checkFlock()

  # blist.txt に定義されている板用フォルダを作成
  var boards: seq[string]
  if fileExists("blist.txt"):
    boards = loadBoards()
    boards.sort()
  else:
    boards = @DefaultBoards

  for board in boards:
    if not dirExists(board):
      createDir(board)
      echo "  - フォルダ作成: " & board & "/"
    setFilePermissions(board, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupWrite, fpGroupExec,
        fpOthersRead, fpOthersWrite, fpOthersExec})

    # index.html が無い(または極端に小さい)場合は、再生成を促す転送ページを置く
    let indexPath = board / "index.html"
    if not fileExists(indexPath) or getFileSize(indexPath) < 100:
      writeFile(indexPath,
          "<html><head>" &
          "<meta http-equiv=\"refresh\" content=\"0;url=../amezo.cgi?folder=" &
          board & "\">" &
          "</head><body>Redirecting to BBS...</body></html>")
      # 更新日時を古くして、amezo の「直近に更新済みなら再生成しない」判定を避ける
      setLastModificationTime(indexPath, fromUnix(int64(int(epochTime()) - 3600)))
      echo "  - 初期リダイレクト用ファイルを配置: " & indexPath


proc cleanupOldProcesses(port: int) =
  ## 以前の古いプロセスをクリーンアップ
  echo "🧹 古いWebサーバーやトンネルプロセスをクリーンアップしています..."
  discard execCmd("pkill -f 'cloudflared' 2>/dev/null")
  discard execCmd("fuser -k " & $port & "/tcp 2>/dev/null")
  sleep(2000)


# ---- パスの形の検査 (PHP 版 router.php と同じ) --------------------------------
# REQUEST のパス ('?' より前) を、デコードする前の生のまま使う。
# '//' '%' '\' NUL '..' '.' の区間、'/' で始まらない形 (http://… の絶対形式) は 400 で止める。
proc isMalformedPath(rawPath: string): bool =
  if rawPath.len == 0 or not rawPath.startsWith("/"):
    return true
  if "//" in rawPath or "%" in rawPath or "\\" in rawPath or
      "\x00" in rawPath or ".." in rawPath:
    return true
  for seg in rawPath.split('/'):
    if seg == ".":
      return true
  return false


proc acceptsGzip(header: string): bool =
  ## Accept-Encoding が gzip を受け付けるか (gzip;q=0 は受け付けない)
  for tok in header.split(','):
    let parts = tok.split(';').mapIt(it.strip())
    if parts.len == 0 or (parts[0].toLowerAscii() != "gzip" and
        parts[0].toLowerAscii() != "x-gzip"):
      continue
    var q = 1.0
    for p in parts[1 ..< parts.len]:
      if p.len >= 3 and p[0 .. 1].toLowerAscii() == "q=" and
          p[2 ..< p.len].allCharsInSet({'0'..'9', '.'}):
        try:
          q = parseFloat(p[2 ..< p.len])
        except CatchableError:
          discard
    return q > 0
  return false


# ---- HTTP の小物 ---------------------------------------------------------------
const WdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
const MonthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

proc pad2(n: int): string =
  if n < 10: "0" & $n else: $n

proc httpDate(t: times.Time): string =
  let dt = t.utc
  WdayNames[ord(dt.weekday)] & ", " & pad2(dt.monthday) & " " &
      MonthNames[ord(dt.month) - 1] & " " & $dt.year & " " &
      pad2(dt.hour) & ":" & pad2(dt.minute) & ":" & pad2(dt.second) & " GMT"

proc reasonPhrase(code: int): string =
  case code
  of 200: "OK"
  of 301: "Moved Permanently"
  of 302: "Found"
  of 303: "See Other"
  of 304: "Not Modified"
  of 400: "Bad Request"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 413: "Payload Too Large"
  of 414: "Request-URI Too Long"
  of 500: "Internal Server Error"
  of 501: "Not Implemented"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  of 504: "Gateway Timeout"
  else: "Unknown"

proc explainPhrase(code: int): string =
  case code
  of 301: "The document has moved"
  of 400: "Bad request syntax or unsupported method"
  of 404: "Nothing matches the given URI"
  of 413: "Request entity is too large"
  of 414: "The request line is too long"
  of 500: "Server got itself in trouble"
  of 501: "Server does not support this operation"
  of 504: "Gateway timeout"
  else: "???"


type ClientConn = ref object
  sock: Socket
  buf: string
  ip: string
  serverPort: int
  headers: seq[tuple[name, value: string]]

proc sendAll(c: ClientConn, data: string) =
  var pos = 0
  let fd = c.sock.getFd()
  while pos < data.len:
    var n = 0
    try:
      n = int(nativesockets.send(fd, addr data[pos], data.len - pos, 0.cint))
    except CatchableError:
      return
    if n <= 0:
      return
    pos += n

proc respondHead(c: ClientConn, code: int,
                 headers: seq[tuple[name, value: string]],
                 bodyLen: int = -1) =
  var s = "HTTP/1.1 " & $code & " " & reasonPhrase(code) & "\r\n"
  s &= "Server: NimCGI/1.1\r\n"
  s &= "Date: " & httpDate(getTime()) & "\r\n"
  for (k, v) in headers:
    s &= k & ": " & v & "\r\n"
  if bodyLen >= 0:
    s &= "Content-Length: " & $bodyLen & "\r\n"
  s &= "Connection: close\r\n\r\n"
  c.sendAll(s)

proc sendError(c: ClientConn, code: int, message: string) =
  let body = "<!DOCTYPE HTML>\n<html lang=\"en\">\n    <head>\n" &
      "        <meta charset=\"utf-8\">\n        <title>Error response</title>\n" &
      "    </head>\n    <body>\n        <h1>Error response</h1>\n" &
      "        <p>Error code: " & $code & "</p>\n" &
      "        <p>Message: " & htmlEscape(message) & ".</p>\n" &
      "        <p>Error code explanation: " & $code & " - " &
      explainPhrase(code) & ".</p>\n    </body>\n</html>\n"
  c.respondHead(code, @[("Content-Type", "text/html;charset=utf-8")], body.len)
  c.sendAll(body)

proc getHeader(c: ClientConn, name: string): string =
  let ln = name.toLowerAscii()
  for (k, v) in c.headers:
    if k.toLowerAscii() == ln:
      return v
  return ""

proc rawRecvOnce(c: ClientConn, want: int, timeoutMs: int): string =
  ## poll で読み可能を待ってから、生の recv を1回だけする ("" は EOF・時間切れ・失敗)。
  ## std/net の recv は buffered ソケットだと要求サイズを読み切るまで待つので使わない
  var pfd = TPollfd(fd: cint(c.sock.getFd()), events: POLLIN)
  if posix.poll(addr pfd, 1, cint(timeoutMs)) <= 0:
    return ""
  var tmp = newString(want)
  let n = nativesockets.recv(c.sock.getFd(), addr tmp[0], tmp.len, 0.cint)
  if n <= 0:
    return ""
  tmp.setLen(n)
  return tmp

proc connRecv(c: ClientConn): bool =
  ## ソケットから1回分読んでバッファに足す。読めなければ false
  let data = c.rawRecvOnce(16384, 30000)
  if data.len == 0:
    return false
  c.buf.add(data)
  return true

proc readRawLine(c: ClientConn, limit: int = 65536): tuple[line: string,
    tooLong: bool, eof: bool] =
  ## 1行読む (末尾の \n と \r は取る)。行が無く EOF なら eof=true で残りを返す
  while true:
    let idx = c.buf.find('\n')
    if idx >= 0:
      result.line = c.buf[0 ..< idx]
      c.buf = c.buf[idx + 1 ..< c.buf.len]
      if result.line.endsWith("\r"):
        result.line.setLen(result.line.len - 1)
      return
    if c.buf.len > limit:
      result.line = c.buf
      result.tooLong = true
      return
    if not c.connRecv():
      result.line = c.buf
      c.buf = ""
      result.eof = true
      return

proc readBytes(c: ClientConn, n: int): string =
  result = ""
  if c.buf.len > 0:
    let take = min(n, c.buf.len)
    result.add(c.buf[0 ..< take])
    c.buf = c.buf[take ..< c.buf.len]
  while result.len < n:
    let data = c.rawRecvOnce(min(16384, n - result.len), 30000)
    if data.len == 0:
      break
    result.add(data)


# ---- 静的ファイル: 許可リスト方式 ----------------------------------------------
proc boardFileMatch(name: string): bool =
  ## (?:index\d*|kako|o?\d+)\.html と同じ
  if not name.endsWith(".html"):
    return false
  let stem = name[0 ..< name.len - 5]
  if stem == "kako":
    return true
  if stem.startsWith("index"):
    return stem[5 ..< stem.len].allCharsInSet({'0'..'9'})
  var i = 0
  if i < stem.len and stem[i] == 'o':
    inc i
  if i >= stem.len:
    return false
  return stem[i ..< stem.len].allCharsInSet({'0'..'9'})

proc isStaticAllowed(path: string): bool =
  if path in StaticRootFiles:
    return true
  # /板名  /板名/  /板名/index.html  /板名/index2.html  /板名/数字.html  /板名/o数字.html  /板名/kako.html
  if path.len < 2 or path[0] != '/':
    return false
  let rest = path[1 ..< path.len]
  let slash = rest.find('/')
  var board, file: string
  if slash < 0:
    board = rest
    file = ""
  else:
    board = rest[0 ..< slash]
    file = rest[slash + 1 ..< rest.len]
    if '/' in file:
      return false
  if board.len == 0 or board notin loadBoards():
    return false
  if slash < 0 or file.len == 0:
    return true
  return boardFileMatch(file)

proc serveFile(c: ClientConn, fsPath: string, headOnly: bool) =
  var info: FileInfo
  try:
    info = getFileInfo(fsPath)
  except CatchableError:
    c.sendError(404, "File not found")
    return
  let ext = splitFile(fsPath).ext.toLowerAscii()
  let ctype = case ext
    of ".html": "text/html"
    of ".css": "text/css"
    of ".js": "text/javascript"
    else: "application/octet-stream"
  c.respondHead(200, @[("Content-Type", ctype),
      ("Last-Modified", httpDate(info.lastWriteTime))], int(info.size))
  if headOnly:
    return
  var f: File
  if not open(f, fsPath, fmRead):
    return
  defer: f.close()
  var buf = newString(65536)
  while true:
    let n = f.readBuffer(addr buf[0], buf.len)
    if n <= 0:
      break
    c.sendAll(buf[0 ..< n])

proc handleStatic(c: ClientConn, rawPath, query: string, headOnly: bool) =
  if not isStaticAllowed(rawPath):
    c.sendError(404, "Not Found")
    return
  let fsGuess = "." & rawPath
  if dirExists(fsGuess) and not rawPath.endsWith("/"):
    # /板名 -> /板名/ への転送 (http.server の send_head と同じ。query は引き継ぐ)
    var loc = rawPath & "/"
    if query.len > 0:
      loc &= "?" & query
    var s = "HTTP/1.1 301 " & reasonPhrase(301) & "\r\n"
    s &= "Server: NimCGI/1.1\r\n"
    s &= "Date: " & httpDate(getTime()) & "\r\n"
    s &= "Location: " & loc & "\r\n"
    s &= "Connection: close\r\n\r\n"
    c.sendAll(s)
    return
  let fsPath = if dirExists(fsGuess): fsGuess & "/index.html" else: fsGuess
  if not fileExists(fsPath):
    # フォルダの一覧は出さない。フォルダへの要求は "Not Found"、ファイルは "File not found"
    if rawPath.endsWith("/") or rawPath == "/":
      c.sendError(404, "Not Found")
    else:
      c.sendError(404, "File not found")
    return
  c.serveFile(fsPath, headOnly)


# ---- 圧縮済みの過去ログ (o数字.html.gz) の配信 ---------------------------------
proc archivedGzPath(rawPath: string): string =
  ## この要求が /板/o数字.html で、配信すべき .gz があればそのパス。無ければ ""。
  ## 平文があって更新日時が違うときは gz が古いので "" (平文を従来どおり配信する)
  let parts = rawPath.split('/')
  if parts.len != 3 or parts[0] != "":
    return ""
  let board = parts[1]
  let file = parts[2]
  if board notin loadBoards():
    return ""
  if file.len < 7 or file[0] != 'o' or not file.endsWith(".html"):
    return ""
  if not file[1 ..< file.len - 5].allCharsInSet({'0'..'9'}):
    return ""
  let plain = board & "/" & file
  let gz = plain & ".gz"
  if not fileExists(gz):
    return ""
  if fileExists(plain):
    try:
      if int(getFileInfo(plain).lastWriteTime.toUnix()) !=
          int(getFileInfo(gz).lastWriteTime.toUnix()):
        return ""
    except CatchableError:
      return ""
  return gz

proc serveArchived(c: ClientConn, gzPath: string, headOnly: bool) =
  ## o数字.html.gz を、o数字.html の URL のまま返す。
  ## gzip を受け付ける相手には圧縮のまま、受け付けない相手には展開して返す
  let doGzip = acceptsGzip(c.getHeader("Accept-Encoding"))
  var headers = @[("Content-Type", "text/html; charset=UTF-8"),
      ("Vary", "Accept-Encoding"),
      ("X-Content-Type-Options", "nosniff"),
      ("Cache-Control", "public, max-age=3600")]
  var size = -1
  if doGzip:
    headers.add(("Content-Encoding", "gzip"))
    try:
      size = int(getFileSize(gzPath))
    except CatchableError:
      size = -1
  c.respondHead(200, headers, size)
  if headOnly:
    return
  if doGzip:
    var f: File
    if not open(f, gzPath, fmRead):
      return
    defer: f.close()
    var buf = newString(65536)
    while true:
      let n = f.readBuffer(addr buf[0], buf.len)
      if n <= 0:
        break
      c.sendAll(buf[0 ..< n])
  else:
    var f: File
    if not open(f, gzPath, fmRead):
      return
    try:
      let r = newGzReader(f)
      while true:
        let chunk = r.readChunk()
        if chunk.len == 0:
          break
        c.sendAll(chunk)
      r.close()
    except CatchableError:
      discard
    f.close()


# ---- CGI 実行 ------------------------------------------------------------------
proc isCgiRequest(path: string): bool =
  ## /xxx.cgi /xxx.py をCGIとして扱う (AllowedCgi で対象を制限)
  if path.len < 2 or path[0] != '/':
    return false
  let rest = path[1 ..< path.len]
  if '/' in rest:
    return false
  let dot = rest.rfind('.')
  if dot <= 0:
    return false
  let name = rest[0 ..< dot]
  let ext = rest[dot + 1 ..< rest.len]
  if ext != "cgi" and ext != "py":
    return false
  for ch in name:
    if not (ch.isAlphaNumeric() or ch == '_'):
      return false
  return name in AllowedCgi

proc setNonBlocking(fd: FileHandle) =
  let flags = posix.fcntl(cint(fd), F_GETFL, 0)
  discard posix.fcntl(cint(fd), F_SETFL, flags or O_NONBLOCK)

proc communicate(p: Process, input: string, timeoutMs: int):
    tuple[outs, errs: string, timedOut: bool] =
  ## 子プロセスに input を渡し、stdout/stderr を読み切る (最大 timeoutMs)。
  ## stdin 書き込みと両方の読み取りを selectors で並行させる (パイプ詰まり対策)
  result.outs = ""
  result.errs = ""
  result.timedOut = false
  let inFd = p.inputHandle
  let outFd = p.outputHandle
  let errFd = p.errorHandle
  setNonBlocking(inFd)
  setNonBlocking(outFd)
  setNonBlocking(errFd)
  var sel = newSelector[int]()
  var inOpen = false
  var outOpen = true
  var errOpen = true
  if input.len > 0:
    sel.registerHandle(int(inFd), {Write}, 0)
    inOpen = true
  else:
    try: p.inputStream.close()
    except CatchableError: discard
  sel.registerHandle(int(outFd), {Read}, 1)
  sel.registerHandle(int(errFd), {Read}, 2)
  var inPos = 0
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var buf = newString(8192)
  while inOpen or outOpen or errOpen:
    if getMonoTime() > deadline:
      result.timedOut = true
      p.kill()
      break
    let ready = sel.select(100)
    for ev in ready:
      let which = sel.getData(ev.fd)
      if which == 0 and inOpen:
        let n = posix.write(cint(inFd), addr input[inPos],
                            input.len - inPos)
        if n > 0:
          inPos += n
          if inPos >= input.len:
            sel.unregister(int(inFd))
            try: p.inputStream.close()
            except CatchableError: discard
            inOpen = false
        elif n < 0 and myErrno != EAGAIN_C and myErrno != EINTR_C:
          sel.unregister(int(inFd))
          try: p.inputStream.close()
          except CatchableError: discard
          inOpen = false
      elif which == 1 and outOpen:
        let n = posix.read(cint(outFd), addr buf[0], buf.len)
        if n > 0:
          result.outs.add(buf[0 ..< n])
        elif n == 0:
          sel.unregister(int(outFd))
          outOpen = false
        elif myErrno != EAGAIN_C and myErrno != EINTR_C:
          sel.unregister(int(outFd))
          outOpen = false
      elif which == 2 and errOpen:
        let n = posix.read(cint(errFd), addr buf[0], buf.len)
        if n > 0:
          result.errs.add(buf[0 ..< n])
        elif n == 0:
          sel.unregister(int(errFd))
          errOpen = false
        elif myErrno != EAGAIN_C and myErrno != EINTR_C:
          sel.unregister(int(errFd))
          errOpen = false
  sel.close()
  try:
    if p.waitForExit(3000) < 0:
      p.kill()
      discard p.waitForExit(1000)
  except CatchableError:
    discard    # 回収済みなど。出力は読み切れているので支障ない

proc runCgi(c: ClientConn, meth, rawPath, query: string) =
  let scriptName = rawPath.rsplit('/', 1)[^1]     # 例: amezo.cgi
  let dot = scriptName.rfind('.')
  let base = scriptName[0 ..< dot]
  let binRel = "./" & base & ".cgi"
  if not fileExists(binRel):
    c.sendError(404, "Script not found: " & scriptName)
    return

  # POSTデータ読み込み (上限を超えるものは読まずに拒否)
  var contentLength = 0
  let clRaw = c.getHeader("Content-Length")
  if clRaw.len > 0:
    try:
      contentLength = parseInt(clRaw.strip())
    except CatchableError:
      contentLength = 0
  if contentLength < 0:
    contentLength = 0
  if contentLength > MaxPostBytes:
    c.sendError(413, "Payload Too Large")
    return
  let body = if contentLength > 0: c.readBytes(contentLength) else: ""

  echo "⚡ CGIを実行中: " & base & ".cgi (要求: " & scriptName &
      ", Method: " & meth & ")"
  flushFile(stdout)

  # 環境変数の準備 (CGI/1.1 に近づける)
  let env = newStringTable()
  for (k, v) in envPairs():
    env[k] = v
  env["SERVER_SOFTWARE"] = "NimCGI/1.1"
  env["SERVER_NAME"] = nativesockets.getHostname()
  env["GATEWAY_INTERFACE"] = "CGI/1.1"
  env["SERVER_PROTOCOL"] = "HTTP/1.1"
  env["SERVER_PORT"] = $c.serverPort
  env["REQUEST_METHOD"] = meth
  env["QUERY_STRING"] = query
  env["CONTENT_TYPE"] = c.getHeader("Content-Type")
  env["SCRIPT_NAME"] = "/" & scriptName
  # 要求された名前(amezo.cgi)で渡す: フォームの action="../amezo.cgi" をそのまま保つため
  env["SCRIPT_FILENAME"] = getCurrentDir() / scriptName
  env["REMOTE_ADDR"] = c.ip
  env["REMOTE_HOST"] = c.ip
  env["HTTP_REFERER"] = c.getHeader("Referer")
  env["HTTP_ORIGIN"] = c.getHeader("Origin")
  env["HTTP_USER_AGENT"] = c.getHeader("User-Agent")
  let hostHdr = c.getHeader("Host")
  env["HTTP_HOST"] = if hostHdr.len > 0: hostHdr
                     else: "127.0.0.1:" & $c.serverPort
  env["HTTPS"] = "OFF"
  # その他のHTTPヘッダーを HTTP_* として渡す
  for (name, value) in c.headers:
    let key = "HTTP_" & name.toUpperAscii().replace("-", "_")
    if key notin env:
      env[key] = value
  env["CONTENT_LENGTH"] = $body.len

  var p: Process
  try:
    p = startProcess(getCurrentDir() / (base & ".cgi"),
        workingDir = getCurrentDir(), env = env, options = {})
  except CatchableError as e:
    c.sendError(500, "CGI Execution Failed: " & e.msg)
    return

  let (outs, errs, timedOut) = communicate(p, body, 30000)
  try: p.close()
  except CatchableError: discard
  if timedOut:
    c.sendError(504, "CGI Timeout")
    return

  if errs.strip().len > 0:
    for line in errs.strip().splitLines():
      echo "  ⚠️ " & line
    flushFile(stdout)

  # ヘッダーとボディを分離 (\r\n\r\n と \n\n の両方に対応)
  var headPart, bodyPart: string
  let idx1 = outs.find("\r\n\r\n")
  if idx1 >= 0:
    headPart = outs[0 ..< idx1]
    bodyPart = outs[idx1 + 4 ..< outs.len]
  else:
    let idx2 = outs.find("\n\n")
    if idx2 >= 0:
      headPart = outs[0 ..< idx2]
      bodyPart = outs[idx2 + 2 ..< outs.len]
    else:
      headPart = ""
      bodyPart = outs

  # ヘッダー解析
  var statusCode = 200
  var respHeaders: seq[tuple[name, value: string]] = @[]
  for line in headPart.split('\n'):
    let h = line.strip()
    if h.len == 0:
      continue
    let colon = h.find(':')
    if colon < 0:
      continue
    let k = h[0 ..< colon].strip()
    let v = h[colon + 1 ..< h.len].strip()
    if k.toLowerAscii() == "status":
      let parts = v.splitWhitespace()
      if parts.len > 0:
        try:
          statusCode = parseInt(parts[0])
        except CatchableError:
          discard
    else:
      respHeaders.add((k, v))

  # Status が無く Location だけの場合は 302 (CGI の仕様)
  if statusCode == 200 and
      respHeaders.anyIt(it.name.toLowerAscii() == "location"):
    statusCode = 302

  let hasCL = respHeaders.anyIt(it.name.toLowerAscii() == "content-length")
  c.respondHead(statusCode, respHeaders,
      if hasCL: -1 else: bodyPart.len)
  c.sendAll(bodyPart)


# ---- 接続の処理 -----------------------------------------------------------------
proc handleConnection(client: Socket, ip: string, serverPort: int) =
  let c = ClientConn(sock: client, buf: "", ip: ip, serverPort: serverPort,
      headers: @[])
  try:
    let (reqLine, tooLong, _) = c.readRawLine()
    if tooLong:
      c.sendError(414, "Request-URI Too Long")
      return
    if reqLine.len == 0:
      return    # 空の要求行 (接続確認など) は、そのまま閉じる
    let tokens = reqLine.splitWhitespace()
    if tokens.len < 2:
      c.sendError(400, "Bad request syntax")
      return
    let meth = tokens[0]
    let rawTarget = tokens[1]
    let qpos = rawTarget.find('?')
    let rawPath = if qpos >= 0: rawTarget[0 ..< qpos] else: rawTarget
    let query = if qpos >= 0: rawTarget[qpos + 1 ..< rawTarget.len] else: ""

    # ヘッダーを読む
    while true:
      let (hLine, _, hEof) = c.readRawLine()
      if hLine.len == 0:
        break
      let colon = hLine.find(':')
      if colon > 0:
        c.headers.add((hLine[0 ..< colon].strip(),
            hLine[colon + 1 ..< hLine.len].strip()))
      if hEof:
        break

    if gVerbose:
      echo "  " & meth & " " & rawTarget
      flushFile(stdout)

    if c.getHeader("Expect").toLowerAscii() == "100-continue":
      c.sendAll("HTTP/1.1 100 Continue\r\n\r\n")

    # 不正な形のパスは、振り分けの前に 400 で止める
    if isMalformedPath(rawPath):
      c.sendError(400, "Bad Request")
      return

    case meth
    of "GET":
      let gz = archivedGzPath(rawPath)
      if gz.len > 0:
        c.serveArchived(gz, false)
      elif isCgiRequest(rawPath):
        c.runCgi(meth, rawPath, query)
      else:
        c.handleStatic(rawPath, query, false)
    of "HEAD":
      let gz = archivedGzPath(rawPath)
      if gz.len > 0:
        c.serveArchived(gz, true)
      else:
        c.handleStatic(rawPath, query, true)
    of "POST":
      if isCgiRequest(rawPath):
        c.runCgi(meth, rawPath, query)
      else:
        c.sendError(501, "Can only POST to CGI scripts")
    else:
      c.sendError(501, "Unsupported method ('" & meth & "')")
  except CatchableError:
    discard    # 接続単位の失敗は、接続を閉じて終わる
  finally:
    try: client.close()
    except CatchableError: discard


proc acceptLoop(server: Socket, serverPort: int) =
  ## 接続を受け付けて、接続ごとに fork して処理する (この関数は戻らない)
  while true:
    # 終わった接続プロセスを回収する (溜めない。ブロックはしない)
    var wstatus: cint
    while cast[int](posix.waitpid(cast[Pid](-1), wstatus, WNOHANG)) > 0:
      discard
    var client: Socket
    try:
      server.accept(client)
    except CatchableError:
      sleep(50)
      continue
    var ip = ""
    try:
      ip = client.getPeerAddr()[0]
    except CatchableError:
      discard
    flushFile(stdout)
    let pid = posix.fork()
    if cast[int](pid) == 0:
      # 子プロセス: この接続だけ処理して終わる
      discard cSignal(SIGINT_C, SIG_DFL_C)
      try: server.close()
      except CatchableError: discard
      handleConnection(client, ip, serverPort)
      flushFile(stdout)
      cExit(0)
    elif cast[int](pid) > 0:
      try: client.close()
      except CatchableError: discard
    else:
      try: client.close()
      except CatchableError: discard
      sleep(50)


# ---- 起動確認 -------------------------------------------------------------------
proc waitForServer(port: int, timeoutSec: int = 10): bool =
  let start = getMonoTime()
  while (getMonoTime() - start).inSeconds < timeoutSec:
    var s: Socket
    try:
      s = newSocket()
      s.connect("127.0.0.1", Port(port))
      s.close()
      echo "✅ Webサーバーがポート " & $port & " で正常に応答しました。"
      return true
    except CatchableError:
      if s != nil:
        try: s.close()
        except CatchableError: discard
    sleep(1000)
  return false

proc httpStatus(port: int, path: string): int =
  ## self_check 用に、生の要求行のまま GET してステータスだけ見る (失敗したら 0)
  var s: Socket
  try:
    s = newSocket()
    s.connect("127.0.0.1", Port(port))
    let fd = s.getFd()
    var req = "GET " & path & " HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n"
    var pos = 0
    while pos < req.len:
      let n = int(nativesockets.send(fd, addr req[pos], req.len - pos, 0.cint))
      if n <= 0:
        break
      pos += n
    var line = ""
    var pfd = TPollfd(fd: cint(s.getFd()), events: POLLIN)
    if posix.poll(addr pfd, 1, 10000) <= 0:
      return 0
    var tmp = newString(4096)
    let n = nativesockets.recv(s.getFd(), addr tmp[0], tmp.len, 0.cint)
    if n <= 0:
      return 0
    tmp.setLen(n)
    line = tmp.splitLines()[0]
    let parts = line.splitWhitespace()
    if parts.len >= 2:
      return parseInt(parts[1])
    return 0
  except CatchableError:
    return 0
  finally:
    if s != nil:
      try: s.close()
      except CatchableError: discard

proc selfCheck(port: int): bool =
  ## 起動直後の確認: 板一覧や中継は出る / 鍵やパスワードやソースは配られない (失敗しても起動は続ける)
  echo "🔎 起動チェック:"
  var good = true
  for (path, want) in [("/dai.cgi", 200), ("/jump.cgi", 200),
        ("/style.css", 200), ("/hide.js", 200),
        ("//amezo.cgi", 400), ("/src/bbs.nim", 404),
        ("/trip_secret.txt", 404), ("/id_secret.txt", 404),
        ("/delpass.txt", 404), ("/cap.txt", 404), ("/blist.txt", 404),
        ("/config.ini", 404), ("/key_secret.txt", 404),
        ("/jump_secret.txt", 404), ("/ng.txt", 404),
        ("/archive", 404), ("//archive", 400)]:
    let got = httpStatus(port, path)
    let mark = if got == want: "✅" else: "❌"
    if got != want:
      good = false
    echo "  " & mark & " " & path & " -> " & $got &
        (if got == want: "" else: " (期待: " & $want & ")")
  if not good:
    echo "  ⚠️ 期待と違う結果があります。公開する前に server.nim の配信判定を確認してください。"
  return good


# ---- 3. トンネルによる外部公開 ---------------------------------------------------
type TunnelState = ref object
  p: Process
  fd: FileHandle
  buf: string        # 行になり切っていない残り
  eof: bool

proc findTunnelUrl(line: string): string =
  ## https://<英数字->.trycloudflare.com を探す
  const Suffix = ".trycloudflare.com"
  var i = 0
  while true:
    let j = line.find("https://", i)
    if j < 0:
      return ""
    var k = j + 8
    while k < line.len and (line[k].isAlphaNumeric() or line[k] == '-'):
      inc k
    if k > j + 8 and line.continuesWith(Suffix, k):
      return line[j ..< k + Suffix.len]
    i = j + 8

proc tunnelNewLines(t: TunnelState): seq[string] =
  ## たまっている出力を読み、完成した行を返す (ノンブロッキング)
  result = @[]
  if not t.eof:
    var chunk = newString(8192)
    while true:
      let n = posix.read(cint(t.fd), addr chunk[0], chunk.len)
      if n > 0:
        t.buf.add(chunk[0 ..< n])
      elif n == 0:
        t.eof = true
        break
      else:
        break    # EAGAIN: 今は無い
  while true:
    let idx = t.buf.find('\n')
    if idx < 0:
      break
    result.add(t.buf[0 ..< idx])
    t.buf = t.buf[idx + 1 ..< t.buf.len]
  if t.eof and t.buf.len > 0:
    result.add(t.buf)
    t.buf = ""

proc printTunnelLines(t: TunnelState): string =
  ## 新しい行を Python 版と同じ形で表示し、公開 URL が見つかればそれを返す
  result = ""
  for line in t.tunnelNewLines():
    if "[CF_OUT]" notin line:
      echo "[CF_OUT] " & line.strip()
    if result.len == 0:
      let u = findTunnelUrl(line)
      if u.len > 0:
        result = u
  flushFile(stdout)

proc startTunnel(port: int): TunnelState =
  echo "☁️ Cloudflare Tunnel をセットアップしています..."
  var bin = findExe("cloudflared")
  if bin.len == 0:
    echo "cloudflared をダウンロード中..."
    discard execCmd("curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared")
    discard execCmd("chmod +x cloudflared")
    bin = "./cloudflared"

  var p: Process
  try:
    p = startProcess(bin, args = @["tunnel", "--url",
        "http://127.0.0.1:" & $port], options = {poStdErrToStdOut})
  except CatchableError:
    # 起動できない場合は、ローカルで出し続ける (Python 版は例外で落ちる箇所の安全側の扱い)
    echo "❌ cloudflared を起動できませんでした。ローカルで継続します: http://127.0.0.1:" & $port & "/"
    return nil

  let t = TunnelState(p: p, buf: "", eof: false)
  t.fd = p.outputHandle
  setNonBlocking(t.fd)

  echo "⏳ トンネルの公開URLを取得しています..."
  let deadline = getMonoTime() + initDuration(seconds = 20)
  var url = ""
  while url.len == 0 and getMonoTime() < deadline:
    url = t.printTunnelLines()
    if url.len > 0:
      break
    if t.eof or not p.running():
      break
    sleep(50)
  if url.len == 0:
    url = t.printTunnelLines()
  if url.len > 0:
    echo "\n🎉 【BBSアクセス先URL】: " & url & "/ \n"
  else:
    echo "❌ 公開URLの取得に失敗しました。トンネルプロセスの出力を確認してください。"
  return t


# ---- --make-hash ---------------------------------------------------------------
proc writeDelpass(password: string): bool =
  if password.len == 0:
    echo "❌ 合言葉が空です。"
    return false
  writeFile(DELCRYPTFILE, makeHash(password) & "\n")
  setFilePermissions(DELCRYPTFILE, {fpUserRead, fpUserWrite})   # 既存ファイルでも 0600 にそろえる
  echo "✅ delpass.txt を作りました。管理画面は /admin.cgi です。"
  return true


proc main(): int =
  var port = DefaultPort
  var noTunnel = false
  var makeHashPw = ""
  var doMakeHash = false
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    case args[i]
    of "--make-hash":
      if i + 1 >= args.len:
        stderr.writeLine("Usage: server --make-hash PASSWORD")
        return 2
      doMakeHash = true
      makeHashPw = args[i + 1]
      i += 2
    of "--no-tunnel":
      noTunnel = true
      inc i
    of "--port":
      if i + 1 >= args.len:
        stderr.writeLine("Usage: server --port PORT")
        return 2
      try:
        port = parseInt(args[i + 1])
      except CatchableError:
        stderr.writeLine("server: error: argument --port: invalid int value: '" &
            args[i + 1] & "'")
        return 2
      i += 2
    of "--verbose":
      gVerbose = true
      inc i
    of "-h", "--help":
      echo "usage: server [--make-hash PASSWORD] [--no-tunnel] [--port PORT] [--verbose]"
      return 0
    else:
      stderr.writeLine("server: error: unrecognized arguments: " & args[i])
      return 2

  # server バイナリのあるフォルダ (アプリのフォルダ) に固定
  setCurrentDir(getAppDir())

  if doMakeHash:
    return if writeDelpass(makeHashPw): 0 else: 1

  cleanupOldProcesses(port)
  setupBbsDirectories()

  echo "🚀 CGI Webサーバーを起動しています (ポート " & $port & ")..."
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  try:
    server.bindAddr(Port(port), "127.0.0.1")
    server.listen()
  except CatchableError as e:
    stderr.writeLine("❌ サーバーを起動できませんでした: " & e.msg)
    return 1

  setControlCHook(proc() {.noconv.} =
    gStop = true
  )

  # 接続の受け付けは子プロセスに任せ、こちらは起動確認と監視をする
  let acceptorPid = posix.fork()
  if cast[int](acceptorPid) == 0:
    acceptLoop(server, port)
    cExit(0)
  elif cast[int](acceptorPid) < 0:
    stderr.writeLine("❌ 接続受付プロセスを作れませんでした。")
    return 1
  try: server.close()
  except CatchableError: discard

  if not waitForServer(port):
    echo "❌ Webサーバーが起動しませんでした。"
    discard posix.kill(acceptorPid, SIGTERM)
    return 1

  discard selfCheck(port)

  var tunnel: TunnelState = nil
  if noTunnel:
    echo "\n🏠 ローカルで起動しました: http://127.0.0.1:" & $port & "/\n"
  else:
    tunnel = startTunnel(port)

  var interrupted = false
  var tunnelDied = false
  echo "\n⏳ サーバー稼働中... 停止するには Ctrl+C を押してください。"
  flushFile(stdout)
  while true:
    if gStop:
      interrupted = true
      break
    if tunnel != nil:
      discard tunnel.printTunnelLines()
      if not tunnel.p.running():
        tunnelDied = true
        break
    sleep(100)

  if interrupted:
    echo "\n🛑 終了シグナルを検知しました。プロセスを停止します..."
  if tunnelDied:
    echo "⚠️ トンネルプロセスが終了しました。"
  if tunnel != nil:
    try: tunnel.p.terminate()
    except CatchableError: discard
  discard posix.kill(acceptorPid, SIGTERM)
  echo "✅ プロセスを安全に停止しました。"
  return 0


when isMainModule:
  quit(main())
