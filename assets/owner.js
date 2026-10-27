/* RSA - POS Assistant — Owner screens: overview, approvals inbox, money, reports, expenses, closes, export (mobile app layout) */
(function () {
  'use strict';
  const R = window.RSA, esc = R.esc, money = R.money, qty = R.qty, baht = R.baht;
  const B = () => R.state.boot;
  const on = (node, fn) => node && node.addEventListener('click', fn);
  const signed = (v) => (Number(v) > 0 ? '+' : '') + money(v);
  const WD = ['วันอาทิตย์', 'วันจันทร์', 'วันอังคาร', 'วันพุธ', 'วันพฤหัสบดี', 'วันศุกร์', 'วันเสาร์'];

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
    low_stock: 'stock', unconfirmed: 'settings', budget_over: 'cashflow', cost_ratio_high: 'cashflow', debt_short: 'cashflow', missing_docs: 'expenses', fixed_overdue: 'approvals',
    five_paydays: 'staff' };
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
      ${x.cancel_reason ? `<div class="note">ยกเลิก: ${esc(x.cancel_reason)}${x.replaced_by_no ? ' · แทนด้วย ' + esc(x.replaced_by_no) : ''}</div>` : ''}
      ${x.replaces_no || x.edited_at ? `<p class="muted small">${x.replaces_no ? 'แก้ไขจาก ' + esc(x.replaces_no) + ' · ' : ''}${x.edited_at ? 'แก้ไขล่าสุด ' + R.dt(x.edited_at) + (x.edited_by_name ? ' โดย ' + esc(x.edited_by_name) : '') : ''}</p>` : ''}
      ${x.wage_bill && x.status !== 'ยกเลิก' ? '<div class="note info">บิลค่าจ้างประมาณการ แก้ยอดได้ จ่ายจริงที่หน้า พนักงาน / ค่าจ้าง (ตามวันทำงาน) แล้วระบบปิดบิลนี้ให้เอง</div>' : ''}
      <div class="btn-row" id="acts"></div>`);
    const acts = [];
    if (R.can('expense.cancel') && x.status !== 'ยกเลิก') acts.push(['x', x.status === 'รออนุมัติ' ? 'ไม่อนุมัติ' : 'ยกเลิก', 'danger']);
    if (R.can('expense.approve') && x.status === 'รออนุมัติ') acts.push(['ok', 'อนุมัติ', '']);
    if (R.can('expense.approve') && x.status === 'จ่ายแล้ว' && !x.reviewed) acts.push(['ok', 'ตรวจแล้ว', 'primary']);
    const editable = x.status !== 'ยกเลิก' && !x.receipt_id && x.fund_source !== 'payroll' && !x.advance_user_id
      && (R.can('expense.approve') || (x.created_by === B().me.id && x.status === 'รออนุมัติ'));
    if (editable) acts.push(['ed', 'แก้ไข', '']);
    if (x.wage_bill && x.status !== 'ยกเลิก' && R.can('expense.pay')) acts.push(['wage', 'จ่ายค่าจ้าง', 'primary']);
    else if (R.can('expense.pay') && (x.status === 'รอทำจ่าย' || (x.status === 'รออนุมัติ' && R.can('expense.approve')))) acts.push(['pay', x.status === 'รออนุมัติ' ? 'อนุมัติและจ่าย' : 'จ่ายเงิน', 'primary']);
    m.el.querySelector('#acts').innerHTML = acts.map(([k, l, c]) => `<button class="btn lg ${c}" data-a="${k}">${l}</button>`).join('') + R.purgeBtn(x.status === 'ยกเลิก' && !x.receipt_id && !x.fixed_expense_id && x.fund_source !== 'payroll' && !x.advance_user_id);
    R.purge(m.el, 'expense', x.id, x.expense_no + ' ' + x.description, () => { m.close(); done(); });
    on(m.el.querySelector('[data-a=ok]'), (ev) => R.busy(ev.currentTarget, async () => { await R.api('expense.approve', { expense_id: x.id }); m.close(); R.toast('บันทึกแล้ว'); done(); }));
    on(m.el.querySelector('[data-a=pay]'), () => { m.close(); paySheet(x, done); });
    on(m.el.querySelector('[data-a=wage]'), () => { m.close(); location.hash = '#/staff'; });
    on(m.el.querySelector('[data-a=ed]'), () => { m.close(); editExpense(x, done); });
    on(m.el.querySelector('[data-a=x]'), async () => {
      m.close();
      const r = await R.askReason((x.status === 'รออนุมัติ' ? 'ไม่อนุมัติ ' : 'ยกเลิก ') + x.expense_no, { text: x.status === 'จ่ายแล้ว' ? 'จ่ายไปแล้ว ระบบจะบันทึกเงินกลับเข้าบัญชีเดิม' : '', danger: true, ok: 'ยืนยัน' });
      if (r) R.busy(null, async () => { await R.api('expense.cancel', { expense_id: x.id, reason: r.reason }); done(); });
    });
  }
  R.expenseSheet = expenseSheet;

  // edit: not paid yet = changed in place; paid = old row cancelled and a new one paid (money follows), always with a reason
  function editExpense(x, done) {
    const m = R.modal('แก้ไข ' + x.expense_no, `<form class="form">
      ${x.status === 'จ่ายแล้ว' ? '<p class="note info">จ่ายแล้ว: ระบบยกเลิกรายการเดิม (เงินกลับเข้าบัญชีเดิม) แล้วบันทึกใหม่ด้วยยอดที่แก้ เก็บประวัติทั้งสองรายการ</p>' : ''}
      <label class="field"><span>จำนวนเงิน</span><input type="number" id="amt" min="0.01" step="0.01" inputmode="decimal" class="input-amt" value="${esc(x.amount)}" required></label>
      <label class="field"><span>จ่ายค่าอะไร</span><input type="text" id="desc" value="${esc(x.description)}" required></label>
      <label class="field"><span>หมวด</span><select id="cat">${R.catOptions(B().categories.filter((c) => !R.isNotCost(c)), x.category_id)}</select></label>
      <label class="field"><span>จ่ายให้</span><input type="text" id="payee" value="${esc(x.payee || '')}"></label>
      <label class="field"><span>วันที่ของค่าใช้จ่าย</span><input type="datetime-local" id="at" value="${R.toLocal(x.occurred_at)}"></label>
      <label class="field"><span class="req">เหตุผลที่แก้</span><input type="text" id="why" required placeholder="เช่น ยอดตามใบเสร็จจริง"></label>
      <button class="btn primary lg">บันทึกการแก้ไข</button></form>`);
    m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
      await R.api('expense.update', { expense_id: x.id, amount: R.val(m.el, '#amt'), description: R.val(m.el, '#desc'), category_id: R.val(m.el, '#cat'),
        payee: R.val(m.el, '#payee'), occurred_at: R.val(m.el, '#at') ? R.toIso(R.val(m.el, '#at')) : null, reason: R.val(m.el, '#why') });
      m.close(); R.toast('แก้ไขแล้ว ยอดในภาพรวมเปลี่ยนตามทันที'); done();
    }); });
  }
  R.editExpense = editExpense;

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
  // ------------------------------------------------------------ money plan: each month's payments against the money expected
  const MP_ST = { ok: ['ok', 'พอจ่าย'], five: ['warn', 'ค่าจ้าง 5 รอบ'] };
  const TH_M = ['ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.', 'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.'];
  const monthName = (ym) => TH_M[Number(ym.slice(5, 7)) - 1] + ' ' + (Number(ym.slice(0, 4)) + 543);
  function monthCard(m) {
    const [tone, label] = m.status === 'short' ? ['bad', 'ขาด ' + money(m.short)] : MP_ST[m.status] || MP_ST.ok;
    return `<div class="mp-month ${m.status === 'short' ? 'alert' : ''}">
      <div class="mp-line"><b>${monthName(m.month)}${m.partial ? ' <span class="muted small">(ที่เหลือของเดือน)</span>' : ''}</b><span class="pill ${tone}">${label}</span></div>
      ${m.lines.length ? m.lines.map((l) => `<div class="mp-line small"><span class="muted">${esc(l.label)}</span><span class="num">${money(l.amount)}</span></div>`).join('') : '<div class="muted small">ยังไม่มีรายการต้องจ่าย</div>'}
      <div class="mp-line tot small"><span>ต้องจ่ายรวม</span><span class="num">${baht(m.total)}</span></div>
      <div class="mp-line small"><span class="muted">เงินคาดว่าเหลือสิ้นเดือน</span><span class="num" style="color:${m.end_cash < 0 ? 'var(--bad)' : 'inherit'}">${baht(m.end_cash)}</span></div>
      ${m.advice ? `<div class="small"><b>ควรทำ:</b> ${esc(m.advice)}</div>` : ''}</div>`;
  }
  function moneyChart(mp) {
    const pts = mp.daily, W = 640, H = 200, L = 56, Rt = 14, T = 14, Bt = 28;
    const vals = pts.map((p) => p.balance).concat([mp.min_cash || 0, 0]);
    const hi = Math.max(...vals), lo = Math.min(...vals), span = hi - lo || 1;
    const x = (i) => L + (i * (W - L - Rt)) / (pts.length - 1), y = (v) => T + (H - T - Bt) * (1 - (v - lo) / span);
    const line = pts.map((p, i) => `${x(i).toFixed(1)},${y(p.balance).toFixed(1)}`).join(' ');
    const first = pts.findIndex((p) => mp.min_cash && p.balance < mp.min_cash);
    const marks = pts.map((p, i) => (p.loan ? `<circle cx="${x(i)}" cy="${y(p.balance)}" r="5" fill="var(--bad)"><title>ผ่อนเงินกู้ลงทุน ${money(p.loan)}</title></circle>
      <text x="${Math.min(x(i) + 6, W - 150)}" y="${Math.min(y(p.balance) + 16, H - Bt - 4)}" class="bad">ผ่อนเงินกู้ลงทุน −${money(p.loan)}</text>` : '')).join('');
    const ticks = [0, 15, 30, 45, 60].map((i) => `<text x="${x(i)}" y="${H - 8}" text-anchor="middle">${R.date(pts[i].date).replace(/\s\d{4}$/, '')}</text>`).join('');
    const ylab = [hi, lo].map((v) => `<text x="${L - 6}" y="${y(v) + 4}" text-anchor="end">${Math.round(v).toLocaleString('th-TH')}</text>`).join('');
    return `<div class="mp-title"><b>เงินสดคาดการณ์ 60 วัน</b>${first >= 0 ? `<span class="pill bad">ต่ำกว่าขั้นต่ำ ${esc(R.date(pts[first].date))}</span>` : '<span class="pill ok">ไม่ต่ำกว่าขั้นต่ำ</span>'}</div>
      <figure class="chart"><svg viewBox="0 0 ${W} ${H}" role="img" aria-label="เงินสดคาดการณ์ 60 วัน">
        ${ylab}${ticks}<line x1="${L}" x2="${W - Rt}" y1="${y(0)}" y2="${y(0)}" class="g"/>
        ${mp.min_cash ? `<line x1="${L}" x2="${W - Rt}" y1="${y(mp.min_cash)}" y2="${y(mp.min_cash)}" stroke="var(--bad)" stroke-dasharray="5 4"/><text x="${W - Rt}" y="${y(mp.min_cash) - 5}" text-anchor="end" class="bad">ขั้นต่ำ ${money(mp.min_cash)}</text>` : ''}
        <polygon points="${x(0)},${y(lo)} ${line} ${x(pts.length - 1)},${y(lo)}" fill="var(--accent)" opacity=".1"/>
        <polyline points="${line}" fill="none" stroke="var(--accent)" stroke-width="2.5" stroke-linejoin="round"/>${marks}</svg></figure>`;
  }
  // this month's costs: main categories only; the full table opens on request
  async function costSummary(el) {
    const box = el.querySelector('#costsum'); if (!box) return;
    const c = await R.api('report.costs', {}), over = Number(c.over_alert_pct) || 0.1;
    const rows = c.rows.filter((r) => ['A', 'B'].includes(r.grp) && !r.parent_id && (Number(r.used) || Number(r.budget_to_date)));
    rows.sort((a, b) => (b.budget_to_date ? b.used / b.budget_to_date : 0) - (a.budget_to_date ? a.used / a.budget_to_date : 0));
    box.innerHTML = `${rows.slice(0, 6).map((r) => { const bt = Number(r.budget_to_date) || 0, u = Number(r.used), bad = bt && u > bt * (1 + over), warn = bt && u > bt;
      const w = bt ? Math.min(100, (u / Math.max(u, bt)) * 100) : 100, mk = bt ? Math.min(100, (bt / Math.max(u, bt)) * 100) : null;
      return `<div class="mp-cost"><span>${esc(r.name)}${bad ? ` <span class="pill bad">เกิน ${money(u - bt)}</span>` : ''}${r.estimate ? ' <span class="muted small">ประมาณการ</span>' : ''}</span>
        <b class="num">${money(u)}${bt ? ' / ' + money(bt) : ''}</b><span class="bar"><i class="${bad ? 'bad' : warn ? 'warn' : 'ok'}" style="width:${w}%"></i>${mk != null ? `<b style="left:${mk}%"></b>` : ''}</span></div>`; }).join('')}
      <p class="muted small">ใช้จริง / งบที่ควรใช้ถึงวันนี้ (เส้นดำ) · กำไรสุทธิเดือนนี้ ${baht(c.summary.net_profit)}</p>
      <button type="button" class="btn small" id="costmore">ดูทุกหมวดและสัดส่วนรายสัปดาห์</button>`;
    on(box.querySelector('#costmore'), () => { const f = el.querySelector('#costfull'); f.hidden = !f.hidden; if (!f.hidden && !f.dataset.done) { f.dataset.done = '1'; R.costCard(f).catch(R.fail); } });
  }

  R.def('cashflow', { title: 'การบริหารกระแสเงินสด', tab: 'cashflow', back: 'more' }, async function (el) {
    const [x, fc, mp] = await Promise.all([R.api('cashflow.summary', {}), R.api('cashflow.forecast', {}), R.api('cashflow.months', {})]);
    const manage = R.can('cashflow.manage');
    const total = x.accounts.reduce((a, b) => a + Number(b.balance), 0);
    const c = x.capital, pf = x.profit;
    const KIND = { capital_in: 'ลงทุนเพิ่ม', loan_in: 'กู้ยืม', capital_return: 'ถอนเงินเจ้าของ / คืนทุน', loan_repayment: 'ผ่อนเงินกู้ลงทุน', owner_paid: 'เจ้าของจ่ายแทนร้าน' };
    const KIND_NEW = { capital_in: 'ลงทุนเพิ่ม', loan_in: 'กู้ยืม', capital_return: 'ถอนเงินเจ้าของ / คืนทุน', loan_repayment: 'ผ่อนเงินกู้ลงทุน' };
    const PUR = R.PURPOSE;
    el.innerHTML = `${R.sectTabs('cashflow')}<div class="card blue"><span class="muted small">เงินที่ใช้ได้ตอนนี้ (ทุกบัญชี)</span><span class="big-amt">${baht(total)}</span></div>
      ${R.list(x.accounts.map((a) => R.row({ data: { acc: a.id }, icon: a.is_drawer ? 'wallet' : 'receipt', t: esc(a.name),
        s: a.is_drawer ? 'เงินสดหน้าร้าน · นับตอนปิดยอด' : Number(a.unreconciled) ? `ยังไม่ตรวจกับ statement ${a.unreconciled} รายการ` : 'ตรวจกับ statement ครบ', v: baht(a.balance),
        pill: a.opening_confirmed ? '' : '<span class="pill warn">ยอดยกมายังไม่ยืนยัน</span>' })))}
      ${R.can('cashflow.view') ? `${R.sec('เงินเข้า-ออกรายวัน')}<div id="cal" class="card"><div class="boot">กำลังโหลดปฏิทิน…</div></div>` : ''}
      ${R.sec('เตรียมเงินรายเดือน')}
      <div class="mp-chart card">${moneyChart(mp)}</div>
      <div class="mp-months">${mp.months.map(monthCard).join('')}</div>
      <p class="muted small" style="padding:0 4px">เงินคาดการณ์ = เงินตอนนี้ + ยอดขายและเงิน Delivery ที่คาดว่าจะเข้า − ค่าใช้จ่ายทั่วไปเฉลี่ย − รายการที่ต้องจ่าย ใช้ดูทิศทางเท่านั้น</p>
      ${R.can('report.view') ? `${R.sec('ต้นทุนและงบเดือนนี้')}<div class="card" id="costsum"><div class="boot">กำลังโหลด…</div></div><div id="costfull" hidden></div>` : ''}
      ${manage ? R.list([R.row({ data: { act: 'tr' }, icon: 'flow', t: 'โอนเงินระหว่างบัญชี', s: 'เช่น นำเงินสดหน้าร้านฝากธนาคาร' })]) : ''}
      ${R.sec('รอรับเงินจาก Delivery')}
      ${R.list(x.receivables.map((r) => R.row({ data: { set: r.channel_id, from: r.oldest }, icon: 'flow', t: esc(r.channel_name), s: `${r.orders} ออเดอร์ · ครบรอบ ${R.date(r.expected_by)}`, v: baht(r.est_net), vs: manage ? 'แตะเมื่อเงินเข้า' : 'หลังหักค่าธรรมเนียม' })), 'ไม่มียอดค้างรับ')}
      ${R.sec('ค้างจ่าย', x.payables.length ? '<a href="#/approvals">จัดการ</a>' : '')}
      ${R.list(x.payables.slice(0, 6).map((p) => R.row({ href: '#/approvals', icon: 'wallet', t: esc(p.description), s: `ครบ ${R.date(p.due_date)} · ${esc(p.status)}`, v: baht(p.amount) })), 'ไม่มีค่าใช้จ่ายค้างจ่าย')}
      ${R.sec('ทุน เงินกู้ลงทุน และกำไร')}
      <div class="stats">${R.stat('ทุนที่ใส่', baht(c.capital_in), 'คืนแล้ว ' + money(c.capital_returned))}${R.stat('เงินกู้ลงทุนคงเหลือ', baht(c.debt_left ?? (Number(c.loan_in) - Number(c.loan_repaid))), 'ตั้งต้น ' + money(c.opening_debt || 0) + ' + กู้เพิ่ม ' + money(c.loan_in) + ' − ผ่อนแล้ว ' + money(c.loan_repaid))}
        ${R.stat('กำไรสะสม (ประมาณ)', baht(pf.cumulative_net))}${R.stat('กำไรที่ประกาศได้', baht(pf.available), 'ประกาศแล้ว ' + money(pf.declared) + (Number(pf.owner_goods) ? ' · เจ้าของหยิบสินค้า ' + money(pf.owner_goods) : ''))}</div>
      ${profitNote(pf)}
      ${manage ? R.list([R.row({ data: { act: 'pf' }, icon: 'check', t: 'ประกาศใช้กำไร', s: 'โปะเงินกู้ลงทุน · เก็บเป็นเงินหมุน · ลงทุนกลับร้าน · คืนทุน · จ่ายเจ้าของ' }), R.row({ data: { act: 'cap' }, icon: 'plus', t: 'บันทึกทุน ถอนเงินเจ้าของ หรือ เงินกู้' }), R.row({ href: '#/invest', icon: 'chart', t: 'เงินลงทุน / คืนทุน' })]) : ''}
      ${x.declarations.length || x.capital_rows.length ? R.sec('ประวัติทุนและการใช้กำไร') + R.list([
        ...x.declarations.map((d) => R.row({ data: d.status === 'done' && manage ? { pfx: d.id } : {}, static: !(d.status === 'done' && manage), off: d.status === 'cancelled', icon: 'check', t: 'ประกาศใช้กำไร · ' + PUR[d.purpose], s: `${R.date(d.declared_at)} · ${esc(d.recipient)}${!d.paid_now && !['keep_working_capital', 'reinvest'].includes(d.purpose) && d.status === 'done' ? ' · ยังไม่จ่าย' : ''}`, v: baht(d.amount) })),
        ...x.capital_rows.filter((r) => !r.profit_declaration_id && r.kind !== 'investment_item').map((r) => R.row({ data: r.status === 'done' && manage ? { capx: r.id } : {}, static: !(r.status === 'done' && manage), off: r.status === 'cancelled', icon: 'plus', t: KIND[r.kind], s: `${R.date(r.occurred_at)} · ${esc(r.party)}`, v: baht(r.amount) }))]) : ''}
      <div id="setl"></div>`;

    costSummary(el).catch(R.fail);
    if (el.querySelector('#cal')) calendar(el.querySelector('#cal')).catch(R.fail);
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
      ${Number(fc.min_working_capital) ? `<p class="muted small">ถอนเงิน/ผ่อนเงินกู้ลงทุนได้เมื่อเหลือเงินหมุนอย่างน้อย ${baht(fc.min_working_capital)}</p>` : ''}
      <label class="field"><span>ผู้ลงทุน / ผู้ให้กู้</span><input type="text" id="p" required></label><label class="field"><span>จำนวน (บาท)</span><input type="number" step="0.01" min="0.01" inputmode="decimal" id="a" class="input-amt" required></label>
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

  // ------------------------------------------------------------ money in / out calendar: real numbers up to today, scheduled ones ahead
  const kfmt = (v) => { const a = Math.abs(Number(v)); return (a >= 1000 ? (Math.round(a / 100) / 10).toLocaleString('th-TH') + 'k' : Math.round(a).toLocaleString('th-TH')); };
  let calMonth = null;
  async function calendar(box) {
    const m0 = calMonth || R.today().slice(0, 8) + '01', c = await R.api('cashflow.calendar', { month: m0 }), sm = c.summary;
    const lead = new Date(m0 + 'T12:00:00Z').getUTCDay();
    const tile = (cls, t, x) => `<div class="cal-sum ${cls}"><span>${t}</span><b>${baht(x.amount)}</b><small>${x.count} รายการ</small></div>`;
    box.innerHTML = `<div class="cal-head"><button type="button" class="btn small ghost" data-cm="-1" aria-label="เดือนก่อน">‹</button><h2>${esc(monthName(m0))}</h2><button type="button" class="btn small ghost" data-cm="1" aria-label="เดือนถัดไป">›</button></div>
      <div class="cal-sums">${tile('in', 'เงินเข้า', sm.in)}${tile('late', 'ค้างรับเกินเวลา', sm.overdue_in)}${tile('exp', 'เงินคาดว่าจะเข้า', sm.expect_in)}
        ${tile('out', 'เงินออก', sm.out)}${tile('late', 'ค้างจ่ายเกินเวลา', sm.overdue_out)}${tile('exp', 'เงินคาดว่าจะออก', sm.expect_out)}</div>
      <div class="cal-grid">${R.WEEKDAYS.map((d) => `<div class="cal-wd">${d}</div>`).join('')}${'<div></div>'.repeat(lead)}
        ${c.days.map((d) => { const net = Number(d.in) - Number(d.out), has = Number(d.in) || Number(d.out);
          return `<button type="button" class="cal-day ${d.future ? 'future' : ''} ${d.date === c.today ? 'today' : ''}" data-cd="${d.date}" ${has ? '' : 'disabled'}>
            <span class="dn">${Number(d.date.slice(8))}</span>${has ? `<span class="net ${net >= 0 ? 'pos' : 'neg'}">${net >= 0 ? '+' : '−'}${kfmt(net)}</span>
            <span class="io">${Number(d.in) ? `<i class="pos">+${money(d.in)}</i>` : ''}${Number(d.out) ? `<i class="neg">−${money(d.out)}</i>` : ''}</span>` : ''}</button>`; }).join('')}</div>
      <p class="muted small">ถึงวันนี้เป็นเงินเข้า-ออกจริง (ไม่นับโอนระหว่างบัญชีร้าน) · วันข้างหน้า (ตัวจาง) เป็นรายการที่ถึงกำหนด: ค่าใช้จ่ายประจำ บิลรอจ่าย ผ่อนเงินกู้ลงทุน และเงิน Delivery ที่จะเข้า</p>`;
    box.querySelectorAll('[data-cm]').forEach((b) => b.addEventListener('click', () => { const d = new Date(m0 + 'T12:00:00Z'); d.setUTCMonth(d.getUTCMonth() + Number(b.dataset.cm)); calMonth = d.toISOString().slice(0, 8) + '01'; calendar(box).catch(R.fail); }));
    box.querySelectorAll('[data-cd]').forEach((b) => b.addEventListener('click', () => { const d = c.days.find((x) => x.date === b.dataset.cd);
      R.modal(R.date(d.date) + (d.future ? ' · คาดการณ์' : ''), `${R.mlist([['', d.items.map((i) => R.mrow(i.label + (i.count > 1 ? ` · ${i.count} รายการ` : ''), `<span style="color:${i.dir === 'in' ? 'var(--ok)' : 'var(--bad)'}">${i.dir === 'in' ? '+' : '−'}${money(i.amount)}</span>`))]])}
        <div class="sum-row"><span>สุทธิ</span><b>${signed(Number(d.in) - Number(d.out))}</b></div>`); }));
  }

  // ------------------------------------------------------------ all expenses
  R.def('expenses', { title: 'ค่าใช้จ่ายทั้งหมด', back: 'more' }, async function (el) {
    let tab = R.store.get('exp.tab') || '';
    const TABS = [['', 'ทั้งหมด'], ['fixed', 'ค่าใช้จ่ายประจำ'], ['รออนุมัติ', 'รออนุมัติ'], ['รอทำจ่าย', 'รอทำจ่าย'], ['จ่ายแล้ว', 'จ่ายแล้ว'], ['docs', 'รอเอกสาร'], ['ยกเลิก', 'ยกเลิก']];
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
      el.querySelectorAll('[data-tab]').forEach((b) => b.addEventListener('click', () => { tab = b.dataset.tab; R.store.set('exp.tab', tab); draw().catch(R.fail); }));
      R.bindPeriod(el, () => draw().catch(R.fail));
      const body = el.querySelector('#body');
      if (tab === 'fixed') return fixed(body);
      let list;
      if (tab === 'docs') {
        // paid in the last 60 days with no receipt / slip attached
        const miss = (await R.api('report.costs', {})).missing_docs.map((d) => d.id);
        list = (await R.api('expense.list', { from: R.addDays(R.today(), -60) })).filter((x) => miss.includes(x.id));
      } else list = await R.api('expense.list', { status: tab, ...r });
      body.innerHTML = `<p class="muted small" style="padding:0 4px">${list.length} รายการ รวม ${baht(list.reduce((a, x) => a + Number(x.amount), 0))}</p>
        ${R.list(list.map((x) => R.row({ data: { x: x.id }, icon: 'wallet', off: x.status === 'ยกเลิก', t: esc(x.description), s: `${R.dt(x.occurred_at)} · ${esc(x.category_name || '')} · ${esc(R.FUND[x.fund_source] || '')} · ${esc(x.created_by_name)}${x.attachments.length ? '' : ' · ไม่มีรูป'}`,
          v: baht(x.amount), pill: R.statusPill(x.status) + (x.status === 'จ่ายแล้ว' && !x.reviewed ? ' <span class="pill">รอตรวจ</span>' : '') + (x.owed_to ? ' <span class="pill warn">ค้างคืน</span>' : '') })), 'ไม่มีรายการ')}`;
      body.querySelectorAll('[data-x]').forEach((b) => b.addEventListener('click', () => expenseSheet(list.find((y) => y.id === b.dataset.x), () => draw().catch(R.fail))));
    }
    async function fixed(body) {
      const [list, rl] = await Promise.all([R.api('master.list', { entity: 'fixed_expenses' }), R.api('recurring.list', {})]);
      const nextDue = Object.fromEntries(rl.fixed.map((f) => [f.id, f.next_due]));
      body.innerHTML = `<p class="muted small" style="padding:0 4px">ระบบสร้างรายการ "รอทำจ่าย" ให้เองทุกรอบ (รายเดือนหรือรายสัปดาห์) ไม่สร้างซ้ำ จ่ายแล้วเปลี่ยนเป็น "จ่ายแล้ว"</p>
        ${R.list(list.map((f) => R.row({ data: { f: f.id }, icon: 'calendar', off: !f.active, t: esc(f.name), s: `${f.frequency === 'weekly' ? 'ทุก' + WD[f.weekday] : 'ทุกวันที่ ' + f.due_day}${f.active && nextDue[f.id] ? ' · ครั้งถัดไป ' + esc(R.date(nextDue[f.id])) : ''}${f.confirmed === false ? ' · ประมาณการ (ยังไม่ยืนยัน)' : ''}${f.payee ? ' · ' + esc(f.payee) : ''}${f.this_month ? ' · เดือนนี้ ' + esc(f.this_month.status) : ''}${f.note ? ' · ' + esc(f.note) : ''}`, v: baht(f.amount), pill: f.confirmed === false ? R.unconfirmed() : '' })), 'ยังไม่มี เช่น ค่าเช่า ค่าจ้าง ค่าอินเทอร์เน็ต')}
        ${rl.loan.length ? R.sec('ผ่อนเงินกู้ลงทุน') + R.list(rl.loan.map((x) => R.row({ static: true, icon: 'wallet', off: !Number(x.left), t: 'งวด ' + x.n, s: R.date(x.due) + (Number(x.left) ? (Number(x.paid) ? ' · จ่ายแล้ว ' + money(x.paid) : '') : ' · จ่ายครบแล้ว'), v: baht(x.amount) }))) : ''}
        ${R.can('expense.approve') ? '<div class="btn-row"><button class="btn" id="gen">สร้างรายการเดือนนี้</button><button class="btn primary" id="add">+ เพิ่มรายการประจำ</button></div>' : ''}`;
      const edit = (f) => {
        f = f || { active: true, due_day: 1, start_month: R.today().slice(0, 8) + '01', auto_approve: false };
        const m = R.modal(f.id ? 'แก้ไขค่าใช้จ่ายประจำ' : 'เพิ่มค่าใช้จ่ายประจำ', `<form class="form">
          <label class="field"><span>ชื่อรายการ</span><input type="text" id="name" value="${esc(f.name || '')}" required></label>
          <div class="field"><span>รอบจ่าย</span>${R.seg('freq', [['monthly', 'รายเดือน'], ['weekly', 'รายสัปดาห์']], f.frequency || 'monthly')}</div>
          <label class="field"><span>จำนวนต่อรอบ</span><input type="number" id="amt" min="0" step="0.01" inputmode="decimal" value="${f.amount ?? ''}" class="input-amt" required></label>
          <div class="two"><label class="field" id="duebox"><span>ครบกำหนดวันที่</span><input type="number" id="due" min="1" max="31" value="${f.due_day || 1}"></label>
          <label class="field" id="wdbox"><span>ครบกำหนดทุกวัน</span><select id="wd">${WD.map((w, i) => `<option value="${i}" ${Number(f.weekday ?? 6) === i ? 'selected' : ''}>${w}</option>`).join('')}</select></label>
          <label class="field"><span>หมวด</span><select id="cat">${R.catOptions(B().categories.filter((c) => !R.isNotCost(c)), f.category_id)}</select></label></div>
          <label class="field"><span>แหล่งเงินที่ใช้จ่าย</span><select id="fsrc"><option value="">—</option>${['shop_cash', 'shop_bank', 'other_account'].map((k) => `<option value="${k}" ${f.fund_source === k ? 'selected' : ''}>${esc(R.FUND[k])}</option>`).join('')}</select></label>
          <label class="field"><span>จ่ายให้</span><input type="text" id="payee" value="${esc(f.payee || '')}"></label>
          <label class="field"><span>จ่ายจากบัญชี</span><select id="acc"><option value="">—</option>${R.opts(B().accounts, f.account_id)}</select></label>
          <div class="two"><label class="field"><span>เริ่มเดือน</span><input type="month" id="start" value="${(f.start_month || '').slice(0, 7)}"></label>
          <label class="field"><span>ถึงเดือน (ถ้ามี)</span><input type="month" id="end" value="${(f.end_month || '').slice(0, 7)}"></label></div>
          <label class="check"><input type="checkbox" id="auto" ${f.auto_approve ? 'checked' : ''}> อนุมัติอัตโนมัติ (ไปที่ "รอทำจ่าย" เลย)</label>
          <label class="check"><input type="checkbox" id="conf" ${f.confirmed !== false ? 'checked' : ''}> ยืนยันยอดนี้แล้ว (ยังไม่ยืนยัน = ไม่สร้างบิลและไม่นับในคาดการณ์)</label>
          <label class="field"><span>หมายเหตุ</span><input type="text" id="fnote" value="${esc(f.note || '')}"></label>
          <label class="check"><input type="checkbox" id="active" ${f.active ? 'checked' : ''}> ใช้งาน</label>
          <button class="btn primary lg">บันทึก</button></form>`);
        const fq = () => { const w = R.segVal(m.el, 'freq') === 'weekly'; m.el.querySelector('#duebox').hidden = w; m.el.querySelector('#wdbox').hidden = !w; };
        m.el.querySelector('.seg').addEventListener('change', fq); fq();
        m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
          const wk = R.segVal(m.el, 'freq') === 'weekly';
          await R.api('master.save', { entity: 'fixed_expenses', data: { id: f.id, name: R.val(m.el, '#name'), category_id: R.val(m.el, '#cat') || null, payee: R.val(m.el, '#payee'),
            frequency: wk ? 'weekly' : 'monthly', weekday: wk ? Number(R.val(m.el, '#wd')) : null, fund_source: R.val(m.el, '#fsrc') || null,
            amount: R.val(m.el, '#amt'), due_day: wk ? 1 : R.val(m.el, '#due'), account_id: R.val(m.el, '#acc') || null, start_month: R.val(m.el, '#start') + '-01',
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
  R.def('export', { title: 'ส่งออกให้นักบัญชี', back: 'more' }, async function (el) {
    const KINDS = [['ledger', 'สมุดเงินกลาง (18 คอลัมน์)'], ['tax_monthly', 'สรุปรายเดือนเตรียมภาษี'], ['sales', 'ยอดขายรายรายการ'], ['money', 'เงินรับ-จ่ายทุกบัญชี'], ['expenses', 'ค่าใช้จ่ายและการจ่าย'], ['delivery', 'Delivery ค่าธรรมเนียม เงินเข้า'],
      ['corrections', 'ยกเลิก คืนเงิน การแก้ไข'], ['receipts', 'ใบรับของและต้นทุน'], ...(R.can('audit.view') ? [['audit', 'ประวัติการใช้งาน']] : [])];
    // pick by the job, not by the file name; every file is still under "เลือกไฟล์เอง"
    const PRESETS = [['acct', 'ส่งนักบัญชีรายเดือน', 'สรุปรายเดือน + สมุดเงินกลาง + ค่าใช้จ่าย (3 ไฟล์)', ['tax_monthly', 'ledger', 'expenses']],
      ['money', 'เช็กเงินเข้า-ออก', 'ทุกบัญชี ไว้เทียบกับ statement ธนาคาร', ['money']],
      ['sales', 'ดูยอดขายละเอียด', 'ทุกออเดอร์ ทุกรายการสินค้า', ['sales']],
      ['custom', 'เลือกไฟล์เอง', 'ทั้ง ' + KINDS.length + ' แบบ พร้อมตัวกรอง', null]];
    const t = R.today(), m0 = t.slice(0, 8) + '01', pm = R.addDays(m0, -1), RANGES = [['this', 'เดือนนี้', m0, t], ['last', 'เดือนก่อน', pm.slice(0, 8) + '01', pm], ['pick', 'เลือกเอง', m0, t]];
    el.innerHTML = `<form class="form" id="f" onsubmit="return false">
      <div class="form" style="gap:8px">${PRESETS.map(([k, l, d], n) => `<button type="button" class="preset" data-pre="${k}" aria-pressed="${n === 0}"><b>${esc(l)}</b><span>${esc(d)}</span></button>`).join('')}</div>
      <div class="card" id="adv" hidden><div class="field"><span>ไฟล์</span>${R.seg('kind', KINDS, 'ledger', 'wrap')}</div>
        <p class="note info" id="taxnote" hidden>สรุปรายเดือนเป็นข้อมูลเตรียมให้นักบัญชี ไม่ใช่แบบยื่นภาษี</p>
        <label class="field"><span>ช่องทาง</span><select id="ch"><option value="">ทั้งหมด</option>${R.opts(B().channels)}</select></label>
        <label class="field"><span>สถานะ</span><input type="text" id="status" placeholder="เช่น paid, cancelled, จ่ายแล้ว"></label>
        <label class="field"><span>ผู้บันทึก</span><select id="user"><option value="">ทุกคน</option>${R.opts(B().users, null, 'display_name')}</select></label></div>
      <div class="field"><span>ช่วงเวลา</span><div class="chips">${RANGES.map(([k, l], n) => `<button type="button" class="chip" data-rg="${k}" aria-pressed="${n === 0}">${l}</button>`).join('')}</div></div>
      <div class="two" id="dates" hidden><label class="field"><span>ตั้งแต่</span><input type="date" id="from" value="${m0}"></label><label class="field"><span>ถึง</span><input type="date" id="to" value="${t}"></label></div>
      <p class="muted small">ทุกแถวมีรหัสรายการคงที่ ย้อนหาต้นทางได้ รายการที่ยกเลิกยังอยู่ในไฟล์พร้อมเหตุผล</p></form>
      <div id="out"></div>
      ${R.actionbar('<button class="btn" id="pv">ดูตัวอย่าง</button><button class="btn primary" id="dl">' + R.icon('download') + ' ดาวน์โหลด CSV</button>')}`;
    const f = el.querySelector('#f');
    let pre = 'acct';
    f.querySelectorAll('[data-pre]').forEach((b) => b.addEventListener('click', () => {
      pre = b.dataset.pre; f.querySelectorAll('[data-pre]').forEach((x) => x.setAttribute('aria-pressed', x === b)); f.querySelector('#adv').hidden = pre !== 'custom';
    }));
    f.querySelectorAll('[data-rg]').forEach((b) => b.addEventListener('click', () => {
      const r = RANGES.find((x) => x[0] === b.dataset.rg); f.querySelectorAll('[data-rg]').forEach((x) => x.setAttribute('aria-pressed', x === b));
      f.querySelector('#dates').hidden = r[0] !== 'pick'; if (r[0] !== 'pick') { f.querySelector('#from').value = r[2]; f.querySelector('#to').value = r[3]; }
    }));
    f.querySelector('#adv .seg').addEventListener('change', () => { f.querySelector('#taxnote').hidden = R.segVal(f, 'kind') !== 'tax_monthly'; });
    const kinds = () => (pre === 'custom' ? [R.segVal(f, 'kind')] : PRESETS.find((x) => x[0] === pre)[3]);
    const payload = (kind) => ({ kind, from: R.val(f, '#from'), to: R.val(f, '#to'), ...(pre === 'custom' ? { channel_id: R.val(f, '#ch') || null, status: R.val(f, '#status') || null, user_id: R.val(f, '#user') || null } : {}) });
    document.getElementById('dl').addEventListener('click', (ev) => R.busy(ev.currentTarget, async () => {
      let n = 0;
      for (const k of kinds()) { const p = payload(k); const rows = await R.api('export', p); R.downloadCsv(`rsa-${p.kind}-${p.from}-to-${p.to}.csv`, rows); n += rows.length; }
      if (n) R.toast('ส่งออก ' + n + ' แถว');
    }));
    document.getElementById('pv').addEventListener('click', (ev) => R.busy(ev.currentTarget, async () => {
      const rows = await R.api('export', payload(kinds()[0]));
      const cols = rows.length ? Object.keys(rows[0]) : [];
      el.querySelector('#out').innerHTML = rows.length ? `${R.sec(rows.length + ' แถว (แสดง 20 แถวแรก)')}<div class="table-wrap"><table class="plain"><thead><tr>${cols.map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead><tbody>
        ${rows.slice(0, 20).map((r) => `<tr>${cols.map((c) => `<td>${esc(typeof r[c] === 'object' && r[c] ? JSON.stringify(r[c]) : r[c])}</td>`).join('')}</tr>`).join('')}</tbody></table></div>` : R.empty('ไม่มีข้อมูลในช่วงนี้');
    }));
  });

  // ------------------------------------------------------------ import QR / transfer amounts and Delivery platform orders from a file
  const IMP_KIND = { bank: 'ยอด QR / เงินโอนเข้าบัญชี', delivery: 'ออเดอร์ Delivery' };
  const MATCH = { match: ['ok', 'ตรงกัน'], diff: ['warn', 'ยอดต่าง'], missing: ['bad', 'ไม่มีในระบบ'], cancelled: ['', 'ยกเลิกในแพลตฟอร์ม'], dup: ['', 'นำเข้าแล้ว'] };
  const TEMPLATES = {
    bank: { file: 'rsa-template-qr-transfer.csv', rows: [
      { 'วันที่* (date)': 'ตัวอย่าง 20/10/2569', 'เวลา (time)': '', 'ยอดเงิน* (amount)': '3,450.00', 'เลขอ้างอิง (ref)': '', 'รายละเอียด (desc)': 'ยอดรวมทั้งวัน (ไม่ใส่เวลา)' },
      { 'วันที่* (date)': 'ตัวอย่าง 2026-10-21', 'เวลา (time)': '13:05', 'ยอดเงิน* (amount)': '85', 'เลขอ้างอิง (ref)': '202610211305ABC', 'รายละเอียด (desc)': 'ทีละรายการ (แถวที่ขึ้นต้นว่า ตัวอย่าง ระบบข้ามให้)' }] },
    delivery: { file: 'rsa-template-delivery-orders.csv', rows: [
      { 'เลขออเดอร์* (order_id)': 'ตัวอย่าง-LM-1001', 'วันที่* (date)': '21/10/2569', 'เวลา (time)': '12:10', 'ชื่อสินค้า* (item)': 'ชาไทย', 'จำนวน* (qty)': '2', 'ยอดขายก่อนหัก* (gross)': '130', 'ส่วนลดที่ร้านออก (discount)': '10', 'ค่าคอม (commission)': '35.10', 'VAT ค่าคอม (vat)': '2.46', 'ค่าธรรมเนียมอื่น (other)': '', 'สถานะ (status)': 'completed' },
      { 'เลขออเดอร์* (order_id)': 'ตัวอย่าง-LM-1001', 'วันที่* (date)': '21/10/2569', 'เวลา (time)': '12:10', 'ชื่อสินค้า* (item)': 'ขนมปังปิ้ง', 'จำนวน* (qty)': '1', 'ยอดขายก่อนหัก* (gross)': '45', 'ส่วนลดที่ร้านออก (discount)': '', 'ค่าคอม (commission)': '', 'VAT ค่าคอม (vat)': '', 'ค่าธรรมเนียมอื่น (other)': '', 'สถานะ (status)': '' }] },
  };
  // the platform orders of one import that the team did not record → add them to sales
  R.importMissingSheet = async function (imp, done) {
    const list = (await R.api('import.orders', { import_id: imp.id })).filter((x) => x.platform_status === 'completed' && !x.matched_order_id);
    if (!list.length) { R.toast('ไม่มีออเดอร์ที่ต้องเพิ่ม'); return; }
    const items = (x) => (x.items || []).map((i) => `${esc(i.name)} ×${qty(i.qty)}${i.product_id ? '' : ' (ข้าม)'}`).join(', ');
    const m = R.modal('ออเดอร์ที่ไม่มีในระบบ (' + list.length + ')', `<p class="muted small">มีในไฟล์แพลตฟอร์มแต่ทีมไม่ได้ลง กดเพิ่มแล้วระบบสร้างออเดอร์ Delivery ตามเวลาในไฟล์ และตัดสต็อกตามสูตร</p>
      ${R.list(list.map((x) => R.row({ static: true, icon: 'receipt', tone: 'warn', t: '#' + esc(x.external_id), s: `${R.date(x.biz_date)} ${R.time(x.ordered_at)} น. · ${items(x)}`,
        v: money(Number(x.gross) - Number(x.shop_discount)), pill: `<button type="button" class="btn small primary" data-add="${x.id}">เพิ่ม</button>` })))}
      <div class="btn-row" style="margin-top:12px"><button class="btn" type="button" data-close>ไว้ก่อน</button><button class="btn primary lg" id="all">เพิ่มทั้งหมด ${list.length} ออเดอร์</button></div>`, { wide: true });
    const add = (btn, ids) => R.busy(btn, async () => {
      const r = await R.api('import.add_orders', { ids });
      R.toast(`เพิ่มเข้ายอดขาย ${r.added} ออเดอร์${r.skipped_no_product.length ? ` · ข้าม ${r.skipped_no_product.length} (ไม่มีสินค้าของร้าน)` : ''}`);
      m.close(); done && done();
    });
    m.el.querySelectorAll('[data-add]').forEach((b) => b.addEventListener('click', () => add(b, [b.dataset.add])));
    on(m.el.querySelector('#all'), (ev) => add(ev.currentTarget, list.map((x) => x.id)));
  };

  R.def('import', { title: 'นำเข้าข้อมูล', back: 'more' }, async function (el) {
    const banks = B().accounts.filter((a) => a.kind !== 'cash' && !a.is_drawer && a.active !== false);
    const chans = B().channels.filter((c) => c.kind === 'delivery' && c.active !== false);
    const prods = B().products.filter((p) => p.active !== false);
    let kind = R.store.get('import.kind') === 'delivery' ? 'delivery' : 'bank', rows = null, fileName = '', aliases = {}, pv = null;
    el.innerHTML = `<form class="form" id="f" onsubmit="return false">
      <div class="field"><span>นำเข้าอะไร</span>${R.seg('ikind', Object.entries(IMP_KIND), kind)}</div>
      <div class="field" id="tg"></div>
      <div class="card flat"><b>1. ดาวน์โหลดเทมเพลต</b>
        <p class="muted small" id="tdesc"></p>
        <button type="button" class="btn" id="tpl">${R.icon('download')} ดาวน์โหลดเทมเพลต</button><span class="muted small">ไฟล์ .csv เปิดและกรอกใน Excel หรือ Google Sheets ได้</span></div>
      <div class="card flat"><b>2. อัปโหลดไฟล์ที่กรอกแล้ว</b>
        <p class="muted small">รับไฟล์ .xlsx หรือ .csv · ใช้ไฟล์ที่ส่งออกจากแอปธนาคาร/แพลตฟอร์มได้ ถ้าหัวคอลัมน์ตรงกับเทมเพลต · วันที่ใช้ได้ทั้ง 2026-10-21, 21/10/2026 และปี พ.ศ.</p>
        <label class="btn primary" style="position:relative;overflow:hidden">${R.icon('plus')} เลือกไฟล์<input type="file" id="file" accept=".csv,.xlsx,.xls,text/csv" style="position:absolute;inset:0;opacity:0"></label>
        <span class="muted small" id="fname"></span></div></form>
      <div id="pv"></div>
      ${R.sec('ประวัติการนำเข้า')}<div id="hist"></div>
      <p class="muted small" style="padding:0 4px">ยกเลิกรอบนำเข้าได้ ระบบไม่ลบข้อมูลจริง · การเชื่อมต่อกับแพลตฟอร์มโดยตรง (API) จะมาในเฟสถัดไป</p>`;
    const f = el.querySelector('#f'), out = el.querySelector('#pv');
    const target = () => R.segVal(f, 'itg');
    const drawTarget = () => {
      const list = kind === 'bank' ? banks : chans;
      f.querySelector('#tg').innerHTML = list.length ? `<span>${kind === 'bank' ? 'เข้าบัญชี' : 'แพลตฟอร์ม'}</span>${R.seg('itg', list.map((x) => [x.id, x.name]), list[0].id, 'wrap')}`
        : `<div class="note">${kind === 'bank' ? 'ยังไม่มีบัญชีธนาคาร เพิ่มที่ ข้อมูลหลัก › บัญชีเงิน' : 'ยังไม่มีช่องทาง Delivery เพิ่มที่ ข้อมูลหลัก › ช่องทางขาย'}</div>`;
      f.querySelector('#tdesc').innerHTML = kind === 'bank'
        ? 'คอลัมน์: วันที่*, เวลา, ยอดเงิน*, เลขอ้างอิง, รายละเอียด · ไม่ใส่เวลา = ยอดรวมทั้งวัน · ใส่เวลา = ทีละรายการ · รายการซ้ำ (เลขอ้างอิงเดิม หรือวัน เวลา ยอดเดิม) ระบบข้ามให้'
        : 'คอลัมน์: เลขออเดอร์*, วันที่*, เวลา, ชื่อสินค้า*, จำนวน*, ยอดขายก่อนหัก*, ส่วนลดที่ร้านออก, ค่าคอม, VAT ค่าคอม, ค่าธรรมเนียมอื่น, สถานะ · 1 แถว = 1 สินค้า ออเดอร์เดียวกันใช้เลขเดียวกัน · ค่าคอมใส่แถวแรกของออเดอร์ก็พอ';
    };
    const payload = (extra) => ({ kind, rows, file_name: fileName, aliases, [kind === 'bank' ? 'account_id' : 'channel_id']: target(), ...(extra || {}) });

    function drawBank(v) {
      const okN = v.ok, rowsErr = v.rows.filter((x) => x.error);
      out.innerHTML = `${R.sec('ตรวจไฟล์ ' + esc(fileName))}
        <div class="card"><div class="chips" style="flex-wrap:wrap"><span class="pill ok">พร้อมบันทึก ${okN}</span>${v.dups ? `<span class="pill">ซ้ำ ข้าม ${v.dups}</span>` : ''}${v.errors ? `<span class="pill bad">อ่านไม่ได้ ${v.errors}</span>` : ''}</div>
          ${rowsErr.length ? `<ul class="small" style="margin:8px 0 0;padding-left:18px">${rowsErr.slice(0, 10).map((x) => `<li>แถว ${x.n + 1}: ${esc(x.error)}</li>`).join('')}</ul>` : ''}</div>
        ${R.sec('เทียบรายวัน: ทีมลง QR/โอน กับยอดในไฟล์')}
        ${R.table([{ l: 'วันที่', f: (d) => R.date(d.date) }, { l: 'ทีมลงในระบบ', num: true, f: (d) => money(d.system) }, { l: 'ในไฟล์', num: true, main: true, f: (d) => money(d.file) },
          { l: 'ต่าง', num: true, f: (d) => { const df = Number(d.file) - Number(d.system); return Math.abs(df) > 0.009 ? `<span class="pill warn">${signed(df)}</span>` : '<span class="pill ok">ตรง</span>'; } },
          { l: 'นำเข้าไว้ก่อนแล้ว', num: true, f: (d) => (Number(d.already) ? money(d.already) : '-') }], v.days, { empty: 'ไม่มีแถวที่อ่านได้' })}
        <p class="muted small" style="padding:0 4px">ยอดต่าง = ทีมอาจลงช่องทางผิด (เงินสด/QR) หรือลืมลง ตรวจได้ที่ รายการขาย · บันทึกแล้วไปจับคู่กับรายการในระบบต่อที่ บัญชีเงิน / ภาษี</p>
        ${okN ? `<button class="btn primary lg" id="commit" style="width:100%;margin:8px 0">บันทึก ${okN} รายการเข้าบัญชี</button>` : ''}`;
    }
    function drawDelivery(v) {
      const c = v.counts || {}, unm = v.unmapped || [];
      const items = (o) => o.items.map((i) => `${esc(i.name)} ×${qty(i.qty)}${i.product_id ? '' : unm.includes(i.name) ? ' <span class="pill warn">?</span>' : ' <span class="muted">(ข้าม)</span>'}`).join(', ');
      const ready = (v.orders || []).filter((o) => o.kind !== 'dup').length;
      out.innerHTML = `${R.sec('ตรวจไฟล์ ' + esc(fileName))}
        ${unm.length ? `<div class="card"><b>จับคู่ชื่อสินค้า ${unm.length} ชื่อ</b><p class="muted small">ชื่อในไฟล์ไม่ตรงกับสินค้าในระบบ เลือกครั้งเดียว ครั้งหน้าระบบจำให้</p>
          <div class="form" style="gap:8px">${unm.map((n, i) => `<label class="field"><span>${esc(n)}</span><select data-al="${i}"><option value="">— เลือกสินค้า —</option>${R.opts(prods, aliases[n])}<option value="skip" ${aliases[n] === 'skip' ? 'selected' : ''}>ไม่ใช่สินค้าของร้าน (ข้าม)</option></select></label>`).join('')}</div>
          <button class="btn primary" id="remap" style="margin-top:10px">ตรวจอีกครั้ง</button></div>` : ''}
        <div class="card"><div class="chips" style="flex-wrap:wrap">${Object.entries(MATCH).filter(([k]) => c[k]).map(([k, [tone, l]]) => `<span class="pill ${tone}">${l} ${c[k]}</span>`).join('')}
          ${v.staff_only.length ? `<span class="pill warn">ทีมลงแต่ไม่มีในไฟล์ ${v.staff_only.length}</span>` : ''}${v.errors.length ? `<span class="pill bad">อ่านไม่ได้ ${v.errors.length} แถว</span>` : ''}</div>
          ${v.errors.length ? `<ul class="small" style="margin:8px 0 0;padding-left:18px">${v.errors.slice(0, 10).map((x) => `<li>แถว ${x.n + 1}: ${esc(x.error)}</li>`).join('')}</ul>` : ''}</div>
        ${R.sec('รายวัน: ทีมลง กับ ไฟล์แพลตฟอร์ม')}
        ${R.table([{ l: 'วันที่', f: (d) => R.date(d.date) }, { l: 'ออเดอร์ ทีม / ไฟล์', num: true, f: (d) => `${d.system_orders} / ${d.file_orders}` },
          { l: 'ทีมลง', num: true, f: (d) => money(d.system_gross) }, { l: 'ในไฟล์', num: true, main: true, f: (d) => money(d.file_gross) },
          { l: 'ต่าง', num: true, f: (d) => { const df = Number(d.file_gross) - Number(d.system_gross); return Math.abs(df) > 0.009 ? `<span class="pill warn">${signed(df)}</span>` : '<span class="pill ok">ตรง</span>'; } }], v.days, { empty: 'ไม่มีออเดอร์ที่อ่านได้' })}
        ${R.sec('ออเดอร์ในไฟล์ (' + v.orders.length + ')')}
        ${R.table([{ l: 'เลขออเดอร์', f: (o) => `#${esc(o.ext)}<br><span class="muted small">${R.date(o.date)} ${o.time || ''}</span>` }, { l: 'รายการ', f: items },
          { l: 'ยอดลูกค้าจ่าย', num: true, main: true, f: (o) => money(o.net) }, { l: 'หักแพลตฟอร์ม', num: true, f: (o) => money(Number(o.commission) + Number(o.vat) + Number(o.other)) },
          { l: 'ในระบบ', f: (o) => (o.order_no ? `${esc(o.order_no)} · ${money(o.order_total)}` : '-') },
          { l: 'ผล', f: (o) => `<span class="pill ${MATCH[o.kind][0]}">${MATCH[o.kind][1]}</span>` }], v.orders, { empty: 'ไม่มีออเดอร์' })}
        ${v.staff_only.length ? `${R.sec('ทีมลงแต่ไม่มีในไฟล์ (' + v.staff_only.length + ')')}
          ${R.list(v.staff_only.map((s) => R.row({ href: '#/orders', icon: 'receipt', tone: 'warn', t: esc(s.order_no), s: `${R.date(s.date)} ${s.time} น.${s.note ? ' · ' + esc(s.note) : ''}`, v: money(s.total) })))}
          <p class="muted small" style="padding:0 4px">อาจลงช่องทางผิดหรือลงซ้ำ ตรวจแล้วยกเลิกเองได้ที่ออเดอร์นั้น ระบบไม่ยกเลิกให้อัตโนมัติ</p>` : ''}
        ${ready ? `<button class="btn primary lg" id="commit" style="width:100%;margin:8px 0" ${unm.length ? 'disabled' : ''}>${unm.length ? 'จับคู่ชื่อสินค้าให้ครบก่อน' : `บันทึก ${ready} ออเดอร์จากไฟล์`}</button>` : ''}
        <p class="muted small" style="padding:0 4px">บันทึกแล้ว ค่าคอมและค่าธรรมเนียมจริงใช้คำนวณกำไรแทนค่าประมาณ และเติมให้ตอนบันทึกเงินเข้า Delivery ออเดอร์ที่ไม่มีในระบบกดเพิ่มเข้ายอดขายได้ในขั้นถัดไป</p>`;
      out.querySelectorAll('[data-al]').forEach((s) => s.addEventListener('change', () => { const n = unm[Number(s.dataset.al)]; if (s.value) aliases[n] = s.value; else delete aliases[n]; }));
      on(out.querySelector('#remap'), (ev) => R.busy(ev.currentTarget, check));
    }
    async function check() {
      if (!rows) return;
      if (!target()) throw new Error(kind === 'bank' ? 'กรุณาเลือกบัญชีที่รับเงิน' : 'กรุณาเลือกแพลตฟอร์ม');
      pv = await R.api('import.preview', payload());
      (kind === 'bank' ? drawBank : drawDelivery)(pv);
      on(out.querySelector('#commit'), (ev) => R.busy(ev.currentTarget, async () => {
        const r = await R.api('import.commit', payload());
        rows = null; aliases = {}; f.querySelector('#file').value = ''; f.querySelector('#fname').textContent = '';
        out.innerHTML = `<div class="banner ok"><span class="dot"></span><span>บันทึกแล้ว ${r.added} ${kind === 'bank' ? 'รายการ' : 'ออเดอร์'} จาก ${esc(fileName)}</span></div>`;
        R.toast('นำเข้าเรียบร้อย');
        await hist();
        if (kind === 'delivery' && (r.counts || {}).missing) R.importMissingSheet({ id: r.import_id }, () => hist().catch(R.fail));
      }));
    }
    async function hist() {
      const list = await R.api('import.list', {}), box = el.querySelector('#hist');
      box.innerHTML = R.list(list.map((b) => R.row({ data: { im: b.id }, off: b.status === 'cancelled', icon: b.kind === 'bank' ? 'receipt' : 'flow', tone: b.missing ? 'warn' : '',
        t: `${IMP_KIND[b.kind]} · ${esc(b.target || '')}`, s: `${R.date(b.created_at)} ${R.time(b.created_at)} น. · ${esc(b.by || '')} · ${esc(b.file_name || '')}${b.status === 'cancelled' ? ' · ยกเลิกแล้ว' : b.missing ? ` · ไม่มีในระบบ ${b.missing} ออเดอร์` : ''}`,
        v: b.rows_added + (b.kind === 'bank' ? ' รายการ' : ' ออเดอร์'), vs: b.rows_skipped ? 'ข้าม ' + b.rows_skipped : '' })), 'ยังไม่เคยนำเข้า');
      box.querySelectorAll('[data-im]').forEach((r) => r.addEventListener('click', () => {
        const b = list.find((x) => x.id === r.dataset.im);
        const m = R.modal(IMP_KIND[b.kind], `${R.mlist([['', [R.mrow(b.kind === 'bank' ? 'บัญชี' : 'แพลตฟอร์ม', esc(b.target || '')), R.mrow('ไฟล์', esc(b.file_name || '-')),
            R.mrow('นำเข้าเมื่อ', `${R.date(b.created_at)} ${R.time(b.created_at)} น.`, { sub: esc(b.by || '') }), R.mrow('บันทึก', String(b.rows_added), { sub: b.rows_skipped ? 'ข้าม ' + b.rows_skipped + ' (ซ้ำหรืออ่านไม่ได้)' : '' }),
            ...(b.status === 'cancelled' ? [R.mrow('ยกเลิกแล้ว', '', { sub: esc(b.cancel_reason || '') })] : [])]]])}
          <div class="btn-row" style="margin-top:12px">${b.status === 'done' && R.can('cashflow.manage') ? '<button class="btn danger" id="cx">ยกเลิกรอบนี้</button>' : ''}
            ${b.missing && b.status === 'done' && R.can('cashflow.manage') ? `<button class="btn primary" id="miss">เพิ่ม ${b.missing} ออเดอร์เข้ายอดขาย</button>` : ''}</div>`);
        on(m.el.querySelector('#miss'), () => { m.close(); R.importMissingSheet(b, () => hist().catch(R.fail)).catch(R.fail); });
        on(m.el.querySelector('#cx'), async () => {
          m.close();
          const x = await R.askReason('ยกเลิกรอบนำเข้า', { text: 'รายการจากไฟล์นี้จะไม่ถูกนับ ระบบไม่ลบข้อมูลจริง · ออเดอร์ที่เพิ่มเข้ายอดขายไปแล้วยังอยู่ ยกเลิกได้ที่ออเดอร์นั้น', danger: true, ok: 'ยกเลิกรอบนี้' });
          if (!x) return;
          try { await R.api('import.cancel', { import_id: b.id, reason: x.reason }); R.toast('ยกเลิกรอบนำเข้าแล้ว'); await hist(); } catch (e) { R.fail(e); }
        });
      }));
    }
    drawTarget();
    f.querySelector('[name=ikind]').closest('.seg').addEventListener('change', () => {
      kind = R.segVal(f, 'ikind'); R.store.set('import.kind', kind); drawTarget(); rows = null; pv = null; aliases = {}; out.innerHTML = '';
      f.querySelector('#file').value = ''; f.querySelector('#fname').textContent = '';
    });
    f.querySelector('#tg').addEventListener('change', () => { if (rows) check().catch(R.fail); });
    on(f.querySelector('#tpl'), () => R.downloadCsv(TEMPLATES[kind].file, TEMPLATES[kind].rows));
    f.querySelector('#file').addEventListener('change', async (ev) => {
      const file = ev.target.files[0]; if (!file) return;
      fileName = file.name; f.querySelector('#fname').textContent = file.name; aliases = {};
      out.innerHTML = '<div class="empty">กำลังอ่านไฟล์…</div>';
      try {
        const m = R.mapRows(await R.readSheet(file), kind);
        if (!m.rows.length) { rows = null; out.innerHTML = `<div class="note">${m.missing.length ? 'ไม่พบหัวคอลัมน์ที่ต้องมี ใช้หัวคอลัมน์ตามเทมเพลต (เช่น ' + esc(TEMPLATES[kind].rows[0] ? Object.keys(TEMPLATES[kind].rows[0]).filter((k) => k.includes('*')).join(', ') : '') + ')' : 'ไฟล์ไม่มีข้อมูล'}</div>`; return; }
        rows = m.rows; await check();
      } catch (e) { out.innerHTML = ''; R.fail(e); }
    });
    await hist();
  });
})();
