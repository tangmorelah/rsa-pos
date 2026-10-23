-- RSA - POS Assistant : detail upgrade (period reports, bank lines, investment / payback, profit uses,
-- cash forecast, settings, exports, API entry point)
set check_function_bodies = off;

-- ---------------------------------------------------------------- period KPIs
create or replace function rsa_kpi(p_from date, p_to date) returns jsonb language sql stable as $$
  with o as (
    select coalesce(sum(total - refunded), 0) revenue,
           coalesce(sum(total - refunded) filter (where channel_kind = 'storefront'), 0) storefront,
           coalesce(sum(total - refunded) filter (where channel_kind = 'delivery'), 0) delivery,
           count(*) orders, coalesce(sum(discount), 0) discount
      from orders where status <> 'cancelled' and biz_date between p_from and p_to),
  md as (select coalesce(sum(i.discount), 0) markdown from order_items i join orders o on o.id = i.order_id
          where o.status <> 'cancelled' and o.biz_date between p_from and p_to and i.promo_snapshot->>'rule' = 'markdown'),
  pr as (select rsa_profit(p_from, p_to) j),
  d as (select coalesce(sum(variance), 0) variance, count(*) closes, count(*) filter (where on_time) on_time,
               count(*) filter (where variance <> 0) variance_days
          from daily_closes where biz_date between p_from and p_to)
  select jsonb_build_object('from', p_from, 'to', p_to,
    'revenue', o.revenue, 'storefront', o.storefront, 'delivery', o.delivery, 'orders', o.orders, 'discount', o.discount, 'markdown', md.markdown,
    'avg_ticket', case when o.orders > 0 then round(o.revenue / o.orders, 2) else 0 end,
    'gross_profit', (pr.j->>'gross_profit')::numeric, 'net_profit', (pr.j->>'net_profit')::numeric,
    'margin_pct', case when o.revenue > 0 then round((pr.j->>'gross_profit')::numeric * 100 / o.revenue, 1) end,
    'waste', (pr.j->>'waste')::numeric,
    'waste_pct', case when o.revenue > 0 then round((pr.j->>'waste')::numeric * 100 / o.revenue, 1) end,
    'staff_meals', (pr.j->>'staff_meals')::numeric, 'owner_use', (pr.j->>'owner_use')::numeric,
    'expenses', (pr.j->>'expenses')::numeric, 'var_costs', (pr.j->>'var_costs')::numeric, 'fixed_costs', (pr.j->>'fixed_costs')::numeric,
    'cash_variance', d.variance, 'closes', d.closes, 'on_time', d.on_time, 'variance_days', d.variance_days,
    'profit_complete', pr.j->'complete', 'profit_flags', pr.j->'flags')
  from o, md, pr, d
$$;

create or replace function rsa_owed_reimburse() returns numeric language sql stable as $$
  select coalesce(sum(amount), 0) from expenses where (paid_by_employee is not null or paid_by_owner) and status in ('รออนุมัติ','รอทำจ่าย')
$$;

create or replace function rsa_cash_total() returns numeric language sql stable as $$
  select coalesce(sum(rsa_account_balance(id)), 0) from payment_accounts where active
$$;

create or replace function rsa_delivery_receivable() returns numeric language sql stable as $$
  select coalesce(sum(total - refunded - est_fee), 0) from orders where channel_kind = 'delivery' and status <> 'cancelled' and settlement_id is null
$$;

create or replace function rsa__report_overview(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 6); v_to date := rsa_date(p, 'to'); v_n int; v_pf date; v_pt date;
        v_month date := date_trunc('month', rsa_today())::date;
begin
  perform rsa_need(u, 'report.view');
  if v_to < v_from then perform rsa_err('ช่วงวันที่ไม่ถูกต้อง'); end if;
  v_n := v_to - v_from + 1; v_pt := v_from - 1; v_pf := v_from - v_n;
  return jsonb_build_object('from', v_from, 'to', v_to, 'days', v_n, 'prev_from', v_pf, 'prev_to', v_pt,
    'kpi', rsa_kpi(v_from, v_to),
    'prev', rsa_kpi(v_pf, v_pt),
    'now', jsonb_build_object(
      'cash', rsa_cash_total(),
      'drawer', rsa_account_balance(rsa_drawer()),
      'delivery_receivable', rsa_delivery_receivable(),
      'owed_reimburse', rsa_owed_reimburse(),
      'payables', (select coalesce(sum(amount), 0) from expenses where status in ('รออนุมัติ','รอทำจ่าย')),
      'low_stock', (select count(*) from stock_items s where s.active and s.min_qty > 0 and rsa_stock_qty(s.id) <= s.min_qty),
      'min_working_capital', rsa_setting_num('min_working_capital', 0),
      'profit_target', rsa_setting_num('profit_target', 0),
      'profit_target_confirmed', coalesce((select confirmed from settings where key = 'profit_target'), false),
      'month_net_profit', (rsa_profit(v_month, rsa_today())->>'net_profit')::numeric),
    'series', (select jsonb_agg(jsonb_build_object('date', d::date,
        'storefront', coalesce((select sum(total - refunded) from orders where biz_date = d::date and status <> 'cancelled' and channel_kind = 'storefront'), 0),
        'delivery', coalesce((select sum(total - refunded) from orders where biz_date = d::date and status <> 'cancelled' and channel_kind = 'delivery'), 0),
        'orders', (select count(*) from orders where biz_date = d::date and status <> 'cancelled')) order by d)
      from generate_series(v_from, v_to, interval '1 day') d),
    'channels', (select coalesce(jsonb_agg(jsonb_build_object('name', c.channel_name, 'kind', c.kind, 'net', c.net, 'orders', c.n) order by c.net desc), '[]')
      from (select channel_name, max(channel_kind) kind, sum(total - refunded) net, count(*) n from orders
             where status <> 'cancelled' and biz_date between v_from and v_to group by channel_name) c),
    'top_products', (select coalesce(jsonb_agg(x order by (x->>'revenue')::numeric desc), '[]') from (
       select jsonb_build_object('product_id', i.product_id, 'name', max(i.product_name), 'emoji', max(pr.emoji), 'qty', sum(i.qty), 'revenue', sum(i.line_total)) x
         from order_items i join orders o on o.id = i.order_id left join products pr on pr.id = i.product_id
        where o.status <> 'cancelled' and o.biz_date between v_from and v_to
        group by i.product_id order by sum(i.line_total) desc limit 5) t));
end $$;

