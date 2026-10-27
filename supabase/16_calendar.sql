-- RSA - POS Assistant : money in / out calendar for a month (owner's expenses page).
-- Past days and today: what really moved in the accounts (transfers between the shop's own accounts are left out).
-- Days ahead: what is scheduled — bills due, recurring costs not billed yet, investment-loan installments, delivery payouts due.
set check_function_bodies = off;

create or replace function rsa__cashflow_calendar(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  t date := rsa_today(); m0 date := date_trunc('month', coalesce(rsa_date(p, 'month'), rsa_today()))::date; m1 date;
  v_paid numeric; v_actual jsonb; v_plan jsonb; v_days jsonb;
begin
  perform rsa_need(u, 'cashflow.view');
  m1 := (m0 + interval '1 month - 1 day')::date;
  if rsa_has(u, 'expense.approve') then perform rsa_fixed_generate(u, m0); end if;
  v_paid := coalesce((select sum(amount) from capital_entries where kind = 'loan_repayment' and status = 'done'), 0);

  -- what really happened, grouped by what it was
  select coalesce(jsonb_agg(jsonb_build_object('date', d, 'dir', dir, 'label', label, 'amount', amt, 'count', n)), '[]') into v_actual from (
    select m.biz_date d, m.direction dir,
           case m.source_type
             when 'order' then 'ขาย' when 'order_refund' then 'คืนเงิน / ยกเลิกขาย' when 'settlement' then 'เงินเข้า Delivery'
             when 'adjustment' then 'ผลต่างเงินสดปิดยอด' when 'profit' then 'ใช้กำไร'
             when 'expense' then coalesce((select case when e.fund_source = 'payroll' then 'ค่าจ้าง' else e.category_name end from expenses e where e.id = m.source_id), 'ค่าใช้จ่าย')
             when 'expense_reversal' then 'กลับรายการค่าใช้จ่าย'
             when 'capital' then coalesce((select case c.kind when 'loan_repayment' then 'ผ่อนเงินกู้ลงทุน' when 'capital_in' then 'เงินเติมจากเจ้าของ'
                                                  when 'loan_in' then 'เงินกู้เข้า' when 'capital_return' then 'ถอนทุน' else 'ทุน' end
                                             from capital_entries c where c.id = m.source_id), 'ทุน')
             else m.source_type end label,
           sum(m.amount) amt, count(*) n
      from money_ledger m
     where m.biz_date between m0 and least(m1, t) and m.source_type <> 'transfer'
     group by 1, 2, 3) x;

  -- what is scheduled from tomorrow on
  select coalesce(jsonb_agg(jsonb_build_object('date', d, 'dir', dir, 'label', label, 'amount', amt, 'count', n, 'kind', kind)), '[]') into v_plan from (
    select d, dir, label, kind, sum(amt) amt, count(*) n from (
      select coalesce(e.due_date, rsa_bdate(e.occurred_at)) d, 'out' dir,
             case when e.tax_category = 'เงินเดือนและค่าจ้าง' then 'ค่าจ้าง' when e.fixed_expense_id is not null then coalesce((select name from fixed_expenses f where f.id = e.fixed_expense_id), e.category_name) else e.category_name end label,
             'bill' kind, e.amount amt
        from expenses e where e.status in ('รออนุมัติ','รอทำจ่าย') and coalesce(e.due_date, rsa_bdate(e.occurred_at)) > t
      union all
      select d, 'out', case when c.tax_category = 'เงินเดือนและค่าจ้าง' then 'ค่าจ้าง' else f.name end, 'fixed', f.amount
        from fixed_expenses f left join expense_categories c on c.id = f.category_id
        cross join lateral rsa_fixed_dates(f, greatest(t + 1, m0), m1) d
       where f.active and f.confirmed and f.amount > 0
         and not exists (select 1 from expenses x where x.fixed_expense_id = f.id
                          and x.period = case when f.frequency = 'weekly' then to_char(d, 'YYYY-MM-DD') else to_char(d, 'YYYY-MM') end)
      union all
      select s.due, 'out', 'ผ่อนเงินกู้ลงทุน งวด ' || s.n, 'loan', s.left_amt
        from (select (v->>'due')::date due, n, greatest(least((v->>'amount')::numeric, sum((v->>'amount')::numeric) over (order by v->>'due', n) - v_paid), 0) left_amt
                from jsonb_array_elements(case when jsonb_typeof(rsa_setting('debt_schedule')) = 'array' then rsa_setting('debt_schedule') else '[]' end) with ordinality a(v, n)) s
       where s.left_amt > 0 and s.due > t
      union all
      select o.biz_date + c.settlement_days, 'in', 'เงินเข้า ' || c.name, 'delivery', o.total - o.refunded - o.est_fee
        from orders o join channels c on c.id = o.channel_id
       where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days > t
    ) z where d between m0 and m1 group by 1, 2, 3, 4) y;

  select jsonb_agg(jsonb_build_object('date', g::date, 'future', g::date > t,
           'in', (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(case when g::date > t then v_plan else v_actual end) x where (x->>'date')::date = g::date and x->>'dir' = 'in'),
           'out', (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(case when g::date > t then v_plan else v_actual end) x where (x->>'date')::date = g::date and x->>'dir' = 'out'),
           'items', (select coalesce(jsonb_agg(x order by x->>'dir', (x->>'amount')::numeric desc), '[]') from jsonb_array_elements(case when g::date > t then v_plan else v_actual end) x where (x->>'date')::date = g::date))
         order by g) into v_days
    from generate_series(m0, m1, interval '1 day') g;

  return jsonb_build_object('month', to_char(m0, 'YYYY-MM'), 'today', t, 'days', v_days,
    'summary', jsonb_build_object(
      'in', jsonb_build_object('count', (select coalesce(sum((x->>'count')::int), 0) from jsonb_array_elements(v_actual) x where x->>'dir' = 'in'),
                               'amount', (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_actual) x where x->>'dir' = 'in')),
      'out', jsonb_build_object('count', (select coalesce(sum((x->>'count')::int), 0) from jsonb_array_elements(v_actual) x where x->>'dir' = 'out'),
                                'amount', (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_actual) x where x->>'dir' = 'out')),
      'overdue_in', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(o.total - o.refunded - o.est_fee), 0)) from orders o join channels c on c.id = o.channel_id
                      where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days < t),
      'overdue_out', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0)) from expenses
                       where status in ('รออนุมัติ','รอทำจ่าย') and coalesce(due_date, rsa_bdate(occurred_at)) < t),
      'expect_in', jsonb_build_object('count', (select coalesce(sum((x->>'count')::int), 0) from jsonb_array_elements(v_plan) x where x->>'dir' = 'in'),
                                      'amount', (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_plan) x where x->>'dir' = 'in')),
      'expect_out', jsonb_build_object('count', (select coalesce(sum((x->>'count')::int), 0) from jsonb_array_elements(v_plan) x where x->>'dir' = 'out'),
                                       'amount', (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_plan) x where x->>'dir' = 'out'))));
