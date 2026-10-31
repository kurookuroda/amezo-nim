# amezo.nim - 投稿 CGI (Python 版 amezo.py の main() の移植)
# 起動したら自分のフォルダに chdir し、config.ini を適用してから処理する。
# 標準出力は CGI の応答そのものなので、ここでは --make-hash の結果以外は出さない。

import std/[os, strutils, tables, posix, times]
import bbs, bbsindex

proc p2(n: int): string =
  ## 2桁ゼロ埋め (strftime の %m など)
  let s = $n
  if s.len >= 2: s else: "0" & s

proc parsePyInt(s: string): tuple[ok: bool, val: int] =
  ## Python の int() 相当 (前後の空白、符号、数字の間の '_' を許す)。失敗したら ok=false
  let t = s.strip()
  if t.len == 0: return (false, 0)
  var i = 0
  var neg = false
  if t[0] in {'+', '-'}:
    neg = t[0] == '-'
    i = 1
  if i >= t.len: return (false, 0)
  var val = 0
  var digits = 0
  var lastUnderscore = true   # 先頭の '_' は許さない
  while i < t.len:
    let c = t[i]
    if c == '_':
      if lastUnderscore: return (false, 0)
      lastUnderscore = true
    elif c in '0'..'9':
      if val > 1_000_000_000_000: return (true, if neg: -val else: val)  # 飽和 (上限判定には十分)
      val = val * 10 + (ord(c) - ord('0'))
      lastUnderscore = false
      inc digits
    else:
      return (false, 0)
    inc i
  if lastUnderscore or digits == 0: return (false, 0)
  (true, if neg: -val else: val)

proc readStdinBytes(n: int): string =
  ## 標準入力から最大 n バイトを生で読む (Python の sys.stdin.buffer.read(n) 相当)
  result = ""
  if n <= 0: return
  var buf: array[8192, char]
  var left = n
  while left > 0:
    let want = min(left, buf.len)
    let got = posix.read(cint(0), addr buf[0], want)
    if got <= 0: break
    let old = result.len
    result.setLen(old + int(got))
    copyMem(addr result[old], addr buf[0], int(got))
    left -= int(got)

proc stripControls(s: string): string =
  ## \x00-\x1f を取り除く (Python の re.sub(r'[\x00-\x1f]', '', s) 相当)
  result = newStringOfCap(s.len)
  for c in s:
    if c >= '\x20':
      result.add(c)

