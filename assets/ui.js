/* RSA - POS Assistant — shared detail widgets: period filter, comparisons, charts, table/cards, evidence, receipt reader, reminders */
(function () {
  'use strict';
  const R = window.RSA, esc = R.esc, money = R.money;

  // ------------------------------------------------------------ labels shared by several screens
  R.FUND = {
    shop_cash: 'เงินสดของร้าน (ลิ้นชัก)', shop_bank: 'บัญชีร้าน / QR ร้าน', other_account: 'บัญชีอื่นของร้าน',
    owner_advance: 'เจ้าของสำรองจ่าย (ต้องคืน)', employee_advance: 'พนักงานสำรองจ่าย (ต้องคืน)',
    owner_capital: 'เงินเจ้าของ (ไม่ต้องคืน)', credit: 'เครดิต / ยังไม่จ่าย',
  };
  R.FUND_HELP = {
    shop_cash: 'เงินออกจากลิ้นชักวันนี้ ระบบหักให้ตอนปิดยอด', shop_bank: 'โอน / สแกนจ่ายจากบัญชีร้าน ต้องใส่เลขอ้างอิงและแนบสลิป',
    other_account: 'เลือกบัญชีที่จ่าย ต้องใส่เลขอ้างอิง', owner_advance: 'เจ้าของใช้เงินตัวเองจ่ายก่อน ร้านต้องคืนภายหลัง',
    employee_advance: 'ใช้เงินตัวเองจ่ายไปก่อน ขอเบิกคืนจากร้าน', owner_capital: 'เจ้าของจ่ายให้ร้าน ไม่ขอคืน นับเป็นเงินลงทุนเพิ่ม',
    credit: 'ค้างจ่าย รอบิล หรือให้เจ้าของร้านจ่ายภายหลัง',
  };
  R.PURPOSE = { owner_draw: 'จ่ายเจ้าของ', capital_return: 'คืนทุน', loan_repayment: 'โปะเงินกู้ลงทุน', keep_working_capital: 'เก็บเป็นเงินหมุน', reinvest: 'ลงทุนกลับร้าน' };
  R.settingVal = (k, d) => { const s = R.state.boot && R.state.boot.settings[k]; return s && s.value != null ? s.value : d; };
  // shop holidays (weekly closed days 0 = Sunday, one-off closed dates YYYY-MM-DD)
  R.WEEKDAYS = ['อา', 'จ', 'อ', 'พ', 'พฤ', 'ศ', 'ส'];
  R.isHoliday = (d) => (R.settingVal('closed_weekdays', []) || []).includes(new Date(d + 'T12:00:00Z').getUTCDay()) || (R.settingVal('closed_dates', []) || []).includes(d);
  R.settingOk = (k) => { const s = R.state.boot && R.state.boot.settings[k]; return !!(s && s.confirmed); };
  R.unconfirmed = (txt) => `<span class="pill warn" title="ยังไม่ยืนยัน">${esc(txt || 'ยังไม่ยืนยัน')}</span>`;

  // ------------------------------------------------------------ period filter (owner pages)
  const PRESETS = [['today', 'วันนี้'], ['7d', '7 วัน'], ['week', 'สัปดาห์นี้'], ['month', 'เดือนนี้'], ['30d', '30 วัน'], ['custom', 'กำหนดเอง']];
  R.period = () => R.store.json('period', { p: '7d', cmp: true });
  R.periodRange = (pp) => {
    const p = pp || R.period(), t = R.today();
    const dow = (new Date(t + 'T12:00:00').getDay() + 6) % 7;
    switch (p.p) {
      case 'today': return { from: t, to: t };
      case 'week': return { from: R.addDays(t, -dow), to: t };
      case 'month': return { from: t.slice(0, 8) + '01', to: t };
      case '30d': return { from: R.addDays(t, -29), to: t };
      case 'custom': return { from: p.from || R.addDays(t, -6), to: p.to || t };
      default: return { from: R.addDays(t, -6), to: t };
    }
  };
  R.periodLabel = () => { const p = R.period(), r = R.periodRange(p); return (PRESETS.find((x) => x[0] === p.p) || PRESETS[1])[1] + ' · ' + (r.from === r.to ? R.date(r.from) : R.date(r.from) + ' – ' + R.date(r.to)); };
  // one small button instead of a row of chips: tap to pick the period and turn the comparison on/off
  const PLABEL = () => { const p = R.period(); return (PRESETS.find((x) => x[0] === p.p) || PRESETS[1])[1]; };
  R.periodBar = (opts) => {
    const p = R.period(), r = R.periodRange(p), cmpOk = !(opts && opts.compare === false);
    return `<div class="period-row" id="period" data-cmp="${cmpOk ? 1 : 0}"><button type="button" class="period-pill" id="pp-open">${esc(PLABEL())} ▾</button>
      <span class="muted small">${r.from === r.to ? R.date(r.from) : R.date(r.from) + ' – ' + R.date(r.to)}${cmpOk && p.cmp ? ' · เทียบช่วงก่อน' : ''}</span></div>`;
  };
  R.bindPeriod = (root, cb) => {
    const btn = root.querySelector('#pp-open'); if (!btn) return;
    const cmpOk = root.querySelector('#period').dataset.cmp === '1';
    const save = (np) => { R.store.set('period', JSON.stringify(np)); cb(); };
    btn.addEventListener('click', () => {
      const p = R.period(), r = R.periodRange(p);
      const m = R.modal('ช่วงเวลา', `<div class="form">
        <div class="chips" style="flex-wrap:wrap">${PRESETS.map(([k, l]) => `<button type="button" class="chip" data-pp="${k}" aria-pressed="${p.p === k}">${l}</button>`).join('')}</div>
        <div class="two" id="pp-custom" ${p.p === 'custom' ? '' : 'hidden'}><label class="field"><span>ตั้งแต่</span><input type="date" id="pp-from" value="${r.from}"></label>
          <label class="field"><span>ถึง</span><input type="date" id="pp-to" value="${r.to}" max="${R.today()}"></label></div>
        ${cmpOk ? `<label class="check"><input type="checkbox" id="pp-cmp" ${p.cmp ? 'checked' : ''}> เทียบกับช่วงก่อนหน้า</label>` : ''}
        <button type="button" class="btn primary lg" id="pp-ok">ใช้ช่วงนี้</button></div>`);
      let pick = p.p;
      m.el.querySelectorAll('[data-pp]').forEach((b) => b.addEventListener('click', () => {
        pick = b.dataset.pp; m.el.querySelectorAll('[data-pp]').forEach((x) => x.setAttribute('aria-pressed', x === b));
        m.el.querySelector('#pp-custom').hidden = pick !== 'custom';
      }));
      m.el.querySelector('#pp-ok').addEventListener('click', () => {
        const c = m.el.querySelector('#pp-cmp'), np = { ...R.period(), p: pick, cmp: c ? c.checked : R.period().cmp };
        if (pick === 'custom') { np.from = m.el.querySelector('#pp-from').value || r.from; np.to = m.el.querySelector('#pp-to').value || r.to; }
        m.close(); save(np);
      });
    });
  };

  // "+12.5%" against the previous period; costs use invert so that going up shows as bad
  R.delta = (cur, prev, invert) => {
    if (!R.period().cmp || prev == null) return '';
    const c = Number(cur || 0), p = Number(prev || 0);
    if (!p) return '';   // nothing to compare with (the previous period had no data)
    const pct = Math.round(((c - p) / Math.abs(p)) * 1000) / 10;
    if (Math.abs(pct) < 1) return `<span class="delta">${pct > 0 ? '+' : pct < 0 ? '−' : ''}${Math.abs(pct)}%</span>`;
    const good = invert ? pct < 0 : pct > 0;
    return `<span class="delta ${good ? 'up' : 'down'}">${pct > 0 ? '▲' : '▼'} ${Math.abs(pct)}%</span>`;
  };
  // one quiet line of the key-number list: label left, value and change right
  R.mrow = (label, value, opts) => { opts = opts || {};
    const tag = opts.href ? 'a' : 'div';
    return `<${tag} class="mrow" ${opts.href ? `href="${opts.href}"` : ''}><span class="ml">${esc(label)}${opts.sub ? `<small>${opts.sub}</small>` : ''}</span>
      <span class="mv ${opts.tone || ''}">${value}${opts.delta || ''}</span></${tag}>`; };
  R.mlist = (groups) => `<div class="mlist">${groups.map(([g, rows]) => (g ? `<div class="mgroup">${esc(g)}</div>` : '') + rows.join('')).join('')}</div>`;
  // first items of a long list, the rest behind a button
  R.shortList = (rows, n, emptyText) => {
    if (!rows.length) return R.empty(emptyText || 'ไม่มีรายการ');
    return `<div class="list todo">${rows.slice(0, n).join('')}${rows.length > n ? `<div class="more-rows" hidden>${rows.slice(n).join('')}</div><button type="button" class="todo-more" onclick="this.previousElementSibling.hidden=false;this.remove()">ดูทั้งหมด ${rows.length} เรื่อง</button>` : ''}</div>`;
  };
  R.kpi = (label, value, deltaHtml, sub, tone) => `<div class="stat kpi ${tone || ''}"><span class="k">${esc(label)}</span><span class="v">${value}</span>
    <span class="s">${deltaHtml || ''}${sub ? ` <span>${sub}</span>` : ''}</span></div>`;

  // ------------------------------------------------------------ charts (inline SVG, no library)
  const SERIES = ['#1c68cf', '#0f8a6a', '#c26a12', '#7a4fc2', '#c23d6b', '#2f7f9e'];
  R.SERIES = SERIES;
  R.lineChart = (points, keys, opts) => {
    opts = opts || {};
    if (!points.length) return R.empty('ยังไม่มีข้อมูลในช่วงนี้');
    const W = 640, H = 220, L = 52, Rt = 30, T = 14, Bt = 30;
    const max = Math.max(1, ...points.flatMap((p) => keys.map((k) => Number(p[k.key] || 0))));
    const nice = (() => { const e = Math.pow(10, Math.floor(Math.log10(max))); return Math.ceil(max / e) * e; })();
    const x = (i) => L + (points.length === 1 ? (W - L - Rt) / 2 : (i * (W - L - Rt)) / (points.length - 1));
    const y = (v) => T + (H - T - Bt) * (1 - v / nice);
    const grid = [0, 0.5, 1].map((f) => `<line x1="${L}" x2="${W - Rt}" y1="${y(nice * f)}" y2="${y(nice * f)}" class="g"/><text x="${L - 6}" y="${y(nice * f) + 4}" text-anchor="end">${Math.round(nice * f).toLocaleString('th-TH')}</text>`).join('');
    const step = Math.max(1, Math.ceil(points.length / 7));
    const xl = points.map((p, i) => (i % step === 0 || i === points.length - 1) ? `<text x="${x(i)}" y="${H - 8}" text-anchor="middle">${esc(opts.xfmt ? opts.xfmt(p) : p.label)}</text>` : '').join('');
    const lines = keys.map((k, ki) => {
      const pts = points.map((p, i) => `${x(i).toFixed(1)},${y(Number(p[k.key] || 0)).toFixed(1)}`).join(' ');
      const dots = points.length <= 31 ? points.map((p, i) => `<circle cx="${x(i)}" cy="${y(Number(p[k.key] || 0))}" r="3" fill="${k.color || SERIES[ki]}"><title>${esc(opts.xfmt ? opts.xfmt(p) : p.label)} · ${esc(k.label)} ${money(p[k.key])}</title></circle>`).join('') : '';
      return `<polyline points="${pts}" fill="none" stroke="${k.color || SERIES[ki]}" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>${dots}`;
    }).join('');
    return `<figure class="chart"><svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(opts.title || 'กราฟ')}">${grid}${xl}${lines}</svg>
      <figcaption class="legend">${keys.map((k, ki) => `<span><i style="background:${k.color || SERIES[ki]}"></i>${esc(k.label)}</span>`).join('')}</figcaption></figure>`;
  };
  R.donut = (items, opts) => {
    opts = opts || {};
    const total = items.reduce((s, i) => s + Math.max(0, Number(i.value || 0)), 0);
    if (!total) return R.empty('ยังไม่มีข้อมูลในช่วงนี้');
    const r = 52, C = 2 * Math.PI * r; let off = 0;
    const segs = items.map((it, i) => {
      const v = Math.max(0, Number(it.value || 0)), len = (v / total) * C;
      const s = `<circle r="${r}" cx="70" cy="70" fill="none" stroke="${it.color || SERIES[i % SERIES.length]}" stroke-width="22" stroke-dasharray="${len} ${C - len}" stroke-dashoffset="${-off}"><title>${esc(it.label)} ${money(v)}</title></circle>`;
      off += len; return s;
    }).join('');
    return `<figure class="donut"><svg viewBox="0 0 140 140" role="img" aria-label="${esc(opts.title || 'สัดส่วน')}"><g transform="rotate(-90 70 70)">${segs}</g>
        <text x="70" y="66" text-anchor="middle" class="dl">${esc(opts.center || 'รวม')}</text><text x="70" y="84" text-anchor="middle" class="dv">${Math.round(total).toLocaleString('th-TH')}</text></svg>
      <figcaption class="legend col">${items.map((it, i) => `<span><i style="background:${it.color || SERIES[i % SERIES.length]}"></i>${esc(it.label)} <b>${money(it.value)}</b> <small>${Math.round((Number(it.value || 0) / total) * 1000) / 10}%</small></span>`).join('')}</figcaption></figure>`;
  };
  R.hbars = (items) => {
    const max = Math.max(1, ...items.map((i) => Number(i.value || 0)));
    return items.length ? `<div class="hbars">${items.map((i) => `<div class="barline"><span class="lab">${i.label}</span><span class="track"><span class="fill" style="width:${Math.max(2, (Number(i.value || 0) / max) * 100)}%"></span></span><b class="num">${i.text != null ? i.text : money(i.value)}</b></div>`).join('')}</div>` : R.empty('ยังไม่มีข้อมูล');
  };
  R.meter = (pct, label) => `<div class="meter" role="meter" aria-valuenow="${Math.round(pct || 0)}" aria-valuemin="0" aria-valuemax="100" aria-label="${esc(label || '')}"><i style="width:${Math.min(100, Math.max(0, pct || 0))}%"></i></div>`;

  // ------------------------------------------------------------ table on a computer, cards on a phone (same markup)
  // cols: [{k, l, num, f(row) -> html}] ; opts: {click: 'data-key', key: 'id', empty}
  // Computer: a full table. Phone: one short row per item (name + main number, a grey line with the key numbers),
  // tap to show the rest. Column options: main (number on the right), pri 1 (in the grey line) / 2 (only after tap).
  R.table = (cols, rows, opts) => {
    opts = opts || {};
    if (!rows.length) return R.empty(opts.empty || 'ยังไม่มีรายการ');
    const cell = (c, r) => (c.f ? c.f(r) : esc(r[c.k]));
    const flat = (h) => String(h == null ? '' : h).replace(/<br\s*\/?>/g, ' · ');
    const blank = (h) => { const t = flat(h).replace(/<[^>]*>/g, '').trim(); return !t || t === '-'; };
    const lead = cols[0], main = cols.find((c) => c.main) || null;
    const rest = cols.slice(1).filter((c) => c !== main);
    let n1 = 0; const pri = rest.map((c) => (c.pri ? c.pri : !c.l ? 1 : n1++ < 2 ? 1 : 2));
    const attrs = (r) => (opts.click ? `data-${opts.click}="${esc(r[opts.key || 'id'])}" tabindex="0"` : '');
    const desk = `<table class="rt"><thead><tr>${cols.map((c) => `<th class="${c.num ? 'n' : ''}">${esc(c.l)}</th>`).join('')}</tr></thead>
      <tbody>${rows.map((r) => `<tr ${attrs(r)} class="${opts.click ? 'click' : ''}">${cols.map((c, i) => `<td class="${c.num ? 'n' : ''} ${i === 0 ? 'lead' : ''}">${cell(c, r)}</td>`).join('')}</tr>`).join('')}</tbody>
      ${opts.foot ? `<tfoot><tr>${cols.map((c, i) => `<td class="${c.num ? 'n' : ''}">${opts.foot[i] != null ? opts.foot[i] : ''}</td>`).join('')}</tr></tfoot>` : ''}</table>`;
    const phone = `<div class="rtm">${rows.map((r) => {
      const sub = rest.map((c, i) => (pri[i] === 1 && !blank(cell(c, r)) ? `<span>${c.l ? `<small>${esc(c.l)}</small> ` : ''}${flat(cell(c, r))}</span>` : '')).filter(Boolean).join('');
      const more = rest.map((c, i) => (pri[i] === 2 && !blank(cell(c, r)) ? `<div><small>${esc(c.l)}</small><span>${cell(c, r)}</span></div>` : '')).filter(Boolean).join('');
      return `<div class="rtm-row ${opts.click ? 'click' : more ? 'tog' : ''}" ${attrs(r)} ${!opts.click && more ? 'onclick="if(!event.target.closest(\'button,a\'))this.classList.toggle(\'open\')"' : ''}>
        <div class="rtm-top"><span class="rtm-name">${cell(lead, r)}</span>${main ? `<span class="rtm-main">${flat(cell(main, r))}</span>` : ''}</div>
        ${sub ? `<div class="rtm-sub">${sub}</div>` : ''}${more && !opts.click ? `<div class="rtm-more">${more}</div>` : ''}</div>`;
    }).join('')}${opts.foot ? `<div class="rtm-row rtm-foot"><div class="rtm-top"><span class="rtm-name">${opts.foot[0] || 'รวม'}</span>${main ? `<span class="rtm-main">${opts.foot[cols.indexOf(main)] || ''}</span>` : ''}</div></div>` : ''}</div>`;
    return `<div class="rt-wrap">${desk}${phone}</div>`;
  };
  R.bindRows = (root, attr, fn) => root.querySelectorAll(`[data-${attr}]`).forEach((tr) => {
    tr.addEventListener('click', () => fn(tr.dataset[attr.replace(/-([a-z])/g, (m, c) => c.toUpperCase())]));
    tr.addEventListener('keydown', (e) => { if (e.key === 'Enter') tr.click(); });
  });

  // ------------------------------------------------------------ evidence: take a photo or pick one, preview, "required" tag
  R.attachWidget = function (key, docKinds, label, opts) {
    opts = opts || {};
    const files = [];
    const kinds = docKinds || [['receipt', 'ใบเสร็จ'], ['tax_invoice', 'ใบกำกับภาษี'], ['bill', 'บิล/ใบส่งของ'], ['slip', 'สลิปโอน'], ['substitute', 'ใบรับรองแทนใบเสร็จ'], ['photo', 'รูปถ่าย']];
    return {
      files,
      html: `<div class="field evidence" id="aw-${key}"><span>${esc(label || 'รูปหลักฐาน')} <span class="pill ${opts.required ? 'bad' : ''}" id="aw-${key}-req">${opts.required ? 'จำเป็น' : 'ถ้ามี'}</span></span>
        ${kinds.length > 1 ? `<select id="aw-${key}-kind" aria-label="ชนิดหลักฐาน">${kinds.map((k) => `<option value="${k[0]}">${k[1]}</option>`).join('')}</select>` : `<input type="hidden" id="aw-${key}-kind" value="${kinds[0][0]}">`}
        <div class="ev-btns"><label class="photo-btn">${R.icon('camera')} ถ่ายรูป<input type="file" accept="image/*" capture="environment" hidden data-aw="${key}"></label>
          <label class="photo-btn">${R.icon('clip')} เลือกรูปจากเครื่อง<input type="file" accept="image/*,application/pdf" hidden data-aw="${key}"></label></div>
        <div class="ev-list" id="aw-${key}-list"></div>
        ${opts.noProof ? `<details class="ev-none" id="aw-${key}-none"><summary>ไม่มีบิล / สลิป</summary><label class="field"><span class="req">เหตุผลที่ไม่มีหลักฐาน</span><input type="text" id="aw-${key}-why" placeholder="เช่น ซื้อตลาดสด แม่ค้าไม่มีบิล"></label></details>` : ''}</div>`,
      bind(root, onAdd) {
        const list = root.querySelector(`#aw-${key}-list`);
        root.querySelectorAll(`input[data-aw="${key}"]`).forEach((input) => input.addEventListener('change', async () => {
          const f = input.files[0]; if (!f) return;
          const tile = document.createElement('div'); tile.className = 'ev'; tile.innerHTML = '<span class="muted small">กำลังอัปโหลด…</span>'; list.appendChild(tile);
          try {
            const up = await R.uploadFile(f, root.querySelector(`#aw-${key}-kind`).value);
            files.push(up);
            tile.innerHTML = (/^image\//.test(up.mime) ? `<img src="${up.dataUrl}" alt="">` : `<span class="pdf">PDF</span>`)
              + `<span class="small">${esc(up.filename)}</span><button type="button" class="x" aria-label="เอาออก">×</button>`;
            tile.querySelector('.x').addEventListener('click', () => { const i = files.indexOf(up); if (i >= 0) files.splice(i, 1); tile.remove(); });
            if (onAdd) onAdd(up, f);
          } catch (e) { tile.remove(); R.fail(e); }
          input.value = '';
        }));
      },
      setRequired(root, on) { const p = root.querySelector(`#aw-${key}-req`); if (p) { p.textContent = on ? 'จำเป็น' : 'ถ้ามี'; p.className = 'pill ' + (on ? 'bad' : ''); } opts.required = on; },
      required: () => !!opts.required,
      ids: () => files.map((f) => f.id),
      reason: (root) => { const i = root.querySelector(`#aw-${key}-why`); return i ? i.value.trim() : ''; },
      // required evidence: a file, or (when allowed) a reason why there is none
      check(root) { if (opts.required && !files.length && !this.reason(root)) throw new Error(opts.noProof ? 'แนบรูปบิล / สลิป หรือกด "ไม่มีบิล / สลิป" แล้วใส่เหตุผล' : 'ต้องแนบรูปหลักฐาน'); },
    };
  };

  // ------------------------------------------------------------ receipt / slip reader (suggestions only, the person confirms)
  const TH_MONTHS = [['มกราคม', 'ม.ค.'], ['กุมภาพันธ์', 'ก.พ.'], ['มีนาคม', 'มี.ค.'], ['เมษายน', 'เม.ย.'], ['พฤษภาคม', 'พ.ค.'], ['มิถุนายน', 'มิ.ย.'],
    ['กรกฎาคม', 'ก.ค.'], ['สิงหาคม', 'ส.ค.'], ['กันยายน', 'ก.ย.'], ['ตุลาคม', 'ต.ค.'], ['พฤศจิกายน', 'พ.ย.'], ['ธันวาคม', 'ธ.ค.']];
  const EN_MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
  R.parseReceipt = function (raw) {
    const text = String(raw || '').replace(/[๐-๙]/g, (c) => String(c.charCodeAt(0) - 0x0E50));
    const lines = text.split(/\n/).map((s) => s.trim()).filter(Boolean);
    const toNum = (s) => Number(String(s).replace(/[,\s]/g, ''));
    const fixYear = (y) => { y = Number(y); if (y < 100) y += y > 50 ? 2500 : 2000; if (y > 2400) y -= 543; return y; };
    const iso = (y, m, d) => (m >= 1 && m <= 12 && d >= 1 && d <= 31 ? `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}` : null);
    let amount = null;
    const keyLine = lines.filter((l) => /(รวมทั้งสิ้น|ยอดสุทธิ|ทั้งสิ้น|สุทธิ|จำนวนเงิน|จำนวน|รวม|total|amount|ยอด)/i.test(l));
    for (const l of keyLine.reverse()) { const m = l.match(/(\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+\.\d{2}|\d{2,})/g); if (m) { amount = toNum(m[m.length - 1]); break; } }
    if (amount == null) { const all = (text.match(/\d{1,3}(?:,\d{3})*\.\d{2}/g) || []).map(toNum); if (all.length) amount = Math.max(...all); }
    let date = null;
    const dm = text.match(/(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{2,4})/);
    if (dm) date = iso(fixYear(dm[3]), Number(dm[2]), Number(dm[1]));
    if (!date) {
      for (let i = 0; i < 12 && !date; i++) {
        const re = new RegExp('(\\d{1,2})\\s*(?:' + TH_MONTHS[i].map((s) => s.replace(/\./g, '\\.?')).join('|') + ')\\s*(\\d{2,4})');
        const m = text.match(re); if (m) date = iso(fixYear(m[2]), i + 1, Number(m[1]));
      }
    }
    if (!date) { const m = text.match(/(\d{1,2})\s*([A-Za-z]{3})[a-z]*\.?\s*(\d{2,4})/); if (m && EN_MONTHS.includes(m[2].toLowerCase())) date = iso(fixYear(m[3]), EN_MONTHS.indexOf(m[2].toLowerCase()) + 1, Number(m[1])); }
    const tm = text.match(/\b([01]?\d|2[0-3])[:.]([0-5]\d)(?::[0-5]\d)?\s*(?:น\.?)?/);
    const refm = text.match(/(?:เลขที่รายการ|รหัสอ้างอิง|เลขอ้างอิง|หมายเลขอ้างอิง|ref(?:erence)?\.?\s*(?:no\.?|number)?|transaction\s*(?:id|no\.?)|เลขที่)\s*[:#]?\s*([A-Za-z0-9\-]{6,})/i);
    const payee = (() => { for (let i = 0; i < lines.length; i++) { const m = lines[i].match(/^(?:ไปยัง|ถึง|ผู้รับ(?:เงิน)?|ชื่อผู้รับ|to)\s*[:\-]?\s*(.*)$/i); if (m) return (m[1] || lines[i + 1] || '').slice(0, 80); } return ''; })();
    const merchant = (lines.find((l) => /[ก-๙a-zA-Z]{3,}/.test(l) && !/(ใบเสร็จ|receipt|tax|ภาษี|วันที่|date|โอนเงินสำเร็จ|สำเร็จ)/i.test(l)) || '').slice(0, 80);
    return { merchant: payee || merchant, payee, amount, date, time: tm ? `${tm[1].padStart(2, '0')}:${tm[2]}` : null, ref: refm ? refm[1] : null };
  };
  // expense categories grouped A / B / C (sub-categories under their parent)
  R.GRP = { A: 'A ต้นทุนผันแปร', B: 'B ค่าใช้จ่ายคงที่', C: 'C ไม่ใช่ค่าใช้จ่าย' };
  R.catOptions = (cats, sel) => ['A', 'B', 'C'].map((g) => {
    const list = (cats || []).filter((c) => (c.grp || 'B') === g);
    if (!list.length) return '';
    const top = list.filter((c) => !c.parent_id || !list.some((x) => x.id === c.parent_id));
    const opt = (c, sub) => `<option value="${esc(c.id)}" ${String(c.id) === String(sel) ? 'selected' : ''}>${sub ? '· ' : ''}${esc(c.name)}</option>`;
    return `<optgroup label="${esc(R.GRP[g])}">${top.map((c) => opt(c) + list.filter((x) => x.parent_id === c.id).map((x) => opt(x, true)).join('')).join('')}</optgroup>`;
  }).join('');
  R.isNotCost = (c) => c && (c.grp === 'C') && c.c_kind !== 'advance';

  R.loadTesseract = async function () {
    if (window.Tesseract) return window.Tesseract;
    await new Promise((res, rej) => { const s = document.createElement('script'); s.src = 'https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js'; s.onload = res; s.onerror = () => rej(new Error('โหลดตัวอ่านรูปไม่สำเร็จ กรอกข้อมูลเองได้เลย')); document.head.appendChild(s); });
    return window.Tesseract;
  };

  // ------------------------------------------------------------ import files (.csv / .xlsx) → rows keyed by our column names
  R.loadXlsx = async function () {
    if (window.XLSX) return window.XLSX;
    await new Promise((res, rej) => { const s = document.createElement('script'); s.src = 'https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js'; s.onload = res; s.onerror = () => rej(new Error('โหลดตัวอ่าน Excel ไม่สำเร็จ ลองบันทึกไฟล์เป็น CSV แล้วอัปโหลดใหม่')); document.head.appendChild(s); });
    return window.XLSX;
  };
  R.parseCsv = function (text) {
    text = String(text || '').replace(/^﻿/, '');
    const sep = (text.split(/\r?\n/)[0].match(/;/g) || []).length > (text.split(/\r?\n/)[0].match(/,/g) || []).length ? ';' : text.split(/\r?\n/)[0].includes('\t') && !text.split(/\r?\n/)[0].includes(',') ? '\t' : ',';
    const rows = []; let row = [], cell = '', q = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (q) { if (c === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; }
      else if (c === '"') q = true;
      else if (c === sep) { row.push(cell); cell = ''; }
      else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = ''; }
      else cell += c;
    }
    if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
    return rows.filter((r) => r.some((x) => String(x).trim() !== ''));
  };
  const pad = (n) => String(n).padStart(2, '0');
  // a file → array of arrays of strings (Excel dates become YYYY-MM-DD, times HH:MM)
  R.readSheet = async function (file) {
    if (/\.(xlsx|xls)$/i.test(file.name)) {
      const X = await R.loadXlsx();
      // date cells are read from Excel's day number, not as JS dates (those come out a day early in Thai time)
      const wb = X.read(await file.arrayBuffer(), { type: 'array', cellNF: true });
      const ws = wb.Sheets[wb.SheetNames[0]];
      if (!ws || !ws['!ref']) return [];
      const rg = X.utils.decode_range(ws['!ref']), out = [];
      for (let r = rg.s.r; r <= rg.e.r; r++) {
        const row = [];
        for (let c = rg.s.c; c <= rg.e.c; c++) {
          const cell = ws[X.utils.encode_cell({ r, c })];
          if (!cell || cell.v == null) { row.push(''); continue; }
          if (cell.t === 'n' && cell.z && X.SSF.is_date(cell.z)) {
            const d = X.SSF.parse_date_code(cell.v), t = pad(d.H) + ':' + pad(d.M);
            row.push(cell.v < 1 ? t : `${d.y}-${pad(d.m)}-${pad(d.d)}` + (t !== '00:00' ? ' ' + t : ''));
          } else row.push(cell.t === 'd' ? String(cell.w || cell.v) : String(cell.v));
        }
        out.push(row);
      }
      return out.filter((r) => r.some((x) => x.trim() !== ''));
    }
    const buf = await file.arrayBuffer();
    let text;
    try { text = new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch (e) { text = new TextDecoder('windows-874').decode(buf); } // Thai bank files are often TIS-620
    return R.parseCsv(text);
  };
  // header text → our key. Template headers look like "วันที่* (date)"; files from other systems use their own names.
  R.IMPORT_COLS = {
    bank: { date: ['วันที่', 'วันที่ทำรายการ', 'date', 'transaction date', 'วันที่รายการ'], time: ['เวลา', 'time'], amount: ['ยอดเงิน', 'จำนวนเงิน', 'ยอด', 'เงินเข้า', 'amount', 'credit', 'deposit'],
      ref: ['เลขอ้างอิง', 'เลขที่รายการ', 'รหัสอ้างอิง', 'ref', 'reference', 'transaction id'], desc: ['รายละเอียด', 'หมายเหตุ', 'description', 'desc', 'note'] },
    delivery: { order_id: ['เลขออเดอร์', 'หมายเลขคำสั่งซื้อ', 'เลขที่ออเดอร์', 'order id', 'order no', 'order_id', 'booking id'], date: ['วันที่', 'date', 'order date'], time: ['เวลา', 'time'],
      item: ['ชื่อสินค้า', 'สินค้า', 'เมนู', 'item', 'menu', 'product'], qty: ['จำนวน', 'qty', 'quantity'], gross: ['ยอดขายก่อนหัก', 'ยอดขาย', 'ราคา', 'gross', 'price', 'subtotal'],
      discount: ['ส่วนลดที่ร้านออก', 'ส่วนลด', 'discount', 'shop discount'], commission: ['ค่าคอม', 'ค่าคอมมิชชัน', 'gp', 'commission'], vat: ['vat ค่าคอม', 'vat'],
      other: ['ค่าธรรมเนียมอื่น', 'other', 'other fee'], status: ['สถานะ', 'status'] },
  };
  R.mapRows = function (table, kind) {
    const spec = R.IMPORT_COLS[kind], keys = Object.keys(spec);
    const norm = (h) => String(h || '').toLowerCase().replace(/\*/g, '').replace(/\s+/g, ' ').trim();
    const keyOf = (h) => {
      const n = norm(h), par = (n.match(/\(([a-z_]+)\)/) || [])[1];
      if (par && keys.includes(par)) return par;
      const bare = n.replace(/\(.*?\)/g, '').trim();
      return keys.find((k) => spec[k].includes(bare) || spec[k].includes(n)) || null;
    };
    const need = kind === 'bank' ? ['date', 'amount'] : ['order_id', 'date', 'item', 'qty', 'gross'];
    for (let h = 0; h < Math.min(15, table.length); h++) {
      const map = table[h].map(keyOf);
      if (!need.every((k) => map.includes(k))) continue;
      const rows = table.slice(h + 1).map((r) => { const o = {}; map.forEach((k, i) => { if (k && o[k] == null) o[k] = String(r[i] == null ? '' : r[i]).trim(); }); return o; });
      // a date cell that also holds the time (Excel) fills the time column when it is empty
      rows.forEach((o) => { const m = String(o.date || '').match(/^(\S+)\s+(\d{1,2}:\d{2})/); if (m) { o.date = m[1]; if (!o.time) o.time = m[2]; } });
      return { rows, missing: [] };
    }
    return { rows: [], missing: need };
  };

  // ------------------------------------------------------------ polite reminders before the daily close
  const hhmm = () => { const d = new Date(); return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0'); };
  R.reminderState = () => {
    const b = R.state.boot; if (!b || !R.can('closing.add') || R.can('report.view')) return null;
    if (b.closed_today) return { done: true };
    if (R.isHoliday(R.today())) return { holiday: true };
    const times = (R.settingVal('reminder_times', []) || []).slice().sort();
    const now = hhmm(), due = R.settingVal('close_due_time', '21:00'), close = R.settingVal('close_time', '20:00');
    const passed = times.filter((t) => t <= now);
    if (!passed.length) return { upcoming: times[0] || null, due, close };
    const last = passed[passed.length - 1];
    const level = now > due ? 'late' : last >= close ? 'now' : 'soon';
    return { last, level, due, close, text: level === 'late' ? `เลยเวลาส่งรายงาน (${due} น.) แล้ว ส่งได้แต่จะนับว่าหลังเวลา`
      : level === 'now' ? `ถึงเวลาปิดยอดแล้ว ส่งรายงานภายใน ${due} น.` : `อีกสักครู่ร้านปิด (${close} น.) เตรียมนับเงินและของเหลือ` };
  };
  function remind() {
    const s = R.reminderState(); if (!s || s.done || !s.last) return;
    const key = 'rem.' + R.today() + '.' + s.last;
    if (R.store.get(key)) return;
    R.store.set(key, '1');
    R.toast('⏰ ' + s.text);
    try { if (window.Notification && Notification.permission === 'granted') new Notification('RSA - POS Assistant', { body: s.text }); } catch (e) { /* ignore */ }
  }
  setInterval(remind, 60000);
  window.addEventListener('hashchange', () => setTimeout(remind, 500));
  R.remind = remind;
})();
