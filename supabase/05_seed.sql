-- RSA - POS Assistant : starting master data (no demo transactions, every money value starts at 0 and unconfirmed)

insert into settings(key, value, confirmed) values
  ('shop_name', '""', false),
  ('close_due_time', '"21:00"', true),
  ('cash_variance_tolerance', '0', false),
  ('waste_evidence_required', 'false', false),
  ('vat_registered', 'false', false),
  ('tax_id', '""', false)
on conflict (key) do nothing;

insert into units(name) values ('ชิ้น'), ('กล่อง'), ('แก้ว'), ('ถุง'), ('กิโลกรัม'), ('กรัม'), ('ลิตร'), ('มิลลิลิตร'), ('ลูก'), ('แพ็ก')
on conflict (name) do nothing;

insert into payment_accounts(name, kind, is_drawer, opening_balance, opening_confirmed)
select 'เงินสดหน้าร้าน', 'cash', true, 0, false
where not exists (select 1 from payment_accounts where is_drawer);

insert into payment_accounts(name, kind, is_drawer, opening_balance, opening_confirmed)
select 'บัญชีธนาคารร้าน (รับ QR/โอน)', 'bank', false, 0, false
where not exists (select 1 from payment_accounts where kind = 'bank');

insert into channels(name, kind, payment_method, account_id, fee_pct, fee_confirmed, settlement_days, sort_order)
select v.name, v.kind, v.pm, case v.pm when 'cash' then (select id from payment_accounts where is_drawer limit 1)
                                       when 'qr' then (select id from payment_accounts where kind = 'bank' order by created_at limit 1) end,
       0, v.kind = 'storefront', v.days, v.sort
from (values ('หน้าร้าน เงินสด', 'storefront', 'cash', 0, 1),
             ('หน้าร้าน QR', 'storefront', 'qr', 0, 2),
             ('LINE MAN', 'delivery', 'platform', 7, 3),
             ('Grab', 'delivery', 'platform', 7, 4)) v(name, kind, pm, days, sort)
where not exists (select 1 from channels);

-- first install only: the owner may rename categories later, and a re-run must not bring the old names back
insert into expense_categories(name, tax_category, staff_allowed)
select v.name, v.tax, v.staff from (values
  ('วัตถุดิบ / ของเข้าร้าน', 'ต้นทุนสินค้า', true),
  ('บรรจุภัณฑ์', 'ต้นทุนสินค้า', true),
  ('วัสดุสิ้นเปลือง', 'ค่าใช้จ่ายในการขาย', true),
  ('ค่าขนส่ง', 'ค่าใช้จ่ายในการขาย', true),
  ('ค่าเช่า', 'ค่าเช่า', false),
  ('ค่าน้ำ ค่าไฟ', 'ค่าสาธารณูปโภค', false),
  ('ค่าจ้างพนักงาน', 'เงินเดือนและค่าจ้าง', false),
  ('ค่าธรรมเนียม', 'ค่าธรรมเนียม', false),
  ('ซ่อมแซม / อุปกรณ์', 'ค่าซ่อมแซม', false),
  ('อื่น ๆ', null, true)) v(name, tax, staff)
where not exists (select 1 from expense_categories)
on conflict (name) do nothing;
