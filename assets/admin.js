/* RSA - POS Assistant — master data, users & permissions, audit log, shop settings (mobile app layout) */
(function () {
  'use strict';
  const R = window.RSA, esc = R.esc, money = R.money, baht = R.baht;
  const B = () => R.state.boot;
  const on = (node, fn) => node && node.addEventListener('click', fn);

  // Field schema per master entity: [key, label, type, options]
  const ENT = {
    products: { t: 'สินค้า', icon: 'cart', fields: [
      ['name', 'ชื่อสินค้า', 'text', { req: true }], ['price', 'ราคาหน้าร้าน (บาท)', 'number', { req: true }], ['category', 'หมวดสินค้า', 'category'], ['unit', 'หน่วยขาย', 'unit'],
      ['delivery_enabled', 'ขายทาง Delivery', 'bool'], ['delivery_price', 'ราคา Delivery (เว้นว่าง = ใช้ราคาหน้าร้าน)', 'number'], ['markdown_price', 'ราคาลดตอนเย็น หน้าร้าน (เว้นว่าง = ไม่ลด)', 'number'], ['emoji', 'ไอคอน (emoji) เช่น 🍉', 'text'],
      ['sku', 'SKU / รหัส', 'text'], ['main_stock_item_id', 'วัตถุดิบหลัก (ไว้ดูอ้างอิง ยังไม่ตัดสต็อก)', 'stockitem'],
      ['est_cost', 'ต้นทุนโดยประมาณต่อหน่วย (ใช้เมื่อยังไม่มีสูตร)', 'number'], ['sort_order', 'ลำดับที่แสดงในหน้าขาย', 'number']],
      row: (r) => ({ t: (r.emoji ? esc(r.emoji) + ' ' : '') + esc(r.name), s: `${esc(r.category || 'ไม่มีหมวด')} · ${r.delivery_enabled === false ? 'ไม่ขาย Delivery' : r.delivery_price != null ? 'Delivery ' + money(r.delivery_price) : 'Delivery ราคาเดียวกัน'} · ${r.recipe.length ? 'มีสูตร ' + r.recipe.length + ' รายการ' : 'ยังไม่มีสูตร'}`, v: baht(r.price) }) },
    stock_items: { t: 'วัตถุดิบ / สต็อก', icon: 'box', fields: [
      ['name', 'ชื่อรายการ', 'text', { req: true }], ['unit', 'หน่วยหลักของสต็อก (เช่น กิโลกรัม)', 'unit', { req: true }],
      ['count_units', 'หน่วยนับอื่นที่พนักงานใช้ได้', 'countunits'],
      ['kind', 'ประเภท', 'seg', { o: [['raw', 'วัตถุดิบ'], ['packaging', 'บรรจุภัณฑ์'], ['goods', 'สินค้าสำเร็จรูป']] }],
      ['min_qty', 'เตือนเมื่อเหลือต่ำกว่า', 'number'], ['reorder_qty', 'จำนวนที่แนะนำให้สั่ง', 'number'], ['code', 'รหัส', 'text'], ['default_supplier_id', 'ซัพพลายเออร์หลัก', 'supplier']],
      row: (r) => ({ t: esc((r.code ? r.code + ' · ' : '') + r.name), s: `${esc(r.unit)}${(r.count_units || []).length ? ' · นับเป็น ' + r.count_units.map((c) => esc(c.unit) + '≈' + R.qty(c.factor)).join(', ') : ''} · เตือนเมื่อต่ำกว่า ${R.qty(r.min_qty)}`, v: r.avg_cost ? 'ทุน ' + money(r.avg_cost) : '' }) },
    promotions: { t: 'โปรโมชัน', icon: 'tag', fields: [
      ['name', 'ชื่อโปรโมชัน', 'text', { req: true }], ['rule', 'วิธีคิด', 'seg', { o: [['bundle', 'ซื้อเป็นชุด (N ชิ้น ราคา P)'], ['percent', 'ลดเป็น %'], ['amount_each', 'ลดบาทต่อชิ้น']] }],
      ['buy_qty', 'ชุดละกี่ชิ้น (โปรชุด) เช่น 3', 'number'], ['bundle_price', 'ราคาต่อชุด (โปรชุด) เช่น 100', 'number'],
      ['value', 'ลดเท่าไร (% หรือ บาท) สำหรับโปรลดราคา', 'number'], ['min_qty', 'ซื้อขั้นต่ำต่อรายการ', 'number'],
      ['scope', 'ใช้กับ', 'seg', { o: [['products', 'สินค้าที่เลือก'], ['all', 'ทุกสินค้า']] }], ['product_ids', 'สินค้าที่ร่วมโปร (โปรชุดนับรวมกันได้)', 'products'],
      ['storefront_only', 'ใช้เฉพาะหน้าร้าน', 'bool'], ['channel_ids', 'ช่องทาง (ไม่เลือก = ทุกช่องทาง)', 'channels'], ['starts_at', 'เริ่ม', 'datetime'], ['ends_at', 'สิ้นสุด', 'datetime']],
      row: (r) => ({ t: esc(r.name), s: `${r.rule === 'bundle' ? `ชุดละ ${R.qty(r.buy_qty)} ชิ้น ${money(r.bundle_price)} บาท` : r.rule === 'percent' ? 'ลด ' + r.value + '%' : 'ลด ' + money(r.value) + ' บาท/ชิ้น'}${r.storefront_only ? ' · เฉพาะหน้าร้าน' : ''} · ${(r.product_ids || []).length || 'ทุก'} สินค้า`, v: '' }) },
    channels: { t: 'ช่องทางขาย', icon: 'flow', fields: [
      ['name', 'ชื่อช่องทาง', 'text', { req: true }], ['kind', 'ประเภท', 'seg', { o: [['storefront', 'หน้าร้าน'], ['delivery', 'Delivery']] }],
      ['payment_method', 'การรับเงิน', 'seg', { o: [['cash', 'เงินสด'], ['qr', 'QR'], ['transfer', 'โอน'], ['card', 'บัตร'], ['platform', 'แพลตฟอร์มโอนให้']] }],
      ['account_id', 'เงินเข้าบัญชี (หน้าร้าน)', 'account'], ['fee_pct', 'ค่าธรรมเนียม %', 'number'], ['fee_confirmed', 'ยืนยันค่าธรรมเนียมแล้ว', 'bool'],
      ['settlement_days', 'แพลตฟอร์มโอนเงินภายใน (วัน)', 'number'], ['sort_order', 'ลำดับแสดง', 'number']],
      row: (r) => ({ t: esc(r.name), s: r.kind === 'delivery' ? `ค่าธรรมเนียม ${r.fee_pct}%${r.fee_confirmed ? '' : ' (ยังไม่ยืนยัน)'} · โอนภายใน ${r.settlement_days} วัน` : 'หน้าร้าน', v: '' }) },
    payment_accounts: { t: 'บัญชีเงิน', icon: 'wallet', fields: [
      ['name', 'ชื่อบัญชี', 'text', { req: true }], ['kind', 'ประเภท', 'seg', { o: [['cash', 'เงินสด'], ['bank', 'ธนาคาร'], ['ewallet', 'e-Wallet']] }],
      ['is_drawer', 'เป็นลิ้นชักเงินสดหน้าร้าน (มีได้ 1 บัญชี)', 'bool'], ['opening_balance', 'ยอดยกมา ณ วันเริ่มใช้ระบบ', 'number'], ['opening_confirmed', 'ยืนยันยอดยกมาแล้ว', 'bool'],
      ['bank_detail', 'เลขบัญชี / QR (เห็นเฉพาะเจ้าของร้าน)', 'text']],
      row: (r) => ({ t: esc(r.name), s: `ยอดยกมา ${money(r.opening_balance)}${r.opening_confirmed ? '' : ' · ยังไม่ยืนยัน'}${r.is_drawer ? ' · ลิ้นชักหน้าร้าน' : ''}`, v: '' }) },
    suppliers: { t: 'ซัพพลายเออร์', icon: 'users', fields: [
      ['name', 'ชื่อร้าน / ซัพพลายเออร์', 'text', { req: true }], ['contact_name', 'ผู้ติดต่อ', 'text'], ['phone', 'โทรศัพท์', 'text'], ['line_id', 'LINE', 'text'],
      ['supplies', 'ส่งอะไรให้ร้าน', 'text'], ['order_days', 'วันที่สั่งของ', 'text'], ['lead_time', 'ส่งของภายใน', 'text'], ['delivery_schedule', 'รอบส่งของ', 'text'],
      ['min_order', 'สั่งขั้นต่ำ', 'text'], ['delivery_fee', 'ค่าส่ง', 'text'], ['payment_method', 'วิธีจ่ายเงิน', 'text'], ['credit_terms', 'เครดิต', 'text'],
      ['bank_detail', 'บัญชี / QR สำหรับโอน', 'text'], ['can_issue_receipt', 'ออกใบเสร็จได้', 'bool'], ['can_issue_tax_invoice', 'ออกใบกำกับภาษีได้', 'bool'],
      ['return_terms', 'เงื่อนไขคืนของ / ของขาด / เสียหาย', 'text'], ['priority', 'สถานะ', 'seg', { o: [['primary', 'ร้านหลัก'], ['backup', 'ร้านสำรอง']] }], ['note', 'หมายเหตุ', 'text']],
      row: (r) => ({ t: esc(r.name), s: [r.supplies, r.phone, r.priority === 'backup' ? 'ร้านสำรอง' : ''].filter(Boolean).map(esc).join(' · ') || 'ยังไม่มีรายละเอียด', v: '' }) },
    expense_categories: { t: 'หมวดค่าใช้จ่าย', icon: 'receipt', fields: [
      ['name', 'ชื่อหมวด', 'text', { req: true }], ['tax_category', 'หมวดทางภาษี / บัญชี', 'text'], ['staff_allowed', 'พนักงานบันทึกได้', 'bool']],
      row: (r) => ({ t: esc(r.name), s: `${esc(r.tax_category || '-')}${r.staff_allowed ? ' · พนักงานบันทึกได้' : ' · เฉพาะเจ้าของร้าน'}`, v: '' }) },
    units: { t: 'หน่วย', icon: 'list', fields: [['name', 'ชื่อหน่วย', 'text', { req: true }]], row: (r) => ({ t: esc(r.name), v: '' }) },
  };

  R.def('master', { title: 'ข้อมูลหลัก', back: 'more' }, async function (el, arg) {
    let ent = ENT[arg] ? arg : 'products';
    const lookups = {};
    async function draw() {
      const [rows, si, pr, ac, su, cats] = await Promise.all([R.api('master.list', { entity: ent }), R.api('master.list', { entity: 'stock_items' }), R.api('master.list', { entity: 'products' }),
        R.api('master.list', { entity: 'payment_accounts' }), R.api('master.list', { entity: 'suppliers' }), R.api('category.list', {})]);
      Object.assign(lookups, { stock_items: si, products: pr, accounts: ac, suppliers: su, categories: cats });
      const E = ENT[ent];
      el.innerHTML = `<div class="chips">${Object.entries(ENT).map(([k, v]) => `<button class="chip" data-e="${k}" aria-pressed="${k === ent}">${v.t}</button>`).join('')}</div>
        ${R.list(rows.map((r) => { const x = E.row(r); return R.row({ data: { ed: r.id }, icon: E.icon, off: !r.active, t: x.t, s: x.s, v: x.v || null, pill: r.active ? '' : '<span class="pill">ปิดใช้งาน</span>' }); }), 'ยังไม่มี' + E.t)}
        <p class="muted small" style="padding:0 4px">ข้อมูลที่เคยใช้แล้วลบไม่ได้ ใช้ "ปิดใช้งาน" แทน การแก้ราคาหรือสูตรมีผลกับรายการใหม่ ออเดอร์เดิมเก็บราคาและต้นทุน ณ วันที่ขาย</p>
        ${R.actionbar(`${ent === 'products' ? '<button class="btn" id="cats">จัดการหมวด</button>' : ''}<button class="btn primary" id="add">+ เพิ่ม${esc(E.t)}</button>`)}`;
      el.querySelectorAll('[data-e]').forEach((b) => b.addEventListener('click', () => { ent = b.dataset.e; history.replaceState(null, '', '#/master/' + ent); draw().catch(R.fail); }));
      on(document.getElementById('add'), () => form());
      on(document.getElementById('cats'), () => catSheet());
      el.querySelectorAll('[data-ed]').forEach((b) => b.addEventListener('click', () => form(rows.find((r) => r.id === b.dataset.ed))));
    }
    async function afterSave() { await R.loadBoot(); await draw(); }
    function input(f, r) {
      const [k, label, type] = f; const o = f[3] || {}; const v = r ? r[k] : undefined;
      const lab = `<span>${esc(label)}</span>`;
      if (type === 'bool') return `<label class="check"><input type="checkbox" data-k="${k}" data-t="bool" ${v ? 'checked' : ''}><span>${esc(label)}</span></label>`;
      if (type === 'seg') return `<div class="field">${lab}<div data-segk="${k}">${R.seg('f-' + k, o.o, v != null ? v : o.o[0][0], 'wrap')}</div></div>`;
      if (type === 'unit') return `<label class="field">${lab}<input type="text" data-k="${k}" list="units-dl" value="${esc(v ?? '')}" ${o.req ? 'required' : ''}><datalist id="units-dl">${B().units.map((u) => `<option value="${esc(u)}">`).join('')}</datalist></label>`;
      if (type === 'account') return `<label class="field">${lab}<select data-k="${k}"><option value="">—</option>${R.opts(lookups.accounts.filter((a) => a.active), v)}</select></label>`;
      if (type === 'category') {
        const cats = lookups.categories || [];
        return `<div class="field">${lab}<input type="text" data-k="${k}" list="cat-dl" value="${esc(v ?? '')}" placeholder="พิมพ์เพื่อค้นหา หรือพิมพ์ชื่อหมวดใหม่" autocomplete="off">
          <datalist id="cat-dl">${cats.map((c) => `<option value="${esc(c.name)}">`).join('')}</datalist>
          ${cats.length ? `<div class="chips" style="flex-wrap:wrap">${cats.map((c) => `<button type="button" class="chip" data-pickcat="${esc(c.name)}" aria-pressed="${c.name === v}">${esc(c.name)}</button>`).join('')}</div>` : ''}</div>`;
      }
      if (type === 'countunits') {
        const rows = (v || []).concat([{ unit: '', factor: '' }, { unit: '', factor: '' }]).slice(0, Math.max(2, (v || []).length + 1));
        return `<div class="field">${lab}<p class="muted small">ใส่ค่าเฉลี่ยของหน่วยที่นับง่าย เช่น 1 ลูก ≈ 3.5 (กิโลกรัม) วิธีหา: ชั่ง 3–5 ลูกแล้วหารเฉลี่ย · หน่วยที่ขาย (กล่อง / ไม้) ระบบดึงจากสูตรสินค้าให้เอง ไม่ต้องใส่ตรงนี้</p>
          <div class="cu-rows">${rows.map((x) => `<div class="two"><input type="text" data-cuu placeholder="หน่วย เช่น ลูก" value="${esc(x.unit || '')}" list="units-dl2"><input type="number" step="any" min="0" inputmode="decimal" data-cuf placeholder="= กี่หน่วยหลัก" value="${esc(x.factor ?? '')}"></div>`).join('')}</div>
          <datalist id="units-dl2">${B().units.map((u) => `<option value="${esc(u)}">`).join('')}<option value="ลูก"><option value="ถุง"><option value="ลัง"><option value="แพ็ก"></datalist></div>`;
      }
      if (type === 'stockitem') return `<label class="field">${lab}<select data-k="${k}"><option value="">—</option>${R.opts(lookups.stock_items.filter((a) => a.active), v, (x) => (x.code ? x.code + ' · ' : '') + x.name)}</select></label>`;
      if (type === 'supplier') return `<label class="field">${lab}<select data-k="${k}"><option value="">—</option>${R.opts(lookups.suppliers.filter((a) => a.active), v)}</select></label>`;
      if (type === 'products' || type === 'channels') {
        const list = type === 'products' ? lookups.products.filter((p) => p.active) : B().channels;
        return `<div class="field">${lab}<div class="chips" style="flex-wrap:wrap">${list.map((x) => `<label class="chip" style="display:inline-flex;gap:6px;align-items:center"><input type="checkbox" data-arr="${k}" value="${x.id}" ${(v || []).includes(x.id) ? 'checked' : ''}>${esc(x.name)}</label>`).join('')}</div></div>`;
      }
      if (type === 'datetime') return `<label class="field">${lab}<input type="datetime-local" data-k="${k}" data-t="dt" value="${v ? new Date(new Date(v).getTime() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 16) : ''}"></label>`;
      return `<label class="field">${lab}<input type="${type === 'number' ? 'number' : 'text'}" ${type === 'number' ? 'step="any" inputmode="decimal" data-t="num"' : ''} data-k="${k}" value="${esc(v ?? '')}" ${o.req ? 'required' : ''}></label>`;
    }
    function form(r) {
      const E = ENT[ent], main = E.fields.slice(0, 4), more = E.fields.slice(4);
      const m = R.modal((r ? 'แก้ไข' : 'เพิ่ม') + E.t, `<form class="form">${main.map((f) => input(f, r)).join('')}
        ${more.length ? `<details ${r ? '' : ''}><summary>ข้อมูลเพิ่มเติม</summary><div class="form" style="margin-top:10px">${more.map((f) => input(f, r)).join('')}</div></details>` : ''}
        ${ent === 'products' && r ? `<button type="button" class="btn" id="recipe">${R.icon('box')} สูตร / การตัดสต็อก (${r.recipe.length ? r.recipe.length + ' รายการ' : 'ยังไม่มี'})</button>` : ''}
        ${ent === 'payment_accounts' && r ? '<p class="note small">แก้ยอดยกมามีผลกับยอดคงเหลือทุกวัน ระบบเก็บค่าก่อน-หลังไว้ในประวัติ</p>' : ''}
        <button class="btn primary lg">บันทึก</button>
        ${r ? `<button type="button" class="btn ${r.active ? 'danger' : ''}" id="toggle">${r.active ? 'ปิดใช้งาน' : 'เปิดใช้งานอีกครั้ง'}</button>` : ''}</form>`);
      on(m.el.querySelector('#recipe'), () => { m.close(); recipe(r); });
      m.el.querySelectorAll('[data-pickcat]').forEach((b) => b.addEventListener('click', () => {
        m.el.querySelector('[data-k="category"]').value = b.dataset.pickcat;
        m.el.querySelectorAll('[data-pickcat]').forEach((x) => x.setAttribute('aria-pressed', x === b)); }));
      on(m.el.querySelector('#toggle'), (ev) => R.busy(ev.currentTarget, async () => { await R.api('master.save', { entity: ent, data: { id: r.id, active: !r.active } }); m.close(); await afterSave(); }));
      m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
        const data = r ? { id: r.id } : {};
        m.el.querySelectorAll('[data-k]').forEach((i) => {
          const k = i.dataset.k, t = i.dataset.t;
          data[k] = t === 'bool' ? i.checked : t === 'num' ? (i.value === '' ? null : Number(i.value)) : t === 'dt' ? (i.value ? new Date(i.value).toISOString() : null) : (i.value === '' ? null : i.value.trim());
        });
        m.el.querySelectorAll('[data-segk]').forEach((s) => { data[s.dataset.segk] = R.segVal(s, 'f-' + s.dataset.segk); });
        if (m.el.querySelector('[data-cuu]')) data.count_units = [...m.el.querySelectorAll('.cu-rows .two')].map((r) => ({ unit: r.querySelector('[data-cuu]').value.trim(), factor: Number(r.querySelector('[data-cuf]').value) }))
          .filter((x) => x.unit && x.factor > 0);
        E.fields.filter((f) => f[2] === 'products' || f[2] === 'channels').forEach((f) => { data[f[0]] = [...m.el.querySelectorAll(`[data-arr="${f[0]}"]:checked`)].map((i) => i.value); });
        if (data.price === null) delete data.price;
        if (ent === 'promotions') { if (data.value == null) data.value = 0; if (data.rule === 'bundle' && !(data.buy_qty > 0 && data.bundle_price != null)) throw new Error('โปรชุดต้องใส่จำนวนชิ้นต่อชุดและราคาต่อชุด'); }
        if (ent === 'products' && !data.unit) data.unit = 'ชิ้น';
        await R.api('master.save', { entity: ent, data }); m.close(); R.toast('บันทึกแล้ว'); await afterSave();
      }); });
    }
    // categories: rename (all products follow), order (used for the tabs on the sell screen), add an empty one
    function catSheet() {
      const list = (lookups.categories || []).map((c) => ({ old: c.name, name: c.name, n: c.products }));
      const m = R.modal('หมวดสินค้า', '<div id="cs" class="form"></div>');
      const draw2 = () => {
        m.el.querySelector('#cs').innerHTML = `<p class="muted small">แก้ชื่อหมวดแล้วสินค้าในหมวดเปลี่ยนตามทั้งหมด · ลำดับนี้ใช้กับแถบหมวดในหน้าบันทึกขาย</p>
          ${list.map((c, i) => `<div class="row static" style="gap:8px"><input type="text" data-cn="${i}" value="${esc(c.name)}" aria-label="ชื่อหมวด"><span class="muted small" style="white-space:nowrap">${c.n} สินค้า</span>
            <button type="button" class="icon-btn" data-up="${i}" aria-label="เลื่อนขึ้น" ${i ? '' : 'disabled'}>▲</button><button type="button" class="icon-btn" data-down="${i}" aria-label="เลื่อนลง" ${i < list.length - 1 ? '' : 'disabled'}>▼</button></div>`).join('')}
          <div class="two"><input type="text" id="newc" placeholder="ชื่อหมวดใหม่"><button type="button" class="btn" id="addc">+ เพิ่มหมวด</button></div>
          <button type="button" class="btn primary lg" id="savec">บันทึกหมวด</button>`;
        m.el.querySelectorAll('[data-cn]').forEach((i) => i.addEventListener('input', () => { list[i.dataset.cn].name = i.value; }));
        m.el.querySelectorAll('[data-up],[data-down]').forEach((b) => b.addEventListener('click', () => {
          const i = Number(b.dataset.up ?? b.dataset.down), j = b.dataset.up != null ? i - 1 : i + 1; [list[i], list[j]] = [list[j], list[i]]; draw2(); }));
        on(m.el.querySelector('#addc'), () => { const n = R.val(m.el, '#newc'); if (n && !list.some((c) => c.name === n)) { list.push({ old: '', name: n, n: 0 }); draw2(); } });
        on(m.el.querySelector('#savec'), (ev) => R.busy(ev.currentTarget, async () => {
          if (list.some((c) => !c.name.trim())) throw new Error('ชื่อหมวดว่างไม่ได้');
          for (const c of list) if (c.old && c.old !== c.name.trim()) await R.api('category.rename', { old: c.old, new: c.name.trim() });
          await R.api('settings.save', { key: 'product_categories', value: list.map((c) => c.name.trim()), confirmed: true });
          m.close(); R.toast('บันทึกหมวดแล้ว'); await afterSave();
        }));
      };
      draw2();
    }
    function recipe(p) {
      const items = lookups.stock_items.filter((s) => s.active);
      const lines = p.recipe.map((l) => ({ stock_item_id: l.stock_item_id, qty: l.qty }));
      const m = R.modal('สูตร: ' + p.name, '<div id="rc" class="form"></div>');
      const draw2 = () => {
        let cost = 0, missing = false;
        lines.forEach((l) => { const s = items.find((x) => x.id === l.stock_item_id); if (s) { cost += l.qty * s.avg_cost; if (!Number(s.avg_cost)) missing = true; } });
        m.el.querySelector('#rc').innerHTML = `<p class="muted small">ขาย ${esc(p.name)} 1 ${esc(p.unit)} ใช้อะไรเท่าไร ระบบตัดสต็อกและคิดต้นทุนเฉพาะสินค้าที่มีสูตร ไม่รู้ก็เว้นไว้ก่อนได้</p>
          ${R.list(lines.map((l, i) => { const s = items.find((x) => x.id === l.stock_item_id) || {}; return R.row({ data: { del: i }, icon: 'box', t: esc(s.name || '?'), s: `${R.qty(l.qty)} ${esc(s.unit || '')} ต่อ 1 ${esc(p.unit)} · แตะเพื่อลบ`, v: s.avg_cost ? money(l.qty * s.avg_cost) : '-', chev: false }); }), 'ยังไม่มีวัตถุดิบในสูตร')}
          <div class="card flat"><div class="two"><label class="field"><span>วัตถุดิบ</span><select id="s"><option value="">เลือก…</option>${R.opts(items, null, (x) => x.name + ' (' + x.unit + ')')}</select></label>
            <label class="field"><span>ใช้เท่าไร</span><input type="number" id="q" step="any" min="0" inputmode="decimal"></label></div><button type="button" class="btn" id="addl">+ เพิ่มในสูตร</button></div>
          <div class="sum-row"><span>ต้นทุนโดยประมาณ${missing ? ' (บางรายการยังไม่มีต้นทุน)' : ''}</span><b>${baht(cost)}</b></div><div class="sum-row"><span>ราคาขาย</span><b>${baht(p.price)}</b></div>
          <button type="button" class="btn primary lg" id="saver">บันทึกสูตร</button>`;
        m.el.querySelectorAll('[data-del]').forEach((b) => b.addEventListener('click', () => { lines.splice(b.dataset.del, 1); draw2(); }));
        on(m.el.querySelector('#addl'), () => { const s = R.val(m.el, '#s'), q = Number(R.val(m.el, '#q')); if (!s || !(q > 0)) return R.fail(new Error('เลือกวัตถุดิบและใส่จำนวน'));
          const ex = lines.find((l) => l.stock_item_id === s); if (ex) ex.qty = q; else lines.push({ stock_item_id: s, qty: q }); draw2(); });
        on(m.el.querySelector('#saver'), (ev) => R.busy(ev.currentTarget, async () => { await R.api('recipe.save', { product_id: p.id, lines }); m.close(); R.toast('บันทึกสูตรแล้ว'); await afterSave(); }));
      };
      draw2();
    }
    await draw();
  });

  // ------------------------------------------------------------ users & permissions
  R.def('users', { title: 'ผู้ใช้ สิทธิ์ และ PIN', back: 'more' }, async function (el) {
    const list = await R.api('user.list', {});
    el.innerHTML = `${R.list(list.map((u) => R.row({ data: { u: u.id }, avatar: u.display_name, off: !u.active, t: esc(u.display_name), s: `${esc(R.ROLE_LABEL[u.role])} · ${esc(u.username)}`,
        pill: !u.active ? '<span class="pill">ปิดใช้งาน</span>' : u.locked ? '<span class="pill warn">ล็อกชั่วคราว</span>' : '' })))}
      <p class="muted small" style="padding:0 4px">PIN เก็บแบบเข้ารหัส ไม่มีใครดู PIN จริงได้ ลืมให้ตั้งใหม่</p>
      ${R.actionbar('<button class="btn primary" id="add">+ เพิ่มผู้ใช้</button>')}`;
    const permBoxes = (perms) => R.PERMS.map(([g, ps]) => `${R.sec(g)}<div class="list">${ps.map(([k, l]) => `<label class="row"><span class="body"><span class="t" style="font-weight:500">${esc(l)}</span></span><input type="checkbox" data-perm="${k}" ${perms.includes(k) ? 'checked' : ''} style="width:24px;height:24px;accent-color:var(--accent)"></label>`).join('')}</div>`).join('');
    const form = (u) => {
      const role = u ? u.role : 'staff';
      const m = R.modal(u ? u.display_name : 'เพิ่มผู้ใช้', `<form class="form">
        <label class="field"><span>ชื่อที่แสดง</span><input type="text" id="dn" value="${esc(u ? u.display_name : '')}" required></label>
        ${u ? '' : `<label class="field"><span>ชื่อผู้ใช้ (a-z 0-9)</span><input type="text" id="un" pattern="[a-z0-9._\\-]{2,32}" autocapitalize="none" required></label>
          <label class="field"><span>PIN 6 หลัก</span><input type="password" id="pin" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="new-password" required></label>`}
        <div class="field"><span>บทบาท</span>${R.seg('role', [['staff', 'พนักงาน'], ['owner', 'เจ้าของร้าน'], ['admin', 'ผู้ดูแลระบบ']], role)}</div>
        ${u ? `<label class="check"><input type="checkbox" id="act" ${u.active ? 'checked' : ''}> ใช้งาน</label>` : ''}
        <details><summary>ปรับสิทธิ์ทีละข้อ</summary><div style="margin-top:8px">${permBoxes(u ? u.perms : R.ROLE_PERMS[role])}</div></details>
        <button class="btn primary lg">บันทึก</button>
        ${u ? '<button type="button" class="btn" id="pinbtn">ตั้ง PIN ใหม่</button>' : ''}</form>`);
      const setPerms = (ps) => m.el.querySelectorAll('[data-perm]').forEach((c) => { c.checked = ps.includes(c.dataset.perm); });
      m.el.querySelector('.seg').addEventListener('change', () => setPerms(R.ROLE_PERMS[R.segVal(m.el, 'role')]));
      on(m.el.querySelector('#pinbtn'), () => { m.close(); pinSheet(u); });
      m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => {
        const perms = [...m.el.querySelectorAll('[data-perm]:checked')].map((c) => c.dataset.perm);
        await R.api('user.save', { id: u ? u.id : null, display_name: R.val(m.el, '#dn'), username: u ? undefined : R.val(m.el, '#un').toLowerCase(), pin: u ? undefined : R.val(m.el, '#pin'),
          role: R.segVal(m.el, 'role'), perms, active: u ? R.val(m.el, '#act') : true });
        m.close(); R.toast('บันทึกแล้ว'); R.route();
      }); });
    };
    const pinSheet = (u) => {
      const m = R.modal('ตั้ง PIN ใหม่ให้ ' + u.display_name, `<form class="form"><label class="field"><span>PIN ใหม่ 6 หลัก</span><input type="password" id="pin" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="new-password" required></label>
        <p class="muted small">แจ้ง PIN กับเจ้าตัวโดยตรง อย่าจดในกลุ่มแชต ผู้ใช้จะถูกออกจากระบบทุกเครื่อง</p><button class="btn primary lg">บันทึก PIN</button></form>`);
      m.el.querySelector('form').addEventListener('submit', (ev) => { ev.preventDefault(); R.busy(ev.submitter, async () => { await R.api('user.reset_pin', { id: u.id, pin: R.val(m.el, '#pin') }); m.close(); R.toast('ตั้ง PIN ใหม่แล้ว'); }); });
    };
    on(document.getElementById('add'), () => form());
    el.querySelectorAll('[data-u]').forEach((b) => b.addEventListener('click', () => form(list.find((u) => u.id === b.dataset.u))));
  });

  // ------------------------------------------------------------ audit
  const ACT = { login: 'เข้าสู่ระบบ', 'login.failed': 'ใส่ PIN ผิด', 'order.create': 'บันทึกออเดอร์', 'order.cancel': 'ยกเลิกออเดอร์', 'order.refund': 'คืนเงิน', 'receipt.create': 'รับของเข้า',
    'receipt.cancel': 'ยกเลิกใบรับของ', 'waste.create': 'บันทึกของเสีย', 'waste.cancel': 'ยกเลิกของเสีย', 'expense.create': 'บันทึกค่าใช้จ่าย', 'expense.approve': 'อนุมัติค่าใช้จ่าย', 'expense.pay': 'จ่ายเงิน',
    'expense.cancel': 'ยกเลิกค่าใช้จ่าย', 'close.submit': 'ส่งรายงานปิดยอด', 'close.revise': 'แก้รายงานปิดยอด', 'close.review': 'ตรวจรายงานปิดยอด', 'stocktake.create': 'นับสต็อก', 'stocktake.approve': 'อนุมัติผลนับ',
    'stocktake.reject': 'ไม่อนุมัติผลนับ', 'master.create': 'เพิ่มข้อมูลหลัก', 'master.update': 'แก้ข้อมูลหลัก', 'recipe.save': 'แก้สูตร', 'settings.save': 'ตั้งค่าร้าน', 'user.create': 'เพิ่มผู้ใช้',
    'user.update': 'แก้ผู้ใช้', 'user.permissions': 'แก้สิทธิ์', 'user.reset_pin': 'ตั้ง PIN ใหม่', export: 'ส่งออกข้อมูล', 'settlement.create': 'รับเงิน Delivery', 'transfer.create': 'โอนเงิน',
    'capital.create': 'บันทึกทุน/เงินกู้', 'profit.declare': 'ประกาศใช้กำไร', 'ledger.reconcile': 'ตรวจกับ statement', 'fixed.generate': 'สร้างค่าใช้จ่ายประจำ', 'attachment.upload': 'แนบไฟล์' };
  R.def('audit', { title: 'ประวัติการใช้งาน', back: 'more' }, async function (el) {
    const st = { days: 7, action: '' };
    async function draw() {
      const rows = await R.api('audit.list', { from: R.addDays(R.today(), -st.days), action: st.action });
      el.innerHTML = `${R.seg('days', [[1, 'วันนี้'], [7, '7 วัน'], [30, '30 วัน']], st.days)}
        <div class="chips">${[['', 'ทั้งหมด'], ['order', 'ขาย'], ['expense', 'ค่าใช้จ่าย'], ['close', 'ปิดยอด'], ['stock', 'สต็อก'], ['master', 'ข้อมูลหลัก'], ['user', 'ผู้ใช้'], ['login', 'เข้าระบบ'], ['export', 'ส่งออก']]
          .map(([k, l]) => `<button class="chip" data-a="${k}" aria-pressed="${k === st.action}">${l}</button>`).join('')}</div>
        ${R.list(rows.map((a, i) => R.row({ data: { i }, avatar: a.user_name || '?', t: esc(ACT[a.action] || a.action), s: `${esc(a.user_name || '')} · ${R.dt(a.at)}`, chev: !!(a.before || a.after || a.meta) })), 'ไม่มีรายการ')}`;
      el.querySelector('.seg').addEventListener('change', () => { st.days = Number(R.segVal(el, 'days')); draw().catch(R.fail); });
      el.querySelectorAll('[data-a]').forEach((b) => b.addEventListener('click', () => { st.action = b.dataset.a; draw().catch(R.fail); }));
      el.querySelectorAll('[data-i]').forEach((b) => b.addEventListener('click', () => {
        const a = rows[b.dataset.i]; if (!(a.before || a.after || a.meta)) return;
        R.modal(ACT[a.action] || a.action, `<p class="muted small">${esc(a.user_name || '')} · ${R.dt(a.at)} · ${esc(a.entity || '')}</p>
          ${a.before ? `<div class="field"><span>ก่อน</span><pre style="white-space:pre-wrap;font-size:.8rem;margin:0">${esc(JSON.stringify(a.before, null, 1))}</pre></div>` : ''}
          ${a.after ? `<div class="field"><span>หลัง</span><pre style="white-space:pre-wrap;font-size:.8rem;margin:0">${esc(JSON.stringify(a.after, null, 1))}</pre></div>` : ''}
          ${a.meta ? `<div class="field"><span>รายละเอียด</span><pre style="white-space:pre-wrap;font-size:.8rem;margin:0">${esc(JSON.stringify(a.meta, null, 1))}</pre></div>` : ''}`);
      }));
    }
    await draw();
  });

  // ------------------------------------------------------------ settings center: every value shows whether the owner confirmed it
  const SET = [
    ['ร้านและภาษี', [['shop_name', 'ชื่อร้าน', 'text'], ['vat_registered', 'ร้านจดทะเบียน VAT', 'bool'], ['tax_id', 'เลขประจำตัวผู้เสียภาษี', 'text']]],
    ['เวลาปิดร้านและการเตือน', [['close_time', 'เวลาปิดร้าน', 'time'], ['reminder_times', 'เวลาเตือนพนักงาน (คั่นด้วย ,)', 'times'], ['close_due_time', 'ส่งรายงานภายในเวลานี้ = ตรงเวลา', 'time']]],
    ['เงินสดและเงินหมุน', [['starting_float', 'เงินทอนที่เก็บไว้ในลิ้นชักต้นวัน (บาท)', 'num'], ['cash_variance_tolerance', 'เงินขาด/เกินได้ไม่เกิน (บาท) โดยไม่ต้องอธิบาย', 'num'],
      ['min_working_capital', 'เงินหมุนขั้นต่ำที่ต้องกันไว้ก่อนถอน/จ่ายกำไร (บาท)', 'num'], ['opening_debt', 'หนี้ตั้งต้น (บาท)', 'num']]],
    ['ค่าขนส่งและรอบตลาด', [['transport_default', 'ค่าขนส่งต่อรอบ (บาท)', 'num'], ['transport_method', 'เฉลี่ยค่าขนส่งเข้าต้นทุน', 'alloc'],
      ['market_trip_km', 'ระยะทางไปตลาด (กม.)', 'num'], ['market_trips_per_week', 'รอบตลาดต่อสัปดาห์', 'num']]],
    ['วันหยุดร้านและราคาลดตอนเย็น', [['closed_weekdays', 'วันหยุดประจำสัปดาห์ (ไม่ต้องปิดยอด ไม่เตือน ไม่นับในค่าเฉลี่ยต่อวัน)', 'weekdays'],
      ['closed_dates', 'วันหยุดพิเศษ เช่น ปีใหม่ สงกรานต์', 'dates'], ['markdown_from', 'เวลาเริ่มใช้ราคาลดตอนเย็น (เว้นว่าง = ไม่ใช้ · ตั้งราคาลดที่ ข้อมูลหลัก › สินค้า)', 'time']]],
    ['เป้าหมาย', [['profit_target', 'เป้ากำไรต่อเดือน (บาท)', 'num']]],
    ['หลักฐาน', [['evidence_required', 'บังคับแนบหลักฐานทุกครั้งที่บันทึกค่าใช้จ่าย / รับสินค้า', 'bool'], ['waste_evidence_required', 'บังคับแนบรูปทุกครั้งที่บันทึกของเสีย', 'bool'],
      ['waste_reasons', 'สาเหตุของเสียที่ให้เลือก (คั่นด้วย ,)', 'list']]],
  ];
  R.def('settings', { title: 'ตั้งค่า', back: 'more' }, async function (el) {
    await R.loadBoot();
    const s = B().settings;
    const v = (k) => (s[k] ? s[k].value : null);
    const ck = R.can('report.view') ? await R.api('setup.checklist', {}) : [];
    const LINK = { setting: null, account: '#/master/payment_accounts', channel: '#/master/channels', fixed: '#/expenses', investment: '#/invest', recipe: '#/master/products', stock_cost: '#/stock' };
    const inp = ([k, , t]) => {
      const x = v(k);
      if (t === 'bool') return `<input type="checkbox" data-s="${k}" data-t="bool" ${x ? 'checked' : ''} style="width:24px;height:24px">`;
      if (t === 'time') return `<input type="time" data-s="${k}" data-t="text" value="${esc(x || '')}" style="max-width:140px">`;
      if (t === 'num') return `<input type="number" step="0.01" min="0" inputmode="decimal" data-s="${k}" data-t="num" value="${x ?? 0}" style="max-width:160px;text-align:right">`;
      if (t === 'alloc') return `<select data-s="${k}" data-t="text" style="max-width:180px">${Object.entries(R.ALLOC).map(([a, l]) => `<option value="${a}" ${a === x ? 'selected' : ''}>${l}</option>`).join('')}</select>`;
      if (t === 'weekdays') return `<span class="chips wd" data-s="${k}" data-t="weekdays">${R.WEEKDAYS.map((d, i) => `<button type="button" class="chip" data-wd="${i}" aria-pressed="${(x || []).includes(i)}">${d}</button>`).join('')}</span>`;
      if (t === 'dates') return `<span class="dates" data-s="${k}" data-t="dates" data-v="${esc(JSON.stringify(x || []))}"></span>`;
      if (t === 'times' || t === 'list') return `<input type="text" data-s="${k}" data-t="${t}" value="${esc((x || []).join(', '))}">`;
      return `<input type="text" data-s="${k}" data-t="text" value="${esc(x || '')}">`;
    };
    el.innerHTML = `${R.sectTabs ? R.sectTabs('settings') : ''}
      ${ck.length ? `${R.sec('รายการที่ควรตั้งค่าให้ครบ (' + ck.length + ')')}${R.list(ck.slice(0, 40).map((c) => R.row({ href: LINK[c.kind] || '#/settings', icon: 'shield', tone: 'warn', t: esc(c.text), chev: !!LINK[c.kind] })))}
        <p class="muted small" style="padding:0 4px">ตัวเลขที่ยังไม่ยืนยันจะถูกติดป้ายในรายงาน และไม่ถือเป็นข้อมูลจริง</p>` : '<div class="banner ok"><span class="dot"></span><span>ตั้งค่าครบแล้ว</span></div>'}
      <form class="form" id="f" onsubmit="return false">${SET.map(([g, items]) => `${R.sec(g)}<div class="card">${items.map((it) => `<div class="money-line"><span><span class="t">${esc(it[1])}</span>
          <span class="s">${s[it[0]] && s[it[0]].confirmed ? '<span class="pill ok">ยืนยันแล้ว</span>' : '<span class="pill warn">ยังไม่ยืนยัน</span>'}</span></span>${inp(it)}</div>`).join('')}</div>`).join('')}
        ${R.sec('ข้อมูลหลักที่เกี่ยวข้อง')}${R.list([R.row({ href: '#/master/payment_accounts', icon: 'wallet', t: 'ยอดยกมาของบัญชีเงิน' }), R.row({ href: '#/master/channels', icon: 'flow', t: 'ช่องทางขายและค่าธรรมเนียม Delivery' }),
          R.row({ href: '#/master/products', icon: 'tag', t: 'สินค้า ราคา สูตร' }), R.row({ href: '#/master/promotions', icon: 'tag', t: 'โปรโมชัน' }), R.row({ href: '#/expenses', icon: 'calendar', t: 'ค่าใช้จ่ายประจำ (ค่าเช่า ฯลฯ)' }), R.row({ href: '#/invest', icon: 'chart', t: 'เงินลงทุน' })])}
      </form>${R.actionbar('<button class="btn primary" id="save">บันทึกและยืนยันทั้งหมด</button>')}`;
    const f = el.querySelector('#f');
    f.querySelectorAll('.wd [data-wd]').forEach((b) => b.addEventListener('click', () => b.setAttribute('aria-pressed', b.getAttribute('aria-pressed') !== 'true')));
    // one-off holidays: chips with ×, plus a date input to add
    f.querySelectorAll('.dates').forEach((box) => {
      const draw = () => { const v = JSON.parse(box.dataset.v);
        box.innerHTML = `${v.map((d) => `<button type="button" class="chip" data-rm="${d}" aria-label="ลบ ${d}">${R.date(d)} ✕</button>`).join('')}
          <span class="two" style="gap:6px"><input type="date" class="nd"><button type="button" class="btn small add">+ เพิ่ม</button></span>`;
        box.querySelectorAll('[data-rm]').forEach((b) => b.addEventListener('click', () => { box.dataset.v = JSON.stringify(v.filter((d) => d !== b.dataset.rm)); draw(); }));
        box.querySelector('.add').addEventListener('click', () => { const d = box.querySelector('.nd').value; if (d && !v.includes(d)) { box.dataset.v = JSON.stringify([...v, d].sort()); draw(); } });
      };
      draw();
    });
    document.getElementById('save').addEventListener('click', (ev) => R.busy(ev.currentTarget, async () => {
      const inputs = [...f.querySelectorAll('[data-s]')];
      for (const i of inputs) {
        const t = i.dataset.t, k = i.dataset.s;
        const value = t === 'weekdays' ? [...i.querySelectorAll('[data-wd][aria-pressed="true"]')].map((b) => Number(b.dataset.wd))
          : t === 'dates' ? JSON.parse(i.dataset.v) : t === 'bool' ? i.checked : t === 'num' ? Number(i.value) || 0 : (t === 'times' || t === 'list') ? i.value.split(',').map((x) => x.trim()).filter(Boolean) : i.value.trim();
        const cur = s[k];
        if (cur && cur.confirmed && JSON.stringify(cur.value) === JSON.stringify(value)) continue;
        await R.api('settings.save', { key: k, value, confirmed: true });
      }
      await R.loadBoot(); R.toast('บันทึกและยืนยันการตั้งค่าแล้ว'); R.route();
    }));
  });
})();
