-- RSA - POS Assistant : dashboard, reports, master data, users, attachments, export, API entry point
set check_function_bodies = off;

-- ---------------------------------------------------------------- dashboard & reports
create or replace function rsa__dashboard(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_date date := rsa_date(p, 'date'); v_today date := rsa_today(); v_ex jsonb := '[]'; v_n numeric; v_close daily_closes;
        v_due text := coalesce((select value #>> '{}' from settings where key = 'close_due_time'), '21:00');
begin
  perform rsa_need(u, 'report.view');
  if rsa_has(u, 'expense.approve') then perform rsa_fixed_generate(u, date_trunc('month', v_today)::date); end if;
  select * into v_close from daily_closes where biz_date = v_date;

  -- exceptions: things that need a look; nothing is forced to balance
  select count(*) into v_n from generate_series(v_today - 7, v_today - 1, interval '1 day') d
   where exists (select 1 from orders where biz_date = d::date) and not exists (select 1 from daily_closes where biz_date = d::date);
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'close_missing', 'level', 'warn', 'text', 'มี ' || v_n || ' วันที่มียอดขายแต่ยังไม่มีรายงานปิดยอด (7 วันล่าสุด)'); end if;
  -- open days (not holidays) with no sale and no report: probably a day off that was not set as a holiday
  select count(*) into v_n from generate_series(v_today - 7, v_today - 1, interval '1 day') d
   where rsa_is_open(d::date) and not exists (select 1 from orders where biz_date = d::date) and not exists (select 1 from daily_closes where biz_date = d::date)
     and d::date >= (select min(biz_date) from orders);
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'open_no_sales', 'level', 'info', 'text', 'มี ' || v_n || ' วันที่ร้านควรเปิดแต่ไม่มียอดขายและไม่มีรายงาน ถ้าวันนั้นหยุด ให้ตั้งเป็นวันหยุดร้าน'); end if;
  if v_close.id is null and v_date = v_today and to_char(now() at time zone 'Asia/Bangkok', 'HH24:MI') > v_due
     and exists (select 1 from orders where biz_date = v_today) then
    v_ex := v_ex || jsonb_build_object('kind', 'close_today', 'level', 'info', 'text', 'วันนี้ยังไม่มีรายงานปิดยอด (กำหนด ' || v_due || ')');
  end if;
  for v_close in select * from daily_closes where variance <> 0 and reviewed_at is null order by biz_date desc limit 10 loop
    v_ex := v_ex || jsonb_build_object('kind', 'cash_variance', 'level', 'warn', 'ref', v_close.id,
      'text', 'ปิดยอด ' || to_char(v_close.biz_date, 'DD/MM') || ' เงินสด' || case when v_close.variance < 0 then 'ขาด ' else 'เกิน ' end
              || to_char(abs(v_close.variance), 'FM999,999,990.00') || ' บาท: ' || coalesce(v_close.variance_reason, '-'));
  end loop;
  for v_close in select * from daily_closes where jsonb_array_length(adjustments) > 0 and reviewed_at is null order by biz_date desc limit 10 loop
    v_ex := v_ex || jsonb_build_object('kind', 'close_adjust', 'level', 'info', 'ref', v_close.id,
      'text', 'ปิดยอด ' || to_char(v_close.biz_date, 'DD/MM') || ' มีการแก้ตัวเลข ' || jsonb_array_length(v_close.adjustments) || ' จุด');
  end loop;
  select count(*) into v_n from orders o where o.status = 'cancelled' and exists (select 1 from daily_closes d where d.biz_date = o.biz_date and o.cancelled_at > d.submitted_at)
     and o.cancelled_at > now() - interval '14 days';
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'cancel_after_close', 'level', 'warn', 'text', 'มีออเดอร์ถูกยกเลิกหลังปิดยอดแล้ว ' || v_n || ' รายการ (14 วัน)'); end if;
  select count(*) into v_n from expenses where status = 'จ่ายแล้ว' and not reviewed;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'expense_review', 'level', 'info', 'text', 'ค่าใช้จ่ายที่จ่ายจากลิ้นชักแล้ว รอเจ้าของตรวจ ' || v_n || ' รายการ'); end if;
  select count(*) into v_n from expenses where status = 'รออนุมัติ';
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'expense_pending', 'level', 'info', 'text', 'ค่าใช้จ่ายรออนุมัติ ' || v_n || ' รายการ'); end if;
  select count(*) into v_n from expenses where status = 'รอทำจ่าย' and coalesce(due_date, rsa_bdate(occurred_at)) <= v_today;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'expense_due', 'level', 'warn', 'text', 'ค่าใช้จ่ายถึงกำหนดจ่าย ' || v_n || ' รายการ'); end if;
  select count(*) into v_n from stocktakes where status = 'pending';
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'stocktake_pending', 'level', 'info', 'text', 'การนับสต็อกรออนุมัติ ' || v_n || ' ครั้ง'); end if;
  select count(*) into v_n from delivery_settlements where status = 'done' and abs(system_gross - reported_gross) > 0.009;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'settlement_diff', 'level', 'warn', 'text', 'ยอด Delivery ในระบบไม่ตรงกับรายงานแพลตฟอร์ม ' || v_n || ' รอบ'); end if;
  select count(*) into v_n from orders o join channels c on c.id = o.channel_id
   where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days + 2 < v_today;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'settlement_overdue', 'level', 'warn', 'text', 'ออเดอร์ Delivery เลยกำหนดรับเงิน ' || v_n || ' ออเดอร์'); end if;
  select count(*) into v_n from money_ledger m join payment_accounts a on a.id = m.account_id
   where a.kind <> 'cash' and m.reconciled_at is null and m.biz_date < v_today - 3;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'bank_unreconciled', 'level', 'info', 'text', 'รายการเงินเข้า-ออกธนาคารยังไม่ได้ตรวจกับ statement ' || v_n || ' รายการ'); end if;
  select count(*) into v_n from stock_items s where s.active and s.min_qty > 0 and rsa_stock_qty(s.id) <= s.min_qty;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'low_stock', 'level', 'info', 'text', 'สต็อกใกล้หมด ' || v_n || ' รายการ'); end if;
  if exists (select 1 from payment_accounts where active and not opening_confirmed)
     or exists (select 1 from channels where active and kind = 'delivery' and not fee_confirmed) then
    v_ex := v_ex || jsonb_build_object('kind', 'unconfirmed', 'level', 'info', 'text', 'ยังมีค่าตั้งต้นที่ยังไม่ยืนยัน (ยอดยกมาบัญชี / ค่าธรรมเนียม Delivery)');
  end if;

  -- costs: over budget, cost ratios, recurring bills overdue, missing documents, 5 wage paydays (14_costs.sql)
  v_ex := v_ex || rsa_cost_alerts(v_today) || rsa_receipt_alerts();

  select * into v_close from daily_closes where biz_date = v_date;
  return jsonb_build_object(
    'date', v_date,
    'holiday', not rsa_is_open(v_date),
    'sales', rsa_close_compute(v_date),
    'profit', rsa_profit(v_date, v_date),
    'month', rsa_profit(date_trunc('month', v_date)::date, v_date),
    'cash', jsonb_build_object('drawer', rsa_account_balance(rsa_drawer()),
              'all', (select coalesce(sum(rsa_account_balance(id)), 0) from payment_accounts where active)),
    'close', case when v_close.id is not null then rsa_close_json(v_close.id) end,
    'due_time', v_due,
    'exceptions', v_ex,
    'last7', (select jsonb_agg(jsonb_build_object('date', d::date,
                'net', (select coalesce(sum(total - refunded), 0) from orders where biz_date = d::date and status <> 'cancelled')) order by d)
              from generate_series(v_date - 6, v_date, interval '1 day') d)
  );