end $$;

-- recurring costs and investment-loan installments in one list (owner's expenses page)
create or replace function rsa__recurring_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare t date := rsa_today(); v_paid numeric := coalesce((select sum(amount) from capital_entries where kind = 'loan_repayment' and status = 'done'), 0);
begin
  perform rsa_need(u, 'expense.view_all');
  return jsonb_build_object(
    'fixed', (select coalesce(jsonb_agg(to_jsonb(f) || jsonb_build_object('category_name', (select name from expense_categories where id = f.category_id),
                 'next_due', (select min(d) from rsa_fixed_dates(f, t, t + 62) d),
                 'open_bill', (select jsonb_build_object('id', e.id, 'status', e.status, 'due_date', e.due_date, 'amount', e.amount) from expenses e
                                where e.fixed_expense_id = f.id and e.status in ('รออนุมัติ','รอทำจ่าย') order by e.due_date limit 1))
               order by f.active desc, f.frequency desc, f.due_day, f.name), '[]') from fixed_expenses f),
    'loan', (select coalesce(jsonb_agg(jsonb_build_object('n', n, 'due', due, 'amount', amt, 'paid', amt - left_amt, 'left', left_amt) order by due), '[]')
               from (select (v->>'due')::date due, n, (v->>'amount')::numeric amt,
                            greatest(least((v->>'amount')::numeric, sum((v->>'amount')::numeric) over (order by v->>'due', n) - v_paid), 0) left_amt
                       from jsonb_array_elements(case when jsonb_typeof(rsa_setting('debt_schedule')) = 'array' then rsa_setting('debt_schedule') else '[]' end) with ordinality a(v, n)) s));
end $$;
