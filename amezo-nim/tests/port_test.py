# -*- coding: utf-8 -*-
# 移植した機能の結合テスト (Nim 版: サーバーと CGI はコンパイル済みバイナリ): サーバーを立てて、投稿・中継 (jump)・鍵つきスレッド・
# 管理画面・配信の 400/404・ページ送り・過去ログの gz 配信までを通しで確認する。
# 一時フォルダにコピーして実行する (元のフォルダは汚さない)。
# 実行: python3 tests/port_test.py
import gzip
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ng = 0
ok = 0


def chk(name, cond, extra=''):
    global ng, ok
    if cond:
        ok += 1
        print(f'OK {name}')
    else:
        ng += 1
        print(f'NG {name} {extra}')


d = tempfile.mkdtemp(prefix='amezo_port_')
shutil.copytree(ROOT, d, dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('.git', 'nimcache', 'tests', '*.patch'))
with open(os.path.join(d, 'config.ini'), 'w', encoding='utf-8') as f:
    f.write('POST_INTERVAL = 0\nGLOBAL_WINDOW = 0\n')
r = subprocess.run(['./amezo.cgi', '--make-hash', 'adminpw'],
                   cwd=d, capture_output=True, text=True)
with open(os.path.join(d, 'delpass.txt'), 'w', encoding='utf-8') as f:
    f.write(r.stdout.strip())
for b in ('main', 'zatsu', 'test'):
    os.makedirs(os.path.join(d, b), exist_ok=True)

