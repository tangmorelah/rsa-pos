-- RSA - POS Assistant : import from other systems (QR / bank lines, delivery platform orders) to cross-check what the team
-- recorded and to use the platform's real fees. Rows arrive already split into columns by the browser (CSV or Excel);
-- every value is checked again here. Safe to run again.
set check_function_bodies = off;

-- the default drawer name, shorter (a name the owner changed is left alone)
update payment_accounts set name = 'เงินสดหน้าร้าน' where name = 'ลิ้นชักเงินสดหน้าร้าน';

-- ---------------------------------------------------------------- parsing helpers (lenient, return null when unreadable)
-- dates: 2026-10-21, 21/10/2026, 21-10-2026, 21/10/2569 (Buddhist year), 21/10/69
create or replace function rsa_parse_date(p text) returns date language plpgsql immutable as $$
declare t text := trim(coalesce(p, '')); m text[]; y int; d date;
begin
  if t = '' then return null; end if;
  m := regexp_match(t, '^(\d{4})-(\d{1,2})-(\d{1,2})');
  if m is not null then y := m[1]::int; if y > 2400 then y := y - 543; end if;
    begin d := make_date(y, m[2]::int, m[3]::int); exception when others then return null; end; return d; end if;
  m := regexp_match(t, '^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})');
  if m is not null then y := m[3]::int; if y < 100 then y := y + (case when y > 40 then 2500 else 2000 end); end if; if y > 2400 then y := y - 543; end if;
    begin d := make_date(y, m[2]::int, m[1]::int); exception when others then return null; end; return d; end if;
  return null;
end $$;

-- times: 13:05, 13.05, 13:05:59, 1305 (empty = no time)
create or replace function rsa_parse_time(p text) returns time language plpgsql immutable as $$
declare t text := trim(coalesce(p, '')); m text[];
begin
  if t = '' then return null; end if;
  m := regexp_match(t, '(\d{1,2})[:.]?(\d{2})(?:[:.](\d{2}))?');
  if m is null or m[1]::int > 23 or m[2]::int > 59 then return null; end if;
  return make_time(m[1]::int, m[2]::int, coalesce(m[3], '0')::int);
end $$;

-- numbers: 1,234.50 · ฿1234 · (12.00) negative · empty = null
create or replace function rsa_parse_num(p text) returns numeric language plpgsql immutable as $$
declare t text := regexp_replace(trim(coalesce(p, '')), '[฿,\s]|THB|บาท', '', 'g'); neg boolean := false;
begin
  if t = '' then return null; end if;
  if t ~ '^\(.*\)$' then neg := true; t := substr(t, 2, length(t) - 2); end if;
  if t !~ '^-?\d+(\.\d+)?$' then return null; end if;
  return case when neg then -t::numeric else t::numeric end;
end $$;

create or replace function rsa_import_ts(d date, t time) returns timestamptz language sql immutable as $$
  select ((d + coalesce(t, time '12:00'))::timestamp at time zone 'Asia/Bangkok')
$$;

