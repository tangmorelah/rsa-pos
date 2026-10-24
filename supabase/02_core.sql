-- RSA - POS Assistant : helpers, authentication, sales, stock
set check_function_bodies = off;

-- ---------------------------------------------------------------- helpers
create or replace function rsa_today() returns date language sql stable as $$
  select (now() at time zone 'Asia/Bangkok')::date
$$;

create or replace function rsa_bdate(ts timestamptz) returns date language sql immutable as $$
  select (ts at time zone 'Asia/Bangkok')::date
$$;

create or replace function rsa_err(msg text) returns void language plpgsql as $$
begin
  raise exception using message = msg, errcode = 'P0001';
end $$;

create or replace function rsa_num(p jsonb, k text, dflt numeric default null) returns numeric language sql immutable as $$
  select coalesce(nullif(p->>k, '')::numeric, dflt)
$$;

create or replace function rsa_uuid(p jsonb, k text) returns uuid language sql immutable as $$
  select nullif(p->>k, '')::uuid
$$;

create or replace function rsa_ts(p jsonb, k text) returns timestamptz language sql stable as $$
  select coalesce(nullif(p->>k, '')::timestamptz, now())
$$;

create or replace function rsa_date(p jsonb, k text, dflt date default null) returns date language sql stable as $$
  select coalesce(nullif(p->>k, '')::date, dflt, rsa_today())
$$;

create or replace function rsa_all_perms() returns text[] language sql immutable as $$
  select array[
    'sales.view','sales.view_all','sales.add','sales.cancel',
    'closing.add','closing.view_all','closing.edit',
    'stock.view','stock.receive','stock.count','stock.approve','stock.cancel','waste.add',
    'expense.add','expense.view_all','expense.approve','expense.pay','expense.cancel',
    'cashflow.view','cashflow.manage','report.view',
    'master.manage','settings.manage','export.run','audit.view','admin.users'
  ]
$$;

create or replace function rsa_role_perms(p_role text) returns text[] language sql immutable as $$
  select case p_role
    when 'staff' then array['sales.view','sales.add','closing.add','stock.view','stock.receive','stock.count','waste.add','expense.add']
    when 'owner' then array_remove(rsa_all_perms(), 'admin.users')
    when 'admin' then array['admin.users','audit.view']
    else array[]::text[] end
$$;

create or replace function rsa_has(u app_users, perm text) returns boolean language sql stable as $$
  select perm = any(u.perms)
$$;

create or replace function rsa_need(u app_users, perm text) returns void language plpgsql as $$
begin
  if not (perm = any(u.perms)) then
    perform rsa_err('คุณยังไม่มีสิทธิ์ทำรายการนี้ (' || perm || ') กรุณาติดต่อผู้ดูแลระบบ');
  end if;
end $$;

create or replace function rsa_audit(u app_users, p_action text, p_entity text, p_entity_id text,
  p_before jsonb default null, p_after jsonb default null, p_meta jsonb default null) returns void
language sql as $$
  insert into audit_log(user_id, user_name, action, entity, entity_id, before, after, meta)
  values (u.id, u.display_name, p_action, p_entity, p_entity_id, p_before, p_after, p_meta)
$$;

create or replace function rsa_drawer() returns uuid language sql stable as $$
  select id from payment_accounts where is_drawer and active order by created_at limit 1
$$;

create or replace function rsa_money(p_account uuid, p_dir text, p_amount numeric, p_src text, p_src_id uuid,
  p_note text, p_user uuid, p_at timestamptz default now()) returns void language plpgsql as $$
begin
  if p_account is null or coalesce(p_amount, 0) = 0 then return; end if;
  insert into money_ledger(account_id, occurred_at, biz_date, direction, amount, source_type, source_id, note, created_by)
  values (p_account, p_at, rsa_bdate(p_at), p_dir, abs(p_amount), p_src, p_src_id, p_note, p_user);
end $$;

create or replace function rsa_account_balance(p_account uuid, p_before date default null) returns numeric language sql stable as $$
  select coalesce((select opening_balance from payment_accounts where id = p_account), 0)
       + coalesce((select sum(case direction when 'in' then amount else -amount end) from money_ledger
                   where account_id = p_account and (p_before is null or biz_date < p_before)), 0)
$$;

create or replace function rsa_stock_qty(p_item uuid) returns numeric language sql stable as $$
  select coalesce(sum(qty), 0) from stock_ledger where stock_item_id = p_item
$$;

create or replace function rsa_link_attachments(p_ids jsonb, p_type text, p_id uuid, u app_users) returns int language plpgsql as $$
declare n int;
begin
  if p_ids is null or jsonb_typeof(p_ids) <> 'array' then return 0; end if;
  update attachments set linked_type = p_type, linked_id = p_id
   where id in (select (x)::uuid from jsonb_array_elements_text(p_ids) x)
     and linked_id is null and created_by = u.id;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function rsa_attachment_refs(p_type text, p_id uuid) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'filename', filename, 'doc_kind', doc_kind, 'mime', mime) order by created_at), '[]')
    from attachments where linked_type = p_type and linked_id = p_id