create or replace function rsa__report_products(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 29); v_to date := rsa_date(p, 'to'); v_days int;
begin
  perform rsa_need(u, 'report.view');
  v_days := rsa_open_days(v_from, v_to);
  return jsonb_build_object('from', v_from, 'to', v_to, 'open_days', v_days, 'days', v_to - v_from + 1,
    'products', (select coalesce(jsonb_agg(x order by (x->>'revenue')::numeric desc), '[]') from (
       select jsonb_build_object('product_id', pr.id, 'name', pr.name, 'emoji', pr.emoji, 'sku', pr.sku, 'category', pr.category, 'unit', pr.unit,
         'price', pr.price, 'delivery_price', pr.delivery_price, 'active', pr.active,
         'qty', coalesce(sum(i.qty), 0), 'revenue', coalesce(sum(i.line_total), 0),
         'storefront_qty', coalesce(sum(i.qty) filter (where o.channel_kind = 'storefront'), 0),
         'delivery_qty', coalesce(sum(i.qty) filter (where o.channel_kind = 'delivery'), 0),
         'discount', coalesce(sum(i.discount), 0),
         'markdown_qty', coalesce(sum(i.qty) filter (where i.promo_snapshot->>'rule' = 'markdown'), 0),
         'markdown_discount', coalesce(sum(i.discount) filter (where i.promo_snapshot->>'rule' = 'markdown'), 0),
         'cost', coalesce(sum(coalesce(i.unit_cost, 0) * i.qty), 0),
         'gross_profit', coalesce(sum(i.line_total - coalesce(i.unit_cost, 0) * i.qty), 0),
         'margin_pct', case when coalesce(sum(i.line_total), 0) > 0
                          then round(sum(i.line_total - coalesce(i.unit_cost, 0) * i.qty) * 100 / sum(i.line_total), 1) end,
         'avg_per_day', round(coalesce(sum(i.qty), 0) / v_days, 2),
         'cost_known', coalesce(bool_and(i.cost_source <> 'none'), exists (select 1 from recipe_lines r where r.product_id = pr.id) or pr.est_cost is not null),
         'has_recipe', exists (select 1 from recipe_lines r where r.product_id = pr.id),
         'waste_qty', (select coalesce(sum(w.qty), 0) from waste_records w where w.product_id = pr.id and w.status = 'recorded' and w.kind = 'waste' and w.biz_date between v_from and v_to)) x
       from products pr
       left join order_items i on i.product_id = pr.id
            and exists (select 1 from orders o2 where o2.id = i.order_id and o2.status <> 'cancelled' and o2.biz_date between v_from and v_to)
       left join orders o on o.id = i.order_id
       where pr.active or i.id is not null
       group by pr.id) t),
    'waste', (select coalesce(jsonb_agg(x order by (x->>'cost')::numeric desc), '[]') from (
       select jsonb_build_object('item', item_name, 'kind', kind, 'unit', max(unit), 'qty', sum(qty), 'cost', round(sum(qty * unit_cost), 2), 'times', count(*),
         'reasons', jsonb_agg(distinct reason)) x
       from waste_records where status = 'recorded' and biz_date between v_from and v_to group by item_name, kind) t),
    'used', (select jsonb_build_object(
       'waste', coalesce(round(sum(qty * unit_cost) filter (where kind = 'waste'), 2), 0),
       'staff_meal', coalesce(round(sum(qty * unit_cost) filter (where kind = 'staff_meal'), 2), 0),
       'owner_use', coalesce(round(sum(qty * unit_cost) filter (where kind = 'owner_use'), 2), 0))
       from waste_records where status = 'recorded' and biz_date between v_from and v_to),
    'markdown', (select jsonb_build_object('lines', count(*), 'qty', coalesce(sum(i.qty), 0), 'discount', coalesce(sum(i.discount), 0))
         from order_items i join orders o on o.id = i.order_id
        where o.status <> 'cancelled' and o.biz_date between v_from and v_to and i.promo_snapshot->>'rule' = 'markdown'),
    'promotions', (select coalesce(jsonb_agg(x), '[]') from (
       select jsonb_build_object('name', i.promo_snapshot->>'name', 'lines', count(*), 'discount', sum(coalesce((i.promo_snapshot->>'promo_discount')::numeric, 0))) x
         from order_items i join orders o on o.id = i.order_id
        where o.status <> 'cancelled' and o.biz_date between v_from and v_to and i.promo_snapshot ? 'name'
          and coalesce(i.promo_snapshot->>'rule', '') <> 'markdown'
        group by i.promo_snapshot->>'name') t));
end $$;