end $$;

create or replace function rsa__report_sales(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 29); v_to date := rsa_date(p, 'to'); v_g text := coalesce(p->>'group', 'day');
begin
  perform rsa_need(u, 'report.view');
  if v_g not in ('day','week','month') then v_g := 'day'; end if;
  return jsonb_build_object('from', v_from, 'to', v_to, 'group', v_g,
    'rows', (select coalesce(jsonb_agg(x order by x->>'period', x->>'channel'), '[]') from (
       select jsonb_build_object('period', to_char(date_trunc(v_g, biz_date), 'YYYY-MM-DD'), 'channel', channel_name,
         'orders', count(*), 'net', sum(total - refunded), 'discount', sum(discount), 'est_fee', sum(est_fee), 'cost', sum(cost_total)) x
       from orders where status <> 'cancelled' and biz_date between v_from and v_to
       group by date_trunc(v_g, biz_date), channel_name) t),
    -- storefront money by where it went (split bills count in both), from the money ledger
    'payments', (select coalesce(jsonb_agg(x order by (x->>'amount')::numeric desc), '[]') from (
       select jsonb_build_object('account', a.name, 'kind', a.kind,
         'amount', sum(case m.direction when 'in' then m.amount else -m.amount end),
         'orders', count(distinct m.source_id) filter (where m.direction = 'in')) x
       from money_ledger m join orders o on o.id = m.source_id join payment_accounts a on a.id = m.account_id
       where m.source_type in ('order','order_refund') and o.biz_date between v_from and v_to
       group by a.id, a.name, a.kind) t),
    'mixed_orders', (select count(*) from orders where payment_method = 'mixed' and status <> 'cancelled' and biz_date between v_from and v_to),
    'profit', rsa_profit(v_from, v_to));
end $$;