$$;

create or replace function rsa_user_json(u app_users) returns jsonb language sql stable as $$
  select jsonb_build_object('id', u.id, 'username', u.username, 'display_name', u.display_name,
    'role', u.role, 'perms', to_jsonb(u.perms), 'active', u.active)
$$;

-- ---------------------------------------------------------------- authentication (6-digit PIN)
create or replace function rsa_setup(p_username text, p_display_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v app_users;
begin
  perform pg_advisory_xact_lock(424242);
  if exists (select 1 from app_users) then
    perform rsa_err('ระบบตั้งค่าผู้ดูแลคนแรกไปแล้ว');
  end if;
  if p_pin !~ '^[0-9]{6}$' then perform rsa_err('PIN ต้องเป็นตัวเลข 6 หลัก'); end if;
  insert into app_users(username, display_name, role, perms, pin_hash)
  values (lower(trim(p_username)), trim(p_display_name), 'admin', rsa_all_perms(), crypt(p_pin, gen_salt('bf', 8)))
  returning * into v;
  perform rsa_audit(v, 'user.setup_first_admin', 'user', v.id::text, null, rsa_user_json(v));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa_status() returns jsonb
language sql security definer set search_path = public, extensions as $$
  select jsonb_build_object('needs_setup', not exists (select 1 from app_users),
    'shop_name', (select value from settings where key = 'shop_name'))
$$;

create or replace function rsa_login(p_username text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v app_users; v_token text;
begin
  select * into v from app_users where username = lower(trim(p_username));
  if not found or not v.active then
    perform rsa_err('ชื่อผู้ใช้หรือ PIN ไม่ถูกต้อง');
  end if;
  if v.locked_until is not null and v.locked_until > now() then
    perform rsa_err('ใส่ PIN ผิดหลายครั้ง กรุณารอ ' || ceil(extract(epoch from v.locked_until - now()) / 60)::int || ' นาทีแล้วลองใหม่');
  end if;
  if v.pin_hash <> crypt(coalesce(p_pin, ''), v.pin_hash) then
    update app_users set failed_attempts = failed_attempts + 1,
      locked_until = case when failed_attempts + 1 >= 5 then now() + interval '5 minutes' else null end
     where id = v.id;
    perform rsa_audit(v, 'login.failed', 'user', v.id::text);
    -- the failed-attempt counter must survive the exception, so return an error object instead of raising
    return jsonb_build_object('error', 'ชื่อผู้ใช้หรือ PIN ไม่ถูกต้อง');
  end if;
  update app_users set failed_attempts = 0, locked_until = null where id = v.id;
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into app_sessions(token_hash, user_id, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'), v.id, now() + interval '12 hours');
  delete from app_sessions where expires_at < now() - interval '7 days';
  perform rsa_audit(v, 'login', 'user', v.id::text);
  return jsonb_build_object('token', v_token, 'user', rsa_user_json(v));
end $$;

create or replace function rsa_session_user(p_token text) returns app_users
language plpgsql security definer set search_path = public, extensions as $$
declare v app_users;
begin
  select u.* into v from app_sessions s join app_users u on u.id = s.user_id
   where s.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and s.revoked_at is null and s.expires_at > now() and u.active;
  if not found then
    raise exception using message = 'กรุณาเข้าสู่ระบบอีกครั้ง', errcode = 'P0001', hint = 'auth';
  end if;
  return v;
end $$;

create or replace function rsa_logout(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  update app_sessions set revoked_at = now()
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and revoked_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- bootstrap data for the app
create or replace function rsa__bootstrap(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare is_mgr boolean := rsa_has(u, 'master.manage') or rsa_has(u, 'expense.approve');
begin
  return jsonb_build_object(
    'me', rsa_user_json(u),
    'today', rsa_today(),
    'now', now(),
    'settings', (select coalesce(jsonb_object_agg(key, jsonb_build_object('value', value, 'confirmed', confirmed)), '{}') from settings),
    'channels', (select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order, c.name), '[]') from channels c where c.active),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'is_drawer', a.is_drawer) order by a.is_drawer desc, a.name), '[]')
                   from payment_accounts a where a.active),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', p2.id, 'sku', p2.sku, 'name', p2.name, 'category', p2.category,
                   'unit', p2.unit, 'price', p2.price, 'sort_order', p2.sort_order,
                   'has_recipe', exists (select 1 from recipe_lines r where r.product_id = p2.id)) order by p2.sort_order, p2.name), '[]')
                   from products p2 where p2.active),
    'promotions', (select coalesce(jsonb_agg(to_jsonb(pr)), '[]') from promotions pr
                   where pr.active and (pr.starts_at is null or pr.starts_at <= now()) and (pr.ends_at is null or pr.ends_at > now())),
    'stock_items', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'unit', s.unit, 'kind', s.kind) order by s.name), '[]')
                   from stock_items s where s.active),
    'units', (select coalesce(jsonb_agg(name order by name), '[]') from units where active),
    'categories', (select coalesce(jsonb_agg(to_jsonb(c) order by c.name), '[]') from expense_categories c
                   where c.active and (is_mgr or c.staff_allowed)),
    'suppliers', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name), '[]') from suppliers s where s.active),
    'users', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'display_name', x.display_name) order by x.display_name), '[]')
                   from app_users x where x.active)
  );