create or replace function rsa__report_delivery(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 29); v_to date := rsa_date(p, 'to');
begin
  perform rsa_need(u, 'report.view');
  return jsonb_build_object('from', v_from, 'to', v_to,
    'rows', (select coalesce(jsonb_agg(x order by x->>'date' desc, x->>'channel'), '[]') from (
       select jsonb_build_object('date', o.biz_date, 'channel_id', o.channel_id, 'channel', o.channel_name, 'orders', count(*),
         'gross', sum(o.total - o.refunded), 'est_fee', sum(o.est_fee), 'est_net', sum(o.total - o.refunded - o.est_fee),
         'fee_pct', max(o.fee_pct), 'expected_date', o.biz_date + max(c.settlement_days),
         'settled_orders', count(*) filter (where o.settlement_id is not null),
         'status', case when bool_and(o.settlement_id is not null) then 'รับเงินแล้ว'
                        when o.biz_date + max(c.settlement_days) < rsa_today() then 'เลยกำหนด' else 'รอรับเงิน' end) x
         from orders o join channels c on c.id = o.channel_id
        where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.biz_date between v_from and v_to
        group by o.biz_date, o.channel_id, o.channel_name) t),
    'channels', (select coalesce(jsonb_agg(jsonb_build_object('channel_id', c.id, 'name', c.name, 'fee_pct', c.fee_pct, 'fee_confirmed', c.fee_confirmed,
         'settlement_days', c.settlement_days,
         'gross', (select coalesce(sum(total - refunded), 0) from orders o where o.channel_id = c.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
         'orders', (select count(*) from orders o where o.channel_id = c.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
         'unsettled', (select coalesce(sum(total - refunded - est_fee), 0) from orders o where o.channel_id = c.id and o.status <> 'cancelled' and o.settlement_id is null))
         order by c.sort_order), '[]') from channels c where c.kind = 'delivery' and c.active),
    'settlements', (select coalesce(jsonb_agg(to_jsonb(s) || jsonb_build_object('account_name', (select name from payment_accounts where id = s.account_id))
         order by s.deposited_at desc), '[]') from delivery_settlements s where s.period_to between v_from and v_to));
end $$;

create or replace function rsa__report_expenses(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', date_trunc('month', rsa_today())::date); v_to date := rsa_date(p, 'to');
begin
  perform rsa_need(u, 'expense.view_all');
  return jsonb_build_object('from', v_from, 'to', v_to,
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', category_name, 'tax_category', tax, 'amount', amt, 'count', n) order by amt desc), '[]') from (
        select coalesce(category_name, '-') category_name, max(tax_category) tax, sum(amount) amt, count(*) n from expenses
         where status <> 'ยกเลิก' and rsa_bdate(occurred_at) between v_from and v_to group by category_name) t),
    'by_source', (select coalesce(jsonb_agg(jsonb_build_object('fund_source', fs, 'amount', amt, 'count', n) order by amt desc), '[]') from (
        select coalesce(fund_source, 'credit') fs, sum(amount) amt, count(*) n from expenses
         where status <> 'ยกเลิก' and rsa_bdate(occurred_at) between v_from and v_to group by coalesce(fund_source, 'credit')) t),
    'by_status', (select coalesce(jsonb_object_agg(status, amt), '{}') from (
        select status, sum(amount) amt from expenses where rsa_bdate(occurred_at) between v_from and v_to group by status) t),
    'owed', (select coalesce(jsonb_agg(jsonb_build_object('owed_to', owed_to, 'amount', amt, 'count', n)), '[]') from (
        select coalesce((select display_name from app_users where id = paid_by_employee), 'เจ้าของ') owed_to, sum(amount) amt, count(*) n
          from expenses where (paid_by_employee is not null or paid_by_owner) and status in ('รออนุมัติ','รอทำจ่าย')
         group by 1) t),
    'no_evidence', (select count(*) from expenses e where e.status <> 'ยกเลิก' and rsa_bdate(e.occurred_at) between v_from and v_to
         and not exists (select 1 from attachments a where (a.linked_type = 'expense' and a.linked_id = e.id) or (a.linked_type = 'receipt' and a.linked_id = e.receipt_id))),
    'total', (select coalesce(sum(amount), 0) from expenses where status <> 'ยกเลิก' and rsa_bdate(occurred_at) between v_from and v_to));
end $$;

create or replace function rsa__report_staff(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', date_trunc('month', rsa_today())::date); v_to date := rsa_date(p, 'to');
begin
  perform rsa_need(u, 'report.view');
  return jsonb_build_object('from', v_from, 'to', v_to,
    'workdays', rsa__close_workdays(u, jsonb_build_object('from', v_from, 'to', v_to)),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('user_id', x.id, 'display_name', x.display_name, 'role', x.role, 'active', x.active,
        'orders', (select count(*) from orders o where o.created_by = x.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
        'sales', (select coalesce(sum(total - refunded), 0) from orders o where o.created_by = x.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
        'cancels', (select count(*) from orders o where o.cancelled_by = x.id and o.replaced_by is null and rsa_bdate(o.cancelled_at) between v_from and v_to),
        'edits', (select count(*) from orders o where o.cancelled_by = x.id and o.replaced_by is not null and rsa_bdate(o.cancelled_at) between v_from and v_to),
        'waste', (select coalesce(round(sum(qty * unit_cost), 2), 0) from waste_records w where w.created_by = x.id and w.status = 'recorded' and w.biz_date between v_from and v_to),
        'expenses', (select coalesce(sum(amount), 0) from expenses e where e.created_by = x.id and e.status <> 'ยกเลิก' and rsa_bdate(e.occurred_at) between v_from and v_to),
        'owed', (select coalesce(sum(amount), 0) from expenses e where e.paid_by_employee = x.id and e.status in ('รออนุมัติ','รอทำจ่าย')))
        order by x.active desc, x.display_name), '[]') from app_users x where x.role <> 'admin' or x.active));
end $$;

-- ---------------------------------------------------------------- stock balance with daily use and reorder suggestion
create or replace function rsa__stock_balance(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(x order by x->>'code', x->>'name'), '[]') from (
    select jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'unit', s.unit, 'kind', s.kind, 'active', s.active,
      'qty', q.qty, 'avg_cost', case when rsa_has(u, 'report.view') then s.avg_cost end,
      'value', case when rsa_has(u, 'report.view') then round(greatest(q.qty, 0) * s.avg_cost, 2) end,
      'min_qty', s.min_qty, 'reorder_qty', s.reorder_qty,
      'used_7d', coalesce((select -sum(qty) from stock_ledger l where l.stock_item_id = s.id and l.kind in ('sale','sale_reversal')
                            and l.occurred_at > now() - interval '7 days'), 0),
      'avg_daily_use', a.avg_use,
      'days_left', case when a.avg_use > 0 then round(greatest(q.qty, 0) / a.avg_use, 1) end,
      'status', case when q.qty <= 0 then 'out' when q.qty <= s.min_qty then 'low' else 'ok' end,
      -- use per day x 2 days + minimum - on hand (falls back to reorder qty when there is no usage history yet)
      'suggest', case when a.avg_use > 0 then greatest(ceil((a.avg_use * 2 + s.min_qty - q.qty) * 10) / 10, 0)
                      when q.qty <= s.min_qty then greatest(coalesce(nullif(s.reorder_qty, 0), s.min_qty * 2 - q.qty), 0) else 0 end,
      'last_received', (select max(occurred_at) from stock_ledger l where l.stock_item_id = s.id and l.kind = 'receipt'),
      'last_cost', case when rsa_has(u, 'report.view') then (select unit_cost from stock_ledger l where l.stock_item_id = s.id and l.kind = 'receipt' order by occurred_at desc limit 1) end,
      'used_in_recipe', exists (select 1 from recipe_lines r where r.stock_item_id = s.id),
      'products', (select coalesce(jsonb_agg(pr.name), '[]') from products pr where pr.main_stock_item_id = s.id or exists (select 1 from recipe_lines r where r.stock_item_id = s.id and r.product_id = pr.id)),
      'pending_count', exists (select 1 from stocktake_lines l join stocktakes t on t.id = l.stocktake_id where t.status = 'pending' and l.stock_item_id = s.id)
    ) x
    from stock_items s
    cross join lateral (select rsa_stock_qty(s.id) qty) q
    cross join lateral (select round(coalesce((select -sum(qty) from stock_ledger l where l.stock_item_id = s.id
                          and l.kind in ('sale','sale_reversal','waste','waste_reversal') and l.occurred_at > now() - interval '14 days'), 0)
                          / rsa_open_days(rsa_today() - 13, rsa_today()), 3) avg_use) a
    where s.active or coalesce((p->>'include_inactive')::boolean, false)) z);
end $$;

-- ---------------------------------------------------------------- bank statement lines and reconciliation
create or replace function rsa__bank_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_amt numeric := rsa_num(p, 'amount', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
        v_acc payment_accounts;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v_acc from payment_accounts where id = rsa_uuid(p, 'account_id') and kind <> 'cash';
  if not found then perform rsa_err('กรุณาเลือกบัญชีธนาคาร'); end if;
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if coalesce(p->>'direction', '') not in ('in','out') then perform rsa_err('เลือกเงินเข้า หรือ เงินออก'); end if;
  insert into bank_lines(id, account_id, occurred_at, biz_date, direction, amount, ref_no, description, created_by)
  values (v_id, v_acc.id, v_at, rsa_bdate(v_at), p->>'direction', v_amt, nullif(trim(p->>'ref_no'), ''), nullif(trim(p->>'description'), ''), u.id);
  perform rsa_link_attachments(p->'attachment_ids', 'bank_line', v_id, u);
  perform rsa_audit(u, 'bank.create', 'bank_line', v_id::text, null,
    jsonb_build_object('account', v_acc.name, 'direction', p->>'direction', 'amount', v_amt, 'ref_no', p->>'ref_no'));
  return (select to_jsonb(b) from bank_lines b where id = v_id);
end $$;

create or replace function rsa__bank_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'cashflow.view');
  return (select coalesce(jsonb_agg(to_jsonb(b) || jsonb_build_object('account_name', (select name from payment_accounts where id = b.account_id),
            'by', (select display_name from app_users where id = b.created_by), 'attachments', rsa_attachment_refs('bank_line', b.id))
            order by b.occurred_at desc), '[]')
          from bank_lines b where b.biz_date between rsa_date(p, 'from', rsa_today() - 30) and rsa_date(p, 'to')
           and (rsa_uuid(p, 'account_id') is null or b.account_id = rsa_uuid(p, 'account_id')));
end $$;