create or replace function rsa__report_products(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 29); v_to date := rsa_date(p, 'to');
begin
  perform rsa_need(u, 'report.view');
  return jsonb_build_object(
    'products', (select coalesce(jsonb_agg(x order by (x->>'revenue')::numeric desc), '[]') from (
       select jsonb_build_object('product_id', i.product_id, 'name', max(i.product_name), 'qty', sum(i.qty), 'revenue', sum(i.line_total),
         'cost', sum(coalesce(i.unit_cost, 0) * i.qty), 'gross_profit', sum(i.line_total - coalesce(i.unit_cost, 0) * i.qty),
         'cost_known', bool_and(i.cost_source <> 'none'), 'stock_linked', bool_and(i.stock_linked)) x
       from order_items i join orders o on o.id = i.order_id
       where o.status <> 'cancelled' and o.biz_date between v_from and v_to group by i.product_id) t),
    'waste', (select coalesce(jsonb_agg(x order by (x->>'cost')::numeric desc), '[]') from (
       select jsonb_build_object('item', item_name, 'unit', max(unit), 'qty', sum(qty), 'cost', round(sum(qty * unit_cost), 2), 'times', count(*)) x
       from waste_records where status = 'recorded' and biz_date between v_from and v_to group by item_name) t));
end $$;

-- ---------------------------------------------------------------- master data
create or replace function rsa_master_cols(p_entity text) returns text[] language sql immutable as $$
  select case p_entity
    when 'products' then array['sku','name','category','unit','price','est_cost','sort_order','active']
    when 'stock_items' then array['code','name','kind','unit','min_qty','reorder_qty','avg_cost','default_supplier_id','active']
    when 'units' then array['name','active']
    when 'channels' then array['name','kind','payment_method','account_id','fee_pct','fee_confirmed','settlement_days','sort_order','active']
    when 'payment_accounts' then array['name','kind','is_drawer','bank_detail','opening_balance','opening_confirmed','active']
    when 'promotions' then array['name','scope','product_ids','channel_ids','rule','value','min_qty','starts_at','ends_at','active']
    when 'suppliers' then array['name','contact_name','phone','line_id','supplies','order_days','lead_time','delivery_schedule','min_order',
                                'delivery_fee','payment_method','credit_terms','bank_detail','can_issue_receipt','can_issue_tax_invoice',
                                'return_terms','priority','note','active']
    when 'expense_categories' then array['name','tax_category','staff_allowed','active']
    when 'fixed_expenses' then array['name','category_id','payee','amount','due_day','account_id','start_month','end_month','auto_approve','active']
  end
$$;

create or replace function rsa__master_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_e text := p->>'entity'; v jsonb;
begin
  if v_e = 'fixed_expenses' then return rsa__fixed_list(u, p); end if;
  perform rsa_need(u, 'master.manage');
  if rsa_master_cols(v_e) is null then perform rsa_err('ไม่รู้จักข้อมูลประเภทนี้'); end if;
  execute format('select coalesce(jsonb_agg(to_jsonb(t) order by t.active desc, t.name), ''[]'') from %I t', v_e) into v;
  if v_e = 'products' then
    select coalesce(jsonb_agg(x || jsonb_build_object('recipe', (select coalesce(jsonb_agg(jsonb_build_object('stock_item_id', r.stock_item_id, 'qty', r.qty,
             'name', s.name, 'unit', s.unit, 'avg_cost', s.avg_cost)), '[]') from recipe_lines r join stock_items s on s.id = r.stock_item_id
             where r.product_id = (x->>'id')::uuid))), '[]') into v from jsonb_array_elements(v) x;
  end if;
  return v;
end $$;

create or replace function rsa__master_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_e text := p->>'entity'; v_data jsonb := coalesce(p->'data', '{}'); v_id uuid := rsa_uuid(p->'data', 'id');
        v_cols text[]; v_keys text[]; v_before jsonb; v_after jsonb; v_list text;
