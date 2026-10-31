# gz.nim - gzip 圧縮/伸長 (システムの libz への薄い FFI)。
# amezo.py の gzip モジュール相当を、archive / 配信まわりで使うために用意する。
{.passL: "-lz".}

type
  ZStream {.importc: "z_stream", header: "<zlib.h>", final.} = object
    next_in: ptr uint8
    avail_in: cuint
    total_in: culong
    next_out: ptr uint8
    avail_out: cuint
    total_out: culong
    msg: cstring
    state: pointer
    zalloc: pointer
    zfree: pointer
    opaque: pointer
    data_type: cint
    adler: culong
    reserved: culong

const
  Z_OK = 0
  Z_STREAM_END = 1
  Z_BUF_ERROR = -5
  Z_NO_FLUSH = 0
  Z_FINISH = 4
  Z_DEFLATED = 8

proc zlibVersion(): cstring {.importc, header: "<zlib.h>".}
proc deflateInit2(strm: ptr ZStream, level, meth, windowBits, memLevel,
                  strategy: cint, version: cstring,
                  stream_size: cint): cint {.importc: "deflateInit2_",
    header: "<zlib.h>".}
proc deflate(strm: ptr ZStream, flush: cint): cint {.
  importc, header: "<zlib.h>".}
proc deflateEnd(strm: ptr ZStream): cint {.importc, header: "<zlib.h>".}
proc inflateInit2(strm: ptr ZStream, windowBits: cint, version: cstring,
                  stream_size: cint): cint {.importc: "inflateInit2_",
    header: "<zlib.h>".}
proc inflate(strm: ptr ZStream, flush: cint): cint {.
  importc, header: "<zlib.h>".}
proc inflateEnd(strm: ptr ZStream): cint {.importc, header: "<zlib.h>".}
proc crc32z(crc: culong, buf: ptr uint8, len: cuint): culong {.
  importc: "crc32", header: "<zlib.h>".}

const ChunkSize = 65536

proc gzError(msg: string): ref CatchableError =
  newException(CatchableError, msg)

proc gzCompress*(data: string, level: int = 6): string =
  ## 文字列全体を gzip 圧縮する。
  var strm: ZStream
  if deflateInit2(addr strm, cint(level), Z_DEFLATED, 15 + 16, 8, 0,
                  zlibVersion(), cint(sizeof(ZStream))) != Z_OK:
    raise gzError("deflateInit2 failed")
  strm.next_in = cast[ptr uint8](data.cstring)
  strm.avail_in = cuint(data.len)
  result = ""
  var chunk = newString(ChunkSize)
  var last: cint = Z_OK
  while last != Z_STREAM_END:
    strm.next_out = cast[ptr uint8](chunk.cstring)
    strm.avail_out = cuint(chunk.len)
    last = deflate(addr strm, Z_FINISH)
    let have = chunk.len - int(strm.avail_out)
    if have > 0:
      result.add(chunk[0 ..< have])
    if last != Z_OK and last != Z_STREAM_END:
      discard deflateEnd(addr strm)
      raise gzError("deflate failed: " & $last)
  discard deflateEnd(addr strm)

proc gzUncompress*(data: string): string =
  ## gzip 文字列全体を伸長する。壊れたデータでは CatchableError を投げる。
  var strm: ZStream
  if inflateInit2(addr strm, 15 + 16, zlibVersion(),
                  cint(sizeof(ZStream))) != Z_OK:
    raise gzError("inflateInit2 failed")
  strm.next_in = cast[ptr uint8](data.cstring)
  strm.avail_in = cuint(data.len)
  result = ""
  var chunk = newString(ChunkSize)
  var sawEnd = false
  while not sawEnd:
    strm.next_out = cast[ptr uint8](chunk.cstring)
    strm.avail_out = cuint(chunk.len)
    let r = inflate(addr strm, Z_NO_FLUSH)
    let have = chunk.len - int(strm.avail_out)
    if have > 0:
      result.add(chunk[0 ..< have])
    if r == Z_STREAM_END:
      sawEnd = true
    elif r != Z_OK:
      discard inflateEnd(addr strm)
      raise gzError("inflate failed: " & $r)
    elif have == 0 and strm.avail_in == 0:
      # 入力を使い切ったのに終端に届かない = 途中で切れたデータ
      discard inflateEnd(addr strm)
      raise gzError("inflate failed: truncated data")
  discard inflateEnd(addr strm)

proc gzipCrc32*(data: string): uint32 =
  uint32(crc32z(0, cast[ptr uint8](data.cstring), cuint(data.len)))

# ---- ストリーム版 --------------------------------------------------------