end $$;

-- ---------------------------------------------------------------- sales
create or replace function rsa_order_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(o) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = o.created_by),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) order by i.product_name), '[]') from order_items i where i.order_id = o.id),
    'events', (select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object('by', (select display_name from app_users where id = e.created_by)) order by e.created_at), '[]')
               from order_events e where e.order_id = o.id),
    'closed', exists (select 1 from daily_closes d where d.biz_date = o.biz_date))
  from orders o where o.id = p_id
$$;

create or replace function rsa__order_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_ch channels; it jsonb; v_prod products; v_promo promotions;
  v_id uuid := gen_random_uuid(); v_no text; v_n int;
  -- an order kept on the phone while offline keeps the time it was taken (accepted up to 2 days back)
  v_at timestamptz := case when nullif(p->>'offline_at', '') is not null
                             and (p->>'offline_at')::timestamptz between now() - interval '2 days' and now()
                           then (p->>'offline_at')::timestamptz else now() end;
  v_date date := rsa_bdate(v_at);
  v_qty numeric; v_gross numeric; v_pdisc numeric; v_mdisc numeric; v_line numeric;
  v_unit_cost numeric; v_src text; v_linked boolean; v_missing boolean;
  v_sub numeric := 0; v_disc numeric := 0; v_cost numeric := 0; v_cost_ok boolean := true;
  v_existing uuid; v_total numeric; v_item_id uuid; r record;
begin
  perform rsa_need(u, 'sales.add');
  if nullif(p->>'client_ref', '') is not null then
    select id into v_existing from orders where client_ref = p->>'client_ref';
    if found then return rsa_order_json(v_existing); end if;
  end if;
  select * into v_ch from channels where id = rsa_uuid(p, 'channel_id') and active;
  if not found then perform rsa_err('กรุณาเลือกช่องทางขาย'); end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then
    perform rsa_err('ยังไม่มีสินค้าในออเดอร์');
  end if;

  insert into order_counters(biz_date, n) values (v_date, 1)
  on conflict (biz_date) do update set n = order_counters.n + 1 returning n into v_n;
  v_no := 'S' || to_char(v_date, 'YYMMDD') || '-' || lpad(v_n::text, 3, '0');

  insert into orders(id, order_no, client_ref, biz_date, created_at, channel_id, channel_name, channel_kind, payment_method, account_id,
                     subtotal, total, fee_pct, note, created_by)
  values (v_id, v_no, nullif(p->>'client_ref', ''), v_date, v_at, v_ch.id, v_ch.name, v_ch.kind, v_ch.payment_method,
          case when v_ch.kind = 'storefront' then v_ch.account_id end, 0, 0, v_ch.fee_pct,
          nullif(concat_ws(' · ', nullif(p->>'note', ''), case when v_at < now() - interval '1 minute' then 'บันทึกตอนไม่มีสัญญาณ ส่งเข้าระบบ ' || to_char(now() at time zone 'Asia/Bangkok', 'DD/MM HH24:MI') end), ''), u.id);

  for it in select * from jsonb_array_elements(p->'items') loop
    select * into v_prod from products where id = rsa_uuid(it, 'product_id') and active;
    if not found then perform rsa_err('ไม่พบสินค้า หรือสินค้าถูกปิดใช้งานแล้ว'); end if;
    v_qty := rsa_num(it, 'qty', 0);
    if v_qty <= 0 then perform rsa_err('จำนวนสินค้าต้องมากกว่า 0'); end if;
    v_gross := round(v_prod.price * v_qty, 2);

    -- best active promotion for this product and channel
    v_pdisc := 0; v_promo := null;
    select * into v_promo from promotions pr
     where pr.active and (pr.starts_at is null or pr.starts_at <= now()) and (pr.ends_at is null or pr.ends_at > now())
       and (pr.scope = 'all' or v_prod.id = any(pr.product_ids))
       and (cardinality(pr.channel_ids) = 0 or v_ch.id = any(pr.channel_ids))
       and v_qty >= pr.min_qty
     order by case pr.rule when 'percent' then round(v_gross * pr.value / 100, 2) else least(pr.value, v_prod.price) * v_qty end desc
     limit 1;
    if v_promo.id is not null then
      v_pdisc := case v_promo.rule when 'percent' then round(v_gross * v_promo.value / 100, 2)
                 else round(least(v_promo.value, v_prod.price) * v_qty, 2) end;
    end if;
    v_mdisc := least(greatest(rsa_num(it, 'discount', 0), 0), v_gross - v_pdisc);
    v_line := v_gross - v_pdisc - v_mdisc;

    -- cost and stock: only when a recipe/usage mapping exists
    v_linked := exists (select 1 from recipe_lines where product_id = v_prod.id);
    if v_linked then
      select sum(rl.qty * s.avg_cost), bool_or(s.avg_cost <= 0) into v_unit_cost, v_missing
        from recipe_lines rl join stock_items s on s.id = rl.stock_item_id where rl.product_id = v_prod.id;
      v_src := 'recipe';
      if v_missing then v_cost_ok := false; end if;
    elsif v_prod.est_cost is not null then
      v_unit_cost := v_prod.est_cost; v_src := 'manual';
    else
      v_unit_cost := null; v_src := 'none'; v_cost_ok := false;
    end if;

    v_item_id := gen_random_uuid();
    insert into order_items(id, order_id, product_id, product_name, sku, unit, qty, unit_price, discount, promo_id, promo_snapshot,
                            line_total, unit_cost, cost_source, stock_linked)
    values (v_item_id, v_id, v_prod.id, v_prod.name, v_prod.sku, v_prod.unit, v_qty, v_prod.price, v_pdisc + v_mdisc, v_promo.id,
            case when v_promo.id is not null then jsonb_build_object('name', v_promo.name, 'rule', v_promo.rule, 'value', v_promo.value,
                 'promo_discount', v_pdisc) end
            || case when v_mdisc > 0 then jsonb_build_object('manual_discount', v_mdisc) else '{}'::jsonb end,
            v_line, v_unit_cost, v_src, v_linked);

    if v_linked then
      for r in select rl.stock_item_id, rl.qty, s.avg_cost from recipe_lines rl join stock_items s on s.id = rl.stock_item_id
                where rl.product_id = v_prod.id loop
        insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
        values (r.stock_item_id, v_at, -(r.qty * v_qty), 'sale', 'order_item', v_item_id, r.avg_cost, u.id);
      end loop;
    end if;

    v_sub := v_sub + v_gross;
    v_disc := v_disc + v_pdisc + v_mdisc;
    v_cost := v_cost + coalesce(v_unit_cost, 0) * v_qty;
  end loop;

  v_total := v_sub - v_disc;
  update orders set subtotal = v_sub, discount = v_disc, total = v_total, cost_total = round(v_cost, 2), cost_complete = v_cost_ok,
         est_fee = case when v_ch.kind = 'delivery' then round(v_total * v_ch.fee_pct / 100, 2) else 0 end
   where id = v_id;

  if v_ch.kind = 'storefront' then
    perform rsa_money(v_ch.account_id, 'in', v_total, 'order', v_id, v_no, u.id, v_at);
  end if;
  perform rsa_audit(u, 'order.create', 'order', v_id::text, null, jsonb_build_object('order_no', v_no, 'total', v_total, 'channel', v_ch.name));
  return rsa_order_json(v_id);
