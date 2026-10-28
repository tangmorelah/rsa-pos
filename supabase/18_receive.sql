-- RSA - POS Assistant : receiving in any unit, price filled in later, owner review of every staff receipt,
-- required evidence (or a reason) for money already paid.
--   * A line can be bought in any unit (กก. / ลูก / หวี / เข่ง / แพ็ก …). Known factor → converted into the stock unit.
--     Unknown factor → the bill still counts; the stock waits ("รอใส่ตัวแปลง") until the owner sets 1 <unit> ≈ x <stock unit>.
--   * "ไม่รู้ราคา": goods enter stock now, the bill waits for the owner to fill the price and how it was paid.
--   * Every receipt a staff member records waits in the owner's queue until checked.
set check_function_bodies = off;

alter table stock_receipt_lines add column if not exists buy_unit text;
alter table stock_receipt_lines add column if not exists buy_qty numeric(14,3);
alter table stock_receipt_lines add column if not exists unit_pending boolean not null default false;
alter table stock_receipt_lines add column if not exists stock_posted boolean not null default true;
alter table stock_receipts add column if not exists price_pending boolean not null default false;
alter table stock_receipts add column if not exists pay_ref text;
alter table stock_receipts add column if not exists no_evidence_reason text;
alter table stock_receipts add column if not exists reviewed_at timestamptz;
alter table stock_receipts add column if not exists reviewed_by uuid references app_users(id);
alter table expenses add column if not exists no_evidence_reason text;
-- receipts made before this version are not put in the review queue
insert into settings(key, value, confirmed) values ('receipt_review_since', to_jsonb(now()), true) on conflict (key) do nothing;

-- 1 <unit> of a stock item in its stock unit (null = not known yet)
create or replace function rsa_unit_factor(p_item stock_items, p_unit text) returns numeric language sql stable as $$
  select case when coalesce(nullif(trim(p_unit), ''), p_item.unit) = p_item.unit then 1::numeric
    else (select nullif(x->>'factor', '')::numeric from jsonb_array_elements(p_item.count_units) x
           where x->>'unit' = trim(p_unit) and nullif(x->>'factor', '')::numeric > 0 limit 1) end
$$;

-- remember a unit on the stock item (factor may be null = known name, size not known yet)
create or replace function rsa_unit_learn(p_item uuid, p_unit text, p_factor numeric) returns void language plpgsql as $$
declare v stock_items;
begin
  select * into v from stock_items where id = p_item for update;
  if not found or coalesce(trim(p_unit), '') = '' or trim(p_unit) = v.unit then return; end if;
  if p_factor is null and exists (select 1 from jsonb_array_elements(v.count_units) x where x->>'unit' = trim(p_unit)) then return; end if;
  update stock_items set count_units = coalesce((select jsonb_agg(x) from jsonb_array_elements(v.count_units) x where x->>'unit' <> trim(p_unit)), '[]')
         || jsonb_build_array(jsonb_build_object('unit', trim(p_unit), 'factor', p_factor))
   where id = p_item;
end $$;