-- ---------------------------------------------------------------- QR / bank lines
-- rows: [{date, time, amount, ref, desc}] → each row checked, duplicates found, and day totals set against what the shop recorded
create or replace function rsa_import_bank_check(p_acc uuid, p_rows jsonb) returns jsonb language plpgsql stable as $$
declare r jsonb; n int := 0; v_out jsonb := '[]'; v_d date; v_t time; v_amt numeric; v_ref text; v_err text; v_dup boolean; v_seen text[] := '{}'; v_key text;
begin
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    n := n + 1;
    if coalesce(r->>'date', '') ~* '^\s*(ตัวอย่าง|example)' then continue; end if;
    v_d := rsa_parse_date(r->>'date'); v_t := rsa_parse_time(r->>'time'); v_amt := rsa_parse_num(r->>'amount'); v_ref := nullif(trim(coalesce(r->>'ref', '')), '');
    v_err := case when v_d is null then 'วันที่อ่านไม่ได้' when v_amt is null then 'ยอดเงินอ่านไม่ได้' when v_amt <= 0 then 'ยอดเงินต้องมากกว่า 0'
                  when v_d > rsa_today() then 'วันที่อยู่ในอนาคต' end;
    v_key := coalesce(v_ref, v_d::text || ' ' || coalesce(v_t::text, '-') || ' ' || coalesce(v_amt::text, ''));
    v_dup := v_err is null and (v_key = any(v_seen) or exists (select 1 from bank_lines b where b.account_id = p_acc and b.status = 'done' and b.direction = 'in'
              and ((v_ref is not null and b.ref_no = v_ref) or (v_ref is null and b.occurred_at = rsa_import_ts(v_d, v_t) and b.amount = v_amt))));
    v_seen := v_seen || v_key;
    v_out := v_out || jsonb_build_array(jsonb_build_object('n', n, 'date', v_d, 'time', to_char(v_t, 'HH24:MI'), 'amount', v_amt, 'ref', v_ref,
               'desc', nullif(trim(coalesce(r->>'desc', '')), ''), 'error', v_err, 'dup', v_dup, 'daily', v_t is null));
  end loop;
  return jsonb_build_object('rows', v_out,
    'days', (select coalesce(jsonb_agg(jsonb_build_object('date', d,
        'file', (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_out) x where (x->>'date')::date = d and x->>'error' is null),
        'system', (select coalesce(sum(case m.direction when 'in' then m.amount else -m.amount end), 0) from money_ledger m
                    where m.account_id = p_acc and m.biz_date = d and m.source_type in ('order','order_refund')),
        'already', (select coalesce(sum(amount), 0) from bank_lines b where b.account_id = p_acc and b.biz_date = d and b.status = 'done' and b.direction = 'in'))
        order by d), '[]')
      from (select distinct (x->>'date')::date d from jsonb_array_elements(v_out) x where x->>'error' is null) t),
    'ok', (select count(*) from jsonb_array_elements(v_out) x where x->>'error' is null and not (x->>'dup')::boolean),
    'dups', (select count(*) from jsonb_array_elements(v_out) x where (x->>'dup')::boolean),
    'errors', (select count(*) from jsonb_array_elements(v_out) x where x->>'error' is not null));
end $$;

-- ---------------------------------------------------------------- delivery platform orders
-- rows: [{order_id, date, time, item, qty, gross, discount, commission, vat, other, status}] → grouped per order, item names mapped to
-- products (saved aliases, exact product name, or p_alias {name: product_id | "skip"} chosen in the preview), then matched to
-- the orders the team recorded on the same day and channel: by the app order number in the note, else same amount + nearest time
create or replace function rsa_import_delivery_check(p_ch uuid, p_rows jsonb, p_alias jsonb) returns jsonb language plpgsql stable as $$
declare r jsonb; n int := 0; v_lines jsonb := '[]'; v_orders jsonb := '[]'; o record; v_match uuid; v_kind text; v_used uuid[] := '{}';
        v_unmapped jsonb; v_from date; v_to date; v_net numeric; v_err jsonb := '[]'; v_tot jsonb;