end $$;

create or replace function rsa__order_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from'); v_to date := rsa_date(p, 'to', rsa_date(p, 'from'));
begin
  perform rsa_need(u, 'sales.view');
  return (select coalesce(jsonb_agg(rsa_order_json(o.id) order by o.created_at desc), '[]') from orders o
           where o.biz_date between v_from and v_to
             and (rsa_has(u, 'sales.view_all') or o.created_by = u.id)
             and (rsa_uuid(p, 'channel_id') is null or o.channel_id = rsa_uuid(p, 'channel_id')));
end $$;

create or replace function rsa__order_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v orders; v_amt numeric; r record;
begin
  perform rsa_need(u, 'sales.cancel');
  select * into v from orders where id = rsa_uuid(p, 'order_id') for update;
  if not found then perform rsa_err('ไม่พบออเดอร์'); end if;
  if v.status = 'cancelled' then perform rsa_err('ออเดอร์นี้ยกเลิกไปแล้ว'); end if;
  if v.settlement_id is not null then perform rsa_err('ออเดอร์นี้รับเงินจากแพลตฟอร์มแล้ว ให้ใช้การคืนเงินแทน'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  v_amt := v.total - v.refunded;
  update orders set status = 'cancelled', cancelled_at = now(), cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  insert into order_events(order_id, kind, amount, reason, account_id, created_by)
  values (v.id, 'cancel', v_amt, p->>'reason', v.account_id, u.id);
  if v.channel_kind = 'storefront' then
    perform rsa_money(v.account_id, 'out', v_amt, 'order_refund', v.id, 'ยกเลิก ' || v.order_no, u.id);
  end if;
  for r in select sl.* from stock_ledger sl join order_items i on i.id = sl.source_id
            where sl.source_type = 'order_item' and sl.kind = 'sale' and i.order_id = v.id loop
    insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
    values (r.stock_item_id, -r.qty, 'sale_reversal', 'order_item', r.source_id, r.unit_cost, u.id);
  end loop;
  perform rsa_audit(u, 'order.cancel', 'order', v.id::text, jsonb_build_object('status', v.status, 'total', v.total),
                    jsonb_build_object('status', 'cancelled', 'amount', v_amt), jsonb_build_object('reason', p->>'reason', 'order_no', v.order_no,
                    'after_close', exists (select 1 from daily_closes where biz_date = v.biz_date)));
  return rsa_order_json(v.id);
end $$;

create or replace function rsa__order_refund(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v orders; v_amt numeric := rsa_num(p, 'amount', 0); v_acc uuid;
begin
  perform rsa_need(u, 'sales.cancel');
  select * into v from orders where id = rsa_uuid(p, 'order_id') for update;
  if not found then perform rsa_err('ไม่พบออเดอร์'); end if;
  if v.status = 'cancelled' then perform rsa_err('ออเดอร์นี้ยกเลิกไปแล้ว'); end if;
  if v_amt <= 0 or v_amt > v.total - v.refunded then perform rsa_err('ยอดคืนเงินต้องมากกว่า 0 และไม่เกินยอดที่เหลือ ' || (v.total - v.refunded)); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการคืนเงิน'); end if;
  v_acc := coalesce(rsa_uuid(p, 'account_id'), v.account_id);
  update orders set refunded = refunded + v_amt,
         status = case when refunded + v_amt >= total then 'refunded' else 'partial_refund' end where id = v.id;
  insert into order_events(order_id, kind, amount, reason, account_id, created_by) values (v.id, 'refund', v_amt, p->>'reason', v_acc, u.id);
  if v.channel_kind = 'storefront' or rsa_uuid(p, 'account_id') is not null then
    perform rsa_money(v_acc, 'out', v_amt, 'order_refund', v.id, 'คืนเงิน ' || v.order_no, u.id);
  end if;
  perform rsa_audit(u, 'order.refund', 'order', v.id::text, jsonb_build_object('refunded', v.refunded),
                    jsonb_build_object('refunded', v.refunded + v_amt), jsonb_build_object('reason', p->>'reason', 'amount', v_amt, 'order_no', v.order_no));
  return rsa_order_json(v.id);
end $$;

-- ---------------------------------------------------------------- stock receiving
create or replace function rsa_next_no(p_prefix text) returns text language plpgsql as $$
declare v_key text := p_prefix || to_char(rsa_today(), 'YYMM'); v_n int;
begin
  insert into expense_counters(yymm, n) values (v_key, 1)
  on conflict (yymm) do update set n = expense_counters.n + 1 returning n into v_n;
  return p_prefix || to_char(rsa_today(), 'YYMM') || '-' || lpad(v_n::text, 4, '0');
end $$;

create or replace function rsa_expense_insert(u app_users, p jsonb, p_receipt uuid default null) returns uuid language plpgsql as $$
-- p: occurred_at, category_id, payee, supplier_id, description, amount, pay_mode (drawer|account|later|employee),
--    account_id, employee_id, doc_type, doc_no, ocr_snapshot, attachment_ids
declare
  v_id uuid := gen_random_uuid(); v_cat expense_categories; v_mode text := coalesce(p->>'pay_mode', 'later');
  v_status text; v_acc uuid; v_emp uuid; v_amt numeric := rsa_num(p, 'amount', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
  v_is_mgr boolean := rsa_has(u, 'expense.approve');
begin
  perform rsa_need(u, 'expense.add');
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if coalesce(trim(p->>'description'), '') = '' then perform rsa_err('กรุณาระบุรายละเอียดค่าใช้จ่าย'); end if;
  select * into v_cat from expense_categories where id = rsa_uuid(p, 'category_id') and active;
  if not found then perform rsa_err('กรุณาเลือกหมวดค่าใช้จ่าย'); end if;
  if not v_is_mgr and not v_cat.staff_allowed then perform rsa_err('หมวด "' || v_cat.name || '" ต้องให้เจ้าของร้านบันทึก'); end if;

  if v_mode = 'drawer' then
    v_acc := rsa_drawer(); v_status := 'จ่ายแล้ว';
    if v_acc is null then perform rsa_err('ยังไม่ได้ตั้งบัญชีลิ้นชักเงินสด'); end if;
  elsif v_mode = 'account' then
    perform rsa_need(u, 'expense.pay');
    v_acc := rsa_uuid(p, 'account_id'); v_status := 'จ่ายแล้ว';
    if v_acc is null then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
  elsif v_mode = 'employee' then
    v_emp := coalesce(rsa_uuid(p, 'employee_id'), u.id); v_status := 'รออนุมัติ';
  elsif v_mode = 'later' then
    v_status := case when v_is_mgr and coalesce((p->>'approve')::boolean, false) then 'รอทำจ่าย' else 'รออนุมัติ' end;
  else
    perform rsa_err('รูปแบบการจ่ายเงินไม่ถูกต้อง');
  end if;

  insert into expenses(id, expense_no, occurred_at, due_date, category_id, category_name, tax_category, payee, supplier_id, description, amount,
    status, pay_account_id, paid_by_employee, doc_type, doc_no, ocr_snapshot, receipt_id, reviewed, created_by,
    approved_at, approved_by, paid_at, paid_by)
  values (v_id, rsa_next_no('E'), v_at, nullif(p->>'due_date', '')::date, v_cat.id, v_cat.name, v_cat.tax_category, nullif(p->>'payee', ''),
    rsa_uuid(p, 'supplier_id'), p->>'description', v_amt, v_status, v_acc, v_emp, nullif(p->>'doc_type', ''), nullif(p->>'doc_no', ''),
    case when jsonb_typeof(p->'ocr_snapshot') = 'object' then p->'ocr_snapshot' end, p_receipt,
    (v_status = 'จ่ายแล้ว' and v_is_mgr),
    u.id,
    case when v_status in ('รอทำจ่าย') or (v_status = 'จ่ายแล้ว' and v_is_mgr) then now() end,
    case when v_status in ('รอทำจ่าย') or (v_status = 'จ่ายแล้ว' and v_is_mgr) then u.id end,
    case when v_status = 'จ่ายแล้ว' then v_at end,
    case when v_status = 'จ่ายแล้ว' then u.id end);

  if v_status = 'จ่ายแล้ว' then
    perform rsa_money(v_acc, 'out', v_amt, 'expense', v_id, p->>'description', u.id, v_at);
  end if;
  perform rsa_link_attachments(p->'attachment_ids', 'expense', v_id, u);
  perform rsa_audit(u, 'expense.create', 'expense', v_id::text, null,
    jsonb_build_object('amount', v_amt, 'status', v_status, 'pay_mode', v_mode, 'category', v_cat.name));
  return v_id;
end $$;

create or replace function rsa_receipt_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(r) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = r.created_by),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l)), '[]') from stock_receipt_lines l where l.receipt_id = r.id),
    'attachments', rsa_attachment_refs('receipt', r.id),
    'expense', (select jsonb_build_object('id', e.id, 'expense_no', e.expense_no, 'status', e.status, 'amount', e.amount) from expenses e where e.id = r.expense_id))
  from stock_receipts r where r.id = p_id
