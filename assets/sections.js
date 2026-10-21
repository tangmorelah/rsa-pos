/* RSA - POS Assistant — owner sections with period filter and comparison: overview, sales, accounts/tax, products/SKU,
   purchases, delivery, investment/payback, staff */
(function () {
  'use strict';
  const R = window.RSA, esc = R.esc, money = R.money, qty = R.qty, baht = R.baht;
  const B = () => R.state.boot;
  const on = (node, fn) => node && node.addEventListener('click', fn);
  const pct = (v) => (v == null ? '-' : qty(v) + '%');
  const signed = (v) => (Number(v) > 0 ? '+' : '') + money(v);

  const SECTIONS = [['dashboard', 'ภาพรวม'], ['sales', 'ยอดขาย'], ['cashflow', 'เงินสด / Cashflow'], ['accounts', 'บัญชีเงิน / ภาษี'], ['products', 'สินค้า / SKU'],
    ['stock', 'สต๊อก'], ['expenses', 'ค่าใช้จ่าย'], ['purchases', 'ซื้อสินค้า'], ['delivery', 'Delivery'], ['invest', 'เงินลงทุน / คืนทุน'], ['staff', 'พนักงาน'], ['settings', 'ตั้งค่า']];
  R.sectTabs = (cur) => `<nav class="sect-tabs" aria-label="หมวดของเจ้าของร้าน">${SECTIONS.map(([r, t]) => `<a href="#/${r}" ${r === cur ? 'aria-current="page"' : ''}>${esc(t)}</a>`).join('')}</nav>`;
  // period pages redraw themselves when the filter changes
  function periodPage(el, cur, body) {
    async function draw() {
      const r = R.periodRange();
      el.innerHTML = `${R.sectTabs(cur)}${R.periodBar()}<div id="pbody" class="grid2"><div class="boot full">กำลังโหลด…</div></div>`;
      R.bindPeriod(el, () => draw().catch(R.fail));
      await body(el.querySelector('#pbody'), r, draw);
    }
    return draw();
  }
  const dayLabel = (iso) => { const d = new Date(iso + 'T12:00:00'); return d.getDate() + '/' + (d.getMonth() + 1); };

  // ------------------------------------------------------------ 1. overview: one big number, a quiet list of key numbers, then what to look at
  R.def('dashboard', { title: 'ภาพรวม', tab: 'dashboard' }, async function (el) {
    await periodPage(el, 'dashboard', async (box, r) => {
      const [ov, dash] = await Promise.all([R.api('report.overview', r), R.api('dashboard', {})]);
      const k = ov.kpi, p = ov.prev, n = ov.now;
      const target = Number(n.profit_target), mnp = Number(n.month_net_profit);
      const low = Number(n.min_working_capital) && Number(n.cash) < Number(n.min_working_capital);
      const cl = dash.close;
      const todo = dash.exceptions.slice().sort((a, b) => (a.level === 'warn' ? 0 : 1) - (b.level === 'warn' ? 0 : 1))
        .map((e) => R.row({ href: '#/' + (R.EX_ROUTE[e.kind] || 'dashboard'), icon: e.level === 'warn' ? 'shield' : 'list', tone: e.level === 'warn' ? 'warn' : '', t: esc(e.text) }));
      const canHol = R.can('settings.manage') && !cl, oneOff = (R.settingVal('closed_dates', []) || []).includes(R.today());
      // today first: was the day closed, and does the cash match
      const tol = Number(R.settingVal('cash_variance_tolerance', 0)) || 0, v = cl ? Number(cl.variance) : 0, varOff = cl && Math.abs(v) > tol;
      const status = cl
        ? { tone: varOff ? 'warn' : 'ok', t: `ปิดยอดวันนี้แล้ว ${R.time(cl.submitted_at)} น. · ${esc(cl.submitted_by_name)}${cl.on_time === false ? ' (หลังเวลา)' : ''}`
            + (varOff ? `<br><b>เงินสด${v < 0 ? 'ขาด' : 'เกิน'} ${money(Math.abs(v))} บาท</b>` : v ? ` · เงินสด ${signed(v)}` : ' · เงินสดตรง'), btn: varOff ? '<a class="btn small" href="#/approvals">ตรวจ</a>' : '' }
        : dash.holiday ? { tone: 'ok', t: `วันนี้ร้านหยุด${Number(dash.sales.orders_count) ? ` แต่มีการขาย ${dash.sales.orders_count} ออเดอร์ ควรส่งรายงานปิดยอด` : ' ไม่ต้องปิดยอด'}`, btn: '' }
        : { tone: '', t: `วันนี้ยังไม่ปิดยอด · ส่งภายใน ${esc(dash.due_time)} น.`, btn: '' };
      if (canHol && (!dash.holiday || oneOff)) status.btn += `<button type="button" class="btn small ghost" id="hol">${dash.holiday ? 'ยกเลิกวันหยุด' : 'วันนี้ร้านหยุด'}</button>`;
      // without product costs the profit is meaningless (100% margin): say what is missing instead; other gaps are a note
      const fl = k.profit_flags || {}, flags = Object.values(fl), noCost = !!fl.cost;
      const profit = !noCost
        ? R.mlist([['กำไร (ประมาณ)', [
            R.mrow('กำไรขั้นต้น', baht(k.gross_profit), { delta: R.delta(k.gross_profit, p.gross_profit), sub: 'อัตรากำไร ' + pct(k.margin_pct), href: '#/products' }),
            R.mrow('ของเสียต่อยอดขาย', pct(k.waste_pct), { sub: 'มูลค่า ' + money(k.waste), tone: Number(k.waste_pct) > 5 ? 'warn' : '', href: '#/products' }),
            ...(Number(k.markdown) ? [R.mrow('ลดราคาตอนเย็น', money(k.markdown), { href: '#/products' })] : []),
            ...(Number(k.staff_meals) ? [R.mrow('สวัสดิการทีมงาน', money(k.staff_meals), { sub: 'ราคาทุน', href: '#/products' })] : []),
            ...(target ? [R.mrow('กำไรสุทธิเดือนนี้ / เป้า', baht(mnp), { sub: `เป้า ${money(target)} · ${Math.round((mnp / target) * 100)}%`, href: '#/invest' })] : [])]]])
          + (flags.length ? `<p class="muted small" style="padding:4px 4px 0">ตัวเลขยังเป็นค่าประมาณ: ${flags.map(esc).join(' · ')}</p>` : '')
        : `<div class="pcard"><span class="k">กำไร</span><b>ยังคำนวณกำไรไม่ได้</b><span class="sub">${esc(fl.cost)} ใส่สูตรหรือต้นทุนแล้วระบบจะคำนวณให้</span>
            <a class="go" href="#/master/products" style="font-weight:600">ใส่สูตร / ต้นทุนสินค้า ›</a></div>`;
      box.innerHTML = `<div class="full today-bar ${status.tone}"><span class="dot"></span><span class="txt">${status.t}</span>${status.btn}</div>
        ${todo.length ? `<div class="full">${R.sec('ต้องทำ (' + todo.length + ')')}${R.shortList(todo, 3, '')}</div>` : ''}
        <a class="pcard full" href="#/sales" style="text-decoration:none;color:inherit">
          <span class="k">ยอดขาย · ${esc(R.periodLabel())}</span>
          <span class="big">${baht(k.revenue)} ${R.delta(k.revenue, p.revenue)}</span>
          <span class="sub">หน้าร้าน ${money(k.storefront)} · Delivery ${money(k.delivery)} · ${qty(k.orders)} ออเดอร์</span></a>
        <div class="full">${R.mlist([['เงิน', [
            R.mrow('เงินทุกบัญชี', baht(n.cash), { sub: Number(n.min_working_capital) ? 'เงินหมุนขั้นต่ำ ' + money(n.min_working_capital) : '', tone: low ? 'bad' : '', href: '#/cashflow' }),
            R.mrow('ในลิ้นชัก', baht(n.drawer), { href: '#/accounts' }),
            R.mrow('รอรับจาก Delivery', baht(n.delivery_receivable), { href: '#/delivery' }),
            R.mrow('ค้างจ่าย', baht(n.payables), { href: '#/approvals' }),
            ...(Number(n.owed_reimburse) ? [R.mrow('ร้านค้างคืนพนักงาน / เจ้าของ', baht(n.owed_reimburse), { tone: 'warn', href: '#/expenses' })] : [])]]])}</div>
        <div class="full">${profit}</div>`;
      on(box.querySelector('[data-sv]'), () => R.setStaffView(true));
      on(box.querySelector('#hol'), (ev) => R.busy(ev.currentTarget, async () => {
        const d = R.settingVal('closed_dates', []) || [], t = R.today();
        await R.api('settings.save', { key: 'closed_dates', value: d.includes(t) ? d.filter((x) => x !== t) : [...d, t], confirmed: true });
        await R.loadBoot(); R.toast(d.includes(t) ? 'ยกเลิกวันหยุดวันนี้แล้ว' : 'ตั้งวันนี้เป็นวันหยุดร้านแล้ว ไม่ต้องปิดยอดและไม่เตือน'); R.route();
      }));
    });
  });

  // ------------------------------------------------------------ 2. sales
  R.def('sales', { title: 'ยอดขาย', tab: 'sales' }, async function (el) {
    await periodPage(el, 'sales', async (box, r) => {
      const [ov, rs] = await Promise.all([R.api('report.overview', r), R.api('report.sales', { ...r, group: 'day' })]);
      const k = ov.kpi, p = ov.prev;
      const chs = [...new Set(rs.rows.map((x) => x.channel))];
      const days = [...new Set(rs.rows.map((x) => x.period))].sort().reverse().map((d) => {
        const row = { date: d, total: 0, orders: 0, discount: 0, fee: 0 };
        rs.rows.filter((x) => x.period === d).forEach((x) => { row[x.channel] = Number(x.net); row.total += Number(x.net); row.orders += Number(x.orders); row.discount += Number(x.discount); row.fee += Number(x.est_fee); });
        return row;
      });
      box.innerHTML = `<div class="kpis full">${R.kpi('ยอดขายรวม', baht(k.revenue), R.delta(k.revenue, p.revenue))}${R.kpi('ออเดอร์', qty(k.orders), R.delta(k.orders, p.orders))}
          ${R.kpi('เฉลี่ยต่อออเดอร์', baht(k.avg_ticket), R.delta(k.avg_ticket, p.avg_ticket))}${R.kpi('ส่วนลด / โปร', baht(k.discount), R.delta(k.discount, p.discount, true), Number(k.markdown) ? 'ลดราคาตอนเย็น ' + money(k.markdown) : '')}</div>
        <div class="card full">${R.lineChart(ov.series.map((s) => ({ ...s, label: dayLabel(s.date) })), [{ key: 'storefront', label: 'หน้าร้าน' }, { key: 'delivery', label: 'Delivery' }, { key: 'orders', label: 'ออเดอร์', color: '#8a98aa' }], { title: 'ยอดขายรายวัน' })}</div>
        <div class="card"><h2>ตามช่องทาง</h2>${R.donut(ov.channels.map((c) => ({ label: c.name, value: c.net })), { center: 'ยอดขาย' })}</div>
        <div class="card"><h2>เทียบช่วงก่อนหน้า</h2>
          <div class="sum-row"><span>ช่วงนี้</span><b>${baht(k.revenue)}</b></div><div class="sum-row"><span>ช่วงก่อน ${R.date(ov.prev_from)} – ${R.date(ov.prev_to)}</span><span>${baht(p.revenue)}</span></div>
          <div class="sum-row"><span>ต่าง</span><span>${signed(Number(k.revenue) - Number(p.revenue))} ${R.delta(k.revenue, p.revenue)}</span></div>
          <a class="btn block" href="#/orders" style="margin-top:10px">ดูรายการขายรายวัน</a></div>
        ${(rs.payments || []).length ? `<div class="card full"><h2>รับเงินหน้าร้านเข้าบัญชีไหน</h2>${R.mlist([['', rs.payments.map((x) => R.mrow(esc(x.account), money(x.amount), { sub: qty(x.orders) + ' ออเดอร์' }))]])}
          ${Number(rs.mixed_orders) ? `<p class="muted small">จ่ายผสม (เงินสด + QR ในบิลเดียว) ${qty(rs.mixed_orders)} ออเดอร์ นับแยกเข้าแต่ละบัญชีแล้ว</p>` : ''}</div>` : ''}
        <div class="full">${R.sec('ยอดขายรายวันแยกช่องทาง')}${R.table([{ l: 'วันที่', f: (d) => R.date(d.date) }, ...chs.map((c) => ({ l: c, num: true, f: (d) => money(d[c] || 0) })),
          { l: 'ออเดอร์', num: true, k: 'orders' }, { l: 'ส่วนลด', num: true, f: (d) => money(d.discount) }, { l: 'ค่าธรรมเนียมประมาณ', num: true, f: (d) => money(d.fee) }, { l: 'รวม', num: true, main: true, f: (d) => `<b>${money(d.total)}</b>` }],
          days, { empty: 'ไม่มียอดขายในช่วงนี้', foot: ['รวม', ...chs.map((c) => money(days.reduce((s, d) => s + (d[c] || 0), 0))), qty(days.reduce((s, d) => s + d.orders, 0)), money(days.reduce((s, d) => s + d.discount, 0)), money(days.reduce((s, d) => s + d.fee, 0)), money(days.reduce((s, d) => s + d.total, 0))] })}</div>`;
    });
  });

  // ------------------------------------------------------------ 4. accounts / tax: balances, bank statement lines, reconciliation
  R.def('accounts', { title: 'บัญชีเงิน / ภาษี', back: 'more' }, async function (el) {
    await periodPage(el, 'accounts', async (box, r, redraw) => {
      const cf = await R.api('cashflow.summary', {});
      const banks = cf.accounts.filter((a) => a.kind !== 'cash');
      let acc = R.store.get('recon.acc') || (banks[0] && banks[0].id);
      if (!banks.find((b) => b.id === acc) && banks[0]) acc = banks[0].id;
      const [rec, lines] = acc ? await Promise.all([R.api('bank.recon', { ...r, account_id: acc }), R.api('bank.list', { ...r, account_id: acc })]) : [{ days: [] }, []];
      const manage = R.can('cashflow.manage');
      const days = (rec.days || []).filter((d) => Number(d.expected_in) || Number(d.expected_out) || Number(d.actual_in) || Number(d.actual_out));
      const vat = R.settingVal('vat_registered', false);
      box.innerHTML = `<div class="full">${R.table([{ l: 'บัญชี', f: (a) => esc(a.name) + (a.opening_confirmed ? '' : ' ' + R.unconfirmed('ยอดยกมา')) }, { l: 'ประเภท', f: (a) => (a.is_drawer ? 'ลิ้นชักหน้าร้าน' : a.kind === 'bank' ? 'ธนาคาร' : a.kind) },
          { l: 'ยอดยกมา', num: true, f: (a) => money(a.opening_balance) }, { l: 'คงเหลือในระบบ', num: true, main: true, f: (a) => `<b>${money(a.balance)}</b>` }, { l: 'ยังไม่ตรวจกับ statement', num: true, f: (a) => (a.kind === 'cash' ? '-' : a.unreconciled) }], cf.accounts)}</div>
        ${banks.length ? `<div class="card full"><h2>กระทบยอดธนาคาร</h2>
          <div class="field"><span>บัญชี</span>${R.seg('racc', banks.map((b) => [b.id, b.name]), acc, 'wrap')}</div>
          <p class="muted small">ระบบคาดว่าเข้า = ออเดอร์ QR/โอน + เงินจากแพลตฟอร์ม + เงินฝากจากหน้าร้าน · เข้าจริง = รายการจาก statement ที่บันทึกไว้</p>
          ${R.table([{ l: 'วันที่', f: (d) => R.date(d.date) }, { l: 'QR / โอน', num: true, f: (d) => money(d.qr_orders) }, { l: 'Delivery', num: true, f: (d) => money(d.settlements) },
            { l: 'คาดว่าเข้า', num: true, f: (d) => money(d.expected_in) }, { l: 'เข้าจริง', num: true, f: (d) => money(d.actual_in) },
            { l: 'ต่าง (เข้า)', num: true, main: true, f: (d) => { const x = Number(d.actual_in) - Number(d.expected_in); return x ? `<b style="color:var(--warn)">${signed(x)}</b>` : '<span class="pill ok">ตรง</span>'; } },
            { l: 'คาดว่าออก', num: true, f: (d) => money(d.expected_out) }, { l: 'ออกจริง', num: true, f: (d) => money(d.actual_out) }], days, { empty: 'ไม่มีความเคลื่อนไหวในช่วงนี้' })}
          ${manage ? '<button class="btn primary" id="addl" style="margin-top:10px">+ บันทึกรายการจาก statement</button>' : ''}</div>
          <div class="full">${R.sec('รายการจาก statement')}${R.list(lines.map((b) => R.row({ data: b.status === 'done' && manage ? { bl: b.id } : {}, static: !(b.status === 'done' && manage), off: b.status === 'cancelled',
            icon: b.direction === 'in' ? 'download' : 'out', tone: b.direction === 'in' ? 'ok' : '', t: (b.direction === 'in' ? 'เงินเข้า ' : 'เงินออก ') + money(b.amount),
            s: `${R.dt(b.occurred_at)}${b.ref_no ? ' · ' + esc(b.ref_no) : ''}${b.description ? ' · ' + esc(b.description) : ''} · ${esc(b.by)}`, v: b.direction === 'in' ? '+' + money(b.amount) : '−' + money(b.amount) })), 'ยังไม่มีรายการในช่วงนี้')}</div>` : '<div class="note full">ยังไม่มีบัญชีธนาคาร เพิ่มที่ ข้อมูลหลัก › บัญชีเงิน</div>'}
        <div class="card"><h2>ภาษี</h2><div class="sum-row"><span>จดทะเบียน VAT</span><span>${vat ? 'ใช่' : 'ไม่ใช่'} ${R.settingOk('vat_registered') ? '' : R.unconfirmed()}</span></div>
          <div class="sum-row"><span>เลขผู้เสียภาษี</span><span>${esc(R.settingVal('tax_id', '') || '-')}</span></div>
          <p class="muted small">สรุปรายเดือนเป็นข้อมูลเตรียมให้นักบัญชี ไม่ใช่แบบยื่นภาษี</p>
          <div class="btn-row"><a class="btn" href="#/export">สมุดเงินกลาง</a><a class="btn" href="#/export">สรุปรายเดือนเตรียมภาษี</a></div></div>
        <div class="card"><h2>ตรวจรายการในระบบ</h2><p class="muted small">ติ๊กรายการเงินเข้า-ออกที่ตรงกับ statement ได้ที่หน้า เงินสด / Cashflow โดยแตะที่บัญชี</p><a class="btn block" href="#/cashflow">ไปหน้า เงินสด / Cashflow</a></div>`;
      const sg = box.querySelector('input[name="racc"]');
      if (sg) sg.closest('.seg').addEventListener('change', () => { R.store.set('recon.acc', R.segVal(box, 'racc')); redraw().catch(R.fail); });
      on(box.querySelector('#addl'), () => {
        const aw = R.attachWidget('bl', [['slip', 'สลิป / statement']], 'หลักฐาน');
        const m = R.modal('บันทึกรายการจาก statement', `<form class="form"><div class="field"><span>ประเภท</span>${R.seg('dir', [['in', 'เงินเข้า'], ['out', 'เงินออก']], 'in')}</div>
          <label class="field"><span>จำนวน (บาท)</span><input type="number" id="a" min="0.01" step="0.01" inputmode="decimal" class="input-amt" required></label>
          <label class="field"><span>วันเวลา</span><input type="datetime-local" id="at" value="${R.nowLocal()}"></label>
          <label class="field"><span>เลขอ้างอิง</span><input type="text" id="ref"></label><label class="field"><span>รายละเอียด</span><input type="text" id="d" placeholder="เช่น QR ลูกค้า, LINE MAN โอนเข้า"></label>
          ${aw.html}<button class="btn primary lg">บันทึก</button></form>`);
        aw.bind(m.el);
        m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
          await R.api('bank.create', { account_id: acc, direction: R.segVal(m.el, 'dir'), amount: R.val(m.el, '#a'), occurred_at: R.toIso(R.val(m.el, '#at')), ref_no: R.val(m.el, '#ref'), description: R.val(m.el, '#d'), attachment_ids: aw.ids() });
          m.close(); R.toast('บันทึกแล้ว'); redraw();
        }); });
      });
      box.querySelectorAll('[data-bl]').forEach((b) => b.addEventListener('click', async () => {
        const x = await R.askReason('ยกเลิกรายการ statement', { danger: true, ok: 'ยกเลิกรายการ' });
        if (x) R.busy(null, async () => { await R.api('bank.cancel', { id: b.dataset.bl, reason: x.reason }); redraw(); });
      }));
    });
  });

  // ------------------------------------------------------------ 5. products / SKU
  R.def('products', { title: 'สินค้า / SKU', back: 'more' }, async function (el) {
    await periodPage(el, 'products', async (box, r) => {
      const rp = await R.api('report.products', r);
      const tot = rp.products.reduce((s, x) => s + Number(x.revenue), 0);
      box.innerHTML = `<div class="kpis full">${R.kpi('ยอดขายสินค้า', baht(tot))}${R.kpi('สินค้าที่ขายได้', rp.products.filter((x) => Number(x.qty)).length + ' / ' + rp.products.length)}
          ${R.kpi('ยังไม่มีสูตร / ต้นทุน', rp.products.filter((x) => !x.cost_known).length + ' รายการ', '', 'กำไรยังเป็นค่าประมาณ', rp.products.some((x) => !x.cost_known) ? 'warn' : '')}
          ${R.kpi('ส่วนลดจากโปร', baht(rp.promotions.reduce((s, x) => s + Number(x.discount), 0)))}
          ${Number(rp.markdown.discount) ? R.kpi('ลดราคาตอนเย็น', baht(rp.markdown.discount), '', `${qty(rp.markdown.qty)} ชิ้นขายราคาลด · ของเสีย ${money(rp.used.waste)}`) : ''}</div>
        <div class="full">${R.table([
          { l: 'สินค้า', f: (x) => `${x.emoji ? esc(x.emoji) + ' ' : ''}${esc(x.name)}${x.active ? '' : ' <span class="pill">ปิดใช้</span>'}` },
          { l: 'ราคา', num: true, pri: 2, f: (x) => money(x.price) + (x.delivery_price != null ? `<br><span class="muted small">Delivery ${money(x.delivery_price)}</span>` : '') },
          { l: 'ขาย (หน้าร้าน / Delivery)', num: true, f: (x) => `${qty(x.qty)} ${esc(x.unit)}<br><span class="muted small">${qty(x.storefront_qty)} / ${qty(x.delivery_qty)}</span>` },
          { l: 'ยอดขาย', num: true, main: true, f: (x) => `<b>${money(x.revenue)}</b>` }, { l: 'ส่วนลด', num: true, f: (x) => money(x.discount) },
          { l: 'ต้นทุน', num: true, f: (x) => (x.cost_known ? money(x.cost) : R.unconfirmed('ไม่มีสูตร')) },
          { l: 'กำไรขั้นต้น', num: true, f: (x) => (x.cost_known ? money(x.gross_profit) : '-') }, { l: 'Margin', num: true, pri: 1, f: (x) => (x.cost_known ? pct(x.margin_pct) : '-') },
          { l: 'ขายราคาลด', num: true, pri: 2, f: (x) => (Number(x.markdown_qty) ? `${qty(x.markdown_qty)} <span class="muted small">ลด ${money(x.markdown_discount)}</span>` : '-') },
          { l: 'ขายเฉลี่ย/วันที่เปิด', num: true, f: (x) => qty(x.avg_per_day) }, { l: 'ของเสีย', num: true, f: (x) => qty(x.waste_qty) }], rp.products, { empty: 'ยังไม่มีสินค้า' })}
          ${rp.open_days < rp.days ? `<p class="muted small" style="padding:0 4px">ค่าเฉลี่ยต่อวันคิดจากวันที่ร้านเปิด ${rp.open_days} วัน (หยุด ${rp.days - rp.open_days} วัน)</p>` : ''}</div>
        <div class="card"><h2>โปรโมชันที่ใช้</h2>${R.list(rp.promotions.map((x) => R.row({ static: true, icon: 'tag', t: esc(x.name), s: x.lines + ' รายการ', v: '−' + money(x.discount) })), 'ไม่มีการใช้โปรในช่วงนี้')}
          ${R.can('master.manage') ? '<a class="btn block" href="#/master/promotions" style="margin-top:10px">จัดการโปรโมชัน</a>' : ''}</div>
        <div class="card"><h2>ของเสียและสวัสดิการทีมงาน</h2>${R.mlist([['', [R.mrow('ของเสีย', money(rp.used.waste), { tone: Number(rp.used.waste) ? 'warn' : '' }),
            R.mrow('สวัสดิการทีมงาน', money(rp.used.staff_meal), { sub: 'ราคาทุน' }), ...(Number(rp.used.owner_use) ? [R.mrow('เจ้าของหยิบใช้ (รายการเดิม)', money(rp.used.owner_use), { sub: 'ไม่นับเป็นต้นทุนร้าน' })] : [])]]])}
          ${R.list(rp.waste.map((w) => R.row({ static: true, icon: 'trash', tone: w.kind === 'waste' ? 'warn' : '', pill: w.kind !== 'waste' ? `<span class="pill">${R.WASTE_KIND[w.kind]}</span>` : '', t: esc(w.item), s: `${qty(w.qty)} ${esc(w.unit)} · ${w.times} ครั้ง · ${(w.reasons || []).map(esc).join(', ')}`, v: baht(w.cost) })), 'ไม่มีของเสีย')}
          ${R.can('master.manage') ? '<a class="btn block" href="#/master/products" style="margin-top:10px">แก้ราคา สูตร สินค้า</a>' : ''}</div>`;
    });
  });

  // ------------------------------------------------------------ 8. purchases
  const PM = { shop_bank: 'บัญชีร้าน', shop_cash: 'เงินสดร้าน', credit: 'เครดิต', unpaid: 'ยังไม่จ่าย' }, PAYER = { shop: 'ร้าน', owner: 'เจ้าของ', employee: 'พนักงาน' };
  R.def('purchases', { title: 'ซื้อสินค้า', back: 'more' }, async function (el) {
    await periodPage(el, 'purchases', async (box, r) => {
      const [list, bal] = await Promise.all([R.api('receipt.list', r), R.api('stock.balance', {})]);
      const live = list.filter((x) => x.status !== 'cancelled');
      const goods = live.reduce((s, x) => s + Number(x.goods_cost || x.total_cost), 0), trans = live.reduce((s, x) => s + Number(x.transport_cost || 0), 0);
      const buy = bal.filter((b) => Number(b.suggest) > 0);
      const km = R.settingVal('market_trip_km', 0), trips = R.settingVal('market_trips_per_week', 0), tdef = R.settingVal('transport_default', 0);
      box.innerHTML = `<div class="kpis full">${R.kpi('ซื้อของรวม', baht(goods + trans), '', live.length + ' บิล')}${R.kpi('ค่าของ', baht(goods))}${R.kpi('ค่าขนส่ง', baht(trans), '', goods ? qty(Math.round((trans / goods) * 1000) / 10) + '% ของค่าของ' : '')}
          ${R.kpi('ค้างจ่าย / ค้างคืน', baht(live.filter((x) => x.expense && x.expense.status !== 'จ่ายแล้ว' && x.expense.status !== 'ยกเลิก').reduce((s, x) => s + Number(x.expense.amount), 0)))}</div>
        <div class="full">${R.table([{ l: 'วันที่', f: (x) => R.dt(x.received_at) }, { l: 'ร้านค้า', f: (x) => esc(x.supplier_name || '-') + (x.status === 'cancelled' ? ' ' + R.statusPill('cancelled') : '') },
          { l: 'รายการ', f: (x) => x.lines.map((l) => esc(l.item_name) + ' ' + qty(l.qty)).join(', ') }, { l: 'ค่าของ', num: true, f: (x) => money(x.goods_cost || x.total_cost) },
          { l: 'ขนส่ง', num: true, f: (x) => money(x.transport_cost || 0) }, { l: 'รวม', num: true, main: true, f: (x) => `<b>${money(x.total_cost)}</b>` },
          { l: 'จ่าย / ผู้ออกเงิน', f: (x) => `${esc(PM[x.pay_method] || '-')} · ${esc(PAYER[x.payer] || '-')}` }, { l: 'สถานะจ่าย', f: (x) => (x.expense ? R.statusPill(x.expense.status) : '-') },
          { l: 'หลักฐาน', f: (x) => (x.attachments.length ? x.attachments.length + ' ไฟล์' : '<span class="pill warn">ไม่มี</span>') }], list, { click: 'rc', empty: 'ยังไม่มีการซื้อในช่วงนี้' })}</div>
        <div class="card"><h2>ควรซื้อรอบหน้า</h2>${R.list(buy.map((b) => R.row({ static: true, icon: 'box', tone: b.status === 'out' ? 'bad' : 'warn', t: esc(b.name), s: `เหลือ ${qty(b.qty)} ${esc(b.unit)} · ใช้ ${qty(b.avg_daily_use)}/วัน`, v: qty(b.suggest) + ' ' + esc(b.unit) })), 'ยังไม่มีรายการที่ต้องซื้อ')}
          <p class="muted small">ใช้เฉลี่ยต่อวัน × 2 วัน + ขั้นต่ำ − คงเหลือ</p></div>
        <div class="card"><h2>รอบตลาด</h2><div class="sum-row"><span>ระยะทาง</span><span>${qty(km)} กม.</span></div><div class="sum-row"><span>รอบต่อสัปดาห์</span><span>${qty(trips)}</span></div>
          <div class="sum-row"><span>ค่าขนส่งต่อรอบ</span><span>${baht(tdef)}</span></div><div class="sum-row"><span>เฉลี่ยค่าขนส่งเข้าต้นทุน</span><span>${esc(R.ALLOC[R.settingVal('transport_method', 'value')] || '')}</span></div>
          <div class="btn-row" style="margin-top:10px"><a class="btn" href="#/settings">แก้ค่า</a><a class="btn primary" href="#/receive">+ รับสินค้า</a></div></div>`;
      R.bindRows(box, 'rc', (id) => R.receiptSheet(list.find((x) => x.id === id)));
    });
  });

  // ------------------------------------------------------------ Delivery payout: what the platform paid, matched to our orders
  // Revenue stays at the full sales amount; commission, VAT on commission, ads / promo and other deductions are recorded as costs.
  R.settlementSheet = function (chId, from, to, done) {
    const ch = B().channels.find((c) => c.id === chId) || {};
    const banks = B().accounts.filter((a) => !a.is_drawer);
    const aw = R.attachWidget('set', [['settlement_report', 'รายงาน/statement แพลตฟอร์ม'], ['tax_invoice', 'ใบกำกับภาษีค่าคอมมิชชัน'], ['slip', 'หลักฐานเงินเข้า']], 'รายงานจากแพลตฟอร์ม / ใบกำกับภาษีค่าคอม');
    const m = R.modal('เงินเข้าจาก ' + (ch.name || ''), `<form class="form">
      <div class="two"><label class="field"><span>ขายตั้งแต่</span><input type="date" id="from" value="${from}"></label>
      <label class="field"><span>ถึง</span><input type="date" id="to" value="${to}"></label></div>
      <div id="sys"></div>
      <label class="field"><span class="req">ยอดขายตามรายงานแพลตฟอร์ม (ก่อนหัก)</span><input type="number" step="0.01" inputmode="decimal" id="gross" class="input-amt" required></label>
      <div class="card flat"><span class="muted small">แพลตฟอร์มหักอะไรบ้าง (ดูจาก statement)</span>
        <div class="two"><label class="field"><span>ค่าคอมมิชชัน (GP)</span><input type="number" step="0.01" inputmode="decimal" id="b-commission"></label>
        <label class="field"><span>VAT 7% ของค่าคอม</span><input type="number" step="0.01" inputmode="decimal" id="b-vat"></label></div>
        <div class="two"><label class="field"><span>ค่าโฆษณา / โปรที่ร้านออก</span><input type="number" step="0.01" inputmode="decimal" id="b-marketing"></label>
        <label class="field"><span>ปรับปรุงอื่น (ติดลบได้)</span><input type="number" step="0.01" inputmode="decimal" id="b-other"></label></div>
        <div class="sum-row"><span>หักรวม</span><b id="feeSum">0.00</b></div></div>
      <label class="field"><span class="req">เงินเข้าบัญชีจริง</span><input type="number" step="0.01" inputmode="decimal" id="net" class="input-amt" required></label>
      <div id="chk"></div>
      <div class="field"><span>เข้าบัญชี</span>${R.seg('sacc', banks.map((a) => [a.id, a.name]), banks[0] && banks[0].id, 'wrap')}</div>
      <details><summary>วันที่เงินเข้า เลขอ้างอิง หลักฐาน</summary><div class="form" style="margin-top:8px">
        <label class="field"><span>วันที่เงินเข้า</span><input type="datetime-local" id="at" value="${R.nowLocal()}"></label>
        <label class="field"><span>เลขอ้างอิงรอบจ่าย</span><input type="text" id="ref"></label>${aw.html}</div></details>
      <p class="muted small">บันทึกบัญชี: รายได้ = ยอดขายเต็ม ส่วนที่แพลตฟอร์มหักเป็นค่าใช้จ่ายของร้าน เก็บใบกำกับภาษีค่าคอมไว้เป็นหลักฐาน</p>
      <button class="btn primary lg">บันทึกเงินเข้า</button></form>`);
    aw.bind(m.el);
    const v = (id) => Number(R.val(m.el, id)) || 0;
    let pv = null;
    const check = () => {
      const fee = ['#b-commission', '#b-vat', '#b-marketing', '#b-other'].reduce((t, id) => t + v(id), 0), g = v('#gross'), n = v('#net');
      m.el.querySelector('#feeSum').textContent = money(fee);
      const diff = Math.round((g - fee - n) * 100) / 100;
      const rate = g ? Math.round((fee / g) * 1000) / 10 : 0;
      m.el.querySelector('#chk').innerHTML = !g ? '' : diff ? `<div class="note">ยอดขาย − หักรวม = ${money(g - fee)} แต่เงินเข้า ${money(n)} ต่าง ${money(diff)} · ใส่ส่วนต่างในช่อง "ปรับปรุงอื่น"</div>`
        : `<div class="banner ok"><span class="dot"></span><span>ตัวเลขตรงกัน · หักจริง ${rate}%${pv && Number(pv.fee_pct) ? ` (ตั้งไว้ ${qty(pv.fee_pct)}%)` : ''}</span></div>`;
    };
    const prev = async () => {
      pv = await R.api('settlement.preview', { channel_id: chId, from: R.val(m.el, '#from'), to: R.val(m.el, '#to') });
      const sg = pv.staff_gross != null ? Number(pv.staff_gross) : null;
      m.el.querySelector('#sys').innerHTML = `<div class="mlist">${R.mrow('ในระบบ (ออเดอร์ที่บันทึก)', baht(pv.system_gross), { sub: pv.orders + ' ออเดอร์' })}
        ${R.mrow('พนักงานกรอกตอนปิดยอด', sg == null ? '-' : baht(sg), { sub: sg != null && Math.abs(sg - pv.system_gross) > 0.009 ? 'ต่างจากระบบ ' + signed(sg - pv.system_gross) : '', tone: sg != null && Math.abs(sg - pv.system_gross) > 0.009 ? 'warn' : '' })}
        ${R.mrow('คาดว่าหัก ' + qty(pv.fee_pct) + '%', money(pv.est_fee), { sub: 'คาดว่าได้รับ ' + money(pv.system_gross - pv.est_fee) })}</div>`;
      if (!m.el.querySelector('#gross').value) m.el.querySelector('#gross').value = Number(pv.system_gross).toFixed(2);
      check();
    };
    m.el.querySelector('#from').addEventListener('change', () => prev().catch(R.fail)); m.el.querySelector('#to').addEventListener('change', () => prev().catch(R.fail));
    m.el.querySelectorAll('input[type=number]').forEach((i) => i.addEventListener('input', check));
    prev().catch(R.fail);
    m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
      const bd = {}; ['commission', 'vat', 'marketing', 'other'].forEach((k) => { const x = R.val(m.el, '#b-' + k); if (x !== '') bd[k] = Number(x); });
      await R.api('settlement.create', { channel_id: chId, from: R.val(m.el, '#from'), to: R.val(m.el, '#to'), reported_gross: R.val(m.el, '#gross'), breakdown: bd,
        net: R.val(m.el, '#net'), account_id: R.segVal(m.el, 'sacc'), deposited_at: R.toIso(R.val(m.el, '#at')), ref_no: R.val(m.el, '#ref'), attachment_ids: aw.ids() });
      m.close(); R.toast('บันทึกเงินเข้าแล้ว'); done();
    }); });
  };

  R.def('delivery', { title: 'Delivery', back: 'more' }, async function (el) {
    await periodPage(el, 'delivery', async (box, r, redraw) => {
      const d = await R.api('report.delivery', r), manage = R.can('cashflow.manage');
      const BD = { commission: 'ค่าคอม', vat: 'VAT ค่าคอม', marketing: 'โฆษณา/โปร', other: 'อื่น ๆ' };
      box.innerHTML = `<div class="full">${R.mlist([['ช่องทาง', d.channels.map((c) => R.mrow(c.name, baht(c.gross), {
          sub: `${c.orders} ออเดอร์ · ตั้งหัก ${qty(c.fee_pct)}%${c.fee_confirmed ? '' : ' (ยังไม่ยืนยัน)'}${c.actual_fee_pct != null ? ' · หักจริง ' + qty(c.actual_fee_pct) + '%' : ''} · รอรับ ${money(c.unsettled)}`,
          tone: c.actual_fee_pct != null && Math.abs(Number(c.actual_fee_pct) - Number(c.fee_pct)) >= 1 ? 'warn' : '' }))]])}
          ${d.channels.some((c) => c.actual_fee_pct != null && Math.abs(Number(c.actual_fee_pct) - Number(c.fee_pct)) >= 1) ? '<p class="muted small" style="padding:4px">อัตราหักจริงต่างจากที่ตั้งไว้ ควรแก้ % ค่าธรรมเนียมที่ ข้อมูลหลัก › ช่องทางขาย เพื่อให้กำไรประมาณแม่นขึ้น</p>' : ''}</div>
        <div class="full">${R.sec('รอบที่ยังไม่ได้บันทึกเงินเข้า (จันทร์–อาทิตย์)')}
          ${R.table([{ l: 'แพลตฟอร์ม / สัปดาห์', f: (w) => `${esc(w.channel)}<br><span class="muted small">${R.date(w.from)} – ${R.date(w.to)}</span>` },
            { l: 'ออเดอร์', num: true, k: 'orders' }, { l: 'ยอดในระบบ', num: true, f: (w) => money(w.gross) },
            { l: 'พนักงานกรอก', num: true, f: (w) => (w.staff_gross == null ? '-' : Math.abs(Number(w.staff_gross) - Number(w.gross)) > 0.009 ? `<span style="color:var(--warn)">${money(w.staff_gross)}</span>` : money(w.staff_gross)) },
            { l: 'คาดว่าได้รับ', num: true, main: true, f: (w) => money(w.est_net) },
            { l: '', f: (w) => (manage ? `<button type="button" class="btn small primary" data-pay="${w.channel_id}|${w.from}|${w.to}">บันทึกเงินเข้า</button>` : '') }], d.open_weeks, { empty: 'บันทึกเงินเข้าครบทุกรอบแล้ว' })}</div>
        <div class="full">${R.sec('เงินเข้าที่บันทึกแล้ว · เทียบ 3 ยอด')}
          ${R.table([{ l: 'แพลตฟอร์ม / รอบขาย', f: (x) => `${esc(x.channel_name)}<br><span class="muted small">${R.date(x.period_from)} – ${R.date(x.period_to)} · ${x.orders} ออเดอร์</span>` },
            { l: 'ในระบบ', num: true, f: (x) => money(x.system_gross) },
            { l: 'พนักงานกรอก', num: true, f: (x) => (x.staff_gross == null ? '-' : money(x.staff_gross)) },
            { l: 'ตามแพลตฟอร์ม', num: true, f: (x) => { const df = Number(x.reported_gross) - Number(x.system_gross); return money(x.reported_gross) + (Math.abs(df) > 0.009 ? `<br><span class="pill warn">${signed(df)}</span>` : ''); } },
            { l: 'หัก', num: true, f: (x) => `${money(x.fee)} <span class="muted small">(${qty(x.fee_pct_actual)}%)</span>${Object.keys(x.fee_breakdown || {}).length ? '<br><span class="muted small">' + Object.entries(x.fee_breakdown).map(([k, v]) => BD[k] + ' ' + money(v)).join(' · ') + '</span>' : ''}` },
            { l: 'เงินเข้าจริง', num: true, main: true, f: (x) => `<b>${money(x.net)}</b><br><span class="muted small">${R.date(x.deposited_at)}</span>` },
            { l: 'หลักฐาน', f: (x) => (x.attachments.length ? R.attachLinks(x.attachments) : '<span class="pill warn">ไม่มี</span>') }], d.settlements, { empty: 'ยังไม่มีเงินเข้าจากแพลตฟอร์มในช่วงนี้' })}</div>
        <div class="card full"><h2>ทำบัญชีและภาษีจากยอดไหน</h2>
          <p class="small">ใช้ <b>ยอดขายเต็ม</b> (ยอดที่แพลตฟอร์มแสดงว่าเป็นยอดขายของร้าน ก่อนหักค่าคอม) เป็นรายได้ และบันทึกส่วนที่แพลตฟอร์มหัก (ค่าคอม, VAT ของค่าคอม, ค่าโฆษณา) เป็นค่าใช้จ่าย โดยเก็บใบกำกับภาษี/ใบเสร็จค่าคอมจากแพลตฟอร์มเป็นหลักฐาน ระบบทำแบบนี้ให้อัตโนมัติ</p>
          <p class="muted small">ไม่ใช้ยอดเงินเข้าสุทธิเป็นรายได้ เพราะจะทำให้รายได้ต่ำกว่าจริงและไม่ตรงกับรายงานที่แพลตฟอร์มส่งให้สรรพากร ค่าส่งที่ลูกค้าจ่ายให้แพลตฟอร์มไม่ใช่รายได้ของร้าน · ควรยืนยันรายละเอียดกับนักบัญชีของร้าน</p></div>
        <details class="full"><summary>ยอดรายวัน (${d.rows.length} แถว)</summary><div style="margin-top:8px">${R.table([{ l: 'วันที่ขาย', f: (x) => R.date(x.date) }, { l: 'แพลตฟอร์ม', k: 'channel' }, { l: 'ออเดอร์', num: true, k: 'orders' },
          { l: 'ในระบบ', num: true, main: true, f: (x) => money(x.gross) }, { l: 'พนักงานกรอก', num: true, f: (x) => (x.staff_gross == null ? '-' : money(x.staff_gross)) },
          { l: 'คาดว่าได้รับ', num: true, f: (x) => money(x.est_net) }, { l: 'คาดว่าเงินเข้า', f: (x) => R.date(x.expected_date) },
          { l: 'สถานะ', f: (x) => `<span class="pill ${x.status === 'รับเงินแล้ว' ? 'ok' : x.status === 'เลยกำหนด' ? 'bad' : 'warn'}">${esc(x.status)}</span>` }], d.rows, { empty: 'ไม่มียอด Delivery ในช่วงนี้' })}</div></details>`;
      box.querySelectorAll('[data-pay]').forEach((b) => b.addEventListener('click', (ev) => { ev.stopPropagation(); const [c, f, t] = b.dataset.pay.split('|'); R.settlementSheet(c, f, t, () => redraw().catch(R.fail)); }));
    });
  });

  // ------------------------------------------------------------ 10. investment / payback
  R.def('invest', { title: 'เงินลงทุน / คืนทุน', back: 'more' }, async function (el) {
    const [pb, cf] = await Promise.all([R.api('payback.summary', {}), R.api('cashflow.summary', {})]);
    const manage = R.can('cashflow.manage');
    const KIND = { capital_in: 'ลงทุนเพิ่ม (เงินสด)', loan_in: 'กู้ยืม', capital_return: 'ถอนเงินเจ้าของ / คืนทุน', loan_repayment: 'ชำระหนี้', owner_paid: 'เจ้าของจ่ายแทนร้าน' };
    el.innerHTML = `${R.sectTabs('invest')}
      ${pb.needs_review ? `<div class="note">มีรายการลงทุน ${pb.needs_review} รายการที่มาจากข้อมูลก่อนหน้า ยังต้องตรวจทาน ตัวเลขคืนทุนจึงยังไม่ใช่ตัวเลขจริง</div>` : ''}
      <div class="kpis">${R.kpi('เงินลงทุนรวม', baht(pb.investment_total), '', 'ได้คืนภายหลัง ' + money(pb.refundable))}${R.kpi('ฐานคืนทุน', baht(pb.payback_base), '', 'ไม่รวมส่วนที่ได้คืน')}
        ${R.kpi('กำไรสะสม (ประมาณ)', baht(pb.profit_to_date), '', pb.profit_complete ? '' : 'ยังไม่ครบ')}${R.kpi('เหลือต้องคืนทุน', baht(pb.remaining), '', pb.months_left && pb.months_left <= 120 ? 'ประมาณ ' + pb.months_left + ' เดือน' : pb.remaining > 0 ? 'ข้อมูลกำไรยังน้อย ประเมินเวลาไม่ได้' : '')}</div>
      <div class="card"><h2>ความคืบหน้าคืนทุน ${pb.progress_pct != null ? qty(pb.progress_pct) + '%' : ''}</h2>${R.meter(pb.progress_pct || 0, 'คืนทุน')}
        <p class="muted small">กำไรสุทธิเฉลี่ย 3 เดือนล่าสุด ${baht(pb.avg_month_profit)} / เดือน (ประมาณ)</p></div>
      ${R.sec('รายการลงทุน', manage ? '<button type="button" id="add">+ เพิ่มรายการ</button>' : '')}
      ${R.table([{ l: 'รายการ', f: (x) => esc(x.category) + (x.note ? `<br><span class="muted small">${esc(x.note)}</span>` : '') }, { l: 'จำนวน', num: true, main: true, f: (x) => money(x.amount) },
        { l: 'ได้คืนภายหลัง', num: true, f: (x) => money(x.refundable_amount) }, { l: 'นับเป็นเงินลงทุน', f: (x) => (x.counts_as_investment ? 'ใช่' : 'ไม่') }, { l: 'ใช้คิดคืนทุน', f: (x) => (x.in_payback ? 'ใช่' : 'ไม่') },
        { l: 'สถานะข้อมูล', f: (x) => (x.data_status === 'ยืนยันแล้ว' ? '<span class="pill ok">ยืนยันแล้ว</span>' : `<span class="pill warn">${esc(x.data_status)}</span>`) }], pb.items, { click: manage ? 'inv' : null, empty: 'ยังไม่มีรายการลงทุน' })}
      <p class="muted small" style="padding:0 4px">ค่าเช่ารายเดือนเป็นค่าใช้จ่าย ไม่นับเป็นเงินลงทุน</p>
      ${R.sec('หนี้')}<div class="stats">${R.stat('หนี้ตั้งต้น', baht(pb.opening_debt), pb.opening_debt_confirmed ? '' : 'ยังไม่ยืนยัน')}${R.stat('ชำระแล้ว', baht(pb.debt_paid))}${R.stat('คงเหลือ', baht(pb.debt_left))}${R.stat('ทุนเงินสดที่ใส่', baht(pb.cash_capital_in), 'ถอนแล้ว ' + money(pb.capital_returned))}</div>
      ${R.sec('ประวัติทุน ถอน และการใช้กำไร', '<a href="#/cashflow">บันทึก</a>')}
      ${R.list([...cf.capital_rows.filter((c) => c.kind !== 'investment_item').map((c) => R.row({ static: true, off: c.status === 'cancelled', icon: 'plus', t: KIND[c.kind] || c.kind, s: `${R.date(c.occurred_at)} · ${esc(c.party)}${c.account_name ? ' · ' + esc(c.account_name) : ''}`, v: baht(c.amount) })),
        ...cf.declarations.map((d) => R.row({ static: true, off: d.status === 'cancelled', icon: 'check', t: 'ใช้กำไร · ' + esc(R.PURPOSE[d.purpose] || d.purpose), s: `${R.date(d.declared_at)} · ${esc(d.recipient)}`, v: baht(d.amount) }))], 'ยังไม่มีรายการ')}`;
    const edit = (x) => {
      x = x || { counts_as_investment: true, in_payback: true, data_status: 'ยืนยันแล้ว', refundable_amount: 0 };
      const m = R.modal(x.id ? 'แก้รายการลงทุน' : 'เพิ่มรายการลงทุน', `<form class="form">
        <label class="field"><span>รายการ</span><input type="text" id="cat" value="${esc(x.category || '')}" placeholder="เช่น ค่าเซ้ง เงินประกัน อุปกรณ์" required></label>
        <div class="two"><label class="field"><span>จำนวน (บาท)</span><input type="number" id="amt" min="0.01" step="0.01" inputmode="decimal" value="${x.amount ?? ''}" required></label>
        <label class="field"><span>ได้คืนภายหลัง</span><input type="number" id="ref" min="0" step="0.01" inputmode="decimal" value="${x.refundable_amount ?? 0}"></label></div>
        <label class="check"><input type="checkbox" id="cnt" ${x.counts_as_investment ? 'checked' : ''}> นับเป็นเงินลงทุน</label>
        <label class="check"><input type="checkbox" id="pay" ${x.in_payback ? 'checked' : ''}> ใช้คิดระยะคืนทุน</label>
        <div class="field"><span>สถานะข้อมูล</span>${R.seg('ds', [['ยืนยันแล้ว', 'ยืนยันแล้ว'], ['ต้องตรวจทาน', 'ต้องตรวจทาน']], x.data_status === 'ยืนยันแล้ว' ? 'ยืนยันแล้ว' : 'ต้องตรวจทาน')}</div>
        <label class="field"><span>หมายเหตุ</span><input type="text" id="n" value="${esc(x.note || '')}"></label>
        <div class="btn-row">${x.id ? '<button type="button" class="btn danger" id="cx">ยกเลิกรายการ</button>' : ''}<button class="btn primary lg">บันทึก</button></div></form>`);
      m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
        const data = { category: R.val(m.el, '#cat'), amount: R.val(m.el, '#amt'), refundable_amount: R.val(m.el, '#ref') || 0, counts_as_investment: R.val(m.el, '#cnt'), in_payback: R.val(m.el, '#pay'), data_status: R.segVal(m.el, 'ds'), note: R.val(m.el, '#n') };
        if (x.id) await R.api('investment.save', { id: x.id, ...data }); else await R.api('capital.create', { kind: 'investment_item', ...data });
        m.close(); R.toast('บันทึกแล้ว'); R.route();
      }); });
      on(m.el.querySelector('#cx'), async () => { m.close(); const r = await R.askReason('ยกเลิกรายการลงทุน', { danger: true, ok: 'ยกเลิกรายการ' });
        if (r) R.busy(null, async () => { await R.api('capital.cancel', { capital_id: x.id, reason: r.reason }); R.route(); }); });
    };
    on(el.querySelector('#add'), () => edit());
    R.bindRows(el, 'inv', (id) => edit(pb.items.find((x) => x.id === id)));
  });

  // ------------------------------------------------------------ 11. staff: workdays, on time, weekly wages
  // Pay sheet: days come from submitted daily closes (submitter + co-workers); wage = days x daily wage + extras − advances.
  R.payrollSheet = function (userId, done, from, to) {
    const banks = B().accounts;
    const st = { extras: [], days: null, reason: '' };
    const m = R.modal('จ่ายค่าจ้าง', '<div class="form" id="pr"><div class="boot">กำลังโหลด…</div></div>');
    const aw = R.attachWidget('pr', [['slip', 'สลิปโอน'], ['receipt', 'ใบรับเงิน']], 'สลิป / ใบรับเงินค่าจ้าง');
    let pv;
    async function load(f, t) { pv = await R.api('payroll.preview', { user_id: userId, from: f, to: t }); st.days = null; draw(); }
    const days = () => (st.days == null ? pv.unpaid_days : st.days);
    const totals = () => { const base = Math.round(days() * Number(pv.daily_wage || 0) * 100) / 100, ext = st.extras.reduce((t, x) => t + (Number(x.amount) || 0), 0);
      return { base, ext, gross: base + ext, net: base + ext - Number(pv.advance_total) }; };
    function draw() {
      const t = totals(), box = m.el.querySelector('#pr');
      box.innerHTML = `<div class="card flat"><b>${esc(pv.display_name)}</b>
          <div class="two"><label class="field"><span>ตั้งแต่</span><input type="date" id="pf" value="${pv.from}"></label><label class="field"><span>ถึง</span><input type="date" id="pt" value="${pv.to}"></label></div>
          <div class="field"><span>วันทำงานจากรายงานปิดยอด</span><div class="chips" style="flex-wrap:wrap">${pv.dates.length ? pv.dates.map((d) => `<span class="chip" style="min-height:30px;padding:2px 10px;${d.paid ? 'opacity:.4;text-decoration:line-through' : ''}" title="${d.paid ? 'จ่ายแล้ว' : ''}">${R.date(d.date).replace(/ \d{4}$/, '')}${d.submitted ? '' : ' (ร่วมกะ)'}${d.on_time === false && d.submitted ? ' ⏰' : ''}</span>`).join('') : '<span class="muted small">ไม่มีวันทำงานในช่วงนี้</span>'}</div>
            <span class="muted small">ยังไม่จ่าย ${pv.unpaid_days} วัน · ขีดฆ่า = จ่ายไปแล้ว</span></div></div>
        ${pv.daily_wage ? '' : `<div class="note">ยังไม่ได้ตั้งค่าแรงต่อวัน <label class="field"><span>ค่าแรง/วัน (บาท)</span><input type="number" id="setw" min="0" step="1" inputmode="decimal"></label><button type="button" class="btn small" id="savew">บันทึกค่าแรง</button></div>`}
        <div class="two"><label class="field"><span>จำนวนวันที่จ่าย</span><input type="number" id="dd" min="0" step="0.5" inputmode="decimal" value="${days()}"></label>
          <div class="field"><span>ค่าแรง/วัน</span><b style="padding:10px 0">${pv.daily_wage ? money(pv.daily_wage) : '-'}</b></div></div>
        ${days() !== pv.unpaid_days ? `<label class="field"><span class="req">ทำไมไม่เท่ากับที่ระบบนับ (${pv.unpaid_days} วัน)</span><input type="text" id="dr" value="${esc(st.reason)}" placeholder="เช่น มาทำงานแต่ไม่ได้ถูกเลือกว่าร่วมกะ"></label>` : ''}
        <div class="field"><span>ค่าพิเศษ (บวก / หัก ใส่ติดลบได้)</span>${st.extras.map((x, i) => `<div class="two"><input type="text" data-xl="${i}" value="${esc(x.label)}" placeholder="เช่น โบนัส ค่าล่วงเวลา หักของเสีย"><input type="number" step="1" inputmode="decimal" data-xa="${i}" value="${x.amount ?? ''}" placeholder="บาท"></div>`).join('')}
          <button type="button" class="btn small" id="addx">+ เพิ่มค่าพิเศษ</button></div>
        <div class="mlist">${R.mrow('ค่าแรง ' + days() + ' วัน × ' + money(pv.daily_wage || 0), money(t.base))}
          ${t.ext ? R.mrow('ค่าพิเศษ', (t.ext > 0 ? '+' : '') + money(t.ext)) : ''}
          ${R.mrow('รวมค่าจ้าง', `<b>${money(t.gross)}</b>`)}
          ${Number(pv.advance_total) ? R.mrow('หักเบิกล่วงหน้า', '−' + money(pv.advance_total), { sub: pv.advances.map((a) => R.date(a.occurred_at) + ' ' + money(a.amount)).join(' · '), tone: 'warn' }) : ''}
          ${R.mrow('จ่ายสุทธิ', `<b style="font-size:1.2rem">${baht(t.net)}</b>`)}</div>
        <div class="field"><span>จ่ายจาก</span>${R.seg('pacc', banks.map((a) => [a.id, a.name]), (banks.find((a) => a.is_drawer) || banks[0] || {}).id, 'wrap')}</div>
        <label class="field" id="refbox"><span class="req">เลขอ้างอิง / เลขที่สลิป</span><input type="text" id="ref"></label>
        ${aw.html}
        <label class="field"><span>หมายเหตุ</span><input type="text" id="note"></label>
        ${!pv.unpaid_days && st.days == null ? `<div class="note info">ช่วงนี้จ่ายครบแล้ว เลือกช่วงวันที่ใหม่ หรือใส่จำนวนวันเอง (ต้องมีเหตุผล)</div>` : ''}
        <button type="button" class="btn primary lg" id="pay" ${!pv.unpaid_days && st.days == null ? 'disabled' : ''}>จ่าย ${baht(t.net)}</button>
        ${pv.runs.length ? R.sec('ประวัติจ่ายค่าจ้าง') + R.list(pv.runs.map((r) => R.row({ data: r.status === 'done' ? { run: r.id } : {}, static: r.status !== 'done', off: r.status !== 'done', icon: 'wallet',
          t: `${R.date(r.period_from)} – ${R.date(r.period_to)} · ${qty(r.days)} วัน`, s: `รวม ${money(r.gross)}${Number(r.advance_deducted) ? ' · หักเบิก ' + money(r.advance_deducted) : ''}${r.status !== 'done' ? ' · ยกเลิก: ' + esc(r.cancel_reason || '') : ''}`, v: money(r.net_paid), vs: r.status === 'done' ? 'แตะเพื่อยกเลิก' : '', chev: false }))) : ''}`;
      aw.bind(box);
      const refBox = () => { const a = banks.find((y) => y.id === R.segVal(box, 'pacc')); box.querySelector('#refbox').hidden = !a || a.kind === 'cash' || t.net <= 0; };
      box.querySelector('input[name="pacc"]').closest('.seg').addEventListener('change', refBox); refBox();
      box.querySelector('#pf').addEventListener('change', () => load(R.val(box, '#pf'), R.val(box, '#pt')).catch(R.fail));
      box.querySelector('#pt').addEventListener('change', () => load(R.val(box, '#pf'), R.val(box, '#pt')).catch(R.fail));
      box.querySelector('#dd').addEventListener('change', (e) => { st.days = e.target.value === '' ? null : Number(e.target.value); draw(); });
      const dr = box.querySelector('#dr'); if (dr) dr.addEventListener('input', () => { st.reason = dr.value; });
      box.querySelectorAll('[data-xl]').forEach((i) => i.addEventListener('input', () => { st.extras[i.dataset.xl].label = i.value; }));
      box.querySelectorAll('[data-xa]').forEach((i) => i.addEventListener('change', () => { st.extras[i.dataset.xa].amount = i.value; draw(); }));
      on(box.querySelector('#addx'), () => { st.extras.push({ label: '', amount: '' }); draw(); });
      on(box.querySelector('#savew'), (ev) => R.busy(ev.currentTarget, async () => { await R.api('payroll.set_wage', { user_id: userId, daily_wage: R.val(box, '#setw') }); await load(pv.from, pv.to); }));
      box.querySelectorAll('[data-run]').forEach((b) => b.addEventListener('click', async () => {
        const r = await R.askReason('ยกเลิกรอบจ่ายค่าจ้าง', { text: 'ระบบบันทึกเงินกลับเข้าบัญชี และคืนเงินเบิกล่วงหน้าให้หักรอบหน้า', danger: true, ok: 'ยกเลิกรอบนี้' });
        if (r) R.busy(null, async () => { await R.api('payroll.cancel', { run_id: b.dataset.run, reason: r.reason }); R.toast('ยกเลิกแล้ว'); done(); });
      }));
      on(box.querySelector('#pay'), (ev) => R.busy(ev.currentTarget, async () => {
        const run = await R.api('payroll.pay', { user_id: userId, from: pv.from, to: pv.to, days: st.days, days_reason: st.reason, extras: st.extras,
          account_id: R.segVal(box, 'pacc'), pay_ref: R.val(box, '#ref'), note: R.val(box, '#note'), attachment_ids: aw.ids() });
        m.close(); R.toast(`จ่ายค่าจ้าง ${pv.display_name} ${money(run.net_paid)} บาทแล้ว`); done();
      }));
    }
    load(from, to).catch((e) => { m.close(); R.fail(e); });
  };

  R.def('staff', { title: 'พนักงาน', back: 'more' }, async function (el) {
    await periodPage(el, 'staff', async (box, r, redraw) => {
      const s = await R.api('report.staff', r), pay = R.can('expense.pay');
      const wd = Object.fromEntries(s.workdays.map((w) => [w.user_id, w]));
      const rows = s.people.map((p) => ({ ...p, id: p.user_id, w: wd[p.user_id] || { days: 0, submitted: 0, on_time: 0, late: 0, variance_days: 0 } }));
      const owedDays = rows.reduce((t, p) => t + (p.daily_wage ? Number(p.unpaid_days) * Number(p.daily_wage) : 0), 0);
      box.innerHTML = `<div class="full">${pay ? R.mlist([['ค่าจ้าง', [
          R.mrow('ค่าแรงที่ยังไม่จ่าย (ประมาณ)', baht(owedDays), { sub: 'วันทำงานที่ยังไม่จ่าย × ค่าแรง/วัน', tone: owedDays ? 'warn' : '' }),
          R.mrow('จ่ายแล้วในช่วงนี้', baht(rows.reduce((t, p) => t + Number(p.paid_gross || 0), 0))),
          R.mrow('เบิกล่วงหน้าค้างหัก', baht(rows.reduce((t, p) => t + Number(p.advance_open || 0), 0)))]]]) : ''}</div>
        <div class="full">${R.table([
          { l: 'ชื่อ', f: (p) => `${esc(p.display_name)}${p.active ? '' : ' <span class="pill">ปิดใช้</span>'}` },
          { l: 'ยังไม่จ่าย', num: true, main: true, f: (p) => (Number(p.unpaid_days) ? `<span style="color:var(--warn)">${p.unpaid_days} วัน</span>` : 'จ่ายครบ') },
          { l: 'วันทำงาน', num: true, pri: 1, f: (p) => p.w.days + ' วัน' },
          { l: 'ตรงเวลา / หลังเวลา', num: true, pri: 1, f: (p) => `${p.w.on_time} / ${p.w.late ? `<span style="color:var(--warn)">${p.w.late}</span>` : 0}` },
          ...(pay ? [{ l: 'ค่าแรง/วัน', num: true, pri: 1, f: (p) => (p.daily_wage ? money(p.daily_wage) : '<span class="pill warn">ยังไม่ตั้ง</span>') },
            { l: 'จ่ายแล้ว (ช่วงนี้)', num: true, pri: 1, f: (p) => (Number(p.paid_gross) ? money(p.paid_gross) + ` <span class="muted small">${qty(p.paid_days)} วัน</span>` : '-') },
            { l: 'เบิกค้างหัก', num: true, pri: 2, f: (p) => (Number(p.advance_open) ? money(p.advance_open) : '-') }] : []),
          { l: 'ส่งรายงานเอง', num: true, pri: 2, f: (p) => p.w.submitted },
          { l: 'วันเงินไม่ตรง', num: true, pri: 2, f: (p) => p.w.variance_days },
          { l: 'ออเดอร์ / ยอดขาย', num: true, pri: 2, f: (p) => `${p.orders} · ${money(p.sales)}` },
          { l: 'ยกเลิก / แก้ไข', num: true, pri: 2, f: (p) => p.cancels + ' / ' + p.edits },
          { l: 'ของเสีย (ต้นทุน)', num: true, pri: 2, f: (p) => money(p.waste) },
          { l: 'สวัสดิการทีมงาน (ทุน)', num: true, pri: 2, f: (p) => money(p.meals || 0) },
          ...(pay ? [{ l: '', f: (p) => `<button type="button" class="btn small primary" data-pay="${p.user_id}">จ่ายค่าจ้าง</button>` }] : [])], rows, { empty: 'ยังไม่มีพนักงาน' })}</div>
        <p class="muted small full" style="padding:0 4px">วันทำงาน = วันที่ส่งรายงานปิดยอดสำเร็จ นับให้ผู้ส่งและผู้ร่วมกะ · ตรงเวลา = ส่งภายใน ${esc(R.settingVal('close_due_time', '21:00'))} น. · ค่าจ้าง = วัน × ค่าแรง/วัน + ค่าพิเศษ − เบิกล่วงหน้า</p>
        <div class="full">${R.list([R.row({ href: '#/closes', icon: 'calendar', t: 'รายงานปิดยอดทั้งหมด' }), ...(R.can('admin.users') ? [R.row({ href: '#/users', icon: 'users', t: 'ผู้ใช้ สิทธิ์ และ PIN' })] : [])])}</div>`;
      box.querySelectorAll('[data-pay]').forEach((b) => b.addEventListener('click', (ev) => { ev.stopPropagation(); R.payrollSheet(b.dataset.pay, () => redraw().catch(R.fail)); }));
    });
  });
})();
