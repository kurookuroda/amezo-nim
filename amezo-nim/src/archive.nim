# -*- coding: utf-8 -*-
#
# archive.nim - 退避済みの過去ログ (oN.html) を gzip -6 で oN.html.gz にする (CLI 専用。投稿の外で動かす)
#
#   archive 板名… | --all  [--quiet=秒] [--limit=件数] [--dry-run] [-v]
#   archive --restore 板名 oN        (gz から平文を作る。gz は残す)
#   archive --selftest [板名]        (nlink / flock / rename / 更新日時 / gzip が、この環境で働くかを確認)
#
# 段階1: 平文から oN.html.gz を作る (平文は残す)。
# 段階2: gz の作成から十分たち、gz が平文と同期し、中身が一致するときだけ、平文を消す (消す直前に平文の flock を取って再確認)。
# 投稿側 (amezo) は、flock を取った直後に nlink を確認する。この2つが組になって、投稿の静かな消失を防ぐ。
# 安全の保証はこの構造が担う。--quiet (既定 ARCHIVE_QUIET_SECONDS) の待機は、無駄を減らす工夫にすぎない。
#
# archive.py の Nim 移植。挙動・出力文言・終了コードは Python 版に合わせる
# (使い方などのプログラム名の言及だけ、バイナリ名に合わせてある)。

import std/[os, osproc, strutils, tables, times, posix, algorithm, unicode]
import nimcrypto/sha2
import nimcrypto/hash
import bbs
import gz

const ArchLockTries = 50          # 平文のロックを待つ回数 (0.1秒おき = 最大5秒)
const ArchTmpMaxAge = 86400'i64   # これより古い一時ファイル (.gz.tmp*) は掃除する
const Chunk = 65536
const LockChildArg = "--selftest-lock-child"   # 自己チェック用: 別プロセスとして flock を保持する隠し引数

var quietDefault = 600            # 起動時に bbs の ARCHIVE_QUIET_SECONDS (設定適用後) で上書きする

# ---- 出力 -------------------------------------------------------------------

proc archOut(s: string) =
  stdout.write(s & "\n")
  stdout.flushFile()

proc archErr(s: string) =
  stderr.write(s & "\n")
  stderr.flushFile()

proc archMb(b: int64): string =
  formatFloat(b.float / 1048576.0, ffDecimal, 2) & "MB"

proc fmtInt(x: float): string =
  ## Python の f"{x:.0f}" と同じ (Nim の formatFloat は "0." のように点が残ることがある)
  result = formatFloat(x, ffDecimal, 0)
  if result.endsWith('.'):
    result.setLen(result.len - 1)

proc lstripDotSlash(s: string): string =
  # Python の str.lstrip('./') と同じ (先頭の '.' と '/' を全部落とす)
  var i = 0
  while i < s.len and (s[i] == '.' or s[i] == '/'):
    inc i
  s[i ..< s.len]

# ---- stat / ダイジェスト ------------------------------------------------------

type ArchStat = object
  size: int64
  mtime: int64
  ctime: int64

proc archStat(p: string): tuple[ok: bool, st: ArchStat] =
  ## stat を新しく読む。読めなければ ok = false
  var st: posix.Stat
  if posix.stat(p.cstring, st) != 0:
    return (false, ArchStat())
  (true, ArchStat(size: int64(st.st_size), mtime: int64(st.st_mtim.tv_sec),
                  ctime: int64(st.st_ctim.tv_sec)))

proc diskFree(p: string): tuple[ok: bool, free: int64] =
  var vfs: posix.Statvfs
  if posix.statvfs(p.cstring, vfs) != 0:
    return (false, 0)
  (true, int64(vfs.f_bavail) * int64(vfs.f_frsize))

type Digest = object
  ok: bool
  hex: string
  length: int64

proc finishHex(ctx: var sha256): string =
  toLowerAscii($ctx.finish())

proc archFileDigest(p: string): Digest =
  ## [sha256, 長さ]。読めなければ ok = false
  var f: File
  try:
    f = open(p, fmRead)
  except OSError:
    return Digest(ok: false)
  var ctx: sha256
  ctx.init()
  var n: int64 = 0
  var buf = newString(Chunk)
  try:
    while true:
      let got = f.readBuffer(addr buf[0], Chunk)
      if got == 0:
        break
      n += got
      ctx.update(buf.toOpenArrayByte(0, got - 1))
  except CatchableError:
    f.close()
    return Digest(ok: false)
  f.close()
  Digest(ok: true, hex: finishHex(ctx), length: n)