$$;

create or replace function rsa__receipt_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_id uuid := gen_random_uuid(); ln jsonb; v_item stock_items; v_qty numeric; v_cost numeric; v_total numeric := 0;
  v_cur numeric; v_sup suppliers; v_exp uuid; v_at timestamptz := rsa_ts(p, 'received_at');
begin
  perform rsa_need(u, 'stock.receive');
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then perform rsa_err('ใส่รายการรับของอย่างน้อย 1 รายการ'); end if;
  select * into v_sup from suppliers where id = rsa_uuid(p, 'supplier_id');
  insert into stock_receipts(id, receipt_no, supplier_id, supplier_name, ref_no, received_at, note, created_by)
  values (v_id, rsa_next_no('R'), v_sup.id, coalesce(v_sup.name, nullif(p->>'supplier_name', '')), nullif(p->>'ref_no', ''), v_at, nullif(p->>'note', ''), u.id);
  for ln in select * from jsonb_array_elements(p->'lines') loop
    select * into v_item from stock_items where id = rsa_uuid(ln, 'stock_item_id') and active for update;
    if not found then perform rsa_err('ไม่พบรายการสต็อก'); end if;
    v_qty := rsa_num(ln, 'qty', 0); v_cost := rsa_num(ln, 'unit_cost', 0);
    if v_qty <= 0 then perform rsa_err('จำนวนรับเข้าของ "' || v_item.name || '" ต้องมากกว่า 0'); end if;
    if v_cost < 0 then perform rsa_err('ราคาต่อหน่วยติดลบไม่ได้'); end if;
    insert into stock_receipt_lines(receipt_id, stock_item_id, item_name, unit, qty, unit_cost, line_total)
    values (v_id, v_item.id, v_item.name, v_item.unit, v_qty, v_cost, round(v_qty * v_cost, 2));
    if v_cost > 0 then
      v_cur := greatest(rsa_stock_qty(v_item.id), 0);
      update stock_items set avg_cost = round((v_cur * avg_cost + v_qty * v_cost) / (v_cur + v_qty), 4) where id = v_item.id;
    end if;
    insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
    values (v_item.id, v_at, v_qty, 'receipt', 'receipt', v_id, v_cost, u.id);
    v_total := v_total + round(v_qty * v_cost, 2);
  end loop;
  update stock_receipts set total_cost = v_total where id = v_id;
  perform rsa_link_attachments(p->'attachment_ids', 'receipt', v_id, u);

  if coalesce(p->'expense'->>'pay_mode', 'none') <> 'none' and v_total > 0 then
    v_exp := rsa_expense_insert(u, (p->'expense') || jsonb_build_object(
      'amount', v_total, 'occurred_at', v_at, 'supplier_id', v_sup.id, 'payee', coalesce(v_sup.name, p->>'supplier_name'),
      'description', coalesce(nullif(p->'expense'->>'description', ''), 'ซื้อของเข้าร้าน ' || coalesce(v_sup.name, p->>'supplier_name', '')),
      'doc_no', p->>'ref_no'), v_id);
    update stock_receipts set expense_id = v_exp where id = v_id;
    update attachments set linked_type = 'receipt' where linked_type = 'expense' and linked_id = v_exp; -- evidence lives on the receipt
  end if;
  perform rsa_audit(u, 'receipt.create', 'receipt', v_id::text, null, jsonb_build_object('total', v_total, 'lines', jsonb_array_length(p->'lines'), 'expense_id', v_exp));
  return rsa_receipt_json(v_id);
