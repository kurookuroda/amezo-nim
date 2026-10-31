// hide.js - ID / トリップの非表示 (ブラウザの localStorage だけで動く。サーバーは何もしない)
(() => {
  const K = 'bbs_hide', TTL = 3 * 864e5, now = Date.now();
  // 保存されているのは {"id:…": 時刻, "trip:…": 時刻} というオブジェクトだけ。それ以外 (null・配列・数値・文字列・true・壊れた JSON、
  // 他のスクリプトや古い版が書いた値) が入っていても、捨てて空から始める。JSON.parse('null') は null を返すので、
  // そのまま H に入れると H['id:…'] で例外になり、全体が動かなくなる。配列や数値だと、エラーは出ないまま、隠せず・保存もされない。
  let H = {};
  try {
    const o = JSON.parse(localStorage.getItem(K) || '{}');
    if (o !== null && typeof o === 'object' && !Array.isArray(o)) {
      for (const k of Object.keys(o).slice(0, 5000)) {                       // 件数の上限 (巨大な値で重くならないように)
        const t = o[k];
        if (!/^(id|trip):/.test(k) || typeof t !== 'number' || !Number.isFinite(t) || t <= 0) continue;   // __proto__ などの変なキー・時刻でない値は捨てる
        if (k.startsWith('id:') && now - t > TTL) continue;                  // ID は日替わりなので3日で捨てる
        H[k] = t;
      }
    }
  } catch { H = {}; }
  const save = () => { try { localStorage.setItem(K, JSON.stringify(H)); } catch {} };

  const metas = [...document.querySelectorAll('.meta[data-id]')];
  for (const m of metas) {
    const s = document.createElement('span');
    s.className = 'hidebtns';
    for (const [label, key] of [['ID', 'id:' + m.dataset.id], ['トリップ', m.dataset.trip && 'trip:' + m.dataset.trip]]) {
      if (!key) continue;
      const a = document.createElement('a');
      a.href = '#'; a.dataset.hide = key; a.dataset.label = label;
      s.append(' ', a);
    }
    m.after(s);
  }

  function apply() {
    for (const m of metas) {
      const dl = m.closest('dl');
      if (dl) dl.classList.toggle('abone', !!(H['id:' + m.dataset.id] || (m.dataset.trip && H['trip:' + m.dataset.trip])));
    }
    document.querySelectorAll('a[data-hide]').forEach(a => {
      a.textContent = '[' + a.dataset.label + (H[a.dataset.hide] ? '解除' : '非表示') + ']';
    });
  }

  document.addEventListener('click', e => {
    const a = e.target.closest('a[data-hide]');
    if (!a) return;
    e.preventDefault();
    const k = a.dataset.hide;
    if (H[k]) delete H[k]; else H[k] = Date.now();
    save(); apply();
  });
  apply();
})();
