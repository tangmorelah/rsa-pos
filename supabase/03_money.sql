-- RSA - POS Assistant : expenses, daily close, cashflow
set check_function_bodies = off;

-- ---------------------------------------------------------------- expenses
create or replace function rsa_expense_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(e) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = e.created_by),
    'approved_by_name', (select display_name from app_users where id = e.approved_by),
    'paid_by_name', (select display_name from app_users where id = e.paid_by),
    'employee_name', (select display_name from app_users where id = e.paid_by_employee),
    'account_name', (select name from payment_accounts where id = e.pay_account_id),
    'attachments', rsa_attachment_refs('expense', e.id) || coalesce(rsa_attachment_refs('receipt', e.receipt_id), '[]'))
  from expenses e where e.id = p_id
$$;

create or replace function rsa__expense_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid;
begin
  v_id := rsa_expense_insert(u, p);   -- separate statement so the read below sees the new row
  return rsa_expense_json(v_id);
end $$;

create or replace function rsa__expense_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'expense.add');
  return (select coalesce(jsonb_agg(rsa_expense_json(e.id) order by e.occurred_at desc), '[]') from
    (select * from expenses e0
      where (rsa_has(u, 'expense.view_all') or e0.created_by = u.id)
        and (nullif(p->>'status', '') is null or e0.status = p->>'status')
        and (nullif(p->>'from', '') is null or rsa_bdate(e0.occurred_at) >= (p->>'from')::date)
        and (nullif(p->>'to', '') is null or rsa_bdate(e0.occurred_at) <= (p->>'to')::date)
        and (not coalesce((p->>'unreviewed')::boolean, false) or (e0.status = 'จ่ายแล้ว' and not e0.reviewed))
      order by e0.occurred_at desc limit 300) e);
end $$;