end $$;

create or replace function rsa__receipt_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(rsa_receipt_json(r.id) order by r.received_at desc), '[]') from stock_receipts r
           where rsa_bdate(r.received_at) between rsa_date(p, 'from', rsa_today() - 30) and rsa_date(p, 'to'));
end $$;

create or replace function rsa__receipt_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v stock_receipts; r record;
begin
  perform rsa_need(u, 'stock.cancel');
  select * into v from stock_receipts where id = rsa_uuid(p, 'receipt_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบใบรับของ หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update stock_receipts set status = 'cancelled', cancelled_at = now(), cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  for r in select * from stock_ledger where source_type = 'receipt' and source_id = v.id and kind = 'receipt' loop
    insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
    values (r.stock_item_id, -r.qty, 'receipt_reversal', 'receipt', v.id, r.unit_cost, u.id);
  end loop;
  -- every bill of this receipt (one per cost category) is cancelled with it
  for r in select id from expenses where (receipt_id = v.id or id = v.expense_id) and status <> 'ยกเลิก' loop
    perform rsa__expense_cancel(u, jsonb_build_object('expense_id', r.id, 'reason', 'ยกเลิกใบรับของ ' || v.receipt_no || ': ' || (p->>'reason')));
  end loop;
  perform rsa_audit(u, 'receipt.cancel', 'receipt', v.id::text, jsonb_build_object('status', v.status), jsonb_build_object('status', 'cancelled'),
                    jsonb_build_object('reason', p->>'reason'));
  return rsa_receipt_json(v.id);
end $$;

-- ---------------------------------------------------------------- waste
create or replace function rsa__waste_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_item stock_items; v_id uuid := gen_random_uuid(); v_qty numeric := rsa_num(p, 'qty', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
begin
  perform rsa_need(u, 'waste.add');
  select * into v_item from stock_items where id = rsa_uuid(p, 'stock_item_id') and active;
  if not found then perform rsa_err('กรุณาเลือกรายการที่เสีย'); end if;
  if v_qty <= 0 then perform rsa_err('จำนวนต้องมากกว่า 0'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุสาเหตุ'); end if;
  if coalesce((select (value)::text::boolean from settings where key = 'waste_evidence_required'), false)
     and (jsonb_typeof(p->'attachment_ids') <> 'array' or jsonb_array_length(p->'attachment_ids') = 0) then
    perform rsa_err('ร้านกำหนดให้แนบรูปของเสียทุกครั้ง');
  end if;
  insert into waste_records(id, stock_item_id, item_name, unit, qty, reason, unit_cost, occurred_at, biz_date, created_by)
  values (v_id, v_item.id, v_item.name, v_item.unit, v_qty, p->>'reason', v_item.avg_cost, v_at, rsa_bdate(v_at), u.id);
  insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
  values (v_item.id, v_at, -v_qty, 'waste', 'waste', v_id, v_item.avg_cost, u.id);
  perform rsa_link_attachments(p->'attachment_ids', 'waste', v_id, u);
  perform rsa_audit(u, 'waste.create', 'waste', v_id::text, null, jsonb_build_object('item', v_item.name, 'qty', v_qty, 'reason', p->>'reason'));
  return jsonb_build_object('id', v_id);
end $$;

create or replace function rsa__waste_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(to_jsonb(w) || jsonb_build_object('created_by_name', (select display_name from app_users where id = w.created_by),
            'attachments', rsa_attachment_refs('waste', w.id)) order by w.occurred_at desc), '[]')
            from waste_records w where w.biz_date between rsa_date(p, 'from', rsa_today() - 30) and rsa_date(p, 'to'));
end $$;

create or replace function rsa__waste_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v waste_records;
begin
  perform rsa_need(u, 'stock.cancel');
  select * into v from waste_records where id = rsa_uuid(p, 'waste_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update waste_records set status = 'cancelled', cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
  values (v.stock_item_id, v.qty, 'waste_reversal', 'waste', v.id, v.unit_cost, u.id);
  perform rsa_audit(u, 'waste.cancel', 'waste', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- stock count / stocktake
create or replace function rsa_stocktake_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(t) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = t.created_by),
    'approved_by_name', (select display_name from app_users where id = t.approved_by),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) order by l.item_name), '[]') from stocktake_lines l where l.stocktake_id = t.id))
  from stocktakes t where t.id = p_id
