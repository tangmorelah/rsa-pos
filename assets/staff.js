/* RSA - POS Assistant — daily work screens: sell (with today's orders, edit, cancel), orders, receive, waste, expense,
   6-step daily close, my summary, stock (mobile app layout) */
(function () {
  'use strict';
  const R = window.RSA, esc = R.esc, money = R.money, qty = R.qty, baht = R.baht;
  const B = () => R.state.boot;
  const on = (node, fn) => node && node.addEventListener('click', fn);
  const r2 = (v) => Math.round(Number(v || 0) * 100) / 100;
  // After a success screen, a button pointing at the current screen should still reload it.
  const success = (el, o) => {
    R.success(el, o);
    el.querySelectorAll('.success a.btn').forEach((a) => a.addEventListener('click', (e) => { if (a.getAttribute('href') === location.hash) { e.preventDefault(); R.route(); } }));
  };
  R.successGo = success;
  const emo = (p) => (p && p.emoji ? esc(p.emoji) : esc(((p && p.name) || '?').replace(/^[เแโใไ]/, '').slice(0, 1)));

  // ------------------------------------------------------------ price preview (the server recalculates and is authoritative)
  const priceOf = (p, ch) => (ch && ch.kind === 'delivery' && p.delivery_price != null ? Number(p.delivery_price) : Number(p.price));
  const sellable = (p, ch) => !(ch && ch.kind === 'delivery' && p.delivery_enabled === false);
  function activePromos(ch) {
    const now = Date.now();
    return B().promotions.filter((p) => p.active && (!p.starts_at || Date.parse(p.starts_at) <= now) && (!p.ends_at || Date.parse(p.ends_at) > now)
      && (!(p.channel_ids || []).length || p.channel_ids.includes(ch.id)) && (!p.storefront_only || ch.kind === 'storefront'));
  }
  function calc(lines, ch) {
    const prod = (id) => B().products.find((x) => x.id === id);
    const rows = lines.map((l) => { const p = prod(l.product_id), price = priceOf(p, ch); return { l, p, price, gross: r2(price * l.qty), disc: 0, promo: null }; });
    const taken = new Set(), hints = [];
    // evening markdown lines take the markdown price and no other promotion
    rows.forEach((r, i) => { if (r.l.markdown) { r.disc = r2((r.price - Number(r.p.markdown_price)) * r.l.qty); r.promo = { name: 'ลดราคาตอนเย็น', rule: 'markdown' }; taken.add(i); } });
    activePromos(ch).filter((p) => p.rule === 'bundle' && Number(p.buy_qty) > 0 && p.bundle_price != null)
      .sort((a, b) => String(a.created_at).localeCompare(String(b.created_at))).forEach((pr) => {
        const idx = rows.map((r, i) => i).filter((i) => !taken.has(i) && (pr.scope === 'all' || (pr.product_ids || []).includes(rows[i].p.id)));
        const pq = idx.reduce((s, i) => s + Number(rows[i].l.qty), 0), pg = idx.reduce((s, i) => s + rows[i].gross, 0);
        if (!pq) return;
        const n = Math.floor(pq / Number(pr.buy_qty)), left = Number(pr.buy_qty) - (pq % Number(pr.buy_qty));
        if (left > 0 && left < Number(pr.buy_qty)) hints.push(`เพิ่มอีก ${qty(left)} ชิ้นได้โปร "${pr.name}"`);
        if (n < 1) return;
        const bd = r2((n * Number(pr.buy_qty) * pg) / pq - n * Number(pr.bundle_price));
        if (bd <= 0) return;
        let rest = bd;
        idx.forEach((i, k) => { const sh = k === idx.length - 1 ? r2(rest) : r2((bd * rows[i].gross) / pg); rest = r2(rest - sh); rows[i].disc = sh; rows[i].promo = { ...pr, bundles: n }; taken.add(i); });
      });
    rows.forEach((r, i) => {
      if (taken.has(i)) return;
      let best = null, bd = 0;
      activePromos(ch).filter((p) => p.rule !== 'bundle' && (p.scope === 'all' || (p.product_ids || []).includes(r.p.id)) && r.l.qty >= Number(p.min_qty || 1)).forEach((p) => {
        const d = p.rule === 'percent' ? r2((r.gross * p.value) / 100) : r2(Math.min(p.value, r.price) * r.l.qty);
        if (d > bd) { bd = d; best = p; }
      });
      r.disc = bd; r.promo = best;
    });
    const sub = r2(rows.reduce((s, r) => s + r.gross, 0)), disc = r2(rows.reduce((s, r) => s + r.disc, 0));
    return { rows, sub, disc, total: r2(sub - disc), n: rows.reduce((s, r) => s + Number(r.l.qty), 0), hints };
  }
  R.calcOrder = calc;

  // ------------------------------------------------------------ order detail sheet (shared by sell and orders)
  const canEdit = (o) => o.status !== 'cancelled' && !o.settlement_id && !Number(o.refunded)
    && (R.can('sales.cancel') || (o.created_by === B().me.id && o.biz_date === R.today() && !o.closed));
  R.orderCanEdit = canEdit;
  function orderSheet(o, done) {
    const m = R.modal('ออเดอร์ ' + o.order_no, `
      <div class="muted small">${R.dt(o.created_at)} · ${esc(o.channel_name)} · โดย ${esc(o.created_by_name)}</div>
      ${o.replaces_no ? `<div class="note info">ออเดอร์นี้แก้ไขจาก ${esc(o.replaces_no)}</div>` : ''}
      ${o.replaced_by_no ? `<div class="note">ถูกแก้ไขเป็น ${esc(o.replaced_by_no)} แล้ว</div>` : ''}
      <div>${o.items.map((i) => `<div class="sum-row"><span>${i.emoji ? esc(i.emoji) + ' ' : ''}${esc(i.product_name)} × ${qty(i.qty)} <span class="muted small">@${money(i.unit_price)}</span>${Number(i.discount) ? `<br><span class="muted small">ลด ${money(i.discount)}${i.promo_snapshot && i.promo_snapshot.name ? ' · ' + esc(i.promo_snapshot.name) : ''}</span>` : ''}</span><span>${money(i.line_total)}</span></div>`).join('')}
        ${(o.payments || []).length > 1 ? `<div class="note info">จ่ายผสม: ${o.payments.map((x) => esc(x.account) + ' ' + money(x.amount)).join(' + ')}</div>` : ''}
      ${o.calc_total != null && Number(o.calc_total) !== Number(o.total) ? `<div class="sum-row"><span>ยอดคำนวณ</span><span>${money(o.calc_total)}</span></div><div class="sum-row"><span>ยอดรับจริง · ${esc(o.received_note || '')}</span><span>${money(o.total)}</span></div>` : ''}
        <div class="sum-row total"><span>รวม</span><span>${baht(o.total)}</span></div>${Number(o.refunded) ? `<div class="sum-row"><span>คืนเงินแล้ว</span><span>−${money(o.refunded)}</span></div>` : ''}</div>
      ${o.note ? `<p class="muted">${esc(o.note)}</p>` : ''}
      ${o.events.length ? R.sec('ประวัติ') + o.events.map((e) => `<div class="note">${e.kind === 'cancel' ? 'ยกเลิก' : 'คืนเงิน'} ${money(e.amount)} · ${esc(e.reason)} · ${esc(e.by)} ${R.dt(e.created_at)}</div>`).join('') : ''}
      <div class="btn-row">${canEdit(o) ? '<button class="btn lg" id="ed">แก้ไข</button><button class="btn lg danger" id="x">ยกเลิก</button>' : ''}
        ${R.can('sales.cancel') && o.status !== 'cancelled' ? '<button class="btn" id="rf">คืนเงิน</button>' : ''}${R.purgeBtn(o.status === 'cancelled' && !o.settlement_id)}</div>
      ${!canEdit(o) && o.status !== 'cancelled' && !R.can('sales.cancel') ? '<p class="muted small">แก้ไขได้เฉพาะออเดอร์ของตัวเองวันนี้ก่อนส่งรายงานปิดยอด ถ้าต้องแก้รายการอื่นให้แจ้งเจ้าของร้าน</p>' : ''}`);
    on(m.el.querySelector('#ed'), () => { m.close(); R.state.editOrder = o; location.hash = '#/sell/edit'; });
    R.purge(m.el, 'order', o.id, 'ออเดอร์ ' + o.order_no, () => { m.close(); done(); });
    on(m.el.querySelector('#x'), async () => {
      m.close();
      const r = await R.askReason('ยกเลิกออเดอร์ ' + o.order_no, { text: (o.closed ? 'วันนี้ส่งรายงานปิดยอดแล้ว เจ้าของร้านจะเห็นรายการนี้ · ' : '') + 'ระบบคืนสต็อกและบันทึกเงินออกให้ รายการเดิมยังอยู่ในประวัติ', ok: 'ยกเลิกออเดอร์', danger: true });
      if (r) R.busy(null, async () => { await R.api('order.cancel', { order_id: o.id, reason: r.reason }); R.toast('ยกเลิกออเดอร์แล้ว'); done(); });
    });
    on(m.el.querySelector('#rf'), async () => {
      m.close();
      const r = await R.askReason('คืนเงิน ' + o.order_no, { amount: (Number(o.total) - Number(o.refunded)).toFixed(2), ok: 'บันทึกการคืนเงิน' });
      if (r) R.busy(null, async () => { await R.api('order.refund', { order_id: o.id, amount: r.amount, reason: r.reason }); R.toast('บันทึกการคืนเงินแล้ว'); done(); });
    });
  }
  R.orderSheet = orderSheet;
  const chIcon = (o) => (o.channel_kind === 'delivery' ? 'flow' : o.payment_method === 'cash' ? 'wallet' : 'receipt');
  const orderRow = (o) => R.row({ data: { o: o.id }, icon: chIcon(o), tone: o.status === 'cancelled' ? 'bad' : '', off: o.status === 'cancelled',
    t: esc(o.items.map((i) => (i.emoji ? i.emoji + ' ' : '') + i.product_name + (Number(i.qty) !== 1 ? ' ×' + qty(i.qty) : '')).join(', ')),
    s: `${R.time(o.created_at)} · ${esc(o.order_no)} · ${o.payment_method === 'mixed' ? 'จ่ายผสม' : esc(o.channel_name)}${o.replaces_no ? ' · แก้ไขแล้ว' : ''}${R.can('sales.view_all') ? ' · ' + esc(o.created_by_name) : ''}`,
    v: baht(o.total), pill: o.replaced_by ? '<span class="pill">ถูกแก้ไข</span>' : o.status !== 'paid' ? R.statusPill(o.status) : '' });

  // ------------------------------------------------------------ sell: channel buttons, product rows with steppers, received amount, today's list
  R.def('sell', { title: 'บันทึกการขาย', tab: 'sell', back: 'home' }, async function (el, arg) {
    const channels = B().channels, products = B().products;
    const edit = arg === 'edit' && R.state.editOrder ? R.state.editOrder : null;
    R.state.editOrder = null;
    const st = { channel: (edit && edit.channel_id) || R.store.get('channel') || (channels[0] && channels[0].id), lines: [], ref: R.uid(), cat: '', note: '', recv: null, recvNote: '', md: false, split: false, cash: null };
    if (edit) {
      st.lines = edit.items.map((i) => ({ product_id: i.product_id, qty: Number(i.qty), markdown: !!(i.promo_snapshot && i.promo_snapshot.rule === 'markdown') })).filter((l) => products.some((p) => p.id === l.product_id));
      st.note = (edit.note || '').split(' · ')[0]; st.md = st.lines.some((l) => l.markdown);
      if ((edit.payments || []).length > 1) { st.split = true; st.cash = Number((edit.payments.find((x) => x.method === 'cash') || {}).amount || 0); }
    }
    if (!channels.find((c) => c.id === st.channel) && channels[0]) st.channel = channels[0].id;
    const ch = () => channels.find((c) => c.id === st.channel);
    // evening markdown: products with a markdown price, storefront, from the set time (owner/manager any time)
    const mdFrom = R.settingVal('markdown_from', '') || '';
    const mdAllowed = () => ch() && ch().kind === 'storefront' && products.some((p) => p.markdown_price != null)
      && (R.can('master.manage') || (mdFrom && new Date().toLocaleTimeString('en-GB', { timeZone: 'Asia/Bangkok', hour: '2-digit', minute: '2-digit' }) >= mdFrom));
    const isMd = (p) => st.md && mdAllowed() && p.markdown_price != null && Number(p.markdown_price) < priceOf(p, ch());
    const accts = B().accounts || [], drawerAcc = accts.find((a) => a.is_drawer);
    const qrAcc = () => { const q = channels.find((c) => c.kind === 'storefront' && c.payment_method !== 'cash' && c.account_id); return (q && accts.find((a) => a.id === q.account_id)) || accts.find((a) => a.kind !== 'cash'); };
    const order = R.settingVal('product_categories', []) || [];
    const cats = [...new Set(products.map((p) => p.category).filter(Boolean))].sort((a, b) => ((order.indexOf(a) + 1) || 999) - ((order.indexOf(b) + 1) || 999));

    el.innerHTML = `${edit ? `<div class="note info">กำลังแก้ไขออเดอร์ ${esc(edit.order_no)} (${R.time(edit.created_at)}) · ระบบยกเลิกรายการเดิมและบันทึกรายการใหม่เวลาเดิม <a href="#/sell">ยกเลิกการแก้ไข</a></div>` : ''}
      <div class="pos-top"><div class="field"><span class="req">ช่องทาง / รับเงินทาง</span>${R.seg('ch', channels.map((c) => [c.id, c.name]), st.channel, 'wrap')}</div>
        <div id="mdbox"></div>
        ${cats.length > 1 ? `<div class="chips" id="cats"><button class="chip" data-cat="" aria-pressed="true">ทั้งหมด</button>${cats.map((c) => `<button class="chip" data-cat="${esc(c)}" aria-pressed="false">${esc(c)}</button>`).join('')}</div>` : ''}</div>
      <div class="prows" id="prods"></div>
      <div class="card" id="sum"></div>
      <div id="today"></div>
      ${R.actionbar(`<button class="btn" id="b-clear">ล้าง</button><button class="btn primary" id="b-save">${edit ? 'บันทึกแก้ไข' : 'บันทึก'} <b id="b-total" class="num">฿0.00</b></button>`)}`;

    function drawProducts() {
      const c = ch();
      const list = products.filter((p) => !st.cat || p.category === st.cat);
      el.querySelector('#mdbox').innerHTML = mdAllowed() ? `<button type="button" class="chip md-chip" id="md" aria-pressed="${st.md}">🌙 ราคาลดตอนเย็น${st.md ? ' · เปิดอยู่' : ''}</button>` : '';
      st.lines.forEach((l) => { l.markdown = isMd(products.find((p) => p.id === l.product_id)); });
      el.querySelector('#prods').innerHTML = list.length ? list.map((p) => {
        const l = st.lines.find((x) => x.product_id === p.id), ok = sellable(p, c);
        return `<div class="prow ${l ? 'in' : ''} ${ok ? '' : 'off'}"><span class="emo">${emo(p)}</span>
          <span><span class="nm">${esc(p.name)}</span><br><span class="pr">${!ok ? 'ไม่ขายทาง Delivery' : isMd(p) ? `<s class="muted">${money(priceOf(p, c))}</s> <b class="md-price">${baht(p.markdown_price)}</b> / ${esc(p.unit)} · ราคาลด` : `${baht(priceOf(p, c))} / ${esc(p.unit)}${c.kind === 'delivery' && p.delivery_price != null ? ' · ราคา Delivery' : ''}`}</span></span>
          ${ok ? `<span class="stepper"><button type="button" data-dec="${p.id}" aria-label="ลด ${esc(p.name)}" ${l ? '' : 'disabled'}>−</button><span class="n">${l ? qty(l.qty) : 0}</span><button type="button" data-inc="${p.id}" aria-label="เพิ่ม ${esc(p.name)}">+</button></span>` : '<span></span>'}</div>`;
      }).join('') : `<div class="empty">ยังไม่มีสินค้า${R.can('master.manage') ? ' เพิ่มได้ที่ เพิ่มเติม › ข้อมูลหลัก' : ''}</div>`;
    }
    function drawSum() {
      const c = ch(), t = calc(st.lines.filter((l) => sellable(B().products.find((p) => p.id === l.product_id), c)), c);
      const recv = st.recv == null ? t.total : st.recv;
      const box = el.querySelector('#sum');
      box.hidden = !st.lines.length;
      box.innerHTML = `<div>${t.rows.map((r) => `<div class="sum-row"><span>${emo(r.p)} ${esc(r.p.name)} × ${qty(r.l.qty)}${r.disc ? `<br><span class="muted small">${esc(r.promo ? r.promo.name : 'ส่วนลด')} −${money(r.disc)}</span>` : ''}</span><span>${money(r.gross - r.disc)}</span></div>`).join('')}
          ${t.disc ? `<div class="sum-row"><span>${t.rows.some((r) => r.l.markdown) ? "ส่วนลดรวม" : "ส่วนลดโปรโมชัน"}</span><span>−${money(t.disc)}</span></div>` : ''}
          <div class="sum-row total"><span>ยอดคำนวณ · ${esc(c.name)}</span><span>${baht(t.total)}</span></div></div>
        ${t.hints.length ? `<div class="note info">${t.hints.map(esc).join('<br>')}</div>` : ''}
        <label class="field"><span>ยอดรับจริง (แก้ได้ถ้าลูกค้าจ่ายไม่ตรง)</span><input type="number" id="recv" min="0" step="0.01" inputmode="decimal" class="input-amt" value="${recv}"></label>
        ${r2(recv) !== t.total ? `<label class="field"><span class="req">ทำไมยอดรับจริงต่างจากยอดคำนวณ ${money(r2(recv) - t.total)}</span><input type="text" id="recv-note" value="${esc(st.recvNote)}" placeholder="เช่น ปัดเศษให้ลูกค้า"></label>` : ''}
        ${c.kind === 'storefront' && drawerAcc && qrAcc() ? `<label class="check"><input type="checkbox" id="split" ${st.split ? 'checked' : ''}> จ่ายผสม เงินสด + ${esc(qrAcc().name)}</label>
          ${st.split ? `<div class="two"><label class="field"><span>เงินสด</span><input type="number" id="pcash" min="0" step="0.01" inputmode="decimal" value="${st.cash ?? ''}" placeholder="0"></label>
            <div class="field"><span>${esc(qrAcc().name)} (ที่เหลือ)</span><b class="num" style="padding:10px 0;font-size:1.1rem">${baht(Math.max(r2(recv - Number(st.cash || 0)), 0))}</b></div></div>
            ${Number(st.cash || 0) > recv ? '<div class="note bad">เงินสดมากกว่ายอดรับ</div>' : ''}` : ''}` : ''}
        <label class="field"><span>หมายเหตุ (ถ้ามี)</span><input type="text" id="note" value="${esc(st.note)}" placeholder="${c.kind === 'delivery' ? 'เลขออเดอร์ในแอป' : 'เช่น ลูกค้าประจำ'}"></label>`;
      document.getElementById('b-total').textContent = baht(recv);
      document.querySelector('.actionbar').hidden = !st.lines.length;
      return t;
    }
    const redraw = () => { drawProducts(); drawSum(); };
    redraw();

    el.querySelector('.seg').addEventListener('change', () => { st.channel = R.segVal(el, 'ch'); R.store.set('channel', st.channel); st.recv = null; redraw(); });
    const catsEl = el.querySelector('#cats');
    if (catsEl) catsEl.addEventListener('click', (ev) => {
      const b = ev.target.closest('[data-cat]'); if (!b) return;
      st.cat = b.dataset.cat; catsEl.querySelectorAll('[data-cat]').forEach((x) => x.setAttribute('aria-pressed', x === b)); drawProducts();
    });
    el.querySelector('#prods').addEventListener('click', (ev) => {
      const b = ev.target.closest('button'); if (!b) return;
      const id = b.dataset.inc || b.dataset.dec, l = st.lines.find((x) => x.product_id === id);
      if (b.dataset.inc) { if (l) l.qty += 1; else st.lines.push({ product_id: id, qty: 1 }); }
      if (b.dataset.dec && l) { l.qty -= 1; if (l.qty <= 0) st.lines.splice(st.lines.indexOf(l), 1); }
      st.recv = null; redraw();
    });
    el.querySelector('#sum').addEventListener('input', (ev) => {
      if (ev.target.id === 'note') st.note = ev.target.value;
      if (ev.target.id === 'recv-note') st.recvNote = ev.target.value;
    });
    el.querySelector('#sum').addEventListener('change', (ev) => {
      if (ev.target.id === 'recv') { st.recv = ev.target.value === '' ? null : Number(ev.target.value); drawSum(); }
      if (ev.target.id === 'split') { st.split = ev.target.checked; drawSum(); }
      if (ev.target.id === 'pcash') { st.cash = ev.target.value === '' ? null : Number(ev.target.value); drawSum(); }
    });
    el.querySelector('#mdbox').addEventListener('click', (ev) => { if (ev.target.closest('#md')) { st.md = !st.md; st.recv = null; redraw(); } });
    on(document.getElementById('b-clear'), () => { st.lines = []; st.recv = null; st.recvNote = ''; st.split = false; st.cash = null; redraw(); });
    document.getElementById('b-save').addEventListener('click', (ev) => R.busy(ev.currentTarget, async () => {
      const c = ch(), t = drawSum();
      if (!t.rows.length) throw new Error('ยังไม่มีสินค้าในออเดอร์');
      const recv = st.recv == null ? t.total : r2(st.recv);
      if (recv !== t.total && !st.recvNote.trim()) throw new Error('ยอดรับจริงไม่เท่ากับยอดคำนวณ ใส่เหตุผลก่อน');
      const payload = { channel_id: c.id, note: st.note, items: t.rows.map((r) => ({ product_id: r.p.id, qty: r.l.qty, ...(r.l.markdown ? { markdown: true } : {}) })),
        received_amount: recv !== t.total ? recv : null, received_note: recv !== t.total ? st.recvNote : null };
      if (st.split && c.kind === 'storefront') {
        const cash = r2(st.cash || 0);
        if (cash <= 0 || cash >= recv) throw new Error('จ่ายผสม: ใส่ยอดเงินสดมากกว่า 0 และน้อยกว่ายอดรับ ' + money(recv));
        payload.payments = [{ account_id: drawerAcc.id, amount: cash }, { account_id: qrAcc().id, amount: r2(recv - cash) }];
      }
      let o;
      if (edit) {
        const r = await R.askReason('เหตุผลที่แก้ไขออเดอร์ ' + edit.order_no, { ok: 'บันทึกการแก้ไข' });
        if (!r) return;
        o = await R.api('order.update', { ...payload, order_id: edit.id, reason: r.reason });
      } else {
        o = await R.saveOrder({ ...payload, client_ref: st.ref });
      }
      st.lines = []; st.ref = R.uid(); st.note = ''; st.recv = null; st.recvNote = ''; st.split = false; st.cash = null;
      success(el, o
        ? { title: edit ? 'แก้ไขออเดอร์แล้ว' : 'บันทึกออเดอร์แล้ว', sub: `${esc(o.order_no)} · ${esc(o.channel_name)} · ${R.time(o.created_at)} น.<br><b style="font-size:1.6rem;color:var(--ink)">${baht(o.total)}</b>`, actions: [{ label: 'ขายออเดอร์ถัดไป', href: '#/sell', primary: true }] }
        : { title: 'เก็บออเดอร์ไว้ในเครื่องแล้ว', sub: `ยอด ${baht(recv)} · ไม่มีสัญญาณ จะส่งเข้าระบบเองเมื่อมีสัญญาณ`, actions: [{ label: 'ขายออเดอร์ถัดไป', href: '#/sell', primary: true }] });
    }));

    // today's orders under the form, tap to edit / cancel
    if (navigator.onLine && R.can('sales.view') && !edit) {
      try {
        const list = await R.api('order.list', { from: R.today(), to: R.today() });
        const live = list.filter((o) => o.status !== 'cancelled');
        const box = el.querySelector('#today');
        box.innerHTML = R.sec(`รายการวันนี้ · ${live.length} ออเดอร์ · ${baht(live.reduce((s, o) => s + Number(o.total) - Number(o.refunded), 0))}`, '<a href="#/orders">ดูทั้งหมด</a>')
          + R.list(list.filter((o) => !o.replaced_by).slice(0, 30).map(orderRow), 'ยังไม่มีออเดอร์วันนี้');
        box.querySelectorAll('[data-o]').forEach((b) => b.addEventListener('click', () => orderSheet(list.find((x) => x.id === b.dataset.o), () => R.route())));
      } catch (e) { /* the form still works */ }
    }
  });

  // ------------------------------------------------------------ day picker used by lists
  function dayPicker(d) {
    const t = R.today(), y = R.addDays(t, -1), other = d !== t && d !== y;
    return `<div class="chips" id="days"><button class="chip" data-d="${t}" aria-pressed="${d === t}">วันนี้</button><button class="chip" data-d="${y}" aria-pressed="${d === y}">เมื่อวาน</button>
      <button class="chip" id="dpick-btn" aria-pressed="${other}">${other ? R.date(d) : 'เลือกวัน'}</button><input type="date" id="dpick" value="${d}" class="sr" aria-label="เลือกวัน"></div>`;
  }
  function bindDays(el, cb) {
    el.querySelectorAll('[data-d]').forEach((b) => b.addEventListener('click', () => cb(b.dataset.d)));
    const p = el.querySelector('#dpick');
    on(el.querySelector('#dpick-btn'), () => { try { p.showPicker(); } catch (e) { p.classList.remove('sr'); p.focus(); } });
    p.addEventListener('change', () => p.value && cb(p.value));
  }
  R.dayPicker = dayPicker; R.bindDays = bindDays;

  // ------------------------------------------------------------ orders of a day
  R.def('orders', { title: 'รายการขายรายวัน', back: 'sell' }, async function (el) {
    let d = R.today(), showEdited = false;
    async function draw() {
      const list = await R.api('order.list', { from: d, to: d });
      const live = list.filter((o) => o.status !== 'cancelled');
      const cancelled = list.filter((o) => o.status === 'cancelled' && !o.replaced_by).length, edited = list.filter((o) => o.replaced_by).length;
      const byCh = {};
      live.forEach((o) => { byCh[o.channel_name] = (byCh[o.channel_name] || 0) + Number(o.total) - Number(o.refunded); });
      el.innerHTML = `${dayPicker(d)}
        <div class="stats">${R.stat('ยอดขายสุทธิ', baht(live.reduce((s, o) => s + Number(o.total) - Number(o.refunded), 0)))}${R.stat('ออเดอร์', live.length, [cancelled ? 'ยกเลิก ' + cancelled : '', edited ? 'แก้ไข ' + edited : ''].filter(Boolean).join(' · '))}
          ${Object.entries(byCh).map(([k, v]) => R.stat(k, baht(v))).join('')}</div>
        ${edited ? `<label class="check small"><input type="checkbox" id="se" ${showEdited ? 'checked' : ''}> แสดงรายการเดิมที่ถูกแก้ไข (${edited})</label>` : ''}
        ${R.list(list.filter((o) => showEdited || !o.replaced_by).map(orderRow), 'ยังไม่มีออเดอร์ในวันนี้')}`;
      bindDays(el, (x) => { d = x; draw().catch(R.fail); });
      const se = el.querySelector('#se'); if (se) se.addEventListener('change', () => { showEdited = se.checked; draw().catch(R.fail); });
      el.querySelectorAll('[data-o]').forEach((b) => b.addEventListener('click', () => orderSheet(list.find((x) => x.id === b.dataset.o), () => draw().catch(R.fail))));
    }
    await draw();
  });

  // ------------------------------------------------------------ fund source block (expenses)
  function fundOptions() {
    const o = ['shop_cash', 'shop_bank', 'employee_advance', 'credit'];
    if (R.can('expense.pay')) o.splice(2, 0, 'other_account');
    if (R.can('cashflow.manage')) o.splice(o.length - 1, 0, 'owner_advance', 'owner_capital');
    return o;
  }
  function fundBlock(name, dflt) {
    const accounts = B().accounts.filter((a) => !a.is_drawer);
    const v = dflt || 'shop_cash';
    return `<div class="field"><span class="req">แหล่งเงินที่ใช้จ่าย</span><select id="${name}">${fundOptions().map((k) => `<option value="${k}" ${k === v ? 'selected' : ''}>${esc(R.FUND[k])}</option>`).join('')}</select>
        <span class="muted small" id="${name}-help">${esc(R.FUND_HELP[v])}</span></div>
      ${R.can('expense.pay') && accounts.length ? `<label class="field" id="${name}-accbox" hidden><span>จ่ายจากบัญชี</span><select id="${name}-acc">${R.opts(accounts)}</select></label>` : ''}
      <label class="field" id="${name}-refbox" hidden><span class="req">เลขอ้างอิง / เลขที่สลิป</span><input type="text" id="${name}-ref" placeholder="ดูจากสลิปโอน"></label>`;
  }
  function bindFund(root, name, onChange) {
    const sel = root.querySelector('#' + name);
    const upd = () => {
      const v = sel.value;
      root.querySelector(`#${name}-help`).textContent = R.FUND_HELP[v] || '';
      const box = root.querySelector(`#${name}-accbox`); if (box) box.hidden = !(v === 'other_account' || (v === 'shop_bank' && R.can('expense.pay')));
      root.querySelector(`#${name}-refbox`).hidden = !(v === 'shop_bank' || v === 'other_account');
      if (onChange) onChange(v);
    };
    sel.addEventListener('change', upd); upd();
  }
  const fundValue = (root, name) => ({ fund_source: R.val(root, '#' + name), account_id: R.val(root, `#${name}-acc`) || null, pay_ref: R.val(root, `#${name}-ref`) || null });

  // ------------------------------------------------------------ receive stock with transport allocation
  const ALLOC = { value: 'ตามมูลค่าสินค้า', weight: 'ตามน้ำหนัก', equal: 'เฉลี่ยเท่ากัน' };
  R.ALLOC = ALLOC;
  function allocate(lines, trans, method) {
    const basis = (l) => (method === 'value' ? l.total : method === 'weight' ? (l.weight || l.qty) : 1);
    let sum = lines.reduce((s, l) => s + basis(l), 0), m = method;
    if (sum <= 0) { m = 'equal'; sum = lines.length; }
    let rest = trans;
    return lines.map((l, i) => {
      const b = m === 'value' ? l.total : m === 'weight' ? (l.weight || l.qty) : 1;
      const a = i === lines.length - 1 ? r2(rest) : r2((trans * b) / sum); rest = r2(rest - a);
      return { ...l, alloc: a, landed: l.qty ? (l.total + a) / l.qty : 0 };
    });
  }
  R.def('receive', { title: 'รับสินค้า / ซื้อของเข้า', back: 'home' }, async function (el) {
    const items = B().stock_items, sups = B().suppliers;
    const aw = R.attachWidget('rcv', [['bill', 'บิล/ใบส่งของ'], ['receipt', 'ใบเสร็จ'], ['slip', 'สลิปโอน'], ['tax_invoice', 'ใบกำกับภาษี'], ['photo', 'รูปของที่รับ']], 'รูปบิล / สลิป', { required: true, noProof: true });
    const lines = [];
    const transDefault = Number(R.settingVal('transport_default', 0)) || 0;
    el.innerHTML = `${items.length ? '' : '<div class="note">ยังไม่มีรายการวัตถุดิบ ให้เจ้าของร้านเพิ่มที่ เพิ่มเติม › ข้อมูลหลัก</div>'}
      <form class="form" id="f" onsubmit="return false">
        <div class="card"><label class="field"><span class="req">ซื้อจาก</span><select id="sup"><option value="">พิมพ์ชื่อร้านเอง</option>${R.opts(sups)}</select></label>
          <label class="field" id="supname-box"><span class="req">ชื่อร้าน / แผง / คนที่ซื้อให้</span><input type="text" id="supname" placeholder="เช่น ตลาดไท แผง 12 หรือ เจ้าของซื้อมาให้"></label>
          <label class="check"><input type="checkbox" id="later"> ไม่รู้ราคา (เจ้าของใส่ราคาทีหลัง)</label>
          <p class="muted small" id="later-help" hidden>ของเข้าสต็อกเลย ใบนี้จะไปรอให้เจ้าของใส่ราคาและวิธีจ่าย</p></div>
        ${R.sec('ของที่รับ', '<button type="button" id="add">+ เพิ่มของ</button>')}
        <div id="lines"></div>
        <div class="card" id="trans-card"><h2>ค่าขนส่งรอบนี้</h2>
          <div class="two"><label class="field"><span>ค่าขนส่งทั้งรอบ (บาท)</span><input type="number" id="trans" min="0" step="0.01" inputmode="decimal" value="" placeholder="0"></label>
          <label class="field" ${R.can('expense.approve') ? '' : 'hidden'}><span>เฉลี่ยเข้าต้นทุน</span><select id="tm">${Object.entries(ALLOC).map(([k, l]) => `<option value="${k}" ${k === R.settingVal('transport_method', 'value') ? 'selected' : ''}>${l}</option>`).join('')}</select></label></div>
          ${transDefault ? `<button type="button" class="btn small" id="tdef">ใช้ค่ารอบตลาดปกติ ${baht(transDefault)}</button>` : ''}
          <p class="muted small">ค่าขนส่งถูกเฉลี่ยเข้าต้นทุนต่อหน่วยของของที่รับ (ต้นทุนถึงร้าน)</p></div>
        <div class="card" id="pay-card"><h2>จ่ายเงินอย่างไร</h2>
          <div class="field"><span class="req">วิธีจ่าย</span>${R.seg('pm', [['shop_bank', 'บัญชีร้าน'], ['shop_cash', 'เงินสดร้าน'], ['credit', 'เครดิต'], ['unpaid', 'ยังไม่จ่าย'], ['none', 'จ่ายรวมบิลอื่นแล้ว']], 'shop_cash', 'wrap')}</div>
          <div class="field"><span class="req">ใครออกเงินจริง</span>${R.seg('payer', [['shop', 'ร้าน'], ['owner', 'เจ้าของ'], ['employee', 'พนักงาน']], 'shop')}</div>
          <span class="muted small" id="pm-help"></span>
          <label class="field" id="pref-box" hidden><span class="req">เลขอ้างอิง / เลขที่สลิป</span><input type="text" id="pref"></label>
          ${aw.html}</div>
        <div class="card"><details><summary>เลขที่บิล วันเวลา หมายเหตุ</summary><div class="form" style="margin-top:10px">
            <label class="field"><span>เลขที่บิล / อ้างอิง</span><input type="text" id="ref"></label>
            <label class="field"><span>วันเวลาที่รับ</span><input type="datetime-local" id="at" value="${R.nowLocal()}"></label>
            <label class="field"><span>หมายเหตุ</span><input type="text" id="note"></label></div></details></div>
      </form>
      <div id="recent"></div>
      ${R.actionbar('<button class="btn primary" id="save">บันทึกรับสินค้า <b id="sum" class="num">฿0.00</b></button>')}`;
    const f = el.querySelector('#f');
    aw.bind(f);
    const later = () => f.querySelector('#later').checked;
    const payHelp = () => {
      const pm = R.segVal(f, 'pm'), payer = R.segVal(f, 'payer');
      f.querySelector('#pref-box').hidden = !(pm === 'shop_bank' && payer === 'shop');
      f.querySelector('#pm-help').textContent = payer === 'owner' ? 'เจ้าของออกเงินก่อน ระบบบันทึกยอดค้างคืนเจ้าของ'
        : payer === 'employee' ? 'พนักงานออกเงินก่อน ระบบบันทึกยอดค้างคืนพนักงาน รอเจ้าของอนุมัติ'
        : { shop_bank: 'โอน/สแกนจากบัญชีร้าน ใส่เลขอ้างอิง', shop_cash: 'เงินออกจากลิ้นชักวันนี้ หักให้ตอนปิดยอด', credit: 'ซื้อเชื่อ ค้างจ่ายร้านค้า', unpaid: 'ยังไม่ได้จ่าย บันทึกเป็นค้างจ่าย', none: 'จ่ายรวมในบิลอื่นแล้ว ไม่บันทึกเงินออกซ้ำ' }[pm];
    };
    f.querySelectorAll('.seg').forEach((s) => s.addEventListener('change', payHelp)); payHelp();
    const unitLabel = (l) => `${qty(l.qty)} ${esc(l.unit)}${l.unit !== l.base ? (l.factor ? ` (≈ ${qty(l.qty * l.factor)} ${esc(l.base)})` : ' · ยังไม่รู้ว่าเท่ากับกี่ ' + esc(l.base)) : ''}`;
    const drawLines = () => {
      const lt = later(), trans = lt ? 0 : Number(R.val(f, '#trans')) || 0, method = R.val(f, '#tm');
      f.querySelector('#trans-card').hidden = lt; f.querySelector('#pay-card').hidden = lt; f.querySelector('#later-help').hidden = !lt;
      const goods = lt ? 0 : lines.reduce((s, l) => s + l.total, 0);
      f.querySelector('#lines').innerHTML = lines.length ? R.list(lines.map((l, i) => R.row({ data: { li: i }, icon: 'box', t: esc(l.name),
        s: unitLabel(l) + (l.weight ? ' · ' + qty(l.weight) + ' กก.' : ''), v: lt ? '<span class="muted small">รอราคา</span>' : money(l.total), vs: 'แตะเพื่อลบ', chev: false })))
          + (lt ? '' : `<div class="sum-row"><span>ค่าของ</span><span>${money(goods)}</span></div>${trans ? `<div class="sum-row"><span>ค่าขนส่ง (${esc(ALLOC[method])})</span><span>${money(trans)}</span></div>` : ''}`)
        : `<button type="button" class="photo-btn" id="add2" style="width:100%">${R.icon('plus')} เพิ่มของที่รับเข้า</button>`;
      document.getElementById('sum').textContent = lt ? 'รอราคา' : baht(goods + trans);
      f.querySelectorAll('[data-li]').forEach((b) => b.addEventListener('click', () => { lines.splice(b.dataset.li, 1); drawLines(); }));
      on(f.querySelector('#add2'), addLine);
    };
    function addLine() {
      const lt = later();
      const m = R.modal('เพิ่มของที่รับ', `<form class="form">
        <label class="field"><span class="req">รายการ</span><select id="it" required><option value="">เลือก…</option>${R.opts(items, null, (x) => (x.code ? x.code + ' · ' : '') + x.name)}</select></label>
        <div class="two"><label class="field"><span class="req">จำนวน</span><input type="number" id="q" min="0" step="any" inputmode="decimal" required></label>
          <label class="field"><span class="req">หน่วยที่ซื้อ</span><select id="u"></select></label></div>
        <label class="field" id="unew-box" hidden><span class="req">ชื่อหน่วย</span><input type="text" id="unew" placeholder="เช่น หวี ลูก เข่ง แพ็ก ถุง"></label>
        <label class="field" id="fac-box" hidden><span id="fac-l">1 หน่วยนี้ ≈ กี่</span><input type="number" id="fac" min="0" step="any" inputmode="decimal" placeholder="ไม่รู้ เว้นไว้ได้"></label>
        <p class="muted small" id="fac-help" hidden>ไม่รู้ก็เว้นไว้ บิลบันทึกได้ปกติ เจ้าของใส่ทีหลัง แล้วระบบเพิ่มสต็อกให้</p>
        ${lt ? '' : '<label class="field"><span class="req">ราคารวมรายการนี้ (บาท)</span><input type="number" id="t" min="0.01" step="0.01" inputmode="decimal" required></label>'}
        <details><summary>น้ำหนัก (ถ้าเฉลี่ยค่าขนส่งตามน้ำหนัก)</summary><label class="field"><span>น้ำหนัก กก.</span><input type="number" id="w" min="0" step="any" inputmode="decimal"></label></details>
        <button class="btn primary lg">เพิ่มในรายการ</button></form>`);
      const sel = m.el.querySelector('#u');
      const cur = () => items.find((x) => x.id === R.val(m.el, '#it'));
      const fillUnits = () => {
        const it = cur();
        sel.innerHTML = it ? [`<option value="${esc(it.unit)}">${esc(it.unit)}</option>`, ...(it.count_units || []).filter((x) => x.unit).map((x) => `<option value="${esc(x.unit)}">${esc(x.unit)}${Number(x.factor) > 0 ? ` (≈ ${qty(x.factor)} ${esc(it.unit)})` : ''}</option>`), '<option value="__new">หน่วยอื่น…</option>'].join('') : '<option value="">เลือกรายการก่อน</option>';
        unitBox();
      };
      const unitBox = () => {
        const it = cur(), u = sel.value === '__new' ? R.val(m.el, '#unew') : sel.value, known = it && (u === it.unit || (it.count_units || []).some((x) => x.unit === u && Number(x.factor) > 0));
        m.el.querySelector('#unew-box').hidden = sel.value !== '__new';
        m.el.querySelector('#fac-box').hidden = m.el.querySelector('#fac-help').hidden = !it || !u || known;
        if (it) m.el.querySelector('#fac-l').textContent = `1 ${u || 'หน่วยนี้'} ≈ กี่ ${it.unit} (ถ้ารู้)`;
      };
      m.el.querySelector('#it').addEventListener('change', fillUnits); sel.addEventListener('change', unitBox); m.el.querySelector('#unew').addEventListener('input', unitBox); fillUnits();
      m.el.querySelector('form').addEventListener('submit', (ev) => {
        ev.preventDefault();
        const it = cur(), q = Number(R.val(m.el, '#q')), u = (sel.value === '__new' ? R.val(m.el, '#unew') : sel.value).trim();
        if (!it || !(q > 0) || !u) return R.fail(new Error('เลือกรายการ ใส่จำนวน และหน่วยที่ซื้อ'));
        const known = (it.count_units || []).find((x) => x.unit === u && Number(x.factor) > 0), fac = Number(R.val(m.el, '#fac')) || null;
        const total = lt ? 0 : Number(R.val(m.el, '#t')) || 0;
        if (!lt && !(total > 0)) return R.fail(new Error('ใส่ราคา หรือกลับไปติ๊ก "ไม่รู้ราคา"'));
        lines.push({ stock_item_id: it.id, name: it.name, base: it.unit, unit: u, qty: q, factor: u === it.unit ? 1 : (known ? Number(known.factor) : fac), new_factor: u !== it.unit && !known ? fac : null, total, weight: Number(R.val(m.el, '#w')) || null });
        m.close(); drawLines();
      });
    }
    drawLines();
    on(f.querySelector('#add'), addLine);
    f.querySelector('#later').addEventListener('change', drawLines);
    on(f.querySelector('#tdef'), () => { f.querySelector('#trans').value = transDefault; drawLines(); });
    f.querySelector('#trans').addEventListener('input', drawLines); f.querySelector('#tm').addEventListener('change', drawLines);
    f.querySelector('#sup').addEventListener('change', () => { f.querySelector('#supname-box').hidden = !!R.val(f, '#sup'); });
    document.getElementById('save').addEventListener('click', (ev) => R.busy(ev.currentTarget, async () => {
      if (!R.val(f, '#sup') && !R.val(f, '#supname')) throw new Error('ใส่ว่าซื้อจากร้านไหน / ใคร');
      if (!lines.length) throw new Error('เพิ่มของที่รับอย่างน้อย 1 รายการ');
      const lt = later(), pm = R.segVal(f, 'pm'), payer = R.segVal(f, 'payer');
      if (!lt) {
        aw.check(f);
        if (pm === 'shop_bank' && payer === 'shop' && !R.val(f, '#pref')) throw new Error('จ่ายจากบัญชีร้าน ใส่เลขอ้างอิงด้วย');
      }
      const r = await R.api('receipt.create', { supplier_id: R.val(f, '#sup') || null, supplier_name: R.val(f, '#supname'), ref_no: R.val(f, '#ref'),
        received_at: R.toIso(R.val(f, '#at')), note: R.val(f, '#note'), attachment_ids: aw.ids(), no_evidence_reason: lt ? null : aw.reason(f), price_later: lt,
        transport_cost: lt ? 0 : Number(R.val(f, '#trans')) || 0, transport_method: R.val(f, '#tm'),
        pay_method: lt ? null : pm, payer, pay_ref: R.val(f, '#pref'),
        lines: lines.map((l) => ({ stock_item_id: l.stock_item_id, qty: l.qty, unit: l.unit, factor: l.new_factor, line_total: l.total, weight: l.weight })) });
      success(el, { title: lt ? 'บันทึกรับของแล้ว รอเจ้าของใส่ราคา' : 'บันทึกรับสินค้าแล้ว', sub: `${esc(r.receipt_no)} · ${r.lines.length} รายการ${lt ? '' : ' · ' + baht(r.total_cost)}${r.expense ? '<br>ค่าใช้จ่าย: ' + esc(r.expense.status) : ''}${r.needs === 'unit' ? '<br>บางรายการรอเจ้าของใส่ขนาดหน่วย' : ''}`,
        actions: [{ label: 'กลับหน้าหลัก', href: '#/home' }, { label: 'รับของอีกบิล', href: '#/receive', primary: true }] });
    }));
    if (R.can('stock.view')) {
      const list = await R.api('receipt.list', {});
      el.querySelector('#recent').innerHTML = R.sec(R.can('expense.approve') ? 'รับของล่าสุด' : 'ที่ฉันรับ 30 วัน') + R.list(list.slice(0, 15).map((r) => R.row({ data: { r: r.id }, icon: 'box', off: r.status === 'cancelled',
        t: esc(r.supplier_name || 'ไม่ระบุร้าน'), s: `${R.dt(r.received_at)} · ${r.lines.length} รายการ${Number(r.transport_cost) ? ' · ขนส่ง ' + money(r.transport_cost) : ''}`, v: r.price_pending ? 'รอราคา' : baht(r.total_cost), pill: r.status === 'cancelled' ? R.statusPill(r.status) : R.receiptNeedsPill(r) })), 'ยังไม่มีการรับของใน 30 วัน');
      el.querySelectorAll('[data-r]').forEach((b) => b.addEventListener('click', () => receiptSheet(list.find((x) => x.id === b.dataset.r))));
    }
  });
  const PAYER = { shop: 'ร้าน', owner: 'เจ้าของ', employee: 'พนักงาน' }, PM = { shop_bank: 'บัญชีร้าน', shop_cash: 'เงินสดร้าน', credit: 'เครดิต', unpaid: 'ยังไม่จ่าย' };
  const NEEDS = { price: ['warn', 'รอใส่ราคา'], unit: ['warn', 'รอใส่ตัวแปลงหน่วย'], review: ['', 'รอตรวจ'] };
  R.receiptNeedsPill = (r) => (r.needs && NEEDS[r.needs] ? `<span class="pill ${NEEDS[r.needs][0]}">${NEEDS[r.needs][1]}</span>` : '');
  function receiptSheet(r, done) {
    done = done || (() => R.route());
    const owner = R.can('expense.approve'), live = r.status !== 'cancelled';
    const lineRow = (l) => `<div class="sum-row"><span>${esc(l.item_name)} ${qty(l.buy_qty ?? l.qty)} ${esc(l.buy_unit || l.unit)}${l.buy_unit && l.buy_unit !== l.stock_unit ? (l.unit_pending ? ` <span class="pill warn">ยังไม่รู้ว่าเท่ากับกี่ ${esc(l.stock_unit)}</span>` : ` <span class="muted small">= ${qty(l.qty)} ${esc(l.stock_unit)}</span>`) : ''}${Number(l.transport_alloc) ? `<br><span class="muted small">+ ขนส่ง ${money(l.transport_alloc)}${l.landed_unit_cost ? ' · ต้นทุนถึงร้าน ' + money(l.landed_unit_cost) + '/' + esc(l.stock_unit) : ''}</span>` : ''}</span><span>${r.price_pending ? '<span class="muted small">รอราคา</span>' : money(l.line_total)}</span></div>`;
    const m = R.modal(r.receipt_no, `<div class="muted small">${R.dt(r.received_at)} · ${esc(r.supplier_name || '-')}${r.ref_no ? ' · บิล ' + esc(r.ref_no) : ''} · โดย ${esc(r.created_by_name)}</div>
      ${R.receiptNeedsPill(r)}
      <div>${r.lines.map(lineRow).join('')}
        ${Number(r.transport_cost) ? `<div class="sum-row"><span>ค่าขนส่ง (${esc(ALLOC[r.transport_method] || '')})</span><span>${money(r.transport_cost)}</span></div>` : ''}
        ${r.price_pending ? '' : `<div class="sum-row total"><span>รวม</span><span>${baht(r.total_cost)}</span></div>`}</div>
      ${r.pay_method || r.payer ? `<p class="muted small">จ่ายโดย ${esc(PM[r.pay_method] || r.pay_method || '-')} · ผู้ออกเงิน ${esc(PAYER[r.payer] || r.payer || '-')}</p>` : ''}
      ${r.no_evidence_reason ? `<p class="muted small">ไม่มีบิล: ${esc(r.no_evidence_reason)}</p>` : ''}
      ${r.expense ? `<p>ค่าใช้จ่าย ${esc(r.expense.expense_no)} ${R.statusPill(r.expense.status)}</p>` : ''}${R.attachLinks(r.attachments)}
      ${r.reviewed_at && r.reviewed_by_name ? `<p class="muted small">ตรวจแล้วโดย ${esc(r.reviewed_by_name)} ${R.dt(r.reviewed_at)}</p>` : ''}
      ${r.cancel_reason ? `<div class="note">ยกเลิก: ${esc(r.cancel_reason)}</div>` : ''}
      <div class="btn-row">${owner && live && r.needs === 'price' ? '<button class="btn primary lg" id="sp">ใส่ราคา</button>' : ''}
        ${owner && live && r.needs === 'unit' && R.can('master.manage') ? '<button class="btn primary lg" id="su">ใส่ตัวแปลงหน่วย</button>' : ''}
        ${owner && live && r.needs === 'review' ? '<button class="btn primary lg" id="rv">ตรวจแล้ว ถูกต้อง</button>' : ''}</div>
      ${R.can('stock.cancel') && live ? `<button class="btn danger" id="x">${owner && r.needs === 'review' ? 'ผิด: ยกเลิกแล้วลงใหม่' : 'ยกเลิกใบรับของ'}</button>` : ''}${R.purgeBtn(r.status === 'cancelled')}`);
    R.purge(m.el, 'receipt', r.id, 'ใบรับของ ' + r.receipt_no, () => { m.close(); done(); });
    on(m.el.querySelector('#rv'), (ev) => R.busy(ev.currentTarget, async () => { await R.api('receipt.review', { receipt_id: r.id }); m.close(); R.toast('ตรวจแล้ว'); done(); }));
    on(m.el.querySelector('#sp'), () => { m.close(); priceSheet(r, done); });
    on(m.el.querySelector('#su'), () => { m.close(); unitSheet(r, done); });
    on(m.el.querySelector('#x'), async () => {
      m.close();
      const x = await R.askReason('ยกเลิกใบรับของ', { text: 'สต็อกจะถูกตัดออก และค่าใช้จ่ายที่ผูกไว้จะถูกยกเลิกด้วย ถ้าลงผิด ให้ลงใบใหม่ที่ถูกต้องหลังยกเลิก', danger: true, ok: 'ยกเลิกใบรับของ' });
      if (x) R.busy(null, async () => { await R.api('receipt.cancel', { receipt_id: r.id, reason: x.reason }); R.toast('ยกเลิกแล้ว'); done(); });
    });
  }
  // owner: price of a "ไม่รู้ราคา" receipt and how it was paid
  function priceSheet(r, done) {
    const aw = R.attachWidget('rp', [['slip', 'สลิปโอน'], ['bill', 'บิล/ใบส่งของ'], ['receipt', 'ใบเสร็จ']], 'รูปบิล / สลิป', { required: true, noProof: true });
    const m = R.modal('ใส่ราคา ' + r.receipt_no, `<form class="form" onsubmit="return false">
      ${r.lines.map((l) => `<label class="field"><span class="req">${esc(l.item_name)} ${qty(l.buy_qty ?? l.qty)} ${esc(l.buy_unit || l.unit)} ราคารวม (บาท)</span><input type="number" data-lp="${l.id}" min="0.01" step="0.01" inputmode="decimal" required></label>`).join('')}
      <label class="field"><span>ค่าขนส่ง (บาท)</span><input type="number" id="tr" min="0" step="0.01" inputmode="decimal" placeholder="0"></label>
      <div class="field"><span class="req">วิธีจ่าย</span>${R.seg('ppm', [['shop_bank', 'บัญชีร้าน'], ['shop_cash', 'เงินสดร้าน'], ['credit', 'เครดิต'], ['unpaid', 'ยังไม่จ่าย'], ['none', 'จ่ายรวมบิลอื่นแล้ว']], 'shop_bank', 'wrap')}</div>
      <div class="field"><span class="req">ใครออกเงินจริง</span>${R.seg('ppay', [['shop', 'ร้าน'], ['owner', 'เจ้าของ'], ['employee', 'พนักงาน']], 'owner')}</div>
      <label class="field"><span>เลขอ้างอิง / เลขที่สลิป</span><input type="text" id="pr"></label>
      ${aw.html}<div class="sum-row total"><span>รวม</span><b id="ptot">฿0.00</b></div>
      <button class="btn primary lg" id="ok">บันทึกราคา</button></form>`);
    aw.bind(m.el);
    const tot = () => { m.el.querySelector('#ptot').textContent = baht([...m.el.querySelectorAll('[data-lp]')].reduce((s, i) => s + (Number(i.value) || 0), 0) + (Number(R.val(m.el, '#tr')) || 0)); };
    m.el.querySelectorAll('input').forEach((i) => i.addEventListener('input', tot));
    on(m.el.querySelector('#ok'), (ev) => R.busy(ev.currentTarget, async () => {
      const lines = [...m.el.querySelectorAll('[data-lp]')].map((i) => ({ id: i.dataset.lp, line_total: Number(i.value) || 0 }));
      if (lines.some((l) => !(l.line_total > 0))) throw new Error('ใส่ราคาให้ครบทุกรายการ');
      aw.check(m.el);
      const pm = R.segVal(m.el, 'ppm'), payer = R.segVal(m.el, 'ppay');
      if (pm === 'shop_bank' && payer === 'shop' && !R.val(m.el, '#pr')) throw new Error('จ่ายจากบัญชีร้าน ใส่เลขอ้างอิงด้วย');
      await R.api('receipt.set_price', { receipt_id: r.id, lines, transport_cost: Number(R.val(m.el, '#tr')) || 0, pay_method: pm, payer, pay_ref: R.val(m.el, '#pr'), attachment_ids: aw.ids(), no_evidence_reason: aw.reason(m.el) });
      m.close(); R.toast('บันทึกราคาแล้ว ค่าใช้จ่ายและต้นทุนอัปเดตแล้ว'); done();
    }));
  }
  // owner: how big is the unit the staff bought in (1 หวี ≈ x กก.)
  function unitSheet(r, done) {
    const wait = r.lines.filter((l) => l.unit_pending);
    const m = R.modal('ใส่ตัวแปลงหน่วย', `<form class="form" onsubmit="return false"><p class="muted small">ใส่ครั้งเดียว ระบบจำไว้ใช้กับการรับของครั้งต่อไป และเพิ่มสต็อกที่รอไว้ให้</p>
      ${wait.map((l, i) => `<label class="field"><span class="req">1 ${esc(l.buy_unit)} ของ ${esc(l.item_name)} ≈ กี่ ${esc(l.stock_unit)}</span><input type="number" data-uf="${i}" min="0" step="any" inputmode="decimal" required></label>`).join('')}
      <button class="btn primary lg" id="ok">บันทึก</button></form>`);
    on(m.el.querySelector('#ok'), (ev) => R.busy(ev.currentTarget, async () => {
      for (const [i, l] of wait.entries()) {
        const fv = Number(m.el.querySelector(`[data-uf="${i}"]`).value);
        if (!(fv > 0)) throw new Error('ใส่ขนาดของ ' + l.buy_unit + ' ให้ครบ');
        await R.api('stock.unit_set', { stock_item_id: l.stock_item_id, unit: l.buy_unit, factor: fv });
      }
      m.close(); R.toast('บันทึกแล้ว สต็อกอัปเดตแล้ว'); done();
    }));
  }
  R.receiptSheet = receiptSheet;

  // ------------------------------------------------------------ waste (by product, or by raw material)
  const reasons = () => R.settingVal('waste_reasons', ['เสีย/เน่า', 'หล่น/เสียหาย', 'เหลือขายไม่หมด', 'ทดลองชิม', 'อื่น ๆ']);
  function wasteForm(prefix) {
    const req = !!R.settingVal('waste_evidence_required', false);
    const aw = R.attachWidget(prefix, [['photo', 'รูปของเสีย']], 'รูปของเสีย', { required: req });
    const prods = B().products, items = B().stock_items, users = B().users || [];
    const st = { by: 'product', id: '' };
    const unitOf = () => { const x = (st.by === 'product' ? prods : items).find((y) => y.id === st.id); return x ? x.unit : ''; };
    return {
      aw,
      html: `${R.seg(prefix + '-kind', [['waste', R.WASTE_KIND.waste], ['staff_meal', R.WASTE_KIND.staff_meal]], 'waste')}
        <p class="muted small" id="${prefix}-khelp"></p>
        <div class="field" id="${prefix}-pbox"><span class="req">สินค้า</span><div class="ptiles">${prods.map((p) => `<button type="button" data-wp="${p.id}" aria-pressed="false"><span class="e">${emo(p)}</span><span>${esc(p.name)}</span></button>`).join('')}</div>
          <button type="button" class="linkbtn" id="${prefix}-toitem">เลือกวัตถุดิบแทน</button></div>
        <label class="field" id="${prefix}-ibox" hidden><span class="req">วัตถุดิบ</span><select id="${prefix}-item"><option value="">เลือก…</option>${R.opts(items, null, (x) => x.name + ' (' + x.unit + ')')}</select>
          <button type="button" class="linkbtn" id="${prefix}-toprod">กลับไปเลือกสินค้า</button></label>
        <div class="field"><span class="req">จำนวน <span id="${prefix}-unit" class="muted small"></span></span>
          <div class="qstep"><button type="button" data-q="-1" aria-label="ลดจำนวน">−</button><input type="number" id="${prefix}-qty" min="0" step="any" inputmode="decimal" value="1" aria-label="จำนวน"><button type="button" data-q="1" aria-label="เพิ่มจำนวน">+</button></div></div>
        <label class="field" id="${prefix}-ubox" hidden><span>ของใคร (ไม่บังคับ)</span><select id="${prefix}-for"><option value="">ทีมงาน (ไม่ระบุ)</option>${R.opts(users.filter((x) => x.role !== 'admin'), null, (x) => x.display_name)}</select></label>
        <div class="field" id="${prefix}-rbox"><span class="req">สาเหตุ</span><div class="chips" style="flex-wrap:wrap">${reasons().map((r) => `<button type="button" class="chip" data-reason="${esc(r)}" aria-pressed="false">${esc(r)}</button>`).join('')}</div>
          <input type="text" id="${prefix}-reason" placeholder="หรือพิมพ์สาเหตุ"></div>
        <div id="${prefix}-awbox">${aw.html}</div>`,
      bind(root) {
        aw.bind(root);
        const $ = (id) => root.querySelector('#' + prefix + id);
        const unit = () => { $('-unit').textContent = unitOf() ? '(' + unitOf() + ')' : ''; };
        const kind = () => {
          const k = R.segVal(root, prefix + '-kind');
          $('-rbox').hidden = k !== 'waste'; $('-awbox').hidden = k !== 'waste'; $('-ubox').hidden = k !== 'staff_meal';
          $('-khelp').textContent = R.WASTE_HELP[k];
        };
        root.querySelector(`input[name="${prefix}-kind"]`).closest('.seg').addEventListener('change', kind); kind();
        root.querySelectorAll('[data-wp]').forEach((b) => b.addEventListener('click', () => {
          st.by = 'product'; st.id = b.dataset.wp; root.querySelectorAll('[data-wp]').forEach((x) => x.setAttribute('aria-pressed', x === b)); unit();
        }));
        $('-toitem').addEventListener('click', () => { st.by = 'item'; st.id = R.val(root, '#' + prefix + '-item'); $('-pbox').hidden = true; $('-ibox').hidden = false; unit(); });
        $('-toprod').addEventListener('click', () => { st.by = 'product'; st.id = (root.querySelector('[data-wp][aria-pressed=true]') || {}).dataset?.wp || ''; $('-pbox').hidden = false; $('-ibox').hidden = true; unit(); });
        $('-item').addEventListener('change', () => { st.id = R.val(root, '#' + prefix + '-item'); unit(); });
        root.querySelectorAll('[data-q]').forEach((b) => b.addEventListener('click', () => {
          const i = $('-qty'); i.value = Math.max(0, r2(Number(i.value || 0) + Number(b.dataset.q)));
        }));
        root.querySelectorAll('[data-reason]').forEach((b) => b.addEventListener('click', () => {
          $('-reason').value = b.dataset.reason;
          root.querySelectorAll('[data-reason]').forEach((x) => x.setAttribute('aria-pressed', x === b));
        }));
      },
      payload: (root) => {
        const k = R.segVal(root, prefix + '-kind');
        if (k === 'waste' && aw.required() && !aw.ids().length) throw new Error('ร้านกำหนดให้แนบรูปของเสียทุกครั้ง');
        if (!st.id) throw new Error(st.by === 'product' ? 'แตะเลือกสินค้า' : 'เลือกวัตถุดิบ');
        if (!(Number(R.val(root, `#${prefix}-qty`)) > 0)) throw new Error('จำนวนต้องมากกว่า 0');
        if (k === 'waste' && !R.val(root, `#${prefix}-reason`)) throw new Error('เลือกหรือพิมพ์สาเหตุของเสีย');
        return { kind: k, [st.by === 'product' ? 'product_id' : 'stock_item_id']: st.id, qty: R.val(root, `#${prefix}-qty`), reason: k === 'waste' ? R.val(root, `#${prefix}-reason`) : '',
          for_user_id: k === 'staff_meal' ? R.val(root, `#${prefix}-for`) || null : null, attachment_ids: k === 'waste' ? aw.ids() : [],
          _label: (st.by === 'product' ? prods : items).find((x) => x.id === st.id) };
      },
    };
  }
  R.wasteForm = wasteForm;
  // owner_use is no longer offered in the form; the label stays for records made before
  R.WASTE_KIND = { waste: 'ของเสีย', staff_meal: 'สวัสดิการทีมงาน', owner_use: 'เจ้าของหยิบใช้' };
  R.WASTE_HELP = { waste: 'ของเน่า หล่น เหลือขายไม่หมด นับเป็นของเสียของร้าน',
    staff_meal: 'ของที่ทีมงานกินหรือใช้ ตัดสต็อกและนับเป็นค่าสวัสดิการทีมงาน ไม่นับเป็นของเสีย',
    owner_use: 'เจ้าของหยิบไปใช้เอง ตัดสต็อก ไม่นับเป็นต้นทุนร้าน แต่นับเป็นเงินที่เจ้าของเอาออกแล้ว (ราคาทุน)' };

  R.def('waste', { title: 'ของเสีย / สวัสดิการ', back: 'home' }, async function (el) {
    const wf = wasteForm('w');
    el.innerHTML = `<form class="card form" id="f" onsubmit="return false">${wf.html}</form><div id="recent"></div>${R.actionbar('<button class="btn primary" id="save">บันทึก</button>')}`;
    const f = el.querySelector('#f'); wf.bind(f);
    document.getElementById('save').addEventListener('click', (ev) => R.busy(ev.currentTarget, async () => {
      if (!f.reportValidity()) return;
      const p = wf.payload(f); delete p._label;
      await R.api('waste.create', p);
      success(el, { title: 'บันทึก' + R.WASTE_KIND[p.kind] + 'แล้ว', actions: [{ label: 'กลับหน้าหลัก', href: '#/home' }, { label: 'บันทึกอีกรายการ', href: '#/waste', primary: true }] });
    }));
    if (R.can('stock.view')) {
      const list = await R.api('waste.list', { from: R.addDays(R.today(), -7) });
      el.querySelector('#recent').innerHTML = R.sec('7 วันล่าสุด') + R.list(list.map((w) => R.row({ data: { w: w.id }, icon: 'trash', tone: 'warn', off: w.status === 'cancelled',
        t: `${esc(w.item_name)} ${qty(w.qty)} ${esc(w.unit)}`, s: `${R.dt(w.occurred_at)} · ${esc(w.reason)} · ${esc(w.created_by_name)}${w.close_id ? ' · จากปิดยอด' : ''}`,
        pill: w.kind && w.kind !== 'waste' ? `<span class="pill">${R.WASTE_KIND[w.kind]}</span>` : '', chev: R.can('stock.cancel') && (w.status !== 'cancelled' || R.canPurge()) })), 'ยังไม่มีของเสียใน 7 วัน');
      if (R.can('stock.cancel')) el.querySelectorAll('[data-w]').forEach((b) => b.addEventListener('click', async () => {
        const w = list.find((x) => x.id === b.dataset.w);
        if (w.status === 'cancelled') {
          if (!R.canPurge()) return;
          const m = R.modal('รายการที่ยกเลิกแล้ว', `<p>${esc(w.item_name)} ${qty(w.qty)} ${esc(w.unit)}</p><div class="note">ยกเลิก: ${esc(w.cancel_reason || '')}</div><div class="btn-row">${R.purgeBtn(true)}</div>`);
          R.purge(m.el, 'waste', w.id, `${w.item_name} ${qty(w.qty)} ${w.unit}`, () => { m.close(); R.route(); });
          return;
        }
        const r = await R.askReason('ยกเลิกรายการของเสีย', { text: `${w.item_name} ${qty(w.qty)} ${w.unit} · ระบบคืนสต็อกให้`, danger: true, ok: 'ยกเลิกรายการ' });
        if (r) R.busy(null, async () => { await R.api('waste.cancel', { waste_id: w.id, reason: r.reason }); R.route(); });
      }));
    }
  });

  // ------------------------------------------------------------ expense with receipt / slip reader
  R.def('expense', { title: 'บันทึกค่าใช้จ่าย', back: 'home' }, async function (el) {
    const evReq = !!R.settingVal('evidence_required', false);
    const aw = R.attachWidget('exp', [['receipt', 'ใบเสร็จ'], ['tax_invoice', 'ใบกำกับภาษี'], ['bill', 'บิลเงินสด'], ['slip', 'สลิปโอน'], ['substitute', 'ใบรับรองแทนใบเสร็จ'], ['photo', 'รูปถ่าย']], 'หลักฐาน (ใบเสร็จ / สลิป / บิล)', { required: true, noProof: true });
    const cats = B().categories;
    el.innerHTML = `<form class="form" id="f" onsubmit="return false">
        <div class="card">${aw.html}
          <button type="button" class="btn" id="ocr" hidden>${R.icon('eye')} ให้ระบบอ่านยอดจากรูป</button><span class="muted small" id="ocr-status"></span>
          <div class="note info" id="ocr-note" hidden>ช่องกรอบสีฟ้าอ่านมาจากรูป อาจคลาดเคลื่อน ตรวจให้ตรงกับเอกสารก่อนบันทึก
            <label class="check"><input type="checkbox" id="ocr-ok"> ตรวจแล้ว ถูกต้อง</label></div></div>
        <div class="card">
          <label class="field"><span class="req">จำนวนเงิน (บาท)</span><input type="number" id="amt" min="0.01" step="0.01" inputmode="decimal" class="input-amt" placeholder="0.00" required></label>
          <label class="field"><span class="req">จ่ายค่าอะไร</span><input type="text" id="desc" required placeholder="เช่น น้ำแข็ง 2 ถุง"></label>
          <label class="field"><span class="req">หมวด</span><select id="cat" required>${R.catOptions(cats)}</select></label>
          <div id="catx"></div>
          <div id="fundwrap" class="form" style="gap:inherit">${fundBlock('fund')}</div>
          <details><summary>จ่ายให้ใคร วันเวลา เลขที่เอกสาร</summary><div class="form" style="margin-top:10px">
            <label class="field"><span>จ่ายให้ (ร้าน / บุคคล)</span><input type="text" id="payee"></label>
            <label class="field"><span>วันเวลาที่จ่าย</span><input type="datetime-local" id="at" value="${R.nowLocal()}"></label>
            <label class="field"><span>ครบกำหนดจ่าย (ถ้าค้างจ่าย)</span><input type="date" id="due"></label>
            <label class="field"><span>ชนิดเอกสาร</span><select id="doct"><option value="receipt">ใบเสร็จ</option><option value="tax_invoice">ใบกำกับภาษี</option><option value="bill">บิลเงินสด</option><option value="slip">สลิปโอน</option><option value="substitute">ใบรับรองแทนใบเสร็จ</option><option value="none">ไม่มีเอกสาร</option></select></label>
            <label class="field"><span>เลขที่เอกสาร</span><input type="text" id="docno"></label></div></details></div>
      </form>
      <div id="mine"></div>
      ${R.actionbar('<button class="btn primary" id="save">บันทึกค่าใช้จ่าย</button>')}`;
    const f = el.querySelector('#f');
    bindFund(f, 'fund', (v) => aw.setRequired(f, v !== 'credit'));
    // wages are paid from workdays (no hand counting); a wage advance needs the person
    const catx = () => {
      const c = cats.find((x) => x.id === R.val(f, '#cat')) || {}, box = f.querySelector('#catx');
      if (c.name === 'ค่าจ้างพนักงาน') box.innerHTML = `<div class="note info">ค่าจ้างรายสัปดาห์ให้จ่ายจากวันทำงานที่ระบบนับให้ ไม่ต้องนับเอง${R.can('expense.pay') ? ' <a href="#/staff">ไปหน้าพนักงาน › จ่ายค่าจ้าง</a>' : ''}</div>`;
      else if (c.tax_category === 'เงินเบิกล่วงหน้าพนักงาน') box.innerHTML = `<label class="field"><span class="req">พนักงานที่เบิก</span><select id="advu"><option value="">เลือก…</option>${R.opts(B().users.filter((x) => x.role !== 'admin'), null, 'display_name')}</select></label>
        <p class="muted small">เงินเบิกจะถูกหักอัตโนมัติตอนจ่ายค่าจ้างรอบถัดไป</p>`;
      else if (R.isNotCost(c)) {
        // group C is not a cost: it is saved where it belongs (debt, capital, investment, drawing), never in profit
        const accs = B().accounts.filter((a) => a.active !== false);
        box.innerHTML = `<div class="note info"><b>${esc(c.name)} ไม่ใช่ค่าใช้จ่าย</b> ไม่นับในกำไร ${c.c_kind === 'loan_repayment' ? 'ระบบลดยอดเงินกู้ลงทุนคงเหลือ และตัดเงินจากบัญชีที่เลือก'
          : c.c_kind === 'capital_in' ? 'ระบบบันทึกเป็นทุนของเจ้าของ เงินเข้าบัญชีที่เลือก' : c.c_kind === 'investment_item' ? 'ระบบบันทึกเป็นเงินลงทุน (ค่าเซ้ง / อุปกรณ์) ใช้คิดระยะคืนทุน'
          : 'ถอนกำไรต้องประกาศใช้กำไรก่อน ที่หน้า เงิน'}</div>
          ${['loan_repayment', 'capital_in'].includes(c.c_kind) ? `<div class="field"><span>${c.c_kind === 'loan_repayment' ? 'จ่ายจากบัญชี' : 'เงินเข้าบัญชี'}</span>${R.seg('cacc', accs.map((a) => [a.id, a.name]), (accs.find((a) => !a.is_drawer) || accs[0] || {}).id, 'wrap')}</div>` : ''}`;
      } else box.innerHTML = '';
      f.querySelector('#fundwrap').hidden = R.isNotCost(c);
      document.getElementById('save').textContent = R.isNotCost(c) ? (c.c_kind === 'owner_draw' ? 'ไปประกาศใช้กำไร' : 'บันทึกที่หน้าเงิน') : 'บันทึกค่าใช้จ่าย';
    };
    f.querySelector('#cat').addEventListener('change', catx); catx();
    let ocrData = null, lastImage = null;
    aw.bind(f, (up) => { if (/^image\//.test(up.mime)) { lastImage = up.dataUrl; f.querySelector('#ocr').hidden = false; } });
    f.querySelector('#ocr').addEventListener('click', (ev) => R.busy(ev.currentTarget, async () => {
      const s = f.querySelector('#ocr-status');
      s.textContent = 'กำลังเตรียมตัวอ่าน…';
      const T = await R.loadTesseract();
      const res = await T.recognize(lastImage, 'tha+eng', { logger: (m) => { if (m.status === 'recognizing text') s.textContent = 'กำลังอ่าน ' + Math.round(m.progress * 100) + '%'; } });
      ocrData = { ...R.parseReceipt(res.data.text), raw: res.data.text.slice(0, 2000) };
      const mark = (id, v) => { if (v == null || v === '') return; const i = f.querySelector(id); if (!i) return; i.value = v; i.style.borderColor = '#1c68cf'; i.style.background = '#f4f9fe'; };
      mark('#payee', ocrData.merchant); mark('#amt', ocrData.amount); mark('#fund-ref', ocrData.ref); mark('#docno', ocrData.ref);
      if (ocrData.date) mark('#at', ocrData.date + 'T' + (ocrData.time || '12:00'));
      if (ocrData.merchant || ocrData.date) f.querySelector('details').open = true;
      s.textContent = 'อ่านเสร็จ ตรวจข้อมูลอีกครั้ง';
      f.querySelector('#ocr-note').hidden = false;
    }));
    document.getElementById('save').addEventListener('click', (ev) => R.busy(ev.currentTarget, async () => {
      const cc = cats.find((x) => x.id === R.val(f, '#cat'));
      if (R.isNotCost(cc)) {
        if (cc.c_kind === 'owner_draw') { R.toast('ถอนกำไร: ประกาศใช้กำไรก่อน แล้วระบบจ่ายเงินออกให้'); location.hash = '#/cashflow'; return; }
        if (!(Number(R.val(f, '#amt')) > 0)) throw new Error('จำนวนเงินต้องมากกว่า 0');
        const c = await R.api('capital.create', { kind: cc.c_kind, amount: R.val(f, '#amt'), occurred_at: R.toIso(R.val(f, '#at')), account_id: R.segVal(f, 'cacc'),
          party: R.val(f, '#payee') || (cc.c_kind === 'loan_repayment' ? 'ผู้ให้กู้' : 'เจ้าของ'), category: R.val(f, '#desc') || cc.name, note: R.val(f, '#desc') || null });
        success(el, { title: 'บันทึก' + cc.name + 'แล้ว', sub: `${baht(c.amount || R.val(f, '#amt'))} · ไม่นับเป็นค่าใช้จ่ายในกำไร`,
          actions: [{ label: 'ดูหน้าเงิน', href: '#/cashflow' }, { label: 'บันทึกอีกรายการ', href: '#/expense', primary: true }] });
        return;
      }
      if (!f.reportValidity()) return;
      if (ocrData && !R.val(f, '#ocr-ok')) throw new Error('ตรวจข้อมูลที่อ่านจากรูป แล้วติ๊ก "ตรวจแล้ว ถูกต้อง"');
      const fv = fundValue(f, 'fund');
      aw.check(f);
      if ((fv.fund_source === 'shop_bank' || fv.fund_source === 'other_account') && !fv.pay_ref) throw new Error('จ่ายผ่านบัญชี ใส่เลขอ้างอิง / เลขที่สลิป');
      const e = await R.api('expense.create', { occurred_at: R.toIso(R.val(f, '#at')), category_id: R.val(f, '#cat'), payee: R.val(f, '#payee'), amount: R.val(f, '#amt'),
        description: R.val(f, '#desc'), advance_user_id: R.val(f, '#advu') || null, doc_type: R.val(f, '#doct'), doc_no: R.val(f, '#docno'), due_date: R.val(f, '#due') || null, attachment_ids: aw.ids(), no_evidence_reason: aw.reason(f),
        ocr_snapshot: ocrData ? { ...ocrData, reviewed_by_user: true } : null, ...fv });
      success(el, { title: 'บันทึกค่าใช้จ่ายแล้ว', sub: `${esc(e.expense_no)} · ${baht(e.amount)} · ${esc(e.status)}${e.owed_to ? '<br>ค้างคืน ' + esc(e.owed_to) : ''}`,
        actions: [{ label: 'กลับหน้าหลัก', href: '#/home' }, { label: 'บันทึกอีกรายการ', href: '#/expense', primary: true }] });
    }));
    const mine = (await R.api('expense.list', { from: R.addDays(R.today(), -30) })).filter((x) => x.created_by === B().me.id);
    el.querySelector('#mine').innerHTML = R.sec('ที่ฉันบันทึก 30 วัน') + R.list(mine.slice(0, 20).map((x) => R.row({ data: { x: x.id }, icon: 'wallet', off: x.status === 'ยกเลิก',
      t: esc(x.description), s: `${R.dt(x.occurred_at)} · ${esc(R.FUND[x.fund_source] || x.category_name || '')}${x.owed_to ? ' · ค้างคืน ' + esc(x.owed_to) : ''}`, v: baht(x.amount),
      pill: R.statusPill(x.status), chev: x.status === 'รออนุมัติ' })), 'ยังไม่มีรายการ');
    el.querySelectorAll('[data-x]').forEach((b) => b.addEventListener('click', async () => {
      const x = mine.find((y) => y.id === b.dataset.x); if (x.status !== 'รออนุมัติ') return;
      const r = await R.askReason('ยกเลิกค่าใช้จ่าย', { text: x.description + ' ' + baht(x.amount), danger: true, ok: 'ยกเลิกรายการ' });
      if (r) R.busy(null, async () => { await R.api('expense.cancel', { expense_id: x.id, reason: r.reason }); R.route(); });
    }));
  });


  // ------------------------------------------------------------ count leftovers in any unit (กล่อง / ไม้ / ลูก / กก.)
  // units come from the server: base unit, owner-set averages (1 ลูก ≈ 3.5 กก.) and sold units from recipes (1 กล่อง = 0.35 กก.)
  const unitOrder = { recipe: 0, avg: 1, base: 2 };
  function countBox(s, val) {
    const units = (s.units || [{ key: 'base', unit: s.unit, factor: 1, kind: 'base' }]).slice().sort((a, b) => unitOrder[a.kind] - unitOrder[b.kind]);
    const box = units.filter((u) => u.kind === 'recipe')[0];
    return `<div class="cnt" data-cbox="${s.id}">
      <div class="cnt-head"><b>${esc(s.name)}</b><span class="muted small">${Number(s.system_qty) < 0 ? `ในระบบติดลบ ${qty(s.system_qty)} ${esc(s.unit)} (ขายเกินของที่รับเข้า ควรนับ)` : `ในระบบ ${qty(s.system_qty)} ${esc(s.unit)}${box && Number(s.system_qty) > 0 ? ` ≈ ${qty(Math.floor(Number(s.system_qty) / Number(box.factor)))} ${esc(box.unit)}` : ''}`}</span></div>
      <div class="cnt-units">${units.map((u) => `<label class="cu"><span class="cu-l">${u.kind === 'recipe' && u.emoji ? esc(u.emoji) + ' ' : ''}${esc(u.unit)}${u.kind === 'recipe' && units.filter((x) => x.kind === 'recipe' && x.unit === u.unit).length > 1 ? ' ' + esc(u.product) : ''}</span>
          <input type="number" min="0" step="any" inputmode="decimal" data-cu="${s.id}" data-key="${esc(u.key)}" value="${val && val[u.key] != null ? esc(val[u.key]) : ''}" placeholder="–" aria-label="${esc(s.name)} เป็น ${esc(u.unit)}">
          <small>${u.kind === 'base' ? 'ชั่งได้' : `1 ${esc(u.unit)} = ${qty(u.factor)} ${esc(s.unit)}${u.kind === 'avg' ? ' (เฉลี่ย)' : ''}`}</small></label>`).join('')}</div>
      <div class="cnt-total" data-ctot="${s.id}">${countTotalText(s, val)}</div></div>`;
  }
  function countTotal(s, val) {
    if (!val) return null; let t = 0, any = false;
    (s.units || [{ key: 'base', factor: 1 }]).forEach((u) => { const v = val[u.key]; if (v !== '' && v != null) { any = true; t += Number(v) * Number(u.factor); } });
    return any ? Math.round(t * 1000) / 1000 : null;
  }
  function countTotalText(s, val) {
    const t = countTotal(s, val); if (t == null) return '<span class="muted small">ยังไม่ได้นับ · ใส่หน่วยที่สะดวก ระบบแปลงเป็น ' + esc(s.unit) + ' ให้</span>';
    const d = Math.round((t - Number(s.system_qty)) * 1000) / 1000;
    return `รวมนับได้ <b>${qty(t)} ${esc(s.unit)}</b>${d ? ` · <span style="color:var(--warn)">ต่างจากระบบ ${d > 0 ? '+' : ''}${qty(d)}</span>` : ' · ตรงกับระบบ'}`;
  }
  // wire inputs: keeps typing smooth (no redraw), updates the total line
  function bindCounts(root, items, state) {
    root.querySelectorAll('[data-cu]').forEach((i) => i.addEventListener('input', () => {
      const id = i.dataset.cu; state[id] = state[id] || {}; state[id][i.dataset.key] = i.value;
      const s = items.find((x) => x.id === id), tot = root.querySelector(`[data-ctot="${id}"]`); if (tot) tot.innerHTML = countTotalText(s, state[id]);
    }));
  }
  const countPayload = (items, state) => items.filter((s) => countTotal(s, state[s.id]) != null).map((s) => ({ stock_item_id: s.id, counted_qty: countTotal(s, state[s.id]),
    parts: Object.entries(state[s.id]).filter(([, v]) => v !== '' && v != null).map(([key, v]) => ({ key, qty: Number(v) })) }));
  R.countBox = countBox; R.bindCounts = bindCounts; R.countPayload = countPayload;

  // ------------------------------------------------------------ daily close: 6 steps
  const DENOMS = [1000, 500, 100, 50, 20];
  R.def('close', { title: 'บันทึกรายงานปิดยอดร้านประจำวัน', tab: 'close', back: 'home' }, async function (el, argDate) {
    const d = argDate && /^\d{4}-\d{2}-\d{2}$/.test(argDate) ? argDate : R.today();
    const pv = await R.api('close.preview', { date: d });
    const c = pv.computed;
    if (pv.close) return closedView(el, pv.close);
    const STEPS = ['ยอดขายหน้าร้าน', 'ยอด Delivery', 'ของเสีย', 'ของเหลือ / วัตถุดิบ', 'เงินสด', 'ตรวจและส่ง'];
    const st = {
      step: 0, pc: Object.fromEntries(c.products.map((p) => [p.product_id, { q: Number(p.storefront_qty), note: '' }])),
      dc: Object.fromEntries(c.channels.filter((x) => x.kind === 'delivery').map((x) => [x.channel_id, { orders: x.orders, gross: Number(x.net), note: '' }])),
      waste: [], counts: {}, stockNote: '',
      start: Number(c.starting_cash), startReason: '', cashSales: r2(Number(c.cash_in_orders) - Number(c.cash_out_refunds)), cashReason: '', qr: Number(c.qr_sales), qrReason: '',
      removed: 0, removedTo: (pv.accounts[0] || {}).id || '', removedNote: '', den: {}, coins: 0, typed: null, varReason: '', note: '', coworkers: [],
    };
    const users = B().users.filter((u) => u.id !== B().me.id && u.role !== 'admin');
    const sysStart = Number(c.starting_cash), sysCash = r2(Number(c.cash_in_orders) - Number(c.cash_out_refunds));
    const expected = () => r2(Number(c.expected_cash) - sysStart + st.start - sysCash + st.cashSales - st.removed);
    const counted = () => (st.typed != null ? st.typed : DENOMS.reduce((s, v) => s + v * (st.den[v] || 0), 0) + Number(st.coins || 0));
    const hasCount = () => st.typed != null || DENOMS.some((v) => st.den[v]) || Number(st.coins) > 0;
    const variance = () => r2(counted() - expected());
    const tol = Number(pv.tolerance || 0);
    const wf = wasteForm('cw');
    const nowHM = () => { const x = new Date(); return String(x.getHours()).padStart(2, '0') + ':' + String(x.getMinutes()).padStart(2, '0'); };
    const onTime = () => d === R.today() && nowHM() <= pv.due_time;

    function stepHtml() {
      if (st.step === 0) return `<div class="card blue"><span class="muted small">ยอดขายหน้าร้านในระบบ · ${R.date(d)}</span><span class="big-amt">${baht(c.storefront_net)}</span>
          <span class="muted small">รวมทั้งร้าน ${baht(c.total_net)} · ${c.orders_count} ออเดอร์</span></div>
        <p class="muted small" style="padding:0 4px">ตรวจจำนวนที่ขายหน้าร้านของแต่ละสินค้า ถ้าไม่ตรงให้แก้ตัวเลขและบอกเหตุผล (ไม่แก้ออเดอร์เดิม เจ้าของร้านเห็นผลต่าง)</p>
        <div class="list">${c.products.map((p) => {
          const v = st.pc[p.product_id], diff = r2(v.q - p.storefront_qty);
          return `<div class="row static"><span class="ic" style="font-size:1.4rem">${p.emoji ? esc(p.emoji) : R.icon('tag')}</span><span class="body"><span class="t">${esc(p.name)}</span>
            <span class="s">ในระบบ ${qty(p.storefront_qty)} ${esc(p.unit)} · ${money(p.storefront_net)}${diff ? ` · <b style="color:var(--warn)">ต่าง ${diff > 0 ? '+' : ''}${qty(diff)}</b>` : ''}</span>
            ${diff ? `<input type="text" data-pcn="${p.product_id}" value="${esc(v.note)}" placeholder="เหตุผลที่ไม่ตรง" style="margin-top:6px">` : ''}</span>
            <input type="number" min="0" step="any" inputmode="decimal" data-pc="${p.product_id}" value="${v.q}" style="max-width:96px;text-align:right" aria-label="จำนวนที่ขาย ${esc(p.name)}"></div>`; }).join('')}</div>
        <p class="muted small" style="padding:0 4px">ลืมบันทึกออเดอร์? กลับไปที่ บันทึกขาย แล้วบันทึกก่อนปิดยอด</p>`;
      if (st.step === 1) {
        const dl = c.channels.filter((x) => x.kind === 'delivery');
        return `<div class="card blue"><span class="muted small">ยอด Delivery ในระบบ</span><span class="big-amt">${baht(c.delivery_net)}</span></div>
        ${dl.length ? dl.map((x) => { const v = st.dc[x.channel_id], diff = r2(v.gross - Number(x.net));
          return `<div class="card"><h2>${esc(x.name)}</h2><p class="muted small">ในระบบ ${x.orders} ออเดอร์ · ${baht(x.net)}${Number(x.est_fee) ? ' · ค่าธรรมเนียมประมาณ ' + money(x.est_fee) : ''}</p>
            <div class="two"><label class="field"><span>จำนวนออเดอร์ในแอป</span><input type="number" min="0" step="1" inputmode="numeric" data-dco="${x.channel_id}" value="${v.orders}"></label>
            <label class="field"><span>ยอดขายในแอป (บาท)</span><input type="number" min="0" step="0.01" inputmode="decimal" data-dcg="${x.channel_id}" value="${v.gross}"></label></div>
            ${diff || Number(v.orders) !== Number(x.orders) ? `<label class="field"><span class="req">ไม่ตรงกับระบบ${diff ? ' ' + (diff > 0 ? '+' : '') + money(diff) : ''} · เหตุผล</span><input type="text" data-dcn="${x.channel_id}" value="${esc(v.note)}" placeholder="เช่น ลูกค้ายกเลิกในแอป"></label>` : '<div class="banner ok"><span class="dot"></span>ตรงกับระบบ</div>'}</div>`; }).join('')
          : R.empty('ร้านยังไม่มีช่องทาง Delivery')}`;
      }
      if (st.step === 2) return `${R.sec('ของเสียที่บันทึกแล้ววันนี้')}
        ${R.list(c.waste_rows.map((w) => R.row({ static: true, icon: 'trash', tone: 'warn', t: `${esc(w.item_name)} ${qty(w.qty)} ${esc(w.unit)}`, s: (w.kind && w.kind !== 'waste' ? R.WASTE_KIND[w.kind] + ' · ' : '') + esc(w.reason) })), 'ยังไม่มี')}
        ${R.sec('เพิ่มของเสียตอนปิดร้าน', R.can('waste.add') ? '<button type="button" id="addw">+ เพิ่ม</button>' : '')}
        ${R.list(st.waste.map((w, i) => R.row({ data: { wi: i }, icon: 'trash', tone: 'warn', t: `${esc(w._label ? (w._label.emoji ? w._label.emoji + ' ' : '') + w._label.name : '')} ${qty(w.qty)} ${esc(w._label ? w._label.unit : '')}`, s: w.kind !== 'waste' ? R.WASTE_KIND[w.kind] : esc(w.reason), vs: 'แตะเพื่อลบ', chev: false })), 'ไม่มีของเสียเพิ่ม')}
        <p class="muted small" style="padding:0 4px">ของเสียที่เพิ่มตรงนี้จะถูกบันทึกพร้อมรายงาน และตัดสต็อกตามสูตรของสินค้า</p>`;
      if (st.step === 3) return `${R.can('stock.count') && pv.stock.length ? `<p class="muted small" style="padding:0 4px">นับเป็นหน่วยที่สะดวก เช่น กล่องที่ตัดแล้ว ไม้ที่เสียบแล้ว ผลไม้ทั้งลูก หรือชั่งเป็นกิโล ใส่ได้หลายช่องพร้อมกัน ระบบรวมเป็นกิโลให้ ใส่เฉพาะที่นับ ผลนับส่งให้เจ้าของร้านอนุมัติ</p>
          <div class="cnts">${pv.stock.map((s) => countBox(s, st.counts[s.id])).join('')}</div><p class="muted small" style="padding:0 4px"><span class="req">ต้องนับทุกรายการที่ระบบบอกว่ายังมีของ (หมดใส่ 0)</span></p>` : R.empty('ไม่มีรายการให้นับ')}
        <div class="card"><label class="field"><span>สังเกตเรื่องของเหลือ / วัตถุดิบ (ถ้ามี)</span><textarea id="snote">${esc(st.stockNote)}</textarea></label></div>`;
      if (st.step === 4) {
        const v = hasCount() ? variance() : null;
        const suggest = Math.max(0, r2(counted() + st.removed - Number(pv.float || 0)));
        return `<div class="card"><h2>ที่มาของเงินสดในลิ้นชัก</h2>
            <div class="money-line"><span><span class="t">เงินทอนต้นวัน</span><span class="s">ยอดคงเหลือจากปิดยอดครั้งก่อน${st.start !== sysStart ? ' · แก้แล้ว: ' + esc(st.startReason) : ''}</span></span><span class="num" style="text-align:right">${money(st.start)} <button type="button" class="btn small ghost" id="fix-start">แก้</button></span></div>
            <div class="money-line"><span><span class="t">1. เงินสดที่ลูกค้าจ่ายวันนี้</span><span class="s">จากออเดอร์เงินสด ${money(sysCash)}${Number(c.cash_out_refunds) ? ' (หักยกเลิก/แก้ไข ' + money(c.cash_out_refunds) + ' แล้ว)' : ''} ตรวจและแก้ไขได้</span></span><input type="number" step="0.01" inputmode="decimal" id="m-cash" value="${st.cashSales}"></div>
            ${st.cashSales !== sysCash ? `<input type="text" id="m-cash-r" value="${esc(st.cashReason)}" placeholder="ทำไมไม่ตรงกับออเดอร์ (จำเป็น)">` : ''}
            <div class="money-line"><span><span class="t">2. QR / โอนเข้าบัญชีร้าน</span><span class="s">จากออเดอร์ ${money(c.qr_sales)} (ไม่อยู่ในลิ้นชัก)</span></span><input type="number" step="0.01" inputmode="decimal" id="m-qr" value="${st.qr}"></div>
            ${st.qr !== Number(c.qr_sales) ? `<input type="text" id="m-qr-r" value="${esc(st.qrReason)}" placeholder="ทำไมไม่ตรงกับออเดอร์ (จำเป็น)">` : ''}
            <div class="money-line"><span><span class="t">3. เงินสดร้านที่ใช้จ่ายระหว่างวัน</span><span class="s">จากหน้าบันทึกค่าใช้จ่ายที่เลือก "เงินสดของร้าน" ${c.expense_rows.length} รายการ</span></span><b class="num" style="text-align:right">${money(c.cash_out_expenses)}</b></div>
            ${Number(c.cash_transfers_net_out) ? `<div class="money-line"><span><span class="t">นำเงินออกที่บันทึกไว้แล้ว</span></span><b class="num" style="text-align:right">${money(c.cash_transfers_net_out)}</b></div>` : ''}
            <div class="money-line"><span><span class="t">4. เงินสดนำออกจากร้าน / ฝากธนาคาร</span><span class="s">เงินที่ย้ายออกจากร้าน ไม่ใช่ค่าใช้จ่าย${Number(pv.float) ? ` · ถ้าเก็บเงินทอนไว้ ${money(pv.float)} ควรนำออก ${money(suggest)}` : ''}</span></span><input type="number" min="0" step="0.01" inputmode="decimal" id="m-rm" value="${st.removed || ''}" placeholder="0"></div>
            ${st.removed > 0 ? `<div class="two"><label class="field"><span class="req">นำไปเข้าบัญชี</span><select id="m-rm-to">${R.opts(pv.accounts, st.removedTo)}</select></label>
              <label class="field"><span>หมายเหตุ</span><input type="text" id="m-rm-n" value="${esc(st.removedNote)}" placeholder="เช่น ฝากเข้าบัญชีร้าน"></label></div>` : ''}
            <div class="sum-row total"><span>ควรมีเงินสดในลิ้นชัก</span><span>${baht(expected())}</span></div></div>
          ${R.sec('5. เงินสดที่นับได้จริงตอนปิดร้าน')}
          <div class="list">${DENOMS.map((dv) => `<div class="row static"><span class="body"><span class="t">แบงก์ ${dv}</span><span class="s">${money(dv * (st.den[dv] || 0))}</span></span>
            <span class="stepper"><button type="button" data-dm="${dv}" aria-label="ลดแบงก์ ${dv}">−</button><span class="n">${st.den[dv] || 0}</span><button type="button" data-dp="${dv}" aria-label="เพิ่มแบงก์ ${dv}">+</button></span></div>`).join('')}
            <div class="row static"><span class="body"><span class="t">เหรียญรวม (บาท)</span></span><input type="number" id="coins" min="0" step="0.25" inputmode="decimal" value="${st.coins || ''}" placeholder="0" style="max-width:130px;text-align:right" aria-label="เหรียญรวม"></div></div>
          <div class="card"><div class="sum-row total" style="border:0;padding:0"><span>นับได้</span><span>${baht(counted())}</span></div>
            <details ${st.typed != null ? 'open' : ''}><summary>พิมพ์ยอดรวมเอง</summary><input type="number" id="typed" min="0" step="0.01" inputmode="decimal" value="${st.typed ?? ''}" placeholder="0.00" class="input-amt" style="margin-top:8px"></details>
            ${v == null ? '<span class="muted small">กด + ที่แบงก์แต่ละชนิด หรือพิมพ์ยอดรวมเอง</span>' : v === 0 ? '<div class="banner ok"><span class="dot"></span>ตรงกับยอดที่ควรมี</div>'
              : `<div class="note">${v < 0 ? 'เงินขาด' : 'เงินเกิน'} ${baht(Math.abs(v))}${Math.abs(v) <= tol ? ` (ไม่เกินเกณฑ์ ${money(tol)} บาท)` : ` · เกินเกณฑ์ ${money(tol)} บาท ต้องใส่หมายเหตุ`}</div>
                <label class="field"><span>${Math.abs(v) > tol ? '<span class="req">' : '<span>'}เกิดจากอะไร</span></span><textarea id="var-r" placeholder="เช่น ทอนเงินผิด">${esc(st.varReason)}</textarea></label>`}</div>`;
      }
      const v = variance(), late = !onTime();
      const pcDiff = c.products.filter((p) => r2(st.pc[p.product_id].q - p.storefront_qty)).length;
      const dcDiff = Object.entries(st.dc).filter(([id, x]) => { const ch = c.channels.find((y) => y.channel_id === id); return r2(x.gross - Number(ch.net)) || Number(x.orders) !== Number(ch.orders); }).length;
      return `<div class="banner ${late ? 'bad' : 'ok'}"><span class="dot"></span><span>${late ? `ส่งตอนนี้นับว่า "หลังเวลา" (กำหนด ${esc(pv.due_time)} น.)` : `ส่งตอนนี้นับว่า "ตรงเวลา" (ภายใน ${esc(pv.due_time)} น.)`}</span></div>
        <div class="stats">${R.stat('ยอดขายรวม', baht(c.total_net), c.orders_count + ' ออเดอร์')}${R.stat('ควรมีเงินสด', baht(expected()))}${R.stat('นับได้จริง', baht(counted()))}
          ${R.stat('ผลต่าง', `<span style="color:${v === 0 ? 'var(--ok)' : 'var(--warn)'}">${v > 0 ? '+' : ''}${money(v)}</span>`, v === 0 ? 'ตรงกัน' : v < 0 ? 'เงินขาด' : 'เงินเกิน')}</div>
        ${R.list([
          R.row({ static: true, icon: 'cart', t: 'ยอดขายหน้าร้าน', s: pcDiff ? `ไม่ตรง ${pcDiff} สินค้า` : 'ตรงกับระบบ', v: baht(c.storefront_net) }),
          R.row({ static: true, icon: 'flow', t: 'Delivery', s: dcDiff ? `ไม่ตรง ${dcDiff} แพลตฟอร์ม` : 'ตรงกับระบบ', v: baht(c.delivery_net) }),
          R.row({ static: true, icon: 'trash', t: 'ของเสีย', s: `บันทึกแล้ว ${c.waste_rows.length} · เพิ่มตอนปิด ${st.waste.length}` }),
          R.row({ static: true, icon: 'box', t: 'นับของเหลือ', s: `${countPayload(pv.stock, st.counts).length} รายการ` }),
          R.row({ static: true, icon: 'wallet', t: 'นำเงินสดออก', s: st.removed ? 'เข้า ' + esc(R.lookup(pv.accounts, st.removedTo)) : 'ไม่มี', v: money(st.removed) })])}
        ${v !== 0 && st.varReason ? `<div class="note">คำอธิบายเงินต่าง: ${esc(st.varReason)}</div>` : ''}
        ${users.length ? `${R.sec('ใครอยู่กะวันนี้ด้วย')}<div class="people">${users.map((u) => `<button type="button" class="person" data-cw="${u.id}" aria-pressed="${st.coworkers.includes(u.id)}">${R.avatar(u.display_name)}<span>${esc(u.display_name)}</span></button>`).join('')}</div>
          <p class="muted small" style="padding:0 4px">ทุกคนที่เลือกได้นับวันทำงานวันนี้ 1 วัน</p>` : ''}
        <div class="card"><label class="field"><span>ฝากถึงเจ้าของร้าน (ถ้ามี)</span><textarea id="cnote">${esc(st.note)}</textarea></label></div>`;
    }

    function save() {
      const g = (id) => el.querySelector(id);
      el.querySelectorAll('[data-pc]').forEach((i) => { st.pc[i.dataset.pc].q = i.value === '' ? 0 : Number(i.value); });
      el.querySelectorAll('[data-pcn]').forEach((i) => { st.pc[i.dataset.pcn].note = i.value.trim(); });
      el.querySelectorAll('[data-dco]').forEach((i) => { st.dc[i.dataset.dco].orders = Number(i.value) || 0; });
      el.querySelectorAll('[data-dcg]').forEach((i) => { st.dc[i.dataset.dcg].gross = Number(i.value) || 0; });
      el.querySelectorAll('[data-dcn]').forEach((i) => { st.dc[i.dataset.dcn].note = i.value.trim(); });
      if (g('#snote')) st.stockNote = g('#snote').value.trim();
      if (g('#m-cash')) st.cashSales = r2(g('#m-cash').value);
      if (g('#m-cash-r')) st.cashReason = g('#m-cash-r').value.trim();
      if (g('#m-qr')) st.qr = r2(g('#m-qr').value);
      if (g('#m-qr-r')) st.qrReason = g('#m-qr-r').value.trim();
      if (g('#m-rm')) st.removed = Math.max(0, r2(g('#m-rm').value));
      if (g('#m-rm-to')) st.removedTo = g('#m-rm-to').value;
      if (g('#m-rm-n')) st.removedNote = g('#m-rm-n').value.trim();
      if (g('#coins')) st.coins = Number(g('#coins').value) || 0;
      if (g('#typed')) st.typed = g('#typed').value === '' ? null : Number(g('#typed').value);
      if (g('#var-r')) st.varReason = g('#var-r').value.trim();
      if (g('#cnote')) st.note = g('#cnote').value.trim();
    }
    function validate() {
      if (st.step === 0 && c.products.some((p) => r2(st.pc[p.product_id].q - p.storefront_qty) && !st.pc[p.product_id].note)) throw new Error('สินค้าที่จำนวนไม่ตรงกับระบบ ใส่เหตุผลด้วย');
      if (st.step === 1 && Object.entries(st.dc).some(([id, x]) => { const ch = c.channels.find((y) => y.channel_id === id); return (r2(x.gross - Number(ch.net)) || Number(x.orders) !== Number(ch.orders)) && !x.note; })) throw new Error('ยอด Delivery ไม่ตรงกับระบบ ใส่เหตุผลด้วย');
      // leftovers: everything the system says is still in stock must be counted (0 when it is gone)
      if (st.step === 3 && R.can('stock.count')) {
        const done = new Set(countPayload(pv.stock, st.counts).map((x) => x.stock_item_id)), miss = pv.stock.filter((x) => Number(x.system_qty) > 0 && !done.has(x.id));
        if (miss.length) throw new Error('นับของเหลือให้ครบ (ถ้าหมดใส่ 0): ' + miss.slice(0, 4).map((x) => x.name).join(', ') + (miss.length > 4 ? ' และอีก ' + (miss.length - 4) + ' รายการ' : ''));
      }
      if (st.step === 4) {
        if (st.cashSales !== sysCash && !st.cashReason) throw new Error('เงินสดที่ลูกค้าจ่ายไม่ตรงกับออเดอร์ ใส่เหตุผล');
        if (st.qr !== Number(c.qr_sales) && !st.qrReason) throw new Error('ยอด QR ไม่ตรงกับออเดอร์ ใส่เหตุผล');
        if (st.removed > 0 && !st.removedTo) throw new Error('เลือกว่าเงินสดที่นำออกไปเข้าบัญชีไหน');
        if (!hasCount()) throw new Error('นับเงินสดก่อน หรือพิมพ์ยอดรวมเอง');
        if (Math.abs(variance()) > tol && !st.varReason) throw new Error('เงิน' + (variance() < 0 ? 'ขาด' : 'เกิน') + ' ' + money(Math.abs(variance())) + ' บาท เกินเกณฑ์ ใส่คำอธิบาย');
      }
    }
    function draw() {
      el.innerHTML = `<div class="step-head"><span class="muted">ขั้นที่ ${st.step + 1} จาก ${STEPS.length} · ${R.date(d)}</span><h2>${STEPS[st.step]}</h2>
          <div class="progress"><i style="width:${((st.step + 1) / STEPS.length) * 100}%"></i></div>
          <div class="step-dots">${STEPS.map((s, i) => `<button type="button" data-go="${i}" ${i === st.step ? 'aria-current="step"' : ''} class="${i < st.step ? 'done' : ''}">${i + 1}. ${esc(s)}</button>`).join('')}</div></div>
        ${stepHtml()}
        ${R.actionbar(`${st.step > 0 ? '<button class="btn" id="prev">ย้อนกลับ</button>' : ''}<button class="btn primary" id="next">${st.step < STEPS.length - 1 ? 'ถัดไป' : 'ส่งรายงานปิดยอด'}</button>`)}`;
      on(document.getElementById('prev'), () => { save(); st.step--; draw(); window.scrollTo(0, 0); });
      el.querySelectorAll('[data-go]').forEach((b) => b.addEventListener('click', () => {
        save(); const to = Number(b.dataset.go);
        if (to > st.step) { try { validate(); } catch (e) { return R.fail(e); } }
        st.step = Math.min(to, st.step + 1 > to ? to : st.step + 1); draw(); window.scrollTo(0, 0);
      }));
      document.getElementById('next').addEventListener('click', (ev) => {
        save();
        try { validate(); } catch (e) { return R.fail(e); }
        if (st.step < STEPS.length - 1) { st.step++; draw(); window.scrollTo(0, 0); } else submit(ev.currentTarget);
      });
      // redraw on change so the "reason" boxes and totals follow what was typed
      el.querySelectorAll('[data-pc],[data-dco],[data-dcg],#m-cash,#m-qr,#m-rm,#coins,#typed').forEach((i) => i.addEventListener('change', () => { save(); draw(); }));
      if (st.step === 3) bindCounts(el, pv.stock, st.counts);
      if (st.step === 2) {
        on(el.querySelector('#addw'), () => {
          const m = R.modal('เพิ่มของเสีย', `<form class="form">${wf.html}<button class="btn primary lg">เพิ่มในรายงาน</button></form>`);
          const fm = m.el.querySelector('form'); wf.bind(fm);
          fm.addEventListener('submit', (e) => { e.preventDefault(); try {
            if (!fm.reportValidity()) return;
            st.waste.push(wf.payload(fm)); m.close(); draw();
          } catch (x) { R.fail(x); } });
        });
        el.querySelectorAll('[data-wi]').forEach((b) => b.addEventListener('click', () => { st.waste.splice(b.dataset.wi, 1); draw(); }));
      }
      if (st.step === 4) {
        el.querySelectorAll('[data-dp],[data-dm]').forEach((b) => b.addEventListener('click', () => {
          save(); const k = b.dataset.dp || b.dataset.dm; st.den[k] = Math.max(0, (st.den[k] || 0) + (b.dataset.dp ? 1 : -1)); st.typed = null; draw();
        }));
        on(el.querySelector('#fix-start'), () => {
          const m = R.modal('แก้เงินทอนต้นวัน', `<form class="form"><p class="muted">ในระบบ ${baht(sysStart)} (ยอดนับเมื่อปิดยอดครั้งก่อน)</p>
            <label class="field"><span>เงินทอนต้นวันที่ถูกต้อง</span><input type="number" id="v" step="0.01" inputmode="decimal" value="${st.start}" required></label>
            <label class="field"><span class="req">เหตุผล</span><input type="text" id="r" value="${esc(st.startReason)}" required></label><button class="btn primary lg">บันทึก</button></form>`);
          m.el.querySelector('form').addEventListener('submit', (e) => { e.preventDefault(); save(); st.start = Number(R.val(m.el, '#v')); st.startReason = R.val(m.el, '#r'); m.close(); draw(); });
        });
      }
      if (st.step === 5) el.querySelectorAll('[data-cw]').forEach((b) => b.addEventListener('click', () => {
        const id = b.dataset.cw; st.coworkers = st.coworkers.includes(id) ? st.coworkers.filter((x) => x !== id) : st.coworkers.concat(id);
        b.setAttribute('aria-pressed', st.coworkers.includes(id));
      }));
    }
    async function submit(btn) {
      await R.busy(btn, async () => {
        const res = await R.api('close.submit', { date: d, counted_cash: counted(),
          starting_cash: st.start, starting_cash_reason: st.startReason,
          cash_sales: st.cashSales, cash_sales_reason: st.cashReason, qr_sales: st.qr, qr_sales_reason: st.qrReason,
          cash_removed: st.removed, cash_removed_to: st.removed ? st.removedTo : null, cash_removed_note: st.removedNote,
          variance_reason: st.varReason, coworker_ids: st.coworkers, note: st.note, stock_note: st.stockNote,
          product_counts: c.products.map((p) => ({ product_id: p.product_id, counted_qty: st.pc[p.product_id].q, note: st.pc[p.product_id].note })).filter((x, i) => Number(x.counted_qty) || Number(c.products[i].storefront_qty)),
          delivery_counts: Object.entries(st.dc).map(([id, x]) => ({ channel_id: id, orders: x.orders, gross: x.gross, note: x.note })),
          waste_lines: st.waste.map((w) => { const x = { ...w }; delete x._label; return x; }),
          stock_counts: countPayload(pv.stock, st.counts) });
        if (d === R.today()) B().closed_today = true;
        closedView(el, res, true);
      });
    }
    draw();
  });

  function closeSummary(x) {
    const s = x.summary, v = Number(x.variance), cd = x.cash_detail || {};
    const pcd = (x.product_counts || []).filter((p) => Number(p.diff)), dcd = (x.delivery_counts || []).filter((p) => Number(p.diff) || (p.app_orders != null && Number(p.app_orders) !== Number(p.system_orders)));
    return `<div class="stats">${R.stat('ยอดขายรวม', baht(s.total_net), s.orders_count + ' ออเดอร์')}${R.stat('ควรมีเงินสด', baht(x.expected_cash))}${R.stat('นับได้จริง', baht(x.counted_cash))}
        ${R.stat('ผลต่าง', `<span style="color:${v === 0 ? 'var(--ok)' : 'var(--warn)'}">${v > 0 ? '+' : ''}${money(v)}</span>`, esc(x.variance_reason || (v ? '' : 'ตรงกัน')))}</div>
      ${x.on_time != null ? `<div class="banner ${x.on_time ? 'ok' : 'bad'}"><span class="dot"></span><span>${x.on_time ? 'ส่งตรงเวลา' : 'ส่งหลังเวลา'} · ${R.time(x.submitted_at)} น.${cd.due_time ? ' (กำหนด ' + esc(cd.due_time) + ')' : ''}</span></div>` : ''}
      ${R.list(s.channels.filter((c) => c.orders || Number(c.net)).map((c) => R.row({ static: true, t: esc(c.name), s: c.orders + ' ออเดอร์' + (c.edited_orders ? ' · แก้ไข ' + c.edited_orders : ''), v: baht(c.net) })), 'ไม่มียอดขาย')}
      ${cd.cash_sales != null ? R.list([
        R.row({ static: true, icon: 'wallet', t: 'เงินทอนต้นวัน', v: money(x.starting_cash) }),
        R.row({ static: true, icon: 'wallet', t: 'เงินสดที่ลูกค้าจ่าย', s: Number(cd.cash_sales) !== Number(cd.cash_sales_system) ? 'ระบบ ' + money(cd.cash_sales_system) : '', v: money(cd.cash_sales) }),
        R.row({ static: true, icon: 'receipt', t: 'QR / โอน', s: Number(cd.qr_sales) !== Number(cd.qr_system) ? 'ระบบ ' + money(cd.qr_system) : '', v: money(cd.qr_sales) }),
        R.row({ static: true, icon: 'wallet', t: 'เงินสดร้านที่ใช้จ่าย', v: money(cd.store_spent) }),
        R.row({ static: true, icon: 'flow', t: 'นำเงินสดออก', s: cd.removed ? 'เข้า ' + esc(cd.removed_to || '') + (cd.removed_note ? ' · ' + esc(cd.removed_note) : '') : '', v: money(cd.removed || 0) })]) : ''}
      ${pcd.length ? `<div class="note info"><b>ยอดหน้าร้านที่พนักงานนับไม่ตรง</b><br>${pcd.map((p) => `${esc(p.name)}: ระบบ ${qty(p.system_qty)} → ${qty(p.counted_qty)}${p.note ? ' (' + esc(p.note) + ')' : ''}`).join('<br>')}</div>` : ''}
      ${dcd.length ? `<div class="note info"><b>ยอด Delivery ในแอปไม่ตรง</b><br>${dcd.map((p) => `${esc(p.name)}: ระบบ ${money(p.system_gross)} (${p.system_orders}) → แอป ${money(p.app_gross)} (${p.app_orders ?? '-'})${p.note ? ' · ' + esc(p.note) : ''}`).join('<br>')}</div>` : ''}
      ${x.adjustments.length ? `<div class="note info">${x.adjustments.map((a) => `${esc(a.label || a.field)}: ${money(a.original)} → ${money(a.corrected)} (${esc(a.reason)})`).join('<br>')}</div>` : ''}
      ${x.note ? `<div class="card"><span class="muted small">ฝากถึงเจ้าของร้าน</span>${esc(x.note)}</div>` : ''}${x.stock_note ? `<div class="card"><span class="muted small">เรื่องสต็อก</span>${esc(x.stock_note)}</div>` : ''}
      ${x.revisions.length ? `<p class="muted small">แก้ไข ${x.revisions.length} ครั้ง: ${x.revisions.map((r) => esc(r.by) + ' ' + R.dt(r.at) + ' (' + esc(r.reason) + ')').join('; ')}</p>` : ''}
      ${Number(x.late_entries) ? `<div class="note">มีรายการเงินของวันนี้ที่บันทึกหลังส่งรายงาน ${x.late_entries} รายการ</div>` : ''}`;
  }
  R.closeSummary = closeSummary;
  function closedView(el, x, justNow) {
    document.body.classList.remove('has-actionbar');
    el.innerHTML = `<div class="card success" style="padding:24px 16px"><span class="mark">${R.icon('check')}</span>
        <h2>${justNow ? 'ส่งรายงานปิดยอดแล้ว' : 'วันนี้ปิดยอดแล้ว'}</h2>
        <p class="muted">${R.date(x.biz_date)} · ${R.time(x.submitted_at)} น. โดย ${esc(x.submitted_by_name)}${x.coworker_names.length ? '<br>ร่วมกะ: ' + x.coworker_names.map(esc).join(', ') : ''}</p></div>
      ${closeSummary(x)}
      <a class="btn lg block" href="#/home">กลับหน้าหลัก</a>`;
    window.scrollTo(0, 0);
  }

  // ------------------------------------------------------------ my summary: workdays, on time / late, what the shop owes me
  R.def('my', { title: 'สรุปของฉัน', tab: 'my', back: 'more' }, async function (el) {
    let mo = 0;
    async function draw() {
      const t = R.today(), base = new Date(t.slice(0, 8) + '01T12:00:00'); base.setMonth(base.getMonth() - mo);
      const from = base.toISOString().slice(0, 8) + '01', endD = new Date(base); endD.setMonth(endD.getMonth() + 1); endD.setDate(0);
      const to = mo ? endD.toISOString().slice(0, 10) : t;
      const [list, wd, exp, pay] = await Promise.all([R.api('close.list', { from, to, mine: true }), R.api('close.workdays', { from, to, mine: true }),
        R.api('expense.list', { from: R.addDays(t, -90) }), R.api('payroll.summary', { from, to }).catch(() => null)]);
      const me = wd.find((w) => w.user_id === B().me.id) || { days: 0, submitted: 0, on_time: 0, late: 0 };
      const owed = exp.filter((x) => x.paid_by_employee === B().me.id && (x.status === 'รออนุมัติ' || x.status === 'รอทำจ่าย'));
      el.innerHTML = `<div class="chips"><button class="chip" data-mo="0" aria-pressed="${mo === 0}">เดือนนี้</button><button class="chip" data-mo="1" aria-pressed="${mo === 1}">เดือนก่อน</button><button class="chip" data-mo="2" aria-pressed="${mo === 2}">2 เดือนก่อน</button></div>
        <div class="card blue"><span class="muted small">วันทำงาน ${R.date(from)} – ${R.date(to)}</span><span class="big-amt">${me.days} วัน</span></div>
        <div class="stats">${R.stat('ส่งรายงานเอง', me.submitted + ' ครั้ง')}${R.stat('ตรงเวลา', `<span style="color:var(--ok)">${me.on_time}</span>`, 'ภายใน ' + esc(R.settingVal('close_due_time', '21:00')) + ' น.')}
          ${R.stat('หลังเวลา', `<span style="color:${me.late ? 'var(--warn)' : 'inherit'}">${me.late}</span>`)}${R.stat('ร้านค้างคืนฉัน', baht(owed.reduce((s, x) => s + Number(x.amount), 0)), owed.length + ' รายการ')}</div>
        <p class="muted small" style="padding:0 4px">นับ 1 วันต่อวันที่ส่งรายงานปิดยอดสำเร็จ ทั้งผู้ส่งและคนที่ถูกเลือกว่าอยู่กะเดียวกัน</p>
        ${pay ? `${R.sec('ค่าจ้าง')}${R.mlist([['', [
          R.mrow('ได้รับแล้วในเดือนนี้', baht(pay.paid_gross), { sub: 'รวมส่วนที่เบิกไปก่อนแล้ว' }),
          R.mrow('วันทำงานที่ยังไม่ได้รับเงิน', pay.unpaid_dates.length + ' วัน', { sub: pay.unpaid_dates.map((d) => R.date(d).replace(/ \d{4}$/, '')).join(', '), tone: pay.unpaid_dates.length ? 'warn' : '' }),
          ...(pay.advances.length ? [R.mrow('เบิกล่วงหน้า รอหักรอบหน้า', baht(pay.advances.reduce((x, a) => x + Number(a.amount), 0)))] : [])]]])}
          ${R.list(pay.runs.filter((r) => r.status === 'done').map((r) => R.row({ static: true, icon: 'wallet', t: `${R.date(r.period_from)} – ${R.date(r.period_to)} · ${qty(r.days)} วัน`,
            s: `${money(r.daily_wage)}/วัน${(r.extras || []).map((x) => ' · ' + esc(x.label) + ' ' + money(x.amount)).join('')}${Number(r.advance_deducted) ? ' · หักเบิก ' + money(r.advance_deducted) : ''}`, v: baht(r.net_paid), vs: 'ได้รับ' })), 'ยังไม่มีการจ่ายค่าจ้างในเดือนนี้')}` : ''}
        ${R.sec('รายงานที่ส่ง')}
        ${R.list(list.map((x) => R.row({ static: true, icon: 'calendar', tone: x.on_time === false ? 'warn' : 'ok', t: R.date(x.biz_date),
          s: `${esc(x.submitted_by_name)}${x.submitted_by !== B().me.id ? ' (ร่วมกะ)' : ''} · ${R.time(x.submitted_at)} น. · ยอดขาย ${money(x.summary.total_net)}`,
          v: Number(x.variance) ? (Number(x.variance) > 0 ? '+' : '') + money(x.variance) : 'เงินตรง', pill: x.submitted_by === B().me.id ? (x.on_time ? '<span class="pill ok">ตรงเวลา</span>' : '<span class="pill warn">หลังเวลา</span>') : '' })), 'ยังไม่มีรายงานในเดือนนี้')}
        ${owed.length ? R.sec('รอร้านคืนเงิน') + R.list(owed.map((x) => R.row({ static: true, icon: 'wallet', t: esc(x.description), s: R.dt(x.occurred_at), v: baht(x.amount), pill: R.statusPill(x.status) }))) : ''}`;
      el.querySelectorAll('[data-mo]').forEach((b) => b.addEventListener('click', () => { mo = Number(b.dataset.mo); draw().catch(R.fail); }));
    }
    await draw();
  });

  // ------------------------------------------------------------ stock: daily use, days left, what to buy
  R.def('stock', { title: 'สต๊อกคงเหลือ', back: 'more' }, async function (el) {
    const [bal, pend] = await Promise.all([R.api('stock.balance', {}), R.api('stocktake.list', { status: 'pending' })]);
    const owner = R.can('report.view') && R.isOwnerView();
    const low = bal.filter((b) => b.status !== 'ok' || Number(b.suggest) > 0);
    const val = bal.reduce((s, b) => s + Number(b.value || 0), 0);
    // nothing counted or received yet: one box that says what to do instead of "out of stock" on every row
    const fresh = bal.length && bal.every((b) => !b.last_received && !Number(b.qty));
    bal.sort((a, b) => (Number(b.suggest) > 0) - (Number(a.suggest) > 0) || (Number(a.qty) < 0 ? -1 : 0) - (Number(b.qty) < 0 ? -1 : 0));
    el.innerHTML = `<div class="period-row">${R.can('stock.count') ? '<button class="period-pill" id="count">นับสต็อก</button>' : ''}<a class="period-pill" href="#/receive" style="text-decoration:none">รับสินค้า</a>${R.can('master.manage') && !fresh ? '<button class="period-pill" id="opening">ยอดยกมา</button>' : ''}</div>
      ${fresh && R.can('master.manage') ? `<div class="setup-box"><b>เริ่มนับสต๊อกครั้งแรก</b><span class="muted">ยังไม่มียอดยกมา ${bal.length} รายการ คงเหลือจึงเป็น 0 ทั้งหมด ใส่จำนวนที่มีอยู่จริงและต้นทุนต่อหน่วยครั้งเดียว</span><button class="btn primary" id="opening">ตั้งยอดยกมา</button></div>` : ''}
      ${pend.length && R.can('stock.approve') ? `<a class="banner" href="#/approvals" style="text-decoration:none;color:inherit"><span class="dot"></span><span>ผลนับสต็อกรออนุมัติ ${pend.length} ครั้ง · แตะเพื่อตรวจ</span></a>` : ''}
      ${owner && !fresh ? `<p class="muted" style="padding:0 4px">มูลค่า ${baht(val)} · ใกล้หมด / ควรซื้อ ${low.length} รายการ${bal.some((b) => !Number(b.avg_cost)) ? ' · ไม่มีต้นทุน ' + bal.filter((b) => !Number(b.avg_cost)).length : ''}</p>` : ''}
      ${owner ? R.table([
        { l: 'วัตถุดิบ', f: (b) => esc(b.name) },
        { l: 'คงเหลือ', num: true, main: true, f: (b) => (Number(b.qty) < 0 ? `<span style="color:var(--bad)">ติดลบ ${qty(b.qty)} ${esc(b.unit)}</span>` : `${qty(b.qty)} ${esc(b.unit)}`) },
        { l: 'พอใช้', num: true, pri: 1, f: (b) => (Number(b.qty) > 0 && b.days_left != null ? qty(b.days_left) + ' วัน' : '-') },
        { l: 'แนะนำซื้อ', num: true, pri: 1, f: (b) => (Number(b.suggest) ? `<b>${qty(b.suggest)} ${esc(b.unit)}</b>` : '-') },
        { l: 'สถานะ', pri: 1, f: (b) => (Number(b.qty) < 0 ? '<span class="pill bad">ขายเกินของที่รับเข้า ควรนับ</span>' : fresh || b.status === 'ok' ? '' : R.statusPill(b.status)) },
        { l: 'ใช้ในสูตร', pri: 2, f: (b) => (b.used_in_recipe ? 'ใช่' : 'ไม่อยู่ในสูตรสินค้าไหน') },
        { l: 'ใช้เฉลี่ย/วัน (14 วัน)', num: true, pri: 2, f: (b) => qty(b.avg_daily_use) },
        { l: 'ขั้นต่ำ', num: true, pri: 2, f: (b) => qty(b.min_qty) },
        ...(owner ? [{ l: 'ต้นทุน/หน่วย', num: true, pri: 2, f: (b) => (Number(b.avg_cost) ? money(b.avg_cost) : R.unconfirmed('ยังไม่มี')) },
        { l: 'มูลค่า', num: true, pri: 2, f: (b) => (Number(b.qty) > 0 ? money(b.value) : '-') }] : [])], bal, { click: 'led', empty: 'ยังไม่มีรายการสต็อก' })
        + '<p class="muted small" style="padding:0 4px">แนะนำซื้อ = ใช้เฉลี่ยต่อวัน × 2 วัน + ขั้นต่ำ − คงเหลือ</p>'
      : `${low.length ? `${R.sec('ใกล้หมด / ควรซื้อ')}${R.list(low.map((b) => R.row({ data: { led: b.id }, icon: 'box', tone: b.status === 'out' ? 'bad' : 'warn', t: esc(b.name),
        s: Number(b.suggest) ? `แนะนำซื้อ ${qty(b.suggest)} ${esc(b.unit)}` : 'ต่ำกว่าขั้นต่ำ', v: `${qty(b.qty)} ${esc(b.unit)}`, pill: R.statusPill(b.status) })))}` : ''}
      ${R.sec('ทั้งหมด')}
      ${R.list(bal.map((b) => R.row({ data: { led: b.id }, icon: 'box', t: esc(b.name),
        s: `ใช้เฉลี่ย ${qty(b.avg_daily_use)}/วัน${b.days_left != null ? ' · พอใช้ ' + qty(b.days_left) + ' วัน' : ''}${b.pending_count ? ' · รออนุมัติผลนับ' : ''}`, v: `${qty(b.qty)} ${esc(b.unit)}` })), 'ยังไม่มีรายการสต็อก')}`}`;
    const open = (id) => R.busy(null, async () => {
      const it = bal.find((x) => x.id === id);
      const rows = await R.api('stock.ledger', { stock_item_id: it.id });
      const K = { sale: 'ขาย', sale_reversal: 'ยกเลิกขาย', receipt: 'รับเข้า', receipt_reversal: 'ยกเลิกรับเข้า', waste: 'ของเสีย', waste_reversal: 'ยกเลิกของเสีย', count_adjust: 'ปรับตามยอดนับ' };
      R.modal(it.name, `<div class="stats">${R.stat('คงเหลือ', qty(it.qty) + ' ' + esc(it.unit))}${R.stat('ขั้นต่ำ', qty(it.min_qty))}${R.stat('ใช้เฉลี่ย/วัน', qty(it.avg_daily_use))}${R.stat('แนะนำซื้อ', qty(it.suggest))}</div>
        ${(it.products || []).length ? `<p class="muted small">ใช้กับ: ${it.products.map(esc).join(', ')}</p>` : ''}
        ${R.list(rows.slice(0, 60).map((r) => R.row({ static: true, t: K[r.kind] || r.kind, s: `${R.dt(r.occurred_at)}${r.by ? ' · ' + esc(r.by) : ''}${owner && r.unit_cost ? ' · @' + money(r.unit_cost) : ''}`, v: (Number(r.qty) > 0 ? '+' : '') + qty(r.qty) })), 'ยังไม่มีความเคลื่อนไหว')}`);
    });
    R.bindRows(el, 'led', open);
    const countSheet = (opening) => R.busy(null, async () => {
      const units = opening ? {} : await R.api('stock.units', {});
      const items = bal.filter((b) => b.active).map((b) => ({ ...b, system_qty: b.qty, units: units[b.id] }));
      const state = {};
      const m = R.modal(opening ? 'ตั้งยอดยกมา' : 'นับสต็อก', `<form class="form"><p class="muted small">${opening ? 'ใส่จำนวนและต้นทุนต่อหน่วยจริง ณ วันเริ่มใช้ระบบ มีผลทันที' : 'นับเป็นหน่วยที่สะดวก (กล่อง / ไม้ / ลูก / กิโล) ระบบรวมให้ ใส่เฉพาะที่นับ ผลนับรอเจ้าของร้านอนุมัติ'}</p>
        ${opening ? `<div class="list">${items.map((b) => `<div class="row static"><span class="body"><span class="t">${esc(b.name)}</span><span class="s">ในระบบ ${qty(b.qty)} ${esc(b.unit)}</span></span>
          <span style="display:grid;gap:6px;max-width:120px"><input type="number" min="0" step="any" inputmode="decimal" data-c="${b.id}" placeholder="นับได้ (${esc(b.unit)})" style="text-align:right" aria-label="นับได้">
          <input type="number" min="0" step="0.01" inputmode="decimal" data-u="${b.id}" placeholder="ต้นทุน/หน่วย" style="text-align:right" aria-label="ต้นทุน"></span></div>`).join('')}</div>`
          : `<div class="cnts">${items.map((b) => countBox(b, null)).join('')}</div>`}
        <button class="btn primary lg">บันทึก</button></form>`, { wide: true });
      if (!opening) bindCounts(m.el, items, state);
      m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
        const lines = opening ? [...m.el.querySelectorAll('[data-c]')].filter((i) => i.value !== '').map((i) => ({ stock_item_id: i.dataset.c, counted_qty: i.value,
          unit_cost: m.el.querySelector(`[data-u="${i.dataset.c}"]`).value || null })) : countPayload(items, state);
        await R.api('stocktake.create', { context: opening ? 'opening' : 'stocktake', lines }); m.close(); R.toast(opening ? 'ตั้งยอดยกมาแล้ว' : 'ส่งผลนับแล้ว รอเจ้าของร้านอนุมัติ'); R.route();
      }); });
    });
    on(el.querySelector('#count'), () => countSheet(false));
    on(el.querySelector('#opening'), () => countSheet(true));
  });
})();
