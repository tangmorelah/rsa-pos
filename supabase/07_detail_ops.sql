-- RSA - POS Assistant : detail upgrade (sales with channel price / bundle / received amount / edit,
-- waste by product, receiving with transport, expenses with fund source, 6-step daily close)
set check_function_bodies = off;

create or replace function rsa_setting(p_key text, p_default jsonb default null) returns jsonb language sql stable as $$
  select coalesce((select value from settings where key = p_key), p_default)
$$;

create or replace function rsa_setting_num(p_key text, p_default numeric default 0) returns numeric language sql stable as $$
  select coalesce((select nullif(value #>> '{}', '')::numeric from settings where key = p_key and jsonb_typeof(value) in ('number','string')), p_default)
$$;

create or replace function rsa_setting_bool(p_key text) returns boolean language sql stable as $$
  select coalesce((select (value #>> '{}')::boolean from settings where key = p_key and jsonb_typeof(value) = 'boolean'), false)
$$;

-- shop holidays: weekly closed days (0 = Sunday … 6 = Saturday) and one-off closed dates
create or replace function rsa_is_open(d date) returns boolean language sql stable as $$
  select not (extract(dow from d)::int in (select jsonb_array_elements_text(case when jsonb_typeof(rsa_setting('closed_weekdays')) = 'array' then rsa_setting('closed_weekdays') else '[]' end)::int)
              or to_char(d, 'YYYY-MM-DD') in (select jsonb_array_elements_text(case when jsonb_typeof(rsa_setting('closed_dates')) = 'array' then rsa_setting('closed_dates') else '[]' end)))
$$;

-- number of days the shop is open in a range (at least 1, used as the divisor of per-day averages)
create or replace function rsa_open_days(p_from date, p_to date) returns int language sql stable as $$
  select greatest(count(*)::int, 1) from generate_series(p_from, p_to, interval '1 day') g where rsa_is_open(g::date)
$$;

create or replace function rsa_has_files(p jsonb) returns boolean language sql immutable as $$
  select coalesce(jsonb_typeof(p->'attachment_ids') = 'array' and jsonb_array_length(p->'attachment_ids') > 0, false)
$$;

-- ---------------------------------------------------------------- orders
create or replace function rsa_order_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(o) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = o.created_by),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) || jsonb_build_object('emoji', (select emoji from products where id = i.product_id)) order by i.product_name), '[]')
              from order_items i where i.order_id = o.id),
    'events', (select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object('by', (select display_name from app_users where id = e.created_by)) order by e.created_at), '[]')
               from order_events e where e.order_id = o.id),
    'replaced_by_no', (select order_no from orders x where x.id = o.replaced_by),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('account_id', op.account_id, 'method', op.method, 'amount', op.amount,
                   'account', (select name from payment_accounts where id = op.account_id)) order by op.amount desc), '[]')
                 from order_payments op where op.order_id = o.id),
    'replaces_no', (select order_no from orders x where x.id = o.replaces_order_id),
    'closed', exists (select 1 from daily_closes d where d.biz_date = o.biz_date))
  from orders o where o.id = p_id
$$;

-- Staff may fix their own order on the same day before the daily close; anyone with sales.cancel may fix any order.
create or replace function rsa_order_can_edit(u app_users, v orders) returns boolean language sql stable as $$
  select rsa_has(u, 'sales.cancel')
      or (v.created_by = u.id and v.biz_date = rsa_today() and not exists (select 1 from daily_closes d where d.biz_date = v.biz_date))
$$;