create or replace function rsa__expense_approve(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v expenses;
begin
  perform rsa_need(u, 'expense.approve');
  select * into v from expenses where id = rsa_uuid(p, 'expense_id') for update;
  if not found then perform rsa_err('ไม่พบรายการ'); end if;
  if v.status = 'รออนุมัติ' then
    update expenses set status = 'รอทำจ่าย', approved_at = now(), approved_by = u.id where id = v.id;
  elsif v.status = 'จ่ายแล้ว' and not v.reviewed then
    update expenses set reviewed = true, approved_at = now(), approved_by = u.id where id = v.id;
  else
    perform rsa_err('รายการนี้ไม่อยู่ในสถานะที่อนุมัติได้');
  end if;
  perform rsa_audit(u, 'expense.approve', 'expense', v.id::text, jsonb_build_object('status', v.status, 'reviewed', v.reviewed),
                    (select jsonb_build_object('status', status, 'reviewed', reviewed) from expenses where id = v.id));
  return rsa_expense_json(v.id);
end $$;

create or replace function rsa__expense_pay(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v expenses; v_acc uuid := rsa_uuid(p, 'account_id'); v_at timestamptz := rsa_ts(p, 'paid_at');
begin
  perform rsa_need(u, 'expense.pay');
  select * into v from expenses where id = rsa_uuid(p, 'expense_id') for update;
  if not found then perform rsa_err('ไม่พบรายการ'); end if;
  if v.status = 'รออนุมัติ' then
    perform rsa_need(u, 'expense.approve');
  elsif v.status <> 'รอทำจ่าย' then
    perform rsa_err('รายการนี้จ่ายไม่ได้ (สถานะ ' || v.status || ')');
  end if;
  if v_acc is null then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
  update expenses set status = 'จ่ายแล้ว', pay_account_id = v_acc, paid_at = v_at, paid_by = u.id, reviewed = true,
         approved_at = coalesce(approved_at, now()), approved_by = coalesce(approved_by, u.id),
         reimbursed = (paid_by_employee is not null) where id = v.id;
  perform rsa_money(v_acc, 'out', v.amount, 'expense', v.id,
    case when v.paid_by_employee is not null then 'คืนเงินพนักงาน: ' else '' end || v.description, u.id, v_at);
  perform rsa_link_attachments(p->'attachment_ids', 'expense', v.id, u);
  perform rsa_audit(u, 'expense.pay', 'expense', v.id::text, jsonb_build_object('status', v.status),
                    jsonb_build_object('status', 'จ่ายแล้ว', 'account_id', v_acc, 'amount', v.amount));
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
  update expenses set status = 'ยกเลิก', cancelled_at = now(), cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  if v.status = 'จ่ายแล้ว' then
    perform rsa_money(v.pay_account_id, 'in', v.amount, 'expense_reversal', v.id, 'กลับรายการ ' || v.expense_no, u.id);
  end if;
  perform rsa_audit(u, 'expense.cancel', 'expense', v.id::text, jsonb_build_object('status', v.status, 'amount', v.amount),
                    jsonb_build_object('status', 'ยกเลิก'), jsonb_build_object('reason', p->>'reason'));
  return rsa_expense_json(v.id);
end $$;

-- fixed monthly expenses
create or replace function rsa_fixed_generate(u app_users, p_month date) returns int language plpgsql as $$
declare f fixed_expenses; v_period text := to_char(p_month, 'YYYY-MM'); v_due date; n int := 0; v_id uuid;
begin
  for f in select * from fixed_expenses where active and start_month <= p_month and (end_month is null or end_month >= p_month) loop
    v_due := least(date_trunc('month', p_month)::date + (f.due_day - 1), (date_trunc('month', p_month) + interval '1 month - 1 day')::date);
    v_id := gen_random_uuid();
    insert into expenses(id, expense_no, occurred_at, due_date, category_id, category_name, tax_category, payee, description, amount, status,
                         pay_account_id, fixed_expense_id, period, created_by, approved_at, approved_by)
    select v_id, rsa_next_no('E'), v_due::timestamptz, v_due, f.category_id, c.name, c.tax_category, f.payee, f.name || ' (' || v_period || ')', f.amount,
           case when f.auto_approve then 'รอทำจ่าย' else 'รออนุมัติ' end, f.account_id, f.id, v_period, u.id,
           case when f.auto_approve then now() end, case when f.auto_approve then u.id end
      from (select 1) one left join expense_categories c on c.id = f.category_id
     where f.amount > 0
    on conflict (fixed_expense_id, period) do nothing;
    if found then n := n + 1; end if;
  end loop;
  if n > 0 then perform rsa_audit(u, 'fixed.generate', 'fixed_expense', v_period, null, jsonb_build_object('created', n)); end if;
  return n;
end $$;

create or replace function rsa__fixed_generate(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'expense.approve');
  return jsonb_build_object('created', rsa_fixed_generate(u, date_trunc('month', rsa_date(p, 'month'))::date));
end $$;

create or replace function rsa__fixed_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'expense.view_all');
  return (select coalesce(jsonb_agg(to_jsonb(f) || jsonb_build_object(
            'category_name', (select name from expense_categories where id = f.category_id),
            'this_month', (select jsonb_build_object('id', e.id, 'status', e.status, 'due_date', e.due_date) from expenses e
                            where e.fixed_expense_id = f.id and e.period = to_char(rsa_today(), 'YYYY-MM'))) order by f.due_day), '[]')
          from fixed_expenses f);
end $$;

-- ---------------------------------------------------------------- daily close
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
          'cancelled_orders', count(o.id) filter (where o.status = 'cancelled'),
          'cancelled_amount', coalesce(sum(o.total) filter (where o.status = 'cancelled'), 0)) x
        from channels c left join orders o on o.channel_id = c.id and o.biz_date = p_date
        where c.active or o.id is not null
        group by c.id) t),
    'total_net', (select coalesce(sum(total - refunded), 0) from orders where biz_date = p_date and status <> 'cancelled'),
    'orders_count', (select count(*) from orders where biz_date = p_date and status <> 'cancelled'),
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
                      from expenses e where e.pay_account_id = v_drawer and rsa_bdate(e.paid_at) = p_date),
    'waste_rows', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'item_name', w.item_name, 'qty', w.qty, 'unit', w.unit,
                        'reason', w.reason, 'status', w.status) order by w.occurred_at), '[]')
                      from waste_records w where w.biz_date = p_date and w.status = 'recorded')
  ) into v;
  return v || jsonb_build_object('expected_cash',
     (v->>'starting_cash')::numeric + (v->>'cash_in_orders')::numeric - (v->>'cash_out_refunds')::numeric
     - (v->>'cash_out_expenses')::numeric - (v->>'cash_transfers_net_out')::numeric + (v->>'cash_other_adjust')::numeric);
end $$;

create or replace function rsa_close_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(d) || jsonb_build_object(
    'submitted_by_name', (select display_name from app_users where id = d.submitted_by),
    'coworker_names', (select coalesce(jsonb_agg(display_name), '[]') from app_users where id = any(d.coworker_ids)),
    'reviewed_by_name', (select display_name from app_users where id = d.reviewed_by),
    'revisions', (select coalesce(jsonb_agg(jsonb_build_object('revision', r.revision, 'reason', r.reason, 'at', r.created_at,
                    'by', (select display_name from app_users where id = r.created_by)) order by r.revision), '[]')
                  from daily_close_revisions r where r.close_id = d.id),
    'stocktake', case when d.stocktake_id is not null then rsa_stocktake_json(d.stocktake_id) end,
    'late_entries', (select count(*) from money_ledger m where m.biz_date = d.biz_date and m.created_at > d.submitted_at
                      and not (m.source_type = 'adjustment' and m.source_id = d.id)))
  from daily_closes d where d.id = p_id
$$;

