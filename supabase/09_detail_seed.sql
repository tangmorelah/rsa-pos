-- RSA - POS Assistant : shop data confirmed by the owner (from the previous version's setup sheet).
-- Inserted only when missing, so running again never overwrites what the owner has changed.
-- Stock quantities and costs start at 0 and recipes are left empty: the owner fills them in.

insert into units(name) values ('ไม้') on conflict (name) do nothing;

insert into settings(key, value, confirmed) values
  ('close_time', '"20:00"', true),
  ('reminder_times', '["19:30","20:00","20:15"]', true),
  ('transport_default', '300', true),
  ('transport_method', '"value"', true),
  ('market_trip_km', '12', true),
  ('market_trips_per_week', '2', true),
  ('profit_target', '30000', false),
  ('starting_float', '0', false),
  ('min_working_capital', '0', false),
  ('opening_debt', '0', false),
  ('evidence_required', 'false', false),
  ('waste_reasons', '["เสีย/เน่า","หล่น/เสียหาย","เหลือขายไม่หมด","ทดลองชิม","อื่น ๆ"]', true)
on conflict (key) do nothing;

-- variance alert used before: 100 baht (kept unconfirmed until the owner saves it)
update settings set value = '100' where key = 'cash_variance_tolerance' and value = '0' and not confirmed and updated_by is null;

-- delivery fees used before (unconfirmed until checked against the platform contract)
update channels set fee_pct = 32.1 where name = 'LINE MAN' and fee_pct = 0 and not fee_confirmed;
update channels set fee_pct = 35 where name = 'Grab' and fee_pct = 0 and not fee_confirmed;

insert into stock_items(code, name, kind, unit)
select v.code, v.name, 'raw', 'กิโลกรัม'
from (values ('RM_WM', 'แตงโมสด'), ('RM_PP', 'มะละกอสด'), ('RM_PN', 'สับปะรดสด'), ('RM_CT', 'แคนตาลูปสด'), ('RM_GV', 'ฝรั่งสด'),
             ('RM_DF', 'แก้วมังกรสด'), ('RM_RS', 'ไส้กรอกแดง'), ('RM_PM', 'ลูกชิ้นหมู'), ('RM_CS', 'ไส้กรอกหนังกรอบ'), ('RM_FT', 'ลูกชิ้นเต้าหู้ปลา')) v(code, name)
where not exists (select 1 from stock_items s where s.code = v.code);

insert into products(sku, name, category, unit, price, delivery_price, delivery_enabled, emoji, sort_order)
select v.sku, v.name, v.cat, v.unit, v.price, v.dprice, v.den, v.emoji, v.sort
from (values
  ('FR_WM', 'แตงโม', 'ผลไม้', 'กล่อง', 35, null::numeric, false, '🍉', 1),
  ('FR_PP', 'มะละกอ', 'ผลไม้', 'กล่อง', 35, null, false, '🧡', 2),
  ('FR_PN', 'สับปะรด', 'ผลไม้', 'กล่อง', 35, null, false, '🍍', 3),
  ('FR_CT', 'แคนตาลูป', 'ผลไม้', 'กล่อง', 35, null, false, '🍈', 4),
  ('FR_GV', 'ฝรั่ง', 'ผลไม้', 'กล่อง', 35, null, false, '🍐', 5),
  ('FR_DF', 'แก้วมังกร', 'ผลไม้', 'กล่อง', 35, null, false, '🐉', 6),
  ('FD_RS', 'ไส้กรอกแดงทอด', 'ของทอด', 'ไม้', 10, 18, true, '🌭', 11),
  ('FD_PM', 'ลูกชิ้นหมูทอด', 'ของทอด', 'ไม้', 10, 18, true, '🍢', 12),
  ('FD_CS', 'ไส้กรอกหนังกรอบทอด', 'ของทอด', 'ไม้', 10, 18, true, '🥓', 13),
  ('FD_FT', 'ลูกชิ้นเต้าหู้ปลาทอด', 'ของทอด', 'ไม้', 10, 18, true, '🍡', 14)) v(sku, name, cat, unit, price, dprice, den, emoji, sort)
where not exists (select 1 from products p where p.sku = v.sku);

insert into product_prices(product_id, price)
select p.id, p.price from products p where p.sku in ('FR_WM','FR_PP','FR_PN','FR_CT','FR_GV','FR_DF','FD_RS','FD_PM','FD_CS','FD_FT')
  and not exists (select 1 from product_prices x where x.product_id = p.id);

-- main raw material per product (a hint for the owner; usage per unit is not known yet, so no recipe is created)
update products p set main_stock_item_id = s.id
  from stock_items s where p.main_stock_item_id is null and p.sku like 'F%' and s.code = 'RM_' || substr(p.sku, 4);

insert into promotions(name, scope, product_ids, rule, value, min_qty, buy_qty, bundle_price, storefront_only)
select 'ผลไม้ 3 กล่อง 100', 'products', array(select id from products where sku in ('FR_WM','FR_PP','FR_PN','FR_CT','FR_GV','FR_DF')),
       'bundle', 0, 1, 3, 100, true
where not exists (select 1 from promotions where name = 'ผลไม้ 3 กล่อง 100')
  and exists (select 1 from products where sku = 'FR_WM');

insert into fixed_expenses(name, category_id, amount, due_day, start_month, confirmed, note)
select 'ค่าเช่าร้าน', (select id from expense_categories where name = 'ค่าเช่า'), 6000, 1, date_trunc('month', rsa_today())::date, false,
       'ข้อมูลก่อนหน้า ตรวจทานวันรับร้าน (ยังไม่สร้างบิลจนกว่าจะยืนยัน)'
where not exists (select 1 from fixed_expenses where name = 'ค่าเช่าร้าน');

insert into capital_entries(kind, party, amount, occurred_at, category, counts_as_investment, in_payback, refundable_amount, data_status, note)
select 'investment_item', 'เจ้าของ', v.amt, now(), v.cat, true, true, v.refund, 'ต้องตรวจทาน', v.note
from (values ('ค่าเซ้ง / Key money', 50000::numeric, 0::numeric, 'ข้อมูลก่อนหน้า ตรวจทานวันเซ็นสัญญา'),
             ('เงินประกัน / Deposit', 11600, 5800, 'เคยคุยว่าได้คืน 5,800'),
             ('ค่าจอง / Booking fee', 7000, 0, 'ข้อมูลก่อนหน้า')) v(cat, amt, refund, note)
where not exists (select 1 from capital_entries where kind = 'investment_item');

-- wages: advances are not costs by themselves (they are deducted from the weekly wage, which is the cost)
insert into expense_categories(name, tax_category, staff_allowed) values ('เบิกค่าแรงล่วงหน้า', 'เงินเบิกล่วงหน้าพนักงาน', false) on conflict (name) do nothing;
insert into settings(key, value, confirmed) values ('payroll_week_start', '1', false) on conflict (key) do nothing;
-- v7: evening markdown start time and shop holidays (empty until the owner sets them)
insert into settings(key, value, confirmed) values ('markdown_from', '""', false), ('closed_weekdays', '[]', false), ('closed_dates', '[]', true)
on conflict (key) do nothing;
