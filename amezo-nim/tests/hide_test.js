// hide.js の確認 (Node + jsdom): localStorage に、想定外の値 (null・配列・数値・壊れた JSON など) が入っていても、
// 例外を出さず、ボタンの文字が出て、隠す操作が効き、保存される。
//   使い方: npm i jsdom && node tests/hide_test.js [hide.js のパス]
const {JSDOM} = require('jsdom'); const fs = require('fs'); const path = require('path');
const file = process.argv[2] || path.join(__dirname, '..', 'hide.js');
const code = fs.readFileSync(file, 'utf8');
const post = (n, id, trip) => `<dl><dt>${n}投稿者：<font color=forestgreen><b>n${n} </b></font><font size=-1 class="meta" data-id="${id}"${trip ? ` data-trip="${trip}"` : ''}>　投稿日：d ID:${id}</font><br><dd>c${n} </dl>`;
const HTML = `<html><body>${post(1, 'idA1', 'tripX')}${post(2, 'idB2', '')}${post(3, 'idA1', 'tripX')}</body></html>`;   // idA1 と tripX は、1番と3番が同じ
const now = Date.now(), DAY = 864e5;
let bad = 0, n = 0;
function ok(label, cond, extra = '') { n++; if (!cond) bad++; console.log((cond ? 'OK   ' : 'NG   ') + label + (extra ? '  ' + extra : '')); }

function run(stored, {before} = {}) {
  const dom = new JSDOM(HTML, {runScripts: 'outside-only', url: 'http://localhost/'});
  const w = dom.window, errs = [];
  w.addEventListener('error', e => errs.push(e.message));
  if (before) before(w);
  if (stored !== undefined && !before) w.localStorage.setItem('bbs_hide', stored);
  try { w.eval(code); } catch (e) { errs.push(String(e.message)); }
  const d = w.document;
  const btns = [...d.querySelectorAll('a[data-hide]')];
  const r = {errs, buttons: btns.length, labeled: btns.length > 0 && btns.every(a => a.textContent.length > 0), hiddenAtLoad: d.querySelectorAll('dl.abone').length};
  const first = d.querySelector('a[data-hide^="id:"]');
  if (first) first.dispatchEvent(new w.MouseEvent('click', {bubbles: true, cancelable: true}));
  r.errs = errs; r.hiddenAfterClick = d.querySelectorAll('dl.abone').length;
  try { r.saved = JSON.parse(w.localStorage.getItem('bbs_hide')); } catch { r.saved = undefined; }
  r.w = w; return r;
}
const isObj = o => o !== null && typeof o === 'object' && !Array.isArray(o);

// --- 壊れた・想定外の値: 例外なし / 文字が出る / 隠せる / 保存される (保存された値は、正しい形のオブジェクト) ---
const weird = [['(未設定)', undefined], ['"null" (setItem(k, null))', 'null'], ['"[]"', '[]'], ['"[1,2]"', '[1,2]'], ['"123"', '123'], ['"\\"str\\""', '"str"'],
               ['"true"', 'true'], ['"false"', 'false'], ['"{}"', '{}'], ['"{bad" (壊れた JSON)', '{bad'], ['"" (空文字)', ''], ['"undefined"', 'undefined'], ['"NaN"', 'NaN'],
               ['{"id:idA1":"x"} (時刻が文字列)', '{"id:idA1":"x"}'], ['{"id:idA1":null}', '{"id:idA1":null}'], ['{"id:idA1":-5}', '{"id:idA1":-5}'],
               ['{"id:idA1":{}} (時刻がオブジェクト)', '{"id:idA1":{}}'], ['{"foo":1} (知らないキー)', '{"foo":1}']];