create or replace function rsa__bank_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v bank_lines;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from bank_lines where id = rsa_uuid(p, 'id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update bank_lines set status = 'cancelled', cancelled_by = u.id, cancel_reason = trim(p->>'reason') where id = v.id;
  perform rsa_audit(u, 'bank.cancel', 'bank_line', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

-- What the system expects in the account (QR / transfer orders, platform payouts, deposits, payments)
-- next to what the statement shows, per day.
create or replace function rsa__bank_recon(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 13); v_to date := rsa_date(p, 'to');
        v_acc uuid := coalesce(rsa_uuid(p, 'account_id'), (select id from payment_accounts where active and kind = 'bank' order by created_at limit 1));
begin
  perform rsa_need(u, 'cashflow.view');
  if v_acc is null then return jsonb_build_object('account_id', null, 'days', '[]'); end if;
  return jsonb_build_object('account_id', v_acc, 'account_name', (select name from payment_accounts where id = v_acc), 'from', v_from, 'to', v_to,
    'days', (select jsonb_agg(jsonb_build_object('date', d::date,
        'qr_orders', coalesce((select sum(case direction when 'in' then amount else -amount end) from money_ledger m
                      where m.account_id = v_acc and m.biz_date = d::date and m.source_type in ('order','order_refund')), 0),
        'settlements', coalesce((select sum(case direction when 'in' then amount else -amount end) from money_ledger m
                      where m.account_id = v_acc and m.biz_date = d::date and m.source_type = 'settlement'), 0),
        'expected_in', coalesce((select sum(amount) from money_ledger m where m.account_id = v_acc and m.biz_date = d::date and m.direction = 'in'), 0),
        'expected_out', coalesce((select sum(amount) from money_ledger m where m.account_id = v_acc and m.biz_date = d::date and m.direction = 'out'), 0),
        'actual_in', coalesce((select sum(amount) from bank_lines b where b.account_id = v_acc and b.biz_date = d::date and b.status = 'done' and b.direction = 'in'), 0),
        'actual_out', coalesce((select sum(amount) from bank_lines b where b.account_id = v_acc and b.biz_date = d::date and b.status = 'done' and b.direction = 'out'), 0),
        'lines', (select count(*) from bank_lines b where b.account_id = v_acc and b.biz_date = d::date and b.status = 'done')) order by d desc)
      from generate_series(v_from, v_to, interval '1 day') d),
    'system_balance', rsa_account_balance(v_acc));
end $$;

-- ---------------------------------------------------------------- capital, investment items, payback
create or replace function rsa_floor_check(p_amount numeric) returns void language plpgsql as $$
declare v_min numeric := rsa_setting_num('min_working_capital', 0); v_left numeric;
begin
  if v_min <= 0 then return; end if;
  v_left := rsa_cash_total() - p_amount;
  if v_left < v_min then
    perform rsa_err('ต้องกันเงินหมุนขั้นต่ำ ' || to_char(v_min, 'FM999,999,990') || ' บาท ถ้าจ่ายรายการนี้จะเหลือ '
                    || to_char(v_left, 'FM999,999,990.00') || ' บาท');
  end if;
end $$;

create or replace function rsa__capital_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_kind text := p->>'kind'; v_amt numeric := rsa_num(p, 'amount', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
begin
  perform rsa_need(u, 'cashflow.manage');
  if v_kind not in ('capital_in','loan_in','capital_return','loan_repayment','investment_item') then perform rsa_err('ประเภทรายการไม่ถูกต้อง'); end if;
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if v_kind = 'investment_item' then
    if coalesce(trim(p->>'category'), '') = '' then perform rsa_err('กรุณาระบุรายการลงทุน เช่น ค่าเซ้ง เงินประกัน'); end if;
    insert into capital_entries(id, kind, party, amount, occurred_at, account_id, note, created_by, category, counts_as_investment, in_payback,
                                refundable_amount, data_status)
    values (v_id, 'investment_item', coalesce(nullif(trim(p->>'party'), ''), 'เจ้าของ'), v_amt, v_at, null, nullif(p->>'note', ''), u.id, trim(p->>'category'),
            coalesce((p->>'counts_as_investment')::boolean, true), coalesce((p->>'in_payback')::boolean, true),
            greatest(rsa_num(p, 'refundable_amount', 0), 0), coalesce(nullif(p->>'data_status', ''), 'ยืนยันแล้ว'));
  else
    if coalesce(trim(p->>'party'), '') = '' then perform rsa_err('กรุณาระบุชื่อผู้ลงทุนหรือเจ้าหนี้'); end if;
    if rsa_uuid(p, 'account_id') is null then perform rsa_err('กรุณาเลือกบัญชี'); end if;
    if v_kind in ('capital_return','loan_repayment') then
      if v_amt > rsa_account_balance(rsa_uuid(p, 'account_id')) then perform rsa_err('ยอดเงินในบัญชีที่เลือกไม่พอ'); end if;
      perform rsa_floor_check(v_amt);
    end if;
    insert into capital_entries(id, kind, party, amount, occurred_at, account_id, note, created_by, category)
    values (v_id, v_kind, trim(p->>'party'), v_amt, v_at, rsa_uuid(p, 'account_id'), nullif(p->>'note', ''), u.id, nullif(trim(p->>'category'), ''));
    perform rsa_money(rsa_uuid(p, 'account_id'), case when v_kind in ('capital_in','loan_in') then 'in' else 'out' end, v_amt, 'capital', v_id,
      trim(p->>'party'), u.id, v_at);
  end if;
  perform rsa_audit(u, 'capital.create', 'capital', v_id::text, null, jsonb_build_object('kind', v_kind, 'amount', v_amt, 'party', p->>'party', 'category', p->>'category'));
  return jsonb_build_object('id', v_id);
end $$;

-- investment items carry no cash movement, so their review fields may be corrected (every change is audited)
create or replace function rsa__investment_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v capital_entries;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from capital_entries where id = rsa_uuid(p, 'id') and kind = 'investment_item' and status = 'done' for update;
  if not found then perform rsa_err('ไม่พบรายการลงทุน'); end if;
  update capital_entries set
    amount = coalesce(nullif(rsa_num(p, 'amount'), 0), amount),
    category = coalesce(nullif(trim(p->>'category'), ''), category),
    refundable_amount = coalesce(rsa_num(p, 'refundable_amount'), refundable_amount),
    counts_as_investment = coalesce((p->>'counts_as_investment')::boolean, counts_as_investment),
    in_payback = coalesce((p->>'in_payback')::boolean, in_payback),
    data_status = coalesce(nullif(p->>'data_status', ''), data_status),
    occurred_at = coalesce(nullif(p->>'occurred_at', '')::timestamptz, occurred_at),
    note = coalesce(nullif(p->>'note', ''), note)
   where id = v.id;
  perform rsa_audit(u, 'investment.save', 'capital', v.id::text, to_jsonb(v), (select to_jsonb(c) from capital_entries c where id = v.id));
  return (select to_jsonb(c) from capital_entries c where id = v.id);
end $$;

create or replace function rsa__capital_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v capital_entries;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from capital_entries where id = rsa_uuid(p, 'capital_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if v.profit_declaration_id is not null then perform rsa_err('รายการนี้มาจากการประกาศใช้กำไร ให้ยกเลิกที่การประกาศ'); end if;
  if v.expense_id is not null then perform rsa_err('รายการนี้มาจากค่าใช้จ่ายที่เจ้าของจ่ายแทน ให้ยกเลิกที่ค่าใช้จ่าย'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update capital_entries set status = 'cancelled', cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  if v.account_id is not null then
    perform rsa_money(v.account_id, case when v.kind in ('capital_in','loan_in') then 'out' else 'in' end, v.amount, 'capital', v.id, 'กลับรายการ ' || v.party, u.id);
  end if;
  perform rsa_audit(u, 'capital.cancel', 'capital', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa__payback_summary(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_today date := rsa_today(); v_av jsonb := rsa_profit_available(); v_base numeric; v_profit numeric; v_avg numeric; v_debt numeric; v_paid numeric;
begin
  perform rsa_need(u, 'cashflow.view');
  select coalesce(sum(amount - refundable_amount) filter (where in_payback), 0) into v_base
    from capital_entries where kind = 'investment_item' and status = 'done' and counts_as_investment;
  v_profit := (v_av->>'cumulative_net')::numeric;
  v_avg := round((rsa_profit(v_today - 89, v_today)->>'net_profit')::numeric / 3, 2);
  -- debt: one formula everywhere (rsa_debt_left): opening debt + loans taken − repayments
  v_debt := rsa_setting_num('opening_debt', 0) + (select coalesce(sum(amount), 0) from capital_entries where kind = 'loan_in' and status = 'done');
  select coalesce(sum(amount), 0) into v_paid from capital_entries where kind = 'loan_repayment' and status = 'done';
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(to_jsonb(c) order by c.occurred_at), '[]') from capital_entries c where c.kind = 'investment_item' and c.status = 'done'),
    'investment_total', (select coalesce(sum(amount), 0) from capital_entries where kind = 'investment_item' and status = 'done' and counts_as_investment),
    'refundable', (select coalesce(sum(refundable_amount), 0) from capital_entries where kind = 'investment_item' and status = 'done' and counts_as_investment),
    'payback_base', v_base,
    'cash_capital_in', (select coalesce(sum(amount), 0) from capital_entries where kind in ('capital_in','owner_paid') and status = 'done'),
    'capital_returned', (select coalesce(sum(amount), 0) from capital_entries where kind = 'capital_return' and status = 'done'),
    'profit_to_date', v_profit,
    'profit_complete', v_av->'complete',
    'remaining', greatest(v_base - greatest(v_profit, 0), 0),
    'progress_pct', case when v_base > 0 then least(round(greatest(v_profit, 0) * 100 / v_base, 1), 100) end,
    'avg_month_profit', v_avg,
    'months_left', case when v_avg > 0 and v_base > v_profit then ceil((v_base - greatest(v_profit, 0)) / v_avg) end,
    'opening_debt', v_debt,
    'opening_debt_confirmed', coalesce((select confirmed from settings where key = 'opening_debt'), false),
    'debt_paid', v_paid,
    'debt_left', greatest(v_debt - v_paid, 0),
    'needs_review', (select count(*) from capital_entries where kind = 'investment_item' and status = 'done' and data_status <> 'ยืนยันแล้ว'));
end $$;

-- ---------------------------------------------------------------- profit uses
create or replace function rsa__profit_declare(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_amt numeric := rsa_num(p, 'amount', 0); v_av jsonb := rsa_profit_available();
        v_acc uuid := rsa_uuid(p, 'account_id'); v_purpose text := p->>'purpose'; v_at timestamptz := rsa_ts(p, 'declared_at');
        v_keep boolean; v_now boolean;
begin
  perform rsa_need(u, 'cashflow.manage');
  if v_purpose not in ('owner_draw','capital_return','loan_repayment','keep_working_capital','reinvest') then perform rsa_err('กรุณาเลือกวิธีใช้กำไร'); end if;
  v_keep := v_purpose in ('keep_working_capital','reinvest');
  v_now := not v_keep and coalesce((p->>'paid_now')::boolean, true);
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if not v_keep and coalesce(trim(p->>'recipient'), '') = '' then perform rsa_err('กรุณาระบุผู้รับเงิน'); end if;
  if v_now and v_acc is null then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
  if v_amt > (v_av->>'available')::numeric then
    perform rsa_err('กำไรที่ประกาศได้ตอนนี้ ' || (v_av->>'available') || ' บาท ยอดที่ขอเกินกว่านั้น');
  end if;
  if v_now then
    if v_amt > rsa_account_balance(v_acc) then perform rsa_err('ยอดเงินในบัญชีที่เลือกไม่พอ'); end if;
    perform rsa_floor_check(v_amt);
  end if;
  insert into profit_declarations(id, amount, declared_at, recipient, purpose, account_id, basis_available, note, paid_now, created_by)
  values (v_id, v_amt, v_at, coalesce(nullif(trim(p->>'recipient'), ''), 'ร้าน'), v_purpose, case when v_now then v_acc end,
          (v_av->>'available')::numeric, nullif(p->>'note', ''), v_now, u.id);
  if v_now then perform rsa_profit_payout(u, v_id, v_acc, v_at); end if;
  perform rsa_audit(u, 'profit.declare', 'profit_declaration', v_id::text, null,
    jsonb_build_object('amount', v_amt, 'purpose', v_purpose, 'recipient', p->>'recipient', 'paid_now', v_now, 'available_before', v_av->'available'));
  return jsonb_build_object('id', v_id);
end $$;

create or replace function rsa_profit_payout(u app_users, p_id uuid, p_acc uuid, p_at timestamptz) returns void language plpgsql as $$
declare v profit_declarations;
begin
  select * into v from profit_declarations where id = p_id;
  if v.purpose in ('capital_return','loan_repayment') then
    insert into capital_entries(kind, party, amount, occurred_at, account_id, profit_declaration_id, note, created_by)
    values (v.purpose, v.recipient, v.amount, p_at, p_acc, v.id, 'จากการประกาศใช้กำไร', u.id);
  end if;
  perform rsa_money(p_acc, 'out', v.amount, 'profit', v.id, 'ประกาศใช้กำไร: ' || v.recipient, u.id, p_at);
end $$;

-- pay a declared profit that was set aside to pay later
create or replace function rsa__profit_pay(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v profit_declarations; v_acc uuid := rsa_uuid(p, 'account_id'); v_at timestamptz := rsa_ts(p, 'paid_at');
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from profit_declarations where id = rsa_uuid(p, 'declaration_id') for update;
  if not found or v.status <> 'done' then perform rsa_err('ไม่พบรายการ'); end if;
  if v.paid_now or v.purpose in ('keep_working_capital','reinvest') then perform rsa_err('รายการนี้ไม่มียอดค้างจ่าย'); end if;
  if v_acc is null then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
  if v.amount > rsa_account_balance(v_acc) then perform rsa_err('ยอดเงินในบัญชีที่เลือกไม่พอ'); end if;
  perform rsa_floor_check(v.amount);
  update profit_declarations set paid_now = true, account_id = v_acc where id = v.id;
  perform rsa_profit_payout(u, v.id, v_acc, v_at);
  perform rsa_audit(u, 'profit.pay', 'profit_declaration', v.id::text, null, jsonb_build_object('account_id', v_acc, 'amount', v.amount));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa__profit_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v profit_declarations;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from profit_declarations where id = rsa_uuid(p, 'declaration_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update profit_declarations set status = 'cancelled', cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  update capital_entries set status = 'cancelled', cancelled_by = u.id, cancel_reason = p->>'reason' where profit_declaration_id = v.id;
  if v.account_id is not null and v.paid_now then
    perform rsa_money(v.account_id, 'in', v.amount, 'profit', v.id, 'กลับรายการประกาศใช้กำไร', u.id);
  end if;
  perform rsa_audit(u, 'profit.cancel', 'profit_declaration', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- cash forecast 7 / 14 / 30 days
create or replace function rsa__cashflow_forecast(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_today date := rsa_today(); v_cash numeric := rsa_cash_total(); v_sales numeric; v_spend numeric; v_out numeric;
        v_min numeric := rsa_setting_num('min_working_capital', 0);
begin
  perform rsa_need(u, 'cashflow.view');
  -- averages from real history (estimates, shown as such)
  -- per open day (holidays have no sales and are skipped when projecting forward)
  select coalesce(sum(total - refunded), 0) / rsa_open_days(v_today - 14, v_today - 1) into v_sales from orders
   where channel_kind = 'storefront' and status <> 'cancelled' and biz_date between v_today - 14 and v_today - 1;
  select coalesce(sum(amount), 0) / 30 into v_spend from expenses
   where status = 'จ่ายแล้ว' and fixed_expense_id is null and rsa_bdate(paid_at) between v_today - 30 and v_today - 1;
  select coalesce(sum(case direction when 'out' then amount else 0 end), 0) / 30 into v_out from money_ledger m
   where m.biz_date between v_today - 30 and v_today - 1 and m.source_type in ('expense')
     and exists (select 1 from payment_accounts a where a.id = m.account_id);
  return jsonb_build_object('today', v_today, 'cash_now', v_cash, 'min_working_capital', v_min,
    'avg_daily_storefront', round(v_sales, 2), 'avg_daily_spend', round(v_spend, 2), 'avg_daily_outflow', round(v_out, 2),
    'runway_days', case when v_out > 0 then floor(v_cash / v_out) end,
    'horizons', (select jsonb_agg(jsonb_build_object('days', d,
        'delivery_in', (select coalesce(sum(o.total - o.refunded - o.est_fee), 0) from orders o join channels c on c.id = o.channel_id
                        where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days <= v_today + d),
        'est_sales', round(v_sales * (select count(*) from generate_series(v_today + 1, v_today + d, interval '1 day') g where rsa_is_open(g::date)), 2),
        'payables', (select coalesce(sum(amount), 0) from expenses where status in ('รออนุมัติ','รอทำจ่าย') and coalesce(due_date, rsa_bdate(occurred_at)) <= v_today + d),
        -- this month's recurring bills already exist as payables; later months (monthly and weekly) come from the recurring list
        'fixed', rsa_fixed_upcoming((date_trunc('month', v_today) + interval '1 month')::date, v_today + d),
        'debt', rsa_debt_due(v_today + d),
        'est_spend', round(v_spend * d, 2)) order by d) from unnest(array[7,14,30]) d),
    'unconfirmed_fixed', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'amount', amount, 'due_day', due_day)), '[]')
                          from fixed_expenses where active and not confirmed),
    'daily', (select jsonb_agg(jsonb_build_object('date', v_today + n,
        'balance', round(v_cash + v_sales * (select count(*) from generate_series(v_today + 1, v_today + n, interval '1 day') g where rsa_is_open(g::date)) - v_spend * n
          + (select coalesce(sum(o.total - o.refunded - o.est_fee), 0) from orders o join channels c on c.id = o.channel_id
              where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days <= v_today + n)
          - (select coalesce(sum(amount), 0) from expenses where status in ('รออนุมัติ','รอทำจ่าย') and coalesce(due_date, rsa_bdate(occurred_at)) <= v_today + n), 2))
        order by n) from generate_series(0, 30) n));
end $$;

-- ---------------------------------------------------------------- bootstrap, master data, settings
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
                   'unit', p2.unit, 'price', p2.price, 'delivery_price', p2.delivery_price, 'markdown_price', p2.markdown_price, 'delivery_enabled', p2.delivery_enabled,
                   'emoji', p2.emoji, 'sort_order', p2.sort_order,
                   'has_recipe', exists (select 1 from recipe_lines r where r.product_id = p2.id)) order by p2.sort_order, p2.name), '[]')
                   from products p2 where p2.active),
    'promotions', (select coalesce(jsonb_agg(to_jsonb(pr)), '[]') from promotions pr
                   where pr.active and (pr.starts_at is null or pr.starts_at <= now()) and (pr.ends_at is null or pr.ends_at > now())),
    'stock_items', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'unit', s.unit, 'kind', s.kind) order by s.code nulls last, s.name), '[]')
                   from stock_items s where s.active),
    'units', (select coalesce(jsonb_agg(name order by name), '[]') from units where active),
    'categories', (select coalesce(jsonb_agg(to_jsonb(c) order by coalesce(c.grp, 'B'), c.sort_order, c.code nulls last, c.name), '[]') from expense_categories c
                   where c.active and c.auto_source is null and (is_mgr or (c.staff_allowed and coalesce(c.grp, 'B') <> 'C'))
                     and (coalesce(c.grp, 'B') <> 'C' or c.c_kind = 'advance' or rsa_has(u, 'cashflow.manage'))),
    'suppliers', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name), '[]') from suppliers s where s.active),
    'users', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'display_name', x.display_name, 'role', x.role) order by x.display_name), '[]')
                   from app_users x where x.active),
    'closed_today', exists (select 1 from daily_closes where biz_date = rsa_today()),
    'holiday_today', not rsa_is_open(rsa_today())
  );