begin
  if v_e = 'fixed_expenses' then perform rsa_need(u, 'expense.approve'); else perform rsa_need(u, 'master.manage'); end if;
  v_cols := rsa_master_cols(v_e);
  if v_cols is null then perform rsa_err('ไม่รู้จักข้อมูลประเภทนี้'); end if;
  -- an empty field arrives as null: leave NOT NULL columns at their default/current value instead of failing
  select array_agg(k) into v_keys from jsonb_object_keys(v_data) k
   where k = any(v_cols)
     and not (jsonb_typeof(v_data->k) = 'null' and exists (select 1 from information_schema.columns c
              where c.table_schema = 'public' and c.table_name = v_e and c.column_name = k and c.is_nullable = 'NO'));
  if v_keys is null then perform rsa_err('ไม่มีข้อมูลให้บันทึก'); end if;
  if v_data ? 'name' and coalesce(trim(v_data->>'name'), '') = '' then perform rsa_err('กรุณาใส่ชื่อ'); end if;
  if v_e = 'payment_accounts' and coalesce((v_data->>'is_drawer')::boolean, false)
     and exists (select 1 from payment_accounts where is_drawer and active and id is distinct from v_id) then
    perform rsa_err('มีบัญชีลิ้นชักเงินสดหน้าร้านอยู่แล้ว 1 บัญชี');
  end if;
  select string_agg(quote_ident(k), ',') into v_list from unnest(v_keys) k;
  if v_id is null then
    execute format('insert into %I (%s) select %s from jsonb_populate_record(null::%I, $1) returning id', v_e, v_list, v_list, v_e)
      using v_data into v_id;
  else
    execute format('select to_jsonb(t) from %I t where id = $1', v_e) using v_id into v_before;
    if v_before is null then perform rsa_err('ไม่พบข้อมูลที่จะแก้ไข'); end if;
    execute format('update %I set (%s) = (select %s from jsonb_populate_record(null::%I, $1)) where id = $2', v_e,
      v_list, v_list, v_e) using v_data, v_id;
  end if;
  execute format('select to_jsonb(t) from %I t where id = $1', v_e) using v_id into v_after;
  if v_e = 'products' and (v_before is null or (v_before->>'price')::numeric <> (v_after->>'price')::numeric) then
    insert into product_prices(product_id, price, changed_by) values (v_id, (v_after->>'price')::numeric, u.id);
    update products set updated_at = now() where id = v_id;
  end if;
  perform rsa_audit(u, case when v_before is null then 'master.create' else 'master.update' end, v_e, v_id::text, v_before, v_after);
  return v_after;
end $$;

create or replace function rsa__recipe_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_pid uuid := rsa_uuid(p, 'product_id'); v_before jsonb; ln jsonb;
begin
  perform rsa_need(u, 'master.manage');
  if not exists (select 1 from products where id = v_pid) then perform rsa_err('ไม่พบสินค้า'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('stock_item_id', stock_item_id, 'qty', qty)), '[]') into v_before from recipe_lines where product_id = v_pid;
  delete from recipe_lines where product_id = v_pid;   -- order lines keep their own cost and stock snapshots
  for ln in select * from jsonb_array_elements(coalesce(p->'lines', '[]')) loop
    if rsa_num(ln, 'qty', 0) > 0 and rsa_uuid(ln, 'stock_item_id') is not null then
      insert into recipe_lines(product_id, stock_item_id, qty) values (v_pid, rsa_uuid(ln, 'stock_item_id'), rsa_num(ln, 'qty'))
      on conflict (product_id, stock_item_id) do update set qty = excluded.qty;
    end if;
  end loop;
  perform rsa_audit(u, 'recipe.save', 'product', v_pid::text, v_before,
    (select coalesce(jsonb_agg(jsonb_build_object('stock_item_id', stock_item_id, 'qty', qty)), '[]') from recipe_lines where product_id = v_pid));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa__settings_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_before jsonb;
begin
  perform rsa_need(u, 'settings.manage');
  if p->>'key' not in ('shop_name','close_due_time','cash_variance_tolerance','waste_evidence_required','vat_registered','tax_id') then
    perform rsa_err('ไม่รู้จักการตั้งค่านี้');
  end if;
  select to_jsonb(s) into v_before from settings s where key = p->>'key';
  insert into settings(key, value, confirmed, updated_at, updated_by) values (p->>'key', p->'value', coalesce((p->>'confirmed')::boolean, true), now(), u.id)
  on conflict (key) do update set value = excluded.value, confirmed = excluded.confirmed, updated_at = now(), updated_by = u.id;
  perform rsa_audit(u, 'settings.save', 'settings', p->>'key', v_before, jsonb_build_object('value', p->'value', 'confirmed', coalesce((p->>'confirmed')::boolean, true)));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- users & permissions (Admin)
create or replace function rsa__user_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'admin.users');
  return (select coalesce(jsonb_agg(rsa_user_json(x) || jsonb_build_object('created_at', x.created_at, 'locked', x.locked_until > now())
            order by x.active desc, x.display_name), '[]') from app_users x);
end $$;