proc allDigits(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin '0'..'9': return false
  true

proc digits1to6(s: string): bool =
  s.len >= 1 and s.len <= 6 and allDigits(s)

proc refererFolder(referer0: string): string =
  ## Python の Referer 処理: 先頭の www. を落とし、https?://host/(…)/ の … を取る
  var s = referer0
  if s.startsWith("http://www."):
    s = "http://" & s[11 .. ^1]
  elif s.startsWith("https://www."):
    s = "https://" & s[12 .. ^1]
  var start = 0
  while true:
    let a = s.find("http://", start)
    let b = s.find("https://", start)
    var pos = -1
    var hostStart = -1
    if a >= 0 and (b < 0 or a < b):
      pos = a
      hostStart = a + 7
    elif b >= 0:
      pos = b
      hostStart = b + 8
    if pos < 0: return ""
    var j = hostStart
    while j < s.len and s[j] != '/': inc j
    if j > hostStart and j < s.len:          # ホストが1文字以上あり、'/' が続く
      var k = j + 1
      while k < s.len and s[k] != '/': inc k
      if k > j + 1 and k < s.len:
        return s[j + 1 ..< k]
    start = pos + 1

proc dtNumberOf(line: string): int =
  ## "<dt>数字" があればその数字、なければ -1 (Python の re.search(r'<dt>(\d+)'))
  var start = 0
  while true:
    let p = line.find("<dt>", start)
    if p < 0: return -1
    var j = p + 4
    var val = 0
    var digits = 0
    while j < line.len and line[j] in '0'..'9':
      val = val * 10 + (ord(line[j]) - ord('0'))
      inc j
      inc digits
    if digits > 0: return val
    start = p + 4

proc parsePrevPost(prev: string): tuple[ok: bool, name: string, comm: string] =
  ## Python の re.search(r'投稿者：<font[^>]*><b>(.+?) </b>.+<dd>(.+?) </dl>', prev) 相当
  var start = 0
  while true:
    let p = prev.find("投稿者：<font", start)
    if p < 0: return (false, "", "")
    let gt = prev.find('>', p + len("投稿者："))
    if gt >= 0 and gt + 4 <= prev.len and prev[gt + 1 .. gt + 3] == "<b>":
      let nameStart = gt + 4
      let nameEnd = prev.find(" </b>", nameStart)
      if nameEnd >= 0:
        let after = nameEnd + len(" </b>")
        let dd = prev.find("<dd>", after + 1)     # .+ は最低1文字
        if dd >= 0:
          let commStart = dd + len("<dd>")
          let commEnd = prev.find(" </dl>", commStart)
          if commEnd >= 0:
            return (true, prev[nameStart ..< nameEnd], prev[commStart ..< commEnd])
    start = p + 1

proc main() =
  if paramCount() >= 1 and paramStr(1) == "--make-hash":
    if paramCount() < 2:
      stderr.writeLine("Usage: python3 amezo.py --make-hash PASSWORD")
      quit(1)
    echo makeHash(paramStr(2))
    flushFile(stdout)
    quit(0)

  var contentLen = 0
  let (clOk, clVal) = parsePyInt(getEnv("CONTENT_LENGTH", "0"))
  if clOk:
    contentLen = clVal

  if contentLen < 0:
    bbsError("投稿内容が不正です")
  if contentLen > MAX_POST_BYTES:
    bbsError("投稿内容が大きすぎます")

  let buffer = readStdinBytes(contentLen)
  if buffer.len > MAX_POST_BYTES:
    bbsError("投稿内容が大きすぎます")

  var queryParams = initTable[string, string]()
  let queryString = getEnv("QUERY_STRING", "")
  if queryString.len > 0:
    for pair in queryString.split('&'):
      let eq = pair.find('=')
      if eq >= 0:
        queryParams[pair[0 ..< eq]] = urlDecode(pair[eq + 1 .. ^1])

  var form = initTable[string, string]()
  var tripPw = ""        # 名前欄の「#」より後ろ (エスケープ前のまま。保存も表示もしない)
  if buffer.len > 0:
    for pair in buffer.split('&'):
      let eq = pair.find('=')
      if eq < 0: continue
      let key = toUtf8(pair[0 ..< eq])
      var value = urlDecode(pair[eq + 1 .. ^1])
      value = stripInvisible(value)
      if key == "name":
        # 最初の半角 # で、名前とパスワードに分ける (全角の ＃ は区切りにしない)
        let h = value.find('#')
        if h >= 0:
          tripPw = stripControls(value[h + 1 .. ^1])
          value = value[0 ..< h]
        else:
          tripPw = stripControls("")
      value = htmlEscape(value)
      value = value.replace("\r\n", "\r").replace("\n", "\r")
      if key == "comm":
        value = value.replace("\r", "<br>")
      value = stripControls(value)
      form[key] = value

  var folder = ""
  if form.hasKey("folder"):
    folder = form["folder"]
  else:
    folder = queryParams.getOrDefault("folder", "")
  if folder.len == 0:
    folder = refererFolder(urlDecode(getEnv("HTTP_REFERER", "")))

  if folder.len == 0:
    bbsError("板名が判定できません。")
  if '/' in folder or ".." in folder or not isBoard(folder):
    bbsError("板名が不正です")

  var name = form.getOrDefault("name", "")
  var mail = form.getOrDefault("mail", "")
  var comm = form.getOrDefault("comm", "")
  var subj = form.getOrDefault("subj", "")
  var res = form.getOrDefault("res", "")

  if res.len > 0 and not allDigits(res):
    bbsError("不正なスレッド指定です")

  if form.hasKey("sub") and form["sub"].len > 0:
    resView(folder, form)

  # ページ指定: ページ送りのリンク (?page=N)。POST でも GET でも受ける。実在するページにだけ飛ぶ (範囲外は最後のページ)。
  # 古いフォームの next (開始位置) も、ページに直して受け付ける
  let pageRaw = if form.hasKey("page"): form["page"] else: queryParams.getOrDefault("page", "")
  let nextRaw = if form.hasKey("next"): form["next"] else: queryParams.getOrDefault("next", "")
  var page: int
  if digits1to6(pageRaw):
    page = parseInt(pageRaw)
  elif digits1to6(nextRaw):
    page = (max(1, parseInt(nextRaw)) - 1) div PER_PAGE + 1
  else:
    page = 1
  page = pageClamp(folder, page)

  var reloadFlag = false
  if name == subj and name == comm:
    reloadFlag = true
  if name.len == 0 and subj.len == 0 and comm.len == 0:
    reloadFlag = true

  if comm.count("<br>") > COMM_LINES_MAX:
    bbsError("改行が多すぎます")
  # 本文の改行 (<br>) は1文字として数える
  if htmlCharsLen(comm.replace("<br>", "\n")) > COMM_MAX:
    bbsError("コメントが長すぎます")
  if htmlCharsLen(mail) > MAIL_MAX:
    bbsError("メールが長すぎます")

  subj = subj.replace(" ", "").replace("　", "").replace("＿", "")   # 空白 (半角・全角) と ＿ を除く
  if htmlCharsLen(subj) > SUBJ_MAX:
    bbsError("題名が長すぎます")

  name = name.replace(TRIP_MARK, "◇").replace(CAP_MARK, "☆")   # トリップ・キャップの偽造防止
  name = name.replace(" ", "").replace("　", "").replace("\xe2\x80\x8d", "")   # U+200D
  name = ccut(name, NAME_MAX)
  while "&gt;&gt;" in comm:                 # &gt; の連続を1つに (re.sub(r'&gt;(&gt;)+', '&gt;') 相当)
    comm = comm.replace("&gt;&gt;", "&gt;")

  # NGワード (比べる文章はエスケープ済みなので、ワードもエスケープして、文字列として照合する)
  let comm2 = comm
  if fileExists("./ng.txt"):
    try:
      let ngText = readFile("./ng.txt")
      for rawLine in ngText.split('\n'):
        var line = rawLine
        while line.len > 0 and line[^1] == '\r':
          line.setLen(line.len - 1)
        if line.len == 0: continue
        let parts = line.split(',')
        let ng = parts[0]
        let opt = if parts.len > 1: parts[1] else: ""
        if ng.len == 0: continue
        let ngEsc = htmlEscape(ng)
        if opt == "n":
          if ngEsc in name:
            reloadFlag = true
        elif opt == "c":
          if ngEsc in comm2:
            reloadFlag = true
        else:
          name = name.replace(ngEsc, "")
          comm = comm.replace(ngEsc, "")
          mail = mail.replace(ngEsc, "")
          subj = subj.replace(ngEsc, "")
    except OSError:
      discard

  if page == 1 and not reloadFlag:
    # キャップ (cap.txt の名前とパスワードに一致したとき) は、管理者名の置き換えをしない
    let capOk = isCap(name, tripPw)

    # 管理者名偽装防止
    if not capOk:
      name = name.replace(ADMIN, "＃" & ADMIN)

    if res.len > 0:
      subj = ""

    if name.len == 0:
      bbsError("投稿者を記入してください")
    if comm.len == 0:
      bbsError("コメントが入力されていません")
    if res.len == 0 and subj.len == 0:
      bbsError("題名が入力されていません")

    let leftSec = postIntervalLeft(folder)
    if leftSec > 0:
      bbsError("連投を検知しました。あと " & $leftSec & " 秒ほど待ってから投稿してください")

    let ip = clientIp()
    if subj.len > 0:
      checkGlobalIp(ip)

    comm = linkifyUrlsAuto(comm)
    var trip = ""
    if capOk:
      name &= CAP_MARK
    else:
      trip = makeTrip(tripPw)
      if trip.len > 0:
        name &= TRIP_MARK & trip
    if mail.len > 0:
      name = "<a href=\"mailto:" & mail & " \">" & name & " </a>"

    let now = jstNow()
    let postId = makeId(ip, folder, now)
    const wdays = ["月", "火", "水", "木", "金", "土", "日"]   # 月曜はじまり (Python の weekday())
    let wday = wdays[ord(now.weekday)]
    let dateStr = "20" & p2(now.year mod 100) & "年" & p2(ord(now.month)) & "月" &
                  p2(now.monthday) & "日(" & wday & ")" & p2(now.hour) & "時" &
                  p2(now.minute) & "分" & p2(now.second) & "秒"

    if res.len == 0:
      res = p2(now.year mod 100) & p2(ord(now.month)) & p2(now.monthday) &
            p2(now.hour) & p2(now.minute) & p2(now.second)

    var filePath = "./" & folder & "/" & res & ".html"
    var W: File
    if subj.len > 0:
      var created = false
      var attempt = 0
      while attempt <= 30:
        filePath = "./" & folder & "/" & res & ".html"
        if not fileExists("./" & folder & "/x" & res & ".html") and
           not archivedExists(folder, res):
          let fd = posix.open(filePath.cstring, O_RDWR or O_CREAT or O_EXCL, Mode(0o644))
          if fd >= 0:
            if open(W, cast[FileHandle](fd), fmReadWrite):
              created = true
              break
            discard posix.close(fd)
        if attempt >= 30:
          bbsError("スレッドを作成できません.")
        res = $(parseInt(res) + 1)
        inc attempt
      if not created:
        bbsError("スレッドを作成できません.")
    else:
      if not open(W, filePath, fmReadWriteExisting):
        threadMissing(folder, res, "返信")

    lockFile(W)
    # 返信: ロックを待っているあいだに、過去ログの圧縮 (archive) がこのファイルの名前を消していたら (nlink = 0)、
    # 書き込んでも、どこにも残らない。成功したように見せずに、エラーにする。
    # (圧縮側は、消す直前に同じファイルの flock を取って確認するので、この確認と書き込みのあいだに消されることもない)
    if subj.len == 0:
      var nlink = 1
      var st: posix.Stat
      if posix.fstat(cint(getFileHandle(W)), st) == 0:
        nlink = int(st.st_nlink)
      if nlink == 0:
        close(W)
        threadMissing(folder, res, "返信")

    # 鍵つきスレッド: 状態の確認からフォームの書き込みまで、同じロックの中でやる (管理者の鍵のかけ外しとずれない)
    let locked = subj.len == 0 and threadIsLocked(folder, res)
    if locked:
      let given = form.getOrDefault("key", "")
      if given.len == 0:
        close(W)
        bbsError("このスレッドは認証キーが必要です。ページを再読み込みして、認証キーの欄に入力してください。")
      if not keyVerify(folder, res, given):
        close(W)
        bbsError("認証キーが正しくありません。")

    # 最後の <dt> 行までを読む (Python は readline() で1行ずつ読み、tell() で位置を取る)
    setFilePos(W, 0)
    let content = readAll(W)
    var cnt = 0
    var pos = 0
    var prev = ""
    var off = 0
    while off < content.len:
      let nl = content.find('\n', off)
      let lineEnd = if nl < 0: content.len else: nl + 1
      let line = content[off ..< lineEnd]
      let num = dtNumberOf(line)
      if num < 0: break
      cnt = num
      prev = line
      pos = lineEnd
      off = lineEnd

    setFilePos(W, pos)
    cnt += 1

    let pm = parsePrevPost(prev)
    if pm.ok and name == pm.name and comm == pm.comm:
      close(W)
      bbsError("二重カキコです.")

    var subj1 = ""
    var subj2 = ""
    if subj.len > 0:
      subj1 = "<html><head><meta charset=\"UTF-8\">" &
              "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" &
              "<title>" & subj & " </title>" &
              "<link rel=\"stylesheet\" href=\"../style.css\">" & SCRIPT_TAG &
              "</head><body>"
      subj2 = "<font size=+2 color=red><b>" & subj & " </b></font>"

    let meta = "<font size=-1 class=\"meta\" data-id=\"" & postId & "\"" &
               (if trip.len > 0: " data-trip=\"" & trip & "\"" else: "") & ">"
    let newLine = subj1 & "<dl><dt>" & $cnt & subj2 &
                  "投稿者：<font color=forestgreen><b>" & name & " </b></font>" &
                  meta & "　投稿日：" & dateStr & " ID:" & postId & "</font><br><dd>" &
                  comm & " </dl>\n"
    let footer = replyForm(res, "", locked) & "</body></html>\n"
    W.write(newLine)
    W.write(footer)
    flushFile(W)
    discard posix.ftruncate(cint(getFileHandle(W)), Off(pos + newLine.len + footer.len))
    close(W)
    touchLasttime(folder)

  let regenRes = regenIndex(folder, page, reloadFlag)
  redirect(folder, regenRes.name)

setCurrentDir(getAppDir())
applyConfig()
main()
