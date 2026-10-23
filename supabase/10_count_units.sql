-- RSA - POS Assistant : count leftovers in any unit (kg, whole fruit, prepared boxes, skewers); the system converts to the stock unit
set check_function_bodies = off;

-- Units a stock item can be counted in:
--   base   : the stock unit itself (factor 1)
--   avg    : owner-set average, e.g. 1 ลูก ≈ 3.5 กก.
--   recipe : a sold unit taken from the product recipe, e.g. 1 กล่อง แตงโม = 0.35 กก.
create or replace function rsa_stock_units(p_item uuid) returns jsonb language sql stable as $$
  select jsonb_build_array(jsonb_build_object('key', 'base', 'unit', s.unit, 'factor', 1, 'kind', 'base'))
      || coalesce((select jsonb_agg(jsonb_build_object('key', 'u:' || (x->>'unit'), 'unit', x->>'unit', 'factor', (x->>'factor')::numeric, 'kind', 'avg'))
                     from jsonb_array_elements(s.count_units) x
                    where coalesce(x->>'unit', '') <> '' and nullif(x->>'factor', '')::numeric > 0), '[]')
      || coalesce((select jsonb_agg(jsonb_build_object('key', 'p:' || p.id, 'unit', p.unit, 'factor', rl.qty, 'kind', 'recipe', 'product', p.name, 'emoji', p.emoji) order by p.sort_order)
                     from recipe_lines rl join products p on p.id = rl.product_id where rl.stock_item_id = s.id and p.active), '[]')
  from stock_items s where s.id = p_item
$$;

create or replace function rsa_stocktake_insert(u app_users, p_context text, p_lines jsonb, p_note text, p_close uuid default null) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid(); ln jsonb; pt jsonb; un jsonb; v_item stock_items; v_sys numeric; v_cnt numeric; v_units jsonb; v_detail jsonb; n int := 0;
begin
  if p_context = 'opening' then perform rsa_need(u, 'master.manage'); else perform rsa_need(u, 'stock.count'); end if;
  insert into stocktakes(id, context, biz_date, close_id, note, created_by) values (v_id, p_context, rsa_today(), p_close, p_note, u.id);
  for ln in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    select * into v_item from stock_items where id = rsa_uuid(ln, 'stock_item_id');
    if not found then continue; end if;
    v_detail := null;
    if jsonb_typeof(ln->'parts') = 'array' and exists (select 1 from jsonb_array_elements(ln->'parts') x where nullif(x->>'qty', '') is not null) then
      -- counted in several units: the server converts with its own factors
      v_units := rsa_stock_units(v_item.id); v_cnt := 0; v_detail := '[]';
      for pt in select * from jsonb_array_elements(ln->'parts') loop
        if nullif(pt->>'qty', '') is null then continue; end if;
        if (pt->>'qty')::numeric < 0 then perform rsa_err('จำนวนนับติดลบไม่ได้'); end if;
        select x into un from jsonb_array_elements(v_units) x where x->>'key' = pt->>'key';
        if un is null then perform rsa_err('หน่วยนับของ "' || v_item.name || '" ไม่ถูกต้อง ลองเปิดหน้าใหม่'); end if;
        v_cnt := v_cnt + (pt->>'qty')::numeric * (un->>'factor')::numeric;
        v_detail := v_detail || jsonb_build_array(un || jsonb_build_object('qty', (pt->>'qty')::numeric));
        un := null;
      end loop;
      v_cnt := round(v_cnt, 3);
    elsif nullif(ln->>'counted_qty', '') is not null then
      v_cnt := rsa_num(ln, 'counted_qty');
    else
      continue;
    end if;
    if v_cnt < 0 then perform rsa_err('จำนวนนับติดลบไม่ได้'); end if;
    v_sys := rsa_stock_qty(v_item.id);
    insert into stocktake_lines(stocktake_id, stock_item_id, item_name, system_qty, counted_qty, variance, unit_cost, note, count_detail)
    values (v_id, v_item.id, v_item.name, v_sys, v_cnt, v_cnt - v_sys, rsa_num(ln, 'unit_cost'), nullif(ln->>'note', ''), v_detail);
    n := n + 1;
  end loop;
  if n = 0 then
    update stocktakes set status = 'rejected', note = coalesce(p_note, '') || ' (ไม่มีรายการนับ)' where id = v_id;
    return null;
  end if;
  perform rsa_audit(u, 'stocktake.create', 'stocktake', v_id::text, null, jsonb_build_object('context', p_context, 'lines', n));
  return v_id;
end $$;

-- the closing screen and the stock page get the units to count with
create or replace function rsa__close_preview(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_date date := rsa_date(p, 'date'); v_close uuid;
begin
  if not (rsa_has(u, 'closing.add') or rsa_has(u, 'closing.view_all')) then perform rsa_need(u, 'closing.add'); end if;
  select id into v_close from daily_closes where biz_date = v_date;
  return jsonb_build_object('computed', rsa_close_compute(v_date),
    'close', case when v_close is not null then rsa_close_json(v_close) end,
    'stock', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'unit', s.unit, 'code', s.code,
                'system_qty', rsa_stock_qty(s.id), 'units', rsa_stock_units(s.id)) order by s.code nulls last, s.name), '[]')
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

create or replace function rsa__stock_units(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_object_agg(s.id, rsa_stock_units(s.id)), '{}') from stock_items s where s.active);
end $$;

create or replace function rsa_master_cols(p_entity text) returns text[] language sql immutable as $$
  select case p_entity
    when 'products' then array['sku','name','category','unit','price','delivery_price','delivery_enabled','emoji','main_stock_item_id','est_cost','markdown_price','sort_order','active']
    when 'stock_items' then array['code','name','kind','unit','count_units','min_qty','reorder_qty','avg_cost','default_supplier_id','cost_category_id','active']
    when 'units' then array['name','active']
    when 'channels' then array['name','kind','payment_method','account_id','fee_pct','fee_confirmed','settlement_days','sort_order','active']
    when 'payment_accounts' then array['name','kind','is_drawer','bank_detail','opening_balance','opening_confirmed','active']
    when 'promotions' then array['name','scope','product_ids','channel_ids','rule','value','min_qty','buy_qty','bundle_price','storefront_only','starts_at','ends_at','active']
    when 'suppliers' then array['name','contact_name','phone','line_id','supplies','order_days','lead_time','delivery_schedule','min_order',
                                'delivery_fee','payment_method','credit_terms','bank_detail','can_issue_receipt','can_issue_tax_invoice',
                                'return_terms','priority','note','active']
    when 'expense_categories' then array['name','tax_category','staff_allowed','active','code','grp','parent_id','budget_method','budget_amount','budget_pct',
                                          'pct_base','channel_id','c_kind','ratio_key','budget_confirmed','sort_order']
    when 'fixed_expenses' then array['name','category_id','payee','amount','due_day','account_id','start_month','end_month','auto_approve','confirmed','note','active',
                                      'frequency','weekday','fund_source']
  end
$$;