$$;

create or replace function rsa_stocktake_insert(u app_users, p_context text, p_lines jsonb, p_note text, p_close uuid default null) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid(); ln jsonb; v_item stock_items; v_sys numeric; v_cnt numeric; n int := 0;
begin
  if p_context = 'opening' then perform rsa_need(u, 'master.manage'); else perform rsa_need(u, 'stock.count'); end if;
  insert into stocktakes(id, context, biz_date, close_id, note, created_by) values (v_id, p_context, rsa_today(), p_close, p_note, u.id);
  for ln in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    if nullif(ln->>'counted_qty', '') is null then continue; end if;
    select * into v_item from stock_items where id = rsa_uuid(ln, 'stock_item_id');
    if not found then continue; end if;
    v_sys := rsa_stock_qty(v_item.id); v_cnt := rsa_num(ln, 'counted_qty');
    if v_cnt < 0 then perform rsa_err('จำนวนนับติดลบไม่ได้'); end if;
    insert into stocktake_lines(stocktake_id, stock_item_id, item_name, system_qty, counted_qty, variance, unit_cost, note)
    values (v_id, v_item.id, v_item.name, v_sys, v_cnt, v_cnt - v_sys, rsa_num(ln, 'unit_cost'), nullif(ln->>'note', ''));
    n := n + 1;
  end loop;
  if n = 0 then
    -- nothing counted: keep no empty stocktake around (tables block deletes, so mark it rejected)
    update stocktakes set status = 'rejected', note = coalesce(p_note, '') || ' (ไม่มีรายการนับ)' where id = v_id;
    return null;
  end if;
  perform rsa_audit(u, 'stocktake.create', 'stocktake', v_id::text, null, jsonb_build_object('context', p_context, 'lines', n));
  return v_id;