create or replace function rsa__user_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := rsa_uuid(p, 'id'); v app_users; v_before jsonb; v_perms text[]; v_role text := p->>'role';
begin
  perform rsa_need(u, 'admin.users');
  if v_role not in ('staff','owner','admin') then perform rsa_err('กรุณาเลือกบทบาท'); end if;
  if jsonb_typeof(p->'perms') = 'array' then
    select coalesce(array_agg(x), '{}') into v_perms from jsonb_array_elements_text(p->'perms') x where x = any(rsa_all_perms());
  else
    v_perms := rsa_role_perms(v_role);
  end if;
  if v_id is null then
    if coalesce(p->>'pin', '') !~ '^[0-9]{6}$' then perform rsa_err('PIN ต้องเป็นตัวเลข 6 หลัก'); end if;
    if coalesce(p->>'username', '') !~ '^[a-z0-9._-]{2,32}$' then perform rsa_err('ชื่อผู้ใช้ใช้ได้เฉพาะ a-z 0-9 . _ - (2-32 ตัว)'); end if;
    if exists (select 1 from app_users where username = p->>'username') then perform rsa_err('ชื่อผู้ใช้นี้มีแล้ว'); end if;
    insert into app_users(username, display_name, role, perms, pin_hash, created_by)
    values (p->>'username', trim(p->>'display_name'), v_role, v_perms, crypt(p->>'pin', gen_salt('bf', 8)), u.id) returning * into v;
    perform rsa_audit(u, 'user.create', 'user', v.id::text, null, rsa_user_json(v));
  else
    select * into v from app_users where id = v_id for update;
    if not found then perform rsa_err('ไม่พบผู้ใช้'); end if;
    v_before := rsa_user_json(v);
    if v.id = u.id and (not coalesce((p->>'active')::boolean, true) or not ('admin.users' = any(v_perms))) then
      perform rsa_err('ปิดใช้งานหรือถอดสิทธิ์ผู้ดูแลของตัวเองไม่ได้');
    end if;
    update app_users set display_name = coalesce(nullif(trim(p->>'display_name'), ''), display_name), role = v_role, perms = v_perms,
           active = coalesce((p->>'active')::boolean, active), updated_at = now() where id = v.id returning * into v;
    if not v.active then update app_sessions set revoked_at = now() where user_id = v.id and revoked_at is null; end if;
    perform rsa_audit(u, case when v_before->'perms' <> to_jsonb(v.perms) then 'user.permissions' else 'user.update' end,
                      'user', v.id::text, v_before, rsa_user_json(v));
  end if;
  return rsa_user_json(v);
end $$;

create or replace function rsa__user_reset_pin(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v app_users;
begin
  if rsa_uuid(p, 'id') is distinct from u.id then perform rsa_need(u, 'admin.users'); end if;
  if coalesce(p->>'pin', '') !~ '^[0-9]{6}$' then perform rsa_err('PIN ต้องเป็นตัวเลข 6 หลัก'); end if;
  if rsa_uuid(p, 'id') = u.id and u.pin_hash <> crypt(coalesce(p->>'old_pin', ''), u.pin_hash) then
    perform rsa_err('PIN เดิมไม่ถูกต้อง');
  end if;
  update app_users set pin_hash = crypt(p->>'pin', gen_salt('bf', 8)), failed_attempts = 0, locked_until = null, updated_at = now()
   where id = rsa_uuid(p, 'id') returning * into v;
  if not found then perform rsa_err('ไม่พบผู้ใช้'); end if;
  if v.id <> u.id then update app_sessions set revoked_at = now() where user_id = v.id and revoked_at is null; end if;
  perform rsa_audit(u, 'user.reset_pin', 'user', v.id::text, null, null, jsonb_build_object('target', v.display_name));  -- PIN itself is never logged
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa__audit_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'audit.view');
  return (select coalesce(jsonb_agg(to_jsonb(a) order by a.id desc), '[]') from
    (select * from audit_log a0
      where rsa_bdate(a0.at) between rsa_date(p, 'from', rsa_today() - 7) and rsa_date(p, 'to')
        and (nullif(p->>'action', '') is null or a0.action like (p->>'action') || '%')
        and (rsa_uuid(p, 'user_id') is null or a0.user_id = rsa_uuid(p, 'user_id'))
      order by a0.id desc limit 500) a);
end $$;