proc archGzDigest(p: string): Digest =
  ## gz を最後まで展開して [sha256, 長さ] を返す。開けなければ ok = false
  var f: File
  try:
    f = open(p, fmRead)
  except OSError:
    return Digest(ok: false)
  var r: GzReader
  try:
    r = newGzReader(f)
    var ctx: sha256
    ctx.init()
    var n: int64 = 0
    while true:
      let chunk = r.readChunk()
      if chunk.len == 0:
        break
      n += chunk.len
      ctx.update(chunk.toOpenArrayByte(0, chunk.len - 1))
    result = Digest(ok: true, hex: finishHex(ctx), length: n)
  except CatchableError:
    result = Digest(ok: false)
  if r != nil:
    try:
      r.close()
    except CatchableError:
      discard
  f.close()

proc archGzIsize(p: string): tuple[ok: bool, size: int64] =
  ## gz 末尾4バイト (ISIZE = 元のサイズ。4GiB で折り返す)
  var f: File
  try:
    f = open(p, fmRead)
  except OSError:
    return (false, 0)
  defer: f.close()
  let sz = f.getFileSize()
  if sz < 4:
    return (false, 0)
  f.setFilePos(sz - 4)
  var b = newString(4)
  if f.readBuffer(addr b[0], 4) != 4:
    return (false, 0)
  let v = uint32(byte(b[0])) or (uint32(byte(b[1])) shl 8) or
          (uint32(byte(b[2])) shl 16) or (uint32(byte(b[3])) shl 24)
  (true, int64(v))

# ---- 走査 ---------------------------------------------------------------------
# 名前の形の判定は、Python 版の正規表現 (o(\d+)\.html など) と同じ意味を、手書きで行う
# (std/re は libpcre.so が要るので、単独で配る CLI では使わない)。

proc digitsVal(s: string): tuple[ok: bool, num: int] =
  ## 数字だけの文字列なら、その値 (大きすぎるものは並び順の都合で最大値に丸める)
  if s.len == 0 or not allCharsInSet(s, {'0' .. '9'}):
    return (false, 0)
  try:
    (true, parseInt(s))
  except ValueError:
    (true, int.high)

proc matchPlainName(name: string): tuple[ok: bool, num: int] =
  ## o(\d+)\.html の全体一致
  if name.len > 6 and name[0] == 'o' and name.endsWith(".html"):
    return digitsVal(name[1 ..< name.len - 5])
  (false, 0)

proc isTmpName(name: string): bool =
  ## o\d+\.html\.gz\.tmp\d* の全体一致
  if name.len == 0 or name[0] != 'o':
    return false
  let idx = name.find(".html.gz.tmp")
  if idx < 1:
    return false
  let (dok, _) = digitsVal(name[1 ..< idx])
  if not dok:
    return false
  allCharsInSet(name[idx + ".html.gz.tmp".len ..< name.len], {'0' .. '9'})

proc archScan(folder: string): tuple[plain: seq[tuple[name: string, num: int]],
                                     gz: Table[string, int], tmp: seq[string]] =
  ## 板フォルダの中の、過去ログを数える。(平文 (番号順), gz (平文の名前 => 番号), 一時ファイルのパス)
  var plain: seq[tuple[name: string, num: int]] = @[]
  var gzs = initTable[string, int]()
  var tmp: seq[string] = @[]
  try:
    for kind, path in walkDir("./" & folder):
      let name = extractFilename(path)
      if name.len == 0 or name[0] != 'o':
        continue
      let (pok, pnum) = matchPlainName(name)
      if pok:
        plain.add((name, pnum))
        continue
      if name.endsWith(".gz"):
        let (gok, gnum) = matchPlainName(name[0 ..< name.len - 3])
        if gok:
          gzs[name[0 ..< name.len - 3]] = gnum
          continue
      if isTmpName(name):
        tmp.add("./" & folder & "/" & name)
  except OSError:
    return (@[], initTable[string, int](), @[])
  plain.sort(proc(a, b: tuple[name: string, num: int]): int = cmp(a.num, b.num))
  (plain, gzs, tmp)

# ---- 圧縮・削除 ---------------------------------------------------------------