-- spread transport over the lines and put the lines whose quantity is known into stock
create or replace function rsa_receipt_post(u app_users, p_id uuid) returns void language plpgsql as $$
declare v stock_receipts; r record; v_n int; v_bsum numeric; v_basis numeric; v_alloc numeric; v_rest numeric; v_landed numeric; v_cur numeric; v_item stock_items; k int := 0; v_method text;
begin
  select * into v from stock_receipts where id = p_id;
  v_method := coalesce(v.transport_method, 'value');
  select count(*), coalesce(sum(case v_method when 'value' then line_total when 'weight' then coalesce(weight, buy_qty, qty) else 1 end), 0)
    into v_n, v_bsum from stock_receipt_lines where receipt_id = p_id;
  if v_bsum <= 0 then v_method := 'equal'; v_bsum := v_n; end if;
  v_rest := v.transport_cost;
  for r in select * from stock_receipt_lines where receipt_id = p_id order by id loop
    k := k + 1;
    v_basis := case v_method when 'value' then r.line_total when 'weight' then coalesce(r.weight, r.buy_qty, r.qty) else 1 end;
    v_alloc := case when k = v_n then v_rest else round(v.transport_cost * v_basis / v_bsum, 2) end;
    v_rest := v_rest - v_alloc;
    v_landed := case when r.unit_pending then null else round((r.line_total + v_alloc) / r.qty, 4) end;
    update stock_receipt_lines set transport_alloc = v_alloc, landed_unit_cost = v_landed,
           unit_cost = case when r.unit_pending then 0 else round(r.line_total / r.qty, 4) end where id = r.id;
    if not r.stock_posted and not r.unit_pending then
      select * into v_item from stock_items where id = r.stock_item_id for update;
      if not v.price_pending and v_landed > 0 then
        v_cur := greatest(rsa_stock_qty(v_item.id), 0);
        update stock_items set avg_cost = round((v_cur * avg_cost + r.qty * v_landed) / (v_cur + r.qty), 4) where id = v_item.id;
      end if;
      insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
      values (v_item.id, v.received_at, r.qty, 'receipt', 'receipt', p_id, case when v.price_pending then null else v_landed end, u.id);
      update stock_receipt_lines set stock_posted = true where id = r.id;
    end if;
  end loop;
end $$;

-- the bills of a priced receipt: one per cost category, transport to the travel category
create or replace function rsa_receipt_bills(u app_users, p_id uuid, p jsonb) returns void language plpgsql as $$
declare v stock_receipts; v_src text; v_exp uuid; r record; v_sup suppliers;
begin
  select * into v from stock_receipts where id = p_id;
  select * into v_sup from suppliers where id = v.supplier_id;
  v_src := case when v.payer = 'owner' then 'owner_advance' when v.payer = 'employee' then 'employee_advance'
                when v.pay_method = 'shop_bank' then 'shop_bank' when v.pay_method = 'shop_cash' then 'shop_cash'
                when v.pay_method in ('credit', 'unpaid') then 'credit' end;
  if v_src is null or v.goods_cost + v.transport_cost <= 0 then return; end if;
  for r in
    select coalesce(s.cost_category_id, rsa_receipt_default_category(p)) cat_id, sum(l.line_total) amt, string_agg(l.item_name, ', ' order by l.item_name) names
      from stock_receipt_lines l join stock_items s on s.id = l.stock_item_id where l.receipt_id = p_id
     group by 1
    union all
    select coalesce((select id from expense_categories where active and code = 'A05'), rsa_receipt_default_category(p)), v.transport_cost, 'ค่าขนส่ง / ค่าเดินทางซื้อของ'
     where v.transport_cost > 0
  loop
    continue when r.amt <= 0;
    v_exp := rsa_expense_insert(u, jsonb_build_object(
      'fund_source', v_src, 'amount', r.amt, 'occurred_at', v.received_at, 'supplier_id', v.supplier_id,
      'payee', coalesce(v_sup.name, v.supplier_name), 'pay_ref', v.pay_ref, 'account_id', p->>'account_id', 'employee_id', coalesce(p->>'employee_id', v.created_by::text),
      'category_id', r.cat_id, 'description', 'ซื้อของเข้าร้าน ' || coalesce(v_sup.name, v.supplier_name, '') || ': ' || left(r.names, 120),
      'doc_no', v.ref_no), p_id);
    update stock_receipts set expense_id = coalesce(expense_id, v_exp) where id = p_id;
  end loop;
end $$;