create or replace function rsa__order_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_ch channels; it jsonb; ln jsonb; v_prod products; v_promo promotions;
  v_id uuid := gen_random_uuid(); v_no text; v_n int; i int;
  -- set by order.update so the corrected order keeps the original time and links back to it
  v_edit_at text := nullif(current_setting('rsa.edit_at', true), '');
  v_edit_of uuid := nullif(current_setting('rsa.edit_of', true), '')::uuid;
  v_at timestamptz; v_date date;
  v_lines jsonb := '[]'; v_bdisc jsonb := '{}';
  v_qty numeric; v_price numeric; v_gross numeric; v_pdisc numeric; v_mdisc numeric; v_line numeric;
  v_promo_id uuid; v_snap jsonb;
  v_unit_cost numeric; v_src text; v_linked boolean; v_missing boolean;
  v_sub numeric := 0; v_disc numeric := 0; v_cost numeric := 0; v_cost_ok boolean := true;
  v_existing uuid; v_calc numeric; v_total numeric; v_recv numeric; v_item_id uuid; r record;
  v_idx int[]; v_pool_qty numeric; v_pool_gross numeric; v_bundles numeric; v_bd numeric; v_rest numeric; v_share numeric; k int;
  v_md boolean; v_md_from text := nullif(rsa_setting('markdown_from') #>> '{}', ''); v_pays jsonb; v_pay jsonb; v_pacc payment_accounts; v_psum numeric := 0;
begin
  perform rsa_need(u, 'sales.add');
  if v_edit_at is not null then
    v_at := v_edit_at::timestamptz;
  elsif nullif(p->>'offline_at', '') is not null and (p->>'offline_at')::timestamptz between now() - interval '2 days' and now() then
    -- an order kept on the phone while offline keeps the time it was taken (accepted up to 2 days back)
    v_at := (p->>'offline_at')::timestamptz;
  else
    v_at := now();
  end if;
  v_date := rsa_bdate(v_at);

  if v_edit_of is null and nullif(p->>'client_ref', '') is not null then
    select id into v_existing from orders where client_ref = p->>'client_ref';
    if found then return rsa_order_json(v_existing); end if;
  end if;
  select * into v_ch from channels where id = rsa_uuid(p, 'channel_id') and active;
  if not found then perform rsa_err('กรุณาเลือกช่องทางขาย'); end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then
    perform rsa_err('ยังไม่มีสินค้าในออเดอร์');
  end if;

  -- pass 1: check every line and price it for this channel
  for it in select * from jsonb_array_elements(p->'items') loop
    select * into v_prod from products where id = rsa_uuid(it, 'product_id') and active;
    if not found then perform rsa_err('ไม่พบสินค้า หรือสินค้าถูกปิดใช้งานแล้ว'); end if;
    v_qty := rsa_num(it, 'qty', 0);
    if v_qty <= 0 then perform rsa_err('จำนวนสินค้าต้องมากกว่า 0'); end if;
    if v_ch.kind = 'delivery' and not v_prod.delivery_enabled then
      perform rsa_err('"' || v_prod.name || '" ไม่ได้เปิดขายทาง Delivery');
    end if;
    v_price := case when v_ch.kind = 'delivery' and v_prod.delivery_price is not null then v_prod.delivery_price else v_prod.price end;
    -- evening markdown: storefront only, product must have a markdown price, from the set time (owner/manager any time)
    v_md := coalesce((it->>'markdown')::boolean, false);
    if v_md then
      if v_ch.kind <> 'storefront' then perform rsa_err('ราคาลดตอนเย็นใช้ได้เฉพาะหน้าร้าน'); end if;
      if v_prod.markdown_price is null or v_prod.markdown_price >= v_price then perform rsa_err('"' || v_prod.name || '" ยังไม่ได้ตั้งราคาลดตอนเย็น'); end if;
      if not rsa_has(u, 'master.manage') and (v_md_from is null or to_char(v_at at time zone 'Asia/Bangkok', 'HH24:MI') < v_md_from) then
        perform rsa_err('ยังไม่ถึงเวลาลดราคา' || coalesce(' (เริ่ม ' || v_md_from || ' น.)', ' เจ้าของร้านยังไม่ได้ตั้งเวลา'));
      end if;
    end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('product_id', v_prod.id, 'qty', v_qty, 'price', v_price,
                 'gross', round(v_price * v_qty, 2), 'discount', rsa_num(it, 'discount', 0), 'markdown', v_md,
                 'md_price', case when v_md then v_prod.markdown_price end));
  end loop;

  -- bundle promotions ("buy N for P"): quantities of the eligible products are pooled across the order,
  -- the discount is spread over those lines by value
  for v_promo in select * from promotions pr
                  where pr.active and pr.rule = 'bundle' and coalesce(pr.buy_qty, 0) > 0 and pr.bundle_price is not null
                    and (pr.starts_at is null or pr.starts_at <= v_at) and (pr.ends_at is null or pr.ends_at > v_at)
                    and (cardinality(pr.channel_ids) = 0 or v_ch.id = any(pr.channel_ids))
                    and (not pr.storefront_only or v_ch.kind = 'storefront')
                  order by pr.created_at loop
    select array_agg(t.ord::int order by t.ord), coalesce(sum((t.l->>'qty')::numeric), 0), coalesce(sum((t.l->>'gross')::numeric), 0)
      into v_idx, v_pool_qty, v_pool_gross
      from jsonb_array_elements(v_lines) with ordinality t(l, ord)
     where not (v_bdisc ? (t.ord - 1)::text) and not coalesce((t.l->>'markdown')::boolean, false)
       and (v_promo.scope = 'all' or (t.l->>'product_id')::uuid = any(v_promo.product_ids));
    if v_pool_qty <= 0 then continue; end if;
    v_bundles := floor(v_pool_qty / v_promo.buy_qty);
    if v_bundles < 1 then continue; end if;
    v_bd := round(v_bundles * v_promo.buy_qty * v_pool_gross / v_pool_qty - v_bundles * v_promo.bundle_price, 2);
    if v_bd <= 0 then continue; end if;
    v_rest := v_bd;
    for k in 1 .. array_length(v_idx, 1) loop
      if k = array_length(v_idx, 1) then v_share := v_rest;
      else v_share := round(v_bd * ((v_lines->(v_idx[k] - 1))->>'gross')::numeric / v_pool_gross, 2); end if;
      v_rest := v_rest - v_share;
      v_bdisc := v_bdisc || jsonb_build_object((v_idx[k] - 1)::text, jsonb_build_object('discount', v_share, 'promo_id', v_promo.id,
                   'name', v_promo.name, 'rule', 'bundle', 'buy_qty', v_promo.buy_qty, 'bundle_price', v_promo.bundle_price,
                   'bundles', v_bundles, 'pooled_qty', v_pool_qty));
    end loop;
  end loop;

  insert into order_counters(biz_date, n) values (v_date, 1)
  on conflict (biz_date) do update set n = order_counters.n + 1 returning n into v_n;
  v_no := 'S' || to_char(v_date, 'YYMMDD') || '-' || lpad(v_n::text, 3, '0');

  insert into orders(id, order_no, client_ref, biz_date, created_at, channel_id, channel_name, channel_kind, payment_method, account_id,
                     subtotal, total, fee_pct, note, created_by, replaces_order_id)
  values (v_id, v_no, case when v_edit_of is null then nullif(p->>'client_ref', '') end, v_date, v_at, v_ch.id, v_ch.name, v_ch.kind, v_ch.payment_method,
          case when v_ch.kind = 'storefront' then v_ch.account_id end, 0, 0, v_ch.fee_pct,
          nullif(concat_ws(' · ', nullif(trim(p->>'note'), ''),
            case when v_edit_of is null and v_edit_at is null and v_at < now() - interval '1 minute'
                 then 'บันทึกตอนไม่มีสัญญาณ ส่งเข้าระบบ ' || to_char(now() at time zone 'Asia/Bangkok', 'DD/MM HH24:MI') end), ''),
          u.id, v_edit_of);

  -- pass 2: discounts, cost and stock per line
  i := 0;
  for ln in select * from jsonb_array_elements(v_lines) loop
    select * into v_prod from products where id = (ln->>'product_id')::uuid;
    v_qty := (ln->>'qty')::numeric; v_price := (ln->>'price')::numeric; v_gross := (ln->>'gross')::numeric;
    v_pdisc := 0; v_promo_id := null; v_snap := null;
    if coalesce((ln->>'markdown')::boolean, false) then
      v_pdisc := round((v_price - (ln->>'md_price')::numeric) * v_qty, 2);
      v_snap := jsonb_build_object('name', 'ลดราคาตอนเย็น', 'rule', 'markdown', 'markdown_price', (ln->>'md_price')::numeric, 'promo_discount', v_pdisc);
    elsif v_bdisc ? i::text then
      v_pdisc := ((v_bdisc->i::text)->>'discount')::numeric;
      v_promo_id := ((v_bdisc->i::text)->>'promo_id')::uuid;
      v_snap := (v_bdisc->i::text) - 'discount' - 'promo_id' || jsonb_build_object('promo_discount', v_pdisc);
    else
      select * into v_promo from promotions pr
       where pr.active and pr.rule in ('percent','amount_each')
         and (pr.starts_at is null or pr.starts_at <= v_at) and (pr.ends_at is null or pr.ends_at > v_at)
         and (pr.scope = 'all' or v_prod.id = any(pr.product_ids))
         and (cardinality(pr.channel_ids) = 0 or v_ch.id = any(pr.channel_ids))
         and (not pr.storefront_only or v_ch.kind = 'storefront')
         and v_qty >= pr.min_qty
       order by case pr.rule when 'percent' then round(v_gross * pr.value / 100, 2) else least(pr.value, v_price) * v_qty end desc
       limit 1;
      if found then
        v_pdisc := case v_promo.rule when 'percent' then round(v_gross * v_promo.value / 100, 2) else round(least(v_promo.value, v_price) * v_qty, 2) end;
        v_promo_id := v_promo.id;
        v_snap := jsonb_build_object('name', v_promo.name, 'rule', v_promo.rule, 'value', v_promo.value, 'promo_discount', v_pdisc);
      end if;
    end if;
    v_mdisc := least(greatest(coalesce((ln->>'discount')::numeric, 0), 0), v_gross - v_pdisc);
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
    values (v_item_id, v_id, v_prod.id, v_prod.name, v_prod.sku, v_prod.unit, v_qty, v_price, v_pdisc + v_mdisc, v_promo_id,
            case when v_snap is not null or v_mdisc > 0 then coalesce(v_snap, '{}'::jsonb)
                 || case when v_mdisc > 0 then jsonb_build_object('manual_discount', v_mdisc) else '{}'::jsonb end end,
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
    i := i + 1;
  end loop;

  -- the amount actually received may differ from the computed total (rounding, short payment); it needs a reason
  v_calc := v_sub - v_disc;
  v_recv := coalesce(rsa_num(p, 'received_amount'), v_calc);
  if v_recv < 0 then perform rsa_err('ยอดรับจริงติดลบไม่ได้'); end if;
  if v_recv <> v_calc and coalesce(trim(p->>'received_note'), '') = '' then
    perform rsa_err('ยอดรับจริง (' || v_recv || ') ไม่เท่ากับยอดคำนวณ (' || v_calc || ' บาท) กรุณาใส่เหตุผล');
  end if;
  v_total := v_recv;
  update orders set subtotal = v_sub, discount = v_disc, calc_total = v_calc, total = v_total,
         received_note = case when v_recv <> v_calc then trim(p->>'received_note') end,
         cost_total = round(v_cost, 2), cost_complete = v_cost_ok,
         est_fee = case when v_ch.kind = 'delivery' then round(v_total * v_ch.fee_pct / 100, 2) else 0 end
   where id = v_id;

  -- money in: one row per payment (split cash + QR in one bill), or the channel's account
  if v_ch.kind = 'storefront' then
    v_pays := case when jsonb_typeof(p->'payments') = 'array' and jsonb_array_length(p->'payments') > 0 then p->'payments'
                   else jsonb_build_array(jsonb_build_object('account_id', v_ch.account_id, 'amount', v_total)) end;
    for v_pay in select * from jsonb_array_elements(v_pays) loop
      select * into v_pacc from payment_accounts where id = rsa_uuid(v_pay, 'account_id') and active;
      if not found then perform rsa_err('กรุณาเลือกบัญชีรับเงินของการจ่ายแต่ละส่วน'); end if;
      if rsa_num(v_pay, 'amount', 0) < 0 then perform rsa_err('ยอดจ่ายแต่ละส่วนติดลบไม่ได้'); end if;
      v_psum := v_psum + rsa_num(v_pay, 'amount', 0);
    end loop;
    if v_psum <> v_total then perform rsa_err('ยอดจ่ายรวม (' || v_psum || ') ไม่เท่ากับยอดรับจริง (' || v_total || ' บาท)'); end if;
    for v_pay in select * from jsonb_array_elements(v_pays) loop
      select * into v_pacc from payment_accounts where id = rsa_uuid(v_pay, 'account_id');
      if rsa_num(v_pay, 'amount', 0) > 0 then
        insert into order_payments(order_id, account_id, method, amount)
        values (v_id, v_pacc.id, case v_pacc.kind when 'cash' then 'cash' else 'qr' end, rsa_num(v_pay, 'amount', 0));
        perform rsa_money(v_pacc.id, 'in', rsa_num(v_pay, 'amount', 0), 'order', v_id, v_no, u.id, v_at);
      end if;
    end loop;
    if (select count(*) from order_payments where order_id = v_id) > 1 then
      update orders set payment_method = 'mixed',
             account_id = (select account_id from order_payments where order_id = v_id order by amount desc limit 1) where id = v_id;
    elsif exists (select 1 from order_payments where order_id = v_id and account_id is distinct from v_ch.account_id) then
      update orders set account_id = (select account_id from order_payments where order_id = v_id) where id = v_id;
    end if;
  end if;
  perform rsa_audit(u, 'order.create', 'order', v_id::text, null,
    jsonb_build_object('order_no', v_no, 'total', v_total, 'calc_total', v_calc, 'channel', v_ch.name, 'replaces', v_edit_of));
  return rsa_order_json(v_id);
end $$;

-- reverse money and stock of an order (cancel or edit); caller checks permission
create or replace function rsa_order_void(u app_users, v orders, p_reason text, p_replaced_by uuid default null) returns void language plpgsql as $$
declare v_amt numeric := v.total - v.refunded; r record;
begin
  update orders set status = 'cancelled', cancelled_at = now(), cancelled_by = u.id, cancel_reason = p_reason, replaced_by = p_replaced_by
   where id = v.id;
  insert into order_events(order_id, kind, amount, reason, account_id, created_by)
  values (v.id, 'cancel', v_amt, p_reason, v.account_id, u.id);
  -- give back what each account still holds for this order (split payments go back to where they came from)
  for r in select account_id, sum(case direction when 'in' then amount else -amount end) amt from money_ledger
            where source_id = v.id and source_type in ('order','order_refund') group by account_id loop
    if r.amt > 0 then
      perform rsa_money(r.account_id, 'out', r.amt, 'order_refund', v.id,
        case when p_replaced_by is null then 'ยกเลิก ' else 'แก้ไข ' end || v.order_no, u.id);
    end if;
  end loop;
  for r in select sl.* from stock_ledger sl join order_items i on i.id = sl.source_id
            where sl.source_type = 'order_item' and sl.kind = 'sale' and i.order_id = v.id loop
    insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
    values (r.stock_item_id, -r.qty, 'sale_reversal', 'order_item', r.source_id, r.unit_cost, u.id);
  end loop;
end $$;

create or replace function rsa__order_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v orders;
begin
  perform rsa_need(u, 'sales.add');
  select * into v from orders where id = rsa_uuid(p, 'order_id') for update;
  if not found then perform rsa_err('ไม่พบออเดอร์'); end if;
  if not rsa_order_can_edit(u, v) then perform rsa_need(u, 'sales.cancel'); end if;
  if v.status = 'cancelled' then perform rsa_err('ออเดอร์นี้ยกเลิกไปแล้ว'); end if;
  if v.settlement_id is not null then perform rsa_err('ออเดอร์นี้รับเงินจากแพลตฟอร์มแล้ว ให้ใช้การคืนเงินแทน'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  perform rsa_order_void(u, v, trim(p->>'reason'));
  perform rsa_audit(u, 'order.cancel', 'order', v.id::text, jsonb_build_object('status', v.status, 'total', v.total),
                    jsonb_build_object('status', 'cancelled', 'amount', v.total - v.refunded), jsonb_build_object('reason', p->>'reason', 'order_no', v.order_no,
                    'after_close', exists (select 1 from daily_closes where biz_date = v.biz_date)));
  return rsa_order_json(v.id);
end $$;

-- Edit = cancel the old order and record a corrected one with the same time; both stay in history.
create or replace function rsa__order_update(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v orders; v_new jsonb; v_reason text := trim(coalesce(p->>'reason', ''));
begin
  perform rsa_need(u, 'sales.add');
  select * into v from orders where id = rsa_uuid(p, 'order_id') for update;
  if not found then perform rsa_err('ไม่พบออเดอร์'); end if;
  if v.status = 'cancelled' then perform rsa_err('ออเดอร์นี้ถูกยกเลิกหรือแก้ไขไปแล้ว'); end if;
  if v.settlement_id is not null then perform rsa_err('ออเดอร์นี้รับเงินจากแพลตฟอร์มแล้ว แก้ไขไม่ได้'); end if;
  if v.refunded > 0 then perform rsa_err('ออเดอร์นี้มีการคืนเงินแล้ว แก้ไขไม่ได้'); end if;
  if exists (select 1 from daily_closes where biz_date = v.biz_date) then
    perform rsa_err('วันที่ ' || to_char(v.biz_date, 'DD/MM') || ' ส่งรายงานปิดยอดแล้ว แก้ไขออเดอร์ไม่ได้ ให้ยกเลิกแล้วแจ้งเจ้าของร้าน');
  end if;
  if not rsa_order_can_edit(u, v) then perform rsa_err('แก้ไขได้เฉพาะออเดอร์ของตัวเองในวันนี้ ถ้าต้องแก้รายการอื่นให้แจ้งเจ้าของร้าน'); end if;
  if v_reason = '' then perform rsa_err('กรุณาระบุเหตุผลการแก้ไข'); end if;
  perform set_config('rsa.edit_at', v.created_at::text, true);
  perform set_config('rsa.edit_of', v.id::text, true);
  v_new := rsa__order_create(u, p - 'order_id' - 'reason' - 'client_ref' - 'offline_at');
  perform set_config('rsa.edit_at', '', true);
  perform set_config('rsa.edit_of', '', true);
  perform rsa_order_void(u, v, 'แก้ไขเป็น ' || (v_new->>'order_no') || ': ' || v_reason, (v_new->>'id')::uuid);
  perform rsa_audit(u, 'order.update', 'order', v.id::text,
    jsonb_build_object('order_no', v.order_no, 'total', v.total, 'channel', v.channel_name,
      'items', (select jsonb_agg(jsonb_build_object('product', product_name, 'qty', qty, 'line_total', line_total)) from order_items where order_id = v.id)),
    jsonb_build_object('order_no', v_new->>'order_no', 'total', (v_new->>'total')::numeric, 'channel', v_new->>'channel_name',
      'items', (select jsonb_agg(jsonb_build_object('product', product_name, 'qty', qty, 'line_total', line_total)) from order_items where order_id = (v_new->>'id')::uuid)),
    jsonb_build_object('reason', v_reason));
  return rsa_order_json((v_new->>'id')::uuid);
end $$;

-- ---------------------------------------------------------------- waste (by product through its recipe, or by stock item)
create or replace function rsa_waste_insert(u app_users, p jsonb, p_close uuid default null) returns uuid language plpgsql as $$
declare v_item stock_items; v_prod products; v_id uuid := gen_random_uuid(); v_qty numeric := rsa_num(p, 'qty', 0);
        v_at timestamptz := rsa_ts(p, 'occurred_at'); v_cost numeric; r record;
        -- waste = spoiled/lost (a cost) · staff_meal = staff ate it (welfare expense) · owner_use = owner took it (owner drawing, not a shop cost)
        v_kind text := coalesce(nullif(p->>'kind', ''), 'waste'); v_for uuid := rsa_uuid(p, 'for_user_id'); v_reason text;
begin
  perform rsa_need(u, 'waste.add');
  if v_kind not in ('waste','staff_meal','owner_use') then perform rsa_err('ประเภทรายการไม่ถูกต้อง'); end if;
  if v_qty <= 0 then perform rsa_err('จำนวนต้องมากกว่า 0'); end if;
  v_reason := coalesce(nullif(trim(p->>'reason'), ''), case v_kind when 'staff_meal' then 'สวัสดิการทีมงาน' when 'owner_use' then 'เจ้าของหยิบใช้' end);
  if v_reason is null then perform rsa_err('กรุณาระบุสาเหตุของเสีย'); end if;
  if v_for is not null and not exists (select 1 from app_users where id = v_for) then perform rsa_err('ไม่พบพนักงาน'); end if;
  if v_kind <> 'staff_meal' then v_for := null; end if;
  if v_kind = 'waste' and rsa_setting_bool('waste_evidence_required') and not rsa_has_files(p) then
    perform rsa_err('ร้านกำหนดให้แนบรูปของเสียทุกครั้ง');
  end if;
  if rsa_uuid(p, 'product_id') is not null then
    select * into v_prod from products where id = rsa_uuid(p, 'product_id');
    if not found then perform rsa_err('ไม่พบสินค้า'); end if;
    select sum(rl.qty * s.avg_cost) into v_cost from recipe_lines rl join stock_items s on s.id = rl.stock_item_id where rl.product_id = v_prod.id;
    insert into waste_records(id, product_id, item_name, unit, qty, reason, unit_cost, occurred_at, biz_date, created_by, close_id, kind, for_user_id)
    values (v_id, v_prod.id, v_prod.name, v_prod.unit, v_qty, v_reason, coalesce(v_cost, v_prod.est_cost, 0), v_at, rsa_bdate(v_at), u.id, p_close, v_kind, v_for);
    for r in select rl.stock_item_id, rl.qty, s.avg_cost from recipe_lines rl join stock_items s on s.id = rl.stock_item_id where rl.product_id = v_prod.id loop
      insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
      values (r.stock_item_id, v_at, -(r.qty * v_qty), 'waste', 'waste', v_id, r.avg_cost, u.id);
    end loop;
  else
    select * into v_item from stock_items where id = rsa_uuid(p, 'stock_item_id') and active;
    if not found then perform rsa_err('กรุณาเลือกรายการที่เสีย'); end if;
    insert into waste_records(id, stock_item_id, item_name, unit, qty, reason, unit_cost, occurred_at, biz_date, created_by, close_id, kind, for_user_id)
    values (v_id, v_item.id, v_item.name, v_item.unit, v_qty, v_reason, v_item.avg_cost, v_at, rsa_bdate(v_at), u.id, p_close, v_kind, v_for);
    insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
    values (v_item.id, v_at, -v_qty, 'waste', 'waste', v_id, v_item.avg_cost, u.id);
  end if;
  perform rsa_link_attachments(p->'attachment_ids', 'waste', v_id, u);
  perform rsa_audit(u, 'waste.create', 'waste', v_id::text, null,
    jsonb_build_object('item', coalesce(v_prod.name, v_item.name), 'qty', v_qty, 'reason', v_reason, 'kind', v_kind, 'close_id', p_close));
  return v_id;
end $$;

create or replace function rsa__waste_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid;
begin
  v_id := rsa_waste_insert(u, p);
  return jsonb_build_object('id', v_id);
end $$;

create or replace function rsa__waste_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v waste_records; r record;
begin
  perform rsa_need(u, 'stock.cancel');
  select * into v from waste_records where id = rsa_uuid(p, 'waste_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update waste_records set status = 'cancelled', cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  for r in select * from stock_ledger where source_type = 'waste' and source_id = v.id and kind = 'waste' loop
    insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
    values (r.stock_item_id, -r.qty, 'waste_reversal', 'waste', v.id, r.unit_cost, u.id);
  end loop;
  perform rsa_audit(u, 'waste.cancel', 'waste', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- expenses with fund source
-- fund_source: shop_cash | shop_bank | other_account | owner_advance | employee_advance | owner_capital | credit
-- (older clients may still send pay_mode: drawer | account | employee | later)
create or replace function rsa_expense_insert(u app_users, p jsonb, p_receipt uuid default null) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid(); v_cat expense_categories; v_status text; v_acc uuid; v_emp uuid; v_owner boolean := false;
  v_amt numeric := rsa_num(p, 'amount', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
  v_is_mgr boolean := rsa_has(u, 'expense.approve'); v_no text := rsa_next_no('E');
  v_src text := coalesce(nullif(p->>'fund_source', ''), case p->>'pay_mode' when 'drawer' then 'shop_cash' when 'account' then 'other_account'
                  when 'employee' then 'employee_advance' when 'later' then 'credit' end, 'credit');
  v_ref text := nullif(trim(coalesce(p->>'pay_ref', '')), ''); v_reviewed boolean := false;
begin
  perform rsa_need(u, 'expense.add');
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if coalesce(trim(p->>'description'), '') = '' then perform rsa_err('กรุณาระบุรายละเอียดค่าใช้จ่าย'); end if;
  select * into v_cat from expense_categories where id = rsa_uuid(p, 'category_id') and active;
  if not found then perform rsa_err('กรุณาเลือกหมวดค่าใช้จ่าย'); end if;
  if not v_is_mgr and not v_cat.staff_allowed then perform rsa_err('หมวด "' || v_cat.name || '" ต้องให้เจ้าของร้านบันทึก'); end if;
  if v_cat.grp = 'C' and coalesce(v_cat.c_kind, '') <> 'advance' then
    perform rsa_err('"' || v_cat.name || '" ไม่ใช่ค่าใช้จ่าย จึงไม่นับในกำไร บันทึกที่หน้า เงิน (ชำระหนี้ / เงินเติมจากเจ้าของ / เงินลงทุน / ประกาศใช้กำไร)');
  end if;
  if p_receipt is null and v_src <> 'credit' and rsa_setting_bool('evidence_required') and not rsa_has_files(p) then
    perform rsa_err('ร้านกำหนดให้แนบหลักฐานทุกครั้ง (ใบเสร็จ / สลิป / รูปบิล)');
  end if;

  if v_src = 'shop_cash' then
    v_acc := rsa_drawer(); v_status := 'จ่ายแล้ว';
    if v_acc is null then perform rsa_err('ยังไม่ได้ตั้งบัญชีลิ้นชักเงินสด'); end if;
  elsif v_src in ('shop_bank', 'other_account') then
    if v_src = 'other_account' then perform rsa_need(u, 'expense.pay'); end if;
    v_acc := coalesce(rsa_uuid(p, 'account_id'),
               case when v_src = 'shop_bank' then (select id from payment_accounts where active and kind = 'bank' order by created_at limit 1) end);
    if v_acc is null then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
    if not rsa_has(u, 'expense.pay') and v_acc is distinct from (select id from payment_accounts where active and kind = 'bank' order by created_at limit 1) then
      perform rsa_err('พนักงานเลือกจ่ายได้จากบัญชีร้านหลักเท่านั้น');
    end if;
    if v_ref is null then perform rsa_err('จ่ายผ่านบัญชีต้องใส่เลขอ้างอิง / เลขที่สลิป'); end if;
    v_status := 'จ่ายแล้ว';
  elsif v_src = 'employee_advance' then
    v_emp := coalesce(rsa_uuid(p, 'employee_id'), u.id);
    v_status := case when v_is_mgr then 'รอทำจ่าย' else 'รออนุมัติ' end;
  elsif v_src = 'owner_advance' then
    v_owner := true;
    v_status := case when v_is_mgr then 'รอทำจ่าย' else 'รออนุมัติ' end;
  elsif v_src = 'owner_capital' then
    perform rsa_need(u, 'cashflow.manage');
    v_status := 'จ่ายแล้ว';
  elsif v_src = 'credit' then
    v_status := case when v_is_mgr and coalesce((p->>'approve')::boolean, true) then 'รอทำจ่าย' else 'รออนุมัติ' end;
  else
    perform rsa_err('แหล่งเงินไม่ถูกต้อง');
  end if;
  v_reviewed := v_status = 'จ่ายแล้ว' and v_is_mgr;

  insert into expenses(id, expense_no, occurred_at, due_date, category_id, category_name, tax_category, payee, supplier_id, description, amount,
    status, pay_account_id, paid_by_employee, paid_by_owner, fund_source, pay_ref, doc_type, doc_no, ocr_snapshot, receipt_id, reviewed, created_by,
    approved_at, approved_by, paid_at, paid_by)
  values (v_id, v_no, v_at, nullif(p->>'due_date', '')::date, v_cat.id, v_cat.name, v_cat.tax_category, nullif(trim(p->>'payee'), ''),
    rsa_uuid(p, 'supplier_id'), trim(p->>'description'), v_amt, v_status, v_acc, v_emp, v_owner, v_src, v_ref,
    nullif(p->>'doc_type', ''), nullif(p->>'doc_no', ''),
    case when jsonb_typeof(p->'ocr_snapshot') = 'object' then p->'ocr_snapshot' end, p_receipt, v_reviewed, u.id,
    case when v_status = 'รอทำจ่าย' or v_reviewed then now() end,
    case when v_status = 'รอทำจ่าย' or v_reviewed then u.id end,
    case when v_status = 'จ่ายแล้ว' then v_at end,
    case when v_status = 'จ่ายแล้ว' then u.id end);

  if v_status = 'จ่ายแล้ว' and v_acc is not null then
    perform rsa_money(v_acc, 'out', v_amt, 'expense', v_id, trim(p->>'description'), u.id, v_at);
  end if;
  if v_cat.tax_category = 'เงินเบิกล่วงหน้าพนักงาน' then
    -- a wage advance: money leaves now, the cost is recognised when the weekly wage is paid
    if rsa_uuid(p, 'advance_user_id') is null or not exists (select 1 from app_users where id = rsa_uuid(p, 'advance_user_id')) then
      perform rsa_err('เบิกค่าแรงล่วงหน้า กรุณาเลือกพนักงานที่เบิก');
    end if;
    if v_status <> 'จ่ายแล้ว' then perform rsa_err('เบิกค่าแรงล่วงหน้าต้องจ่ายจากเงินสดหรือบัญชีร้าน'); end if;
    update expenses set advance_user_id = rsa_uuid(p, 'advance_user_id') where id = v_id;
  end if;
  if v_src = 'owner_capital' then
    -- the owner paid and does not want it back: it becomes owner capital (no cash moved in the shop)
    insert into capital_entries(kind, party, amount, occurred_at, account_id, note, created_by, expense_id, category)
    values ('owner_paid', coalesce(nullif(trim(p->>'owner_name'), ''), 'เจ้าของ'), v_amt, v_at, null, 'เจ้าของจ่ายแทนร้าน ' || v_no, u.id, v_id, 'จ่ายแทนร้าน');
  end if;
  perform rsa_link_attachments(p->'attachment_ids', 'expense', v_id, u);
  perform rsa_audit(u, 'expense.create', 'expense', v_id::text, null,
    jsonb_build_object('amount', v_amt, 'status', v_status, 'fund_source', v_src, 'category', v_cat.name));
  return v_id;
end $$;

create or replace function rsa_expense_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(e) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = e.created_by),
    'approved_by_name', (select display_name from app_users where id = e.approved_by),
    'paid_by_name', (select display_name from app_users where id = e.paid_by),
    'employee_name', (select display_name from app_users where id = e.paid_by_employee),
    'owed_to', case when e.paid_by_employee is not null then (select display_name from app_users where id = e.paid_by_employee)
                    when e.paid_by_owner then 'เจ้าของ' end,
    'account_name', (select name from payment_accounts where id = e.pay_account_id),
    'attachments', rsa_attachment_refs('expense', e.id) || coalesce(rsa_attachment_refs('receipt', e.receipt_id), '[]'))
  from expenses e where e.id = p_id
$$;

create or replace function rsa__expense_pay(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v expenses; v_acc payment_accounts; v_at timestamptz := rsa_ts(p, 'paid_at'); v_ref text := nullif(trim(coalesce(p->>'pay_ref', '')), '');
begin
  perform rsa_need(u, 'expense.pay');
  select * into v from expenses where id = rsa_uuid(p, 'expense_id') for update;
  if not found then perform rsa_err('ไม่พบรายการ'); end if;
  if v.status = 'รออนุมัติ' then
    perform rsa_need(u, 'expense.approve');
  elsif v.status <> 'รอทำจ่าย' then
    perform rsa_err('รายการนี้จ่ายไม่ได้ (สถานะ ' || v.status || ')');
  end if;
  if v.fixed_expense_id is not null and v.tax_category = 'เงินเดือนและค่าจ้าง' then
    perform rsa_err('บิลค่าจ้างให้จ่ายที่หน้า พนักงาน / ค่าจ้าง (จ่ายตามวันทำงานจริง แล้วระบบปิดบิลนี้ให้)');
  end if;
  select * into v_acc from payment_accounts where id = rsa_uuid(p, 'account_id') and active;
  if not found then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
  if v_acc.kind <> 'cash' and v_ref is null then perform rsa_err('จ่ายผ่านบัญชีต้องใส่เลขอ้างอิง / เลขที่สลิป'); end if;
  update expenses set status = 'จ่ายแล้ว', pay_account_id = v_acc.id, paid_at = v_at, paid_by = u.id, reviewed = true,
         pay_ref = coalesce(v_ref, pay_ref),
         approved_at = coalesce(approved_at, now()), approved_by = coalesce(approved_by, u.id),
         reimbursed = (paid_by_employee is not null or paid_by_owner) where id = v.id;
  perform rsa_money(v_acc.id, 'out', v.amount, 'expense', v.id,
    case when v.paid_by_employee is not null then 'คืนเงินพนักงาน: ' when v.paid_by_owner then 'คืนเงินเจ้าของ: ' else '' end || v.description, u.id, v_at);
  perform rsa_link_attachments(p->'attachment_ids', 'expense', v.id, u);
  perform rsa_audit(u, 'expense.pay', 'expense', v.id::text, jsonb_build_object('status', v.status),
                    jsonb_build_object('status', 'จ่ายแล้ว', 'account_id', v_acc.id, 'amount', v.amount, 'pay_ref', v_ref));
  return rsa_expense_json(v.id);
end $$;

create or replace function rsa__expense_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v expenses;
begin
  select * into v from expenses where id = rsa_uuid(p, 'expense_id') for update;
  if not found or v.status = 'ยกเลิก' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if not (rsa_has(u, 'expense.cancel') or (v.created_by = u.id and v.status = 'รออนุมัติ')) then
    perform rsa_need(u, 'expense.cancel');
  end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  if exists (select 1 from payroll_runs r where r.expense_id = v.id and r.status = 'done') then
    perform rsa_err('รายการนี้เป็นค่าจ้างที่จ่ายจากวันทำงาน ให้ยกเลิกที่หน้า พนักงาน › ประวัติจ่ายค่าจ้าง');
  end if;
  if v.advance_run_id is not null then perform rsa_err('เงินเบิกนี้ถูกหักในรอบจ่ายค่าจ้างแล้ว ให้ยกเลิกรอบจ่ายค่าจ้างก่อน'); end if;
  update expenses set status = 'ยกเลิก', cancelled_at = now(), cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  if v.status = 'จ่ายแล้ว' and v.pay_account_id is not null then
    perform rsa_money(v.pay_account_id, 'in', v.amount, 'expense_reversal', v.id, 'กลับรายการ ' || v.expense_no, u.id);
  end if;
  update capital_entries set status = 'cancelled', cancelled_by = u.id, cancel_reason = 'ยกเลิกค่าใช้จ่าย ' || v.expense_no
   where expense_id = v.id and status = 'done';
  perform rsa_audit(u, 'expense.cancel', 'expense', v.id::text, jsonb_build_object('status', v.status, 'amount', v.amount),
                    jsonb_build_object('status', 'ยกเลิก'), jsonb_build_object('reason', p->>'reason'));
  return rsa_expense_json(v.id);
end $$;

-- fixed costs: only confirmed ones become bills; monthly on the due day, weekly on every set weekday of the month (never twice)
create or replace function rsa_fixed_generate(u app_users, p_month date) returns int language plpgsql as $$
declare f fixed_expenses; v_m0 date := date_trunc('month', p_month)::date; v_m1 date; v_due date; v_period text; n int := 0;
begin
  v_m1 := (v_m0 + interval '1 month - 1 day')::date;
  for f in select * from fixed_expenses where active and confirmed and amount > 0 and start_month <= v_m1 and (end_month is null or end_month >= v_m0) loop
    for v_due in
      select d::date from generate_series(v_m0, v_m1, interval '1 day') d
       where (f.frequency = 'weekly' and extract(dow from d) = f.weekday)
          or (f.frequency = 'monthly' and d::date = least(v_m0 + (f.due_day - 1), v_m1))
    loop
      if v_due < f.start_month or (f.end_month is not null and v_due > (date_trunc('month', f.end_month) + interval '1 month - 1 day')::date) then continue; end if;
      v_period := case when f.frequency = 'weekly' then to_char(v_due, 'YYYY-MM-DD') else to_char(v_m0, 'YYYY-MM') end;
      -- a wage bill whose week was already paid from the workdays screen is not needed (payroll replaces it the same way)
      if exists (select 1 from expense_categories c where c.id = f.category_id and c.tax_category = 'เงินเดือนและค่าจ้าง')
         and exists (select 1 from payroll_runs r where r.status = 'done' and v_due between r.period_from and r.period_to + 6) then continue; end if;
      insert into expenses(id, expense_no, occurred_at, due_date, category_id, category_name, tax_category, payee, description, amount, status,
                           pay_account_id, fixed_expense_id, period, fund_source, created_by, approved_at, approved_by)
      select gen_random_uuid(), rsa_next_no('E'), (v_due::timestamp + time '12:00') at time zone 'Asia/Bangkok', v_due, f.category_id, c.name, c.tax_category, f.payee,
             f.name || ' (' || case when f.frequency = 'weekly' then 'สัปดาห์ ' || to_char(v_due, 'DD/MM') else v_period end || ')', f.amount,
             case when f.auto_approve then 'รอทำจ่าย' else 'รออนุมัติ' end, f.account_id, f.id, v_period, 'credit', u.id,
             case when f.auto_approve then now() end, case when f.auto_approve then u.id end
        from (select 1) one left join expense_categories c on c.id = f.category_id
      on conflict (fixed_expense_id, period) do nothing;
      if found then n := n + 1; end if;
    end loop;
  end loop;
  if n > 0 then perform rsa_audit(u, 'fixed.generate', 'fixed_expense', to_char(v_m0, 'YYYY-MM'), null, jsonb_build_object('created', n)); end if;
  return n;
end $$;

-- ---------------------------------------------------------------- stock receiving with transport allocation
-- pay_method: shop_bank | shop_cash | credit | none ; payer: shop | owner | employee
create or replace function rsa_receipt_default_category(p jsonb) returns uuid language sql stable as $$
  select coalesce(nullif(p->>'category_id', '')::uuid, nullif(p->'expense'->>'category_id', '')::uuid,
    (select id from expense_categories where active and code = 'A00'),
    (select id from expense_categories where active and tax_category = 'ต้นทุนสินค้า' order by name limit 1))
$$;

create or replace function rsa__receipt_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_id uuid := gen_random_uuid(); ln jsonb; v_item stock_items; v_qty numeric; v_lt numeric; v_goods numeric := 0; v_basis numeric; v_bsum numeric := 0;
  v_trans numeric := greatest(rsa_num(p, 'transport_cost', 0), 0); v_method text := coalesce(nullif(p->>'transport_method', ''), rsa_setting('transport_method', '"value"') #>> '{}', 'value');
  v_cur numeric; v_sup suppliers; v_exp uuid; v_at timestamptz := rsa_ts(p, 'received_at'); v_alloc numeric; v_rest numeric; v_landed numeric;
  v_pay text := coalesce(nullif(p->>'pay_method', ''), 'none'); v_payer text := coalesce(nullif(p->>'payer', ''), 'shop'); v_src text;
  v_n int; k int := 0; r record;
begin
  perform rsa_need(u, 'stock.receive');
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then perform rsa_err('ใส่รายการรับของอย่างน้อย 1 รายการ'); end if;
  if v_method not in ('value','weight','equal') then v_method := 'value'; end if;
  if rsa_setting_bool('evidence_required') and not rsa_has_files(p) then
    perform rsa_err('ร้านกำหนดให้แนบหลักฐานทุกครั้ง (ใบเสร็จ / บิล / รูปของที่รับ)');
  end if;
  select * into v_sup from suppliers where id = rsa_uuid(p, 'supplier_id');
  insert into stock_receipts(id, receipt_no, supplier_id, supplier_name, ref_no, received_at, note, transport_cost, transport_method, pay_method, payer, created_by)
  values (v_id, rsa_next_no('R'), v_sup.id, coalesce(v_sup.name, nullif(trim(p->>'supplier_name'), '')), nullif(p->>'ref_no', ''), v_at,
          nullif(p->>'note', ''), v_trans, v_method, v_pay, v_payer, u.id);

  -- pass 1: lines at purchase price
  for ln in select * from jsonb_array_elements(p->'lines') loop
    select * into v_item from stock_items where id = rsa_uuid(ln, 'stock_item_id') and active;
    if not found then perform rsa_err('ไม่พบรายการสต็อก'); end if;
    v_qty := rsa_num(ln, 'qty', 0);
    if v_qty <= 0 then perform rsa_err('จำนวนรับเข้าของ "' || v_item.name || '" ต้องมากกว่า 0'); end if;
    v_lt := coalesce(rsa_num(ln, 'line_total'), round(v_qty * rsa_num(ln, 'unit_cost', 0), 2));
    if v_lt < 0 then perform rsa_err('ราคาติดลบไม่ได้'); end if;
    insert into stock_receipt_lines(receipt_id, stock_item_id, item_name, unit, qty, unit_cost, line_total, weight)
    values (v_id, v_item.id, v_item.name, v_item.unit, v_qty, round(v_lt / v_qty, 4), v_lt, rsa_num(ln, 'weight'));
    v_goods := v_goods + v_lt;
  end loop;

  -- pass 2: spread transport over the lines (value / weight / equal), then landed cost into the moving average
  select count(*), coalesce(sum(case v_method when 'value' then line_total when 'weight' then coalesce(weight, qty) else 1 end), 0)
    into v_n, v_bsum from stock_receipt_lines where receipt_id = v_id;
  if v_bsum <= 0 then v_method := 'equal'; v_bsum := v_n; end if;
  v_rest := v_trans;
  for r in select * from stock_receipt_lines where receipt_id = v_id order by id loop
    k := k + 1;
    v_basis := case v_method when 'value' then r.line_total when 'weight' then coalesce(r.weight, r.qty) else 1 end;
    v_alloc := case when k = v_n then v_rest else round(v_trans * v_basis / v_bsum, 2) end;
    v_rest := v_rest - v_alloc;
    v_landed := round((r.line_total + v_alloc) / r.qty, 4);
    update stock_receipt_lines set transport_alloc = v_alloc, landed_unit_cost = v_landed where id = r.id;
    select * into v_item from stock_items where id = r.stock_item_id for update;
    if v_landed > 0 then
      v_cur := greatest(rsa_stock_qty(v_item.id), 0);
      update stock_items set avg_cost = round((v_cur * avg_cost + r.qty * v_landed) / (v_cur + r.qty), 4) where id = v_item.id;
    end if;
    insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
    values (v_item.id, v_at, r.qty, 'receipt', 'receipt', v_id, v_landed, u.id);
  end loop;
  update stock_receipts set goods_cost = v_goods, total_cost = v_goods + v_trans where id = v_id;
  perform rsa_link_attachments(p->'attachment_ids', 'receipt', v_id, u);

  -- the bill for this purchase (older clients send an "expense" object with pay_mode)
  v_src := case when v_payer = 'owner' then 'owner_advance' when v_payer = 'employee' then 'employee_advance'
                when v_pay = 'shop_bank' then 'shop_bank' when v_pay = 'shop_cash' then 'shop_cash'
                when v_pay in ('credit', 'unpaid') then 'credit' end;
  if v_src is null and jsonb_typeof(p->'expense') = 'object' and coalesce(p->'expense'->>'pay_mode', 'none') <> 'none' then
    v_src := case p->'expense'->>'pay_mode' when 'drawer' then 'shop_cash' when 'account' then 'other_account'
                  when 'employee' then 'employee_advance' else 'credit' end;
  end if;
  if v_src is not null and v_goods + v_trans > 0 then
    -- purchases are the shop's real cost: split by the cost category of each stock item; transport goes to the travel category
    for r in
      select coalesce(s.cost_category_id, rsa_receipt_default_category(p)) cat_id, sum(l.line_total) amt, string_agg(l.item_name, ', ' order by l.item_name) names
        from stock_receipt_lines l join stock_items s on s.id = l.stock_item_id where l.receipt_id = v_id
       group by 1
      union all
      select coalesce((select id from expense_categories where active and code = 'A05'), rsa_receipt_default_category(p)), v_trans, 'ค่าขนส่ง / ค่าเดินทางซื้อของ'
       where v_trans > 0
    loop
      continue when r.amt <= 0;
      v_exp := rsa_expense_insert(u, coalesce(case when jsonb_typeof(p->'expense') = 'object' then p->'expense' end, '{}'::jsonb) || jsonb_build_object(
        'fund_source', v_src, 'amount', r.amt, 'occurred_at', v_at, 'supplier_id', v_sup.id,
        'payee', coalesce(v_sup.name, p->>'supplier_name'), 'pay_ref', p->>'pay_ref', 'account_id', p->>'account_id', 'employee_id', p->>'employee_id',
        'category_id', r.cat_id,
        'description', 'ซื้อของเข้าร้าน ' || coalesce(v_sup.name, p->>'supplier_name', '') || ': ' || left(r.names, 120),
        'doc_no', p->>'ref_no'), v_id);
      update stock_receipts set expense_id = coalesce(expense_id, v_exp) where id = v_id;
    end loop;
  end if;
  perform rsa_audit(u, 'receipt.create', 'receipt', v_id::text, null,
    jsonb_build_object('goods', v_goods, 'transport', v_trans, 'method', v_method, 'lines', jsonb_array_length(p->'lines'), 'expense_id', v_exp, 'fund_source', v_src));
  return rsa_receipt_json(v_id);
end $$;

-- ---------------------------------------------------------------- daily close (6 steps)
create or replace function rsa_close_compute(p_date date) returns jsonb language plpgsql stable as $$
declare v_drawer uuid := rsa_drawer(); v jsonb;
begin
  select jsonb_build_object(
    'biz_date', p_date,
    'drawer_account', v_drawer,
    'channels', (select coalesce(jsonb_agg(x order by x->>'sort'), '[]') from (
        select jsonb_build_object('channel_id', c.id, 'name', c.name, 'kind', c.kind, 'payment_method', c.payment_method, 'sort', lpad(c.sort_order::text, 4, '0'),
          'orders', count(o.id) filter (where o.status <> 'cancelled'),
          'gross', coalesce(sum(o.total) filter (where o.status <> 'cancelled'), 0),
          'refunded', coalesce(sum(o.refunded) filter (where o.status <> 'cancelled'), 0),
          'net', coalesce(sum(o.total - o.refunded) filter (where o.status <> 'cancelled'), 0),
          'est_fee', coalesce(sum(o.est_fee) filter (where o.status <> 'cancelled'), 0),
          'cancelled_orders', count(o.id) filter (where o.status = 'cancelled' and o.replaced_by is null),
          'cancelled_amount', coalesce(sum(o.total) filter (where o.status = 'cancelled' and o.replaced_by is null), 0),
          'edited_orders', count(o.id) filter (where o.replaced_by is not null)) x
        from channels c left join orders o on o.channel_id = c.id and o.biz_date = p_date
        where c.active or o.id is not null
        group by c.id) t),
    'products', (select coalesce(jsonb_agg(x order by x->>'sort'), '[]') from (
        select jsonb_build_object('product_id', pr.id, 'name', pr.name, 'emoji', pr.emoji, 'unit', pr.unit, 'category', pr.category,
          'sort', lpad(pr.sort_order::text, 4, '0') || pr.name,
          'storefront_qty', coalesce(sum(i.qty) filter (where o.channel_kind = 'storefront'), 0),
          'storefront_net', coalesce(sum(i.line_total) filter (where o.channel_kind = 'storefront'), 0),
          'delivery_qty', coalesce(sum(i.qty) filter (where o.channel_kind = 'delivery'), 0),
          'delivery_net', coalesce(sum(i.line_total) filter (where o.channel_kind = 'delivery'), 0)) x
        from products pr
        left join order_items i on i.product_id = pr.id
             and exists (select 1 from orders o2 where o2.id = i.order_id and o2.biz_date = p_date and o2.status <> 'cancelled')
        left join orders o on o.id = i.order_id
        where pr.active or i.id is not null
        group by pr.id) t),
    'total_net', (select coalesce(sum(total - refunded), 0) from orders where biz_date = p_date and status <> 'cancelled'),
    'orders_count', (select count(*) from orders where biz_date = p_date and status <> 'cancelled'),
    'storefront_net', (select coalesce(sum(total - refunded), 0) from orders where biz_date = p_date and status <> 'cancelled' and channel_kind = 'storefront'),
    'delivery_net', (select coalesce(sum(total - refunded), 0) from orders where biz_date = p_date and status <> 'cancelled' and channel_kind = 'delivery'),
    -- money that went to accounts other than the drawer (QR / transfer), including the QR part of split bills
    'qr_sales', (select coalesce(sum(case m.direction when 'in' then m.amount else -m.amount end), 0)
                   from money_ledger m join orders o on o.id = m.source_id
                  where m.source_type in ('order','order_refund') and o.biz_date = p_date and o.channel_kind = 'storefront'
                    and m.account_id is distinct from v_drawer),
    'starting_cash', rsa_account_balance(v_drawer, p_date),
    'cash_in_orders', (select coalesce(sum(amount), 0) from money_ledger where account_id = v_drawer and biz_date = p_date and direction = 'in' and source_type = 'order'),
    'cash_out_refunds', (select coalesce(sum(amount), 0) from money_ledger where account_id = v_drawer and biz_date = p_date and direction = 'out' and source_type = 'order_refund'),
    'cash_out_expenses', (select coalesce(sum(case direction when 'out' then amount else -amount end), 0) from money_ledger
                           where account_id = v_drawer and biz_date = p_date and source_type in ('expense','expense_reversal')),
    'cash_transfers_net_out', (select coalesce(sum(case direction when 'out' then amount else -amount end), 0) from money_ledger
                           where account_id = v_drawer and biz_date = p_date and source_type in ('transfer','capital','profit')),
    'cash_other_adjust', (select coalesce(sum(case direction when 'in' then amount else -amount end), 0) from money_ledger
                           where account_id = v_drawer and biz_date = p_date and source_type in ('adjustment','settlement')),
    'expense_rows', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'expense_no', e.expense_no, 'description', e.description,
                        'amount', e.amount, 'status', e.status, 'by', (select display_name from app_users where id = e.created_by)) order by e.occurred_at), '[]')
                      from expenses e where e.pay_account_id = v_drawer and e.status = 'จ่ายแล้ว' and rsa_bdate(e.paid_at) = p_date),
    'advance_rows', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'expense_no', e.expense_no, 'description', e.description,
                        'amount', e.amount, 'status', e.status, 'owed_to', coalesce((select display_name from app_users where id = e.paid_by_employee), 'เจ้าของ'))
                        order by e.occurred_at), '[]')
                      from expenses e where (e.paid_by_employee is not null or e.paid_by_owner) and e.status <> 'ยกเลิก' and rsa_bdate(e.occurred_at) = p_date),
    'waste_rows', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'item_name', w.item_name, 'product_id', w.product_id, 'qty', w.qty, 'unit', w.unit,
                        'reason', w.reason, 'kind', w.kind, 'status', w.status, 'cost', round(w.qty * w.unit_cost, 2)) order by w.occurred_at), '[]')
                      from waste_records w where w.biz_date = p_date and w.status = 'recorded')
  ) into v;
  return v || jsonb_build_object('expected_cash',
     (v->>'starting_cash')::numeric + (v->>'cash_in_orders')::numeric - (v->>'cash_out_refunds')::numeric
     - (v->>'cash_out_expenses')::numeric - (v->>'cash_transfers_net_out')::numeric + (v->>'cash_other_adjust')::numeric);