type Archiver = ref object
  quiet: int
  dry: bool
  verbose: bool
  compressed: int64
  plainRemoved: int64
  staleGzRemoved: int64
  quarantined: int64
  ng: int64
  inBytes: int64
  outBytes: int64
  skip: OrderedTable[string, int]

proc say(a: Archiver, path, msg: string) =
  var s = lstripDotSlash(path)
  let pad = 34 - runeLen(s)
  if pad > 0:
    s.add(repeat(' ', pad))
  archOut(s & " " & msg)

proc skip(a: Archiver, path, reason: string): bool =
  a.skip[reason] = a.skip.getOrDefault(reason, 0) + 1
  if a.verbose:
    a.say(path, "skip: " & reason)
  return false

proc ng(a: Archiver, path, msg: string): bool =
  a.ng += 1
  a.say(path, "NG: " & msg)
  return false

proc stage1(a: Archiver, plain: string): bool =
  ## 段階1: 平文から gz を作る。作った (dry-run では作る予定の) なら true
  let (okSt, st) = archStat(plain)
  if not okSt:
    return a.skip(plain, "ファイルが無い")
  if int64(int(epochTime())) - st.mtime < a.quiet:
    return a.skip(plain, "最後の書き込みから間もない")
  let dirp = parentDir(plain)
  let (fok, free) = diskFree(if dirp.len == 0: "." else: dirp)
  if fok and free < st.size + 1048576:
    return a.skip(plain, "ディスクの空きが足りない")
  if a.dry:
    a.say(plain, "[dry-run] 圧縮する (" & archMb(st.size) & ")")
    a.compressed += 1
    return true
  let t0 = epochTime()
  let gzpath = plain & ".gz"
  let tmp = gzpath & ".tmp" & $getCurrentProcessId()
  var fin: File
  try:
    fin = open(plain, fmRead)
  except OSError:
    return a.ng(plain, "開けない (権限・空き容量を確認)")
  var fout: File
  try:
    fout = open(tmp, fmWrite)
  except OSError:
    fin.close()
    discard tryRemoveFile(tmp)
    return a.ng(plain, "開けない (権限・空き容量を確認)")
  var w: GzWriter
  try:
    w = newGzWriter(fout, 6)
  except CatchableError:
    fin.close()
    fout.close()
    discard tryRemoveFile(tmp)
    return a.ng(plain, "開けない (権限・空き容量を確認)")
  var ctx: sha256
  ctx.init()
  var n: int64 = 0
  var buf = newString(Chunk)
  var closed = true
  while true:                     # ストリーム: メモリは一定
    let got = fin.readBuffer(addr buf[0], Chunk)
    if got == 0:
      break
    n += got
    ctx.update(buf.toOpenArrayByte(0, got - 1))
    try:
      w.write(buf[0 ..< got])
    except CatchableError:
      closed = false
      break
  fin.close()
  if closed:
    try:
      w.close()
    except CatchableError:
      closed = false
  fout.close()
  let src = finishHex(ctx)
  let d = if closed: archGzDigest(tmp) else: Digest(ok: false)
  if not d.ok or d.hex != src or d.length != n:
    discard tryRemoveFile(tmp)
    return a.ng(plain, "展開して確かめたら、元と一致しない (一時ファイルを消した)")
  let (ok2, st2) = archStat(plain)                # 圧縮している間に、元が書き換わっていないか
  if not ok2 or st2.size != st.size or st2.mtime != st.mtime or n != st.size:
    discard tryRemoveFile(tmp)
    return a.skip(plain, "圧縮している間に元が変わった")
  try:
    setLastModificationTime(tmp, fromUnix(st.mtime))   # 更新日時を引き継ぐ (同期の印。kako の並びも保つ)
  except OSError:
    discard
  try:
    setFilePermissions(tmp, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  except OSError:
    discard
  try:
    moveFile(tmp, gzpath)
  except OSError:
    discard tryRemoveFile(tmp)
    return a.ng(plain, "rename できない")
  let (okG, gs) = archStat(gzpath)
  let gsize = if okG: gs.size else: 0'i64
  a.compressed += 1
  a.inBytes += st.size
  a.outBytes += gsize
  a.say(plain, "圧縮  " & archMb(st.size) & " → " & archMb(gsize) &
        " (" & formatFloat(st.size.float / max(1'i64, gsize).float, ffDecimal, 1) &
        "倍)  " & fmtInt((epochTime() - t0) * 1000.0) & "ms")
  return true

proc stage2(a: Archiver, plain: string) =
  ## 段階2: 平文と gz が両方あるとき、条件が全部合えば、平文を消す
  let gzpath = plain & ".gz"
  let (okP, sp) = archStat(plain)
  let (okG, sg) = archStat(gzpath)
  if not okP or not okG:
    return
  if sg.mtime != sp.mtime:                        # 圧縮のあとに、平文が更新された → gz は古い
    if a.dry:
      a.say(plain, "[dry-run] 古い gz を削除する")
      a.staleGzRemoved += 1
      return
    discard tryRemoveFile(gzpath)
    a.staleGzRemoved += 1
    a.say(plain, "古い gz を削除 (平文が圧縮のあとに更新された。次回に再圧縮する)")
    return
  if int64(int(epochTime())) - sg.ctime < a.quiet:
    discard a.skip(plain, "gz の作成から間もない")
    return
  if sp.size >= 4294967296:
    discard a.skip(plain, "4GiB 以上は確認できない")
    return
  let (isOk, isize) = archGzIsize(gzpath)
  let dp = archFileDigest(plain)
  let dg = archGzDigest(gzpath)
  if not isOk or isize != sp.size or not dp.ok or not dg.ok or
     dp.hex != dg.hex or dp.length != dg.length:
    # どちらが壊れているかは判定できない。何も消さず、gz を脇へ退避する (平文が配信され続ける。gz が正しければ、証拠として残る)
    if a.dry:
      a.say(plain, "[dry-run] NG: gz の中身が平文と一致しない → gz を .bad に改名する")
      a.ng += 1
      return
    try:
      moveFile(gzpath, gzpath & ".bad")
    except OSError:
      discard
    a.quarantined += 1
    discard a.ng(plain, "gz の中身が平文と一致しない。どちらも消さず、gz を oN.html.gz.bad に改名した (人が確認する)")
    return
  var fh: File
  try:
    fh = open(plain, fmRead)
  except OSError:
    discard a.skip(plain, "ロックのために開けない")
    return
  var got = false
  for i in 0 ..< ArchLockTries:
    if tryLockFile(fh):
      got = true
      break
    os.sleep(100)
  if not got:
    fh.close()
    discard a.skip(plain, "ロックが取れない (投稿中?)")
    return
  var fst: posix.Stat
  discard posix.fstat(cint(fh.getFileHandle()), fst)   # ロックを取ったあとで、確認した内容のままか
  let same = int64(fst.st_nlink) > 0 and int64(fst.st_size) == sp.size and
             int64(fst.st_mtim.tv_sec) == sp.mtime
  if not same:
    unlockFile(fh)
    fh.close()
    discard a.skip(plain, "ロックを待つあいだに変わった (次回に判断する)")
    return
  if a.dry:
    unlockFile(fh)
    fh.close()
    a.say(plain, "[dry-run] 平文を削除する")
    a.plainRemoved += 1
    return
  let unlinked = tryRemoveFile(plain)             # ロックを持ったまま消す。待っている投稿は、nlink = 0 で弾かれる
  unlockFile(fh)
  fh.close()
  if not unlinked:
    discard a.ng(plain, "平文を消せない")
    return
  a.plainRemoved += 1
  a.say(plain, "平文を削除 (gz に置き換え)")

# ---- 自己チェック ---------------------------------------------------------------

proc lockChild(path: string) =
  ## 隠し引数: flock を取って5秒保持するだけの子プロセス (自己チェック用)
  var f: File
  try:
    f = open(path, fmReadWriteExisting)
  except OSError:
    quit(1)
  lockFile(f)
  os.sleep(5000)
  f.close()
  quit(0)

proc selftestFlockCheck(a: string, h: File): bool =
  ## 別プロセス (自分のバイナリを再実行) が持っている flock は、こちらからは取れないことの確認。
  ## 子がロックを取るまで、自分は「取れたらすぐ放す」を繰り返して待つ。
  var p: Process
  try:
    p = startProcess(getAppFilename(), args = @[LockChildArg, a])
  except OSError:
    return false
  result = false
  for i in 0 ..< 250:
    if tryLockFile(h):
      unlockFile(h)
      os.sleep(20)
    else:
      result = true
      break
  try:
    p.terminate()
  except CatchableError:
    discard
  discard p.waitForExit()
  p.close()

type SelfItem = tuple[label: string, ok: bool, detail: string]

proc archSelftest(dirpath: string, full: bool = true): seq[SelfItem] =
  ## 環境の確認。full = false (毎回の簡易版) は、ctime の確認で待たない
  var r: seq[SelfItem] = @[]
  proc add(label: string, ok: bool, detail: string = "") =
    r.add((label, ok, detail))
  add("gzip モジュールが使える", true)
  let base = dirpath.strip(leading = false, trailing = true, chars = {'/'}) &
             "/.archive-selftest-" & $getCurrentProcessId()
  let a = base & ".a"
  let b = base & ".b"
  try:
    try:
      writeFile(a, "selftest\n")
    except OSError:
      add("フォルダに書き込める", false, dirpath)
      return r
    add("フォルダに書き込める", true)
    var h = open(a, fmReadWriteExisting)
    var fst: posix.Stat
    discard posix.fstat(cint(h.getFileHandle()), fst)
    add("通常のファイルの nlink は 1", int64(fst.st_nlink) == 1, "nlink=" & $int64(fst.st_nlink))
    discard tryRemoveFile(a)
    discard posix.fstat(cint(h.getFileHandle()), fst)
    add("開いたまま unlink すると nlink が 0 になる", int64(fst.st_nlink) == 0, "nlink=" & $int64(fst.st_nlink))
    h.close()
    writeFile(a, "selftest\n")
    h = open(a, fmReadWriteExisting)
    moveFile(a, b)
    discard posix.fstat(cint(h.getFileHandle()), fst)
    add("開いたまま rename しても nlink は 1 のまま", int64(fst.st_nlink) == 1, "nlink=" & $int64(fst.st_nlink))
    h.close()
    setLastModificationTime(b, fromUnix(1700000000))
    let (okB, sb) = archStat(b)
    add("os.utime で更新日時 (mtime) を指定できる", okB and sb.mtime == 1700000000)
    let c0 = if okB: sb.ctime else: 0'i64
    if full:
      os.sleep(1000)
    moveFile(b, a)
    let (okA, sa) = archStat(a)
    let ctimeOk = okA and (if full: sa.ctime > c0 else: sa.ctime >= c0)
    add("rename で ctime が更新され、mtime は保たれる",
        okA and ctimeOk and sa.mtime == 1700000000,
        "ctime " & $c0 & " → " & (if okA: $sa.ctime else: "?"))
    var locked = false
    try:
      let h2 = open(a, fmReadWriteExisting)
      locked = selftestFlockCheck(a, h2)
      h2.close()
    except OSError:
      locked = false
    add("別プロセスが持っている flock は、こちらからは取れない", locked)
    var vfs: posix.Statvfs
    add("shutil.disk_usage が使える", posix.statvfs(dirpath.cstring, vfs) == 0)
  finally:
    discard tryRemoveFile(a)
    discard tryRemoveFile(b)
  return r

# ---- 板・使い方 -----------------------------------------------------------------

proc archAllBoards(): seq[string] =
  ## 板名の一覧 (blist.txt の1列目)
  result = @[]
  var content = ""
  try:
    content = readFile("./blist.txt")
  except OSError:
    content = ""
  for line in content.splitLines():
    let name = line.split(',')[0]
    if name != "":
      result.add(name)

proc archValidBoard(b: string): bool =
  b.len > 0 and not b.contains('/') and not b.contains("..") and
    isBoard(b) and dirExists("./" & b)

proc archUsage() {.noreturn.} =
  archErr("使い方:\n" &
          "  archive 板名… | --all [--quiet=秒] [--limit=件数] [--dry-run] [-v]\n" &
          "  archive --restore 板名 oN\n" &
          "  archive --selftest [板名]")
  quit(2)

# ---- restore --------------------------------------------------------------------

proc matchRestoreName(s: string): tuple[ok: bool, num: string] =
  ## o?(\d+)(?:\.html)? の全体一致
  var t = s
  if t.startsWith('o'):
    t = t[1 ..< t.len]
  if t.endsWith(".html"):
    t = t[0 ..< t.len - 5]
  if t.len > 0 and allCharsInSet(t, {'0' .. '9'}):
    (true, t)
  else:
    (false, "")

proc archRestore(folder, oname: string): int =
  ## gz から平文を作る (gz は残す)。終了コードを返す
  let (rok, rnum) = matchRestoreName(oname)
  if not archValidBoard(folder) or not rok:
    archUsage()
  let plain = "./" & folder & "/o" & rnum & ".html"
  let gzpath = plain & ".gz"
  var lk: File
  var lkOpen = false
  try:
    lk = open("./" & folder & "/archive.lock", fmAppend)
    lkOpen = true
  except OSError:
    lkOpen = false
  if not lkOpen or not tryLockFile(lk):
    archErr("板 " & folder & ": 別の archive が実行中です")
    return 2
  if not fileExists(gzpath):
    archErr(gzpath & " が無い")
    return 2
  if fileExists(plain):
    archErr(plain & " がすでにある (上書きはしない)")
    return 2
  let (okSg, sg) = archStat(gzpath)
  let tmp = plain & ".restore.tmp" & $getCurrentProcessId()
  var inf: File
  var outf: File
  var inOk = false
  var outOk = false
  var rdr: GzReader
  try:
    inf = open(gzpath, fmRead)
    inOk = true
    rdr = newGzReader(inf)
    outf = open(tmp, fmWrite)
    outOk = true
  except CatchableError:
    discard
  if not (inOk and outOk):
    archErr("開けない")
    if outOk:
      outf.close()
    if inOk:
      inf.close()
    discard tryRemoveFile(tmp)
    return 2
  var n: int64 = 0
  try:
    while true:
      let chunk = rdr.readChunk()
      if chunk.len == 0:
        break
      n += chunk.len
      outf.write(chunk)
  except CatchableError:
    discard                                       # 壊れた gz は、長さの照合で弾く
  try:
    rdr.close()
  except CatchableError:
    discard
  inf.close()
  outf.close()
  let (isOk, isize) = archGzIsize(gzpath)
  if not isOk or n != isize:
    discard tryRemoveFile(tmp)
    archErr("展開した長さが、gz の記録と一致しない (gz が壊れている?)")
    return 1
  if okSg:
    try:
      setLastModificationTime(tmp, fromUnix(sg.mtime))
    except OSError:
      discard
  try:
    setFilePermissions(tmp, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  except OSError:
    discard
  try:
    moveFile(tmp, plain)
  except OSError:
    discard tryRemoveFile(tmp)
    archErr("rename できない")
    return 1
  archOut(plain & " を作った (" & archMb(n) & ")。gz は残してある。")
  archOut("  編集すると更新日時が変わり、配信は平文に切り替わる (古い gz は次回の実行で消え、その次に再圧縮される)。")
  archOut("  編集しなければ、次回以降の実行で、この平文はまた消える。")
  return 0

# ---- 本体 -----------------------------------------------------------------------

proc matchNumArg(a, prefix: string, maxDigits: int): tuple[ok: bool, val: int] =
  ## --quiet=(\d{1,7}) のような引数の全体一致
  if a.startsWith(prefix):
    let d = a[prefix.len ..< a.len]
    if d.len >= 1 and d.len <= maxDigits and allCharsInSet(d, {'0' .. '9'}):
      try:
        return (true, parseInt(d))
      except ValueError:
        discard
  (false, 0)

proc main(): int =
  let args = commandLineParams()
  if args.len >= 2 and args[0] == LockChildArg:
    lockChild(args[1])                            # quit する
  try:
    setCurrentDir(getAppDir())                    # バイナリのあるディレクトリに固定
  except OSError:
    discard
  applyConfig()
  let qc = ARCHIVE_QUIET_SECONDS
  if qc >= 0 and qc <= 604800:
    quietDefault = qc

  var optQuiet = quietDefault
  var optLimit = 0
  var optDry = false
  var optV = false
  var optAll = false
  var optRestore = false
  var optSelftest = false
  var boards: seq[string] = @[]
  for a in args:
    let qm = matchNumArg(a, "--quiet=", 7)
    let lm = matchNumArg(a, "--limit=", 9)
    if a == "--all":
      optAll = true
    elif a == "--dry-run":
      optDry = true
    elif a == "-v":
      optV = true
    elif a == "--restore":
      optRestore = true
    elif a == "--selftest":
      optSelftest = true
    elif qm.ok and qm.val <= 604800:
      optQuiet = qm.val
    elif lm.ok and lm.val >= 1:
      optLimit = lm.val
    elif a.len > 0 and not a.startsWith('-'):
      boards.add(a)
    else:
      archUsage()
  if optRestore:
    if boards.len != 2:
      archUsage()
    return archRestore(boards[0], boards[1])
  if optAll:
    boards = archAllBoards()
  if optSelftest:
    let allb = archAllBoards()
    let b = if boards.len > 0: boards[0]
            elif allb.len > 0: allb[0]
            else: ""
    if not archValidBoard(b):
      archUsage()
    var bad = 0
    archOut("自己チェック (フォルダ: ./" & b & ")")
    for it in archSelftest("./" & b):
      archOut((if it.ok: "OK   " else: "NG   ") & it.label &
              (if it.detail != "": "  (" & it.detail & ")" else: ""))
      if not it.ok:
        inc bad
    archOut(if bad == 0: "すべて OK。この環境で archive を使えます。"
            else: "NG が " & $bad & " 件。この環境では archive を動かさないでください。")
    return (if bad == 0: 0 else: 2)
  if boards.len == 0:
    archUsage()
  for b in boards:
    if not archValidBoard(b):
      archErr("板 " & b & ": 見つからない (blist.txt とフォルダを確認)")
      return 2
  if not optDry:                                  # 毎回、簡易の自己チェック (dry-run は何も書かないので省略)
    var badLabels: seq[string] = @[]
    for it in archSelftest("./" & boards[0], full = false):
      if not it.ok:
        badLabels.add(it.label)
    if badLabels.len > 0:
      for l in badLabels:
        archErr("自己チェック NG: " & l)
      archErr("この環境では動かしません。`archive --selftest 板名` で詳細を確認してください。")
      return 2

  # ---- 実行 ----
  let run = Archiver(quiet: optQuiet, dry: optDry, verbose: optV,
                     skip: initOrderedTable[string, int]())
  var remaining = optLimit
  for folder in boards:
    var lk: File
    var haveLock = false
    if not optDry:
      var opened = false
      try:
        lk = open("./" & folder & "/archive.lock", fmAppend)
        opened = true
      except OSError:
        opened = false
      if not opened or not tryLockFile(lk):
        if opened:
          lk.close()
        archOut("板 " & folder & ": 別の archive が実行中のため、スキップ")
        continue
      haveLock = true
    let (plainList, gzMap, tmps) = archScan(folder)
    if not optDry:
      for t in tmps:                              # 古い一時ファイル (途中で止まった圧縮の残り) の掃除
        let (okT, stT) = archStat(t)
        if okT and int64(int(epochTime())) - stT.mtime > ArchTmpMaxAge:
          discard tryRemoveFile(t)
          archOut(lstripDotSlash(t) & "  古い一時ファイルを削除")
    let before = (run.compressed, run.inBytes, run.outBytes, run.plainRemoved,
                  run.staleGzRemoved, run.quarantined, run.ng)
    for (name, num) in plainList:
      if gzMap.hasKey(name):
        run.stage2("./" & folder & "/" & name)    # 段階2 (先に。今回作る gz は、次回以降)
    for (name, num) in plainList:
      if gzMap.hasKey(name):
        continue
      if optLimit > 0 and remaining <= 0:
        discard run.skip("./" & folder & "/" & name, "--limit に達した")
        continue
      if run.stage1("./" & folder & "/" & name) and optLimit > 0:
        dec remaining
    archOut("板 " & folder & ": 圧縮 " & $(run.compressed - before[0]) &
            " (" & archMb(run.inBytes - before[1]) & " → " & archMb(run.outBytes - before[2]) & ")、" &
            "平文削除 " & $(run.plainRemoved - before[3]) & "、" &
            "古い gz 削除 " & $(run.staleGzRemoved - before[4]) & "、" &
            "gz を退避 " & $(run.quarantined - before[5]) & "、" &
            "NG " & $(run.ng - before[6]))
    if haveLock:
      unlockFile(lk)
      lk.close()
  if run.skip.len > 0:
    var parts: seq[string] = @[]
    for k, v in run.skip:
      parts.add(k & " " & $v)
    archOut("スキップ: " & parts.join(", "))
  if optV:
    var ru: posix.Rusage
    discard posix.getrusage(0, addr ru)
    let peak = int64(ru.ru_maxrss) * 1024
    archOut("メモリのピーク " & formatFloat(peak.float / 1048576.0, ffDecimal, 1) & "MB")
  return (if run.ng > 0: 1 else: 0)

quit(main())
