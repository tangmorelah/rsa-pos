/* RSA - POS Assistant — core: API client, session, router, shared UI helpers */
(function () {
  'use strict';
  const RSA = (window.RSA = { screens: {}, state: { token: null, boot: null } });

  // ------------------------------------------------------------ storage (per device convenience only)
  const store = {
    get(k) { try { return localStorage.getItem('rsa.' + k); } catch (e) { return null; } },
    set(k, v) { try { v == null ? localStorage.removeItem('rsa.' + k) : localStorage.setItem('rsa.' + k, v); } catch (e) { /* private mode */ } },
    json(k, dflt) { try { const v = this.get(k); return v ? JSON.parse(v) : dflt; } catch (e) { return dflt; } },
  };
  RSA.store = store;

  // Connection settings: config.js on the server wins; otherwise what this device saved from the setup screen or a shared link.
  const fileCfg = window.RSA_CONFIG || {};
  let CFG = fileCfg.supabaseUrl && fileCfg.anonKey && !/YOUR-/.test(fileCfg.supabaseUrl) ? fileCfg : store.json('cfg', {});
  RSA.cfgFromFile = () => CFG === fileCfg;
  RSA.cfg = () => CFG;
  RSA.setCfg = (c) => { CFG = { supabaseUrl: c.supabaseUrl.trim().replace(/\/$/, ''), anonKey: c.anonKey.trim() }; store.set('cfg', JSON.stringify(CFG)); };
  const b64 = { enc: (o) => btoa(unescape(encodeURIComponent(JSON.stringify(o)))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''),
    dec: (t) => JSON.parse(decodeURIComponent(escape(atob(t.replace(/-/g, '+').replace(/_/g, '/'))))) };
  // Link that opens the app on a phone already connected to this shop (the anon key is public by design).
  RSA.shareLink = () => location.origin + location.pathname + (RSA.cfgFromFile() ? '' : '#cfg=' + b64.enc({ u: CFG.supabaseUrl, k: CFG.anonKey }));

  // ------------------------------------------------------------ API
  async function rpc(fn, args) {
    if (window.RSA_MOCK) {   // demo build: an in-browser stand-in for the database
      const j = await window.RSA_MOCK(fn, args || {});
      if (j && typeof j === 'object' && !Array.isArray(j) && j.error) throw new Error(j.error);
      return j;
    }
    let r;
    try {
      r = await fetch(CFG.supabaseUrl.replace(/\/$/, '') + '/rest/v1/rpc/' + fn, {
        method: 'POST',
        // a legacy anon key is a JWT and also goes in Authorization; a new publishable key (sb_publishable_…) is not a JWT and is sent as apikey only
        headers: { 'Content-Type': 'application/json', apikey: CFG.anonKey, ...(/^sb_/.test(CFG.anonKey) ? {} : { Authorization: 'Bearer ' + CFG.anonKey }) },
        body: JSON.stringify(args || {}),
      });
    } catch (e) {
      const err = new Error('เชื่อมต่ออินเทอร์เน็ตไม่ได้ ตรวจสัญญาณแล้วลองอีกครั้ง');
      err.offline = true;
      throw err;
    }
    const j = await r.json().catch(() => null);
    if (!r.ok) {
      const err = new Error((j && j.message) || 'ระบบตอบกลับผิดพลาด (' + r.status + ')');
      err.auth = j && j.hint === 'auth';
      throw err;
    }
    if (j && typeof j === 'object' && !Array.isArray(j) && j.error) throw new Error(j.error);
    return j;
  }
  RSA.rpc = rpc;
  RSA.api = async function (action, payload) {
    try {
      return await rpc('rsa_api', { p_token: RSA.state.token, p_action: action, p_payload: payload || {} });
    } catch (e) {
      if (e.auth) { RSA.logout(true); }
      throw e;
    }
  };

  // ------------------------------------------------------------ orders saved while offline
  // Each queued order keeps its client_ref, so sending it twice still creates one order on the server.
  const queue = { list: () => store.json('queue', []), save: (q) => store.set('queue', JSON.stringify(q)) };
  RSA.queueCount = () => queue.list().length;
  RSA.saveOrder = async function (payload) {
    try {
      return await RSA.api('order.create', payload);
    } catch (e) {
      if (!e.offline) throw e;
      const q = queue.list();
      q.push({ payload: { ...payload, offline_at: new Date().toISOString() }, user: RSA.state.boot.me.id });
      queue.save(q); paintNet();
      return null;
    }
  };
  let flushing = false;
  RSA.flushQueue = async function () {
    if (flushing || !RSA.state.token) return;
    const q = queue.list();
    if (!q.length) return paintNet();
    flushing = true;
    let sent = 0;
    try {
      while (queue.list().length) {
        const item = queue.list()[0];
        try { await RSA.api('order.create', item.payload); sent++; }
        catch (e) {
          if (e.offline || e.auth) break;
          // the server refused it (e.g. product switched off): keep it visible instead of dropping a sale
          item.error = e.message; const rest = queue.list().slice(1); rest.push(item); queue.save(rest);
          if (rest.every((x) => x.error)) break;
          continue;
        }
        queue.save(queue.list().slice(1));
      }
    } finally { flushing = false; paintNet(); }
    if (sent) RSA.toast('ส่งออเดอร์ที่บันทึกตอนไม่มีสัญญาณแล้ว ' + sent + ' รายการ');
  };
  function paintNet() {
    let bar = document.getElementById('net-bar');
    const n = queue.list().length, off = !navigator.onLine;
    if (!off && !n) { if (bar) bar.remove(); return; }
    if (!bar) { bar = document.createElement('div'); bar.id = 'net-bar'; document.body.prepend(bar); }
    const bad = queue.list().filter((x) => x.error).length;
    bar.innerHTML = (off ? 'ไม่มีสัญญาณอินเทอร์เน็ต ขายต่อได้ ระบบเก็บออเดอร์ไว้ในเครื่อง' : 'กำลังส่งออเดอร์ที่ค้างอยู่')
      + (n ? ` · ค้างส่ง ${n} ออเดอร์` : '') + (bad ? ` · ส่งไม่ผ่าน ${bad} (แจ้งเจ้าของร้าน)` : '');
  }
  RSA.paintNet = paintNet;
  window.addEventListener('online', () => { paintNet(); RSA.flushQueue(); });
  window.addEventListener('offline', paintNet);
  setInterval(() => { if (navigator.onLine) RSA.flushQueue(); }, 30000);

  // ------------------------------------------------------------ utils
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const num = (v) => (v == null || v === '' ? 0 : Number(v));
  const money = (v) => num(v).toLocaleString('th-TH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const qty = (v) => num(v).toLocaleString('th-TH', { maximumFractionDigits: 3 });
  const dfmt = new Intl.DateTimeFormat('th-TH', { day: 'numeric', month: 'short', year: 'numeric' });
  const dtfmt = new Intl.DateTimeFormat('th-TH', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  const tfmt = new Intl.DateTimeFormat('th-TH', { hour: '2-digit', minute: '2-digit' });
  const date = (s) => (s ? dfmt.format(new Date(String(s).length === 10 ? s + 'T12:00:00' : s)) : '-');
  const dt = (s) => (s ? dtfmt.format(new Date(s)) : '-');
  const time = (s) => (s ? tfmt.format(new Date(s)) : '-');
  const today = () => (RSA.state.boot && RSA.state.boot.today) || new Date().toISOString().slice(0, 10);
  const addDays = (iso, n) => { const d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  const nowLocal = () => { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };
  const toLocal = (iso) => { if (!iso) return ''; const d = new Date(iso); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };
  const toIso = (local) => (local ? new Date(local).toISOString() : null);
  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : 'r' + Date.now() + Math.random().toString(16).slice(2));
  const can = (perm) => !!(RSA.state.boot && RSA.state.boot.me.perms.includes(perm));
  Object.assign(RSA, { esc, num, money, qty, date, dt, time, today, addDays, nowLocal, toLocal, toIso, uid, can });

  // ------------------------------------------------------------ icons (stroke, 24px grid)
  const P = {
    cart: 'M3 4h2l2.4 11.2a2 2 0 0 0 2 1.6h7.7a2 2 0 0 0 2-1.6L21 8H6.2M10 21h.01M17 21h.01',
    list: 'M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01',
    box: 'M21 8l-9-5-9 5 9 5 9-5zM3 8v8l9 5 9-5V8M12 13v8',
    trash: 'M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3',
    receipt: 'M6 3h12v18l-3-2-3 2-3-2-3 2V3zM9 8h6M9 12h6M9 16h3',
    moon: 'M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z',
    calendar: 'M4 6h16v14H4zM4 10h16M9 3v4M15 3v4',
    chart: 'M4 20V10M10 20V4M16 20v-7M22 20H2',
    wallet: 'M3 7h16a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7zm0 0V6a2 2 0 0 1 2-2h11M16 13h.01',
    flow: 'M4 7h12l-3-3M20 17H8l3 3',
    users: 'M16 20v-1a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v1M9.5 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM21 20v-1a4 4 0 0 0-3-3.8M16 4.2a3.5 3.5 0 0 1 0 6.6',
    shield: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3z',
    gear: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
    tag: 'M20.6 13.4l-7.2 7.2a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8zM7.5 7.5h.01',
    download: 'M12 3v12M7 10l5 5 5-5M5 21h14',
    home: 'M3 11l9-8 9 8M5 10v10h14V10',
    out: 'M15 4h4v16h-4M10 17l5-5-5-5M15 12H3',
    check: 'M5 12l5 5L20 7',
    plus: 'M12 5v14M5 12h14',
    camera: 'M4 7h3l2-3h6l2 3h3v13H4zM12 17a4 4 0 1 0 0-8 4 4 0 0 0 0 8z',
    clip: 'M21 11l-8.5 8.5a5 5 0 0 1-7-7L14 4a3.5 3.5 0 0 1 5 5l-8.5 8.5a2 2 0 0 1-3-3L15 7',
    back: 'M15 18l-6-6 6-6',
    lock: 'M6 11h12v10H6zM8 11V7a4 4 0 0 1 8 0v4',
    eye: 'M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
  };
  RSA.icon = (n) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${P[n] || P.list}"/></svg>`;

  // ------------------------------------------------------------ toast, modal
  RSA.toast = function (msg, isErr) {
    const t = document.createElement('div');
    t.className = 'toast' + (isErr ? ' err' : '');
    t.textContent = msg;
    document.getElementById('toast-root').appendChild(t);
    setTimeout(() => t.remove(), isErr ? 6000 : 3500);
  };
  RSA.fail = (e) => RSA.toast(e && e.message ? e.message : String(e), true);
  // anything that breaks on a phone shows up on screen instead of failing silently
  window.addEventListener('error', (ev) => { if (ev.message && !/ResizeObserver|Script error/.test(ev.message)) RSA.toast('เกิดข้อผิดพลาดในเครื่อง: ' + ev.message, true); });
  window.addEventListener('unhandledrejection', (ev) => { const m = ev.reason && ev.reason.message; if (m) RSA.toast(m, true); });

  RSA.modal = function (title, bodyHtml, opts) {
    opts = opts || {};
    const root = document.getElementById('modal-root');
    const back = document.createElement('div');
    back.className = 'modal-back';
    back.innerHTML = `<div class="modal ${opts.wide ? 'wide' : ''}" role="dialog" aria-modal="true" aria-label="${esc(title)}">
      <header><h2>${esc(title)}</h2><button class="icon-btn" data-close aria-label="ปิด"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg></button></header>
      <div class="m-body">${bodyHtml}</div></div>`;
    root.appendChild(back);
    const close = () => { back.remove(); document.removeEventListener('keydown', onKey); };
    const onKey = (ev) => { if (ev.key === 'Escape') close(); };
    document.addEventListener('keydown', onKey);
    back.addEventListener('click', (ev) => { if (ev.target === back || ev.target.closest('[data-close]')) close(); });
    const el = back.querySelector('.m-body');
    const first = el.querySelector('input, select, textarea, button');
    if (first) setTimeout(() => first.focus(), 30);
    return { el, close };
  };

  // Ask for a reason (and optional amount) before a cancel/refund/correction. Resolves {reason, amount} or null.
  RSA.askReason = function (title, opts) {
    opts = opts || {};
    return new Promise((resolve) => {
      const m = RSA.modal(title, `<form class="form">
        ${opts.text ? `<p class="muted">${esc(opts.text)}</p>` : ''}
        ${opts.amount != null ? `<label class="field"><span class="req">จำนวนเงิน (บาท)</span><input id="ar-amt" type="number" step="0.01" min="0.01" value="${esc(opts.amount)}" required></label>` : ''}
        <label class="field"><span class="req">${esc(opts.label || 'เหตุผล')}</span><textarea id="ar-reason" required></textarea></label>
        <div class="btn-row"><button class="btn" type="button" data-close>กลับ</button><button class="btn lg ${opts.danger ? 'danger' : 'primary'}" type="submit">${esc(opts.ok || 'ยืนยัน')}</button></div></form>`);
      let done = false;
      m.el.querySelector('form').addEventListener('submit', (ev) => {
        ev.preventDefault();
        const reason = m.el.querySelector('#ar-reason').value.trim();
        if (!reason) return;
        done = true;
        resolve({ reason, amount: opts.amount != null ? Number(m.el.querySelector('#ar-amt').value) : undefined });
        m.close();
      });
      const obs = new MutationObserver(() => { if (!document.body.contains(m.el)) { obs.disconnect(); if (!done) resolve(null); } });
      obs.observe(document.getElementById('modal-root'), { childList: true });
    });
  };

  // Owner / admin: remove an already-cancelled entry for good (data.purge). Asks for a reason and the word ลบ.
  RSA.canPurge = () => ['owner', 'admin'].includes((RSA.state.boot && RSA.state.boot.me.role) || '');
  RSA.purgeBtn = (show) => (show && RSA.canPurge() ? '<button type="button" class="btn danger" data-purge>ลบถาวร</button>' : '');
  RSA.purge = function (root, type, id, label, done) {
    const b = root.querySelector('[data-purge]'); if (!b) return;
    b.addEventListener('click', () => {
      const m = RSA.modal('ลบถาวร', `<form class="form">
        <p class="muted">${esc(label)} จะหายจากทุกหน้าและรายงาน ยอดเงินและสต็อกไม่เปลี่ยน เพราะยกเลิกไปแล้ว ระบบเก็บสำเนาไว้ในประวัติระบบ</p>
        <label class="field"><span class="req">เหตุผลที่ลบ</span><textarea id="pg-reason" required placeholder="เช่น ลงทดสอบ / ลงซ้ำ"></textarea></label>
        <label class="field"><span class="req">พิมพ์คำว่า ลบ เพื่อยืนยัน</span><input id="pg-word" type="text" autocomplete="off" required></label>
        <div class="btn-row"><button class="btn" type="button" data-close>กลับ</button><button class="btn lg danger" type="submit">ลบถาวร</button></div></form>`);
      m.el.querySelector('form').addEventListener('submit', (ev) => {
        ev.preventDefault();
        const reason = m.el.querySelector('#pg-reason').value.trim();
        if (!reason) return;
        if (m.el.querySelector('#pg-word').value.trim() !== 'ลบ') { RSA.toast('พิมพ์คำว่า ลบ ให้ถูกต้อง'); return; }
        RSA.busy(ev.submitter, async () => { await RSA.api('data.purge', { type, id, reason }); m.close(); RSA.toast('ลบถาวรแล้ว'); done(); });
      });
    });
  };

  // Run an async action from a button, disabling it meanwhile.
  RSA.busy = async function (btn, fn) {
    if (btn) {
      // a stuck button (e.g. the app was paused mid-save) unlocks itself after 20 s
      if (btn.disabled && Date.now() - (btn._busyAt || 0) < 20000) { RSA.toast('กำลังบันทึก รอสักครู่'); return; }
      btn.disabled = true; btn._busyAt = Date.now();
    }
    try { return await fn(); } catch (e) { RSA.fail(e); } finally { if (btn) btn.disabled = false; }
  };

  RSA.val = (root, sel) => { const e = root.querySelector(sel); return e ? (e.type === 'checkbox' ? e.checked : e.value.trim()) : null; };
  RSA.opts = (list, sel, label, valueKey) => (list || []).map((x) => {
    const v = valueKey ? x[valueKey] : x.id;
    return `<option value="${esc(v)}" ${String(v) === String(sel) ? 'selected' : ''}>${esc(typeof label === 'function' ? label(x) : x[label || 'name'])}</option>`;
  }).join('');
  RSA.lookup = (list, id, key) => { const x = (list || []).find((y) => y.id === id); return x ? x[key || 'name'] : ''; };

  RSA.statusPill = function (s) {
    const map = { 'รออนุมัติ': 'warn', 'รอทำจ่าย': 'blue', 'จ่ายแล้ว': 'ok', 'ยกเลิก': 'bad', paid: 'ok', cancelled: 'bad', refunded: 'warn', partial_refund: 'warn',
      received: 'ok', pending: 'warn', approved: 'ok', rejected: 'bad', done: 'ok', recorded: 'ok', ok: 'ok', low: 'warn', out: 'bad' };
    const th = { paid: 'ชำระแล้ว', cancelled: 'ยกเลิก', refunded: 'คืนเงินแล้ว', partial_refund: 'คืนเงินบางส่วน', received: 'รับแล้ว', pending: 'รออนุมัติ',
      approved: 'อนุมัติแล้ว', rejected: 'ไม่อนุมัติ', done: 'บันทึกแล้ว', recorded: 'บันทึกแล้ว', ok: 'ปกติ', low: 'ใกล้หมด', out: 'หมด' };
    return `<span class="pill ${map[s] || ''}">${esc(th[s] || s)}</span>`;
  };

  // ------------------------------------------------------------ attachments
  function readFile(file) { return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = rej; r.readAsDataURL(file); }); }
  async function compressImage(file) {
    const url = await readFile(file);
    const img = await new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = url; });
    const max = 1600, scale = Math.min(1, max / Math.max(img.width, img.height));
    const c = document.createElement('canvas');
    c.width = Math.round(img.width * scale); c.height = Math.round(img.height * scale);
    c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
    return { dataUrl: c.toDataURL('image/jpeg', 0.78), mime: 'image/jpeg', canvas: c };
  }
  // Upload one file; returns {id, filename, dataUrl}
  RSA.uploadFile = async function (file, docKind) {
    let dataUrl, mime;
    if (file.type === 'application/pdf') { dataUrl = await readFile(file); mime = 'application/pdf'; }
    else if (/^image\//.test(file.type)) { const c = await compressImage(file); dataUrl = c.dataUrl; mime = c.mime; }
    else throw new Error('รองรับเฉพาะรูปภาพหรือ PDF');
    const r = await RSA.api('attachment.upload', { filename: file.name || 'photo.jpg', mime, data_b64: dataUrl.split(',')[1], doc_kind: docKind || null });
    return { id: r.id, filename: file.name || 'photo.jpg', dataUrl, mime };
  };
  // A small attach widget. Returns {html, bind(root), ids()}
  RSA.attachWidget = function (key, docKinds, label) {
    const files = [];
    const kinds = docKinds || [['receipt', 'ใบเสร็จ'], ['tax_invoice', 'ใบกำกับภาษี'], ['bill', 'บิล/ใบส่งของ'], ['slip', 'สลิปโอน'], ['substitute', 'ใบรับรองแทนใบเสร็จ'], ['photo', 'รูปถ่าย']];
    return {
      files,
      html: `<div class="field" id="aw-${key}"><span>${esc(label || 'รูปหลักฐาน')}</span>
        ${kinds.length > 1 ? `<select id="aw-${key}-kind" aria-label="ชนิดหลักฐาน">${kinds.map((k) => `<option value="${k[0]}">${k[1]}</option>`).join('')}</select>` : `<input type="hidden" id="aw-${key}-kind" value="${kinds[0][0]}">`}
        <label class="photo-btn">${RSA.icon('camera')} ถ่ายรูป / เลือกไฟล์<input type="file" accept="image/*,application/pdf" capture="environment" hidden id="aw-${key}-file"></label>
        <div class="thumbs" id="aw-${key}-list"></div></div>`,
      bind(root, onAdd) {
        const input = root.querySelector(`#aw-${key}-file`);
        input.addEventListener('change', async () => {
          const f = input.files[0]; if (!f) return;
          const list = root.querySelector(`#aw-${key}-list`);
          const tag = document.createElement('span'); tag.className = 'thumb'; tag.textContent = 'กำลังอัปโหลด…'; list.appendChild(tag);
          try {
            const up = await RSA.uploadFile(f, root.querySelector(`#aw-${key}-kind`).value);
            files.push(up); tag.textContent = '✓ แนบแล้ว ' + up.filename;
            if (onAdd) onAdd(up, f);
          } catch (e) { tag.remove(); RSA.fail(e); }
          input.value = '';
        });
      },
      ids: () => files.map((f) => f.id),
    };
  };
  RSA.attachLinks = (list) => (list && list.length ? `<span class="thumbs">${list.map((a) => `<button type="button" class="thumb" data-att="${a.id}">${RSA.icon('clip')} ${esc(a.filename)}</button>`).join('')}</span>` : '');
  document.addEventListener('click', async (ev) => {
    const b = ev.target.closest('[data-att]');
    if (!b) return;
    try {
      const a = await RSA.api('attachment.get', { id: b.dataset.att });
      const src = 'data:' + a.mime + ';base64,' + a.data_b64;
      if (a.mime === 'application/pdf') {
        const bin = atob(a.data_b64), arr = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
        const url = URL.createObjectURL(new Blob([arr], { type: 'application/pdf' }));
        RSA.modal(a.filename, `<a class="btn primary lg" href="${url}" target="_blank" rel="noopener">เปิดไฟล์ PDF</a>`);
      } else {
        RSA.modal(a.filename, `<img class="preview-img" src="${src}" alt="${esc(a.filename)}">`);
      }
    } catch (e) { RSA.fail(e); }
  });

  // ------------------------------------------------------------ CSV download (UTF-8 with BOM so Excel reads Thai)
  RSA.downloadCsv = function (filename, rows) {
    if (!rows.length) { RSA.toast('ไม่มีข้อมูลในช่วงที่เลือก'); return; }
    const cols = [...rows.reduce((s, r) => { Object.keys(r).forEach((k) => s.add(k)); return s; }, new Set())];
    const cell = (v) => { if (v == null) return ''; if (typeof v === 'object') v = JSON.stringify(v); v = String(v); return /[",\n\r]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; };
    const csv = '﻿' + [cols.join(','), ...rows.map((r) => cols.map((c) => cell(r[c])).join(','))].join('\r\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
    a.download = filename; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
  };

  // ------------------------------------------------------------ permissions catalogue (labels for Admin)
  RSA.PERMS = [
    ['การขาย', [['sales.view', 'ดูรายการขายของตัวเอง'], ['sales.view_all', 'ดูรายการขายทั้งหมด'], ['sales.add', 'บันทึกออเดอร์'], ['sales.cancel', 'ยกเลิก / คืนเงินออเดอร์']]],
    ['ปิดยอด', [['closing.add', 'บันทึกรายงานปิดยอด'], ['closing.view_all', 'ดูรายงานปิดยอดทุกคน'], ['closing.edit', 'แก้ไขรายงานปิดยอด']]],
    ['สต็อก', [['stock.view', 'ดูสต็อก'], ['stock.receive', 'รับของเข้า'], ['stock.count', 'นับสต็อก'], ['stock.approve', 'อนุมัติผลนับสต็อก'], ['stock.cancel', 'ยกเลิกใบรับของ / ของเสีย'], ['waste.add', 'บันทึกของเสีย']]],
    ['ค่าใช้จ่าย', [['expense.add', 'บันทึกค่าใช้จ่าย'], ['expense.view_all', 'ดูค่าใช้จ่ายทั้งหมด'], ['expense.approve', 'อนุมัติค่าใช้จ่าย'], ['expense.pay', 'ทำจ่าย'], ['expense.cancel', 'ยกเลิกค่าใช้จ่าย']]],
    ['การเงิน', [['cashflow.view', 'ดูกระแสเงินสด'], ['cashflow.manage', 'บันทึกโอน / รับเงิน Delivery / ทุน / ประกาศใช้กำไร'], ['report.view', 'ดูภาพรวมและรายงาน'], ['export.run', 'ส่งออกข้อมูลบัญชีและภาษี']]],
    ['ระบบ', [['master.manage', 'จัดการข้อมูลหลัก (สินค้า สูตร โปรโมชัน ฯลฯ)'], ['settings.manage', 'ตั้งค่าร้าน'], ['audit.view', 'ดูประวัติการใช้งาน'], ['admin.users', 'จัดการผู้ใช้ สิทธิ์ และ PIN']]],
  ];
  const ALL = RSA.PERMS.flatMap((g) => g[1].map((p) => p[0]));
  RSA.ROLE_PERMS = {
    staff: ['sales.view', 'sales.add', 'closing.add', 'stock.view', 'stock.receive', 'stock.count', 'waste.add', 'expense.add'],
    owner: ALL.filter((p) => p !== 'admin.users'),
    admin: ['admin.users', 'audit.view'],
  };
  RSA.ROLE_LABEL = { staff: 'พนักงาน (Staff)', owner: 'เจ้าของร้าน (Owner)', admin: 'ผู้ดูแลระบบ (Admin)' };

  // ------------------------------------------------------------ shared building blocks (mobile app style)
  const COLORS = ['#1c68cf', '#0f8a6a', '#b4570f', '#7a4fc2', '#c23d6b', '#2f7f9e', '#5d6f12', '#a14a2b'];
  RSA.avatar = (name, size) => {
    const s = String(name || '?'); let h = 0; for (const ch of s) h = (h * 31 + ch.codePointAt(0)) >>> 0;
    const first = [...s.replace(/^(น้อง|คุณ|พี่)/, '').replace(/^[เแโใไ]/, '')][0] || '?';
    return `<span class="avatar" style="background:${COLORS[h % COLORS.length]}${size ? `;width:${size}px;height:${size}px` : ''}" aria-hidden="true">${esc(first)}</span>`;
  };
  RSA.baht = (v) => (num(v) < 0 ? '−฿' + money(-num(v)) : '฿' + money(v));
  RSA.row = (o) => {
    const tag = o.href ? 'a' : o.static ? 'div' : 'button';
    const attrs = Object.entries(o.data || {}).map(([k, v]) => ` data-${k}="${esc(v)}"`).join('');
    return `<${tag} class="row ${o.static ? 'static' : ''} ${o.off ? 'off' : ''}" ${o.href ? `href="${o.href}"` : tag === 'button' ? 'type="button"' : ''}${attrs}>
      ${o.avatar ? RSA.avatar(o.avatar) : o.icon ? `<span class="ic ${o.tone || ''}">${RSA.icon(o.icon)}</span>` : ''}
      <span class="body"><span class="t">${o.t}</span>${o.s ? `<span class="s">${o.s}</span>` : ''}</span>
      ${o.v != null || o.pill || o.vs ? `<span class="end">${o.v != null ? `<span class="v">${o.v}</span>` : ''}${o.vs ? `<span class="s small">${o.vs}</span>` : ''}${o.pill || ''}</span>` : ''}
      ${o.static || o.chev === false ? '' : `<svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M9 6l6 6-6 6"/></svg>`}</${tag}>`;
  };
  RSA.list = (rows, emptyText) => (rows.length ? `<div class="list">${rows.join('')}</div>` : `<div class="empty">${esc(emptyText || 'ยังไม่มีรายการ')}</div>`);
  RSA.sec = (title, right) => `<div class="sec-title"><h2>${esc(title)}</h2>${right || ''}</div>`;
  RSA.stat = (k, v, s) => `<div class="stat"><span class="k">${esc(k)}</span><span class="v">${v}</span>${s ? `<span class="s">${s}</span>` : ''}</div>`;
  RSA.empty = (t) => `<div class="empty">${esc(t)}</div>`;
  RSA.seg = (name, opts, val, cls) => `<div class="seg ${cls || ''}" role="radiogroup">${opts.map(([v, l]) =>
    `<label><input type="radio" name="${name}" value="${esc(v)}" ${String(v) === String(val) ? 'checked' : ''}><span>${esc(l)}</span></label>`).join('')}</div>`;
  RSA.segVal = (root, name) => { const i = root.querySelector(`input[name="${name}"]:checked`); return i ? i.value : null; };
  // A fixed bar of the screen's main buttons, kept above the tab bar.
  RSA.actionbar = (html) => { document.body.classList.add('has-actionbar'); return `<div class="actionbar"><div class="in">${html}</div></div>`; };
  RSA.success = (el, o) => {
    document.body.classList.remove('has-actionbar');
    el.innerHTML = `<div class="card success"><span class="mark">${RSA.icon('check')}</span><h2>${esc(o.title)}</h2>${o.sub ? `<p class="muted">${o.sub}</p>` : ''}
      <div class="btn-row" style="width:100%">${(o.actions || []).map((a) => `<a class="btn lg ${a.primary ? 'primary' : ''}" href="${a.href}">${esc(a.label)}</a>`).join('')}</div></div>`;
    window.scrollTo(0, 0);
  };

  // ------------------------------------------------------------ screens: titles, where "back" goes, which tab they belong to
  RSA.META = {};
  RSA.def = (name, meta, fn) => { RSA.META[name] = meta; RSA.screens[name] = fn; };

  RSA.MENU = [
    { group: 'งานประจำวัน', items: [
      { r: 'sell', perm: 'sales.add', icon: 'cart', t: 'บันทึกการขาย' },
      { r: 'close', perm: 'closing.add', icon: 'moon', t: 'รายงานปิดยอดวันนี้' },
      { r: 'orders', perm: 'sales.view', icon: 'receipt', t: 'รายการขายวันนี้' },
      { r: 'receive', perm: 'stock.receive', icon: 'box', t: 'รับสินค้า' },
      { r: 'expense', perm: 'expense.add', icon: 'wallet', t: 'บันทึกค่าใช้จ่าย' },
      { r: 'waste', perm: 'waste.add', icon: 'trash', t: 'ของเสีย / สวัสดิการทีมงาน' },
      { r: 'stock', perm: 'stock.view', icon: 'box', t: 'สต๊อกคงเหลือ' },
      { r: 'my', perm: 'closing.add', icon: 'calendar', t: 'สรุปของฉัน' },
    ] },
    { group: 'รายงาน', items: [
      { r: 'dashboard', perm: 'report.view', icon: 'chart', t: 'ภาพรวม' },
      { r: 'sales', perm: 'report.view', icon: 'chart', t: 'ยอดขาย' },
      { r: 'products', perm: 'report.view', icon: 'tag', t: 'สินค้า / ขายดี' },
      { r: 'stock', perm: 'report.view', icon: 'box', t: 'สต๊อกคงเหลือ' },
      { r: 'delivery', perm: 'report.view', icon: 'flow', t: 'Delivery' },
      { r: 'purchases', perm: 'report.view', icon: 'box', t: 'ซื้อของเข้าร้าน' },
      { r: 'staff', perm: 'report.view', icon: 'users', t: 'พนักงาน / ค่าจ้าง' },
      { r: 'closes', perm: 'closing.view_all', icon: 'calendar', t: 'รายงานปิดยอดทั้งหมด' },
    ] },
    { group: 'เงิน บัญชี และภาษี', items: [
      { r: 'approvals', perm: 'expense.approve', icon: 'check', t: 'รออนุมัติ' },
      { r: 'cashflow', perm: 'cashflow.view', icon: 'flow', t: 'เงินสด / Cashflow' },
      { r: 'expenses', perm: 'expense.view_all', icon: 'wallet', t: 'ค่าใช้จ่าย' },
      { r: 'accounts', perm: 'cashflow.view', icon: 'receipt', t: 'บัญชีเงิน / ภาษี' },
      { r: 'import', perm: 'cashflow.manage', icon: 'plus', t: 'นำเข้าข้อมูล QR / Delivery' },
      { r: 'export', perm: 'export.run', icon: 'download', t: 'ส่งออกให้นักบัญชี' },
      { r: 'invest', perm: 'cashflow.view', icon: 'chart', t: 'เงินลงทุน / คืนทุน' },
    ] },
    { group: 'ร้าน', items: [
      { r: 'master', perm: 'master.manage', icon: 'tag', t: 'สินค้า ราคา สูตร โปร' },
      { r: 'users', perm: 'admin.users', icon: 'users', t: 'ผู้ใช้ สิทธิ์ และ PIN' },
      { r: 'share', perm: 'admin.users', icon: 'users', t: 'ส่งลิงก์ให้พนักงาน' },
      { r: 'settings', perm: 'settings.manage', icon: 'gear', t: 'ตั้งค่าร้าน' },
      { r: 'audit', perm: 'audit.view', icon: 'shield', t: 'ประวัติการใช้งาน' },
    ] },
  ];

  // An owner can look at the app the way staff see it (same permissions on the server; only the layout changes).
  RSA.staffView = () => store.get('staffview') === '1' && RSA.can('report.view');
  RSA.setStaffView = (on) => { store.set('staffview', on ? '1' : null); location.hash = on ? '#/home' : '#/dashboard'; RSA.route(); };
  const isOwnerView = () => RSA.can('report.view') && !RSA.staffView();
  RSA.isOwnerView = isOwnerView;
  function tabs() {
    const t = isOwnerView()
      ? [['dashboard', 'home', 'ภาพรวม'], ['approvals', 'check', 'อนุมัติ', 'expense.approve'], ['sales', 'chart', 'ยอดขาย', 'report.view', 'center'], ['cashflow', 'wallet', 'เงิน', 'cashflow.view'], ['more', 'list', 'เพิ่มเติม']]
      : [['home', 'home', 'หน้าหลัก'], ['close', 'moon', 'ปิดยอด', 'closing.add'], ['sell', 'cart', 'ขาย', 'sales.add', 'center'], ['my', 'calendar', 'ของฉัน', 'closing.add'], ['more', 'list', 'เพิ่มเติม']];
    return t.filter((x) => !x[3] || RSA.can(x[3]));
  }
  RSA.tabs = tabs;

  // ------------------------------------------------------------ layout & router
  const app = () => document.getElementById('app');
  RSA.shopName = () => { const s = RSA.state.boot && RSA.state.boot.settings.shop_name; return (s && s.value) || ''; };

  function shell(name) {
    const me = RSA.state.boot.me, meta = RSA.META[name] || {}, tb = tabs();
    const tabNames = tb.map((x) => x[0]);
    const activeTab = tabNames.includes(name) ? name : (meta.tab && tabNames.includes(meta.tab) ? meta.tab : 'more');
    const back = !tabNames.includes(name) && name !== 'home' ? (meta.back || 'more') : null;
    const sideGroups = RSA.MENU.filter((g) => isOwnerView() || g.group === 'งานประจำวัน').sort((a, b) => (isOwnerView() && a.group === 'งานประจำวัน' ? 1 : 0) - (isOwnerView() && b.group === 'งานประจำวัน' ? 1 : 0)).map((g) => {
      const items = g.items.filter((i, k, all) => RSA.can(i.perm) && !tabNames.includes(i.r) && all.findIndex((y) => y.r === i.r) === k);
      return items.length ? `<h3>${esc(g.group)}</h3>${items.map((i) => `<a href="#/${i.r}" ${i.r === name ? 'aria-current="page"' : ''}>${RSA.icon(i.icon)}<span>${esc(i.t)}</span></a>`).join('')}` : '';
    }).join('');
    return `<div class="app">
      <nav class="side" aria-label="เมนูหลัก">
        <div class="logo"><span class="logo-mark">RSA</span><span>RSA - POS Assistant${RSA.shopName() ? `<small>${esc(RSA.shopName())}</small>` : ''}</span></div>
        ${tb.filter((x) => x[0] !== 'more').map(([r, ic, t]) => `<a href="#/${r}" ${r === activeTab ? 'aria-current="page"' : ''}>${RSA.icon(ic)}<span>${t}</span>${r === 'approvals' ? '<span class="badge" data-badge hidden></span>' : ''}</a>`).join('')}
        ${sideGroups}
        <h3>บัญชีของฉัน</h3>
        <a href="#/more" ${name === 'more' ? 'aria-current="page"' : ''}>${RSA.avatar(me.display_name, 24)}<span>${esc(me.display_name)}</span></a>
      </nav>
      <div class="main">
        <header class="appbar">
          ${back ? `<a class="icon-btn" href="#/${back}" aria-label="ย้อนกลับ">${RSA.icon('back')}</a>` : ''}
          <h1>${esc(meta.title || 'RSA - POS Assistant')}${!back && RSA.shopName() ? `<span class="shop">${esc(RSA.shopName())}</span>` : ''}</h1>
          <span id="appbar-right"></span>
        </header>
        ${RSA.staffView() ? '<div class="banner" style="margin:10px 14px 0"><span class="dot"></span><span>กำลังดูโหมดพนักงาน · <a href="#" id="sv-off">กลับโหมดเจ้าของ</a></span></div>' : ''}
        <main id="view"><div class="boot">กำลังโหลด…</div></main>
      </div>
      <nav class="tabbar" aria-label="เมนูหลัก">${tb.map(([r, ic, t, , c]) => `<a href="#/${r}" class="${c || ''}" ${r === activeTab ? 'aria-current="page"' : ''}>${RSA.icon(ic)}<span>${t}</span>${r === 'approvals' ? '<span class="badge" data-badge hidden></span>' : ''}</a>`).join('')}</nav>
    </div>`;
  }

  // Number of things waiting for the owner, shown on the tab. Refreshed at most every 30 seconds.
  let badgeAt = 0, badgeN = 0;
  RSA.refreshBadge = async function (force) {
    if (!RSA.can('expense.approve')) return;
    if (force || Date.now() - badgeAt > 30000) {
      try { badgeN = (await RSA.approvalItems()).length; badgeAt = Date.now(); } catch (e) { return; }
    }
    document.querySelectorAll('[data-badge]').forEach((b) => { b.hidden = !badgeN; b.textContent = badgeN > 99 ? '99+' : badgeN; });
  };

  RSA.go = (r) => { if (location.hash === '#/' + r) route(); else location.hash = '#/' + r; };
  async function route() {
    if (!RSA.state.token || !RSA.state.boot) return;
    let [name, arg] = (location.hash.replace(/^#\//, '') || 'home').split('/');
    if (name === 'home' && isOwnerView()) name = 'dashboard';
    if (name === 'my-closes') name = 'my';
    if (!RSA.screens[name]) name = isOwnerView() ? 'dashboard' : 'home';
    document.body.classList.remove('has-actionbar');
    app().innerHTML = shell(name);
    const sv = document.getElementById('sv-off'); if (sv) sv.addEventListener('click', (e) => { e.preventDefault(); RSA.setStaffView(false); });
    const view = document.getElementById('view');
    try { await RSA.screens[name](view, arg); } catch (e) {
      view.innerHTML = `<div class="card"><h2>เปิดหน้านี้ไม่ได้</h2><p class="muted">${esc(e.message)}</p><a class="btn" href="#/home">กลับหน้าหลัก</a></div>`;
    }
    window.scrollTo(0, 0);
    paintNet();
    RSA.refreshBadge();
  }
  RSA.route = route;
  window.addEventListener('hashchange', route);

  RSA.head = () => '';   // titles live in the app bar now

  // ------------------------------------------------------------ "more" tab: everything else + my account
  RSA.def('more', { title: 'เพิ่มเติม' }, async function (el) {
    const me = RSA.state.boot.me, tabNames = tabs().map((x) => x[0]);
    const seen = new Set(tabNames);
    const groups = RSA.MENU.filter((g) => isOwnerView() || g.group === 'งานประจำวัน' || g.group === 'ร้าน')
      .sort((a, b) => (isOwnerView() && a.group === 'งานประจำวัน' ? 1 : 0) - (isOwnerView() && b.group === 'งานประจำวัน' ? 1 : 0)).map((g) => {
      const onHome = isOwnerView() ? [] : ['orders', 'receive', 'expense', 'waste'];   // staff reach these from the home screen and the sell tab
      const items = g.items.filter((i) => RSA.can(i.perm) && !seen.has(i.r) && !onHome.includes(i.r));
      items.forEach((i) => seen.add(i.r));
      return items.length ? RSA.sec(g.group) + RSA.list(items.map((i) => RSA.row({ href: '#/' + i.r, icon: i.icon, t: esc(i.t) }))) : '';
    }).join('');
    el.innerHTML = `<div class="card" style="grid-template-columns:auto 1fr;align-items:center">${RSA.avatar(me.display_name, 56)}
        <div><h2>${esc(me.display_name)}</h2><p class="muted small">${esc(RSA.ROLE_LABEL[me.role] || me.role)} · ${esc(me.username)}</p></div></div>
      ${groups}
      ${RSA.sec('บัญชีของฉัน')}
      ${RSA.list([...(RSA.can('report.view') ? [RSA.row({ icon: 'eye', t: RSA.staffView() ? 'กลับโหมดเจ้าของ' : 'ดูโหมดพนักงาน', s: 'ดูหน้าจอแบบที่พนักงานใช้', data: { act: 'sv' } })] : []),
        RSA.row({ icon: 'lock', t: 'เปลี่ยน PIN ของฉัน', data: { act: 'pin' } }), RSA.row({ icon: 'out', tone: 'bad', t: 'ออกจากระบบ / สลับผู้ใช้', data: { act: 'out' }, chev: false })])}`;
    el.querySelector('[data-act=out]').addEventListener('click', () => RSA.logout());
    const svb = el.querySelector('[data-act=sv]'); if (svb) svb.addEventListener('click', () => RSA.setStaffView(!RSA.staffView()));
    el.querySelector('[data-act=pin]').addEventListener('click', () => {
      const m = RSA.modal('เปลี่ยน PIN ของฉัน', `<form class="form">
        <label class="field"><span>PIN เดิม</span><input type="password" inputmode="numeric" maxlength="6" id="p-old" autocomplete="current-password"></label>
        <label class="field"><span>PIN ใหม่ 6 หลัก</span><input type="password" inputmode="numeric" maxlength="6" id="p-new" autocomplete="new-password"></label>
        <button class="btn primary lg" type="submit">บันทึก PIN ใหม่</button></form>`);
      m.el.querySelector('form').addEventListener('submit', (ev) => {
        ev.preventDefault();
        RSA.busy(ev.submitter, async () => { await RSA.api('user.reset_pin', { id: me.id, old_pin: RSA.val(m.el, '#p-old'), pin: RSA.val(m.el, '#p-new') }); m.close(); RSA.toast('เปลี่ยน PIN แล้ว'); });
      });
    });
  });

  // ------------------------------------------------------------ session
  RSA.loadBoot = async function () {
    RSA.state.boot = await RSA.api('bootstrap');
    store.set('boot', JSON.stringify(RSA.state.boot));   // lets the sell screen open when the signal drops
    return RSA.state.boot;
  };
  RSA.logout = function (expired) {
    const t = RSA.state.token;
    if (RSA.queueCount() && !expired) {
      RSA.toast('ยังมีออเดอร์ค้างส่ง ' + RSA.queueCount() + ' รายการ รอให้มีสัญญาณก่อนออกจากระบบ', true);
      return;
    }
    RSA.state.token = null; RSA.state.boot = null; store.set('token', null); store.set('boot', null); store.set('staffview', null);
    if (t && !expired) rpc('rsa_logout', { p_token: t }).catch(() => {});
    if (expired) RSA.toast('หมดเวลาการใช้งาน กรุณาใส่ PIN อีกครั้ง');
    else history.replaceState(null, '', location.pathname + location.search); // the next person starts from their own home
    loginScreen();
  };

  // People who signed in on this device, so staff tap their name instead of typing it.
  const recent = { list: () => store.json('recent', []), add(u, n) { store.set('recent', JSON.stringify([{ u, n }, ...this.list().filter((x) => x.u !== u)].slice(0, 6))); } };

  function loginScreen() {
    document.body.classList.remove('has-actionbar');
    const people = recent.list();
    let user = store.get('username') || (people[0] && people[0].u) || '';
    if (people.length && !people.some((p) => p.u === user)) user = people[0].u;
    app().innerHTML = `<div class="login"><form id="f-login" class="form" autocomplete="off">
      <div class="logo"><span class="logo-mark">RSA</span><span>RSA - POS Assistant</span></div>
      ${people.length ? `<div class="field"><span>แตะชื่อของคุณ</span><div class="people" id="people">${people.map((p) =>
        `<button type="button" class="person" data-u="${esc(p.u)}" aria-pressed="${p.u === user}">${RSA.avatar(p.n)}<span>${esc(p.n)}</span></button>`).join('')}
        <button type="button" class="person" data-u="" aria-pressed="false"><span class="avatar" style="background:#c6d4e4">+</span><span>คนอื่น</span></button></div></div>` : ''}
      <label class="field" id="user-box" ${people.length && user ? 'hidden' : ''}><span>ชื่อผู้ใช้</span><input type="text" id="l-user" value="${esc(user)}" autocapitalize="none" autocomplete="username"></label>
      <div class="field"><span style="text-align:center">ใส่ PIN 6 หลัก</span><div class="pin-dots" aria-hidden="true">${'<span></span>'.repeat(6)}</div>
        <input type="password" id="l-pin" inputmode="numeric" maxlength="6" pattern="[0-9]{6}" autocomplete="current-password" aria-label="PIN 6 หลัก" class="sr"></div>
      <div class="keypad">${[1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => `<button type="button" data-k="${n}">${n}</button>`).join('')}
        <button type="button" class="fn" data-k="clr">ล้าง</button><button type="button" data-k="0">0</button><button type="button" class="fn" data-k="del" aria-label="ลบ">ลบ</button></div>
      <button class="btn primary lg" type="submit">เข้าสู่ระบบ</button>
      <p class="muted small" style="text-align:center">ลืม PIN ให้ผู้ดูแลระบบตั้งใหม่ให้</p></form></div>`;
    const f = app().querySelector('#f-login'), pin = f.querySelector('#l-pin'), userIn = f.querySelector('#l-user');
    const paint = () => f.querySelectorAll('.pin-dots span').forEach((s, i) => s.classList.toggle('on', i < pin.value.length));
    const ppl = f.querySelector('#people');
    if (ppl) ppl.addEventListener('click', (ev) => {
      const b = ev.target.closest('[data-u]'); if (!b) return;
      ppl.querySelectorAll('[data-u]').forEach((x) => x.setAttribute('aria-pressed', x === b));
      userIn.value = b.dataset.u;
      f.querySelector('#user-box').hidden = !!b.dataset.u;
      pin.value = ''; paint();
      if (!b.dataset.u) userIn.focus();
    });
    pin.addEventListener('input', () => { pin.value = pin.value.replace(/\D/g, '').slice(0, 6); paint(); if (pin.value.length === 6 && userIn.value) f.requestSubmit(); });
    f.querySelector('.keypad').addEventListener('click', (ev) => {
      const k = ev.target.closest('button'); if (!k) return;
      const v = k.dataset.k;
      pin.value = v === 'clr' ? '' : v === 'del' ? pin.value.slice(0, -1) : (pin.value + v).slice(0, 6);
      paint();
      if (pin.value.length === 6) f.requestSubmit();
    });
    f.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const btn = f.querySelector('[type=submit]');
      if (btn.disabled) return;
      const username = userIn.value.trim().toLowerCase();
      if (!username) { RSA.fail(new Error('แตะชื่อหรือพิมพ์ชื่อผู้ใช้ก่อน')); pin.value = ''; paint(); return; }
      btn.disabled = true;
      try {
        const r = await rpc('rsa_login', { p_username: username, p_pin: pin.value });
        store.set('username', username);
        recent.add(username, r.user.display_name);
        RSA.state.token = r.token; store.set('token', r.token);
        await RSA.loadBoot();
        if (!location.hash || location.hash === '#/') location.hash = '#/home'; else route();
        RSA.flushQueue();
      } catch (e) { RSA.fail(e); pin.value = ''; paint(); } finally { btn.disabled = false; }
    });
    if (!user) userIn.focus();
  }

  function setupScreen() {
    app().innerHTML = `<div class="login"><form class="card form" id="f-setup">
      <div class="logo"><span class="logo-mark">RSA</span><span>RSA - POS Assistant</span></div>
      <p class="note info">ตั้งผู้ดูแลระบบคนแรก บัญชีนี้มีสิทธิ์ทุกอย่าง ใช้สร้างผู้ใช้คนอื่นและกำหนดสิทธิ์ต่อ</p>
      <label class="field"><span>ชื่อที่แสดง</span><input type="text" id="s-name" required></label>
      <label class="field"><span>ชื่อผู้ใช้ (a-z, 0-9)</span><input type="text" id="s-user" pattern="[a-z0-9._\\-]{2,32}" autocapitalize="none" required></label>
      <div class="two"><label class="field"><span>PIN 6 หลัก</span><input type="password" id="s-pin" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" required></label>
      <label class="field"><span>ยืนยัน PIN</span><input type="password" id="s-pin2" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" required></label></div>
      <button class="btn primary lg" type="submit">สร้างผู้ดูแลระบบ</button></form></div>`;
    const f = app().querySelector('#f-setup');
    f.addEventListener('submit', (ev) => {
      ev.preventDefault();
      RSA.busy(f.querySelector('[type=submit]'), async () => {
        if (RSA.val(f, '#s-pin') !== RSA.val(f, '#s-pin2')) throw new Error('PIN สองช่องไม่ตรงกัน');
        await rpc('rsa_setup', { p_username: RSA.val(f, '#s-user').toLowerCase(), p_display_name: RSA.val(f, '#s-name'), p_pin: RSA.val(f, '#s-pin') });
        store.set('username', RSA.val(f, '#s-user').toLowerCase());
        RSA.toast('สร้างผู้ดูแลระบบแล้ว กรุณาเข้าสู่ระบบ');
        loginScreen();
      });
    });
  }

  const atobSafe = (x) => { try { return atob(x.replace(/-/g, '+').replace(/_/g, '/')); } catch (e) { return ''; } };
  // First run without config.js: the owner pastes the two Supabase values once on their computer.
  function connectScreen(errMsg) {
    app().innerHTML = `<div class="login"><form class="card form" id="f-conn">
      <div class="logo"><span class="logo-mark">RSA</span><span>RSA - POS Assistant</span></div>
      <h2>เชื่อมต่อฐานข้อมูลของร้าน</h2>
      <p class="muted small">ทำครั้งเดียวบนคอมของเจ้าของร้าน: เปิด Supabase → Project Settings → API Keys (และ Data API สำหรับ URL) แล้วคัดลอกสองค่านี้มาวาง พนักงานไม่ต้องทำขั้นนี้</p>
      ${errMsg ? `<div class="note">${esc(errMsg)}</div>` : ''}
      <label class="field"><span>Project URL</span><input type="text" id="c-url" placeholder="https://xxxx.supabase.co" value="${esc(CFG.supabaseUrl || '')}" autocapitalize="none" required></label>
      <label class="field"><span>Publishable key (sb_publishable_…) หรือ anon public key</span><textarea id="c-key" required autocapitalize="none" spellcheck="false" placeholder="sb_publishable_... หรือ eyJhbGciOi...">${esc(CFG.anonKey || '')}</textarea></label>
      <button class="btn primary lg" type="submit">เชื่อมต่อ</button></form></div>`;
    const f = app().querySelector('#f-conn');
    f.addEventListener('submit', (ev) => {
      ev.preventDefault();
      RSA.busy(f.querySelector('[type=submit]'), async () => {
        const url = RSA.val(f, '#c-url'), key = RSA.val(f, '#c-key').replace(/\s+/g, '');
        if (!/^https?:\/\/[^ ]+$/.test(url)) throw new Error('Project URL ต้องขึ้นต้นด้วย https://');
        if (/^sb_secret_/.test(key) || /service_role/.test(atobSafe(key.split('.')[1] || ''))) throw new Error('นี่คือคีย์ลับ (secret / service_role) ห้ามใช้กับแอปนี้ ให้ใช้ Publishable key หรือ anon key');
        const prev = CFG;
        RSA.setCfg({ supabaseUrl: url, anonKey: key });
        try { await rpc('rsa_status', {}); }
        catch (e) {
          CFG = prev; store.set('cfg', prev.supabaseUrl ? JSON.stringify(prev) : null);
          throw new Error(/function|rsa_status|404|PGRST/i.test(e.message) ? 'เชื่อมต่อได้ แต่ยังไม่ได้รันไฟล์ install.sql ใน SQL Editor' : 'เชื่อมต่อไม่ได้: ' + e.message);
        }
        RSA.toast('เชื่อมต่อฐานข้อมูลแล้ว');
        RSA.start();
      });
    });
  }

  // ------------------------------------------------------------ staff home: today card + big buttons
  RSA.def('home', { title: 'หน้าหลัก' }, async function (el) {
    const me = RSA.state.boot.me;
    let card = '', closeBar = '';
    const due = RSA.settingVal ? RSA.settingVal('close_due_time', '21:00') : '21:00';
    const closeAt = RSA.settingVal ? RSA.settingVal('close_time', '20:00') : '20:00';
    if (navigator.onLine && (RSA.can('closing.add') || RSA.can('sales.view'))) {
      try {
        const [orders, closes] = await Promise.all([
          RSA.can('sales.view') ? RSA.api('order.list', { from: today(), to: today() }) : [],
          RSA.can('closing.add') ? RSA.api('close.list', { from: today(), to: today() }) : []]);
        RSA.state.boot.closed_today = closes.length > 0;
        const live = orders.filter((o) => o.status !== 'cancelled');
        const net = live.reduce((s, o) => s + Number(o.total) - Number(o.refunded), 0);
        const mine = live.filter((o) => o.created_by === me.id).length;
        card = `<a class="card blue" href="#/sell" style="text-decoration:none;color:inherit">
          <span class="muted small">บันทึกการขายเมื่อออเดอร์เสร็จ · ${date(today())}</span>
          <span class="big-amt">${RSA.baht(net)}</span><span class="muted">${RSA.can('sales.view_all') ? 'ทั้งร้าน ' : ''}${live.length} ออเดอร์${RSA.can('sales.view_all') ? ' · ของฉัน ' + mine : ''}</span></a>`;
        const rs = RSA.reminderState ? RSA.reminderState() : null;
        const holiday = RSA.isHoliday && RSA.isHoliday(today());
        closeBar = closes.length
          ? `<div class="banner ok"><span class="dot"></span><span>ส่งรายงานปิดยอดวันนี้แล้ว ${time(closes[0].submitted_at)} น.${closes[0].on_time === false ? ' (หลังเวลา)' : ' · ตรงเวลา'}</span></div>`
          : holiday && !live.length ? `<div class="banner ok"><span class="dot"></span><span>วันนี้ร้านหยุด ไม่ต้องส่งรายงานปิดยอด</span></div>`
          : holiday ? `<a class="banner" href="#/close" style="text-decoration:none;color:inherit"><span class="dot"></span><span>วันนี้เป็นวันหยุดร้าน แต่มีการขาย ${live.length} ออเดอร์ กรุณาส่งรายงานปิดยอดด้วย</span></a>`
          : `<a class="banner ${rs && rs.level === 'late' ? 'bad' : ''}" href="#/close" style="text-decoration:none;color:inherit"><span class="dot"></span><span>${rs && rs.text ? esc(rs.text)
              : `ยังไม่ได้ส่งรายงานวันนี้ · ร้านปิด ${esc(closeAt)} น. · ส่งให้ตรงเวลาภายใน ${esc(due)} น.`}</span></a>`;
      } catch (e) { /* buttons still work without the summary */ }
    }
    // the bottom bar already has sell / close / my summary: the home screen lists only the other daily jobs
    const tabNames = tabs().map((x) => x[0]);
    const jobs = [
      { r: 'receive', perm: 'stock.receive', icon: 'box', t: 'รับสินค้า', d: 'ของเข้าร้าน ค่าขนส่ง ใครจ่าย' },
      { r: 'expense', perm: 'expense.add', icon: 'wallet', t: 'ค่าใช้จ่าย', d: 'ถ่ายบิล เลือกว่าจ่ายจากเงินไหน' },
      { r: 'waste', perm: 'waste.add', icon: 'trash', t: 'ของเสีย / สวัสดิการทีมงาน', d: 'ของเสีย หรือของที่ทีมงานกิน' },
      { r: 'sell', perm: 'sales.add', icon: 'cart', t: 'บันทึกการขาย', d: '' },
      { r: 'close', perm: 'closing.add', icon: 'moon', t: 'รายงานปิดยอดวันนี้', d: '' },
    ].filter((b) => RSA.can(b.perm) && !tabNames.includes(b.r));
    el.innerHTML = `<h2 style="padding:2px 4px;font-size:1.05rem">สวัสดี ${esc(me.display_name)}</h2>${card}${closeBar}
      ${jobs.length ? RSA.sec('งานอื่นวันนี้') + RSA.list(jobs.map((b) => RSA.row({ href: '#/' + b.r, icon: b.icon, t: esc(b.t), s: esc(b.d) }))) : ''}
      ${window.Notification && Notification.permission === 'default' && RSA.can('closing.add') ? '<button class="btn ghost small" id="notif">เปิดการแจ้งเตือนเวลาปิดยอดบนเครื่องนี้</button>' : ''}`;
    const nb = el.querySelector('#notif'); if (nb) nb.addEventListener('click', () => Notification.requestPermission().then(() => nb.remove()));
    if (RSA.remind) RSA.remind();
  });

  // ------------------------------------------------------------ share the app with staff phones
  RSA.def('share', { title: 'ส่งลิงก์ให้พนักงาน', back: 'more' }, async function (el) {
    const link = RSA.shareLink();
    el.innerHTML = `<div class="card"><h2>ให้พนักงานสแกน QR นี้</h2><div id="qr" class="qr-box"><span class="muted">กำลังสร้าง QR…</span></div>
        <p class="muted small">เปิดในเบราว์เซอร์มือถือได้เลย ไม่ต้องติดตั้งแอป แล้วแตะชื่อตัวเองและใส่ PIN</p></div>
      <div class="card"><h2>หรือส่งลิงก์ทาง LINE</h2><textarea id="lnk" readonly rows="3" style="font-size:.85rem">${esc(link)}</textarea>
        <button class="btn primary lg" id="copy">คัดลอกลิงก์</button>
        <p class="muted small">ลิงก์มีค่าเชื่อมต่อร้าน (ไม่ใช่รหัสผ่าน) ทุกคนยังต้องใช้ PIN ของตัวเอง</p></div>
      ${RSA.list([RSA.row({ href: '#/users', icon: 'users', t: 'สร้างบัญชีและ PIN ให้พนักงาน' })])}`;
    el.querySelector('#copy').addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(link); RSA.toast('คัดลอกลิงก์แล้ว'); }
      catch (e) { el.querySelector('#lnk').select(); RSA.toast('กดค้างที่ลิงก์แล้วเลือกคัดลอก'); }
    });
    try {
      if (!window.qrcode) await new Promise((res, rej) => { const s = document.createElement('script'); s.src = 'https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js'; s.onload = res; s.onerror = rej; document.head.appendChild(s); });
      const q = window.qrcode(0, 'M'); q.addData(link); q.make();
      el.querySelector('#qr').innerHTML = q.createSvgTag({ cellSize: 6, margin: 2, scalable: true });
    } catch (e) { el.querySelector('#qr').innerHTML = '<span class="muted">สร้าง QR ไม่ได้ ใช้การคัดลอกลิงก์แทน</span>'; }
  });

  // ------------------------------------------------------------ start
  RSA.start = async function () {
    const m = location.hash.match(/^#cfg=([A-Za-z0-9_-]+)/);
    if (m) {
      try { const c = b64.dec(m[1]); if (!RSA.cfgFromFile()) RSA.setCfg({ supabaseUrl: c.u, anonKey: c.k }); } catch (e) { /* ignore a broken link */ }
      history.replaceState(null, '', location.pathname + location.search);
    }
    if (!CFG.supabaseUrl || !CFG.anonKey) return connectScreen();
    const saved = store.get('token');
    try {
      const st = await rpc('rsa_status', {});
      if (st.needs_setup) return setupScreen();
    } catch (e) {
      const cached = store.json('boot', null);
      if (e.offline && saved && cached) {         // no signal: open with what this phone already knows
        RSA.state.token = saved; RSA.state.boot = cached;
        paintNet(); return route();
      }
      if (!e.offline) return connectScreen('เชื่อมต่อไม่ได้: ' + e.message);
      app().innerHTML = `<div class="login"><div class="card"><h2>เชื่อมต่ออินเทอร์เน็ตไม่ได้</h2><p class="muted">ตรวจสัญญาณแล้วลองอีกครั้ง</p><button class="btn primary lg" onclick="location.reload()">ลองอีกครั้ง</button></div></div>`;
      return;
    }
    if (saved) {
      RSA.state.token = saved;
      try { await RSA.loadBoot(); route(); RSA.flushQueue(); return; } catch (e) { RSA.state.token = null; store.set('token', null); }
    }
    loginScreen();
  };
})();
