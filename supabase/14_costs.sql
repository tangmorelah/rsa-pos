-- RSA - POS Assistant : costs in three groups, budgets, cost report on the overview, expense edits with history.
-- A variable cost (moves with sales) · B fixed cost (every month) · C not a cost (debt, capital, investment, drawing).
-- Structure only: shop figures (budgets, recurring amounts, targets, debt) are entered by the owner. Safe to run again.
set check_function_bodies = off;

-- ---------------------------------------------------------------- category tree (codes follow the owner's planning sheet)
-- existing categories join a group (only when not set yet, so the owner's own choices stay)
update expense_categories e set code = coalesce(e.code, v.code), grp = coalesce(e.grp, v.grp), c_kind = coalesce(e.c_kind, v.c_kind),
       ratio_key = coalesce(e.ratio_key, v.ratio_key), budget_method = case when v.method is not null and e.budget_amount is null then v.method else e.budget_method end
  from (values ('วัตถุดิบ / ของเข้าร้าน', 'A00', 'A', null, null, null), ('บรรจุภัณฑ์', 'A04', 'A', null, 'packaging', null),
               ('ค่าขนส่ง', 'A05', 'A', null, null, null), ('ค่าจ้างพนักงาน', 'B01', 'B', null, null, 'fixed'), ('ค่าเช่า', 'B02', 'B', null, null, null),
               ('ค่าน้ำ ค่าไฟ', 'B03', 'B', null, null, null), ('วัสดุสิ้นเปลือง', 'B08', 'B', null, null, null), ('ค่าธรรมเนียม', 'B10', 'B', null, null, null),
               ('ซ่อมแซม / อุปกรณ์', 'B11', 'B', null, null, null), ('อื่น ๆ', 'B99', 'B', null, null, null),
               ('เบิกค่าแรงล่วงหน้า', 'C05', 'C', 'advance', null, null)) v(name, code, grp, c_kind, ratio_key, method)
 where e.name = v.name and not exists (select 1 from expense_categories x where x.code = v.code and x.id <> e.id);

insert into expense_categories(name, tax_category, staff_allowed, code, grp, c_kind, ratio_key, budget_method, sort_order)
select v.name, v.tax, v.staff, v.code, v.grp, v.c_kind, v.ratio_key, v.method, v.sort
  from (values
    ('ผลไม้', 'ต้นทุนสินค้า', true, 'A01', 'A', null, 'fruit', 'pct', 1),
    ('ลูกชิ้น/ไส้กรอก', 'ต้นทุนสินค้า', true, 'A02', 'A', null, 'meatball', 'pct', 2),
    ('น้ำจิ้ม บ๊วย พริกเกลือ', 'ต้นทุนสินค้า', true, 'A03', 'A', null, null, 'pct', 3),
    ('ค่าส่งเบรค', 'ค่าใช้จ่ายในการขาย', true, 'A10', 'A', null, null, 'amount', 10),
    ('ค่าดำเนินการ', null, false, 'B00', 'B', null, null, 'amount', 30),
    ('แก๊ส', 'ค่าใช้จ่ายในการขาย', true, 'B05', 'B', null, null, 'amount', 35),
    ('น้ำมันทอด', 'ค่าใช้จ่ายในการขาย', true, 'B06', 'B', null, null, 'amount', 36),
    ('น้ำแข็ง', 'ค่าใช้จ่ายในการขาย', true, 'B07', 'B', null, null, 'amount', 37),
    ('อินเทอร์เน็ต/โทรศัพท์', 'ค่าสาธารณูปโภค', false, 'B09', 'B', null, null, 'amount', 39),
    ('ผ่อนเงินกู้ลงทุน', null, false, 'C01', 'C', 'loan_repayment', null, 'amount', 91),
    ('เงินเติมจากเจ้าของ', null, false, 'C02', 'C', 'capital_in', null, 'amount', 92),
    ('เงินลงทุน (ค่าเซ้ง/อุปกรณ์)', null, false, 'C03', 'C', 'investment_item', null, 'amount', 93),
    ('ถอนกำไร', null, false, 'C04', 'C', 'owner_draw', null, 'amount', 94)
  ) v(name, tax, staff, code, grp, c_kind, ratio_key, method, sort)
 where not exists (select 1 from expense_categories x where x.code = v.code)
   and not exists (select 1 from expense_categories x where x.name = v.name);

-- running costs: the sub-categories hang under ค่าดำเนินการ (its own budget is used until the subs get theirs)
update expense_categories set parent_id = (select id from expense_categories where code = 'B00')
 where code in ('B03','B04','B05','B06','B07','B08','B09','B10','B11') and parent_id is null;
update expense_categories set grp = 'B' where grp is null;
update expense_categories set sort_order = 30 + coalesce(nullif(regexp_replace(code, '\D', '', 'g'), '')::int, 0)
 where code like 'B%' and code <> 'B00' and sort_order = 100;
update expense_categories set sort_order = coalesce(nullif(regexp_replace(code, '\D', '', 'g'), '')::int, 0)
 where code like 'A%' and sort_order = 100;

-- GP and ads per delivery app: filled automatically from the platform payouts
create or replace function rsa_ensure_delivery_categories() returns void language plpgsql as $$
begin
  insert into expense_categories(name, tax_category, staff_allowed, grp, auto_source, channel_id, budget_method, sort_order)
  select k.prefix || c.name, 'ค่าธรรมเนียม', false, 'A', k.src, c.id, 'pct', k.sort + coalesce(c.sort_order, 0)
    from channels c cross join (values ('GP ', 'delivery_gp', 60), ('ค่าโฆษณา ', 'delivery_ads', 70)) k(prefix, src, sort)
   where c.kind = 'delivery'
     and not exists (select 1 from expense_categories x where x.auto_source = k.src and x.channel_id = c.id);
  update expense_categories x set pct_base = 'channel' where x.auto_source is not null and x.pct_base is null;
end $$;
do $$ begin perform rsa_ensure_delivery_categories(); end $$;

-- ---------------------------------------------------------------- debt: one formula everywhere
create or replace function rsa_debt_left() returns numeric language sql stable as $$
  select greatest(rsa_setting_num('opening_debt', 0)
    + coalesce((select sum(amount) from capital_entries where kind = 'loan_in' and status = 'done'), 0)
    - coalesce((select sum(amount) from capital_entries where kind = 'loan_repayment' and status = 'done'), 0), 0)
$$;

-- installments of the debt schedule still unpaid and due by a date (repayments pay the oldest installment first)
create or replace function rsa_debt_due(p_to date) returns numeric language plpgsql stable as $$
declare v_paid numeric := coalesce((select sum(amount) from capital_entries where kind = 'loan_repayment' and status = 'done'), 0);
        x jsonb; v_cum numeric := 0; v_due numeric := 0; v_amt numeric;
begin
  for x in select * from jsonb_array_elements(coalesce(rsa_setting('debt_schedule', '[]'), '[]')) order by value->>'due' loop
    v_amt := (x->>'amount')::numeric; v_cum := v_cum + v_amt;
    if (x->>'due')::date <= p_to then v_due := v_due + greatest(least(v_amt, v_cum - v_paid), 0); end if;
  end loop;
  return v_due;
end $$;

-- ---------------------------------------------------------------- recurring costs: occurrences between two dates
create or replace function rsa_fixed_dates(f fixed_expenses, p_from date, p_to date) returns setof date language sql stable as $$
  select d::date from generate_series(greatest(p_from, f.start_month), least(p_to, coalesce((date_trunc('month', f.end_month) + interval '1 month - 1 day')::date, p_to)),
                                      interval '1 day') d
   where (f.frequency = 'weekly' and extract(dow from d) = f.weekday)
      or (f.frequency = 'monthly' and d::date = least(date_trunc('month', d)::date + (f.due_day - 1), (date_trunc('month', d) + interval '1 month - 1 day')::date))
$$;

create or replace function rsa_fixed_upcoming(p_from date, p_to date) returns numeric language sql stable as $$
  select coalesce(sum(f.amount), 0) from fixed_expenses f cross join lateral rsa_fixed_dates(f, p_from, p_to) d
   where f.active and f.confirmed and p_from <= p_to
$$;

-- recurring list: this month's bill (weekly: the next one still open, else the latest)
create or replace function rsa__fixed_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'expense.view_all');
  return (select coalesce(jsonb_agg(to_jsonb(f) || jsonb_build_object(
            'category_name', (select name from expense_categories where id = f.category_id),
            'this_month', (select jsonb_build_object('id', e.id, 'status', e.status, 'due_date', e.due_date) from expenses e
                            where e.fixed_expense_id = f.id and left(e.period, 7) = to_char(rsa_today(), 'YYYY-MM')
                            order by (e.status in ('รออนุมัติ','รอทำจ่าย')) desc, case when e.status in ('รออนุมัติ','รอทำจ่าย') then e.due_date end, e.due_date desc limit 1))
          order by f.frequency desc, f.due_day, f.name), '[]')
          from fixed_expenses f);
end $$;

-- ---------------------------------------------------------------- edit an expense, keeping its history
-- not paid yet: changed in place (audit keeps before / after); already paid: the old row is cancelled (money back to its account)
-- and a new row is paid from the same account. Goods received and wages are corrected at their own screens.
create or replace function rsa__expense_update(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v expenses; v_cat expense_categories; v_new uuid; v_amt numeric; v_desc text; v_reason text := trim(coalesce(p->>'reason', ''));
        v_is_mgr boolean := rsa_has(u, 'expense.approve'); v_at timestamptz;
begin
  perform rsa_need(u, 'expense.add');
  select * into v from expenses where id = rsa_uuid(p, 'expense_id') for update;
  if not found or v.status = 'ยกเลิก' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if not (v_is_mgr or (v.created_by = u.id and v.status = 'รออนุมัติ')) then perform rsa_need(u, 'expense.approve'); end if;
  if v_reason = '' then perform rsa_err('กรุณาระบุเหตุผลการแก้ไข'); end if;
  if v.receipt_id is not null then perform rsa_err('รายการนี้มาจากใบรับของ ให้แก้ที่ใบรับของ (ยกเลิกแล้วรับใหม่)'); end if;
  if exists (select 1 from payroll_runs r where r.expense_id = v.id and r.status = 'done') then
    perform rsa_err('รายการนี้เป็นค่าจ้างที่จ่ายแล้ว ให้แก้ที่หน้า พนักงาน › ประวัติจ่ายค่าจ้าง');
  end if;
  if v.advance_user_id is not null then perform rsa_err('เงินเบิกล่วงหน้าแก้ไม่ได้ ให้ยกเลิกแล้วบันทึกใหม่'); end if;
  v_amt := coalesce(rsa_num(p, 'amount'), v.amount);
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  v_desc := coalesce(nullif(trim(p->>'description'), ''), v.description);
  select * into v_cat from expense_categories where id = coalesce(rsa_uuid(p, 'category_id'), v.category_id) and active;
  if not found then perform rsa_err('กรุณาเลือกหมวดค่าใช้จ่าย'); end if;
  if v_cat.grp = 'C' and coalesce(v_cat.c_kind, '') <> 'advance' then perform rsa_err('"' || v_cat.name || '" ไม่ใช่ค่าใช้จ่าย'); end if;
  if not v_is_mgr and not v_cat.staff_allowed then perform rsa_err('หมวด "' || v_cat.name || '" ต้องให้เจ้าของร้านบันทึก'); end if;
  v_at := case when nullif(p->>'occurred_at', '') is not null then rsa_ts(p, 'occurred_at') else v.occurred_at end;

  if v.status in ('รออนุมัติ', 'รอทำจ่าย') then
    update expenses set amount = v_amt, description = v_desc, category_id = v_cat.id, category_name = v_cat.name, tax_category = v_cat.tax_category,
           payee = coalesce(nullif(trim(p->>'payee'), ''), payee), occurred_at = v_at,
           due_date = coalesce(nullif(p->>'due_date', '')::date, due_date), doc_no = coalesce(nullif(p->>'doc_no', ''), doc_no),
           edited_at = now(), edited_by = u.id
     where id = v.id;
    perform rsa_link_attachments(p->'attachment_ids', 'expense', v.id, u);
    perform rsa_audit(u, 'expense.update', 'expense', v.id::text,
      jsonb_build_object('amount', v.amount, 'description', v.description, 'category', v.category_name, 'occurred_at', v.occurred_at),
      jsonb_build_object('amount', v_amt, 'description', v_desc, 'category', v_cat.name, 'occurred_at', v_at), jsonb_build_object('reason', v_reason));
    return rsa_expense_json(v.id);
  end if;

  -- paid: cancel and pay again so every account shows both movements
  v_new := gen_random_uuid();
  update expenses set status = 'ยกเลิก', cancelled_at = now(), cancelled_by = u.id, cancel_reason = 'แก้ไข: ' || v_reason where id = v.id;
  if v.pay_account_id is not null then
    perform rsa_money(v.pay_account_id, 'in', v.amount, 'expense_reversal', v.id, 'แก้ไข ' || v.expense_no, u.id);
  end if;
  insert into expenses(id, expense_no, occurred_at, due_date, category_id, category_name, tax_category, payee, supplier_id, description, amount,
    status, pay_account_id, paid_by_employee, paid_by_owner, reimbursed, fund_source, pay_ref, doc_type, doc_no, ocr_snapshot, fixed_expense_id, period,
    reviewed, created_by, approved_at, approved_by, paid_at, paid_by, replaces_id, edited_at, edited_by)
  values (v_new, rsa_next_no('E'), v_at, coalesce(nullif(p->>'due_date', '')::date, v.due_date), v_cat.id, v_cat.name, v_cat.tax_category,
    coalesce(nullif(trim(p->>'payee'), ''), v.payee), v.supplier_id, v_desc, v_amt, 'จ่ายแล้ว', v.pay_account_id, v.paid_by_employee, v.paid_by_owner,
    v.reimbursed, v.fund_source, v.pay_ref, v.doc_type, coalesce(nullif(p->>'doc_no', ''), v.doc_no), v.ocr_snapshot, null, null,
    v_is_mgr, v.created_by, coalesce(v.approved_at, now()), coalesce(v.approved_by, u.id), coalesce(v.paid_at, now()), coalesce(v.paid_by, u.id), v.id, now(), u.id);
  if v.pay_account_id is not null then
    perform rsa_money(v.pay_account_id, 'out', v_amt, 'expense', v_new, v_desc, u.id);
  end if;
  update expenses set replaced_by = v_new where id = v.id;
  update capital_entries set amount = v_amt, expense_id = v_new where expense_id = v.id and status = 'done';
  perform rsa_link_attachments(p->'attachment_ids', 'expense', v_new, u);
  perform rsa_audit(u, 'expense.update', 'expense', v_new::text,
    jsonb_build_object('expense_no', v.expense_no, 'amount', v.amount, 'description', v.description, 'category', v.category_name),
    jsonb_build_object('amount', v_amt, 'description', v_desc, 'category', v_cat.name), jsonb_build_object('reason', v_reason, 'replaces', v.id));
  return rsa_expense_json(v_new);
end $$;

-- an edited expense still shows the documents of the row it replaced
create or replace function rsa_expense_json(p_id uuid) returns jsonb language sql stable as $$
  with recursive chain(id) as (select p_id union all select x.replaces_id from expenses x join chain c on x.id = c.id where x.replaces_id is not null)
  select to_jsonb(e) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = e.created_by),
    'approved_by_name', (select display_name from app_users where id = e.approved_by),
    'paid_by_name', (select display_name from app_users where id = e.paid_by),
    'edited_by_name', (select display_name from app_users where id = e.edited_by),
    'employee_name', (select display_name from app_users where id = e.paid_by_employee),
    'owed_to', case when e.paid_by_employee is not null then (select display_name from app_users where id = e.paid_by_employee)
                    when e.paid_by_owner then 'เจ้าของ' end,
    'account_name', (select name from payment_accounts where id = e.pay_account_id),
    'grp', (select grp from expense_categories where id = e.category_id),
    'replaces_no', (select expense_no from expenses where id = e.replaces_id),
    'replaced_by_no', (select expense_no from expenses where id = e.replaced_by),
    'wage_bill', e.fixed_expense_id is not null and e.tax_category = 'เงินเดือนและค่าจ้าง',
    'attachments', (select coalesce(jsonb_agg(a), '[]') from chain c cross join lateral jsonb_array_elements(rsa_attachment_refs('expense', c.id)) a)
                   || coalesce(rsa_attachment_refs('receipt', e.receipt_id), '[]'))
  from expenses e where e.id = p_id
