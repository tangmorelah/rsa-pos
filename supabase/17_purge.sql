-- RSA - POS Assistant : owner / admin permanently removes an entry that was entered by mistake.
-- Only entries already cancelled can be removed: cancelling has put the money and stock back,
-- so removing the entry together with its reversal leaves every balance unchanged.
-- A full copy of what was removed stays in audit_log (action 'data.purge').
-- Not removable: daily closes, payroll, capital / loans, Delivery payouts (cancel those instead).
set check_function_bodies = off;

-- delete guards stay on; only data.purge opens them, inside its own transaction
create or replace function rsa_block_delete() returns trigger language plpgsql as $$
begin
  if current_setting('rsa.purge', true) = 'on' then return null; end if;
  raise exception 'ลบข้อมูลในตาราง % ไม่ได้ ให้ใช้การยกเลิกหรือปิดใช้งานแทน', tg_table_name;
end $$;

create or replace function rsa__data_purge(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_type text := p->>'type'; v_id uuid := rsa_uuid(p, 'id'); v_reason text := trim(coalesce(p->>'reason', ''));
  v_row jsonb; v_extra jsonb := '{}'; v_ids uuid[]; v_label text;
begin
  if u.role not in ('owner', 'admin') then perform rsa_err('ลบถาวรได้เฉพาะเจ้าของร้านหรือผู้ดูแลระบบ'); end if;
  if v_reason = '' then perform rsa_err('กรุณาระบุเหตุผลที่ลบ'); end if;
  perform set_config('rsa.purge', 'on', true);

  if v_type = 'expense' then
    select to_jsonb(e) into v_row from expenses e where e.id = v_id for update;
    if v_row is null then perform rsa_err('ไม่พบรายการ'); end if;
    if v_row->>'status' <> 'ยกเลิก' then perform rsa_err('ยกเลิกรายการก่อน แล้วจึงลบถาวรได้'); end if;
    if v_row->>'receipt_id' is not null then perform rsa_err('ค่าใช้จ่ายนี้มาจากใบรับของ ให้ลบที่ใบรับของ'); end if;
    if v_row->>'fixed_expense_id' is not null then perform rsa_err('บิลค่าใช้จ่ายประจำลบไม่ได้ ระบบจะสร้างบิลรอบนั้นขึ้นใหม่ ให้ยกเลิกไว้'); end if;
    if exists (select 1 from payroll_runs where expense_id = v_id) or exists (select 1 from capital_entries where expense_id = v_id) or v_row->>'advance_user_id' is not null then
      perform rsa_err('รายการนี้ผูกกับค่าจ้างหรือทุน ลบไม่ได้ ให้ยกเลิกไว้'); end if;
    v_ids := array[v_id]; v_label := v_row->>'expense_no' || ' ' || (v_row->>'description');
  elsif v_type = 'receipt' then
    select to_jsonb(r) into v_row from stock_receipts r where r.id = v_id for update;
    if v_row is null then perform rsa_err('ไม่พบใบรับของ'); end if;
    if v_row->>'status' <> 'cancelled' then perform rsa_err('ยกเลิกใบรับของก่อน แล้วจึงลบถาวรได้'); end if;
    select array_agg(id) into v_ids from expenses where receipt_id = v_id or id = (v_row->>'expense_id')::uuid;
    if exists (select 1 from expenses where id = any(coalesce(v_ids, '{}')) and status <> 'ยกเลิก') then perform rsa_err('ค่าใช้จ่ายของใบรับของนี้ยังไม่ได้ยกเลิก'); end if;
    select coalesce(jsonb_agg(to_jsonb(l)), '[]') into v_extra from stock_receipt_lines l where l.receipt_id = v_id;
    v_extra := jsonb_build_object('lines', v_extra);
    v_label := 'ใบรับของ ' || (v_row->>'receipt_no');
  elsif v_type = 'waste' then
    select to_jsonb(w) into v_row from waste_records w where w.id = v_id for update;
    if v_row is null then perform rsa_err('ไม่พบรายการ'); end if;
    if v_row->>'status' <> 'cancelled' then perform rsa_err('ยกเลิกรายการก่อน แล้วจึงลบถาวรได้'); end if;
    v_label := (v_row->>'item_name') || ' ' || (v_row->>'qty') || ' ' || (v_row->>'unit');
  elsif v_type = 'order' then
    select to_jsonb(o) into v_row from orders o where o.id = v_id for update;
    if v_row is null then perform rsa_err('ไม่พบออเดอร์'); end if;
    if v_row->>'status' <> 'cancelled' then perform rsa_err('ยกเลิกออเดอร์ก่อน แล้วจึงลบถาวรได้'); end if;
    if v_row->>'settlement_id' is not null then perform rsa_err('ออเดอร์นี้อยู่ในรอบรับเงิน Delivery แล้ว ลบไม่ได้'); end if;
    v_extra := jsonb_build_object(
      'items', (select coalesce(jsonb_agg(to_jsonb(i)), '[]') from order_items i where i.order_id = v_id),
      'payments', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from order_payments x where x.order_id = v_id));
    v_label := 'ออเดอร์ ' || (v_row->>'order_no');
  else
    perform rsa_err('ลบถาวรได้เฉพาะ ค่าใช้จ่าย ออเดอร์ขาย รับของ และของเสีย');
  end if;

  -- keep a full copy first
  perform rsa_audit(u, 'data.purge', v_type, v_id::text, v_row || v_extra, null, jsonb_build_object('reason', v_reason, 'label', v_label));

  if v_type in ('expense', 'receipt') and v_ids is not null then
    update expenses set replaced_by = null where replaced_by = any(v_ids);
    update expenses set replaces_id = null where replaces_id = any(v_ids);
    delete from money_ledger where source_type in ('expense', 'expense_reversal') and source_id = any(v_ids);
    delete from attachments where linked_type = 'expense' and linked_id = any(v_ids);
    delete from expenses where id = any(v_ids);
  end if;
  if v_type = 'receipt' then
    delete from stock_ledger where source_type = 'receipt' and source_id = v_id;
    delete from attachments where linked_type = 'receipt' and linked_id = v_id;
    delete from stock_receipt_lines where receipt_id = v_id;
    delete from stock_receipts where id = v_id;
  elsif v_type = 'waste' then
    delete from stock_ledger where source_type = 'waste' and source_id = v_id;
    delete from attachments where linked_type = 'waste' and linked_id = v_id;
    delete from waste_records where id = v_id;
  elsif v_type = 'order' then
    update orders set replaced_by = null where replaced_by = v_id;
    update orders set replaces_order_id = null where replaces_order_id = v_id;
    update platform_orders set matched_order_id = null where matched_order_id = v_id;
    delete from stock_ledger where source_type = 'order_item' and source_id in (select id from order_items where order_id = v_id);
    delete from money_ledger where source_type in ('order', 'order_refund') and source_id = v_id;
    delete from attachments where linked_type = 'order' and linked_id = v_id;
    delete from order_payments where order_id = v_id;
    delete from order_events where order_id = v_id;
    delete from order_items where order_id = v_id;
    delete from orders where id = v_id;
  end if;

  perform set_config('rsa.purge', 'off', true);
  return jsonb_build_object('ok', true, 'label', v_label);
end $$;
