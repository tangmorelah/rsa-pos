/* RSA - POS Assistant — Owner screens: overview, approvals inbox, money, reports, expenses, closes, export (mobile app layout) */
(function () {
  'use strict';
  const R = window.RSA, esc = R.esc, money = R.money, qty = R.qty, baht = R.baht;
  const B = () => R.state.boot;
  const on = (node, fn) => node && node.addEventListener('click', fn);
  const signed = (v) => (Number(v) > 0 ? '+' : '') + money(v);

  function profitNote(p) {
    const f = Object.values(p.flags || {});
    return p.complete && !f.length ? '' : `<details class="note"><summary style="color:inherit">ตัวเลขกำไรเป็นค่าประมาณ · ทำไม?</summary><ul style="margin:6px 0 0;padding-left:18px">${f.map((x) => `<li>${esc(x)}</li>`).join('')}</ul></details>`;
  }
  function bars(rows, key, label) {
    const max = Math.max(1, ...rows.map((r) => Number(r[key]) || 0));
    return rows.map((r) => `<div class="barline"><div class="lab"><span>${esc(r[label])}</span><b class="num">${baht(r[key])}</b></div><span class="track"><span class="fill" style="width:${(100 * (Number(r[key]) || 0)) / max}%"></span></span></div>`).join('');
  }
  // ------------------------------------------------------------ overview
  const EX_ROUTE = { open_no_sales: 'settings', close_missing: 'closes', close_today: 'close', cash_variance: 'approvals', close_adjust: 'approvals', cancel_after_close: 'orders', expense_review: 'approvals',
    expense_pending: 'approvals', expense_due: 'approvals', stocktake_pending: 'approvals', settlement_diff: 'cashflow', settlement_overdue: 'cashflow', bank_unreconciled: 'cashflow',
    low_stock: 'stock', unconfirmed: 'settings' };
  R.EX_ROUTE = EX_ROUTE;
  R.profitNote = profitNote;

  // ------------------------------------------------------------ approvals inbox: everything waiting for the owner
  R.approvalItems = async function () {
    const jobs = [];
    if (R.can('expense.approve')) { jobs.push(R.api('expense.list', { status: 'รออนุมัติ' }).then((l) => l.map((x) => ({ kind: 'approve', x })))); jobs.push(R.api('expense.list', { unreviewed: true }).then((l) => l.map((x) => ({ kind: 'review', x })))); }
    if (R.can('expense.pay')) jobs.push(R.api('expense.list', { status: 'รอทำจ่าย' }).then((l) => l.map((x) => ({ kind: 'pay', x }))));
    if (R.can('stock.approve')) jobs.push(R.api('stocktake.list', { status: 'pending' }).then((l) => l.map((x) => ({ kind: 'count', x }))));
    if (R.can('closing.view_all')) jobs.push(R.api('close.list', { from: R.addDays(R.today(), -14) }).then((l) => l.filter((c) => !c.reviewed_at && (Number(c.variance) || c.adjustments.length)).map((x) => ({ kind: 'close', x }))));
    return (await Promise.all(jobs)).flat();
  };

  function paySheet(x, done) {
    const aw = R.attachWidget('pay', [['slip', 'สลิปโอน'], ['receipt', 'ใบเสร็จ'], ['tax_invoice', 'ใบกำกับภาษี']], 'สลิป / ใบเสร็จ (ถ้ามี)');
    const accs = B().accounts;
    const m = R.modal('จ่ายเงิน', `<form class="form"><div class="card flat"><b>${esc(x.description)}</b><span class="big-amt">${baht(x.amount)}</span>${x.owed_to ? `<span class="muted">คืนเงินให้ ${esc(x.owed_to)}</span>` : ''}</div>
      <div class="field"><span>จ่ายจาก</span>${R.seg('pacc', accs.map((a) => [a.id, a.name]), x.pay_account_id || (accs.find((a) => !a.is_drawer) || accs[0] || {}).id, 'wrap')}</div>
      <label class="field" id="pref-box"><span class="req">เลขอ้างอิง / เลขที่สลิป (จ่ายผ่านบัญชี)</span><input type="text" id="pref" value="${esc(x.pay_ref || '')}"></label>
      <label class="field"><span>วันเวลาที่จ่าย</span><input type="datetime-local" id="at" value="${R.nowLocal()}"></label>${aw.html}
      <button class="btn primary lg">บันทึกว่าจ่ายแล้ว</button></form>`);
    aw.bind(m.el);
    const refBox = () => { const a = accs.find((y) => y.id === R.segVal(m.el, 'pacc')); m.el.querySelector('#pref-box').hidden = !a || a.kind === 'cash'; };
    m.el.querySelector('.seg').addEventListener('change', refBox); refBox();
    m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
      await R.api('expense.pay', { expense_id: x.id, account_id: R.segVal(m.el, 'pacc'), paid_at: R.toIso(R.val(m.el, '#at')), pay_ref: R.val(m.el, '#pref'), attachment_ids: aw.ids() });
      m.close(); R.toast('บันทึกการจ่ายแล้ว'); done();
    }); });
  }
  R.paySheet = paySheet;

  function expenseSheet(x, done) {
    const m = R.modal(x.expense_no, `<div class="card flat"><b>${esc(x.description)}</b><span class="big-amt">${baht(x.amount)}</span>
        <span class="muted small">${esc(x.category_name || '')}${x.payee ? ' · ' + esc(x.payee) : ''} · ${R.dt(x.occurred_at)}</span><span>${R.statusPill(x.status)}${x.status === 'จ่ายแล้ว' && !x.reviewed ? ' <span class="pill">รอตรวจ</span>' : ''}</span></div>
      ${R.list([R.row({ static: true, t: 'บันทึกโดย', v: esc(x.created_by_name) }),
        x.fund_source ? R.row({ static: true, t: 'แหล่งเงิน', v: esc(R.FUND[x.fund_source] || x.fund_source) }) : '',
        x.owed_to ? R.row({ static: true, t: 'ต้องคืนเงินให้', v: esc(x.owed_to) + (x.reimbursed ? ' (คืนแล้ว)' : '') }) : '',
        x.pay_ref ? R.row({ static: true, t: 'เลขอ้างอิงการจ่าย', v: esc(x.pay_ref) }) : '',
        x.account_name ? R.row({ static: true, t: 'จ่ายจาก', v: esc(x.account_name) }) : '',
        x.due_date ? R.row({ static: true, t: 'ครบกำหนด', v: R.date(x.due_date) }) : '',
        x.doc_no ? R.row({ static: true, t: 'เลขที่เอกสาร', v: esc(x.doc_no) }) : ''].filter(Boolean))}
      ${x.attachments.length ? R.attachLinks(x.attachments) : '<div class="note">ไม่มีรูปหลักฐาน</div>'}
      ${x.ocr_snapshot ? '<p class="muted small">ข้อมูลบางส่วนอ่านจากรูป ผู้บันทึกยืนยันว่าตรวจแล้ว</p>' : ''}
      ${x.cancel_reason ? `<div class="note">ยกเลิก: ${esc(x.cancel_reason)}</div>` : ''}
      <div class="btn-row" id="acts"></div>`);
    const acts = [];
    if (R.can('expense.cancel') && x.status !== 'ยกเลิก') acts.push(['x', x.status === 'รออนุมัติ' ? 'ไม่อนุมัติ' : 'ยกเลิก', 'danger']);
    if (R.can('expense.approve') && x.status === 'รออนุมัติ') acts.push(['ok', 'อนุมัติ', '']);
    if (R.can('expense.approve') && x.status === 'จ่ายแล้ว' && !x.reviewed) acts.push(['ok', 'ตรวจแล้ว', 'primary']);
    if (R.can('expense.pay') && (x.status === 'รอทำจ่าย' || (x.status === 'รออนุมัติ' && R.can('expense.approve')))) acts.push(['pay', x.status === 'รออนุมัติ' ? 'อนุมัติและจ่าย' : 'จ่ายเงิน', 'primary']);
    m.el.querySelector('#acts').innerHTML = acts.map(([k, l, c]) => `<button class="btn lg ${c}" data-a="${k}">${l}</button>`).join('');
    on(m.el.querySelector('[data-a=ok]'), (ev) => R.busy(ev.currentTarget, async () => { await R.api('expense.approve', { expense_id: x.id }); m.close(); R.toast('บันทึกแล้ว'); done(); }));
    on(m.el.querySelector('[data-a=pay]'), () => { m.close(); paySheet(x, done); });
    on(m.el.querySelector('[data-a=x]'), async () => {
      m.close();
      const r = await R.askReason((x.status === 'รออนุมัติ' ? 'ไม่อนุมัติ ' : 'ยกเลิก ') + x.expense_no, { text: x.status === 'จ่ายแล้ว' ? 'จ่ายไปแล้ว ระบบจะบันทึกเงินกลับเข้าบัญชีเดิม' : '', danger: true, ok: 'ยืนยัน' });
      if (r) R.busy(null, async () => { await R.api('expense.cancel', { expense_id: x.id, reason: r.reason }); done(); });
    });
  }
  R.expenseSheet = expenseSheet;

  function stocktakeSheet(t, done) {
    const m = R.modal('ผลนับสต็อก', `<p class="muted small">${R.dt(t.created_at)} · ${esc(t.created_by_name)} · ${t.context === 'close' ? 'นับตอนปิดยอด' : 'นับสต็อก'}</p>
      ${R.list(t.lines.map((l) => R.row({ static: true, icon: 'box', tone: Number(l.variance) < 0 ? 'bad' : Number(l.variance) > 0 ? 'ok' : '', t: esc(l.item_name),
        s: `ในระบบ ${qty(l.system_qty)} → นับได้ ${qty(l.counted_qty)}${(l.count_detail || []).length ? ' (' + l.count_detail.map((c) => qty(c.qty) + ' ' + esc(c.unit) + (c.kind === 'recipe' && c.product ? ' ' + esc(c.product) : '')).join(' + ') + ')' : ''}${l.note ? ' · ' + esc(l.note) : ''}`, v: (Number(l.variance) > 0 ? '+' : '') + qty(l.variance) })))}
      <p class="muted small">อนุมัติแล้วระบบปรับสต็อกตามยอดที่นับได้</p>
      <div class="btn-row"><button class="btn lg danger" data-a="no">ไม่อนุมัติ</button><button class="btn lg primary" data-a="yes">อนุมัติ</button></div>`);
    m.el.querySelectorAll('[data-a]').forEach((b) => b.addEventListener('click', () => R.busy(b, async () => {
      await R.api('stocktake.decide', { stocktake_id: t.id, approve: b.dataset.a === 'yes' }); m.close(); R.toast(b.dataset.a === 'yes' ? 'อนุมัติแล้ว' : 'ไม่อนุมัติ'); done();
    })));
  }
  function closeSheet(c, done) {
    const m = R.modal('ปิดยอด ' + R.date(c.biz_date), `<p class="muted small">ส่งโดย ${esc(c.submitted_by_name)} ${R.time(c.submitted_at)} น.${c.coworker_names.length ? ' · ร่วมกะ ' + c.coworker_names.map(esc).join(', ') : ''}</p>
      ${R.closeSummary(c)}
      <div class="btn-row">${R.can('closing.edit') ? '<button class="btn lg" data-a="edit">แก้ยอดเงินสด</button>' : ''}${!c.reviewed_at ? '<button class="btn lg primary" data-a="ok">รับทราบแล้ว</button>' : ''}</div>
      ${c.reviewed_at ? `<p class="muted small">ตรวจโดย ${esc(c.reviewed_by_name)} ${R.dt(c.reviewed_at)}</p>` : ''}`);
    on(m.el.querySelector('[data-a=ok]'), (ev) => R.busy(ev.currentTarget, async () => { await R.api('close.review', { close_id: c.id }); m.close(); R.toast('บันทึกแล้ว'); done(); }));
    on(m.el.querySelector('[data-a=edit]'), () => {
      m.close();
      const e = R.modal('แก้ยอดเงินสดนับได้', `<form class="form"><p class="muted small">ระบบเก็บรายงานเดิมไว้ และบันทึกผลต่างเป็นรายการปรับปรุงในลิ้นชัก</p>
        <label class="field"><span>เงินสดนับได้ (เดิม ${money(c.counted_cash)})</span><input type="number" step="0.01" inputmode="decimal" id="c" value="${c.counted_cash}" class="input-amt"></label>
        <label class="field"><span>คำอธิบายเงินขาด/เกิน</span><input type="text" id="vr" value="${esc(c.variance_reason || '')}"></label>
        <label class="field"><span>เหตุผลที่แก้ไข</span><input type="text" id="r" required></label><button class="btn primary lg">บันทึกการแก้ไข</button></form>`);
      e.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
        await R.api('close.revise', { close_id: c.id, counted_cash: R.val(e.el, '#c'), variance_reason: R.val(e.el, '#vr'), reason: R.val(e.el, '#r') }); e.close(); done();
      }); });
    });
  }
  R.closeSheet = closeSheet;

  R.def('approvals', { title: 'รออนุมัติ', tab: 'approvals' }, async function (el) {
    async function draw() {
      const items = await R.approvalItems();
      R.refreshBadge(true);
      const grp = (k) => items.filter((i) => i.kind === k);
      const exRow = (i) => R.row({ data: { k: i.kind, id: i.x.id }, avatar: i.x.created_by_name || '?', t: esc(i.x.description), s: `${esc(i.x.created_by_name)} · ${R.dt(i.x.occurred_at)}${i.x.attachments.length ? '' : ' · ไม่มีรูป'}`, v: baht(i.x.amount) });
      const sections = [
        ['ค่าใช้จ่ายรออนุมัติ', grp('approve').map(exRow)],
        ['รอจ่ายเงิน', grp('pay').map((i) => R.row({ data: { k: i.kind, id: i.x.id }, icon: 'wallet', t: esc(i.x.description), s: `${i.x.owed_to ? 'คืนเงินให้ ' + esc(i.x.owed_to) : esc(i.x.payee || i.x.category_name || '')}${i.x.due_date ? ' · ครบ ' + R.date(i.x.due_date) : ''}`, v: baht(i.x.amount) }))],
        ['จ่ายแล้ว รอเจ้าของตรวจ', grp('review').map(exRow)],
        ['ผลนับสต็อก', grp('count').map((i) => R.row({ data: { k: i.kind, id: i.x.id }, icon: 'box', t: `นับ ${i.x.lines.length} รายการ`, s: `${esc(i.x.created_by_name)} · ${R.dt(i.x.created_at)}`, v: `${i.x.lines.filter((l) => Number(l.variance)).length} ต่าง` }))],
        ['ปิดยอดที่ควรดู', grp('close').map((i) => R.row({ data: { k: i.kind, id: i.x.id }, icon: 'moon', tone: Number(i.x.variance) ? 'warn' : '', t: R.date(i.x.biz_date), s: `${esc(i.x.submitted_by_name)}${i.x.adjustments.length ? ' · แก้ตัวเลข ' + i.x.adjustments.length + ' จุด' : ''}`, v: Number(i.x.variance) ? 'เงินสด ' + signed(i.x.variance) : 'ตรวจ' }))],
      ].filter(([, rows]) => rows.length);
      el.innerHTML = sections.length ? sections.map(([t, rows]) => R.sec(`${t} (${rows.length})`) + R.list(rows)).join('')
        : `<div class="card success"><span class="mark">${R.icon('check')}</span><h2>ไม่มีอะไรรออนุมัติ</h2><p class="muted">ทุกอย่างเรียบร้อย</p></div>`;
      el.querySelectorAll('[data-k]').forEach((b) => b.addEventListener('click', () => {
        const it = items.find((i) => i.kind === b.dataset.k && i.x.id === b.dataset.id), done = () => draw().catch(R.fail);
        if (it.kind === 'count') stocktakeSheet(it.x, done); else if (it.kind === 'close') closeSheet(it.x, done); else expenseSheet(it.x, done);
      }));
    }
    await draw();
  });

  // ------------------------------------------------------------ money (cashflow management)
  R.def('cashflow', { title: 'การบริหารกระแสเงินสด', tab: 'cashflow', back: 'more' }, async function (el) {
    const [x, fc] = await Promise.all([R.api('cashflow.summary', {}), R.api('cashflow.forecast', {})]);
    const manage = R.can('cashflow.manage');
    const total = x.accounts.reduce((a, b) => a + Number(b.balance), 0);
    const c = x.capital, pf = x.profit;
    const KIND = { capital_in: 'ลงทุนเพิ่ม', loan_in: 'กู้ยืม', capital_return: 'ถอนเงินเจ้าของ / คืนทุน', loan_repayment: 'ชำระหนี้', owner_paid: 'เจ้าของจ่ายแทนร้าน' };
    const KIND_NEW = { capital_in: 'ลงทุนเพิ่ม', loan_in: 'กู้ยืม', capital_return: 'ถอนเงินเจ้าของ / คืนทุน', loan_repayment: 'ชำระหนี้' };
    const PUR = R.PURPOSE;
    el.innerHTML = `${R.sectTabs('cashflow')}<div class="card blue"><span class="muted small">เงินที่ใช้ได้ตอนนี้ (ทุกบัญชี)</span><span class="big-amt">${baht(total)}</span></div>
      ${R.list(x.accounts.map((a) => R.row({ data: { acc: a.id }, icon: a.is_drawer ? 'wallet' : 'receipt', t: esc(a.name),
        s: a.is_drawer ? 'ลิ้นชักหน้าร้าน · นับตอนปิดยอด' : Number(a.unreconciled) ? `ยังไม่ตรวจกับ statement ${a.unreconciled} รายการ` : 'ตรวจกับ statement ครบ', v: baht(a.balance),
        pill: a.opening_confirmed ? '' : '<span class="pill warn">ยอดยกมายังไม่ยืนยัน</span>' })))}
      ${manage ? R.list([R.row({ data: { act: 'tr' }, icon: 'flow', t: 'โอนเงินระหว่างบัญชี', s: 'เช่น นำเงินสดหน้าร้านฝากธนาคาร' })]) : ''}
      ${R.sec('คาดการณ์เงินสด 7 / 14 / 30 วัน')}
      <div class="card">${R.lineChart(fc.daily.map((p) => ({ ...p, label: R.date(p.date) })), [{ key: 'balance', label: 'เงินคาดว่าคงเหลือ' }], { title: 'คาดการณ์เงินสด 30 วัน', xfmt: (p) => String(new Date(p.date + 'T12:00:00').getDate()) })}
        ${Number(fc.min_working_capital) ? `<p class="muted small">เงินหมุนขั้นต่ำที่ต้องกันไว้ ${baht(fc.min_working_capital)}</p>` : ''}</div>
      ${R.table([{ l: 'ช่วง', f: (h) => h.days + ' วันข้างหน้า' }, { l: 'Delivery เข้า', num: true, f: (h) => '+' + money(h.delivery_in) },
        { l: 'ยอดขายหน้าร้าน (ประมาณ)', num: true, f: (h) => '+' + money(h.est_sales) }, { l: 'ค้างจ่าย', num: true, f: (h) => '−' + money(h.payables) },
        { l: 'ค่าใช้จ่ายประจำ', num: true, f: (h) => '−' + money(h.fixed) }, { l: 'ใช้จ่ายทั่วไป (ประมาณ)', num: true, f: (h) => '−' + money(h.est_spend) },
        { l: 'คาดว่าคงเหลือ', num: true, main: true, f: (h) => { const e = Number(fc.cash_now) + Number(h.delivery_in) + Number(h.est_sales) - Number(h.payables) - Number(h.fixed) - Number(h.est_spend);
          return `<b style="color:${e < Number(fc.min_working_capital || 0) ? 'var(--bad)' : 'inherit'}">${baht(e)}</b>`; } }], fc.horizons)}
      <div class="stats">${R.stat('ขายหน้าร้านเฉลี่ย/วัน', baht(fc.avg_daily_storefront), '14 วันล่าสุด')}${R.stat('จ่ายเฉลี่ย/วัน', baht(fc.avg_daily_outflow), '30 วันล่าสุด')}
        ${R.stat('เงินพอใช้ (Runway)', fc.runway_days != null ? fc.runway_days + ' วัน' : '-', 'ถ้าไม่มีเงินเข้าเลย')}${R.stat('ค่าใช้จ่ายประจำที่ยังไม่ยืนยัน', fc.unconfirmed_fixed.length + ' รายการ', fc.unconfirmed_fixed.map((f) => esc(f.name)).join(', '))}</div>
      <p class="muted small" style="padding:0 4px">ยอดขายและค่าใช้จ่ายทั่วไปเป็นค่าเฉลี่ยจากข้อมูลจริงที่ผ่านมา ใช้ดูทิศทางเท่านั้น</p>
      ${R.sec('รอรับเงินจาก Delivery')}
      ${R.list(x.receivables.map((r) => R.row({ data: { set: r.channel_id, from: r.oldest }, icon: 'flow', t: esc(r.channel_name), s: `${r.orders} ออเดอร์ · ครบรอบ ${R.date(r.expected_by)}`, v: baht(r.est_net), vs: manage ? 'แตะเมื่อเงินเข้า' : 'หลังหักค่าธรรมเนียม' })), 'ไม่มียอดค้างรับ')}
      ${R.sec('ค้างจ่าย', x.payables.length ? '<a href="#/approvals">จัดการ</a>' : '')}
      ${R.list(x.payables.slice(0, 6).map((p) => R.row({ href: '#/approvals', icon: 'wallet', t: esc(p.description), s: `ครบ ${R.date(p.due_date)} · ${esc(p.status)}`, v: baht(p.amount) })), 'ไม่มีค่าใช้จ่ายค้างจ่าย')}
      ${R.sec('ทุน หนี้ และกำไร')}
      <div class="stats">${R.stat('ทุนที่ใส่', baht(c.capital_in), 'คืนแล้ว ' + money(c.capital_returned))}${R.stat('หนี้คงค้าง', baht(Number(c.loan_in) - Number(c.loan_repaid)), 'กู้ ' + money(c.loan_in))}
        ${R.stat('กำไรสะสม (ประมาณ)', baht(pf.cumulative_net))}${R.stat('กำไรที่ประกาศได้', baht(pf.available), 'ประกาศแล้ว ' + money(pf.declared) + (Number(pf.owner_goods) ? ' · เจ้าของหยิบสินค้า ' + money(pf.owner_goods) : ''))}</div>
      ${profitNote(pf)}
      ${manage ? R.list([R.row({ data: { act: 'pf' }, icon: 'check', t: 'ประกาศใช้กำไร', s: 'โปะหนี้ · เก็บเป็นเงินหมุน · ลงทุนกลับร้าน · คืนทุน · จ่ายเจ้าของ' }), R.row({ data: { act: 'cap' }, icon: 'plus', t: 'บันทึกทุน ถอนเงินเจ้าของ หรือ เงินกู้' }), R.row({ href: '#/invest', icon: 'chart', t: 'เงินลงทุน / คืนทุน' })]) : ''}
      ${x.declarations.length || x.capital_rows.length ? R.sec('ประวัติทุนและการใช้กำไร') + R.list([
        ...x.declarations.map((d) => R.row({ data: d.status === 'done' && manage ? { pfx: d.id } : {}, static: !(d.status === 'done' && manage), off: d.status === 'cancelled', icon: 'check', t: 'ประกาศใช้กำไร · ' + PUR[d.purpose], s: `${R.date(d.declared_at)} · ${esc(d.recipient)}${!d.paid_now && !['keep_working_capital', 'reinvest'].includes(d.purpose) && d.status === 'done' ? ' · ยังไม่จ่าย' : ''}`, v: baht(d.amount) })),
        ...x.capital_rows.filter((r) => !r.profit_declaration_id && r.kind !== 'investment_item').map((r) => R.row({ data: r.status === 'done' && manage ? { capx: r.id } : {}, static: !(r.status === 'done' && manage), off: r.status === 'cancelled', icon: 'plus', t: KIND[r.kind], s: `${R.date(r.occurred_at)} · ${esc(r.party)}`, v: baht(r.amount) }))]) : ''}
      <div id="setl"></div>`;

    const SRC = { order: 'ขาย', order_refund: 'ยกเลิก/คืนเงิน', expense: 'ค่าใช้จ่าย', expense_reversal: 'กลับรายการค่าใช้จ่าย', settlement: 'รับเงิน Delivery', transfer: 'โอนระหว่างบัญชี', capital: 'ทุน/เงินกู้', profit: 'ประกาศใช้กำไร', adjustment: 'ผลต่างปิดยอด' };
    el.querySelectorAll('[data-acc]').forEach((b) => b.addEventListener('click', () => R.busy(null, async () => {
      const a = x.accounts.find((y) => y.id === b.dataset.acc);
      const rows = await R.api('ledger.list', { account_id: a.id });
      const recon = manage && a.kind !== 'cash';
      const m = R.modal(a.name, `<div class="card flat"><span class="muted small">คงเหลือ</span><span class="big-amt">${baht(a.balance)}</span><span class="muted small">ยอดยกมา ${money(a.opening_balance)}</span></div>
        ${recon ? '<p class="muted small">ติ๊กรายการที่ตรงกับ statement ธนาคาร แล้วกดบันทึก</p>' : ''}
        <div class="list">${rows.map((r) => `<label class="row ${recon && !r.reconciled_at ? '' : 'static'}">${recon ? `<input type="checkbox" data-lid="${r.id}" ${r.reconciled_at ? 'checked disabled' : ''} style="width:22px;height:22px">` : ''}
          <span class="body"><span class="t">${SRC[r.source_type] || r.source_type}</span><span class="s">${R.dt(r.occurred_at)} · ${esc(r.note || '')}</span></span>
          <span class="end"><span class="v" style="color:${r.direction === 'in' ? 'var(--ok)' : 'var(--ink)'}">${r.direction === 'in' ? '+' : '−'}${money(r.amount)}</span>${r.reconciled_at ? '<span class="pill ok">ตรวจแล้ว</span>' : ''}</span></label>`).join('') || '<div class="empty">ไม่มีรายการใน 30 วัน</div>'}</div>
        ${recon ? '<input type="text" id="bref" placeholder="อ้างอิง statement (ถ้ามี)"><button class="btn primary lg" id="mark">บันทึกว่าตรงกับ statement</button>' : ''}`);
      on(m.el.querySelector('#mark'), (ev) => R.busy(ev.currentTarget, async () => {
        const ids = [...m.el.querySelectorAll('[data-lid]:checked:not(:disabled)')].map((i) => i.dataset.lid);
        if (!ids.length) throw new Error('ติ๊กรายการก่อน');
        await R.api('ledger.reconcile', { ids, bank_ref: R.val(m.el, '#bref') }); m.close(); R.toast('บันทึกแล้ว'); R.route();
      }));
    })));

    const banks = x.accounts.filter((a) => !a.is_drawer);
    el.querySelectorAll('[data-set]').forEach((b) => b.addEventListener('click', () => {
      if (!manage) return;
      R.settlementSheet(b.dataset.set, b.dataset.from, R.addDays(R.today(), -1) < b.dataset.from ? b.dataset.from : R.addDays(R.today(), -1), () => R.route());
    }));
    const simple = (title, html, action, mk) => {
      const m = R.modal(title, `<form class="form">${html}<button class="btn primary lg">บันทึก</button></form>`);
      m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => { await R.api(action, mk(m.el)); m.close(); R.toast('บันทึกแล้ว'); R.route(); }); });
    };
    const accSeg = (n) => R.seg(n, x.accounts.map((a) => [a.id, a.name]), x.accounts[0] && x.accounts[0].id, 'wrap');
    on(el.querySelector('[data-act=tr]'), () => simple('โอนเงินระหว่างบัญชี', `<div class="field"><span>จากบัญชี</span>${accSeg('f')}</div><div class="field"><span>เข้าบัญชี</span>${R.seg('t', x.accounts.map((a) => [a.id, a.name]), (x.accounts[1] || x.accounts[0] || {}).id, 'wrap')}</div>
      <label class="field"><span>จำนวน (บาท)</span><input type="number" step="0.01" min="0.01" inputmode="decimal" id="a" class="input-amt" required></label>
      <label class="field"><span>เหตุผล</span><input type="text" id="r" placeholder="เช่น นำเงินสดหน้าร้านฝากธนาคาร" required></label>`, 'transfer.create',
      (m) => ({ from_account: R.segVal(m, 'f'), to_account: R.segVal(m, 't'), amount: R.val(m, '#a'), reason: R.val(m, '#r') })));
    on(el.querySelector('[data-act=cap]'), () => simple('บันทึกทุน / เงินกู้', `<div class="field"><span>ประเภท</span>${R.seg('k', Object.entries(KIND_NEW), 'capital_in', 'wrap')}</div>
      ${Number(fc.min_working_capital) ? `<p class="muted small">ถอนเงิน/ชำระหนี้ได้เมื่อเหลือเงินหมุนอย่างน้อย ${baht(fc.min_working_capital)}</p>` : ''}
      <label class="field"><span>ผู้ลงทุน / เจ้าหนี้</span><input type="text" id="p" required></label><label class="field"><span>จำนวน (บาท)</span><input type="number" step="0.01" min="0.01" inputmode="decimal" id="a" class="input-amt" required></label>
      <div class="field"><span>บัญชี</span>${accSeg('acc')}</div><label class="field"><span>หมายเหตุ</span><input type="text" id="n"></label>`, 'capital.create',
      (m) => ({ kind: R.segVal(m, 'k'), party: R.val(m, '#p'), amount: R.val(m, '#a'), account_id: R.segVal(m, 'acc'), note: R.val(m, '#n') })));
    on(el.querySelector('[data-act=pf]'), () => {
      const m = R.modal('ประกาศใช้กำไร', `<form class="form"><div class="note info">ประกาศได้ไม่เกิน ${baht(pf.available)} (กำไรสะสมโดยประมาณ หักที่ประกาศแล้ว และสินค้าที่เจ้าของหยิบไปใช้)${Number(fc.min_working_capital) ? '<br>ต้องเหลือเงินหมุนขั้นต่ำ ' + baht(fc.min_working_capital) + ' หลังจ่าย' : ''}</div>
        <label class="field"><span>จำนวน (บาท)</span><input type="number" step="0.01" min="0.01" max="${pf.available}" inputmode="decimal" id="a" class="input-amt" required></label>
        <div class="field"><span>ใช้กำไรทำอะไร</span>${R.seg('pu', Object.entries(PUR), 'loan_repayment', 'wrap')}</div>
        <div id="payout"><label class="field"><span>ผู้รับเงิน</span><input type="text" id="rc" placeholder="เช่น เจ้าของ / ธนาคาร"></label>
          <label class="check"><input type="checkbox" id="now" checked> จ่ายเงินออกตอนนี้</label>
          <div class="field" id="accbox"><span>จ่ายจากบัญชี</span>${accSeg('acc')}</div></div>
        <label class="field"><span>หมายเหตุ</span><input type="text" id="n"></label><button class="btn primary lg">บันทึก</button></form>`);
      const upd = () => { const keep = ['keep_working_capital', 'reinvest'].includes(R.segVal(m.el, 'pu')); m.el.querySelector('#payout').hidden = keep; m.el.querySelector('#accbox').hidden = !m.el.querySelector('#now').checked; };
      m.el.querySelector('.seg').addEventListener('change', upd); m.el.querySelector('#now').addEventListener('change', upd); upd();
      m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
        await R.api('profit.declare', { amount: R.val(m.el, '#a'), purpose: R.segVal(m.el, 'pu'), recipient: R.val(m.el, '#rc'), paid_now: R.val(m.el, '#now'),
          account_id: R.segVal(m.el, 'acc'), note: R.val(m.el, '#n') });
        m.close(); R.toast('บันทึกแล้ว'); R.route();
      }); });
    });
    const cancelBtn = (sel, action, key) => el.querySelectorAll(sel).forEach((b) => b.addEventListener('click', async () => {
      const r = await R.askReason('ยกเลิกรายการนี้', { text: 'ระบบบันทึกรายการกลับเงิน ไม่ลบรายการเดิม', danger: true, ok: 'ยกเลิกรายการ' });
      if (r) R.busy(null, async () => { await R.api(action, { [key]: Object.values(b.dataset)[0], reason: r.reason }); R.route(); });
    }));
    cancelBtn('[data-capx]', 'capital.cancel', 'capital_id');
    el.querySelectorAll('[data-pfx]').forEach((b) => b.addEventListener('click', () => {
      const d = x.declarations.find((y) => y.id === b.dataset.pfx);
      const unpaid = !d.paid_now && !['keep_working_capital', 'reinvest'].includes(d.purpose);
      const m = R.modal('ประกาศใช้กำไร · ' + PUR[d.purpose], `<div class="card flat"><span class="big-amt">${baht(d.amount)}</span><span class="muted small">${R.date(d.declared_at)} · ${esc(d.recipient)}${d.note ? ' · ' + esc(d.note) : ''}</span></div>
        ${unpaid ? `<div class="field"><span>จ่ายจากบัญชี</span>${accSeg('pacc')}</div><button class="btn primary lg" id="pay">จ่ายเงินตอนนี้</button>` : ''}
        <button class="btn danger" id="cx">ยกเลิกรายการนี้</button>`);
      on(m.el.querySelector('#pay'), (ev) => R.busy(ev.currentTarget, async () => { await R.api('profit.pay', { declaration_id: d.id, account_id: R.segVal(m.el, 'pacc') }); m.close(); R.route(); }));
      on(m.el.querySelector('#cx'), async () => { m.close(); const r = await R.askReason('ยกเลิกรายการนี้', { text: 'ระบบบันทึกรายการกลับเงิน ไม่ลบรายการเดิม', danger: true, ok: 'ยกเลิกรายการ' });
        if (r) R.busy(null, async () => { await R.api('profit.cancel', { declaration_id: d.id, reason: r.reason }); R.route(); }); });
    }));
    const sl = await R.api('settlement.list', {});
    el.querySelector('#setl').innerHTML = sl.length ? R.sec('ประวัติรับเงิน Delivery') + R.list(sl.slice(0, 20).map((s) => R.row({ data: s.status === 'done' && manage ? { slx: s.id } : {}, static: !(s.status === 'done' && manage), off: s.status === 'cancelled', icon: 'flow',
      t: esc(s.channel_name), s: `${R.date(s.period_from)} – ${R.date(s.period_to)} · ค่าธรรมเนียม ${money(s.fee)}`, v: baht(s.net),
      pill: Math.abs(s.reported_gross - s.system_gross) > 0.009 ? `<span class="pill warn">ต่าง ${signed(s.reported_gross - s.system_gross)}</span>` : '' }))) : '';
    cancelBtn('[data-slx]', 'settlement.cancel', 'settlement_id');
  });

  // ------------------------------------------------------------ all expenses
  R.def('expenses', { title: 'ค่าใช้จ่ายทั้งหมด', back: 'more' }, async function (el) {
    let tab = '';
    const TABS = [['', 'ทั้งหมด'], ['รออนุมัติ', 'รออนุมัติ'], ['รอทำจ่าย', 'รอทำจ่าย'], ['จ่ายแล้ว', 'จ่ายแล้ว'], ['ยกเลิก', 'ยกเลิก'], ['fixed', 'ประจำเดือน']];
    async function draw() {
      const r = R.periodRange(), sm = await R.api('report.expenses', r);
      el.innerHTML = `${R.sectTabs('expenses')}${R.periodBar({ compare: false })}
        <div class="kpis">${R.kpi('ค่าใช้จ่ายรวม', baht(sm.total))}${R.kpi('จ่ายแล้ว', baht(sm.by_status['จ่ายแล้ว'] || 0))}${R.kpi('รออนุมัติ / รอทำจ่าย', baht(Number(sm.by_status['รออนุมัติ'] || 0) + Number(sm.by_status['รอทำจ่าย'] || 0)))}
          ${R.kpi('ไม่มีหลักฐาน', sm.no_evidence + ' รายการ', '', '', sm.no_evidence ? 'warn' : '')}</div>
        <div class="grid2"><div class="card"><h2>ตามหมวด</h2>${R.hbars(sm.by_category.map((c) => ({ label: esc(c.category) + ` <span class="muted small">${c.count}</span>`, value: c.amount })))}</div>
          <div class="card"><h2>ตามแหล่งเงิน</h2>${R.hbars(sm.by_source.map((c) => ({ label: esc(R.FUND[c.fund_source] || c.fund_source), value: c.amount })))}
            ${sm.owed.length ? `<h2 style="margin-top:12px">ร้านค้างคืน</h2>${sm.owed.map((o) => `<div class="sum-row"><span>${esc(o.owed_to)} (${o.count})</span><b>${money(o.amount)}</b></div>`).join('')}` : ''}</div></div>
        <div class="chips">${TABS.map(([k, l]) => `<button class="chip" data-tab="${k}" aria-pressed="${k === tab}">${l}</button>`).join('')}</div><div id="body" class="form"><div class="boot">กำลังโหลด…</div></div>
        ${R.actionbar('<a class="btn primary" href="#/expense">+ บันทึกค่าใช้จ่าย</a>')}`;
      el.querySelectorAll('[data-tab]').forEach((b) => b.addEventListener('click', () => { tab = b.dataset.tab; draw().catch(R.fail); }));
      R.bindPeriod(el, () => draw().catch(R.fail));
      const body = el.querySelector('#body');
      if (tab === 'fixed') return fixed(body);
      const list = await R.api('expense.list', { status: tab, ...r });
      body.innerHTML = `<p class="muted small" style="padding:0 4px">${list.length} รายการ รวม ${baht(list.reduce((a, x) => a + Number(x.amount), 0))}</p>
        ${R.list(list.map((x) => R.row({ data: { x: x.id }, icon: 'wallet', off: x.status === 'ยกเลิก', t: esc(x.description), s: `${R.dt(x.occurred_at)} · ${esc(x.category_name || '')} · ${esc(R.FUND[x.fund_source] || '')} · ${esc(x.created_by_name)}${x.attachments.length ? '' : ' · ไม่มีรูป'}`,
          v: baht(x.amount), pill: R.statusPill(x.status) + (x.status === 'จ่ายแล้ว' && !x.reviewed ? ' <span class="pill">รอตรวจ</span>' : '') + (x.owed_to ? ' <span class="pill warn">ค้างคืน</span>' : '') })), 'ไม่มีรายการ')}`;
      body.querySelectorAll('[data-x]').forEach((b) => b.addEventListener('click', () => expenseSheet(list.find((y) => y.id === b.dataset.x), () => draw().catch(R.fail))));
    }
    async function fixed(body) {
      const list = await R.api('master.list', { entity: 'fixed_expenses' });
      body.innerHTML = `<p class="muted small" style="padding:0 4px">ระบบสร้างรายการของแต่ละเดือนให้ครั้งเดียว แล้วไปรออนุมัติ/จ่ายตามปกติ</p>
        ${R.list(list.map((f) => R.row({ data: { f: f.id }, icon: 'calendar', off: !f.active, t: esc(f.name), s: `ทุกวันที่ ${f.due_day}${f.payee ? ' · ' + esc(f.payee) : ''}${f.this_month ? ' · เดือนนี้ ' + esc(f.this_month.status) : ''}${f.note ? ' · ' + esc(f.note) : ''}`, v: baht(f.amount), pill: f.confirmed === false ? R.unconfirmed() : '' })), 'ยังไม่มี เช่น ค่าเช่า ค่าจ้าง ค่าอินเทอร์เน็ต')}
        ${R.can('expense.approve') ? '<div class="btn-row"><button class="btn" id="gen">สร้างรายการเดือนนี้</button><button class="btn primary" id="add">+ เพิ่มรายการประจำ</button></div>' : ''}`;
      const edit = (f) => {
        f = f || { active: true, due_day: 1, start_month: R.today().slice(0, 8) + '01', auto_approve: false };
        const m = R.modal(f.id ? 'แก้ไขค่าใช้จ่ายประจำ' : 'เพิ่มค่าใช้จ่ายประจำ', `<form class="form">
          <label class="field"><span>ชื่อรายการ</span><input type="text" id="name" value="${esc(f.name || '')}" required></label>
          <label class="field"><span>จำนวนต่อเดือน</span><input type="number" id="amt" min="0" step="0.01" inputmode="decimal" value="${f.amount ?? ''}" class="input-amt" required></label>
          <div class="two"><label class="field"><span>ครบกำหนดวันที่</span><input type="number" id="due" min="1" max="31" value="${f.due_day}" required></label>
          <label class="field"><span>หมวด</span><select id="cat">${R.opts(B().categories, f.category_id)}</select></label></div>
          <label class="field"><span>จ่ายให้</span><input type="text" id="payee" value="${esc(f.payee || '')}"></label>
          <label class="field"><span>จ่ายจากบัญชี</span><select id="acc"><option value="">—</option>${R.opts(B().accounts, f.account_id)}</select></label>
          <div class="two"><label class="field"><span>เริ่มเดือน</span><input type="month" id="start" value="${(f.start_month || '').slice(0, 7)}"></label>
          <label class="field"><span>ถึงเดือน (ถ้ามี)</span><input type="month" id="end" value="${(f.end_month || '').slice(0, 7)}"></label></div>
          <label class="check"><input type="checkbox" id="auto" ${f.auto_approve ? 'checked' : ''}> อนุมัติอัตโนมัติ (ไปที่ "รอทำจ่าย" เลย)</label>
          <label class="check"><input type="checkbox" id="conf" ${f.confirmed !== false ? 'checked' : ''}> ยืนยันยอดนี้แล้ว (ยังไม่ยืนยัน = ไม่สร้างบิลและไม่นับในคาดการณ์)</label>
          <label class="field"><span>หมายเหตุ</span><input type="text" id="fnote" value="${esc(f.note || '')}"></label>
          <label class="check"><input type="checkbox" id="active" ${f.active ? 'checked' : ''}> ใช้งาน</label>
          <button class="btn primary lg">บันทึก</button></form>`);
        m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
          await R.api('master.save', { entity: 'fixed_expenses', data: { id: f.id, name: R.val(m.el, '#name'), category_id: R.val(m.el, '#cat') || null, payee: R.val(m.el, '#payee'),
            amount: R.val(m.el, '#amt'), due_day: R.val(m.el, '#due'), account_id: R.val(m.el, '#acc') || null, start_month: R.val(m.el, '#start') + '-01',
            end_month: R.val(m.el, '#end') ? R.val(m.el, '#end') + '-01' : null, auto_approve: R.val(m.el, '#auto'), confirmed: R.val(m.el, '#conf'), note: R.val(m.el, '#fnote') || null, active: R.val(m.el, '#active') } });
          m.close(); fixed(body);
        }); });
      };
      on(body.querySelector('#add'), () => edit());
      on(body.querySelector('#gen'), (ev) => R.busy(ev.currentTarget, async () => { const r = await R.api('fixed.generate', {}); R.toast(r.created ? 'สร้างรายการ ' + r.created + ' รายการ' : 'เดือนนี้สร้างครบแล้ว'); fixed(body); }));
      if (R.can('expense.approve')) body.querySelectorAll('[data-f]').forEach((b) => b.addEventListener('click', () => edit(list.find((x) => x.id === b.dataset.f))));
    }
    await draw();
  });

  // ------------------------------------------------------------ closes of all staff + workdays
  R.def('closes', { title: 'รายงานปิดยอดทั้งหมด', back: 'more' }, async function (el) {
    async function draw() {
      const to = R.today(), month0 = to.slice(0, 8) + '01';
      const [list, wd] = await Promise.all([R.api('close.list', { from: R.addDays(to, -45), to }), R.api('close.workdays', { from: month0, to })]);
      el.innerHTML = `${R.sec('วันทำงานเดือนนี้')}
        ${R.list(wd.map((w) => R.row({ static: true, avatar: w.display_name, t: esc(w.display_name), s: `ส่งเอง ${w.submitted} ครั้ง · ตรงเวลา ${w.on_time} · หลังเวลา ${w.late}`, v: w.days + ' วัน' })), 'ยังไม่มีข้อมูล')}
        <p class="muted small" style="padding:0 4px">นับ 1 วันต่อวันที่ส่งรายงานปิดยอดสำเร็จ สำหรับผู้ส่งและผู้ร่วมกะ วันเดียวกันนับไม่เกิน 1 วันต่อคน</p>
        ${R.sec('14 วันล่าสุด')}<div class="card"><div class="chips" style="flex-wrap:wrap">${Array.from({ length: 14 }, (_, i) => R.addDays(to, -i)).map((d) => {
          const has = list.some((c) => c.biz_date === d), hol = R.isHoliday(d);
          return `<span class="chip day-chip ${has ? 'ok' : hol ? 'off' : d === to ? '' : 'miss'}" title="${has ? 'ส่งรายงานแล้ว' : hol ? 'ร้านหยุด' : 'ไม่มีรายงาน'}">${R.date(d).replace(/ \d{4}$/, '')} ${has ? '✓' : hol ? 'หยุด' : d === to ? 'วันนี้' : '–'}</span>`; }).join('')}</div>
          <p class="muted small">✓ ส่งรายงานแล้ว · หยุด = วันหยุดร้าน (ตั้งที่ ตั้งค่าร้าน) · – = ไม่มีรายงาน</p></div>
        ${R.sec('รายงานปิดยอด 45 วัน')}
        ${R.list(list.map((c) => R.row({ data: { c: c.id }, icon: 'moon', tone: Number(c.variance) && !c.reviewed_at ? 'warn' : c.reviewed_at ? 'ok' : '', t: R.date(c.biz_date),
          s: `${esc(c.submitted_by_name)} · ${R.time(c.submitted_at)} น.${c.on_time === false ? ' (หลังเวลา)' : ''} · ยอดขาย ${money(c.summary.total_net)}${c.revision > 1 ? ' · แก้ไขแล้ว' : ''}`, v: Number(c.variance) ? signed(c.variance) : 'ตรง', vs: c.reviewed_at ? 'ตรวจแล้ว' : 'เงินสด' })), 'ยังไม่มีรายงาน')}`;
      el.querySelectorAll('[data-c]').forEach((b) => b.addEventListener('click', () => closeSheet(list.find((x) => x.id === b.dataset.c), () => draw().catch(R.fail))));
    }
    await draw();
  });

  // ------------------------------------------------------------ accounting / tax export
  R.def('export', { title: 'ส่งออกข้อมูลบัญชีและภาษี', back: 'more' }, async function (el) {
    const KINDS = [['ledger', 'สมุดเงินกลาง (18 คอลัมน์)'], ['tax_monthly', 'สรุปรายเดือนเตรียมภาษี'], ['sales', 'ยอดขายรายรายการ'], ['money', 'เงินรับ-จ่ายทุกบัญชี'], ['expenses', 'ค่าใช้จ่ายและการจ่าย'], ['delivery', 'Delivery ค่าธรรมเนียม เงินเข้า'],
      ['corrections', 'ยกเลิก คืนเงิน การแก้ไข'], ['receipts', 'ใบรับของและต้นทุน'], ...(R.can('audit.view') ? [['audit', 'ประวัติการใช้งาน']] : [])];
    el.innerHTML = `<form class="form" id="f" onsubmit="return false">
      <div class="card"><div class="field"><span>ข้อมูลที่ต้องการ</span>${R.seg('kind', KINDS, 'ledger', 'wrap')}</div>
        <p class="note info" id="taxnote" hidden>สรุปรายเดือนเป็นข้อมูลเตรียมให้นักบัญชี ไม่ใช่แบบยื่นภาษี</p>
        <div class="two"><label class="field"><span>ตั้งแต่</span><input type="date" id="from" value="${R.today().slice(0, 8)}01"></label>
        <label class="field"><span>ถึง</span><input type="date" id="to" value="${R.today()}"></label></div>
        <details><summary>กรองเพิ่ม</summary><div class="form" style="margin-top:8px">
          <label class="field"><span>ช่องทาง</span><select id="ch"><option value="">ทั้งหมด</option>${R.opts(B().channels)}</select></label>
          <label class="field"><span>สถานะ</span><input type="text" id="status" placeholder="เช่น paid, cancelled, จ่ายแล้ว"></label>
          <label class="field"><span>ผู้บันทึก</span><select id="user"><option value="">ทุกคน</option>${R.opts(B().users, null, 'display_name')}</select></label></div></details>
        <p class="muted small">ทุกแถวมีรหัสรายการคงที่ ย้อนหาต้นทางได้ รายการที่ยกเลิกยังอยู่ในไฟล์พร้อมเหตุผล และการส่งออกถูกบันทึกในประวัติ</p></div></form>
      <div id="out"></div>
      ${R.actionbar('<button class="btn" id="pv">ดูตัวอย่าง</button><button class="btn primary" id="dl">' + R.icon('download') + ' ดาวน์โหลด CSV</button>')}`;
    const f = el.querySelector('#f');
    f.querySelector('.seg').addEventListener('change', () => { f.querySelector('#taxnote').hidden = R.segVal(f, 'kind') !== 'tax_monthly'; });
    const payload = () => ({ kind: R.segVal(f, 'kind'), from: R.val(f, '#from'), to: R.val(f, '#to'), channel_id: R.val(f, '#ch') || null, status: R.val(f, '#status') || null, user_id: R.val(f, '#user') || null });
    document.getElementById('dl').addEventListener('click', (ev) => R.busy(ev.currentTarget, async () => {
      const p = payload(); const rows = await R.api('export', p);
      R.downloadCsv(`rsa-${p.kind}-${p.from}-to-${p.to}.csv`, rows); if (rows.length) R.toast('ส่งออก ' + rows.length + ' แถว');
    }));
    document.getElementById('pv').addEventListener('click', (ev) => R.busy(ev.currentTarget, async () => {
      const rows = await R.api('export', payload());
      const cols = rows.length ? Object.keys(rows[0]) : [];
      el.querySelector('#out').innerHTML = rows.length ? `${R.sec(rows.length + ' แถว (แสดง 20 แถวแรก)')}<div class="table-wrap"><table class="plain"><thead><tr>${cols.map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead><tbody>
        ${rows.slice(0, 20).map((r) => `<tr>${cols.map((c) => `<td>${esc(typeof r[c] === 'object' && r[c] ? JSON.stringify(r[c]) : r[c])}</td>`).join('')}</tr>`).join('')}</tbody></table></div>` : R.empty('ไม่มีข้อมูลในช่วงนี้');
    }));
  });
})();
