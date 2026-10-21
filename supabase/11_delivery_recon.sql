-- RSA - POS Assistant : Delivery payout reconciliation.
-- Revenue is recorded at the full sales amount (what the platform shows as our sales); the platform's deductions
-- (commission, VAT on commission, ads / merchant-funded promos, other adjustments) are kept separately as costs.
set check_function_bodies = off;

-- what staff typed from the platform app at closing, summed over a period
create or replace function rsa_staff_delivery_gross(p_channel uuid, p_from date, p_to date) returns numeric language sql stable as $$
  select sum((x->>'app_gross')::numeric) from daily_closes d, jsonb_array_elements(d.delivery_counts) x
   where d.biz_date between p_from and p_to and x->>'channel_id' = p_channel::text and nullif(x->>'app_gross', '') is not null
$$;

-- same, but only for days that still have unpaid orders of that platform (a week can be partly paid already)
create or replace function rsa_staff_delivery_gross_open(p_channel uuid, p_from date, p_to date) returns numeric language sql stable as $$
  select sum((x->>'app_gross')::numeric) from daily_closes d, jsonb_array_elements(d.delivery_counts) x
   where d.biz_date between p_from and p_to and x->>'channel_id' = p_channel::text and nullif(x->>'app_gross', '') is not null
     and not exists (select 1 from orders o where o.channel_id = p_channel and o.biz_date = d.biz_date and o.settlement_id is not null)
$$;

create or replace function rsa__settlement_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_ch channels; v_from date := rsa_date(p, 'from'); v_to date := rsa_date(p, 'to');
        v_sys numeric; v_gross numeric := rsa_num(p, 'reported_gross'); v_fee numeric; v_net numeric := rsa_num(p, 'net');
        v_at timestamptz := rsa_ts(p, 'deposited_at'); v_bd jsonb := '{}';
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v_ch from channels where id = rsa_uuid(p, 'channel_id') and kind = 'delivery';
  if not found then perform rsa_err('กรุณาเลือกช่องทาง Delivery'); end if;
  if rsa_uuid(p, 'account_id') is null then perform rsa_err('กรุณาเลือกบัญชีที่เงินเข้า'); end if;
  if v_to < v_from then perform rsa_err('ช่วงวันที่ไม่ถูกต้อง'); end if;
  select coalesce(sum(total - refunded), 0) into v_sys from orders
   where channel_id = v_ch.id and status <> 'cancelled' and settlement_id is null and biz_date between v_from and v_to;
  v_gross := coalesce(v_gross, v_sys);
  if jsonb_typeof(p->'breakdown') = 'object' then
    select coalesce(jsonb_object_agg(k, round(nullif(p->'breakdown'->>k, '')::numeric, 2)), '{}') into v_bd
      from unnest(array['commission','vat','marketing','other']) k where nullif(p->'breakdown'->>k, '') is not null;
    v_fee := coalesce((select sum(value::text::numeric) from jsonb_each(v_bd)), 0);
  else
    v_fee := rsa_num(p, 'fee', 0);
  end if;
  v_net := coalesce(v_net, v_gross - v_fee);
  if v_net <= 0 then perform rsa_err('ยอดเงินเข้าสุทธิต้องมากกว่า 0'); end if;
  if abs(v_gross - v_fee - v_net) > 0.01 then
    perform rsa_err('ยอดขาย ' || v_gross || ' − หักรวม ' || v_fee || ' = ' || (v_gross - v_fee) || ' ไม่เท่ากับเงินเข้า ' || v_net || ' ตรวจตัวเลขจากรายงานแพลตฟอร์ม หรือใส่ส่วนต่างในช่อง "ปรับปรุงอื่น"');
  end if;
  insert into delivery_settlements(id, channel_id, channel_name, period_from, period_to, system_gross, reported_gross, fee, net, account_id, deposited_at, ref_no, note, fee_breakdown, created_by)
  values (v_id, v_ch.id, v_ch.name, v_from, v_to, v_sys, v_gross, v_fee, v_net, rsa_uuid(p, 'account_id'), v_at, nullif(p->>'ref_no', ''), nullif(p->>'note', ''), v_bd, u.id);
  update orders set settlement_id = v_id where channel_id = v_ch.id and status <> 'cancelled' and settlement_id is null and biz_date between v_from and v_to;
  perform rsa_money(rsa_uuid(p, 'account_id'), 'in', v_net, 'settlement', v_id, v_ch.name || ' ' || to_char(v_from, 'DD/MM') || '-' || to_char(v_to, 'DD/MM'), u.id, v_at);
  perform rsa_link_attachments(p->'attachment_ids', 'settlement', v_id, u);
  perform rsa_audit(u, 'settlement.create', 'settlement', v_id::text, null,
    jsonb_build_object('channel', v_ch.name, 'system_gross', v_sys, 'reported_gross', v_gross, 'fee', v_fee, 'breakdown', v_bd, 'net', v_net));
  return (select to_jsonb(s) from delivery_settlements s where id = v_id);
