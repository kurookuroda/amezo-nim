# -*- coding: utf-8 -*-
# archive バイナリ (過去ログの gzip 圧縮) のテスト (Python 版 tests/archive_test.py 相当)。
# 一時フォルダにコピーして実行する。実行: python3 tests/archive_test.py
import gzip
import os
import shutil
import subprocess
import sys
import time

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


d = tempfile_dir = None
import tempfile  # noqa: E402
d = tempfile.mkdtemp(prefix='amezo_arch_')
shutil.copy(os.path.join(ROOT, 'archive'), os.path.join(d, 'archive'))
os.makedirs(os.path.join(d, 'main'))
with open(os.path.join(d, 'blist.txt'), 'w', encoding='utf-8') as f:
    f.write('main,#ddeedd,広場\n')

BODY = ('<html><head><title>題名 </title></head><body><dl><dt>1 投稿者：<b>名無し </b><br>'
        '<dd>本文です。圧縮テスト。 </dl>\n</body></html>\n')
plain = os.path.join(d, 'main', 'o260101000000.html')
gz = plain + '.gz'
with open(plain, 'w', encoding='utf-8') as f:
    f.write(BODY)
old = time.time() - 7200
os.utime(plain, (old, old))


def run(*args):
    return subprocess.run(['./archive', *args], cwd=d, capture_output=True, text=True)


r = run('--selftest', 'main')
chk('selftest が通る', r.returncode == 0 and 'NG' not in r.stdout, r.stdout[-200:])

r = run('main', '--quiet=0', '--dry-run')
chk('dry-run は何も書かない', r.returncode == 0 and not os.path.exists(gz))

r = run('main', '--quiet=0')
chk('段階1: gz ができ、平文は残る', r.returncode == 0 and os.path.exists(gz) and os.path.exists(plain), r.stdout)
chk('段階1: gz の中身が一致', gzip.open(gz, 'rt', encoding='utf-8').read() == BODY)
chk('段階1: gz の更新日時は平文と同じ', int(os.path.getmtime(gz)) == int(old))

r = run('main', '--quiet=0')
chk('段階2: 平文が消えて gz だけ残る', r.returncode == 0 and not os.path.exists(plain) and os.path.exists(gz), r.stdout)

r = run('--restore', 'main', 'o260101000000')
chk('restore: 平文が戻る', r.returncode == 0 and os.path.exists(plain)
    and open(plain, encoding='utf-8').read() == BODY and os.path.exists(gz), r.stdout + r.stderr)
r = run('--restore', 'main', 'o260101000000')
chk('restore: すでにある場合は上書きしない (exit 2)', r.returncode == 2, str(r.returncode))

# 壊れた gz: 中身が平文と違うと .bad に退避して NG (exit 1)、平文は消さない
os.unlink(gz)
with gzip.open(gz, 'wb') as f:
    f.write('ぜんぜん違う中身'.encode())
os.utime(gz, (old, old))
os.utime(plain, (old, old))
r = run('main', '--quiet=0')
chk('壊れた gz は .bad に退避し exit 1', r.returncode == 1 and os.path.exists(gz + '.bad') and os.path.exists(plain),
    f'{r.returncode} {r.stdout}')

r = run('main', '--quiet=999999999')
chk('範囲外の --quiet は exit 2', r.returncode == 2, str(r.returncode))
r = run('nosuchboard', '--quiet=0')
chk('無い板は exit 2', r.returncode == 2, str(r.returncode))

shutil.rmtree(d, ignore_errors=True)
print(f'== OK {ok} / NG {ng}')
sys.exit(1 if ng else 0)