begin
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    n := n + 1;
    if coalesce(r->>'order_id', '') ~* '^\s*(ตัวอย่าง|example)' then continue; end if;
    if coalesce(trim(r->>'order_id'), '') = '' or rsa_parse_date(r->>'date') is null or coalesce(trim(r->>'item'), '') = ''
       or rsa_parse_num(r->>'qty') is null or rsa_parse_num(r->>'gross') is null then
      v_err := v_err || jsonb_build_array(jsonb_build_object('n', n, 'error',
        case when coalesce(trim(r->>'order_id'), '') = '' then 'ไม่มีเลขออเดอร์' when rsa_parse_date(r->>'date') is null then 'วันที่อ่านไม่ได้'
             when coalesce(trim(r->>'item'), '') = '' then 'ไม่มีชื่อสินค้า' when rsa_parse_num(r->>'qty') is null then 'จำนวนอ่านไม่ได้' else 'ยอดขายอ่านไม่ได้' end));
      continue;
    end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('n', n, 'ext', trim(r->>'order_id'), 'date', rsa_parse_date(r->>'date'), 'time', rsa_parse_time(r->>'time'),
      'item', trim(r->>'item'), 'key', lower(trim(r->>'item')), 'qty', rsa_parse_num(r->>'qty'), 'gross', rsa_parse_num(r->>'gross'),
      'discount', coalesce(rsa_parse_num(r->>'discount'), 0), 'commission', coalesce(rsa_parse_num(r->>'commission'), 0), 'vat', coalesce(rsa_parse_num(r->>'vat'), 0),
      'other', coalesce(rsa_parse_num(r->>'other'), 0), 'cancelled', coalesce(r->>'status', '') ~* '(cancel|ยกเลิก|void|refund)'));
  end loop;
  -- item names: alias chosen now > saved alias > product with the same name
  v_unmapped := (select coalesce(jsonb_agg(distinct x->>'item'), '[]') from jsonb_array_elements(v_lines) x
    where not coalesce(p_alias, '{}') ? (x->>'item')
      and not exists (select 1 from product_aliases a where a.channel_id = p_ch and a.external_name = x->>'key')
      and not exists (select 1 from products pr where pr.active and lower(pr.name) = x->>'key'));
  -- every file order's amounts, so a different-amount pairing never takes a team order another file order matches exactly
  select coalesce(jsonb_agg(jsonb_build_object('d', d, 'gross', g, 'net', g - ds)), '[]') into v_tot
    from (select min((l->>'date')::date) d, sum((l->>'gross')::numeric) g, sum((l->>'discount')::numeric) ds from jsonb_array_elements(v_lines) l group by l->>'ext') t;
  for o in
    select l->>'ext' ext, min((l->>'date')::date) d, min(l->>'time') t, sum((l->>'gross')::numeric) gross, sum((l->>'discount')::numeric) disc,
           sum((l->>'commission')::numeric) com, sum((l->>'vat')::numeric) vat, sum((l->>'other')::numeric) oth, bool_or((l->>'cancelled')::boolean) cancelled,
           jsonb_agg(jsonb_build_object('name', l->>'item', 'qty', (l->>'qty')::numeric, 'gross', (l->>'gross')::numeric,
             'product_id', case when coalesce(p_alias, '{}') ? (l->>'item') then nullif(p_alias->>(l->>'item'), 'skip')
                                else coalesce((select a.product_id::text from product_aliases a where a.channel_id = p_ch and a.external_name = l->>'key'),
                                              (select pr.id::text from products pr where pr.active and lower(pr.name) = l->>'key' limit 1)) end)) items
      from jsonb_array_elements(v_lines) l group by l->>'ext' order by min((l->>'date')::date), min(l->>'time')
  loop
    v_match := null; v_net := o.gross - o.disc;
    if exists (select 1 from platform_orders po where po.channel_id = p_ch and po.external_id = o.ext and po.status = 'done') then v_kind := 'dup';
    elsif o.cancelled then v_kind := 'cancelled';
    else
      -- 1) the app order number typed in the note
      select id into v_match from orders x where x.channel_id = p_ch and x.biz_date = o.d and x.status <> 'cancelled' and not (x.id = any(v_used))
         and position(lower(o.ext) in lower(coalesce(x.note, ''))) > 0
         and not exists (select 1 from platform_orders po where po.matched_order_id = x.id and po.status = 'done') limit 1;
      if v_match is not null then
        v_kind := case when (select total from orders where id = v_match) in (o.gross, v_net) then 'match' else 'diff' end;
      else
        -- 2) same amount, nearest time
        select id into v_match from orders x where x.channel_id = p_ch and x.biz_date = o.d and x.status <> 'cancelled' and not (x.id = any(v_used))
           and x.total in (o.gross, v_net)
           and not exists (select 1 from platform_orders po where po.matched_order_id = x.id and po.status = 'done')
         order by abs(extract(epoch from (x.created_at - rsa_import_ts(o.d, o.t::time)))) limit 1;
        v_kind := case when v_match is null then 'missing' else 'match' end;
      end if;
      if v_match is null and o.t is not null then
        -- 3) a different amount at nearly the same time (within 20 minutes)
        select id into v_match from orders x where x.channel_id = p_ch and x.biz_date = o.d and x.status <> 'cancelled' and not (x.id = any(v_used))
           and abs(extract(epoch from (x.created_at - rsa_import_ts(o.d, o.t::time)))) <= 1200
           and not exists (select 1 from platform_orders po where po.matched_order_id = x.id and po.status = 'done')
           and not exists (select 1 from jsonb_array_elements(v_tot) z where (z->>'d')::date = o.d and x.total in ((z->>'gross')::numeric, (z->>'net')::numeric))
         order by floor(abs(extract(epoch from (x.created_at - rsa_import_ts(o.d, o.t::time)))) / 60), abs(x.total - v_net) limit 1;
        if v_match is not null then v_kind := 'diff'; end if;
      end if;
      if v_match is not null then v_used := v_used || v_match; end if;
    end if;
    v_orders := v_orders || jsonb_build_array(jsonb_build_object('ext', o.ext, 'date', o.d, 'time', to_char(o.t::time, 'HH24:MI'), 'gross', o.gross, 'discount', o.disc,
      'commission', o.com, 'vat', o.vat, 'other', o.oth, 'net', v_net, 'items', o.items, 'kind', v_kind, 'order_id', v_match,
      'order_no', (select order_no from orders where id = v_match), 'order_total', (select total from orders where id = v_match)));
  end loop;
  select min((x->>'date')::date), max((x->>'date')::date) into v_from, v_to from jsonb_array_elements(v_orders) x;
  return jsonb_build_object('orders', v_orders, 'errors', v_err, 'unmapped', v_unmapped, 'from', v_from, 'to', v_to,
    -- recorded by the team in the file's date range but not found in the file
    'staff_only', (select coalesce(jsonb_agg(jsonb_build_object('order_id', x.id, 'order_no', x.order_no, 'date', x.biz_date, 'total', x.total, 'note', x.note,
                      'time', to_char(x.created_at at time zone 'Asia/Bangkok', 'HH24:MI')) order by x.created_at), '[]')
                   from orders x where x.channel_id = p_ch and x.status <> 'cancelled' and x.biz_date between v_from and v_to and not (x.id = any(v_used))
                     and not exists (select 1 from platform_orders po where po.matched_order_id = x.id and po.status = 'done')),
    'days', (select coalesce(jsonb_agg(jsonb_build_object('date', d,
        'file_orders', (select count(*) from jsonb_array_elements(v_orders) x where (x->>'date')::date = d and x->>'kind' not in ('cancelled','dup')),
        'file_gross', (select coalesce(sum((x->>'net')::numeric), 0) from jsonb_array_elements(v_orders) x where (x->>'date')::date = d and x->>'kind' not in ('cancelled','dup')),
        'system_orders', (select count(*) from orders x where x.channel_id = p_ch and x.biz_date = d and x.status <> 'cancelled'),
        'system_gross', (select coalesce(sum(total - refunded), 0) from orders x where x.channel_id = p_ch and x.biz_date = d and x.status <> 'cancelled')) order by d), '[]')
      from generate_series(v_from, v_to, interval '1 day') g(d) where v_from is not null),
    'counts', (select jsonb_object_agg(k, c) from (select x->>'kind' k, count(*) c from jsonb_array_elements(v_orders) x group by x->>'kind') t));
