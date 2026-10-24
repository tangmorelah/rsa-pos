-- RSA - POS Assistant : the overview in one call (today live, KPIs, this month against the plan, what to do)
-- and the money plan by month (what must be paid, whether the money is there). Safe to run again.
set check_function_bodies = off;

-- ---------------------------------------------------------------- small helpers
create or replace function rsa_open_count(p_from date, p_to date) returns int language sql stable as $$
  select count(*)::int from generate_series(p_from, p_to, interval '1 day') g where p_from <= p_to and rsa_is_open(g::date)
$$;

-- delivery money expected in by a date (unsettled orders after the channel's settlement days)
create or replace function rsa_delivery_in(p_to date) returns numeric language sql stable as $$
  select coalesce(sum(o.total - o.refunded - o.est_fee), 0) from orders o join channels c on c.id = o.channel_id
   where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days <= p_to
$$;

create or replace function rsa_kpi_tone(v numeric, t numeric) returns text language sql immutable as $$
  select case when v is null or coalesce(t, 0) = 0 then 'none' when v >= t then 'ok' when v >= t * 0.85 then 'warn' else 'bad' end
$$;

create or replace function rsa_th_day(d date) returns text language sql immutable as $$
  select extract(day from d)::int || ' ' || (array['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.','ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'])[extract(month from d)::int]
$$;

-- ---------------------------------------------------------------- overview
create or replace function rsa__dashboard_home(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  t date := rsa_today(); m0 date; m1 date; v_dash jsonb; v_cc jsonb; v_sm jsonb; v_plan jsonb; kt jsonb;
  v_open_all int; v_open_done int; v_open_left int; v_target numeric; v_day_target numeric; v_to_date numeric; v_need numeric;
  v_today numeric; v_sf numeric; v_dl numeric; v_orders int; v_dl_n int; v_dl_avg numeric; v_sticks numeric; v_fruit numeric;
  v_fruit7 numeric; v_waste7 numeric; v_waste_pct numeric; v_kpis jsonb; v_cash numeric := rsa_cash_total(); v_min numeric := rsa_setting_num('min_working_capital', 0);
  v_lw jsonb; v_ratios jsonb; v_ratio_bad jsonb; v_net numeric; v_net_t numeric; v_checks jsonb := '[]'; v_level text;
  v_todo jsonb := '[]'; v_due14 numeric; v_spare numeric; v_now time := (now() at time zone 'Asia/Bangkok')::time; v_past int;
  v_live jsonb; v_tips jsonb := '[]'; v_k jsonb;
begin
  perform rsa_need(u, 'report.view');
  m0 := date_trunc('month', t)::date; m1 := (m0 + interval '1 month - 1 day')::date;
  v_dash := rsa__dashboard(u, jsonb_build_object('date', t));
  v_cc := rsa_costs_compute(t); v_sm := v_cc->'summary';
  v_plan := coalesce(rsa_setting('monthly_plan', '{}') -> to_char(m0, 'YYYY-MM'), '{}');
  kt := '{"meatball_sticks":115,"fruit_storefront":1350,"delivery_bills":6,"delivery_avg":140,"waste_pct":0.05}'::jsonb
        || case when jsonb_typeof(rsa_setting('kpi_targets')) = 'object' then rsa_setting('kpi_targets') else '{}' end;

  -- sales against the month target, paced by open days
  v_open_all := greatest(rsa_open_count(m0, m1), 1); v_open_done := rsa_open_count(m0, t); v_open_left := rsa_open_count(t + 1, m1);
  v_target := nullif(v_plan->>'sales_target', '')::numeric;
  v_day_target := coalesce(nullif(v_plan->>'daily_target', '')::numeric, case when v_target > 0 then round(v_target / v_open_all, 2) end);
  v_to_date := case when v_target > 0 then round(v_target * v_open_done / v_open_all, 2) end;
  v_need := case when v_target > 0 and v_open_left > 0 then greatest(round((v_target - (v_cc->>'sales')::numeric) / v_open_left, 2), 0) end;

  -- today's KPIs from the orders
  select coalesce(sum(total - refunded), 0), coalesce(sum(total - refunded) filter (where channel_kind = 'storefront'), 0),
         coalesce(sum(total - refunded) filter (where channel_kind = 'delivery'), 0), count(*), count(*) filter (where channel_kind = 'delivery')
    into v_today, v_sf, v_dl, v_orders, v_dl_n from orders where biz_date = t and status <> 'cancelled';
  v_dl_avg := case when v_dl_n > 0 then round(v_dl / v_dl_n, 2) end;
  select coalesce(sum(i.qty) filter (where pr.category ~ '(ลูกชิ้น|ทอด)'), 0), coalesce(sum(i.line_total) filter (where pr.category ~ 'ผลไม้'), 0)
    into v_sticks, v_fruit from order_items i join orders o on o.id = i.order_id left join products pr on pr.id = i.product_id
   where o.biz_date = t and o.status <> 'cancelled' and o.channel_kind = 'storefront';
  select coalesce(sum(i.line_total), 0) into v_fruit7 from order_items i join orders o on o.id = i.order_id join products pr on pr.id = i.product_id
   where o.biz_date between t - 6 and t and o.status <> 'cancelled' and pr.category ~ 'ผลไม้';
  select coalesce(sum(qty * unit_cost), 0) into v_waste7 from waste_records where status = 'recorded' and kind = 'waste' and biz_date between t - 6 and t;
  v_waste_pct := case when v_fruit7 > 0 then round(v_waste7 / v_fruit7, 3) end;
  v_kpis := jsonb_build_array(
    jsonb_build_object('key', 'today', 'label', 'ยอดวันนี้', 'value', v_today, 'unit', 'baht', 'target', v_day_target, 'tone', rsa_kpi_tone(v_today, v_day_target), 'href', 'sales'),
    jsonb_build_object('key', 'sticks', 'label', 'ลูกชิ้นหน้าร้าน', 'value', v_sticks, 'unit', 'ไม้', 'target', kt->'meatball_sticks', 'tone', rsa_kpi_tone(v_sticks, (kt->>'meatball_sticks')::numeric), 'href', 'products'),
    jsonb_build_object('key', 'fruit', 'label', 'ผลไม้หน้าร้าน', 'value', v_fruit, 'unit', 'baht', 'target', kt->'fruit_storefront', 'tone', rsa_kpi_tone(v_fruit, (kt->>'fruit_storefront')::numeric), 'href', 'products'),
    jsonb_build_object('key', 'bills', 'label', 'บิล Delivery', 'value', v_dl_n, 'unit', 'บิล', 'target', kt->'delivery_bills', 'tone', rsa_kpi_tone(v_dl_n, (kt->>'delivery_bills')::numeric), 'href', 'delivery'),
    jsonb_build_object('key', 'avg', 'label', 'เฉลี่ยต่อบิล Delivery', 'value', v_dl_avg, 'unit', 'baht', 'target', kt->'delivery_avg', 'tone', rsa_kpi_tone(v_dl_avg, (kt->>'delivery_avg')::numeric), 'href', 'delivery'),
    jsonb_build_object('key', 'waste', 'label', 'ของเสีย 7 วัน', 'value', v_waste_pct, 'unit', 'pct', 'target', kt->'waste_pct', 'max', true, 'href', 'products',
      'tone', case when v_waste_pct is null then 'none' when v_waste_pct <= (kt->>'waste_pct')::numeric then 'ok' when v_waste_pct <= (kt->>'waste_pct')::numeric * 1.4 then 'warn' else 'bad' end));

  -- business status: profit pace, money, raw-material cost (last complete week)
  select x into v_lw from jsonb_array_elements(v_cc->'weeks') x where (x->>'complete')::boolean order by x->>'from' desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('key', r.key, 'ratio', (r.value->>'ratio')::numeric, 'limit', r.value->'limit')), '[]') into v_ratios
    from jsonb_each(coalesce(v_lw->'ratios', '{}')) r where r.key in ('fruit', 'meatball') and r.value->>'ratio' is not null;
  select coalesce(jsonb_agg(x), '[]') into v_ratio_bad from jsonb_array_elements(v_ratios) x where x->>'limit' is not null and (x->>'ratio')::numeric > (x->>'limit')::numeric;
  v_net := (v_sm->>'net_profit')::numeric; v_net_t := nullif(v_sm->>'net_target_to_date', '')::numeric;
  if v_min > 0 and v_cash < v_min then v_checks := v_checks || jsonb_build_array(jsonb_build_array('bad', 'เงินต่ำกว่าเงินหมุนขั้นต่ำ ' || to_char(v_min - v_cash, 'FM999,999,990') || ' บาท')); end if;
  if v_net < 0 then v_checks := v_checks || jsonb_build_array(jsonb_build_array('bad', 'เดือนนี้ยังขาดทุน ' || to_char(-v_net, 'FM999,999,990') || ' บาท')); end if;
  if v_net_t > 0 and v_net >= 0 and v_net < v_net_t then v_checks := v_checks || jsonb_build_array(jsonb_build_array('warn', 'กำไรยังต่ำกว่าเป้า ' || to_char(v_net_t - v_net, 'FM999,999,990') || ' บาท')); end if;
  if v_to_date > 0 and (v_cc->>'sales')::numeric < v_to_date * 0.95 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_array('warn', 'ยอดขายช้ากว่าเป้า ' || round((1 - (v_cc->>'sales')::numeric / v_to_date) * 100) || '%')); end if;
  select v_checks || coalesce(jsonb_agg(jsonb_build_array('warn', 'ต้นทุน' || case x->>'key' when 'fruit' then 'ผลไม้' else 'ลูกชิ้น' end || 'เกินเกณฑ์')), '[]')
    into v_checks from jsonb_array_elements(v_ratio_bad) x;
  v_level := case when exists (select 1 from jsonb_array_elements(v_checks) c where c->>0 = 'bad') then 'bad' when jsonb_array_length(v_checks) > 0 then 'warn' else 'ok' end;

  -- to do: today's close first, a loan installment the money cannot cover, then the usual list
  if v_dash->'close' is null or jsonb_typeof(v_dash->'close') = 'null' then
    if not (v_dash->>'holiday')::boolean then
      v_todo := v_todo || jsonb_build_object('kind', 'close_today', 'level', 'bad', 'text', 'ปิดยอดวันนี้', 'sub', 'ส่งภายใน ' || (v_dash->>'due_time') || ' น.', 'act', 'ไป');
    end if;
  end if;
  v_due14 := rsa_debt_due(t + 14); v_spare := v_cash - v_min;
  if v_due14 > 0 and v_spare < v_due14 then
    v_todo := v_todo || jsonb_build_object('kind', 'debt_short', 'level', 'bad', 'text', 'เตรียมเงินผ่อนเงินกู้ลงทุน ขาด ' || to_char(v_due14 - v_spare, 'FM999,999,990') || ' บาท',
      'sub', 'งวดครบกำหนดภายใน 14 วัน ' || to_char(v_due14, 'FM999,999,990') || ' บาท', 'act', 'ดู');
  end if;
  select v_todo || coalesce(jsonb_agg(e || jsonb_build_object('level', case when e->>'level' = 'warn' then 'warn' else 'info' end, 'act', 'ดู')), '[]')
    into v_todo from jsonb_array_elements(v_dash->'exceptions') e where e->>'kind' <> 'close_today';
  select coalesce(jsonb_agg(x order by case x->>'level' when 'bad' then 0 when 'warn' then 1 else 2 end, n), '[]') into v_todo
    from jsonb_array_elements(v_todo) with ordinality a(x, n);

  -- live: today so far against the same weekday last week at the same time, and by hour against the last 4 same weekdays
  select count(distinct biz_date) into v_past from orders where status <> 'cancelled' and biz_date in (t - 7, t - 14, t - 21, t - 28);
  v_live := jsonb_build_object('sales', v_today, 'orders', v_orders, 'storefront', v_sf, 'delivery', v_dl, 'target', v_day_target,
    'last_week', (select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and biz_date = t - 7 and (created_at at time zone 'Asia/Bangkok')::time <= v_now),
    'last_at', (select max(created_at) from orders where status <> 'cancelled' and biz_date = t),
    'now', to_char(v_now, 'HH24:MI'),
    'hours', (select jsonb_agg(jsonb_build_object('h', h,
        'today', (select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and biz_date = t and extract(hour from created_at at time zone 'Asia/Bangkok') = h),
        'avg', case when v_past > 0 then round((select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and biz_date in (t - 7, t - 14, t - 21, t - 28)
                                                and extract(hour from created_at at time zone 'Asia/Bangkok') = h) / v_past, 2) else 0 end) order by h)
              from generate_series(9, 22) h));

  -- what to do about the numbers (rules from the owner's alert sheet)
  if v_need is not null and v_day_target > 0 and v_need > v_day_target * 1.1 then
    v_tips := v_tips || to_jsonb('ยอดเดือนตามหลังเป้า ต้องขายเพิ่มเป็นวันละ ' || to_char(v_need, 'FM999,999,990') || ' บาท · ดันชุดคู่ / กล่องรวม 49 และเปิดแอดเฉพาะแอปที่ได้ออเดอร์'); end if;
  select x into v_k from jsonb_array_elements(v_kpis) x where x->>'key' = 'sticks';
  if v_k->>'tone' in ('warn', 'bad') then v_tips := v_tips || to_jsonb('ลูกชิ้นหน้าร้านต่ำกว่าเป้า · เช็กของพอขาย คุณภาพการทอด และชวนลูกค้าเพิ่มไม้'::text); end if;
  select x into v_k from jsonb_array_elements(v_kpis) x where x->>'key' = 'avg';
  if v_k->>'tone' in ('warn', 'bad') and v_dl_n > 0 then v_tips := v_tips || to_jsonb('บิล Delivery เล็ก · ดัน Family Set / ลูกชิ้น Mix 10 และเสนอ add-on'::text); end if;
  select x into v_k from jsonb_array_elements(v_kpis) x where x->>'key' = 'waste';
  if v_k->>'tone' in ('warn', 'bad') then v_tips := v_tips || to_jsonb('ของเสียสูง · ลดปริมาณซื้อรอบหน้า และใช้ราคาลดตอนเย็น'::text); end if;
  if jsonb_array_length(v_ratio_bad) > 0 then v_tips := v_tips || to_jsonb('ต้นทุนวัตถุดิบเกินเกณฑ์ · เช็กราคาซื้อ yield และขนาดกล่อง'::text); end if;

  return jsonb_build_object('date', t, 'month', to_char(m0, 'YYYY-MM'), 'holiday', v_dash->'holiday', 'close', v_dash->'close', 'due_time', v_dash->'due_time',
    'live', v_live, 'tips', (select coalesce(jsonb_agg(x), '[]') from (select x from jsonb_array_elements(v_tips) x limit 3) y),
    'status', jsonb_build_object('level', v_level, 'reasons', (select coalesce(jsonb_agg(c->>1), '[]') from jsonb_array_elements(v_checks) c),
      'net_profit', v_net, 'net_target_to_date', v_net_t, 'net_target', v_sm->'net_target', 'cash', v_cash, 'min_cash', v_min, 'ratios', v_ratios,
      'complete', v_sm->'complete', 'flags', v_sm->'flags'),
    'sales', jsonb_build_object('month', v_cc->'sales', 'target', v_target, 'to_date', v_to_date, 'need_per_day', v_need, 'open_left', v_open_left,
      'open_done', v_open_done, 'open_all', v_open_all, 'day_target', v_day_target),
    'kpis', v_kpis, 'todo', v_todo);
end $$;

-- ---------------------------------------------------------------- money plan by month (rest of this month + next 2)
create or replace function rsa__cashflow_months(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  t date := rsa_today(); v_cash numeric := rsa_cash_total(); v_min numeric := rsa_setting_num('min_working_capital', 0);
  v_sales numeric; v_spend numeric; v_out jsonb; v_paid numeric; v_months jsonb := '[]'; k int; m0 date; m1 date; v_from date;
  v_items jsonb; v_lines jsonb; v_start numeric; v_inflow numeric; v_total numeric; v_end numeric; v_short numeric; v_wage int; v_loan numeric; v_advice text;
begin
  perform rsa_need(u, 'cashflow.view');
  if rsa_has(u, 'expense.approve') then perform rsa_fixed_generate(u, date_trunc('month', t)::date); end if;
  select coalesce(sum(total - refunded), 0) / rsa_open_days(t - 14, t - 1) into v_sales from orders
   where channel_kind = 'storefront' and status <> 'cancelled' and biz_date between t - 14 and t - 1;
  select coalesce(sum(amount), 0) / 30 into v_spend from expenses
   where status = 'จ่ายแล้ว' and fixed_expense_id is null and rsa_bdate(paid_at) between t - 30 and t - 1;
  v_paid := coalesce((select sum(amount) from capital_entries where kind = 'loan_repayment' and status = 'done'), 0);

  -- every payment due from tomorrow on: open bills, recurring costs not billed yet, loan installments still unpaid
  select coalesce(jsonb_agg(x), '[]') into v_out from (
    select jsonb_build_object('date', greatest(coalesce(e.due_date, rsa_bdate(e.occurred_at)), t + 1), 'amount', e.amount,
             'group', case when e.tax_category = 'เงินเดือนและค่าจ้าง' then 'wage' when e.fixed_expense_id is not null then 'fixed' else 'bill' end,
             'name', coalesce((select name from fixed_expenses f where f.id = e.fixed_expense_id), e.description)) x
      from expenses e where e.status in ('รออนุมัติ','รอทำจ่าย')
    union all
    select jsonb_build_object('date', d, 'amount', f.amount, 'group', case when c.tax_category = 'เงินเดือนและค่าจ้าง' then 'wage' else 'fixed' end, 'name', f.name)
      from fixed_expenses f left join expense_categories c on c.id = f.category_id
      cross join lateral rsa_fixed_dates(f, (date_trunc('month', t) + interval '1 month')::date, t + 100) d
     where f.active and f.confirmed
    union all
    select jsonb_build_object('date', greatest(s.due, t + 1), 'amount', s.left_amt, 'group', 'loan', 'name', 'ผ่อนเงินกู้ลงทุน งวด ' || s.n)
      from (select (v->>'due')::date due, n, greatest(least((v->>'amount')::numeric, sum((v->>'amount')::numeric) over (order by v->>'due', n) - v_paid), 0) left_amt
              from jsonb_array_elements(case when jsonb_typeof(rsa_setting('debt_schedule')) = 'array' then rsa_setting('debt_schedule') else '[]' end) with ordinality a(v, n)) s
     where s.left_amt > 0) q;

  for k in 0..2 loop
    m0 := (date_trunc('month', t) + make_interval(months => k))::date; m1 := (m0 + interval '1 month - 1 day')::date;
    v_from := case when k = 0 then t + 1 else m0 end;
    select coalesce(jsonb_agg(x), '[]') into v_items from jsonb_array_elements(v_out) x where (x->>'date')::date between v_from and m1;
    select coalesce(jsonb_agg(jsonb_build_object('name', g.key, 'group', g.grp, 'amount', g.amount, 'rounds', g.rounds,
             'label', case g.grp when 'wage' then 'ค่าจ้าง ' || g.rounds || ' รอบ' when 'loan' then g.key || ' · ' || rsa_th_day(g.first_date)
                                 when 'bill' then 'ค้างจ่ายอื่น ' || g.rounds || ' รายการ' else g.key || case when g.rounds > 1 then ' ' || g.rounds || ' รอบ' else '' end end)
             order by case g.grp when 'loan' then 0 when 'wage' then 1 when 'fixed' then 2 else 3 end, g.amount desc), '[]') into v_lines
      from (select case x->>'group' when 'wage' then 'ค่าจ้าง' when 'bill' then 'ค่าใช้จ่ายค้างจ่าย' else x->>'name' end key, min(x->>'group') grp,
                   sum((x->>'amount')::numeric) amount, count(*)::int rounds, min((x->>'date')::date) first_date
              from jsonb_array_elements(v_items) x group by 1) g;
    v_start := case when k = 0 then v_cash else
      round(v_cash + v_sales * rsa_open_count(t + 1, m0 - 1) + rsa_delivery_in(m0 - 1) - v_spend * (m0 - 1 - t)
            - (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_out) x where (x->>'date')::date <= m0 - 1), 2) end;
    v_inflow := round(v_sales * rsa_open_count(v_from, m1) + rsa_delivery_in(m1) - rsa_delivery_in(v_from - 1) - v_spend * (m1 - v_from + 1), 2);
    v_total := (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_items) x);
    v_end := round(v_start + v_inflow - v_total, 2);
    v_short := case when v_end < v_min then round(v_min - v_end, 2) else 0 end;
    v_wage := (select count(*) from jsonb_array_elements(v_items) x where x->>'group' = 'wage');
    v_loan := (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_items) x where x->>'group' = 'loan');
    v_advice := case when v_short > 0 and v_loan > 0 then 'เตรียมเงินเติมจากเจ้าของ หรือคุยขอเลื่อนงวดเงินกู้ลงทุน'
                     when v_short > 0 then 'ลดการซื้อที่ไม่จำเป็น และตามเงิน Delivery ที่ค้าง'
                     when v_wage >= 5 then 'เดือนนี้จ่ายค่าจ้าง 5 รอบ กันเงินเพิ่ม 1 รอบ' else '' end;
    v_months := v_months || jsonb_build_object('month', to_char(m0, 'YYYY-MM'), 'from', v_from, 'to', m1, 'partial', k = 0, 'start_cash', v_start,
      'inflow', v_inflow, 'total', v_total, 'end_cash', v_end, 'short', v_short, 'wage_rounds', v_wage, 'loan', v_loan, 'lines', v_lines, 'advice', v_advice,
      'status', case when v_short > 0 then 'short' when v_wage >= 5 then 'five' else 'ok' end);
  end loop;

  return jsonb_build_object('today', t, 'cash', v_cash, 'min_cash', v_min, 'months', v_months,
    'daily', (select jsonb_agg(jsonb_build_object('date', t + n,
        'balance', case when n = 0 then v_cash else round(v_cash + v_sales * rsa_open_count(t + 1, t + n) + rsa_delivery_in(t + n) - v_spend * n
                     - (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_out) x where (x->>'date')::date <= t + n), 2) end,
        'loan', (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_out) x where x->>'group' = 'loan' and (x->>'date')::date = t + n))
      order by n) from generate_series(0, 60) n));
end $$;