-- ---------------------------------------------------------------- attachments
create or replace function rsa__attachment_upload(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid; v_len int := length(coalesce(p->>'data_b64', ''));
begin
  if v_len = 0 then perform rsa_err('ไม่มีไฟล์'); end if;
  if v_len > 2800000 then perform rsa_err('ไฟล์ใหญ่เกิน 2 MB กรุณาถ่ายใหม่หรือย่อรูป'); end if;
  if coalesce(p->>'mime', '') !~ '^(image/(jpeg|png|webp)|application/pdf)$' then perform rsa_err('รองรับเฉพาะรูปภาพ JPG/PNG/WebP หรือ PDF'); end if;
  insert into attachments(filename, mime, size_bytes, data_b64, doc_kind, created_by)
  values (coalesce(nullif(p->>'filename', ''), 'file'), p->>'mime', (v_len * 3 / 4), p->>'data_b64', nullif(p->>'doc_kind', ''), u.id)
  returning id into v_id;
  perform rsa_audit(u, 'attachment.upload', 'attachment', v_id::text, null, jsonb_build_object('filename', p->>'filename', 'doc_kind', p->>'doc_kind'));
  return jsonb_build_object('id', v_id);
end $$;

create or replace function rsa__attachment_get(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v attachments;
begin
  select * into v from attachments where id = rsa_uuid(p, 'id');
  if not found then perform rsa_err('ไม่พบไฟล์'); end if;
  if v.created_by <> u.id and not (rsa_has(u, 'expense.view_all') or rsa_has(u, 'report.view') or rsa_has(u, 'stock.view')) then
    perform rsa_err('คุณยังไม่มีสิทธิ์ดูไฟล์นี้');
  end if;
  return jsonb_build_object('id', v.id, 'filename', v.filename, 'mime', v.mime, 'data_b64', v.data_b64, 'linked_type', v.linked_type, 'linked_id', v.linked_id);
end $$;

-- ---------------------------------------------------------------- accounting / tax export
create or replace function rsa__export(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_kind text := p->>'kind'; v_from date := rsa_date(p, 'from', rsa_today() - 30); v_to date := rsa_date(p, 'to');
        v_ch uuid := rsa_uuid(p, 'channel_id'); v_user uuid := rsa_uuid(p, 'user_id'); v_status text := nullif(p->>'status', ''); v jsonb;
begin
  perform rsa_need(u, 'export.run');
  if v_kind = 'sales' then
    select coalesce(jsonb_agg(x order by x->>'created_at', x->>'order_no'), '[]') into v from (
      select jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'biz_date', o.biz_date, 'created_at', o.created_at,
        'channel', o.channel_name, 'channel_kind', o.channel_kind, 'payment_method', o.payment_method, 'order_status', o.status,
        'item_id', i.id, 'sku', i.sku, 'product', i.product_name, 'qty', i.qty, 'unit', i.unit, 'unit_price', i.unit_price,
        'line_discount', i.discount, 'promotion', i.promo_snapshot->>'name', 'line_total', i.line_total,
        'order_total', o.total, 'order_refunded', o.refunded, 'est_delivery_fee', o.est_fee, 'settlement_id', o.settlement_id,
        'unit_cost_est', i.unit_cost, 'cost_source', i.cost_source,
        'created_by', (select display_name from app_users where id = o.created_by),
        'cancelled_at', o.cancelled_at, 'cancelled_by', (select display_name from app_users where id = o.cancelled_by), 'cancel_reason', o.cancel_reason) x
      from orders o join order_items i on i.order_id = o.id
      where o.biz_date between v_from and v_to and (v_ch is null or o.channel_id = v_ch) and (v_user is null or o.created_by = v_user)
        and (v_status is null or o.status = v_status)) t;
  elsif v_kind = 'money' then
    select coalesce(jsonb_agg(x order by x->>'occurred_at'), '[]') into v from (
      select jsonb_build_object('ledger_id', m.id, 'biz_date', m.biz_date, 'occurred_at', m.occurred_at, 'account', a.name, 'account_kind', a.kind,
        'direction', case m.direction when 'in' then 'รับเข้า' else 'จ่ายออก' end, 'amount', m.amount, 'source_type', m.source_type, 'source_id', m.source_id,
        'document_no', coalesce((select order_no from orders where id = m.source_id), (select expense_no from expenses where id = m.source_id),
                                (select ref_no from delivery_settlements where id = m.source_id)),
        'note', m.note, 'reconciled_at', m.reconciled_at, 'bank_ref', m.bank_ref, 'created_by', (select display_name from app_users where id = m.created_by),
        'created_at', m.created_at) x
      from money_ledger m join payment_accounts a on a.id = m.account_id
      where m.biz_date between v_from and v_to and (v_user is null or m.created_by = v_user)) t;
  elsif v_kind = 'expenses' then
    select coalesce(jsonb_agg(x order by x->>'occurred_at'), '[]') into v from (
      select jsonb_build_object('expense_id', e.id, 'expense_no', e.expense_no, 'occurred_at', e.occurred_at, 'due_date', e.due_date,
        'category', e.category_name, 'tax_category', e.tax_category, 'payee', e.payee, 'description', e.description, 'amount', e.amount,
        'status', e.status, 'pay_account', (select name from payment_accounts where id = e.pay_account_id),
        'employee_reimbursement', (select display_name from app_users where id = e.paid_by_employee), 'doc_type', e.doc_type, 'doc_no', e.doc_no,
        'evidence_ids', (select string_agg(id::text, ' ') from attachments where (linked_type = 'expense' and linked_id = e.id) or (linked_type = 'receipt' and linked_id = e.receipt_id)),
        'stock_receipt_id', e.receipt_id, 'fixed_expense_period', e.period,
        'created_by', (select display_name from app_users where id = e.created_by), 'created_at', e.created_at,
        'approved_by', (select display_name from app_users where id = e.approved_by), 'approved_at', e.approved_at,
        'paid_by', (select display_name from app_users where id = e.paid_by), 'paid_at', e.paid_at,
        'cancelled_by', (select display_name from app_users where id = e.cancelled_by), 'cancelled_at', e.cancelled_at, 'cancel_reason', e.cancel_reason) x
      from expenses e
      where rsa_bdate(e.occurred_at) between v_from and v_to and (v_status is null or e.status = v_status) and (v_user is null or e.created_by = v_user)) t;
  elsif v_kind = 'delivery' then
    select coalesce(jsonb_agg(x order by x->>'period_from'), '[]') into v from (
      select jsonb_build_object('settlement_id', s.id, 'channel', s.channel_name, 'period_from', s.period_from, 'period_to', s.period_to,
        'system_gross', s.system_gross, 'reported_gross', s.reported_gross, 'difference', s.reported_gross - s.system_gross,
        'fee', s.fee, 'net', s.net, 'deposit_account', (select name from payment_accounts where id = s.account_id), 'deposited_at', s.deposited_at,
        'ref_no', s.ref_no, 'status', s.status, 'cancel_reason', s.cancel_reason,
        'evidence_ids', (select string_agg(id::text, ' ') from attachments where linked_type = 'settlement' and linked_id = s.id),
        'created_by', (select display_name from app_users where id = s.created_by), 'created_at', s.created_at) x
      from delivery_settlements s where s.period_to between v_from and v_to and (v_ch is null or s.channel_id = v_ch)) t;
  elsif v_kind = 'corrections' then
    select coalesce(jsonb_agg(x order by x->>'at'), '[]') into v from (
      select jsonb_build_object('type', 'order.' || e.kind, 'record_id', e.order_id, 'document_no', o.order_no, 'at', e.created_at, 'amount', e.amount,
        'original_amount', o.total, 'reason', e.reason, 'by', (select display_name from app_users where id = e.created_by)) x
        from order_events e join orders o on o.id = e.order_id where rsa_bdate(e.created_at) between v_from and v_to
      union all
      select jsonb_build_object('type', 'expense.cancel', 'record_id', id, 'document_no', expense_no, 'at', cancelled_at, 'amount', amount,
        'original_amount', amount, 'reason', cancel_reason, 'by', (select display_name from app_users where id = cancelled_by))
        from expenses where status = 'ยกเลิก' and rsa_bdate(cancelled_at) between v_from and v_to
      union all
      select jsonb_build_object('type', 'receipt.cancel', 'record_id', id, 'document_no', receipt_no, 'at', cancelled_at, 'amount', total_cost,
        'original_amount', total_cost, 'reason', cancel_reason, 'by', (select display_name from app_users where id = cancelled_by))
        from stock_receipts where status = 'cancelled' and rsa_bdate(cancelled_at) between v_from and v_to
      union all
      select jsonb_build_object('type', 'close.adjustment', 'record_id', d.id, 'document_no', to_char(d.biz_date, 'YYYY-MM-DD'), 'at', d.submitted_at,
        'field', a->>'label', 'original_amount', a->'original', 'amount', a->'corrected', 'reason', a->>'reason', 'by', coalesce(a->>'by', (select display_name from app_users where id = d.submitted_by)))
        from daily_closes d, jsonb_array_elements(d.adjustments) a where d.biz_date between v_from and v_to
      union all
      select jsonb_build_object('type', 'close.cash_variance', 'record_id', d.id, 'document_no', to_char(d.biz_date, 'YYYY-MM-DD'), 'at', d.submitted_at,
        'original_amount', d.expected_cash, 'amount', d.counted_cash, 'difference', d.variance, 'reason', d.variance_reason,
        'by', (select display_name from app_users where id = d.submitted_by))
        from daily_closes d where d.variance <> 0 and d.biz_date between v_from and v_to
      union all
      select jsonb_build_object('type', 'settlement.cancel', 'record_id', id, 'document_no', ref_no, 'at', created_at, 'amount', net, 'reason', cancel_reason,
        'by', (select display_name from app_users where id = cancelled_by)) from delivery_settlements where status = 'cancelled' and period_to between v_from and v_to
      ) t;
  elsif v_kind = 'receipts' then
    select coalesce(jsonb_agg(x order by x->>'received_at'), '[]') into v from (
      select jsonb_build_object('receipt_id', r.id, 'receipt_no', r.receipt_no, 'received_at', r.received_at, 'supplier', r.supplier_name, 'ref_no', r.ref_no,
        'item', l.item_name, 'qty', l.qty, 'unit', l.unit, 'unit_cost', l.unit_cost, 'line_total', l.line_total, 'status', r.status,
        'expense_no', (select expense_no from expenses where id = r.expense_id),
        'evidence_ids', (select string_agg(id::text, ' ') from attachments where linked_type = 'receipt' and linked_id = r.id),
        'created_by', (select display_name from app_users where id = r.created_by)) x
      from stock_receipts r join stock_receipt_lines l on l.receipt_id = r.id where rsa_bdate(r.received_at) between v_from and v_to) t;
  elsif v_kind = 'audit' then
    perform rsa_need(u, 'audit.view');
    select coalesce(jsonb_agg(jsonb_build_object('audit_id', a.id, 'at', a.at, 'user', a.user_name, 'action', a.action, 'entity', a.entity,
      'entity_id', a.entity_id, 'before', a.before, 'after', a.after, 'meta', a.meta) order by a.id), '[]') into v
      from audit_log a where rsa_bdate(a.at) between v_from and v_to and (v_user is null or a.user_id = v_user);
  else
    perform rsa_err('ไม่รู้จักประเภทรายงานส่งออก');
  end if;
  perform rsa_audit(u, 'export', 'export', v_kind, null, null,
    jsonb_build_object('kind', v_kind, 'from', v_from, 'to', v_to, 'channel_id', v_ch, 'user_id', v_user, 'status', v_status, 'rows', jsonb_array_length(v)));
  return v;
end $$;

-- ---------------------------------------------------------------- API entry point
create or replace function rsa_api(p_token text, p_action text, p_payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u app_users := rsa_session_user(p_token); p jsonb := coalesce(p_payload, '{}');
begin
  return case p_action
    when 'bootstrap'          then rsa__bootstrap(u, p)
    when 'order.create'       then rsa__order_create(u, p)
    when 'order.list'         then rsa__order_list(u, p)
    when 'order.cancel'       then rsa__order_cancel(u, p)
    when 'order.refund'       then rsa__order_refund(u, p)
    when 'receipt.create'     then rsa__receipt_create(u, p)
    when 'receipt.list'       then rsa__receipt_list(u, p)
    when 'receipt.cancel'     then rsa__receipt_cancel(u, p)
    when 'waste.create'       then rsa__waste_create(u, p)
    when 'waste.list'         then rsa__waste_list(u, p)
    when 'waste.cancel'       then rsa__waste_cancel(u, p)
    when 'stocktake.create'   then rsa__stocktake_create(u, p)
    when 'stocktake.decide'   then rsa__stocktake_decide(u, p)
    when 'stocktake.list'     then rsa__stocktake_list(u, p)
    when 'stock.balance'      then rsa__stock_balance(u, p)
    when 'stock.ledger'       then rsa__stock_ledger(u, p)
    when 'expense.create'     then rsa__expense_create(u, p)
    when 'expense.list'       then rsa__expense_list(u, p)
    when 'expense.approve'    then rsa__expense_approve(u, p)
    when 'expense.pay'        then rsa__expense_pay(u, p)
    when 'expense.cancel'     then rsa__expense_cancel(u, p)
    when 'fixed.generate'     then rsa__fixed_generate(u, p)
    when 'close.preview'      then rsa__close_preview(u, p)
    when 'close.submit'       then rsa__close_submit(u, p)
    when 'close.revise'       then rsa__close_revise(u, p)
    when 'close.review'       then rsa__close_review(u, p)
    when 'close.list'         then rsa__close_list(u, p)
    when 'close.workdays'     then rsa__close_workdays(u, p)
    when 'transfer.create'    then rsa__transfer_create(u, p)
    when 'settlement.preview' then rsa__settlement_preview(u, p)
    when 'settlement.create'  then rsa__settlement_create(u, p)
    when 'settlement.cancel'  then rsa__settlement_cancel(u, p)
    when 'settlement.list'    then rsa__settlement_list(u, p)
    when 'capital.create'     then rsa__capital_create(u, p)
    when 'capital.cancel'     then rsa__capital_cancel(u, p)
    when 'profit.declare'     then rsa__profit_declare(u, p)
    when 'profit.cancel'      then rsa__profit_cancel(u, p)
    when 'ledger.list'        then rsa__ledger_list(u, p)
    when 'ledger.reconcile'   then rsa__ledger_reconcile(u, p)
    when 'cashflow.summary'   then rsa__cashflow_summary(u, p)
    when 'dashboard'          then rsa__dashboard(u, p)
    when 'report.sales'       then rsa__report_sales(u, p)
    when 'report.products'    then rsa__report_products(u, p)
    when 'master.list'        then rsa__master_list(u, p)
    when 'master.save'        then rsa__master_save(u, p)
    when 'recipe.save'        then rsa__recipe_save(u, p)
    when 'settings.save'      then rsa__settings_save(u, p)
    when 'user.list'          then rsa__user_list(u, p)
    when 'user.save'          then rsa__user_save(u, p)
    when 'user.reset_pin'     then rsa__user_reset_pin(u, p)
    when 'audit.list'         then rsa__audit_list(u, p)
    when 'attachment.upload'  then rsa__attachment_upload(u, p)
    when 'attachment.get'     then rsa__attachment_get(u, p)
    when 'export'             then rsa__export(u, p)
    else (select jsonb_build_object('error', 'ไม่รู้จักคำสั่ง ' || p_action))
  end;
end $$;

-- Only the four entry points are callable from the browser.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'rsa%' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', r.sig); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke all on function %s from authenticated', r.sig); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function rsa_status() to anon;
    grant execute on function rsa_setup(text, text, text) to anon;
    grant execute on function rsa_login(text, text) to anon;
    grant execute on function rsa_logout(text) to anon;
    grant execute on function rsa_api(text, text, jsonb) to anon;
  end if;
end $$;