with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
BASE = f'http://127.0.0.1:{port}'
srv = subprocess.Popen(['./server', '--no-tunnel', '--port', str(port)],
                       cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def req(path, data=None, headers=None):
    rq = urllib.request.Request(BASE + path, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(rq, timeout=15) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def post(path, fields):
    return req(path, data=urllib.parse.urlencode(fields).encode())


try:
    for _ in range(60):
        try:
            if req('/style.css')[0] == 200:
                break
        except Exception:
            pass
        time.sleep(0.5)
    else:
        print('NG サーバーが起動しない')
        sys.exit(1)

    # ---- 投稿と中継リンク ----
    st, hd, body = post('/amezo.cgi', {'folder': 'main', 'name': '名無し', 'subj': 'テストスレ',
                                       'comm': '見て https://example.com/?a=1&b=2 ね'})
    chk('新規投稿できる', st in (200, 303), str(st))
    files = [f for f in os.listdir(os.path.join(d, 'main')) if re.fullmatch(r'\d+\.html', f)]
    chk('スレッドファイルができた', len(files) == 1, str(files))
    res = files[0][:-5]
    html = open(os.path.join(d, 'main', files[0]), encoding='utf-8').read()
    chk('本文が jump リンク化', '../jump.cgi?u=' in html)
    chk('表示文字は元の URL', '>https://example.com/?a=1&amp;b=2</a>' in html)
    m = re.search(r'href="\.\./jump\.cgi\?u=([^&]+)&amp;s=([^"]+)"', html)
    u, s = m.group(1), m.group(2)

    st, hd, body = req(f'/jump.cgi?u={u}&s={s}')
    t = body.decode('utf-8')
    chk('jump: 正しい署名で進むリンク', st == 200 and '進む' in t and 'example.com' in t)
    chk('jump: Cache-Control no-store', hd.get('Cache-Control') == 'no-store')
    st, hd, body = req(f'/jump.cgi?u={u}&s={"A" * 22}')
    t = body.decode('utf-8')
    chk('jump: 改ざんではリンクを出さない', 'href="https://example.com' not in t)
    chk('jump: 改ざんでも URL は文字で出る', 'https://example.com/?a=1&amp;b=2' in t)

    # ---- 鍵つきスレッド ----
    post('/admin.cgi', {'adminpass': 'adminpw', 'act': 'lock', 'folder': 'main', 'res': res})
    chk('admin: 鍵をかけると .lock ができる', os.path.exists(os.path.join(d, 'main', res + '.lock')))
    st, hd, body = post('/admin.cgi', {'adminpass': 'adminpw', 'act': 'issue', 'folder': 'main',
                                       'res': res, 'label': 'テスト', 'scope': 'thread'})
    km = re.search(r'([A-Z2-7]{4}(?:-[A-Z2-7]{4}){5})', body.decode('utf-8'))
    chk('admin: 発行キーが1回だけ表示される', km is not None)
    key = km.group(1)
    st, hd, body = post('/amezo.cgi', {'folder': 'main', 'name': '名無し', 'res': res, 'comm': '鍵なし'})
    chk('鍵なし返信はエラー', '認証キーが必要です' in body.decode('utf-8'))
    st, hd, body = post('/amezo.cgi', {'folder': 'main', 'name': '名無し', 'res': res, 'comm': '鍵ちがい',
                                       'key': 'AAAA-AAAA-AAAA-AAAA-AAAA-AAAA'})
    chk('間違った鍵はエラー', '認証キーが正しくありません' in body.decode('utf-8'))
    post('/amezo.cgi', {'folder': 'main', 'name': '名無し', 'res': res, 'comm': '鍵つき返信おk', 'key': key})
    html = open(os.path.join(d, 'main', files[0]), encoding='utf-8').read()
    chk('正しい鍵で返信できる', '鍵つき返信おk' in html)
    chk('返信後もフォームに鍵欄がある', 'name="key"' in html)

    post('/admin.cgi', {'adminpass': 'wrongpw', 'act': 'boards'})
    fm = ''
    fp = os.path.join(d, 'admin_fail.mem')
    if os.path.exists(fp):
        fm = open(fp).read()
    chk('admin: 失敗記録に生 IP が残らない', fm.strip() != '' and '127.0.0.1' not in fm, fm[:80])

    # ---- 配信の 400 / 404 ----
    chk('// は 400', req('//amezo.py')[0] == 400)
    chk('.. は 400', req('/main/../amezo.py')[0] == 400)
    chk('config.ini は 404', req('/config.ini')[0] == 404)
    chk('archive.py は 404', req('/archive.py')[0] == 404)
    chk('archive バイナリも 404', req('/archive')[0] == 404)
    chk('.gz 直アクセスは 404', req('/main/o1.html.gz')[0] == 404)

    # ---- ページ送り ----
    chk('page=99 は最後のページに寄る', req('/amezo.cgi?folder=main&page=99')[0] in (200, 303))
    post('/amezo.cgi', {'folder': 'main', 'name': '名無し', 'subj': '明示page1', 'comm': 'x', 'page': '1'})
    files2 = [f for f in os.listdir(os.path.join(d, 'main')) if re.fullmatch(r'\d+\.html', f)]
    chk('明示 page=1 でも投稿できる', len(files2) == 2, str(files2))

    # ---- 過去ログの圧縮と gz 配信 ----
    src = os.path.join(d, 'main', files[0])
    arc = os.path.join(d, 'main', 'o260101000000.html')
    shutil.copy(src, arc)
    old = time.time() - 7200
    os.utime(arc, (old, old))
    subprocess.run(['./archive', 'main', '--quiet=0'], cwd=d, capture_output=True, text=True)
    subprocess.run(['./archive', 'main', '--quiet=0'], cwd=d, capture_output=True, text=True)
    chk('archive: 2回の実行で平文が消えて gz だけ残る',
        not os.path.exists(arc) and os.path.exists(arc + '.gz'))
    st, hd, body = req('/main/o260101000000.html')
    chk('gz 配信: 圧縮非対応には平文で 200', st == 200 and hd.get('Content-Encoding') is None and b'</html>' in body)
    chk('gz 配信: Vary と Cache-Control', hd.get('Vary') == 'Accept-Encoding'
        and hd.get('Cache-Control') == 'public, max-age=3600', str(hd))
    st, hd, body = req('/main/o260101000000.html', headers={'Accept-Encoding': 'gzip'})
    chk('gz 配信: 対応ブラウザには gz のまま', st == 200 and hd.get('Content-Encoding') == 'gzip'
        and b'</html>' in gzip.decompress(body))
    st, hd, body = req('/main/o260101000000.html', headers={'Accept-Encoding': 'gzip;q=0'})
    chk('gz 配信: q=0 なら平文', st == 200 and hd.get('Content-Encoding') is None)
finally:
    srv.terminate()
    try:
        srv.wait(timeout=10)
    except Exception:
        srv.kill()
    shutil.rmtree(d, ignore_errors=True)

print(f'== OK {ok} / NG {ng}')
sys.exit(1 if ng else 0)