create or replace function rsa__receipt_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_id uuid := gen_random_uuid(); ln jsonb; v_item stock_items; v_q numeric; v_lt numeric; v_goods numeric := 0; v_f numeric; v_unit text;
  v_trans numeric := greatest(rsa_num(p, 'transport_cost', 0), 0); v_method text := coalesce(nullif(p->>'transport_method', ''), rsa_setting('transport_method', '"value"') #>> '{}', 'value');
  v_sup suppliers; v_at timestamptz := rsa_ts(p, 'received_at'); v_later boolean := coalesce((p->>'price_later')::boolean, false);
  v_pay text := nullif(p->>'pay_method', ''); v_payer text := coalesce(nullif(p->>'payer', ''), 'shop');
  v_noev text := nullif(trim(coalesce(p->>'no_evidence_reason', '')), ''); v_mgr boolean := rsa_has(u, 'expense.approve');
begin
  perform rsa_need(u, 'stock.receive');
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then perform rsa_err('ใส่รายการรับของอย่างน้อย 1 รายการ'); end if;
  if v_method not in ('value','weight','equal') then v_method := 'value'; end if;
  select * into v_sup from suppliers where id = rsa_uuid(p, 'supplier_id');
  if v_sup.id is null and coalesce(trim(p->>'supplier_name'), '') = '' then perform rsa_err('กรุณาระบุว่าซื้อจากร้านไหน / ใคร'); end if;
  -- older clients send an "expense" object with pay_mode
  if v_pay is null and jsonb_typeof(p->'expense') = 'object' then
    v_pay := case p->'expense'->>'pay_mode' when 'drawer' then 'shop_cash' when 'account' then 'shop_bank' when 'employee' then 'shop_cash'
                  when 'later' then 'credit' when 'none' then 'none' end;
    if p->'expense'->>'pay_mode' = 'employee' then v_payer := 'employee'; end if;
  end if;
  if v_later then
    v_pay := null; v_trans := 0;
  else
    if v_pay is null then perform rsa_err('กรุณาเลือกวิธีจ่ายเงิน (ถ้าไม่รู้ราคา ให้ติ๊ก "ไม่รู้ราคา")'); end if;
    if v_pay = 'none' then v_pay := null; end if;
    if not rsa_has_files(p) and v_noev is null then perform rsa_err('แนบรูปบิล / สลิป หรือใส่เหตุผลว่าทำไมไม่มีบิล'); end if;
    if v_pay = 'shop_bank' and v_payer = 'shop' and coalesce(trim(p->>'pay_ref'), '') = '' then perform rsa_err('จ่ายจากบัญชีร้าน ใส่เลขอ้างอิง / เลขที่สลิปด้วย'); end if;
  end if;
  insert into stock_receipts(id, receipt_no, supplier_id, supplier_name, ref_no, received_at, note, transport_cost, transport_method, pay_method, payer, created_by,
                             price_pending, pay_ref, no_evidence_reason, reviewed_at, reviewed_by)
  values (v_id, rsa_next_no('R'), v_sup.id, coalesce(v_sup.name, nullif(trim(p->>'supplier_name'), '')), nullif(p->>'ref_no', ''), v_at,
          nullif(p->>'note', ''), v_trans, v_method, v_pay, case when v_later then null else v_payer end, u.id,
          v_later, nullif(trim(p->>'pay_ref'), ''), v_noev,
          case when v_mgr and not v_later then now() end, case when v_mgr and not v_later then u.id end);

  for ln in select * from jsonb_array_elements(p->'lines') loop
    select * into v_item from stock_items where id = rsa_uuid(ln, 'stock_item_id') and active;
    if not found then perform rsa_err('ไม่พบรายการสต็อก'); end if;
    v_q := coalesce(rsa_num(ln, 'buy_qty'), rsa_num(ln, 'qty'), 0);
    if v_q <= 0 then perform rsa_err('จำนวนรับเข้าของ "' || v_item.name || '" ต้องมากกว่า 0'); end if;
    v_unit := coalesce(nullif(trim(ln->>'unit'), ''), v_item.unit);
    -- a factor typed on the line is remembered on the stock item
    if rsa_num(ln, 'factor') > 0 and v_unit <> v_item.unit then perform rsa_unit_learn(v_item.id, v_unit, rsa_num(ln, 'factor')); select * into v_item from stock_items where id = v_item.id; end if;
    if v_unit <> v_item.unit then perform rsa_unit_learn(v_item.id, v_unit, null); end if;
    v_f := rsa_unit_factor(v_item, v_unit);
    v_lt := case when v_later then 0 else coalesce(rsa_num(ln, 'line_total'), round(v_q * rsa_num(ln, 'unit_cost', 0), 2)) end;
    if v_lt < 0 then perform rsa_err('ราคาติดลบไม่ได้'); end if;
    if not v_later and v_lt <= 0 then perform rsa_err('ใส่ราคาของ "' || v_item.name || '" (ถ้าไม่รู้ราคา ให้ติ๊ก "ไม่รู้ราคา")'); end if;
    insert into stock_receipt_lines(receipt_id, stock_item_id, item_name, unit, qty, unit_cost, line_total, weight, buy_unit, buy_qty, unit_pending, stock_posted)
    values (v_id, v_item.id, v_item.name, case when v_f is null then v_unit else v_item.unit end, case when v_f is null then v_q else round(v_q * v_f, 3) end,
            0, v_lt, rsa_num(ln, 'weight'), v_unit, v_q, v_f is null, false);
    v_goods := v_goods + v_lt;
  end loop;
  update stock_receipts set goods_cost = v_goods, total_cost = v_goods + v_trans where id = v_id;
  perform rsa_receipt_post(u, v_id);
  perform rsa_link_attachments(p->'attachment_ids', 'receipt', v_id, u);
  if not v_later then perform rsa_receipt_bills(u, v_id, p); end if;
  perform rsa_audit(u, 'receipt.create', 'receipt', v_id::text, null,
    jsonb_build_object('goods', v_goods, 'transport', v_trans, 'price_later', v_later, 'lines', jsonb_array_length(p->'lines')));
  return rsa_receipt_json(v_id);
end $$;

-- owner fills the price of a "ไม่รู้ราคา" receipt
create or replace function rsa__receipt_set_price(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v stock_receipts; ln jsonb; r record; v_lt numeric; v_goods numeric := 0; v_landed numeric; v_cur numeric; v_pay text := nullif(p->>'pay_method', '');
begin
  perform rsa_need(u, 'expense.approve');
  select * into v from stock_receipts where id = rsa_uuid(p, 'receipt_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบใบรับของ หรือยกเลิกไปแล้ว'); end if;
  if not v.price_pending then perform rsa_err('ใบรับของนี้ใส่ราคาแล้ว'); end if;
  if v_pay is null then perform rsa_err('กรุณาเลือกวิธีจ่ายเงิน'); end if;
  if not rsa_has_files(p) and coalesce(trim(p->>'no_evidence_reason'), '') = '' then perform rsa_err('แนบรูปบิล / สลิป หรือใส่เหตุผลว่าทำไมไม่มีบิล'); end if;
  for r in select * from stock_receipt_lines where receipt_id = v.id loop
    select x into ln from jsonb_array_elements(coalesce(p->'lines', '[]')) x where x->>'id' = r.id::text;
    v_lt := rsa_num(ln, 'line_total', 0);
    if v_lt <= 0 then perform rsa_err('ใส่ราคาของ "' || r.item_name || '" ให้ครบทุกรายการ'); end if;
    update stock_receipt_lines set line_total = v_lt where id = r.id;
    v_goods := v_goods + v_lt;
  end loop;
  update stock_receipts set price_pending = false, pay_method = case when v_pay = 'none' then null else v_pay end, payer = coalesce(nullif(p->>'payer', ''), 'shop'),
         pay_ref = nullif(trim(p->>'pay_ref'), ''), no_evidence_reason = nullif(trim(p->>'no_evidence_reason'), ''),
         transport_cost = greatest(rsa_num(p, 'transport_cost', v.transport_cost), 0), goods_cost = v_goods,
         total_cost = v_goods + greatest(rsa_num(p, 'transport_cost', v.transport_cost), 0), reviewed_at = now(), reviewed_by = u.id
   where id = v.id;
  perform rsa_receipt_post(u, v.id);
  -- goods already in stock came in at the old average: move the average toward the real landed cost
  for r in select l.*, s.avg_cost from stock_receipt_lines l join stock_items s on s.id = l.stock_item_id where l.receipt_id = v.id and l.stock_posted and l.landed_unit_cost > 0 loop
    v_cur := greatest(rsa_stock_qty(r.stock_item_id), r.qty);
    update stock_items set avg_cost = round(greatest(avg_cost + r.qty * (r.landed_unit_cost - avg_cost) / v_cur, 0), 4) where id = r.stock_item_id;
  end loop;
  perform rsa_link_attachments(p->'attachment_ids', 'receipt', v.id, u);
  perform rsa_receipt_bills(u, v.id, p);
  perform rsa_audit(u, 'receipt.price', 'receipt', v.id::text, null, jsonb_build_object('goods', v_goods, 'pay_method', v_pay));
  return rsa_receipt_json(v.id);
end $$;

-- a unit size known now (receiving, the owner's sheet, or the stock item form): waiting receipt lines go into stock
create or replace function rsa_unit_post_pending(p_item uuid) returns int language plpgsql as $$
declare v_item stock_items; r record; v_f numeric; n int := 0; v_u app_users;
begin
  select * into v_item from stock_items where id = p_item;
  for r in select l.*, s.created_by rcv_by from stock_receipt_lines l join stock_receipts s on s.id = l.receipt_id
            where l.stock_item_id = p_item and l.unit_pending and s.status <> 'cancelled' loop
    v_f := rsa_unit_factor(v_item, r.buy_unit);
    continue when v_f is null;
    update stock_receipt_lines set qty = round(r.buy_qty * v_f, 3), unit = v_item.unit, unit_pending = false where id = r.id;
    select * into v_u from app_users where id = r.rcv_by;
    perform rsa_receipt_post(v_u, r.receipt_id);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function rsa_stock_units_changed() returns trigger language plpgsql as $$
begin
  if new.count_units is distinct from old.count_units then perform rsa_unit_post_pending(new.id); end if;
  return new;
end $$;
drop trigger if exists stock_items_units_changed on stock_items;
create trigger stock_items_units_changed after update of count_units on stock_items for each row execute function rsa_stock_units_changed();

create or replace function rsa__stock_unit_set(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_item stock_items; v_f numeric := rsa_num(p, 'factor', 0); v_unit text := trim(coalesce(p->>'unit', '')); n int;
begin
  perform rsa_need(u, 'master.manage');
  select * into v_item from stock_items where id = rsa_uuid(p, 'stock_item_id');
  if not found then perform rsa_err('ไม่พบวัตถุดิบ'); end if;
  if v_unit = '' or v_f <= 0 then perform rsa_err('ใส่ชื่อหน่วยและจำนวนให้ครบ เช่น 1 หวี ≈ 1.2 ' || v_item.unit); end if;
  select count(*) into n from stock_receipt_lines l join stock_receipts s on s.id = l.receipt_id
   where l.stock_item_id = v_item.id and l.unit_pending and l.buy_unit = v_unit and s.status <> 'cancelled';
  perform rsa_unit_learn(v_item.id, v_unit, v_f);   -- the trigger puts the waiting lines into stock
  perform rsa_audit(u, 'stock.unit_set', 'stock_item', v_item.id::text, null, jsonb_build_object('unit', v_unit, 'factor', v_f, 'lines', n));
  return jsonb_build_object('ok', true, 'lines', n, 'units', (select count_units from stock_items where id = v_item.id));
end $$;

create or replace function rsa__receipt_review(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v stock_receipts;
begin
  perform rsa_need(u, 'expense.approve');
  select * into v from stock_receipts where id = rsa_uuid(p, 'receipt_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบใบรับของ หรือยกเลิกไปแล้ว'); end if;
  if v.price_pending then perform rsa_err('ใส่ราคาก่อน แล้วจึงตรวจได้'); end if;
  update stock_receipts set reviewed_at = now(), reviewed_by = u.id where id = v.id;
  perform rsa_audit(u, 'receipt.review', 'receipt', v.id::text);
  return rsa_receipt_json(v.id);
end $$;

-- receipts waiting for the owner: price, unit size, or a check
create or replace function rsa_receipt_needs(p_id uuid) returns text language sql stable as $$
  select case when r.status = 'cancelled' then null
              when r.price_pending then 'price'
              when exists (select 1 from stock_receipt_lines l where l.receipt_id = r.id and l.unit_pending) then 'unit'
              when r.reviewed_at is null and r.created_at >= coalesce((rsa_setting('receipt_review_since') #>> '{}')::timestamptz, now()) then 'review' end
    from stock_receipts r where r.id = p_id
$$;

create or replace function rsa_receipt_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(r) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = r.created_by),
    'reviewed_by_name', (select display_name from app_users where id = r.reviewed_by),
    'needs', rsa_receipt_needs(r.id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object('stock_unit', s.unit) order by l.id), '[]')
                from stock_receipt_lines l join stock_items s on s.id = l.stock_item_id where l.receipt_id = r.id),
    'attachments', rsa_attachment_refs('receipt', r.id),
    'expense', (select jsonb_build_object('id', e.id, 'expense_no', e.expense_no, 'status', e.status, 'amount', e.amount) from expenses e where e.id = r.expense_id))
  from stock_receipts r where r.id = p_id
$$;

create or replace function rsa__receipt_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  if coalesce((p->>'queue')::boolean, false) then
    perform rsa_need(u, 'expense.approve');
    return (select coalesce(jsonb_agg(rsa_receipt_json(r.id) order by r.received_at), '[]') from stock_receipts r where rsa_receipt_needs(r.id) is not null);
  end if;
  return (select coalesce(jsonb_agg(rsa_receipt_json(r.id) order by r.received_at desc), '[]') from stock_receipts r
           where rsa_bdate(r.received_at) between rsa_date(p, 'from', rsa_today() - 30) and rsa_date(p, 'to')
             and (rsa_has(u, 'expense.approve') or r.created_by = u.id));   -- staff see the receipts they recorded
end $$;

-- dashboard "ต้องทำ"
create or replace function rsa_receipt_alerts() returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', 'receipt_' || k, 'level', case k when 'price' then 'warn' else 'info' end,
           'text', case k when 'price' then 'รับของรอใส่ราคา ' when 'unit' then 'รับของรอใส่ตัวแปลงหน่วย ' else 'รับของรอตรวจ ' end || n || ' ใบ')), '[]')
    from (select rsa_receipt_needs(id) k, count(*) n from stock_receipts where status <> 'cancelled' group by 1) x where k is not null
$$;

-- form path for expenses: how it was paid must be chosen, and money already paid needs a picture or a reason
create or replace function rsa__expense_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid; v_src text := coalesce(nullif(p->>'fund_source', ''), nullif(p->>'pay_mode', ''));
begin
  if v_src is null then perform rsa_err('กรุณาเลือกว่าจ่ายจากเงินไหน'); end if;
  if v_src not in ('credit', 'later') and not rsa_has_files(p)
     and not exists (select 1 from expense_categories c where c.id = rsa_uuid(p, 'category_id') and c.grp = 'C' and coalesce(c.c_kind, '') <> 'advance') and coalesce(trim(p->>'no_evidence_reason'), '') = '' then
    perform rsa_err('แนบรูปใบเสร็จ / สลิป หรือใส่เหตุผลว่าทำไมไม่มีหลักฐาน');
  end if;
  v_id := rsa_expense_insert(u, p);   -- separate statement so the read below sees the new row
  if coalesce(trim(p->>'no_evidence_reason'), '') <> '' then update expenses set no_evidence_reason = trim(p->>'no_evidence_reason') where id = v_id; end if;
  return rsa_expense_json(v_id);
end $$;