end $$;

create or replace function rsa_setting_keys() returns text[] language sql immutable as $$
  select array['shop_name','close_due_time','cash_variance_tolerance','waste_evidence_required','vat_registered','tax_id',
    'close_time','reminder_times','starting_float','min_working_capital','opening_debt','transport_default','transport_method',
    'market_trip_km','market_trips_per_week','profit_target','evidence_required','waste_reasons','payroll_week_start','product_categories',
    'markdown_from','closed_weekdays','closed_dates','cost_ratio_limits','budget_over_alert_pct','monthly_plan','debt_schedule','lease_end']
$$;

create or replace function rsa__settings_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_before jsonb; v_key text := p->>'key'; v_val jsonb := p->'value';
begin
  perform rsa_need(u, 'settings.manage');
  if not (v_key = any(rsa_setting_keys())) then perform rsa_err('ไม่รู้จักการตั้งค่านี้'); end if;
  if v_key in ('close_due_time','close_time') and coalesce(v_val #>> '{}', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    perform rsa_err('รูปแบบเวลาต้องเป็น HH:MM เช่น 20:00');
  end if;
  if v_key = 'reminder_times' and (jsonb_typeof(v_val) <> 'array'
     or exists (select 1 from jsonb_array_elements_text(v_val) t where t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$')) then
    perform rsa_err('เวลาเตือนต้องเป็นรายการเวลา HH:MM');
  end if;
  if v_key in ('cash_variance_tolerance','starting_float','min_working_capital','opening_debt','transport_default','market_trip_km',
               'market_trips_per_week','profit_target') and (jsonb_typeof(v_val) <> 'number' or (v_val #>> '{}')::numeric < 0) then
    perform rsa_err('ค่านี้ต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป');
  end if;
  if v_key = 'transport_method' and coalesce(v_val #>> '{}', '') not in ('value','weight','equal') then perform rsa_err('วิธีจัดสรรค่าขนส่งไม่ถูกต้อง'); end if;
  if v_key = 'payroll_week_start' and (jsonb_typeof(v_val) <> 'number' or (v_val #>> '{}')::int not between 0 and 6) then perform rsa_err('วันเริ่มสัปดาห์ต้องเป็น 0–6 (0 = อาทิตย์, 1 = จันทร์)'); end if;
  if v_key = 'product_categories' and jsonb_typeof(v_val) <> 'array' then perform rsa_err('หมวดสินค้าต้องเป็นรายการ'); end if;
  if v_key = 'markdown_from' and coalesce(v_val #>> '{}', '') !~ '^(([01][0-9]|2[0-3]):[0-5][0-9])?$' then perform rsa_err('รูปแบบเวลาต้องเป็น HH:MM เช่น 19:00 (เว้นว่าง = ไม่ใช้)'); end if;
  if v_key = 'closed_weekdays' and (jsonb_typeof(v_val) <> 'array'
     or exists (select 1 from jsonb_array_elements(v_val) t where jsonb_typeof(t) <> 'number' or (t #>> '{}')::int not between 0 and 6)) then
    perform rsa_err('วันหยุดประจำต้องเป็นรายการวัน 0–6');
  end if;
  if v_key = 'closed_dates' and (jsonb_typeof(v_val) <> 'array'
     or exists (select 1 from jsonb_array_elements_text(v_val) t where t !~ '^\d{4}-\d{2}-\d{2}$')) then
    perform rsa_err('วันหยุดพิเศษต้องเป็นวันที่ YYYY-MM-DD');
  end if;
  if v_key = 'closed_dates' then
    v_val := (select coalesce(jsonb_agg(d order by d), '[]') from (select distinct t d from jsonb_array_elements_text(v_val) t) x);
  end if;
  if v_key = 'cost_ratio_limits' and (jsonb_typeof(v_val) <> 'object'
     or exists (select 1 from jsonb_each(v_val) t where jsonb_typeof(t.value) <> 'number' or (t.value #>> '{}')::numeric not between 0 and 1)) then
    perform rsa_err('เกณฑ์ต้นทุนต้องเป็นสัดส่วน 0–1 เช่น ผลไม้ 0.65');
  end if;
  if v_key = 'budget_over_alert_pct' and (jsonb_typeof(v_val) <> 'number' or (v_val #>> '{}')::numeric not between 0 and 1) then
    perform rsa_err('เกณฑ์แจ้งเตือนเกินงบต้องเป็นสัดส่วน 0–1 เช่น 0.1');
  end if;
  if v_key = 'monthly_plan' and (jsonb_typeof(v_val) <> 'object'
     or exists (select 1 from jsonb_each(v_val) t where t.key !~ '^\d{4}-\d{2}$' or jsonb_typeof(t.value) <> 'object')) then
    perform rsa_err('แผนรายเดือนต้องเป็น { "YYYY-MM": { sales_target, net_profit_target } }');
  end if;
  if v_key = 'debt_schedule' and (jsonb_typeof(v_val) <> 'array'
     or exists (select 1 from jsonb_array_elements(v_val) t where coalesce(t->>'due', '') !~ '^\d{4}-\d{2}-\d{2}$' or jsonb_typeof(t->'amount') <> 'number')) then
    perform rsa_err('ตารางหนี้ต้องเป็นรายการ { due: YYYY-MM-DD, amount }');
  end if;
  if v_key in ('waste_evidence_required','vat_registered','evidence_required') and jsonb_typeof(v_val) <> 'boolean' then perform rsa_err('ค่านี้ต้องเป็น ใช่ / ไม่ใช่'); end if;
  select to_jsonb(s) into v_before from settings s where key = v_key;
  insert into settings(key, value, confirmed, updated_at, updated_by) values (v_key, v_val, coalesce((p->>'confirmed')::boolean, true), now(), u.id)
  on conflict (key) do update set value = excluded.value, confirmed = excluded.confirmed, updated_at = now(), updated_by = u.id;
  perform rsa_audit(u, 'settings.save', 'settings', v_key, v_before, jsonb_build_object('value', v_val, 'confirmed', coalesce((p->>'confirmed')::boolean, true)));
  return jsonb_build_object('ok', true);
end $$;

-- what still needs the owner's confirmation before numbers can be trusted
create or replace function rsa__setup_checklist(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'report.view');
  return (select coalesce(jsonb_agg(x), '[]') from (
    select jsonb_build_object('kind', 'setting', 'key', s.key, 'text', 'ตั้งค่า "' || s.key || '" ยังไม่ยืนยัน', 'value', s.value) x
      from settings s where not s.confirmed and s.key = any(rsa_setting_keys())
    union all
    select jsonb_build_object('kind', 'account', 'id', a.id, 'text', 'ยอดยกมาบัญชี "' || a.name || '" ยังไม่ยืนยัน') from payment_accounts a where a.active and not a.opening_confirmed
    union all
    select jsonb_build_object('kind', 'channel', 'id', c.id, 'text', 'ค่าธรรมเนียม ' || c.name || ' (' || c.fee_pct || '%) ยังไม่ยืนยัน') from channels c where c.active and c.kind = 'delivery' and not c.fee_confirmed
    union all
    select jsonb_build_object('kind', 'fixed', 'id', f.id, 'text', 'ค่าใช้จ่ายประจำ "' || f.name || '" ' || f.amount || ' บาท ยังไม่ยืนยัน') from fixed_expenses f where f.active and not f.confirmed
    union all
    select jsonb_build_object('kind', 'investment', 'id', c.id, 'text', 'เงินลงทุน "' || c.category || '" ' || c.amount || ' บาท ' || c.data_status)
      from capital_entries c where c.kind = 'investment_item' and c.status = 'done' and c.data_status <> 'ยืนยันแล้ว'
    union all
    select jsonb_build_object('kind', 'recipe', 'id', pr.id, 'text', 'สินค้า "' || pr.name || '" ยังไม่มีสูตรการใช้วัตถุดิบ (ยังคิดต้นทุนและตัดสต็อกไม่ได้)')
      from products pr where pr.active and pr.est_cost is null and not exists (select 1 from recipe_lines r where r.product_id = pr.id)
    union all
    select jsonb_build_object('kind', 'stock_cost', 'id', s.id, 'text', 'วัตถุดิบ "' || s.name || '" ยังไม่มีต้นทุน') from stock_items s where s.active and s.avg_cost <= 0
  ) t);
end $$;

-- ---------------------------------------------------------------- exports: central ledger and monthly tax prep
create or replace function rsa__export2(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_kind text := p->>'kind'; v_from date := rsa_date(p, 'from', rsa_today() - 30); v_to date := rsa_date(p, 'to'); v jsonb;
begin
  if v_kind not in ('ledger', 'tax_monthly') then return rsa__export(u, p); end if;
  perform rsa_need(u, 'export.run');
  if v_kind = 'ledger' then
    select coalesce(jsonb_agg(x order by x->>'วันที่', x->>'เวลา', x->>'_id'), '[]') into v from (
      select jsonb_build_object(
        'วันที่', m.biz_date, 'เวลา', to_char(m.occurred_at at time zone 'Asia/Bangkok', 'HH24:MI'),
        'เลขที่เอกสาร', coalesce(o.order_no, e.expense_no, s.ref_no, to_char(d.biz_date, '"CLOSE-"YYYYMMDD'), ''),
        'ประเภทรายการ', case m.source_type when 'order' then 'รับเงินขาย' when 'order_refund' then 'คืนเงิน/ยกเลิกขาย' when 'expense' then 'จ่ายค่าใช้จ่าย'
                         when 'expense_reversal' then 'กลับรายการค่าใช้จ่าย' when 'settlement' then 'รับเงินแพลตฟอร์ม' when 'transfer' then 'โอนระหว่างบัญชี'
                         when 'capital' then 'เงินทุน/เงินกู้' when 'profit' then 'ใช้กำไร' when 'adjustment' then 'ปรับยอดเงินสดจากปิดยอด' else m.source_type end,
        'รายละเอียด', m.note,
        'หมวด/ภาษี', coalesce(e.tax_category, e.category_name, case when m.source_type in ('order','order_refund','settlement') then 'รายได้จากการขาย' end, ''),
        'บัญชี', a.name,
        'รับเข้า', case when m.direction = 'in' then m.amount else 0 end,
        'จ่ายออก', case when m.direction = 'out' then m.amount else 0 end,
        'คงเหลือบัญชี', a.opening_balance + sum(case m.direction when 'in' then m.amount else -m.amount end)
                           over (partition by m.account_id order by m.occurred_at, m.created_at, m.id),
        'ที่มา', m.source_type || ':' || m.source_id,
        'อ้างอิงธนาคาร', coalesce(m.bank_ref, e.pay_ref, s.ref_no, ''),
        'หลักฐาน', (select count(*) from attachments t where t.linked_id = m.source_id or (e.receipt_id is not null and t.linked_id = e.receipt_id)),
        'ผู้บันทึก', (select display_name from app_users where id = m.created_by),
        'ผู้อนุมัติ', (select display_name from app_users where id = e.approved_by),
        'สถานะ', coalesce(e.status, o.status, s.status, ''),
        'กระทบยอดแล้ว', case when m.reconciled_at is not null then 'ใช่' else '' end,
        'หมายเหตุ', coalesce(o.cancel_reason, e.cancel_reason, ''),
        '_id', m.id) x, m.biz_date bd
      from money_ledger m join payment_accounts a on a.id = m.account_id
      left join orders o on o.id = m.source_id and m.source_type in ('order','order_refund')
      left join expenses e on e.id = m.source_id and m.source_type in ('expense','expense_reversal')
      left join delivery_settlements s on s.id = m.source_id and m.source_type = 'settlement'
      left join daily_closes d on d.id = m.source_id and m.source_type = 'adjustment') t
    where bd between v_from and v_to;
    select coalesce(jsonb_agg(x - '_id'), '[]') into v from jsonb_array_elements(v) x;
  else
    select coalesce(jsonb_agg(x order by x->>'เดือน', x->>'ลำดับ'), '[]') into v from (
      select jsonb_build_object('เดือน', to_char(mo, 'YYYY-MM'), 'ลำดับ', '1', 'กลุ่ม', 'รายได้', 'รายการ', 'ยอดขายหน้าร้าน',
        'จำนวนเงิน', (select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and channel_kind = 'storefront' and date_trunc('month', biz_date) = mo),
        'จำนวนรายการ', (select count(*) from orders where status <> 'cancelled' and channel_kind = 'storefront' and date_trunc('month', biz_date) = mo), 'หมายเหตุ', '') x
        from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') mo
      union all
      select jsonb_build_object('เดือน', to_char(mo, 'YYYY-MM'), 'ลำดับ', '2', 'กลุ่ม', 'รายได้', 'รายการ', 'ยอดขาย Delivery (ก่อนหักค่าธรรมเนียม)',
        'จำนวนเงิน', (select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and channel_kind = 'delivery' and date_trunc('month', biz_date) = mo),
        'จำนวนรายการ', (select count(*) from orders where status <> 'cancelled' and channel_kind = 'delivery' and date_trunc('month', biz_date) = mo), 'หมายเหตุ', '')
        from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') mo
      union all
      select jsonb_build_object('เดือน', to_char(mo, 'YYYY-MM'), 'ลำดับ', '3', 'กลุ่ม', 'หักจากรายได้', 'รายการ', 'ค่าธรรมเนียมแพลตฟอร์ม',
        'จำนวนเงิน', (select coalesce(sum(fee), 0) from delivery_settlements where status = 'done' and date_trunc('month', period_to) = mo)
                    + (select coalesce(sum(est_fee), 0) from orders where status <> 'cancelled' and channel_kind = 'delivery' and settlement_id is null and date_trunc('month', biz_date) = mo),
        'จำนวนรายการ', (select count(*) from delivery_settlements where status = 'done' and date_trunc('month', period_to) = mo),
        'หมายเหตุ', 'ส่วนที่ยังไม่ได้รับเงินเป็นค่าประมาณ')
        from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') mo
      union all
      select jsonb_build_object('เดือน', to_char(mo, 'YYYY-MM'), 'ลำดับ', '4', 'กลุ่ม', 'ต้นทุน', 'รายการ', 'ต้นทุนขายประมาณ (จากสูตร)',
        'จำนวนเงิน', (select coalesce(sum(cost_total), 0) from orders where status <> 'cancelled' and date_trunc('month', biz_date) = mo),
        'จำนวนรายการ', null, 'หมายเหตุ', 'ค่าประมาณจากสูตรการใช้วัตถุดิบ')
        from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') mo
      union all
      select jsonb_build_object('เดือน', g.mo, 'ลำดับ', '5', 'กลุ่ม', 'ค่าใช้จ่าย', 'รายการ', g.cat,
        'จำนวนเงิน', g.amt, 'จำนวนรายการ', g.n, 'หมายเหตุ', case when g.noev > 0 then 'ไม่มีหลักฐาน ' || g.noev || ' รายการ' else '' end)
        from (select to_char(date_trunc('month', e.occurred_at at time zone 'Asia/Bangkok'), 'YYYY-MM') mo,
                     coalesce(e.tax_category, e.category_name, 'ไม่ระบุหมวด') cat, sum(e.amount) amt, count(*) n,
                     count(*) filter (where not exists (select 1 from attachments t where t.linked_id = e.id or t.linked_id = e.receipt_id)) noev
                from expenses e where e.status in ('จ่ายแล้ว','รอทำจ่าย') and rsa_bdate(e.occurred_at) between date_trunc('month', v_from)::date and v_to
               group by 1, 2) g
      union all
      select jsonb_build_object('เดือน', '', 'ลำดับ', '9', 'กลุ่ม', 'หมายเหตุ', 'รายการ', 'เอกสารนี้เป็นสรุปเตรียมข้อมูลให้นักบัญชี ไม่ใช่แบบยื่นภาษี',
        'จำนวนเงิน', null, 'จำนวนรายการ', null, 'หมายเหตุ', '')
    ) t;
  end if;
  perform rsa_audit(u, 'export', 'export', v_kind, null, null, jsonb_build_object('kind', v_kind, 'from', v_from, 'to', v_to, 'rows', jsonb_array_length(v)));
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
    when 'order.update'       then rsa__order_update(u, p)
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
    when 'stock.units'        then rsa__stock_units(u, p)
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
    when 'investment.save'    then rsa__investment_save(u, p)
    when 'payback.summary'    then rsa__payback_summary(u, p)
    when 'profit.declare'     then rsa__profit_declare(u, p)
    when 'profit.pay'         then rsa__profit_pay(u, p)
    when 'profit.cancel'      then rsa__profit_cancel(u, p)
    when 'ledger.list'        then rsa__ledger_list(u, p)
    when 'ledger.reconcile'   then rsa__ledger_reconcile(u, p)
    when 'bank.create'        then rsa__bank_create(u, p)
    when 'bank.list'          then rsa__bank_list(u, p)
    when 'bank.cancel'        then rsa__bank_cancel(u, p)
    when 'bank.recon'         then rsa__bank_recon(u, p)
    when 'cashflow.summary'   then rsa__cashflow_summary(u, p)
    when 'cashflow.forecast'  then rsa__cashflow_forecast(u, p)
    when 'dashboard'          then rsa__dashboard(u, p)
    when 'report.overview'    then rsa__report_overview(u, p)
    when 'report.sales'       then rsa__report_sales(u, p)
    when 'report.products'    then rsa__report_products(u, p)
    when 'report.delivery'    then rsa__report_delivery(u, p)
    when 'report.expenses'    then rsa__report_expenses(u, p)
    when 'report.staff'       then rsa__report_staff(u, p)
    when 'setup.checklist'    then rsa__setup_checklist(u, p)
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
    when 'export'             then rsa__export2(u, p)
    else (select jsonb_build_object('error', 'ไม่รู้จักคำสั่ง ' || p_action))
  end;
end $$;