end $$;

create or replace function rsa__settlement_preview(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'cashflow.view');
  return (select jsonb_build_object('orders', count(*), 'system_gross', coalesce(sum(total - refunded), 0), 'est_fee', coalesce(sum(est_fee), 0),
            'staff_gross', rsa_staff_delivery_gross_open(rsa_uuid(p, 'channel_id'), rsa_date(p, 'from'), rsa_date(p, 'to')),
            'fee_pct', (select fee_pct from channels where id = rsa_uuid(p, 'channel_id')))
            from orders where channel_id = rsa_uuid(p, 'channel_id') and status <> 'cancelled' and settlement_id is null
             and biz_date between rsa_date(p, 'from') and rsa_date(p, 'to'));
end $$;

create or replace function rsa__report_delivery(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 29); v_to date := rsa_date(p, 'to');
begin
  perform rsa_need(u, 'report.view');
  return jsonb_build_object('from', v_from, 'to', v_to,
    'rows', (select coalesce(jsonb_agg(x order by x->>'date' desc, x->>'channel'), '[]') from (
       select jsonb_build_object('date', o.biz_date, 'channel_id', o.channel_id, 'channel', o.channel_name, 'orders', count(*),
         'gross', sum(o.total - o.refunded), 'est_fee', sum(o.est_fee), 'est_net', sum(o.total - o.refunded - o.est_fee),
         'staff_gross', rsa_staff_delivery_gross(o.channel_id, o.biz_date, o.biz_date),
         'fee_pct', max(o.fee_pct), 'expected_date', o.biz_date + max(c.settlement_days),
         'settled_orders', count(*) filter (where o.settlement_id is not null),
         'status', case when bool_and(o.settlement_id is not null) then 'รับเงินแล้ว'
                        when o.biz_date + max(c.settlement_days) < rsa_today() then 'เลยกำหนด' else 'รอรับเงิน' end) x
         from orders o join channels c on c.id = o.channel_id
        where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.biz_date between v_from and v_to
        group by o.biz_date, o.channel_id, o.channel_name) t),
    -- payout weeks not recorded yet (Monday to Sunday), ready to match with the platform statement
    'open_weeks', (select coalesce(jsonb_agg(x order by x->>'from', x->>'channel'), '[]') from (
       select jsonb_build_object('channel_id', o.channel_id, 'channel', o.channel_name, 'from', w.wk, 'to', w.wk + 6,
         'orders', count(*), 'gross', sum(o.total - o.refunded), 'est_fee', sum(o.est_fee), 'est_net', sum(o.total - o.refunded - o.est_fee),
         'staff_gross', rsa_staff_delivery_gross_open(o.channel_id, w.wk, w.wk + 6), 'first_sale', min(o.biz_date), 'last_sale', max(o.biz_date)) x
         from orders o cross join lateral (select (date_trunc('week', o.biz_date))::date wk) w
        where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null
        group by o.channel_id, o.channel_name, w.wk) t),
    'channels', (select coalesce(jsonb_agg(jsonb_build_object('channel_id', c.id, 'name', c.name, 'fee_pct', c.fee_pct, 'fee_confirmed', c.fee_confirmed,
         'settlement_days', c.settlement_days,
         'gross', (select coalesce(sum(total - refunded), 0) from orders o where o.channel_id = c.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
         'orders', (select count(*) from orders o where o.channel_id = c.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
         'unsettled', (select coalesce(sum(total - refunded - est_fee), 0) from orders o where o.channel_id = c.id and o.status <> 'cancelled' and o.settlement_id is null),
         -- actual deduction rate from recorded payouts (last 90 days) next to the rate set in the system
         'actual_fee_pct', (select round(sum(s.fee) * 100 / nullif(sum(s.reported_gross), 0), 2) from delivery_settlements s
                             where s.channel_id = c.id and s.status = 'done' and s.period_to >= rsa_today() - 90))
         order by c.sort_order), '[]') from channels c where c.kind = 'delivery' and c.active),
    'settlements', (select coalesce(jsonb_agg(to_jsonb(s) || jsonb_build_object('account_name', (select name from payment_accounts where id = s.account_id),
         'staff_gross', rsa_staff_delivery_gross(s.channel_id, s.period_from, s.period_to),
         'orders', (select count(*) from orders o where o.settlement_id = s.id),
         'fee_pct_actual', round(s.fee * 100 / nullif(s.reported_gross, 0), 2),
         'attachments', rsa_attachment_refs('settlement', s.id))
         order by s.deposited_at desc), '[]') from delivery_settlements s where s.period_to between v_from and v_to));
end $$;