end $$;

create or replace function rsa__stocktake_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid;
begin
  v_id := rsa_stocktake_insert(u, coalesce(p->>'context', 'stocktake'), p->'lines', nullif(p->>'note', ''));
  if v_id is null then perform rsa_err('ยังไม่ได้ใส่จำนวนนับ'); end if;
  if p->>'context' = 'opening' then
    perform rsa__stocktake_decide(u, jsonb_build_object('stocktake_id', v_id, 'approve', true));
  end if;
  return rsa_stocktake_json(v_id);
end $$;

create or replace function rsa__stocktake_decide(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v stocktakes; r record; v_ok boolean := coalesce((p->>'approve')::boolean, false);
begin
  perform rsa_need(u, 'stock.approve');
  select * into v from stocktakes where id = rsa_uuid(p, 'stocktake_id') for update;
  if not found or v.status <> 'pending' then perform rsa_err('ไม่พบรายการนับ หรือพิจารณาไปแล้ว'); end if;
  update stocktakes set status = case when v_ok then 'approved' else 'rejected' end, approved_at = now(), approved_by = u.id,
         note = coalesce(note, '') || coalesce(' / ' || nullif(p->>'note', ''), '') where id = v.id;
  if v_ok then
    for r in select l.*, s.avg_cost from stocktake_lines l join stock_items s on s.id = l.stock_item_id where l.stocktake_id = v.id loop
      if r.unit_cost is not null and r.unit_cost > 0 then
        update stock_items set avg_cost = r.unit_cost where id = r.stock_item_id;
      end if;
      if r.variance <> 0 then
        insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
        values (r.stock_item_id, r.variance, 'count_adjust', 'stocktake', v.id, coalesce(nullif(r.unit_cost, 0), r.avg_cost), u.id);
      end if;
    end loop;
  end if;
  perform rsa_audit(u, case when v_ok then 'stocktake.approve' else 'stocktake.reject' end, 'stocktake', v.id::text, null, null,
                    jsonb_build_object('note', p->>'note'));
  return rsa_stocktake_json(v.id);
end $$;

create or replace function rsa__stocktake_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(rsa_stocktake_json(t.id) order by t.created_at desc), '[]') from
           (select * from stocktakes t0
             where (t0.status <> 'rejected' or t0.approved_by is not null)
               and (p->>'status' is null or t0.status = p->>'status')
             order by t0.created_at desc limit 100) t);
end $$;

create or replace function rsa__stock_balance(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(x order by x->>'name'), '[]') from (
    select jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'unit', s.unit, 'kind', s.kind, 'active', s.active,
      'qty', q.qty, 'avg_cost', case when rsa_has(u, 'report.view') then s.avg_cost end,
      'value', case when rsa_has(u, 'report.view') then round(greatest(q.qty, 0) * s.avg_cost, 2) end,
      'min_qty', s.min_qty, 'reorder_qty', s.reorder_qty,
      'used_7d', coalesce((select -sum(qty) from stock_ledger l where l.stock_item_id = s.id and l.kind in ('sale','sale_reversal')
                            and l.occurred_at > now() - interval '7 days'), 0),
      'status', case when q.qty <= 0 then 'out' when q.qty <= s.min_qty then 'low' else 'ok' end,
      'suggest', case when q.qty <= s.min_qty then greatest(coalesce(nullif(s.reorder_qty, 0), s.min_qty * 2 - q.qty), 0) else 0 end,
      'used_in_recipe', exists (select 1 from recipe_lines r where r.stock_item_id = s.id),
      'pending_count', exists (select 1 from stocktake_lines l join stocktakes t on t.id = l.stocktake_id where t.status = 'pending' and l.stock_item_id = s.id)
    ) x
    from stock_items s cross join lateral (select rsa_stock_qty(s.id) qty) q
    where s.active or coalesce((p->>'include_inactive')::boolean, false)) z);
end $$;

create or replace function rsa__stock_ledger(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object('by', (select display_name from app_users where id = l.created_by)) order by l.occurred_at desc), '[]')
    from (select * from stock_ledger where stock_item_id = rsa_uuid(p, 'stock_item_id') order by occurred_at desc limit 200) l);
end $$;