create or replace function rsa__close_preview(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_date date := rsa_date(p, 'date'); v_close uuid;
begin
  if not (rsa_has(u, 'closing.add') or rsa_has(u, 'closing.view_all')) then perform rsa_need(u, 'closing.add'); end if;
  select id into v_close from daily_closes where biz_date = v_date;
  return jsonb_build_object('computed', rsa_close_compute(v_date),
    'close', case when v_close is not null then rsa_close_json(v_close) end,
    'stock', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'unit', s.unit, 'system_qty', rsa_stock_qty(s.id)) order by s.name), '[]')
                from stock_items s where s.active),
    'due_time', coalesce((select value #>> '{}' from settings where key = 'close_due_time'), '21:00'));
end $$;

create or replace function rsa__close_submit(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_date date := rsa_date(p, 'date'); c jsonb; v_id uuid := gen_random_uuid(); v_start numeric; v_sys_start numeric;
  v_counted numeric := rsa_num(p, 'counted_cash'); v_expected numeric; v_var numeric; v_adj numeric; v_st uuid;
  v_tol numeric := coalesce((select (value #>> '{}')::numeric from settings where key = 'cash_variance_tolerance'), 0);
  v_adjs jsonb := coalesce(p->'adjustments', '[]');
begin
  perform rsa_need(u, 'closing.add');
  perform pg_advisory_xact_lock(hashtext('close' || v_date));
  if exists (select 1 from daily_closes where biz_date = v_date) then
    perform rsa_err('วันที่ ' || to_char(v_date, 'DD/MM/YYYY') || ' ส่งรายงานปิดยอดแล้ว หากต้องแก้ไขให้เจ้าของร้านแก้ในหน้าประวัติ');
  end if;
  if v_date > rsa_today() then perform rsa_err('ยังปิดยอดล่วงหน้าไม่ได้'); end if;
  if v_counted is null or v_counted < 0 then perform rsa_err('กรุณาใส่ยอดเงินสดที่นับได้จริง'); end if;
  c := rsa_close_compute(v_date);
  v_sys_start := (c->>'starting_cash')::numeric;
  v_start := coalesce(rsa_num(p, 'starting_cash'), v_sys_start);
  if v_start <> v_sys_start then
    if coalesce(trim(p->>'starting_cash_reason'), '') = '' then perform rsa_err('แก้เงินตั้งต้นต้องใส่เหตุผล'); end if;
    v_adjs := v_adjs || jsonb_build_array(jsonb_build_object('field', 'starting_cash', 'label', 'เงินตั้งต้น',
               'original', v_sys_start, 'corrected', v_start, 'reason', p->>'starting_cash_reason'));
  end if;
  v_expected := (c->>'expected_cash')::numeric - v_sys_start + v_start;
  v_var := v_counted - v_expected;
  if abs(v_var) > v_tol and coalesce(trim(p->>'variance_reason'), '') = '' then
    perform rsa_err('เงินสด' || case when v_var < 0 then 'ขาด ' else 'เกิน ' end || abs(v_var) || ' บาท กรุณาใส่คำอธิบาย');
  end if;

  if jsonb_typeof(p->'stock_counts') = 'array' and jsonb_array_length(p->'stock_counts') > 0 and rsa_has(u, 'stock.count') then
    v_st := rsa_stocktake_insert(u, 'close', p->'stock_counts', 'นับตอนปิดยอด ' || to_char(v_date, 'DD/MM/YYYY'), v_id);
  end if;

  insert into daily_closes(id, biz_date, submitted_by, coworker_ids, summary, starting_cash, cash_sales, cash_refunds, cash_expenses,
    cash_transfers_out, expected_cash, counted_cash, variance, variance_reason, stock_note, note, adjustments, stocktake_id)
  values (v_id, v_date, u.id,
    coalesce((select array_agg(distinct (x)::uuid) from jsonb_array_elements_text(coalesce(p->'coworker_ids', '[]')) x where (x)::uuid <> u.id), '{}'),
    c, v_start, (c->>'cash_in_orders')::numeric, (c->>'cash_out_refunds')::numeric, (c->>'cash_out_expenses')::numeric,
    (c->>'cash_transfers_net_out')::numeric, v_expected, v_counted, v_var, nullif(p->>'variance_reason', ''),
    nullif(p->>'stock_note', ''), nullif(p->>'note', ''), v_adjs, v_st);


  -- The drawer balance follows the counted cash; the difference stays visible as an adjustment entry.
  v_adj := v_counted - (c->>'expected_cash')::numeric;
  if v_adj <> 0 then
    perform rsa_money((c->>'drawer_account')::uuid, case when v_adj > 0 then 'in' else 'out' end, abs(v_adj), 'adjustment', v_id,
      'ผลต่างเงินสดจากการปิดยอด ' || to_char(v_date, 'DD/MM/YYYY'), u.id, now());
    update money_ledger set biz_date = v_date where source_type = 'adjustment' and source_id = v_id;
  end if;
  perform rsa_audit(u, 'close.submit', 'daily_close', v_id::text, null,
    jsonb_build_object('biz_date', v_date, 'expected', v_expected, 'counted', v_counted, 'variance', v_var, 'adjustments', v_adjs));
  return rsa_close_json(v_id);
end $$;

-- Owner correction: keeps the full previous snapshot as a revision
create or replace function rsa__close_revise(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v daily_closes; v_counted numeric; v_var numeric; v_delta numeric;
begin
  perform rsa_need(u, 'closing.edit');
  select * into v from daily_closes where id = rsa_uuid(p, 'close_id') for update;
  if not found then perform rsa_err('ไม่พบรายงานปิดยอด'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการแก้ไข'); end if;
  insert into daily_close_revisions(close_id, revision, snapshot, reason, created_by) values (v.id, v.revision, to_jsonb(v), p->>'reason', u.id);
  v_counted := coalesce(rsa_num(p, 'counted_cash'), v.counted_cash);
  v_var := v_counted - v.expected_cash;
  v_delta := v_counted - v.counted_cash;
  update daily_closes set counted_cash = v_counted, variance = v_var,
    variance_reason = coalesce(nullif(p->>'variance_reason', ''), variance_reason),
    note = coalesce(nullif(p->>'note', ''), note),
    coworker_ids = case when jsonb_typeof(p->'coworker_ids') = 'array'
       then coalesce((select array_agg(distinct (x)::uuid) from jsonb_array_elements_text(p->'coworker_ids') x where (x)::uuid <> v.submitted_by), '{}')
       else coworker_ids end,
    adjustments = adjustments || jsonb_build_array(jsonb_build_object('field', 'counted_cash', 'label', 'เงินสดนับได้ (แก้โดยเจ้าของ)',
       'original', v.counted_cash, 'corrected', v_counted, 'reason', p->>'reason', 'by', u.display_name, 'at', now())),
    revision = revision + 1, reviewed_at = null, reviewed_by = null
   where id = v.id;
  if v_delta <> 0 then
    perform rsa_money((v.summary->>'drawer_account')::uuid, case when v_delta > 0 then 'in' else 'out' end, abs(v_delta), 'adjustment', v.id,
      'แก้ยอดเงินสดนับได้ ' || to_char(v.biz_date, 'DD/MM/YYYY'), u.id, now());
  end if;
  perform rsa_audit(u, 'close.revise', 'daily_close', v.id::text, jsonb_build_object('counted_cash', v.counted_cash, 'variance', v.variance),
                    jsonb_build_object('counted_cash', v_counted, 'variance', v_var), jsonb_build_object('reason', p->>'reason'));
  return rsa_close_json(v.id);
end $$;

create or replace function rsa__close_review(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v daily_closes;
begin
  perform rsa_need(u, 'closing.view_all');
  select * into v from daily_closes where id = rsa_uuid(p, 'close_id') for update;
  if not found then perform rsa_err('ไม่พบรายงานปิดยอด'); end if;
  update daily_closes set reviewed_at = now(), reviewed_by = u.id where id = v.id;
  perform rsa_audit(u, 'close.review', 'daily_close', v.id::text, null, null, jsonb_build_object('note', p->>'note'));
  return rsa_close_json(v.id);
end $$;

create or replace function rsa__close_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_all boolean := rsa_has(u, 'closing.view_all') and not coalesce((p->>'mine')::boolean, false);
begin
  if not (rsa_has(u, 'closing.add') or rsa_has(u, 'closing.view_all')) then perform rsa_need(u, 'closing.add'); end if;
  return (select coalesce(jsonb_agg(rsa_close_json(d.id) order by d.biz_date desc), '[]') from daily_closes d
           where d.biz_date between rsa_date(p, 'from', rsa_today() - 62) and rsa_date(p, 'to')
             and (v_all or d.submitted_by = u.id or u.id = any(d.coworker_ids)));
end $$;

-- Workday rule: each successfully submitted daily close counts one workday for the submitter and
-- for every co-worker named on it. A person is counted at most once per date.
create or replace function rsa__close_workdays(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', date_trunc('month', rsa_today())::date); v_to date := rsa_date(p, 'to');
        v_all boolean := rsa_has(u, 'closing.view_all') and not coalesce((p->>'mine')::boolean, false);
begin
  if not (rsa_has(u, 'closing.add') or rsa_has(u, 'closing.view_all')) then perform rsa_need(u, 'closing.add'); end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('user_id', w.user_id, 'display_name', x.display_name, 'days', w.days, 'dates', w.dates,
                   'submitted', w.submitted) order by x.display_name), '[]')
    from (select user_id, count(distinct biz_date) days, jsonb_agg(distinct biz_date) dates, count(*) filter (where is_submitter) submitted
            from (select d.biz_date, d.submitted_by user_id, true is_submitter from daily_closes d where d.biz_date between v_from and v_to
                  union all
                  select d.biz_date, cw, false from daily_closes d, unnest(d.coworker_ids) cw where d.biz_date between v_from and v_to) s
           group by user_id) w join app_users x on x.id = w.user_id
    where v_all or w.user_id = u.id);
end $$;

-- ---------------------------------------------------------------- cash, bank, delivery, capital
create or replace function rsa__transfer_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_amt numeric := rsa_num(p, 'amount', 0); v_from uuid := rsa_uuid(p, 'from_account'); v_to uuid := rsa_uuid(p, 'to_account');
        v_at timestamptz := rsa_ts(p, 'occurred_at');
begin
  perform rsa_need(u, 'cashflow.manage');
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if v_from is null or v_to is null or v_from = v_to then perform rsa_err('เลือกบัญชีต้นทางและปลายทางที่ต่างกัน'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผล'); end if;
  insert into transfers(id, from_account, to_account, amount, occurred_at, reason, created_by) values (v_id, v_from, v_to, v_amt, v_at, p->>'reason', u.id);
  perform rsa_money(v_from, 'out', v_amt, 'transfer', v_id, p->>'reason', u.id, v_at);
  perform rsa_money(v_to, 'in', v_amt, 'transfer', v_id, p->>'reason', u.id, v_at);
  perform rsa_audit(u, 'transfer.create', 'transfer', v_id::text, null, jsonb_build_object('amount', v_amt, 'from', v_from, 'to', v_to));
  return jsonb_build_object('id', v_id);
end $$;

create or replace function rsa__settlement_preview(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'cashflow.view');
  return (select jsonb_build_object('orders', count(*), 'system_gross', coalesce(sum(total - refunded), 0), 'est_fee', coalesce(sum(est_fee), 0))
            from orders where channel_id = rsa_uuid(p, 'channel_id') and status <> 'cancelled' and settlement_id is null
             and biz_date between rsa_date(p, 'from') and rsa_date(p, 'to'));
end $$;

create or replace function rsa__settlement_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_ch channels; v_from date := rsa_date(p, 'from'); v_to date := rsa_date(p, 'to');
        v_sys numeric; v_gross numeric := rsa_num(p, 'reported_gross'); v_fee numeric := rsa_num(p, 'fee', 0); v_net numeric := rsa_num(p, 'net');
        v_at timestamptz := rsa_ts(p, 'deposited_at');
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v_ch from channels where id = rsa_uuid(p, 'channel_id') and kind = 'delivery';
  if not found then perform rsa_err('กรุณาเลือกช่องทาง Delivery'); end if;
  if rsa_uuid(p, 'account_id') is null then perform rsa_err('กรุณาเลือกบัญชีที่เงินเข้า'); end if;
  select coalesce(sum(total - refunded), 0) into v_sys from orders
   where channel_id = v_ch.id and status <> 'cancelled' and settlement_id is null and biz_date between v_from and v_to;
  v_gross := coalesce(v_gross, v_sys);
  v_net := coalesce(v_net, v_gross - v_fee);
  if v_net <= 0 then perform rsa_err('ยอดเงินเข้าสุทธิต้องมากกว่า 0'); end if;
  if abs(v_gross - v_fee - v_net) > 0.01 then perform rsa_err('ยอดขาย − ค่าธรรมเนียม ไม่เท่ากับยอดสุทธิ กรุณาตรวจตัวเลขจากรายงานแพลตฟอร์ม'); end if;
  insert into delivery_settlements(id, channel_id, channel_name, period_from, period_to, system_gross, reported_gross, fee, net, account_id, deposited_at, ref_no, note, created_by)
  values (v_id, v_ch.id, v_ch.name, v_from, v_to, v_sys, v_gross, v_fee, v_net, rsa_uuid(p, 'account_id'), v_at, nullif(p->>'ref_no', ''), nullif(p->>'note', ''), u.id);
  update orders set settlement_id = v_id where channel_id = v_ch.id and status <> 'cancelled' and settlement_id is null and biz_date between v_from and v_to;
  perform rsa_money(rsa_uuid(p, 'account_id'), 'in', v_net, 'settlement', v_id, v_ch.name || ' ' || to_char(v_from, 'DD/MM') || '-' || to_char(v_to, 'DD/MM'), u.id, v_at);
  perform rsa_link_attachments(p->'attachment_ids', 'settlement', v_id, u);
  perform rsa_audit(u, 'settlement.create', 'settlement', v_id::text, null,
    jsonb_build_object('channel', v_ch.name, 'system_gross', v_sys, 'reported_gross', v_gross, 'fee', v_fee, 'net', v_net));
  return (select to_jsonb(s) from delivery_settlements s where id = v_id);
end $$;

create or replace function rsa__settlement_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v delivery_settlements;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from delivery_settlements where id = rsa_uuid(p, 'settlement_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update delivery_settlements set status = 'cancelled', cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  update orders set settlement_id = null where settlement_id = v.id;
  perform rsa_money(v.account_id, 'out', v.net, 'settlement', v.id, 'กลับรายการรับเงิน ' || v.channel_name, u.id);
  perform rsa_audit(u, 'settlement.cancel', 'settlement', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa__settlement_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'cashflow.view');
  return (select coalesce(jsonb_agg(to_jsonb(s) || jsonb_build_object('account_name', (select name from payment_accounts where id = s.account_id),
            'attachments', rsa_attachment_refs('settlement', s.id)) order by s.deposited_at desc), '[]')
          from (select * from delivery_settlements order by deposited_at desc limit 200) s);
end $$;

create or replace function rsa__capital_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_kind text := p->>'kind'; v_amt numeric := rsa_num(p, 'amount', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
begin
  perform rsa_need(u, 'cashflow.manage');
  if v_kind not in ('capital_in','loan_in','capital_return','loan_repayment') then perform rsa_err('ประเภทรายการไม่ถูกต้อง'); end if;
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if coalesce(trim(p->>'party'), '') = '' then perform rsa_err('กรุณาระบุชื่อผู้ลงทุนหรือเจ้าหนี้'); end if;
  if rsa_uuid(p, 'account_id') is null then perform rsa_err('กรุณาเลือกบัญชี'); end if;
  insert into capital_entries(id, kind, party, amount, occurred_at, account_id, note, created_by)
  values (v_id, v_kind, trim(p->>'party'), v_amt, v_at, rsa_uuid(p, 'account_id'), nullif(p->>'note', ''), u.id);
  perform rsa_money(rsa_uuid(p, 'account_id'), case when v_kind in ('capital_in','loan_in') then 'in' else 'out' end, v_amt, 'capital', v_id,
    trim(p->>'party'), u.id, v_at);
  perform rsa_audit(u, 'capital.create', 'capital', v_id::text, null, jsonb_build_object('kind', v_kind, 'amount', v_amt, 'party', p->>'party'));
  return jsonb_build_object('id', v_id);
end $$;

create or replace function rsa__capital_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v capital_entries;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from capital_entries where id = rsa_uuid(p, 'capital_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if v.profit_declaration_id is not null then perform rsa_err('รายการนี้มาจากการประกาศใช้กำไร ให้ยกเลิกที่การประกาศ'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update capital_entries set status = 'cancelled', cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  perform rsa_money(v.account_id, case when v.kind in ('capital_in','loan_in') then 'out' else 'in' end, v.amount, 'capital', v.id, 'กลับรายการ ' || v.party, u.id);
  perform rsa_audit(u, 'capital.cancel', 'capital', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

-- Estimated profit for a period. Purchases of stock are not expenses here: their cost reaches profit through
-- recipe-based cost of goods sold, waste and stock-count adjustments.
create or replace function rsa_profit(p_from date, p_to date) returns jsonb language sql stable as $$
  with o as (
    select coalesce(sum(total - refunded), 0) revenue, coalesce(sum(cost_total), 0) cogs,
           bool_and(cost_complete) filter (where status <> 'cancelled') cost_complete,
           coalesce(sum(est_fee) filter (where channel_kind = 'delivery' and settlement_id is null), 0) est_fee_unsettled
      from orders where status <> 'cancelled' and biz_date between p_from and p_to),
  s as (select coalesce(sum(fee), 0) fee from delivery_settlements where status = 'done' and period_to between p_from and p_to),
  w as (select coalesce(sum(qty * unit_cost), 0) waste from waste_records where status = 'recorded' and biz_date between p_from and p_to),
  k as (select coalesce(sum(-l.qty * coalesce(l.unit_cost, 0)), 0) shrink from stock_ledger l join stocktakes t on t.id = l.source_id
         where l.kind = 'count_adjust' and t.context <> 'opening' and rsa_bdate(l.occurred_at) between p_from and p_to),
  e as (select coalesce(sum(amount), 0) expenses, count(*) filter (where status = 'รออนุมัติ') pending
          from expenses where status in ('รอทำจ่าย','จ่ายแล้ว','รออนุมัติ') and receipt_id is null
           and rsa_bdate(occurred_at) between p_from and p_to and status <> 'รออนุมัติ'),
  ep as (select coalesce(sum(amount), 0) pending_amount from expenses where status = 'รออนุมัติ' and receipt_id is null
           and rsa_bdate(occurred_at) between p_from and p_to),
  f as (select bool_and(fee_confirmed) fees_confirmed from channels where kind = 'delivery' and active)
  select jsonb_build_object('from', p_from, 'to', p_to,
    'revenue', o.revenue, 'cogs', o.cogs, 'delivery_fees', s.fee + o.est_fee_unsettled, 'waste', round(w.waste, 2), 'shrink', round(k.shrink, 2),
    'gross_profit', o.revenue - o.cogs - s.fee - o.est_fee_unsettled,
    'expenses', e.expenses, 'pending_expenses', ep.pending_amount,
    'net_profit', round(o.revenue - o.cogs - s.fee - o.est_fee_unsettled - w.waste - k.shrink - e.expenses, 2),
    'complete', coalesce(o.cost_complete, true) and coalesce(f.fees_confirmed, true) and not exists (select 1 from stocktakes where status = 'pending'),
    'flags', jsonb_strip_nulls(jsonb_build_object(
       'cost', case when not coalesce(o.cost_complete, true) then 'มีสินค้าที่ยังไม่มีสูตรหรือต้นทุน' end,
       'fee', case when not coalesce(f.fees_confirmed, true) then 'ค่าธรรมเนียม Delivery ยังไม่ยืนยัน' end,
       'fee_est', case when o.est_fee_unsettled > 0 then 'ค่าธรรมเนียมบางส่วนเป็นค่าประมาณ (ยังไม่ได้รับเงินจากแพลตฟอร์ม)' end,
       'count', case when exists (select 1 from stocktakes where status = 'pending') then 'มีการนับสต็อกรออนุมัติ' end,
       'pending', case when ep.pending_amount > 0 then 'มีค่าใช้จ่ายรออนุมัติที่ยังไม่นับรวม' end)))
  from o, s, w, k, e, ep, f
$$;

create or replace function rsa_profit_available() returns jsonb language sql stable as $$
  with pr as (select rsa_profit('2000-01-01', rsa_today()) j),
       d as (select coalesce(sum(amount), 0) declared from profit_declarations where status = 'done')
  -- goods the owner took (at cost) were already taken out of the shop, so they count against the profit still available
  select jsonb_build_object('cumulative_net', (pr.j->>'net_profit')::numeric, 'declared', d.declared,
    'owner_goods', coalesce((pr.j->>'owner_use')::numeric, 0),
    'available', greatest((pr.j->>'net_profit')::numeric - d.declared - coalesce((pr.j->>'owner_use')::numeric, 0), 0), 'complete', pr.j->'complete', 'flags', pr.j->'flags')
  from pr, d
$$;

create or replace function rsa__profit_declare(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_amt numeric := rsa_num(p, 'amount', 0); v_av jsonb := rsa_profit_available();
        v_acc uuid := rsa_uuid(p, 'account_id'); v_purpose text := p->>'purpose'; v_at timestamptz := rsa_ts(p, 'declared_at');
begin
  perform rsa_need(u, 'cashflow.manage');
  if v_purpose not in ('owner_draw','capital_return','loan_repayment') then perform rsa_err('กรุณาเลือกวัตถุประสงค์'); end if;
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if coalesce(trim(p->>'recipient'), '') = '' then perform rsa_err('กรุณาระบุผู้รับเงิน'); end if;
  if v_acc is null then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
  if v_amt > (v_av->>'available')::numeric then
    perform rsa_err('กำไรที่ประกาศได้ตอนนี้ ' || (v_av->>'available') || ' บาท ยอดที่ขอเกินกว่านั้น');
  end if;
  if v_amt > rsa_account_balance(v_acc) then perform rsa_err('ยอดเงินในบัญชีที่เลือกไม่พอ'); end if;
  insert into profit_declarations(id, amount, declared_at, recipient, purpose, account_id, basis_available, note, created_by)
  values (v_id, v_amt, v_at, trim(p->>'recipient'), v_purpose, v_acc, (v_av->>'available')::numeric, nullif(p->>'note', ''), u.id);
  if v_purpose in ('capital_return','loan_repayment') then
    insert into capital_entries(kind, party, amount, occurred_at, account_id, profit_declaration_id, note, created_by)
    values (v_purpose, trim(p->>'recipient'), v_amt, v_at, v_acc, v_id, 'จากการประกาศใช้กำไร', u.id);
  end if;
  perform rsa_money(v_acc, 'out', v_amt, 'profit', v_id, 'ประกาศใช้กำไร: ' || trim(p->>'recipient'), u.id, v_at);
  perform rsa_audit(u, 'profit.declare', 'profit_declaration', v_id::text, null,
    jsonb_build_object('amount', v_amt, 'purpose', v_purpose, 'recipient', p->>'recipient', 'available_before', v_av->'available'));
  return jsonb_build_object('id', v_id);
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
  perform rsa_money(v.account_id, 'in', v.amount, 'profit', v.id, 'กลับรายการประกาศใช้กำไร', u.id);
  perform rsa_audit(u, 'profit.cancel', 'profit_declaration', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa__ledger_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'cashflow.view');
  return (select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('account_name', a.name, 'by', (select display_name from app_users where id = m.created_by))
            order by m.occurred_at desc, m.created_at desc), '[]')
          from (select * from money_ledger m0
                 where (rsa_uuid(p, 'account_id') is null or m0.account_id = rsa_uuid(p, 'account_id'))
                   and m0.biz_date between rsa_date(p, 'from', rsa_today() - 30) and rsa_date(p, 'to')
                   and (not coalesce((p->>'unreconciled')::boolean, false) or m0.reconciled_at is null)
                 order by m0.occurred_at desc limit 500) m
          join payment_accounts a on a.id = m.account_id);
end $$;

create or replace function rsa__ledger_reconcile(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare n int;
begin
  perform rsa_need(u, 'cashflow.manage');
  update money_ledger set reconciled_at = case when coalesce((p->>'undo')::boolean, false) then null else now() end,
         reconciled_by = case when coalesce((p->>'undo')::boolean, false) then null else u.id end,
         bank_ref = coalesce(nullif(p->>'bank_ref', ''), bank_ref)
   where id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'ids', '[]')) x);
  get diagnostics n = row_count;
  perform rsa_audit(u, case when coalesce((p->>'undo')::boolean, false) then 'ledger.unreconcile' else 'ledger.reconcile' end, 'money_ledger', null, null, null,
                    jsonb_build_object('ids', p->'ids', 'bank_ref', p->>'bank_ref', 'count', n));
  return jsonb_build_object('updated', n);
end $$;

create or replace function rsa__cashflow_summary(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_today date := rsa_today();
begin
  perform rsa_need(u, 'cashflow.view');
  perform rsa_fixed_generate(u, date_trunc('month', v_today)::date);
  return jsonb_build_object(
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'is_drawer', a.is_drawer,
                   'opening_balance', a.opening_balance, 'opening_confirmed', a.opening_confirmed, 'balance', rsa_account_balance(a.id),
                   'unreconciled', (select count(*) from money_ledger m where m.account_id = a.id and m.reconciled_at is null and a.kind <> 'cash'))
                   order by a.is_drawer desc, a.name), '[]') from payment_accounts a where a.active),
    'receivables', (select coalesce(jsonb_agg(x), '[]') from (
                   select jsonb_build_object('channel_id', o.channel_id, 'channel_name', o.channel_name, 'orders', count(*),
                     'gross', sum(o.total - o.refunded), 'est_fee', sum(o.est_fee), 'est_net', sum(o.total - o.refunded - o.est_fee),
                     'oldest', min(o.biz_date), 'expected_by', min(o.biz_date) + max(c.settlement_days)) x
                   from orders o join channels c on c.id = o.channel_id
                   where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null
                   group by o.channel_id, o.channel_name) t),
    'payables', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'expense_no', e.expense_no, 'description', e.description, 'payee', e.payee,
                   'amount', e.amount, 'status', e.status, 'due_date', coalesce(e.due_date, rsa_bdate(e.occurred_at)),
                   'employee_name', (select display_name from app_users where id = e.paid_by_employee)) order by coalesce(e.due_date, rsa_bdate(e.occurred_at))), '[]')
                 from expenses e where e.status in ('รออนุมัติ','รอทำจ่าย')),
    'outlook', (select jsonb_agg(jsonb_build_object('days', d,
        'inflow', (select coalesce(sum(o.total - o.refunded - o.est_fee), 0) from orders o join channels c on c.id = o.channel_id
                    where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days <= v_today + d),
        'outflow', (select coalesce(sum(amount), 0) from expenses where status in ('รออนุมัติ','รอทำจ่าย')
                    and coalesce(due_date, rsa_bdate(occurred_at)) <= v_today + d)
                 + (select coalesce(sum(f.amount), 0) from fixed_expenses f
                     cross join lateral generate_series(date_trunc('month', v_today) + interval '1 month', v_today + d, interval '1 month') m
                    where f.active and f.start_month <= m and (f.end_month is null or f.end_month >= m)
                      and least((m::date + (f.due_day - 1)), (m + interval '1 month - 1 day')::date) <= v_today + d))) from unnest(array[7,14,30]) d),
    'capital', (select jsonb_build_object(
        'capital_in', coalesce(sum(amount) filter (where kind = 'capital_in'), 0),
        'loan_in', coalesce(sum(amount) filter (where kind = 'loan_in'), 0),
        'capital_returned', coalesce(sum(amount) filter (where kind = 'capital_return'), 0),
        'loan_repaid', coalesce(sum(amount) filter (where kind = 'loan_repayment'), 0))
        from capital_entries where status = 'done'),
    'capital_rows', (select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('account_name', (select name from payment_accounts where id = c.account_id)) order by c.occurred_at desc), '[]')
                     from capital_entries c),
    'declarations', (select coalesce(jsonb_agg(to_jsonb(d) || jsonb_build_object('account_name', (select name from payment_accounts where id = d.account_id)) order by d.declared_at desc), '[]')
                     from profit_declarations d),
    'transfers', (select coalesce(jsonb_agg(to_jsonb(t) order by t.occurred_at desc), '[]') from (select * from transfers order by occurred_at desc limit 50) t),
    'profit', rsa_profit_available(),
    'month_profit', rsa_profit(date_trunc('month', v_today)::date, v_today)
  );
end $$;