end $$;

create or replace function rsa__close_preview(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_date date := rsa_date(p, 'date'); v_close uuid;
begin
  if not (rsa_has(u, 'closing.add') or rsa_has(u, 'closing.view_all')) then perform rsa_need(u, 'closing.add'); end if;
  select id into v_close from daily_closes where biz_date = v_date;
  return jsonb_build_object('computed', rsa_close_compute(v_date),
    'close', case when v_close is not null then rsa_close_json(v_close) end,
    'stock', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'unit', s.unit, 'code', s.code,
                'system_qty', rsa_stock_qty(s.id)) order by s.code nulls last, s.name), '[]')
                from stock_items s where s.active),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind) order by a.kind, a.name), '[]')
                from payment_accounts a where a.active and not a.is_drawer),
    'due_time', coalesce(rsa_setting('close_due_time') #>> '{}', '21:00'),
    'close_time', coalesce(rsa_setting('close_time') #>> '{}', '20:00'),
    'reminders', coalesce(rsa_setting('reminder_times'), '[]'),
    'tolerance', rsa_setting_num('cash_variance_tolerance', 0),
    'float', rsa_setting_num('starting_float', 0),
    'waste_reasons', coalesce(rsa_setting('waste_reasons'), '["เสีย/เน่า","หล่น/เสียหาย","เหลือขายไม่หมด","ทดลองชิม","อื่น ๆ"]'));
end $$;

create or replace function rsa__close_submit(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_date date := rsa_date(p, 'date'); c jsonb; v_id uuid := gen_random_uuid(); v_start numeric; v_sys_start numeric;
  v_counted numeric := rsa_num(p, 'counted_cash'); v_expected numeric; v_var numeric; v_adj numeric; v_st uuid;
  v_tol numeric := rsa_setting_num('cash_variance_tolerance', 0);
  v_due text := coalesce(rsa_setting('close_due_time') #>> '{}', '21:00');
  v_adjs jsonb := coalesce(p->'adjustments', '[]');
  v_removed numeric := greatest(rsa_num(p, 'cash_removed', 0), 0); v_to payment_accounts; v_tr uuid; v_tr_at timestamptz;
  v_cash_sys numeric; v_cash_rep numeric; v_qr_rep numeric; ln jsonb; v_pc jsonb := '[]'; v_dc jsonb := '[]'; v_on_time boolean; x jsonb;
begin
  perform rsa_need(u, 'closing.add');
  perform pg_advisory_xact_lock(hashtext('close' || v_date));
  if exists (select 1 from daily_closes where biz_date = v_date) then
    perform rsa_err('วันที่ ' || to_char(v_date, 'DD/MM/YYYY') || ' ส่งรายงานปิดยอดแล้ว หากต้องแก้ไขให้เจ้าของร้านแก้ในหน้าประวัติ');
  end if;
  if v_date > rsa_today() then perform rsa_err('ยังปิดยอดล่วงหน้าไม่ได้'); end if;
  if v_counted is null or v_counted < 0 then perform rsa_err('กรุณาใส่ยอดเงินสดที่นับได้จริง'); end if;

  -- step 3: waste found at closing becomes waste records (stock is cut now)
  for ln in select * from jsonb_array_elements(coalesce(p->'waste_lines', '[]')) loop
    if rsa_num(ln, 'qty', 0) > 0 then perform rsa_waste_insert(u, ln || jsonb_build_object('occurred_at',
         case when v_date < rsa_today() then (v_date + time '23:59')::timestamp at time zone 'Asia/Bangkok' else now() end), v_id); end if;
  end loop;

  -- step 5 (part): cash taken out of the shop is a transfer to a named account, never money that just disappears
  if v_removed > 0 then
    select * into v_to from payment_accounts where id = rsa_uuid(p, 'cash_removed_to') and active and not is_drawer;
    if not found then perform rsa_err('เงินสดนำออก ' || v_removed || ' บาท กรุณาเลือกว่านำไปเข้าบัญชีไหน'); end if;
    v_tr := gen_random_uuid();
    v_tr_at := case when v_date < rsa_today() then (v_date + time '23:59')::timestamp at time zone 'Asia/Bangkok' else now() end;
    insert into transfers(id, from_account, to_account, amount, occurred_at, reason, created_by)
    values (v_tr, rsa_drawer(), v_to.id, v_removed, v_tr_at,
            'นำเงินสดออกตอนปิดยอด ' || to_char(v_date, 'DD/MM/YYYY') || coalesce(' · ' || nullif(trim(p->>'cash_removed_note'), ''), ''), u.id);
    perform rsa_money(rsa_drawer(), 'out', v_removed, 'transfer', v_tr, 'นำเงินสดออก → ' || v_to.name, u.id, v_tr_at);
    perform rsa_money(v_to.id, 'in', v_removed, 'transfer', v_tr, 'เงินสดจากหน้าร้าน ' || to_char(v_date, 'DD/MM'), u.id, v_tr_at);
  end if;

  c := rsa_close_compute(v_date);
  v_sys_start := (c->>'starting_cash')::numeric;
  v_start := coalesce(rsa_num(p, 'starting_cash'), v_sys_start);
  if v_start <> v_sys_start then
    if coalesce(trim(p->>'starting_cash_reason'), '') = '' then perform rsa_err('แก้เงินทอนต้นวันต้องใส่เหตุผล'); end if;
    v_adjs := v_adjs || jsonb_build_array(jsonb_build_object('field', 'starting_cash', 'label', 'เงินทอนต้นวัน',
               'original', v_sys_start, 'corrected', v_start, 'reason', p->>'starting_cash_reason'));
  end if;
  -- step 5: cash the customers paid; a correction to the system figure is kept with its reason
  -- net of cancellations / refunds paid back in cash, i.e. what customers really left in the drawer
  v_cash_sys := (c->>'cash_in_orders')::numeric - (c->>'cash_out_refunds')::numeric;
  v_cash_rep := coalesce(rsa_num(p, 'cash_sales'), v_cash_sys);
  if v_cash_rep <> v_cash_sys then
    if coalesce(trim(p->>'cash_sales_reason'), '') = '' then perform rsa_err('ยอดเงินสดที่ลูกค้าจ่ายไม่ตรงกับออเดอร์ (' || v_cash_sys || ' บาท) กรุณาใส่เหตุผล'); end if;
    v_adjs := v_adjs || jsonb_build_array(jsonb_build_object('field', 'cash_sales', 'label', 'เงินสดที่ลูกค้าจ่าย',
               'original', v_cash_sys, 'corrected', v_cash_rep, 'reason', p->>'cash_sales_reason'));
  end if;
  v_qr_rep := rsa_num(p, 'qr_sales');
  if v_qr_rep is not null and v_qr_rep <> (c->>'qr_sales')::numeric then
    if coalesce(trim(p->>'qr_sales_reason'), '') = '' then perform rsa_err('ยอด QR / โอน ไม่ตรงกับออเดอร์ (' || (c->>'qr_sales') || ' บาท) กรุณาใส่เหตุผล'); end if;
    v_adjs := v_adjs || jsonb_build_array(jsonb_build_object('field', 'qr_sales', 'label', 'ยอด QR / โอน',
               'original', (c->>'qr_sales')::numeric, 'corrected', v_qr_rep, 'reason', p->>'qr_sales_reason'));
  end if;
  v_expected := (c->>'expected_cash')::numeric - v_sys_start + v_start - v_cash_sys + v_cash_rep;
  v_var := v_counted - v_expected;
  if abs(v_var) > v_tol and coalesce(trim(p->>'variance_reason'), '') = '' then
    perform rsa_err('เงินสด' || case when v_var < 0 then 'ขาด ' else 'เกิน ' end || abs(v_var) || ' บาท (เกินเกณฑ์ ' || v_tol || ' บาท) กรุณาใส่คำอธิบาย');
  end if;

  -- step 1 and 2: what staff counted per product (storefront) and per platform (delivery), next to the system figures
  for ln in select * from jsonb_array_elements(coalesce(p->'product_counts', '[]')) loop
    x := null;
    select x0 into x from jsonb_array_elements(c->'products') x0 where x0->>'product_id' = ln->>'product_id';
    if x is null or nullif(ln->>'counted_qty', '') is null then continue; end if;
    v_pc := v_pc || jsonb_build_array(jsonb_build_object('product_id', x->>'product_id', 'name', x->>'name', 'unit', x->>'unit',
              'system_qty', (x->>'storefront_qty')::numeric, 'counted_qty', rsa_num(ln, 'counted_qty'),
              'diff', rsa_num(ln, 'counted_qty') - (x->>'storefront_qty')::numeric, 'note', nullif(trim(ln->>'note'), '')));
  end loop;
  for ln in select * from jsonb_array_elements(coalesce(p->'delivery_counts', '[]')) loop
    x := null;
    select x0 into x from jsonb_array_elements(c->'channels') x0 where x0->>'channel_id' = ln->>'channel_id' and x0->>'kind' = 'delivery';
    if x is null then continue; end if;
    v_dc := v_dc || jsonb_build_array(jsonb_build_object('channel_id', x->>'channel_id', 'name', x->>'name',
              'system_orders', (x->>'orders')::int, 'app_orders', rsa_num(ln, 'orders'),
              'system_gross', (x->>'net')::numeric, 'app_gross', rsa_num(ln, 'gross'),
              'diff', coalesce(rsa_num(ln, 'gross'), (x->>'net')::numeric) - (x->>'net')::numeric, 'note', nullif(trim(ln->>'note'), '')));
  end loop;

  -- step 4: raw material counts go to the owner as a stocktake to approve
  if jsonb_typeof(p->'stock_counts') = 'array' and jsonb_array_length(p->'stock_counts') > 0 and rsa_has(u, 'stock.count') then
    v_st := rsa_stocktake_insert(u, 'close', p->'stock_counts', 'นับตอนปิดยอด ' || to_char(v_date, 'DD/MM/YYYY'), v_id);
  end if;

  v_on_time := v_date = rsa_today() and to_char(now() at time zone 'Asia/Bangkok', 'HH24:MI') <= v_due;

  insert into daily_closes(id, biz_date, submitted_by, coworker_ids, summary, starting_cash, cash_sales, cash_refunds, cash_expenses,
    cash_transfers_out, expected_cash, counted_cash, variance, variance_reason, stock_note, note, adjustments, stocktake_id,
    product_counts, delivery_counts, cash_detail, cash_removed, cash_removed_to, transfer_id, on_time)
  values (v_id, v_date, u.id,
    coalesce((select array_agg(distinct (x1)::uuid) from jsonb_array_elements_text(coalesce(p->'coworker_ids', '[]')) x1 where (x1)::uuid <> u.id), '{}'),
    c, v_start, v_cash_rep, (c->>'cash_out_refunds')::numeric, (c->>'cash_out_expenses')::numeric,
    (c->>'cash_transfers_net_out')::numeric, v_expected, v_counted, v_var, nullif(trim(p->>'variance_reason'), ''),
    nullif(p->>'stock_note', ''), nullif(trim(p->>'note'), ''), v_adjs, v_st, v_pc, v_dc,
    jsonb_build_object('cash_sales_system', v_cash_sys, 'cash_sales', v_cash_rep, 'qr_system', (c->>'qr_sales')::numeric, 'qr_sales', coalesce(v_qr_rep, (c->>'qr_sales')::numeric),
      'store_spent', (c->>'cash_out_expenses')::numeric, 'removed', v_removed, 'removed_to', v_to.name, 'removed_note', nullif(trim(p->>'cash_removed_note'), ''),
      'float', rsa_setting_num('starting_float', 0), 'tolerance', v_tol, 'due_time', v_due),
    v_removed, v_to.id, v_tr, v_on_time);

  -- The drawer balance follows the counted cash; the difference stays visible as an adjustment entry.
  v_adj := v_counted - (c->>'expected_cash')::numeric;
  if v_adj <> 0 then
    perform rsa_money((c->>'drawer_account')::uuid, case when v_adj > 0 then 'in' else 'out' end, abs(v_adj), 'adjustment', v_id,
      'ผลต่างเงินสดจากการปิดยอด ' || to_char(v_date, 'DD/MM/YYYY'), u.id, now());
    update money_ledger set biz_date = v_date where source_type = 'adjustment' and source_id = v_id;
  end if;
  perform rsa_audit(u, 'close.submit', 'daily_close', v_id::text, null,
    jsonb_build_object('biz_date', v_date, 'expected', v_expected, 'counted', v_counted, 'variance', v_var, 'removed', v_removed,
      'on_time', v_on_time, 'adjustments', v_adjs));
  return rsa_close_json(v_id);
end $$;

-- Workday rule: each submitted daily close counts one workday for the submitter and every co-worker named on it
-- (at most once per person per date). On time / late is counted for the person who submitted.
create or replace function rsa__close_workdays(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', date_trunc('month', rsa_today())::date); v_to date := rsa_date(p, 'to');
        v_all boolean := rsa_has(u, 'closing.view_all') and not coalesce((p->>'mine')::boolean, false);
begin
  if not (rsa_has(u, 'closing.add') or rsa_has(u, 'closing.view_all')) then perform rsa_need(u, 'closing.add'); end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('user_id', w.user_id, 'display_name', x.display_name, 'days', w.days, 'dates', w.dates,
                   'submitted', w.submitted, 'on_time', w.on_time, 'late', w.late, 'variance_days', w.variance_days) order by x.display_name), '[]')
    from (select user_id, count(distinct biz_date) days, jsonb_agg(distinct biz_date) dates,
                 count(*) filter (where is_submitter) submitted,
                 count(*) filter (where is_submitter and on_time) on_time,
                 count(*) filter (where is_submitter and on_time is not true) late,
                 count(*) filter (where is_submitter and variance <> 0) variance_days
            from (select d.biz_date, d.submitted_by user_id, true is_submitter, d.on_time, d.variance from daily_closes d where d.biz_date between v_from and v_to
                  union all
                  select d.biz_date, cw, false, d.on_time, d.variance from daily_closes d, unnest(d.coworker_ids) cw where d.biz_date between v_from and v_to) s
           group by user_id) w join app_users x on x.id = w.user_id
    where v_all or w.user_id = u.id);
end $$;
