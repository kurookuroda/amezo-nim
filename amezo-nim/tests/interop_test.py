# -*- coding: utf-8 -*-
# Python 版と Nim 版が同じデータフォルダを共用できることの相互運用テスト。
# 隣に amezo-python リポジトリがある前提。実行: python3 tests/interop_test.py
# 1つのフォルダに両実装を同居させ、サーバーを入れ替えながら操作する。
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
PY = os.path.join(os.path.dirname(ROOT), 'amezo-python')
NIM = ROOT
ng = ok = 0


def chk(name, cond, extra=''):
    global ng, ok
    if cond:
        ok += 1
        print(f'OK {name}')
    else:
        ng += 1
        print(f'NG {name} {extra}')


d = tempfile.mkdtemp(prefix='amezo_interop_')
# Python 実装一式
for f in os.listdir(PY):
    if f in ('.git', '__pycache__', 'tests'):
        continue
    s = os.path.join(PY, f)
    if os.path.isfile(s):
        shutil.copy(s, os.path.join(d, f))
# Nim バイナリ一式を同居させる
for f in ('amezo.cgi', 'dai.cgi', 'admin.cgi', 'jump.cgi', 'archive', 'server'):
    shutil.copy(os.path.join(NIM, f), os.path.join(d, f))
with open(os.path.join(d, 'config.ini'), 'w', encoding='utf-8') as f:
    f.write('POST_INTERVAL = 0\nGLOBAL_WINDOW = 0\n')
r = subprocess.run([sys.executable, '-c', "import amezo; print(amezo.make_hash('adminpw'))"],
                   cwd=d, capture_output=True, text=True)
with open(os.path.join(d, 'delpass.txt'), 'w', encoding='utf-8') as f:
    f.write(r.stdout.strip())
os.makedirs(os.path.join(d, 'main'), exist_ok=True)


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class Server:
    def __init__(self, cmd):
        self.port = free_port()
        self.base = f'http://127.0.0.1:{self.port}'
        self.p = subprocess.Popen(cmd + ['--port', str(self.port)], cwd=d,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(60):
            try:
                if self.req('/style.css')[0] == 200:
                    return
            except Exception:
                pass
            time.sleep(0.5)
        raise RuntimeError('server did not start: ' + ' '.join(cmd))

    def req(self, path, data=None, headers=None):
        rq = urllib.request.Request(self.base + path, data=data, headers=headers or {})
        try:
            with urllib.request.urlopen(rq, timeout=15) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()

    def post(self, path, fields):
        return self.req(path, data=urllib.parse.urlencode(fields).encode())

    def stop(self):
        self.p.terminate()
        try:
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()


def thread_files():
    return sorted(f for f in os.listdir(os.path.join(d, 'main'))
                  if re.fullmatch(r'\d+\.html', f))


# ===== フェーズ1: Python で作る =====
srv = Server([sys.executable, 'setup_expose.py', '--no-tunnel'])
srv.post('/amezo.cgi', {'folder': 'main', 'name': '名無し#pysecret', 'subj': '相互運用',
                        'comm': 'Python で立てたスレ https://example.org/x'})
files = thread_files()
chk('Py: スレッド作成', len(files) == 1, str(files))
res1 = files[0][:-5]
html = open(os.path.join(d, 'main', files[0]), encoding='utf-8').read()
m = re.search(r'<b>([^<]*◆[^<]*)</b>', html)
chk('Py: トリップが付いた', m is not None, html[html.find('<dt>'):html.find('<dt>')+200])
trip_py = m.group(1) if m else ''
srv.post('/admin.cgi', {'adminpass': 'adminpw', 'act': 'lock', 'folder': 'main', 'res': res1})
st, hd, body = srv.post('/admin.cgi', {'adminpass': 'adminpw', 'act': 'issue', 'folder': 'main',
                                       'res': res1, 'label': 'py発行', 'scope': 'thread'})
km = re.search(r'([A-Z2-7]{4}(?:-[A-Z2-7]{4}){5})', body.decode('utf-8'))
chk('Py: 鍵を発行', km is not None)
key_py = km.group(1) if km else ''
# 過去ログを Python の archive で圧縮 (2段階)
arc_src = os.path.join(d, 'main', files[0])
arc = os.path.join(d, 'main', 'o260101000000.html')
shutil.copy(arc_src, arc)
old = time.time() - 7200
os.utime(arc, (old, old))
for _ in range(2):
    subprocess.run([sys.executable, 'archive.py', 'main', '--quiet=0'],
                   cwd=d, capture_output=True, text=True)
chk('Py: archive 段階2まで完了', not os.path.exists(arc) and os.path.exists(arc + '.gz'))
srv.stop()

# ===== フェーズ2: 同じフォルダを Nim で使う =====
srv = Server(['./server', '--no-tunnel'])
st, hd, body = srv.req(f'/main/{files[0]}')
chk('Nim: Python のスレが読める', st == 200 and 'Python で立てたスレ'.encode() in body)
srv.post('/amezo.cgi', {'folder': 'main', 'name': '名無し', 'res': res1,
                        'comm': 'Nim から鍵つき返信', 'key': key_py})
html = open(os.path.join(d, 'main', files[0]), encoding='utf-8').read()
chk('Nim: Python 発行の鍵で返信できた', 'Nim から鍵つき返信' in html)
srv.post('/amezo.cgi', {'folder': 'main', 'name': '名無し#pysecret', 'subj': 'Nim新規', 'comm': 'x'})
files2 = thread_files()
chk('Nim: 新規スレが増えた', len(files2) == 2, str(files2))
newf = [f for f in files2 if f != files[0]][0]
html2 = open(os.path.join(d, 'main', newf), encoding='utf-8').read()
m2 = re.search(r'<b>([^<]*◆[^<]*)</b>', html2)
chk('Nim: トリップが Python と一致', m2 is not None and m2.group(1) == trip_py,
    f'{m2.group(1) if m2 else None} vs {trip_py}')
st, hd, body = srv.req('/main/o260101000000.html')
chk('Nim: Python の gz 過去ログが読める', st == 200 and 'Python で立てたスレ'.encode() in body)
# Nim 側で別のスレをロックして鍵発行
res2 = newf[:-5]
srv.post('/admin.cgi', {'adminpass': 'adminpw', 'act': 'lock', 'folder': 'main', 'res': res2})
chk('Nim: ロックでスレ中身が消えていない (fmReadWrite 修正の回帰確認)',
    'Nim新規' in open(os.path.join(d, 'main', newf), encoding='utf-8').read())
st, hd, body = srv.post('/admin.cgi', {'adminpass': 'adminpw', 'act': 'issue', 'folder': 'main',
                                       'res': res2, 'label': 'nim発行', 'scope': 'thread'})
km = re.search(r'([A-Z2-7]{4}(?:-[A-Z2-7]{4}){5})', body.decode('utf-8'))
chk('Nim: 鍵を発行', km is not None)
key_nim = km.group(1) if km else ''
srv.stop()

# ===== フェーズ3: Nim の成果物を Python で使う =====
srv = Server([sys.executable, 'setup_expose.py', '--no-tunnel'])
srv.post('/amezo.cgi', {'folder': 'main', 'name': '名無し', 'res': res2,
                        'comm': 'Python から Nim 鍵で返信', 'key': key_nim})
html2 = open(os.path.join(d, 'main', newf), encoding='utf-8').read()
chk('Py: Nim 発行の鍵で返信できた', 'Python から Nim 鍵で返信' in html2)
srv.stop()

shutil.rmtree(d, ignore_errors=True)
print(f'== OK {ok} / NG {ng}')
sys.exit(1 if ng else 0)