$$;

-- ---------------------------------------------------------------- cost report for one month (the overview's "รายละเอียดต้นทุน")
create or replace function rsa_costs_compute(p_month date) returns jsonb language plpgsql as $$
declare
  v_m0 date := date_trunc('month', coalesce(p_month, rsa_today()))::date; v_m1 date; v_t date; v_days int; v_el int;
  v_plan jsonb; v_sales numeric; v_sales_m numeric; v_rows jsonb := '[]'; c expense_categories; v_used numeric; v_bm numeric; v_bt numeric;
  v_base_t numeric; v_base_m numeric; v_est boolean; v_cnt int; v_cnt_t int; v_items int; v_weeks jsonb := '[]'; w date; v_ws int := coalesce(rsa_setting_num('payroll_week_start', 1), 1)::int;
  v_lim jsonb := coalesce(rsa_setting('cost_ratio_limits', '{"fruit":0.65,"meatball":0.5}'), '{}'); v_r jsonb; k text; v_pur numeric; v_bs numeric;
  v_profit jsonb; v_target numeric; v_five boolean := false;
begin
  perform rsa_ensure_delivery_categories();
  v_m1 := (v_m0 + interval '1 month - 1 day')::date;
  v_t := least(rsa_today(), v_m1); v_days := v_m1 - v_m0 + 1; v_el := greatest(v_t - v_m0 + 1, 0);
  v_plan := rsa_setting('monthly_plan', '{}') -> to_char(v_m0, 'YYYY-MM');
  v_sales := coalesce((select sum(total - refunded) from orders where status <> 'cancelled' and biz_date between v_m0 and v_t), 0);
  v_sales_m := coalesce(nullif(v_plan->>'sales_target', '')::numeric, case when v_el > 0 then round(v_sales * v_days / v_el, 2) else 0 end);

  for c in select * from expense_categories where active order by coalesce(grp, 'B'), sort_order, code nulls last, name loop
    -- used to date: expenses of the category (group C: what moved through the money screens)
    if coalesce(c.grp, 'B') = 'C' then
      v_used := case c.c_kind
        when 'loan_repayment' then (select coalesce(sum(amount), 0) from capital_entries where kind = 'loan_repayment' and status = 'done' and rsa_bdate(occurred_at) between v_m0 and v_t)
        when 'capital_in' then (select coalesce(sum(amount), 0) from capital_entries where kind in ('capital_in','owner_paid') and status = 'done' and rsa_bdate(occurred_at) between v_m0 and v_t)
        when 'investment_item' then (select coalesce(sum(amount), 0) from capital_entries where kind = 'investment_item' and status = 'done' and rsa_bdate(occurred_at) between v_m0 and v_t)
        when 'owner_draw' then (select coalesce(sum(amount), 0) from profit_declarations where status = 'done' and purpose = 'owner_draw' and rsa_bdate(declared_at) between v_m0 and v_t)
        else (select coalesce(sum(amount), 0) from expenses where category_id = c.id and status in ('รอทำจ่าย','จ่ายแล้ว') and rsa_bdate(occurred_at) between v_m0 and v_t) end;
    elsif c.auto_source = 'delivery_gp' then
      v_used := (select coalesce(sum(s.fee - coalesce((s.fee_breakdown->>'marketing')::numeric, 0)), 0) from delivery_settlements s
                  where s.channel_id = c.channel_id and s.status = 'done' and s.period_to between v_m0 and v_t)
              + (select coalesce(sum(coalesce((select po.commission + po.vat + po.other_fee from platform_orders po where po.matched_order_id = o.id and po.status = 'done' limit 1), o.est_fee)), 0)
                   from orders o where o.channel_id = c.channel_id and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date between v_m0 and v_t)
              + (select coalesce(sum(amount), 0) from expenses where category_id = c.id and status in ('รอทำจ่าย','จ่ายแล้ว') and rsa_bdate(occurred_at) between v_m0 and v_t);
    elsif c.auto_source = 'delivery_ads' then
      v_used := (select coalesce(sum(coalesce((s.fee_breakdown->>'marketing')::numeric, 0)), 0) from delivery_settlements s
                  where s.channel_id = c.channel_id and s.status = 'done' and s.period_to between v_m0 and v_t)
              + (select coalesce(sum(amount), 0) from expenses where category_id = c.id and status in ('รอทำจ่าย','จ่ายแล้ว') and rsa_bdate(occurred_at) between v_m0 and v_t);
    else
      v_used := (select coalesce(sum(amount), 0) from expenses where category_id = c.id and status in ('รอทำจ่าย','จ่ายแล้ว') and advance_user_id is null
                   and rsa_bdate(occurred_at) between v_m0 and v_t);
    end if;
    -- sales the % budget is based on
    v_base_t := case
      when c.pct_base = 'channel' then (select coalesce(sum(total - refunded), 0) from orders where channel_id = c.channel_id and status <> 'cancelled' and biz_date between v_m0 and v_t)
      when c.pct_base like 'pcat:%' then (select coalesce(sum(i.line_total), 0) from order_items i join orders o on o.id = i.order_id join products pr on pr.id = i.product_id
                                           where o.status <> 'cancelled' and o.biz_date between v_m0 and v_t and pr.category = substr(c.pct_base, 6))
      else v_sales end;
    v_base_m := case when c.pct_base is null or c.pct_base = 'sales' then v_sales_m when v_el > 0 then round(v_base_t * v_days / v_el, 2) else 0 end;
    v_cnt := null; v_cnt_t := null;
    if c.budget_method = 'fixed' then
      -- from the recurring list: amount per round × rounds in the month (4 or 5 weekly paydays)
      select coalesce(sum(f.amount), 0), count(*) into v_bm, v_cnt from fixed_expenses f cross join lateral rsa_fixed_dates(f, v_m0, v_m1) d
       where f.active and f.category_id = c.id;
      select coalesce(sum(f.amount), 0), count(*) into v_bt, v_cnt_t from fixed_expenses f cross join lateral rsa_fixed_dates(f, v_m0, v_t) d
       where f.active and f.category_id = c.id;
      if exists (select 1 from fixed_expenses f where f.active and f.category_id = c.id and f.frequency = 'weekly'
                  and (select count(*) from rsa_fixed_dates(f, v_m0, v_m1)) >= 5) then v_five := true; end if;
    elsif c.budget_method = 'pct' then
      v_bm := case when c.budget_pct is not null then round(c.budget_pct * v_base_m, 2) end;
      v_bt := case when c.budget_pct is not null then round(c.budget_pct * v_base_t, 2) end;
    else
      v_bm := c.budget_amount;
      v_bt := case when c.budget_amount is not null then round(c.budget_amount * v_el / v_days, 2) end;
    end if;
    v_est := (v_bm is not null and not c.budget_confirmed)
             or (c.auto_source = 'delivery_gp' and exists (select 1 from orders o where o.channel_id = c.channel_id and o.status <> 'cancelled' and o.settlement_id is null
                     and o.biz_date between v_m0 and v_t and not exists (select 1 from platform_orders po where po.matched_order_id = o.id and po.status = 'done')))
             or exists (select 1 from expenses x where x.category_id = c.id and x.fixed_expense_id is not null and x.status = 'รอทำจ่าย' and rsa_bdate(x.occurred_at) between v_m0 and v_t);
    select count(*) into v_items from expenses where category_id = c.id and status <> 'ยกเลิก' and rsa_bdate(occurred_at) between v_m0 and v_m1;
    v_rows := v_rows || jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name, 'grp', coalesce(c.grp, 'B'), 'parent_id', c.parent_id,
      'auto_source', c.auto_source, 'c_kind', c.c_kind, 'budget_method', c.budget_method, 'budget_pct', c.budget_pct, 'pct_base', c.pct_base,
      'budget_month', v_bm, 'budget_to_date', v_bt, 'used', v_used, 'rounds', v_cnt, 'rounds_to_date', v_cnt_t,
      'estimate', v_est, 'items', v_items);
  end loop;

  -- a parent shows its subs added in; its budget is the subs' budgets once any sub has one
  v_rows := (select jsonb_agg(case when exists (select 1 from jsonb_array_elements(v_rows) ch where ch->>'parent_id' = r->>'id') then
      r || jsonb_build_object(
        'used', (r->>'used')::numeric + (select coalesce(sum((ch->>'used')::numeric), 0) from jsonb_array_elements(v_rows) ch where ch->>'parent_id' = r->>'id'),
        'budget_month', case when exists (select 1 from jsonb_array_elements(v_rows) ch where ch->>'parent_id' = r->>'id' and ch->>'budget_month' is not null)
                             then (select sum((ch->>'budget_month')::numeric) from jsonb_array_elements(v_rows) ch where ch->>'parent_id' = r->>'id') else (r->>'budget_month')::numeric end,
        'budget_to_date', case when exists (select 1 from jsonb_array_elements(v_rows) ch where ch->>'parent_id' = r->>'id' and ch->>'budget_to_date' is not null)
                             then (select sum((ch->>'budget_to_date')::numeric) from jsonb_array_elements(v_rows) ch where ch->>'parent_id' = r->>'id') else (r->>'budget_to_date')::numeric end,
        'estimate', (r->>'estimate')::boolean or exists (select 1 from jsonb_array_elements(v_rows) ch where ch->>'parent_id' = r->>'id' and (ch->>'estimate')::boolean),
        'has_children', true)
      else r end) from jsonb_array_elements(v_rows) r);
  v_rows := (select jsonb_agg(r || jsonb_build_object(
      'diff', case when r->>'budget_to_date' is not null then (r->>'used')::numeric - (r->>'budget_to_date')::numeric end,
      'pct_of_sales', case when v_sales > 0 then round((r->>'used')::numeric * 100 / v_sales, 1) end)) from jsonb_array_elements(v_rows) r);

  -- weekly cost ratios (last 8 weeks): purchases of the category ÷ sales of what it is used for
  for w in select generate_series(rsa_week_start(rsa_today()) - 49, rsa_week_start(rsa_today()), interval '7 day')::date loop
    v_r := '{}';
    for k in select distinct ratio_key from expense_categories where ratio_key is not null and active loop
      select coalesce(sum(x.amount), 0) into v_pur from expenses x join expense_categories ec on ec.id = x.category_id
       where ec.ratio_key = k and x.status in ('รอทำจ่าย','จ่ายแล้ว') and rsa_bdate(x.occurred_at) between w and w + 6;
      select case when min(ec.pct_base) like 'pcat:%' then
               (select coalesce(sum(i.line_total), 0) from order_items i join orders o on o.id = i.order_id join products pr on pr.id = i.product_id
                 where o.status <> 'cancelled' and o.biz_date between w and w + 6 and pr.category = substr(min(ec.pct_base), 6))
             else (select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and biz_date between w and w + 6) end
        into v_bs from expense_categories ec where ec.ratio_key = k and ec.active;
      v_r := v_r || jsonb_build_object(k, jsonb_build_object('purchase', v_pur, 'sales', v_bs,
               'ratio', case when v_bs > 0 then round(v_pur / v_bs, 4) end, 'limit', v_lim->k));
    end loop;
    v_weeks := v_weeks || jsonb_build_object('from', w, 'to', w + 6, 'complete', w + 6 < rsa_today(), 'ratios', v_r);
  end loop;

  v_profit := rsa_profit(v_m0, v_t);
  v_target := coalesce(nullif(v_plan->>'net_profit_target', '')::numeric, rsa_setting_num('profit_target', 0));
  return jsonb_build_object('month', to_char(v_m0, 'YYYY-MM'), 'from', v_m0, 'to', v_t, 'days', v_days, 'elapsed', v_el,
    'sales', v_sales, 'sales_target', nullif(v_plan->>'sales_target', '')::numeric,
    'rows', coalesce(v_rows, '[]'),
    'summary', jsonb_build_object('sales', v_profit->'revenue', 'var_costs', v_profit->'var_costs', 'gross_profit', v_profit->'gross_profit',
       'fixed_costs', v_profit->'fixed_costs', 'net_profit', v_profit->'net_profit',
       'net_target', v_target, 'net_target_to_date', case when v_target > 0 then round(v_target * v_el / v_days, 2) end,
       'complete', v_profit->'complete', 'flags', v_profit->'flags'),
    'weeks', v_weeks, 'limits', v_lim, 'five_paydays', v_five,
    'over_alert_pct', rsa_setting_num('budget_over_alert_pct', 0.1),
    'missing_docs', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'expense_no', e.expense_no, 'description', e.description, 'amount', e.amount,
                       'category_name', e.category_name, 'date', rsa_bdate(e.occurred_at), 'created_by_name', (select display_name from app_users where id = e.created_by))
                       order by e.occurred_at desc), '[]')
                     from expenses e where e.status = 'จ่ายแล้ว' and coalesce(e.fund_source, '') <> 'payroll' and e.occurred_at > now() - interval '60 days'
                       and not exists (select 1 from attachments a where a.linked_type = 'expense' and a.linked_id = e.id)
                       and not (e.receipt_id is not null and exists (select 1 from attachments a where a.linked_type = 'receipt' and a.linked_id = e.receipt_id))
                       and not (e.replaces_id is not null and exists (select 1 from attachments a where a.linked_type = 'expense' and a.linked_id = e.replaces_id))));