for (const [label, v] of weird) {
  const r = run(v);
  ok(`${label}: 例外なし・文字が出る・隠せる・正しい形で保存`, r.errs.length === 0 && r.labeled && r.hiddenAtLoad === 0 && r.hiddenAfterClick >= 1 && isObj(r.saved) && typeof r.saved['id:idA1'] === 'number',
     r.errs[0] ? r.errs[0].slice(0, 50) : `読込時の隠れ ${r.hiddenAtLoad}, クリック後 ${r.hiddenAfterClick}, 保存 ${JSON.stringify(r.saved)}`);
}
// --- 正しい値: 従来どおり ---
let r = run(JSON.stringify({'id:idA1': now}));
ok('正しい: ID を隠していた → 読み込み時に隠れている (同じ ID の2件)。ボタンで解除できる', r.hiddenAtLoad === 2 && r.hiddenAfterClick === 0 && r.errs.length === 0 && !('id:idA1' in r.saved));
r = run(JSON.stringify({'trip:tripX': now}));
ok('正しい: トリップを隠していた → 読み込み時に隠れている (同じトリップの2件)', r.hiddenAtLoad === 2 && r.errs.length === 0);
r = run(JSON.stringify({'id:idA1': now - 4 * DAY}));
ok('ID は3日たつと捨てる', r.hiddenAtLoad === 0 && r.errs.length === 0);
r = run(JSON.stringify({'trip:tripX': now - 400 * DAY}));
ok('トリップは期限なし (400日前でも残る)', r.hiddenAtLoad === 2);
r = run(JSON.stringify({'id:idA1': now - 4 * DAY, 'trip:tripX': now - 400 * DAY}));
ok('期限切れの ID は捨て、トリップは残る (ID で隠すと保存し直され、トリップはそのまま保存される)', r.hiddenAtLoad === 2 && r.saved && 'trip:tripX' in r.saved && typeof r.saved['id:idA1'] === 'number' && r.saved['id:idA1'] > now - DAY);
// --- 変なキー・巨大な値 ---
r = run('{"__proto__":{"polluted":1},"id:idA1":' + now + '}');
ok('__proto__ を含む値でも、Object.prototype を汚さない', ({}).polluted === undefined && r.errs.length === 0 && r.hiddenAtLoad === 2, String(({}).polluted));
r = run(JSON.stringify({'constructor': now, 'toString': now, 'id:': now, 'hasOwnProperty': now}));
const own = k => Object.prototype.hasOwnProperty.call(r.saved || {}, k);
ok('constructor / toString / hasOwnProperty などのキーは捨てる (自分で持つキーとして保存しない)', r.errs.length === 0 && r.hiddenAtLoad === 0 && !own('constructor') && !own('toString') && !own('hasOwnProperty'));
const big = {}; for (let i = 0; i < 6000; i++) big['id:k' + i] = now;
const t0 = Date.now(); r = run(JSON.stringify(big));
ok('6000件の巨大な値でも、上限 (5000件) で止まり、重くならない', r.errs.length === 0 && Object.keys(r.saved || {}).length <= 5001 && Date.now() - t0 < 3000, `保存 ${Object.keys(r.saved || {}).length}件, ${Date.now() - t0}ms`);
// --- localStorage 自体が使えない (ブラウザの設定・プライベートモードなど) ---
r = run(undefined, {before: w => Object.defineProperty(w, 'localStorage', {get() { throw new w.Error('SecurityError'); }})});
ok('localStorage に触るだけで例外 (使えない設定): 例外なし・文字が出る・その場では隠せる', r.errs.length === 0 && r.labeled && r.hiddenAfterClick >= 1, r.errs[0] || '');
r = run(undefined, {before: w => { w.Storage.prototype.setItem = function () { throw new w.Error('QuotaExceededError'); }; }});
ok('保存だけが失敗 (容量いっぱい): 例外なし・その場では隠せる', r.errs.length === 0 && r.labeled && r.hiddenAfterClick >= 1, r.errs[0] || '');
console.log(`\n${n} 項目, NG ${bad} 件 (${path.basename(path.dirname(file))}/${path.basename(file)})`); process.exit(bad ? 1 : 0);