end $$;

-- ---------------------------------------------------------------- API
create or replace function rsa__import_preview(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_acc payment_accounts; v_ch channels;
begin
  perform rsa_need(u, 'cashflow.manage');
  if jsonb_typeof(p->'rows') <> 'array' or jsonb_array_length(p->'rows') = 0 then perform rsa_err('ไฟล์ไม่มีข้อมูล'); end if;
  if jsonb_array_length(p->'rows') > 5000 then perform rsa_err('ไฟล์ใหญ่เกิน 5,000 แถว แบ่งเป็นหลายไฟล์'); end if;
  if p->>'kind' = 'bank' then
    select * into v_acc from payment_accounts where id = rsa_uuid(p, 'account_id') and kind <> 'cash' and active;
    if not found then perform rsa_err('กรุณาเลือกบัญชีที่รับเงิน'); end if;
    return rsa_import_bank_check(v_acc.id, p->'rows');
  elsif p->>'kind' = 'delivery' then
    select * into v_ch from channels where id = rsa_uuid(p, 'channel_id') and kind = 'delivery';
    if not found then perform rsa_err('กรุณาเลือกแพลตฟอร์ม'); end if;
    return rsa_import_delivery_check(v_ch.id, p->'rows', coalesce(p->'aliases', '{}'));
  end if;
  perform rsa_err('เลือกประเภทข้อมูลที่จะนำเข้า');
end $$;

create or replace function rsa__import_commit(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v jsonb := rsa__import_preview(u, p); v_id uuid := gen_random_uuid(); x jsonb; k text; v_added int := 0; v_ch channels;
begin
  if p->>'kind' = 'bank' then
    insert into import_batches(id, kind, account_id, file_name, rows_total, created_by) values (v_id, 'bank', rsa_uuid(p, 'account_id'), p->>'file_name', jsonb_array_length(v->'rows'), u.id);
    for x in select * from jsonb_array_elements(v->'rows') loop
      continue when x->>'error' is not null or (x->>'dup')::boolean;
      insert into bank_lines(account_id, occurred_at, biz_date, direction, amount, ref_no, description, created_by, import_id)
      values (rsa_uuid(p, 'account_id'), rsa_import_ts((x->>'date')::date, (x->>'time')::time), (x->>'date')::date, 'in', (x->>'amount')::numeric,
              x->>'ref', coalesce(x->>'desc', case when (x->>'daily')::boolean then 'ยอดรวมรายวันจากไฟล์' else 'นำเข้าจากไฟล์' end), u.id, v_id);
      v_added := v_added + 1;
    end loop;
  else
    if jsonb_array_length(v->'unmapped') > 0 then perform rsa_err('ยังมีชื่อสินค้าที่ยังไม่ได้จับคู่ ' || jsonb_array_length(v->'unmapped') || ' ชื่อ'); end if;
    select * into v_ch from channels where id = rsa_uuid(p, 'channel_id');
    -- remember the names chosen this time
    for k in select jsonb_object_keys(coalesce(p->'aliases', '{}')) loop
      insert into product_aliases(channel_id, external_name, product_id, created_by)
      values (v_ch.id, lower(trim(k)), case when p->'aliases'->>k = 'skip' then null else (p->'aliases'->>k)::uuid end, u.id)
      on conflict (channel_id, external_name) do update set product_id = excluded.product_id;
    end loop;
    insert into import_batches(id, kind, channel_id, file_name, rows_total, created_by) values (v_id, 'delivery', v_ch.id, p->>'file_name', jsonb_array_length(v->'orders'), u.id);
    for x in select * from jsonb_array_elements(v->'orders') loop
      continue when x->>'kind' = 'dup';
      insert into platform_orders(import_id, channel_id, external_id, biz_date, ordered_at, items, gross, shop_discount, commission, vat, other_fee, platform_status, matched_order_id)
      values (v_id, v_ch.id, x->>'ext', (x->>'date')::date, rsa_import_ts((x->>'date')::date, (x->>'time')::time), x->'items', (x->>'gross')::numeric,
              (x->>'discount')::numeric, (x->>'commission')::numeric, (x->>'vat')::numeric, (x->>'other')::numeric,
              case when x->>'kind' = 'cancelled' then 'cancelled' else 'completed' end, (x->>'order_id')::uuid);
      v_added := v_added + 1;
    end loop;
  end if;
  update import_batches set rows_added = v_added, rows_skipped = rows_total - v_added where id = v_id;
  perform rsa_audit(u, 'import.commit', 'import', v_id::text, null, jsonb_build_object('kind', p->>'kind', 'file', p->>'file_name', 'added', v_added));
  return v || jsonb_build_object('import_id', v_id, 'added', v_added);
end $$;

create or replace function rsa__import_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'cashflow.view');
  return (select coalesce(jsonb_agg(to_jsonb(b) || jsonb_build_object('by', (select display_name from app_users where id = b.created_by),
      'target', coalesce((select name from channels where id = b.channel_id), (select name from payment_accounts where id = b.account_id)),
      'missing', (select count(*) from platform_orders po where po.import_id = b.id and po.status = 'done' and po.platform_status = 'completed' and po.matched_order_id is null))
      order by b.created_at desc), '[]') from (select * from import_batches order by created_at desc limit 50) b);
end $$;

-- the platform orders of one import (for the "add missing orders" screen)
create or replace function rsa__import_orders(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'cashflow.view');
  return (select coalesce(jsonb_agg(to_jsonb(po) || jsonb_build_object('order_no', (select order_no from orders where id = po.matched_order_id),
      'order_total', (select total from orders where id = po.matched_order_id)) order by po.ordered_at), '[]')
    from platform_orders po where po.import_id = rsa_uuid(p, 'import_id') and po.status = 'done');
end $$;

create or replace function rsa__import_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare b import_batches;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into b from import_batches where id = rsa_uuid(p, 'import_id') for update;
  if not found or b.status <> 'done' then perform rsa_err('ไม่พบรอบนำเข้า หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update import_batches set status = 'cancelled', cancelled_by = u.id, cancel_reason = trim(p->>'reason') where id = b.id;
  update bank_lines set status = 'cancelled', cancelled_by = u.id, cancel_reason = 'ยกเลิกรอบนำเข้า: ' || trim(p->>'reason') where import_id = b.id and status = 'done';
  update platform_orders set status = 'cancelled' where import_id = b.id and status = 'done';
  perform rsa_audit(u, 'import.cancel', 'import', b.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true, 'note', 'ออเดอร์ที่เพิ่มเข้ายอดขายจากรอบนี้ยังอยู่ ยกเลิกได้ที่ออเดอร์นั้น');
end $$;

-- orders found in the platform file but not recorded by the team → real delivery orders with the file's time
create or replace function rsa__import_add_orders(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare po platform_orders; v_ch channels; v_items jsonb; v_new jsonb; v_n int := 0; v_skip jsonb := '[]'; v_calc numeric;
begin
  perform rsa_need(u, 'cashflow.manage');
  perform rsa_need(u, 'sales.add');
  for po in select * from platform_orders where id in (select (jsonb_array_elements_text(coalesce(p->'ids', '[]')))::uuid) and status = 'done' for update loop
    if po.matched_order_id is not null or po.platform_status <> 'completed' then continue; end if;
    v_items := (select coalesce(jsonb_agg(jsonb_build_object('product_id', i->>'product_id', 'qty', (i->>'qty')::numeric)), '[]')
                  from jsonb_array_elements(po.items) i where i->>'product_id' is not null);
    if jsonb_array_length(v_items) = 0 then v_skip := v_skip || to_jsonb(po.external_id); continue; end if;
    select * into v_ch from channels where id = po.channel_id;
    perform set_config('rsa.edit_at', po.ordered_at::text, true);
    v_new := rsa__order_create(u, jsonb_build_object('channel_id', po.channel_id, 'items', v_items, 'client_ref', 'import:' || po.channel_id || ':' || po.external_id,
      'note', 'นำเข้าจากไฟล์ ' || v_ch.name || ' #' || po.external_id));
    perform set_config('rsa.edit_at', '', true);
    -- the amount the platform says the customer paid wins over the calculated one
    v_calc := (v_new->>'total')::numeric;
    if v_calc <> po.gross - po.shop_discount then
      update orders set total = po.gross - po.shop_discount, received_note = 'ตามไฟล์แพลตฟอร์ม',
             est_fee = round((po.gross - po.shop_discount) * fee_pct / 100, 2) where id = (v_new->>'id')::uuid;
    end if;
    update platform_orders set matched_order_id = (v_new->>'id')::uuid, added_order = true where id = po.id;
    v_n := v_n + 1;
  end loop;
  perform rsa_audit(u, 'import.add_orders', 'import', null, null, jsonb_build_object('added', v_n));
  return jsonb_build_object('added', v_n, 'skipped_no_product', v_skip);
end $$;

-- per day: what the team recorded against the imported platform file, for every delivery channel
create or replace function rsa__import_compare(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 13); v_to date := rsa_date(p, 'to');
begin
  perform rsa_need(u, 'report.view');
  return (select coalesce(jsonb_agg(x order by x->>'date' desc, x->>'channel'), '[]') from (
    select jsonb_build_object('date', d, 'channel', c.name, 'channel_id', c.id,
      'system_orders', (select count(*) from orders o where o.channel_id = c.id and o.biz_date = d and o.status <> 'cancelled'),
      'system_gross', (select coalesce(sum(total - refunded), 0) from orders o where o.channel_id = c.id and o.biz_date = d and o.status <> 'cancelled'),
      'file_orders', (select count(*) from platform_orders po where po.channel_id = c.id and po.biz_date = d and po.status = 'done' and po.platform_status = 'completed'),
      'file_gross', (select coalesce(sum(gross - shop_discount), 0) from platform_orders po where po.channel_id = c.id and po.biz_date = d and po.status = 'done' and po.platform_status = 'completed'),
      'file_fees', (select coalesce(sum(commission + vat + other_fee), 0) from platform_orders po where po.channel_id = c.id and po.biz_date = d and po.status = 'done' and po.platform_status = 'completed'),
      'imported', exists (select 1 from platform_orders po where po.channel_id = c.id and po.biz_date = d and po.status = 'done')) x
    from channels c cross join generate_series(v_from, v_to, interval '1 day') g(dd) cross join lateral (select dd::date d) dt
    where c.kind = 'delivery' and (c.active or exists (select 1 from orders o where o.channel_id = c.id and o.biz_date = d))) t);
end $$;

create or replace function rsa__alias_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'cashflow.view');
  return (select coalesce(jsonb_agg(to_jsonb(a) || jsonb_build_object('product', (select name from products where id = a.product_id),
           'channel', (select name from channels where id = a.channel_id)) order by a.external_name), '[]') from product_aliases a);
end $$;