end $$;

create or replace function rsa__report_costs(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'report.view');
  if rsa_has(u, 'expense.approve') then perform rsa_fixed_generate(u, date_trunc('month', coalesce(rsa_date(p, 'month'), rsa_today()))::date); end if;
  return rsa_costs_compute(rsa_date(p, 'month'));
end $$;

-- expense categories with their place in the tree (master data screen)
create or replace function rsa__cost_categories(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'report.view');
  perform rsa_ensure_delivery_categories();
  return (select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('parent_name', (select name from expense_categories x where x.id = c.parent_id),
            'channel_name', (select name from channels where id = c.channel_id)) order by coalesce(c.grp, 'B'), c.sort_order, c.code nulls last, c.name), '[]')
    from expense_categories c);
end $$;

-- ---------------------------------------------------------------- cost alerts for the overview's "ต้องทำ"
create or replace function rsa_cost_alerts(p_today date) returns jsonb language plpgsql as $$
declare v jsonb := rsa_costs_compute(p_today); v_ex jsonb := '[]'; r jsonb; v_pct numeric := coalesce((v->>'over_alert_pct')::numeric, 0.1);
        k text; v_w jsonb; v_names text; n int;
begin
  -- a category spending more than its budget so far (+10 %)
  for r in select * from jsonb_array_elements(v->'rows') loop
    if r->>'grp' in ('A','B') and r->>'parent_id' is null and r->>'budget_to_date' is not null and (r->>'budget_to_date')::numeric > 0
       and (r->>'used')::numeric > (r->>'budget_to_date')::numeric * (1 + v_pct) then
      v_ex := v_ex || jsonb_build_object('kind', 'budget_over', 'level', 'warn', 'ref', r->>'id',
        'text', 'หมวด ' || (r->>'name') || ' ใช้เกินงบถึงวันนี้ ' || to_char((r->>'used')::numeric - (r->>'budget_to_date')::numeric, 'FM999,999,990') || ' บาท'
                || case when (r->>'estimate')::boolean then ' (งบประมาณการ)' else '' end);
    end if;
  end loop;
  -- fruit / meatball cost above the limit two complete weeks in a row
  for k in select * from jsonb_object_keys(coalesce(v->'limits', '{}')) loop
    continue when k = 'packaging';
    select count(*) into n from (select x from jsonb_array_elements(v->'weeks') x where (x->>'complete')::boolean order by x->>'from' desc limit 2) last2
     where (x->'ratios'->k->>'ratio')::numeric > (v->'limits'->>k)::numeric;
    if n = 2 then
      v_ex := v_ex || jsonb_build_object('kind', 'cost_ratio_high', 'level', 'warn',
        'text', 'ต้นทุน' || case k when 'fruit' then 'ผลไม้' when 'meatball' then 'ลูกชิ้น' else k end || 'เกินเกณฑ์ '
                || round((v->'limits'->>k)::numeric * 100) || '% 2 สัปดาห์ติด · เช็กราคาซื้อ yield ของเสีย และขนาดกล่อง');
    end if;
  end loop;
  -- recurring bills past their due date and not paid (approved ones are in expense_due already)
  select count(*) into n from expenses where fixed_expense_id is not null and status = 'รออนุมัติ' and coalesce(due_date, rsa_bdate(occurred_at)) < p_today;
  if n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'fixed_overdue', 'level', 'warn', 'text', 'ค่าใช้จ่ายประจำเลยกำหนดยังไม่จ่าย ' || n || ' รายการ'); end if;
  n := jsonb_array_length(v->'missing_docs');
  if n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'missing_docs', 'level', 'info', 'text', 'ค่าใช้จ่ายรอเอกสาร (ยังไม่แนบใบเสร็จ / สลิป) ' || n || ' รายการ'); end if;
  if (v->>'five_paydays')::boolean then
    v_ex := v_ex || jsonb_build_object('kind', 'five_paydays', 'level', 'info', 'text', 'เดือนนี้มีรอบจ่ายค่าจ้าง 5 รอบ ค่าจ้างจะสูงกว่างบรายเดือนปกติ');
  end if;
  return v_ex;
end $$;
