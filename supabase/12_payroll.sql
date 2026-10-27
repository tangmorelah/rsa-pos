-- RSA - POS Assistant : weekly wages from workdays (daily wage x days + extras − advances), product categories
set check_function_bodies = off;

-- days a person worked = days with a submitted daily close where they submitted it or were named on the shift
create or replace function rsa_workdays_of(p_user uuid, p_from date, p_to date)
returns table(biz_date date, submitted boolean, on_time boolean) language sql stable as $$
  select d.biz_date, d.submitted_by = p_user, d.on_time from daily_closes d
   where d.biz_date between p_from and p_to and (d.submitted_by = p_user or p_user = any(d.coworker_ids))
$$;

create or replace function rsa_paid_dates(p_user uuid) returns setof date language sql stable as $$
  select (x)::date from payroll_runs r, jsonb_array_elements_text(r.day_dates) x where r.user_id = p_user and r.status = 'done'
$$;

create or replace function rsa_week_start(p_date date) returns date language sql stable as $$
  select p_date - ((extract(dow from p_date)::int - coalesce((select (value #>> '{}')::int from settings where key = 'payroll_week_start'), 1) + 7) % 7)
$$;

create or replace function rsa_open_advances(p_user uuid) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'expense_no', e.expense_no, 'amount', e.amount, 'occurred_at', e.occurred_at, 'description', e.description)
           order by e.occurred_at), '[]')
    from expenses e where e.advance_user_id = p_user and e.status = 'จ่ายแล้ว' and e.advance_run_id is null
$$;

create or replace function rsa__payroll_preview(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v app_users; v_from date; v_to date; v_first date; v_dates jsonb; v_unpaid int; v_adv jsonb; v_advt numeric;
begin
  perform rsa_need(u, 'expense.pay');
  select * into v from app_users where id = rsa_uuid(p, 'user_id');
  if not found then perform rsa_err('ไม่พบพนักงาน'); end if;
  -- default period: the week of the oldest workday not paid yet (looking back 62 days)
  select min(w.biz_date) into v_first from rsa_workdays_of(v.id, rsa_today() - 62, rsa_today()) w
   where w.biz_date not in (select rsa_paid_dates(v.id));
  v_from := coalesce(nullif(p->>'from', '')::date, rsa_week_start(coalesce(v_first, rsa_today())));
  v_to := coalesce(nullif(p->>'to', '')::date, least(v_from + 6, rsa_today()));
  if v_to < v_from then perform rsa_err('ช่วงวันที่ไม่ถูกต้อง'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('date', w.biz_date, 'submitted', w.submitted, 'on_time', w.on_time,
           'paid', w.biz_date in (select rsa_paid_dates(v.id))) order by w.biz_date), '[]'),
         count(*) filter (where w.biz_date not in (select rsa_paid_dates(v.id)))
    into v_dates, v_unpaid from rsa_workdays_of(v.id, v_from, v_to) w;
  v_adv := rsa_open_advances(v.id);
  select coalesce(sum((x->>'amount')::numeric), 0) into v_advt from jsonb_array_elements(v_adv) x;
  return jsonb_build_object('user_id', v.id, 'display_name', v.display_name, 'daily_wage', v.daily_wage, 'from', v_from, 'to', v_to,
    'dates', v_dates, 'unpaid_days', v_unpaid, 'advances', v_adv, 'advance_total', v_advt,
    'base', round(v_unpaid * coalesce(v.daily_wage, 0), 2), 'suggested_net', round(v_unpaid * coalesce(v.daily_wage, 0), 2) - v_advt,
    'runs', (select coalesce(jsonb_agg(to_jsonb(r) order by r.period_from desc), '[]') from (select * from payroll_runs where user_id = v.id order by period_from desc limit 12) r));
end $$;

create or replace function rsa__payroll_pay(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v app_users; v_from date := nullif(p->>'from', '')::date; v_to date := nullif(p->>'to', '')::date; v_dates jsonb; v_sys int;
        v_days numeric; v_ex jsonb := '[]'; x jsonb; v_ext numeric := 0; v_base numeric; v_gross numeric; v_advt numeric; v_net numeric;
        v_acc payment_accounts; v_cat expense_categories; v_run uuid := gen_random_uuid(); v_exp uuid := gen_random_uuid(); v_ref text := nullif(trim(coalesce(p->>'pay_ref', '')), '');
        v_at timestamptz := rsa_ts(p, 'paid_at');
begin
  perform rsa_need(u, 'expense.pay');
  select * into v from app_users where id = rsa_uuid(p, 'user_id') for update;
  if not found then perform rsa_err('ไม่พบพนักงาน'); end if;
  if coalesce(v.daily_wage, 0) <= 0 then perform rsa_err('ยังไม่ได้ตั้งค่าแรงต่อวันของ ' || v.display_name); end if;
  if v_from is null or v_to is null or v_to < v_from then perform rsa_err('กรุณาเลือกช่วงวันที่จ่าย'); end if;
  if exists (select 1 from payroll_runs where user_id = v.id and status = 'done' and period_from <= v_to and period_to >= v_from) then
    perform rsa_err('ช่วงนี้มีการจ่ายค่าจ้างให้ ' || v.display_name || ' แล้ว');
  end if;
  select coalesce(jsonb_agg(w.biz_date order by w.biz_date), '[]'), count(*) into v_dates, v_sys
    from rsa_workdays_of(v.id, v_from, v_to) w where w.biz_date not in (select rsa_paid_dates(v.id));
  v_days := coalesce(rsa_num(p, 'days'), v_sys);
  if v_days < 0 then perform rsa_err('จำนวนวันติดลบไม่ได้'); end if;
  if v_days <> v_sys and coalesce(trim(p->>'days_reason'), '') = '' then
    perform rsa_err('ระบบนับได้ ' || v_sys || ' วัน ถ้าจ่าย ' || v_days || ' วัน กรุณาใส่เหตุผล');
  end if;
  for x in select * from jsonb_array_elements(coalesce(p->'extras', '[]')) loop
    if coalesce(rsa_num(x, 'amount'), 0) = 0 then continue; end if;
    if coalesce(trim(x->>'label'), '') = '' then perform rsa_err('ค่าพิเศษแต่ละรายการต้องมีชื่อ เช่น โบนัส ค่าล่วงเวลา'); end if;
    v_ex := v_ex || jsonb_build_array(jsonb_build_object('label', trim(x->>'label'), 'amount', round(rsa_num(x, 'amount'), 2)));
    v_ext := v_ext + round(rsa_num(x, 'amount'), 2);
  end loop;
  v_base := round(v_days * v.daily_wage, 2);
  v_gross := v_base + v_ext;
  if v_gross <= 0 then perform rsa_err('ยอดค่าจ้างต้องมากกว่า 0'); end if;
  select coalesce(sum(amount), 0) into v_advt from expenses where advance_user_id = v.id and status = 'จ่ายแล้ว' and advance_run_id is null;
  if v_advt > v_gross then perform rsa_err('เงินเบิกล่วงหน้า ' || v_advt || ' บาท มากกว่าค่าจ้างรอบนี้ ' || v_gross || ' บาท'); end if;
  v_net := v_gross - v_advt;
  if v_net > 0 then
    select * into v_acc from payment_accounts where id = rsa_uuid(p, 'account_id') and active;
    if not found then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
    if v_acc.kind <> 'cash' and v_ref is null then perform rsa_err('จ่ายผ่านบัญชีต้องใส่เลขอ้างอิง / เลขที่สลิป'); end if;
  end if;
  select * into v_cat from expense_categories where code = 'B01' or name = 'ค่าจ้างพนักงาน' order by (code = 'B01') desc nulls last limit 1;
  if not found then select * into v_cat from expense_categories where tax_category = 'เงินเดือนและค่าจ้าง' order by name limit 1; end if;
  -- the cost is the whole wage; only the part not already advanced leaves the account now
  insert into expenses(id, expense_no, occurred_at, category_id, category_name, tax_category, payee, description, amount, status, pay_account_id,
    fund_source, pay_ref, reviewed, created_by, approved_at, approved_by, paid_at, paid_by)
  values (v_exp, rsa_next_no('E'), v_at, v_cat.id, v_cat.name, v_cat.tax_category, v.display_name,
    'ค่าจ้าง ' || v.display_name || ' ' || to_char(v_from, 'DD/MM') || '–' || to_char(v_to, 'DD/MM') || ' (' || v_days || ' วัน)', v_gross, 'จ่ายแล้ว', v_acc.id,
    'payroll', v_ref, true, u.id, now(), u.id, v_at, u.id);
  if v_net > 0 then perform rsa_money(v_acc.id, 'out', v_net, 'expense', v_exp, 'ค่าจ้าง ' || v.display_name, u.id, v_at); end if;
  insert into payroll_runs(id, user_id, period_from, period_to, system_days, days, days_reason, day_dates, daily_wage, base_amount, extras, extras_total,
    gross, advance_deducted, net_paid, expense_id, account_id, pay_ref, note, created_by)
  values (v_run, v.id, v_from, v_to, v_sys, v_days, nullif(trim(p->>'days_reason'), ''), v_dates, v.daily_wage, v_base, v_ex, v_ext,
    v_gross, v_advt, v_net, v_exp, v_acc.id, v_ref, nullif(trim(p->>'note'), ''), u.id);
  update expenses set advance_run_id = v_run where advance_user_id = v.id and status = 'จ่ายแล้ว' and advance_run_id is null;
  -- the estimated weekly wage bill of this period is replaced by the real wage (cancelled with a reason, never deleted)
  update expenses x set status = 'ยกเลิก', cancelled_at = now(), cancelled_by = u.id, replaced_by = v_exp,
         cancel_reason = 'แทนด้วยค่าจ้างจริง ' || to_char(v_from, 'DD/MM') || '–' || to_char(v_to, 'DD/MM')
   where x.status in ('รออนุมัติ','รอทำจ่าย') and x.fixed_expense_id is not null and x.tax_category = 'เงินเดือนและค่าจ้าง'
     and coalesce(x.due_date, rsa_bdate(x.occurred_at)) between v_from and v_to + 6;
  perform rsa_link_attachments(p->'attachment_ids', 'expense', v_exp, u);
  perform rsa_audit(u, 'payroll.pay', 'payroll', v_run::text, null, jsonb_build_object('user', v.display_name, 'from', v_from, 'to', v_to,
    'system_days', v_sys, 'days', v_days, 'daily_wage', v.daily_wage, 'extras', v_ex, 'gross', v_gross, 'advance', v_advt, 'net', v_net));
  return (select to_jsonb(r) from payroll_runs r where id = v_run);
end $$;

create or replace function rsa__payroll_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare r payroll_runs;
begin
  perform rsa_need(u, 'expense.pay');
  select * into r from payroll_runs where id = rsa_uuid(p, 'run_id') for update;
  if not found or r.status <> 'done' then perform rsa_err('ไม่พบรอบจ่าย หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update payroll_runs set status = 'cancelled', cancelled_by = u.id, cancel_reason = trim(p->>'reason') where id = r.id;
  update expenses set status = 'ยกเลิก', cancelled_at = now(), cancelled_by = u.id, cancel_reason = 'ยกเลิกรอบจ่ายค่าจ้าง: ' || trim(p->>'reason') where id = r.expense_id;
  if r.net_paid > 0 then perform rsa_money(r.account_id, 'in', r.net_paid, 'expense_reversal', r.expense_id, 'กลับรายการค่าจ้าง', u.id); end if;
  update expenses set advance_run_id = null where advance_run_id = r.id;
  perform rsa_audit(u, 'payroll.cancel', 'payroll', r.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

-- a person's wage summary: staff see only their own
create or replace function rsa__payroll_summary(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_uid uuid := coalesce(rsa_uuid(p, 'user_id'), u.id); v_from date := rsa_date(p, 'from', date_trunc('month', rsa_today())::date); v_to date := rsa_date(p, 'to');
begin
  if v_uid <> u.id then perform rsa_need(u, 'expense.pay'); end if;
  return jsonb_build_object('user_id', v_uid, 'from', v_from, 'to', v_to,
    'daily_wage', (select daily_wage from app_users where id = v_uid),
    'runs', (select coalesce(jsonb_agg(to_jsonb(r) order by r.period_from desc), '[]') from payroll_runs r where r.user_id = v_uid and r.period_to >= v_from - 31 and r.period_from <= v_to),
    'paid_gross', (select coalesce(sum(gross), 0) from payroll_runs where user_id = v_uid and status = 'done' and period_to between v_from and v_to),
    'paid_net', (select coalesce(sum(net_paid + advance_deducted), 0) from payroll_runs where user_id = v_uid and status = 'done' and period_to between v_from and v_to),
    'unpaid_dates', (select coalesce(jsonb_agg(w.biz_date order by w.biz_date), '[]') from rsa_workdays_of(v_uid, rsa_today() - 62, rsa_today()) w
                      where w.biz_date not in (select rsa_paid_dates(v_uid))),
    'advances', rsa_open_advances(v_uid));
end $$;

create or replace function rsa__payroll_set_wage(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v app_users; w numeric := rsa_num(p, 'daily_wage');
begin
  perform rsa_need(u, 'expense.pay');
  select * into v from app_users where id = rsa_uuid(p, 'user_id') for update;
  if not found then perform rsa_err('ไม่พบพนักงาน'); end if;
  if w is not null and w < 0 then perform rsa_err('ค่าแรงติดลบไม่ได้'); end if;
  update app_users set daily_wage = w, updated_at = now() where id = v.id;
  perform rsa_audit(u, 'payroll.set_wage', 'user', v.id::text, jsonb_build_object('daily_wage', v.daily_wage), jsonb_build_object('daily_wage', w));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa__report_staff(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', date_trunc('month', rsa_today())::date); v_to date := rsa_date(p, 'to'); v_pay boolean := rsa_has(u, 'expense.pay');
begin
  perform rsa_need(u, 'report.view');
  return jsonb_build_object('from', v_from, 'to', v_to,
    'workdays', rsa__close_workdays(u, jsonb_build_object('from', v_from, 'to', v_to)),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('user_id', x.id, 'display_name', x.display_name, 'role', x.role, 'active', x.active,
        'daily_wage', case when v_pay then x.daily_wage end,
        'orders', (select count(*) from orders o where o.created_by = x.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
        'sales', (select coalesce(sum(total - refunded), 0) from orders o where o.created_by = x.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
        'cancels', (select count(*) from orders o where o.cancelled_by = x.id and o.replaced_by is null and rsa_bdate(o.cancelled_at) between v_from and v_to),
        'edits', (select count(*) from orders o where o.cancelled_by = x.id and o.replaced_by is not null and rsa_bdate(o.cancelled_at) between v_from and v_to),
        'waste', (select coalesce(round(sum(qty * unit_cost), 2), 0) from waste_records w where w.created_by = x.id and w.kind = 'waste' and w.status = 'recorded' and w.biz_date between v_from and v_to),
        'meals', (select coalesce(round(sum(qty * unit_cost), 2), 0) from waste_records w where w.for_user_id = x.id and w.kind = 'staff_meal' and w.status = 'recorded' and w.biz_date between v_from and v_to),
        'expenses', (select coalesce(sum(amount), 0) from expenses e where e.created_by = x.id and e.status <> 'ยกเลิก' and rsa_bdate(e.occurred_at) between v_from and v_to),
        'owed', (select coalesce(sum(amount), 0) from expenses e where e.paid_by_employee = x.id and e.status in ('รออนุมัติ','รอทำจ่าย')),
        'paid_gross', case when v_pay then (select coalesce(sum(gross), 0) from payroll_runs r where r.user_id = x.id and r.status = 'done' and r.period_to between v_from and v_to) end,
        'paid_days', (select coalesce(sum(days), 0) from payroll_runs r where r.user_id = x.id and r.status = 'done' and r.period_to between v_from and v_to),
        'last_paid_to', (select max(period_to) from payroll_runs r where r.user_id = x.id and r.status = 'done'),
        'unpaid_days', (select count(*) from rsa_workdays_of(x.id, rsa_today() - 62, rsa_today()) w where w.biz_date not in (select rsa_paid_dates(x.id))),
        'advance_open', case when v_pay then (select coalesce(sum(amount), 0) from expenses e where e.advance_user_id = x.id and e.status = 'จ่ายแล้ว' and e.advance_run_id is null) end)
        order by x.active desc, x.display_name), '[]') from app_users x where x.role <> 'admin'));
end $$;

-- ---------------------------------------------------------------- product categories (pick from the list or type a new one)
create or replace function rsa__category_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('name', c, 'products', (select count(*) from products where category = c and active)) order by ord, c), '[]') from (
    select c, coalesce((select o from jsonb_array_elements_text(coalesce(rsa_setting('product_categories'), '[]')) with ordinality t(v, o) where v = c), 999) ord
      from (select distinct category c from products where coalesce(category, '') <> ''
            union select v from jsonb_array_elements_text(coalesce(rsa_setting('product_categories'), '[]')) v) z) y);
end $$;

create or replace function rsa__category_rename(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_old text := trim(coalesce(p->>'old', '')); v_new text := trim(coalesce(p->>'new', '')); n int; v_list jsonb;
begin
  perform rsa_need(u, 'master.manage');
  if v_new = '' then perform rsa_err('กรุณาใส่ชื่อหมวดใหม่'); end if;
  update products set category = v_new, updated_at = now() where category = v_old;
  get diagnostics n = row_count;
  select coalesce(jsonb_agg(distinct_v order by o), '[]') into v_list from (
    select case when v = v_old then v_new else v end distinct_v, min(o) o
      from jsonb_array_elements_text(coalesce(rsa_setting('product_categories'), '[]')) with ordinality t(v, o) group by 1) z;
  if v_old = '' or not (v_list ? v_new) then v_list := v_list || to_jsonb(v_new); end if;
  insert into settings(key, value, confirmed, updated_at, updated_by) values ('product_categories', v_list, true, now(), u.id)
  on conflict (key) do update set value = excluded.value, confirmed = true, updated_at = now(), updated_by = u.id;
  perform rsa_audit(u, 'category.rename', 'products', null, jsonb_build_object('category', v_old), jsonb_build_object('category', v_new), jsonb_build_object('products', n));
  return jsonb_build_object('updated', n);
end $$;
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
    when 'import.preview'     then rsa__import_preview(u, p)
    when 'import.commit'      then rsa__import_commit(u, p)
    when 'import.list'        then rsa__import_list(u, p)
    when 'import.orders'      then rsa__import_orders(u, p)
    when 'import.cancel'      then rsa__import_cancel(u, p)
    when 'import.add_orders'  then rsa__import_add_orders(u, p)
    when 'import.compare'     then rsa__import_compare(u, p)
    when 'alias.list'         then rsa__alias_list(u, p)
    when 'report.products'    then rsa__report_products(u, p)
    when 'report.delivery'    then rsa__report_delivery(u, p)
    when 'report.expenses'    then rsa__report_expenses(u, p)
    when 'report.staff'       then rsa__report_staff(u, p)
    when 'payroll.preview'    then rsa__payroll_preview(u, p)
    when 'payroll.pay'        then rsa__payroll_pay(u, p)
    when 'payroll.cancel'     then rsa__payroll_cancel(u, p)
    when 'payroll.summary'    then rsa__payroll_summary(u, p)
    when 'payroll.set_wage'   then rsa__payroll_set_wage(u, p)
    when 'category.list'      then rsa__category_list(u, p)
    when 'category.rename'    then rsa__category_rename(u, p)
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
    when 'expense.update'     then rsa__expense_update(u, p)
    when 'report.costs'       then rsa__report_costs(u, p)
    when 'cost.categories'    then rsa__cost_categories(u, p)
    when 'dashboard.home'     then rsa__dashboard_home(u, p)
    when 'cashflow.months'    then rsa__cashflow_months(u, p)
    when 'cashflow.calendar'  then rsa__cashflow_calendar(u, p)
    when 'recurring.list'     then rsa__recurring_list(u, p)
    else (select jsonb_build_object('error', 'ไม่รู้จักคำสั่ง ' || p_action))
  end;
end $$;

-- profit, one formula for the whole system (overview, reports, profit that can be drawn):
--   sales − variable costs (group A: purchases incl. goods received, delivery GP / ads) = gross profit
--   gross profit − fixed costs (group B, incl. wages) = net profit; group C (debt, capital, investment, drawings) is never a cost.
-- Costs count once approved (รอทำจ่าย) or paid, on the expense date. Waste, staff meals and count differences are already
-- inside the purchases, so they are shown but not deducted again. Recipe cost is kept as a check only.
create or replace function rsa_profit(p_from date, p_to date) returns jsonb language sql stable as $$
  with o as (
    select coalesce(sum(total - refunded), 0) revenue, coalesce(sum(cost_total), 0) recipe_cogs,
           coalesce(sum(coalesce((select po.commission + po.vat + po.other_fee from platform_orders po where po.matched_order_id = orders.id and po.status = 'done' limit 1), est_fee))
             filter (where channel_kind = 'delivery' and settlement_id is null), 0) est_fee_unsettled,
           count(*) filter (where channel_kind = 'delivery' and settlement_id is null
             and not exists (select 1 from platform_orders po where po.matched_order_id = orders.id and po.status = 'done')) fee_guessed
      from orders where status <> 'cancelled' and biz_date between p_from and p_to),
  s as (select coalesce(sum(fee), 0) fee from delivery_settlements where status = 'done' and period_to between p_from and p_to),
  w as (select coalesce(sum(qty * unit_cost) filter (where kind = 'waste'), 0) waste,
               coalesce(sum(qty * unit_cost) filter (where kind = 'staff_meal'), 0) staff_meals,
               coalesce(sum(qty * unit_cost) filter (where kind = 'owner_use'), 0) owner_use
          from waste_records where status = 'recorded' and biz_date between p_from and p_to),
  k as (select coalesce(sum(-l.qty * coalesce(l.unit_cost, 0)), 0) shrink from stock_ledger l join stocktakes t on t.id = l.source_id
         where l.kind = 'count_adjust' and t.context <> 'opening' and rsa_bdate(l.occurred_at) between p_from and p_to),
  e as (select coalesce(sum(x.amount) filter (where coalesce(c.grp, 'B') = 'A'), 0) var_cost,
               coalesce(sum(x.amount) filter (where coalesce(c.grp, 'B') = 'B'), 0) fixed_cost
          from expenses x left join expense_categories c on c.id = x.category_id
         where x.status in ('รอทำจ่าย','จ่ายแล้ว') and x.advance_user_id is null and coalesce(c.grp, 'B') <> 'C'
           and rsa_bdate(x.occurred_at) between p_from and p_to),
  ep as (select coalesce(sum(x.amount), 0) pending_amount from expenses x left join expense_categories c on c.id = x.category_id
          where x.status = 'รออนุมัติ' and x.advance_user_id is null and coalesce(c.grp, 'B') <> 'C' and rsa_bdate(x.occurred_at) between p_from and p_to),
  est as (select count(*) n from expenses x join fixed_expenses f on f.id = x.fixed_expense_id
           where x.status in ('รอทำจ่าย','จ่ายแล้ว') and x.status <> 'จ่ายแล้ว' and rsa_bdate(x.occurred_at) between p_from and p_to),
  f as (select bool_and(fee_confirmed) fees_confirmed from channels where kind = 'delivery' and active)
  select jsonb_build_object('from', p_from, 'to', p_to,
    'revenue', o.revenue,
    'cogs', e.var_cost, 'purchases', e.var_cost, 'recipe_cogs', round(o.recipe_cogs, 2),
    'delivery_fees', s.fee + o.est_fee_unsettled,
    'var_costs', e.var_cost + s.fee + o.est_fee_unsettled,
    'gross_profit', round(o.revenue - e.var_cost - s.fee - o.est_fee_unsettled, 2),
    'fixed_costs', e.fixed_cost, 'expenses', e.fixed_cost, 'pending_expenses', ep.pending_amount,
    'net_profit', round(o.revenue - e.var_cost - s.fee - o.est_fee_unsettled - e.fixed_cost, 2),
    'waste', round(w.waste, 2), 'shrink', round(k.shrink, 2), 'staff_meals', round(w.staff_meals, 2), 'owner_use', round(w.owner_use, 2),
    'complete', coalesce(f.fees_confirmed, true) and o.fee_guessed = 0 and ep.pending_amount = 0 and est.n = 0
                and not (o.revenue > 0 and e.var_cost = 0),
    'flags', jsonb_strip_nulls(jsonb_build_object(
       'purchase', case when o.revenue > 0 and e.var_cost = 0 then 'ยังไม่มียอดซื้อวัตถุดิบ / รับของในช่วงนี้ กำไรจะสูงกว่าจริง' end,
       'fee', case when not coalesce(f.fees_confirmed, true) then 'ค่าธรรมเนียม Delivery ยังไม่ยืนยัน' end,
       'fee_est', case when o.fee_guessed > 0 then 'ค่า GP Delivery บางส่วนเป็นประมาณการ (ยังไม่ได้รับเงินหรือนำเข้าไฟล์แพลตฟอร์ม)' end,
       'bill_est', case when est.n > 0 then 'มีค่าใช้จ่ายประจำที่ยังไม่ได้จ่ายจริง (ใช้ยอดประมาณการ)' end,
       'pending', case when ep.pending_amount > 0 then 'มีค่าใช้จ่ายรออนุมัติที่ยังไม่นับรวม' end)))
  from o, s, w, k, e, ep, est, f
$$;