type
  GzWriter* = ref object
    f: File
    strm: ZStream
    outBuf: string
    closed: bool

  GzReader* = ref object
    f: File
    strm: ZStream
    inBuf: string
    outBuf: string
    inPos: int        # inBuf の未消費位置 (avail_in は strm 側と二重管理しない)
    atEof: bool       # 入力ファイルを読み尽くした
    sawEnd: bool      # gzip ストリームの終端に達した
    finished: bool    # readChunk が "" を返した後
    closed: bool

proc newGzWriter*(f: File, level: int): GzWriter =
  result = GzWriter(f: f, outBuf: newString(ChunkSize), closed: false)
  if deflateInit2(addr result.strm, cint(level), Z_DEFLATED, 15 + 16, 8, 0,
                  zlibVersion(), cint(sizeof(ZStream))) != Z_OK:
    raise gzError("deflateInit2 failed")

proc flushOut(w: GzWriter) =
  let have = w.outBuf.len - int(w.strm.avail_out)
  if have > 0:
    if w.f.writeBuffer(w.outBuf.cstring, have) != have:
      raise gzError("write failed")
  w.strm.next_out = cast[ptr uint8](w.outBuf.cstring)
  w.strm.avail_out = cuint(w.outBuf.len)

proc write*(w: GzWriter, data: string) =
  if data.len == 0:
    return
  w.strm.next_in = cast[ptr uint8](data.cstring)
  w.strm.avail_in = cuint(data.len)
  if w.strm.avail_out == 0:
    w.strm.next_out = cast[ptr uint8](w.outBuf.cstring)
    w.strm.avail_out = cuint(w.outBuf.len)
  while w.strm.avail_in > 0:
    let r = deflate(addr w.strm, Z_NO_FLUSH)
    if r != Z_OK:
      raise gzError("deflate failed: " & $r)
    if w.strm.avail_out == 0:
      w.flushOut()

proc close*(w: GzWriter) =
  if w.closed:
    return
  w.closed = true
  if w.strm.avail_out == 0:
    w.strm.next_out = cast[ptr uint8](w.outBuf.cstring)
    w.strm.avail_out = cuint(w.outBuf.len)
  var r: cint = Z_OK
  while r != Z_STREAM_END:
    r = deflate(addr w.strm, Z_FINISH)
    if r != Z_OK and r != Z_STREAM_END:
      discard deflateEnd(addr w.strm)
      raise gzError("deflate failed: " & $r)
    w.flushOut()
  discard deflateEnd(addr w.strm)

proc newGzReader*(f: File): GzReader =
  result = GzReader(f: f, inBuf: "", outBuf: newString(ChunkSize),
                    inPos: 0, atEof: false, sawEnd: false,
                    finished: false, closed: false)
  if inflateInit2(addr result.strm, 15 + 16, zlibVersion(),
                  cint(sizeof(ZStream))) != Z_OK:
    raise gzError("inflateInit2 failed")

proc readChunk*(r: GzReader): string =
  ## 伸長した塊を返す。きれいな EOF でのみ "" を返し、壊れたデータでは例外。
  if r.finished:
    return ""
  result = ""
  while true:
    if r.strm.avail_in == 0 and not r.sawEnd:
      if r.atEof:
        if r.sawEnd:
          break
        raise gzError("truncated gzip data")
      # 入力を補充する (inPos 以降が未消費なら前に詰める。通常は全部消費済み)
      if r.inPos > 0:
        r.inBuf = r.inBuf[r.inPos ..< r.inBuf.len]
        r.inPos = 0
      let oldLen = r.inBuf.len
      r.inBuf.setLen(oldLen + ChunkSize)
      let got = r.f.readBuffer(addr r.inBuf[oldLen], ChunkSize)
      r.inBuf.setLen(oldLen + got)
      if got == 0:
        r.atEof = true
        continue
      r.strm.next_in = cast[ptr uint8](cast[int](r.inBuf.cstring) + r.inPos)
      r.strm.avail_in = cuint(r.inBuf.len - r.inPos)
    r.strm.next_out = cast[ptr uint8](r.outBuf.cstring)
    r.strm.avail_out = cuint(r.outBuf.len)
    let beforeIn = int(r.strm.avail_in)
    let rc = inflate(addr r.strm, Z_NO_FLUSH)
    r.inPos += beforeIn - int(r.strm.avail_in)
    let have = r.outBuf.len - int(r.strm.avail_out)
    if have > 0:
      result.add(r.outBuf[0 ..< have])
    if rc == Z_STREAM_END:
      r.sawEnd = true
      r.finished = true
      return result
    if rc != Z_OK and rc != Z_BUF_ERROR:
      raise gzError("inflate failed: " & $rc)
    if result.len > 0:
      return result
    if rc == Z_BUF_ERROR and r.strm.avail_in == 0 and r.atEof:
      raise gzError("truncated gzip data")
    # 出力が無かったら、入力を補充して続ける

proc close*(r: GzReader) =
  if r.closed:
    return
  r.closed = true
  discard inflateEnd(addr r.strm)
