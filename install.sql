-- RSA - POS Assistant : full install. Paste this whole file into Supabase > SQL Editor and press Run.
-- Safe to run again after an update: tables are created only if missing, functions are replaced.


-- ==================== 01_schema.sql
-- RSA - POS Assistant : database schema (Supabase / PostgreSQL 15+)
-- Run files in order: 01_schema.sql, 02_functions.sql, 03_seed.sql
-- All access goes through SECURITY DEFINER functions in 02_functions.sql.
-- Tables have RLS enabled with no policies, so the anon key cannot read or write them directly.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- users & access
create table if not exists app_users (
  id            uuid primary key default gen_random_uuid(),
  username      text not null unique check (username ~ '^[a-z0-9._-]{2,32}$'),
  display_name  text not null,
  role          text not null check (role in ('staff','owner','admin')),
  perms         text[] not null default '{}',
  pin_hash      text not null,
  active        boolean not null default true,
  failed_attempts int not null default 0,
  locked_until  timestamptz,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now()
);

create table if not exists app_sessions (
  token_hash  text primary key,
  user_id     uuid not null references app_users(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  revoked_at  timestamptz
);
create index if not exists app_sessions_user on app_sessions(user_id);

create table if not exists settings (
  key        text primary key,
  value      jsonb not null,
  confirmed  boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references app_users(id)
);

-- ---------------------------------------------------------------- master data (never hard-deleted)
create table if not exists units (
  id     uuid primary key default gen_random_uuid(),
  name   text not null unique,
  active boolean not null default true
);

create table if not exists payment_accounts (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  kind             text not null check (kind in ('cash','bank','ewallet')),
  is_drawer        boolean not null default false,
  bank_detail      text,
  opening_balance  numeric(14,2) not null default 0,
  opening_confirmed boolean not null default false,
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);

create table if not exists channels (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  kind            text not null check (kind in ('storefront','delivery')),
  payment_method  text not null check (payment_method in ('cash','qr','transfer','card','platform')),
  account_id      uuid references payment_accounts(id),
  fee_pct         numeric(6,3) not null default 0,
  fee_confirmed   boolean not null default false,
  settlement_days int not null default 0,
  sort_order      int not null default 0,
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);

create table if not exists stock_items (
  id          uuid primary key default gen_random_uuid(),
  code        text,
  name        text not null,
  kind        text not null default 'raw' check (kind in ('raw','packaging','goods')),
  unit        text not null,
  min_qty     numeric(14,3) not null default 0,
  reorder_qty numeric(14,3) not null default 0,
  avg_cost    numeric(14,4) not null default 0,
  default_supplier_id uuid,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists products (
  id          uuid primary key default gen_random_uuid(),
  sku         text,
  name        text not null,
  category    text,
  unit        text not null default 'ชิ้น',
  price       numeric(12,2) not null default 0,
  est_cost    numeric(12,4),          -- manual cost estimate when no recipe is defined
  sort_order  int not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists products_sku_uq on products(sku) where sku is not null and sku <> '';

create table if not exists product_prices (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references products(id),
  price       numeric(12,2) not null,
  effective_at timestamptz not null default now(),
  changed_by  uuid references app_users(id)
);

-- Recipe / usage mapping: how much stock one unit of product consumes. Only Owner defines it.
create table if not exists recipe_lines (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references products(id),
  stock_item_id uuid not null references stock_items(id),
  qty           numeric(14,4) not null check (qty > 0),
  unique (product_id, stock_item_id)
);

create table if not exists promotions (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  scope       text not null default 'products' check (scope in ('all','products')),
  product_ids uuid[] not null default '{}',
  channel_ids uuid[] not null default '{}',   -- empty = every channel
  rule        text not null check (rule in ('percent','amount_each')),
  value       numeric(12,2) not null check (value >= 0),
  min_qty     numeric(12,3) not null default 1,
  starts_at   timestamptz,
  ends_at     timestamptz,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists suppliers (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  contact_name     text,
  phone            text,
  line_id          text,
  supplies         text,
  order_days       text,
  lead_time        text,
  delivery_schedule text,
  min_order        text,
  delivery_fee     text,
  payment_method   text,
  credit_terms     text,
  bank_detail      text,
  can_issue_receipt boolean not null default false,
  can_issue_tax_invoice boolean not null default false,
  return_terms     text,
  priority         text not null default 'primary' check (priority in ('primary','backup')),
  note             text,
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);

create table if not exists expense_categories (
  id        uuid primary key default gen_random_uuid(),
  name      text not null unique,
  tax_category text,
  staff_allowed boolean not null default false,
  active    boolean not null default true
);

-- ---------------------------------------------------------------- attachments (evidence)
create table if not exists attachments (
  id          uuid primary key default gen_random_uuid(),
  filename    text not null,
  mime        text not null,
  size_bytes  int not null,
  data_b64    text not null,
  doc_kind    text,      -- receipt, tax_invoice, slip, bill, substitute, photo, settlement_report
  linked_type text,
  linked_id   uuid,
  created_at  timestamptz not null default now(),
  created_by  uuid references app_users(id)
);
create index if not exists attachments_link on attachments(linked_type, linked_id);

-- ---------------------------------------------------------------- orders
create table if not exists order_counters (
  biz_date date primary key,
  n        int not null default 0
);

create table if not exists orders (
  id             uuid primary key default gen_random_uuid(),
  order_no       text not null unique,
  client_ref     text unique,               -- idempotency key from the device
  biz_date       date not null,
  created_at     timestamptz not null default now(),
  channel_id     uuid not null references channels(id),
  channel_name   text not null,             -- snapshot
  channel_kind   text not null,
  payment_method text not null,
  account_id     uuid references payment_accounts(id),
  subtotal       numeric(12,2) not null,
  discount       numeric(12,2) not null default 0,
  total          numeric(12,2) not null,
  refunded       numeric(12,2) not null default 0,
  fee_pct        numeric(6,3) not null default 0,   -- snapshot for delivery
  est_fee        numeric(12,2) not null default 0,
  cost_total     numeric(14,2) not null default 0,
  cost_complete  boolean not null default true,
  status         text not null default 'paid' check (status in ('paid','cancelled','refunded','partial_refund')),
  settlement_id  uuid,
  note           text,
  created_by     uuid not null references app_users(id),
  cancelled_at   timestamptz,
  cancelled_by   uuid references app_users(id),
  cancel_reason  text
);
create index if not exists orders_date on orders(biz_date);

create table if not exists order_items (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references orders(id),
  product_id    uuid not null references products(id),
  product_name  text not null,
  sku           text,
  unit          text,
  qty           numeric(12,3) not null check (qty > 0),
  unit_price    numeric(12,2) not null,
  discount      numeric(12,2) not null default 0,
  promo_id      uuid,
  promo_snapshot jsonb,
  line_total    numeric(12,2) not null,
  unit_cost     numeric(14,4),
  cost_source   text not null default 'none' check (cost_source in ('recipe','manual','none')),
  stock_linked  boolean not null default false
);
create index if not exists order_items_order on order_items(order_id);

create table if not exists order_events (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references orders(id),
  kind        text not null check (kind in ('cancel','refund')),
  amount      numeric(12,2) not null,
  reason      text not null,
  account_id  uuid references payment_accounts(id),
  created_at  timestamptz not null default now(),
  created_by  uuid not null references app_users(id)
);

-- ---------------------------------------------------------------- stock
create table if not exists stock_receipts (
  id          uuid primary key default gen_random_uuid(),
  receipt_no  text not null unique,
  supplier_id uuid references suppliers(id),
  supplier_name text,
  ref_no      text,
  received_at timestamptz not null default now(),
  total_cost  numeric(14,2) not null default 0,
  expense_id  uuid,
  status      text not null default 'received' check (status in ('received','cancelled')),
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid not null references app_users(id),
  cancelled_at timestamptz,
  cancelled_by uuid references app_users(id),
  cancel_reason text
);

create table if not exists stock_receipt_lines (
  id            uuid primary key default gen_random_uuid(),
  receipt_id    uuid not null references stock_receipts(id),
  stock_item_id uuid not null references stock_items(id),
  item_name     text not null,
  unit          text not null,
  qty           numeric(14,3) not null check (qty > 0),
  unit_cost     numeric(14,4) not null default 0,
  line_total    numeric(14,2) not null default 0
);

create table if not exists waste_records (
  id            uuid primary key default gen_random_uuid(),
  stock_item_id uuid not null references stock_items(id),
  item_name     text not null,
  unit          text not null,
  qty           numeric(14,3) not null check (qty > 0),
  reason        text not null,
  unit_cost     numeric(14,4) not null default 0,
  occurred_at   timestamptz not null default now(),
  biz_date      date not null,
  status        text not null default 'recorded' check (status in ('recorded','cancelled')),
  created_by    uuid not null references app_users(id),
  cancelled_by  uuid references app_users(id),
  cancel_reason text
);

create table if not exists stocktakes (
  id          uuid primary key default gen_random_uuid(),
  context     text not null check (context in ('close','stocktake','opening')),
  biz_date    date not null,
  close_id    uuid,
  status      text not null default 'pending' check (status in ('pending','approved','rejected')),
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid not null references app_users(id),
  approved_at timestamptz,
  approved_by uuid references app_users(id)
);

create table if not exists stocktake_lines (
  id            uuid primary key default gen_random_uuid(),
  stocktake_id  uuid not null references stocktakes(id),
  stock_item_id uuid not null references stock_items(id),
  item_name     text not null,
  system_qty    numeric(14,3) not null,
  counted_qty   numeric(14,3) not null,
  variance      numeric(14,3) not null,
  unit_cost     numeric(14,4),        -- opening stock may set cost
  note          text
);

create table if not exists stock_ledger (
  id            uuid primary key default gen_random_uuid(),
  stock_item_id uuid not null references stock_items(id),
  occurred_at   timestamptz not null default now(),
  qty           numeric(14,3) not null,
  kind          text not null check (kind in ('sale','sale_reversal','receipt','receipt_reversal','waste','waste_reversal','count_adjust')),
  source_type   text not null,
  source_id     uuid not null,
  unit_cost     numeric(14,4),
  created_by    uuid references app_users(id)
);
create index if not exists stock_ledger_item on stock_ledger(stock_item_id);
create index if not exists stock_ledger_source on stock_ledger(source_type, source_id);

-- ---------------------------------------------------------------- expenses
create table if not exists fixed_expenses (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  category_id uuid references expense_categories(id),
  payee       text,
  amount      numeric(12,2) not null check (amount >= 0),
  due_day     int not null check (due_day between 1 and 31),
  account_id  uuid references payment_accounts(id),
  start_month date not null,
  end_month   date,
  auto_approve boolean not null default false,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists expense_counters (
  yymm text primary key,
  n    int not null default 0
);

create table if not exists expenses (
  id            uuid primary key default gen_random_uuid(),
  expense_no    text not null unique,
  occurred_at   timestamptz not null,
  due_date      date,
  category_id   uuid references expense_categories(id),
  category_name text,
  tax_category  text,
  payee         text,
  supplier_id   uuid references suppliers(id),
  description   text not null,
  amount        numeric(12,2) not null check (amount > 0),
  status        text not null check (status in ('รออนุมัติ','รอทำจ่าย','จ่ายแล้ว','ยกเลิก')),
  pay_account_id uuid references payment_accounts(id),
  paid_by_employee uuid references app_users(id),   -- employee paid with own money -> reimbursement
  reimbursed    boolean not null default false,
  doc_type      text,          -- receipt, tax_invoice, bill, slip, substitute, none
  doc_no        text,
  ocr_snapshot  jsonb,
  fixed_expense_id uuid references fixed_expenses(id),
  period        text,          -- YYYY-MM for fixed expense items
  receipt_id    uuid,          -- linked stock receipt
  reviewed      boolean not null default false,   -- owner checked a spend that was already paid
  created_at    timestamptz not null default now(),
  created_by    uuid not null references app_users(id),
  approved_at   timestamptz,
  approved_by   uuid references app_users(id),
  paid_at       timestamptz,
  paid_by       uuid references app_users(id),
  cancelled_at  timestamptz,
  cancelled_by  uuid references app_users(id),
  cancel_reason text,
  unique (fixed_expense_id, period)
);
create index if not exists expenses_status on expenses(status);

-- ---------------------------------------------------------------- money ledger
create table if not exists money_ledger (
  id           uuid primary key default gen_random_uuid(),
  account_id   uuid not null references payment_accounts(id),
  occurred_at  timestamptz not null default now(),
  biz_date     date not null,
  direction    text not null check (direction in ('in','out')),
  amount       numeric(14,2) not null check (amount >= 0),
  source_type  text not null check (source_type in ('order','order_refund','expense','expense_reversal','settlement','transfer','capital','profit','adjustment')),
  source_id    uuid not null,
  note         text,
  reconciled_at timestamptz,
  reconciled_by uuid references app_users(id),
  bank_ref     text,
  created_at   timestamptz not null default now(),
  created_by   uuid references app_users(id)
);
create index if not exists money_ledger_account on money_ledger(account_id, biz_date);
create index if not exists money_ledger_source on money_ledger(source_type, source_id);

create table if not exists transfers (
  id           uuid primary key default gen_random_uuid(),
  from_account uuid not null references payment_accounts(id),
  to_account   uuid not null references payment_accounts(id),
  amount       numeric(14,2) not null check (amount > 0),
  occurred_at  timestamptz not null default now(),
  reason       text not null,
  status       text not null default 'done' check (status in ('done','cancelled')),
  created_by   uuid not null references app_users(id),
  cancelled_by uuid references app_users(id),
  cancel_reason text
);

create table if not exists delivery_settlements (
  id           uuid primary key default gen_random_uuid(),
  channel_id   uuid not null references channels(id),
  channel_name text not null,
  period_from  date not null,
  period_to    date not null,
  system_gross numeric(14,2) not null,
  reported_gross numeric(14,2) not null,
  fee          numeric(14,2) not null default 0,
  net          numeric(14,2) not null,
  account_id   uuid not null references payment_accounts(id),
  deposited_at timestamptz not null,
  ref_no       text,
  note         text,
  status       text not null default 'done' check (status in ('done','cancelled')),
  created_at   timestamptz not null default now(),
  created_by   uuid not null references app_users(id),
  cancelled_by uuid references app_users(id),
  cancel_reason text
);

create table if not exists capital_entries (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('capital_in','loan_in','capital_return','loan_repayment')),
  party       text not null,
  amount      numeric(14,2) not null check (amount > 0),
  occurred_at timestamptz not null,
  account_id  uuid not null references payment_accounts(id),
  profit_declaration_id uuid,
  note        text,
  status      text not null default 'done' check (status in ('done','cancelled')),
  created_at  timestamptz not null default now(),
  created_by  uuid not null references app_users(id),
  cancelled_by uuid references app_users(id),
  cancel_reason text
);

create table if not exists profit_declarations (
  id          uuid primary key default gen_random_uuid(),
  amount      numeric(14,2) not null check (amount > 0),
  declared_at timestamptz not null,
  recipient   text not null,
  purpose     text not null check (purpose in ('owner_draw','capital_return','loan_repayment')),
  account_id  uuid not null references payment_accounts(id),
  basis_available numeric(14,2),
  note        text,
  status      text not null default 'done' check (status in ('done','cancelled')),
  created_at  timestamptz not null default now(),
  created_by  uuid not null references app_users(id),
  cancelled_by uuid references app_users(id),
  cancel_reason text
);

-- ---------------------------------------------------------------- daily close
create table if not exists daily_closes (
  id             uuid primary key default gen_random_uuid(),
  biz_date       date not null unique,
  submitted_at   timestamptz not null default now(),
  submitted_by   uuid not null references app_users(id),
  coworker_ids   uuid[] not null default '{}',
  summary        jsonb not null,       -- system-computed snapshot at submit time
  starting_cash  numeric(14,2) not null,
  cash_sales     numeric(14,2) not null,
  cash_refunds   numeric(14,2) not null,
  cash_expenses  numeric(14,2) not null,
  cash_transfers_out numeric(14,2) not null,
  expected_cash  numeric(14,2) not null,
  counted_cash   numeric(14,2) not null,
  variance       numeric(14,2) not null,
  variance_reason text,
  stock_note     text,
  note           text,
  adjustments    jsonb not null default '[]',   -- [{field, original, corrected, reason}]
  stocktake_id   uuid,
  revision       int not null default 1,
  reviewed_at    timestamptz,
  reviewed_by    uuid references app_users(id)
);

create table if not exists daily_close_revisions (
  id          uuid primary key default gen_random_uuid(),
  close_id    uuid not null references daily_closes(id),
  revision    int not null,
  snapshot    jsonb not null,
  reason      text not null,
  created_at  timestamptz not null default now(),
  created_by  uuid not null references app_users(id)
);

-- ---------------------------------------------------------------- audit
create table if not exists audit_log (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  user_id     uuid,
  user_name   text,
  action      text not null,
  entity      text,
  entity_id   text,
  before      jsonb,
  after       jsonb,
  meta        jsonb
);
create index if not exists audit_at on audit_log(at desc);

-- ---------------------------------------------------------------- integrity guards
create or replace function rsa_block_delete() returns trigger language plpgsql as $$
begin
  raise exception 'ลบข้อมูลในตาราง % ไม่ได้ ให้ใช้การยกเลิกหรือปิดใช้งานแทน', tg_table_name;
end $$;

create or replace function rsa_block_update() returns trigger language plpgsql as $$
begin
  raise exception 'แก้ไขข้อมูลในตาราง % ไม่ได้', tg_table_name;
end $$;

do $$
declare t text;
begin
  foreach t in array array['app_users','units','payment_accounts','channels','stock_items','products','product_prices',
    'promotions','suppliers','expense_categories','attachments','orders','order_items','order_events','stock_receipts',
    'stock_receipt_lines','waste_records','stocktakes','stocktake_lines','stock_ledger','fixed_expenses','expenses',
    'money_ledger','transfers','delivery_settlements','capital_entries','profit_declarations','daily_closes',
    'daily_close_revisions','audit_log']
  loop
    execute format('drop trigger if exists %I on %I', t || '_no_delete', t);
    execute format('create trigger %I before delete on %I for each statement execute function rsa_block_delete()', t || '_no_delete', t);
  end loop;
  foreach t in array array['audit_log','stock_ledger','order_events','product_prices','daily_close_revisions']
  loop
    execute format('drop trigger if exists %I on %I', t || '_no_update', t);
    execute format('create trigger %I before update on %I for each statement execute function rsa_block_update()', t || '_no_update', t);
  end loop;
end $$;

-- Lock every table away from client roles. Only the RPC functions touch them.
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', r.tablename);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on public.%I from anon', r.tablename);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('revoke all on public.%I from authenticated', r.tablename);
    end if;
  end loop;
end $$;

-- ==================== 02_core.sql
-- RSA - POS Assistant : helpers, authentication, sales, stock
set check_function_bodies = off;

-- ---------------------------------------------------------------- helpers
create or replace function rsa_today() returns date language sql stable as $$
  select (now() at time zone 'Asia/Bangkok')::date
$$;

create or replace function rsa_bdate(ts timestamptz) returns date language sql immutable as $$
  select (ts at time zone 'Asia/Bangkok')::date
$$;

create or replace function rsa_err(msg text) returns void language plpgsql as $$
begin
  raise exception using message = msg, errcode = 'P0001';
end $$;

create or replace function rsa_num(p jsonb, k text, dflt numeric default null) returns numeric language sql immutable as $$
  select coalesce(nullif(p->>k, '')::numeric, dflt)
$$;

create or replace function rsa_uuid(p jsonb, k text) returns uuid language sql immutable as $$
  select nullif(p->>k, '')::uuid
$$;

create or replace function rsa_ts(p jsonb, k text) returns timestamptz language sql stable as $$
  select coalesce(nullif(p->>k, '')::timestamptz, now())
$$;

create or replace function rsa_date(p jsonb, k text, dflt date default null) returns date language sql stable as $$
  select coalesce(nullif(p->>k, '')::date, dflt, rsa_today())
$$;

create or replace function rsa_all_perms() returns text[] language sql immutable as $$
  select array[
    'sales.view','sales.view_all','sales.add','sales.cancel',
    'closing.add','closing.view_all','closing.edit',
    'stock.view','stock.receive','stock.count','stock.approve','stock.cancel','waste.add',
    'expense.add','expense.view_all','expense.approve','expense.pay','expense.cancel',
    'cashflow.view','cashflow.manage','report.view',
    'master.manage','settings.manage','export.run','audit.view','admin.users'
  ]
$$;

create or replace function rsa_role_perms(p_role text) returns text[] language sql immutable as $$
  select case p_role
    when 'staff' then array['sales.view','sales.add','closing.add','stock.view','stock.receive','stock.count','waste.add','expense.add']
    when 'owner' then array_remove(rsa_all_perms(), 'admin.users')
    when 'admin' then array['admin.users','audit.view']
    else array[]::text[] end
$$;

create or replace function rsa_has(u app_users, perm text) returns boolean language sql stable as $$
  select perm = any(u.perms)
$$;

create or replace function rsa_need(u app_users, perm text) returns void language plpgsql as $$
begin
  if not (perm = any(u.perms)) then
    perform rsa_err('คุณยังไม่มีสิทธิ์ทำรายการนี้ (' || perm || ') กรุณาติดต่อผู้ดูแลระบบ');
  end if;
end $$;

create or replace function rsa_audit(u app_users, p_action text, p_entity text, p_entity_id text,
  p_before jsonb default null, p_after jsonb default null, p_meta jsonb default null) returns void
language sql as $$
  insert into audit_log(user_id, user_name, action, entity, entity_id, before, after, meta)
  values (u.id, u.display_name, p_action, p_entity, p_entity_id, p_before, p_after, p_meta)
$$;

create or replace function rsa_drawer() returns uuid language sql stable as $$
  select id from payment_accounts where is_drawer and active order by created_at limit 1
$$;

create or replace function rsa_money(p_account uuid, p_dir text, p_amount numeric, p_src text, p_src_id uuid,
  p_note text, p_user uuid, p_at timestamptz default now()) returns void language plpgsql as $$
begin
  if p_account is null or coalesce(p_amount, 0) = 0 then return; end if;
  insert into money_ledger(account_id, occurred_at, biz_date, direction, amount, source_type, source_id, note, created_by)
  values (p_account, p_at, rsa_bdate(p_at), p_dir, abs(p_amount), p_src, p_src_id, p_note, p_user);
end $$;

create or replace function rsa_account_balance(p_account uuid, p_before date default null) returns numeric language sql stable as $$
  select coalesce((select opening_balance from payment_accounts where id = p_account), 0)
       + coalesce((select sum(case direction when 'in' then amount else -amount end) from money_ledger
                   where account_id = p_account and (p_before is null or biz_date < p_before)), 0)
$$;

create or replace function rsa_stock_qty(p_item uuid) returns numeric language sql stable as $$
  select coalesce(sum(qty), 0) from stock_ledger where stock_item_id = p_item
$$;

create or replace function rsa_link_attachments(p_ids jsonb, p_type text, p_id uuid, u app_users) returns int language plpgsql as $$
declare n int;
begin
  if p_ids is null or jsonb_typeof(p_ids) <> 'array' then return 0; end if;
  update attachments set linked_type = p_type, linked_id = p_id
   where id in (select (x)::uuid from jsonb_array_elements_text(p_ids) x)
     and linked_id is null and created_by = u.id;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function rsa_attachment_refs(p_type text, p_id uuid) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'filename', filename, 'doc_kind', doc_kind, 'mime', mime) order by created_at), '[]')
    from attachments where linked_type = p_type and linked_id = p_id
$$;

create or replace function rsa_user_json(u app_users) returns jsonb language sql stable as $$
  select jsonb_build_object('id', u.id, 'username', u.username, 'display_name', u.display_name,
    'role', u.role, 'perms', to_jsonb(u.perms), 'active', u.active)
$$;

-- ---------------------------------------------------------------- authentication (6-digit PIN)
create or replace function rsa_setup(p_username text, p_display_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v app_users;
begin
  perform pg_advisory_xact_lock(424242);
  if exists (select 1 from app_users) then
    perform rsa_err('ระบบตั้งค่าผู้ดูแลคนแรกไปแล้ว');
  end if;
  if p_pin !~ '^[0-9]{6}$' then perform rsa_err('PIN ต้องเป็นตัวเลข 6 หลัก'); end if;
  insert into app_users(username, display_name, role, perms, pin_hash)
  values (lower(trim(p_username)), trim(p_display_name), 'admin', rsa_all_perms(), crypt(p_pin, gen_salt('bf', 8)))
  returning * into v;
  perform rsa_audit(v, 'user.setup_first_admin', 'user', v.id::text, null, rsa_user_json(v));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa_status() returns jsonb
language sql security definer set search_path = public, extensions as $$
  select jsonb_build_object('needs_setup', not exists (select 1 from app_users),
    'shop_name', (select value from settings where key = 'shop_name'))
$$;

create or replace function rsa_login(p_username text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v app_users; v_token text;
begin
  select * into v from app_users where username = lower(trim(p_username));
  if not found or not v.active then
    perform rsa_err('ชื่อผู้ใช้หรือ PIN ไม่ถูกต้อง');
  end if;
  if v.locked_until is not null and v.locked_until > now() then
    perform rsa_err('ใส่ PIN ผิดหลายครั้ง กรุณารอ ' || ceil(extract(epoch from v.locked_until - now()) / 60)::int || ' นาทีแล้วลองใหม่');
  end if;
  if v.pin_hash <> crypt(coalesce(p_pin, ''), v.pin_hash) then
    update app_users set failed_attempts = failed_attempts + 1,
      locked_until = case when failed_attempts + 1 >= 5 then now() + interval '5 minutes' else null end
     where id = v.id;
    perform rsa_audit(v, 'login.failed', 'user', v.id::text);
    -- the failed-attempt counter must survive the exception, so return an error object instead of raising
    return jsonb_build_object('error', 'ชื่อผู้ใช้หรือ PIN ไม่ถูกต้อง');
  end if;
  update app_users set failed_attempts = 0, locked_until = null where id = v.id;
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into app_sessions(token_hash, user_id, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'), v.id, now() + interval '12 hours');
  delete from app_sessions where expires_at < now() - interval '7 days';
  perform rsa_audit(v, 'login', 'user', v.id::text);
  return jsonb_build_object('token', v_token, 'user', rsa_user_json(v));
end $$;

create or replace function rsa_session_user(p_token text) returns app_users
language plpgsql security definer set search_path = public, extensions as $$
declare v app_users;
begin
  select u.* into v from app_sessions s join app_users u on u.id = s.user_id
   where s.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and s.revoked_at is null and s.expires_at > now() and u.active;
  if not found then
    raise exception using message = 'กรุณาเข้าสู่ระบบอีกครั้ง', errcode = 'P0001', hint = 'auth';
  end if;
  return v;
end $$;

create or replace function rsa_logout(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  update app_sessions set revoked_at = now()
   where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') and revoked_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- bootstrap data for the app
create or replace function rsa__bootstrap(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare is_mgr boolean := rsa_has(u, 'master.manage') or rsa_has(u, 'expense.approve');
begin
  return jsonb_build_object(
    'me', rsa_user_json(u),
    'today', rsa_today(),
    'now', now(),
    'settings', (select coalesce(jsonb_object_agg(key, jsonb_build_object('value', value, 'confirmed', confirmed)), '{}') from settings),
    'channels', (select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order, c.name), '[]') from channels c where c.active),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'is_drawer', a.is_drawer) order by a.is_drawer desc, a.name), '[]')
                   from payment_accounts a where a.active),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', p2.id, 'sku', p2.sku, 'name', p2.name, 'category', p2.category,
                   'unit', p2.unit, 'price', p2.price, 'sort_order', p2.sort_order,
                   'has_recipe', exists (select 1 from recipe_lines r where r.product_id = p2.id)) order by p2.sort_order, p2.name), '[]')
                   from products p2 where p2.active),
    'promotions', (select coalesce(jsonb_agg(to_jsonb(pr)), '[]') from promotions pr
                   where pr.active and (pr.starts_at is null or pr.starts_at <= now()) and (pr.ends_at is null or pr.ends_at > now())),
    'stock_items', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'unit', s.unit, 'kind', s.kind) order by s.name), '[]')
                   from stock_items s where s.active),
    'units', (select coalesce(jsonb_agg(name order by name), '[]') from units where active),
    'categories', (select coalesce(jsonb_agg(to_jsonb(c) order by c.name), '[]') from expense_categories c
                   where c.active and (is_mgr or c.staff_allowed)),
    'suppliers', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name), '[]') from suppliers s where s.active),
    'users', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'display_name', x.display_name) order by x.display_name), '[]')
                   from app_users x where x.active)
  );
end $$;

-- ---------------------------------------------------------------- sales
create or replace function rsa_order_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(o) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = o.created_by),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) order by i.product_name), '[]') from order_items i where i.order_id = o.id),
    'events', (select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object('by', (select display_name from app_users where id = e.created_by)) order by e.created_at), '[]')
               from order_events e where e.order_id = o.id),
    'closed', exists (select 1 from daily_closes d where d.biz_date = o.biz_date))
  from orders o where o.id = p_id
$$;

create or replace function rsa__order_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_ch channels; it jsonb; v_prod products; v_promo promotions;
  v_id uuid := gen_random_uuid(); v_no text; v_n int;
  -- an order kept on the phone while offline keeps the time it was taken (accepted up to 2 days back)
  v_at timestamptz := case when nullif(p->>'offline_at', '') is not null
                             and (p->>'offline_at')::timestamptz between now() - interval '2 days' and now()
                           then (p->>'offline_at')::timestamptz else now() end;
  v_date date := rsa_bdate(v_at);
  v_qty numeric; v_gross numeric; v_pdisc numeric; v_mdisc numeric; v_line numeric;
  v_unit_cost numeric; v_src text; v_linked boolean; v_missing boolean;
  v_sub numeric := 0; v_disc numeric := 0; v_cost numeric := 0; v_cost_ok boolean := true;
  v_existing uuid; v_total numeric; v_item_id uuid; r record;
begin
  perform rsa_need(u, 'sales.add');
  if nullif(p->>'client_ref', '') is not null then
    select id into v_existing from orders where client_ref = p->>'client_ref';
    if found then return rsa_order_json(v_existing); end if;
  end if;
  select * into v_ch from channels where id = rsa_uuid(p, 'channel_id') and active;
  if not found then perform rsa_err('กรุณาเลือกช่องทางขาย'); end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then
    perform rsa_err('ยังไม่มีสินค้าในออเดอร์');
  end if;

  insert into order_counters(biz_date, n) values (v_date, 1)
  on conflict (biz_date) do update set n = order_counters.n + 1 returning n into v_n;
  v_no := 'S' || to_char(v_date, 'YYMMDD') || '-' || lpad(v_n::text, 3, '0');

  insert into orders(id, order_no, client_ref, biz_date, created_at, channel_id, channel_name, channel_kind, payment_method, account_id,
                     subtotal, total, fee_pct, note, created_by)
  values (v_id, v_no, nullif(p->>'client_ref', ''), v_date, v_at, v_ch.id, v_ch.name, v_ch.kind, v_ch.payment_method,
          case when v_ch.kind = 'storefront' then v_ch.account_id end, 0, 0, v_ch.fee_pct,
          nullif(concat_ws(' · ', nullif(p->>'note', ''), case when v_at < now() - interval '1 minute' then 'บันทึกตอนไม่มีสัญญาณ ส่งเข้าระบบ ' || to_char(now() at time zone 'Asia/Bangkok', 'DD/MM HH24:MI') end), ''), u.id);

  for it in select * from jsonb_array_elements(p->'items') loop
    select * into v_prod from products where id = rsa_uuid(it, 'product_id') and active;
    if not found then perform rsa_err('ไม่พบสินค้า หรือสินค้าถูกปิดใช้งานแล้ว'); end if;
    v_qty := rsa_num(it, 'qty', 0);
    if v_qty <= 0 then perform rsa_err('จำนวนสินค้าต้องมากกว่า 0'); end if;
    v_gross := round(v_prod.price * v_qty, 2);

    -- best active promotion for this product and channel
    v_pdisc := 0; v_promo := null;
    select * into v_promo from promotions pr
     where pr.active and (pr.starts_at is null or pr.starts_at <= now()) and (pr.ends_at is null or pr.ends_at > now())
       and (pr.scope = 'all' or v_prod.id = any(pr.product_ids))
       and (cardinality(pr.channel_ids) = 0 or v_ch.id = any(pr.channel_ids))
       and v_qty >= pr.min_qty
     order by case pr.rule when 'percent' then round(v_gross * pr.value / 100, 2) else least(pr.value, v_prod.price) * v_qty end desc
     limit 1;
    if v_promo.id is not null then
      v_pdisc := case v_promo.rule when 'percent' then round(v_gross * v_promo.value / 100, 2)
                 else round(least(v_promo.value, v_prod.price) * v_qty, 2) end;
    end if;
    v_mdisc := least(greatest(rsa_num(it, 'discount', 0), 0), v_gross - v_pdisc);
    v_line := v_gross - v_pdisc - v_mdisc;

    -- cost and stock: only when a recipe/usage mapping exists
    v_linked := exists (select 1 from recipe_lines where product_id = v_prod.id);
    if v_linked then
      select sum(rl.qty * s.avg_cost), bool_or(s.avg_cost <= 0) into v_unit_cost, v_missing
        from recipe_lines rl join stock_items s on s.id = rl.stock_item_id where rl.product_id = v_prod.id;
      v_src := 'recipe';
      if v_missing then v_cost_ok := false; end if;
    elsif v_prod.est_cost is not null then
      v_unit_cost := v_prod.est_cost; v_src := 'manual';
    else
      v_unit_cost := null; v_src := 'none'; v_cost_ok := false;
    end if;

    v_item_id := gen_random_uuid();
    insert into order_items(id, order_id, product_id, product_name, sku, unit, qty, unit_price, discount, promo_id, promo_snapshot,
                            line_total, unit_cost, cost_source, stock_linked)
    values (v_item_id, v_id, v_prod.id, v_prod.name, v_prod.sku, v_prod.unit, v_qty, v_prod.price, v_pdisc + v_mdisc, v_promo.id,
            case when v_promo.id is not null then jsonb_build_object('name', v_promo.name, 'rule', v_promo.rule, 'value', v_promo.value,
                 'promo_discount', v_pdisc) end
            || case when v_mdisc > 0 then jsonb_build_object('manual_discount', v_mdisc) else '{}'::jsonb end,
            v_line, v_unit_cost, v_src, v_linked);

    if v_linked then
      for r in select rl.stock_item_id, rl.qty, s.avg_cost from recipe_lines rl join stock_items s on s.id = rl.stock_item_id
                where rl.product_id = v_prod.id loop
        insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
        values (r.stock_item_id, v_at, -(r.qty * v_qty), 'sale', 'order_item', v_item_id, r.avg_cost, u.id);
      end loop;
    end if;

    v_sub := v_sub + v_gross;
    v_disc := v_disc + v_pdisc + v_mdisc;
    v_cost := v_cost + coalesce(v_unit_cost, 0) * v_qty;
  end loop;

  v_total := v_sub - v_disc;
  update orders set subtotal = v_sub, discount = v_disc, total = v_total, cost_total = round(v_cost, 2), cost_complete = v_cost_ok,
         est_fee = case when v_ch.kind = 'delivery' then round(v_total * v_ch.fee_pct / 100, 2) else 0 end
   where id = v_id;

  if v_ch.kind = 'storefront' then
    perform rsa_money(v_ch.account_id, 'in', v_total, 'order', v_id, v_no, u.id, v_at);
  end if;
  perform rsa_audit(u, 'order.create', 'order', v_id::text, null, jsonb_build_object('order_no', v_no, 'total', v_total, 'channel', v_ch.name));
  return rsa_order_json(v_id);
end $$;

create or replace function rsa__order_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from'); v_to date := rsa_date(p, 'to', rsa_date(p, 'from'));
begin
  perform rsa_need(u, 'sales.view');
  return (select coalesce(jsonb_agg(rsa_order_json(o.id) order by o.created_at desc), '[]') from orders o
           where o.biz_date between v_from and v_to
             and (rsa_has(u, 'sales.view_all') or o.created_by = u.id)
             and (rsa_uuid(p, 'channel_id') is null or o.channel_id = rsa_uuid(p, 'channel_id')));
end $$;

create or replace function rsa__order_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v orders; v_amt numeric; r record;
begin
  perform rsa_need(u, 'sales.cancel');
  select * into v from orders where id = rsa_uuid(p, 'order_id') for update;
  if not found then perform rsa_err('ไม่พบออเดอร์'); end if;
  if v.status = 'cancelled' then perform rsa_err('ออเดอร์นี้ยกเลิกไปแล้ว'); end if;
  if v.settlement_id is not null then perform rsa_err('ออเดอร์นี้รับเงินจากแพลตฟอร์มแล้ว ให้ใช้การคืนเงินแทน'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  v_amt := v.total - v.refunded;
  update orders set status = 'cancelled', cancelled_at = now(), cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  insert into order_events(order_id, kind, amount, reason, account_id, created_by)
  values (v.id, 'cancel', v_amt, p->>'reason', v.account_id, u.id);
  if v.channel_kind = 'storefront' then
    perform rsa_money(v.account_id, 'out', v_amt, 'order_refund', v.id, 'ยกเลิก ' || v.order_no, u.id);
  end if;
  for r in select sl.* from stock_ledger sl join order_items i on i.id = sl.source_id
            where sl.source_type = 'order_item' and sl.kind = 'sale' and i.order_id = v.id loop
    insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
    values (r.stock_item_id, -r.qty, 'sale_reversal', 'order_item', r.source_id, r.unit_cost, u.id);
  end loop;
  perform rsa_audit(u, 'order.cancel', 'order', v.id::text, jsonb_build_object('status', v.status, 'total', v.total),
                    jsonb_build_object('status', 'cancelled', 'amount', v_amt), jsonb_build_object('reason', p->>'reason', 'order_no', v.order_no,
                    'after_close', exists (select 1 from daily_closes where biz_date = v.biz_date)));
  return rsa_order_json(v.id);
end $$;

create or replace function rsa__order_refund(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v orders; v_amt numeric := rsa_num(p, 'amount', 0); v_acc uuid;
begin
  perform rsa_need(u, 'sales.cancel');
  select * into v from orders where id = rsa_uuid(p, 'order_id') for update;
  if not found then perform rsa_err('ไม่พบออเดอร์'); end if;
  if v.status = 'cancelled' then perform rsa_err('ออเดอร์นี้ยกเลิกไปแล้ว'); end if;
  if v_amt <= 0 or v_amt > v.total - v.refunded then perform rsa_err('ยอดคืนเงินต้องมากกว่า 0 และไม่เกินยอดที่เหลือ ' || (v.total - v.refunded)); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการคืนเงิน'); end if;
  v_acc := coalesce(rsa_uuid(p, 'account_id'), v.account_id);
  update orders set refunded = refunded + v_amt,
         status = case when refunded + v_amt >= total then 'refunded' else 'partial_refund' end where id = v.id;
  insert into order_events(order_id, kind, amount, reason, account_id, created_by) values (v.id, 'refund', v_amt, p->>'reason', v_acc, u.id);
  if v.channel_kind = 'storefront' or rsa_uuid(p, 'account_id') is not null then
    perform rsa_money(v_acc, 'out', v_amt, 'order_refund', v.id, 'คืนเงิน ' || v.order_no, u.id);
  end if;
  perform rsa_audit(u, 'order.refund', 'order', v.id::text, jsonb_build_object('refunded', v.refunded),
                    jsonb_build_object('refunded', v.refunded + v_amt), jsonb_build_object('reason', p->>'reason', 'amount', v_amt, 'order_no', v.order_no));
  return rsa_order_json(v.id);
end $$;

-- ---------------------------------------------------------------- stock receiving
create or replace function rsa_next_no(p_prefix text) returns text language plpgsql as $$
declare v_key text := p_prefix || to_char(rsa_today(), 'YYMM'); v_n int;
begin
  insert into expense_counters(yymm, n) values (v_key, 1)
  on conflict (yymm) do update set n = expense_counters.n + 1 returning n into v_n;
  return p_prefix || to_char(rsa_today(), 'YYMM') || '-' || lpad(v_n::text, 4, '0');
end $$;

create or replace function rsa_expense_insert(u app_users, p jsonb, p_receipt uuid default null) returns uuid language plpgsql as $$
-- p: occurred_at, category_id, payee, supplier_id, description, amount, pay_mode (drawer|account|later|employee),
--    account_id, employee_id, doc_type, doc_no, ocr_snapshot, attachment_ids
declare
  v_id uuid := gen_random_uuid(); v_cat expense_categories; v_mode text := coalesce(p->>'pay_mode', 'later');
  v_status text; v_acc uuid; v_emp uuid; v_amt numeric := rsa_num(p, 'amount', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
  v_is_mgr boolean := rsa_has(u, 'expense.approve');
begin
  perform rsa_need(u, 'expense.add');
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if coalesce(trim(p->>'description'), '') = '' then perform rsa_err('กรุณาระบุรายละเอียดค่าใช้จ่าย'); end if;
  select * into v_cat from expense_categories where id = rsa_uuid(p, 'category_id') and active;
  if not found then perform rsa_err('กรุณาเลือกหมวดค่าใช้จ่าย'); end if;
  if not v_is_mgr and not v_cat.staff_allowed then perform rsa_err('หมวด "' || v_cat.name || '" ต้องให้เจ้าของร้านบันทึก'); end if;

  if v_mode = 'drawer' then
    v_acc := rsa_drawer(); v_status := 'จ่ายแล้ว';
    if v_acc is null then perform rsa_err('ยังไม่ได้ตั้งบัญชีลิ้นชักเงินสด'); end if;
  elsif v_mode = 'account' then
    perform rsa_need(u, 'expense.pay');
    v_acc := rsa_uuid(p, 'account_id'); v_status := 'จ่ายแล้ว';
    if v_acc is null then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
  elsif v_mode = 'employee' then
    v_emp := coalesce(rsa_uuid(p, 'employee_id'), u.id); v_status := 'รออนุมัติ';
  elsif v_mode = 'later' then
    v_status := case when v_is_mgr and coalesce((p->>'approve')::boolean, false) then 'รอทำจ่าย' else 'รออนุมัติ' end;
  else
    perform rsa_err('รูปแบบการจ่ายเงินไม่ถูกต้อง');
  end if;

  insert into expenses(id, expense_no, occurred_at, due_date, category_id, category_name, tax_category, payee, supplier_id, description, amount,
    status, pay_account_id, paid_by_employee, doc_type, doc_no, ocr_snapshot, receipt_id, reviewed, created_by,
    approved_at, approved_by, paid_at, paid_by)
  values (v_id, rsa_next_no('E'), v_at, nullif(p->>'due_date', '')::date, v_cat.id, v_cat.name, v_cat.tax_category, nullif(p->>'payee', ''),
    rsa_uuid(p, 'supplier_id'), p->>'description', v_amt, v_status, v_acc, v_emp, nullif(p->>'doc_type', ''), nullif(p->>'doc_no', ''),
    case when jsonb_typeof(p->'ocr_snapshot') = 'object' then p->'ocr_snapshot' end, p_receipt,
    (v_status = 'จ่ายแล้ว' and v_is_mgr),
    u.id,
    case when v_status in ('รอทำจ่าย') or (v_status = 'จ่ายแล้ว' and v_is_mgr) then now() end,
    case when v_status in ('รอทำจ่าย') or (v_status = 'จ่ายแล้ว' and v_is_mgr) then u.id end,
    case when v_status = 'จ่ายแล้ว' then v_at end,
    case when v_status = 'จ่ายแล้ว' then u.id end);

  if v_status = 'จ่ายแล้ว' then
    perform rsa_money(v_acc, 'out', v_amt, 'expense', v_id, p->>'description', u.id, v_at);
  end if;
  perform rsa_link_attachments(p->'attachment_ids', 'expense', v_id, u);
  perform rsa_audit(u, 'expense.create', 'expense', v_id::text, null,
    jsonb_build_object('amount', v_amt, 'status', v_status, 'pay_mode', v_mode, 'category', v_cat.name));
  return v_id;
end $$;

create or replace function rsa_receipt_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(r) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = r.created_by),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l)), '[]') from stock_receipt_lines l where l.receipt_id = r.id),
    'attachments', rsa_attachment_refs('receipt', r.id),
    'expense', (select jsonb_build_object('id', e.id, 'expense_no', e.expense_no, 'status', e.status, 'amount', e.amount) from expenses e where e.id = r.expense_id))
  from stock_receipts r where r.id = p_id
$$;

create or replace function rsa__receipt_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_id uuid := gen_random_uuid(); ln jsonb; v_item stock_items; v_qty numeric; v_cost numeric; v_total numeric := 0;
  v_cur numeric; v_sup suppliers; v_exp uuid; v_at timestamptz := rsa_ts(p, 'received_at');
begin
  perform rsa_need(u, 'stock.receive');
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then perform rsa_err('ใส่รายการรับของอย่างน้อย 1 รายการ'); end if;
  select * into v_sup from suppliers where id = rsa_uuid(p, 'supplier_id');
  insert into stock_receipts(id, receipt_no, supplier_id, supplier_name, ref_no, received_at, note, created_by)
  values (v_id, rsa_next_no('R'), v_sup.id, coalesce(v_sup.name, nullif(p->>'supplier_name', '')), nullif(p->>'ref_no', ''), v_at, nullif(p->>'note', ''), u.id);
  for ln in select * from jsonb_array_elements(p->'lines') loop
    select * into v_item from stock_items where id = rsa_uuid(ln, 'stock_item_id') and active for update;
    if not found then perform rsa_err('ไม่พบรายการสต็อก'); end if;
    v_qty := rsa_num(ln, 'qty', 0); v_cost := rsa_num(ln, 'unit_cost', 0);
    if v_qty <= 0 then perform rsa_err('จำนวนรับเข้าของ "' || v_item.name || '" ต้องมากกว่า 0'); end if;
    if v_cost < 0 then perform rsa_err('ราคาต่อหน่วยติดลบไม่ได้'); end if;
    insert into stock_receipt_lines(receipt_id, stock_item_id, item_name, unit, qty, unit_cost, line_total)
    values (v_id, v_item.id, v_item.name, v_item.unit, v_qty, v_cost, round(v_qty * v_cost, 2));
    if v_cost > 0 then
      v_cur := greatest(rsa_stock_qty(v_item.id), 0);
      update stock_items set avg_cost = round((v_cur * avg_cost + v_qty * v_cost) / (v_cur + v_qty), 4) where id = v_item.id;
    end if;
    insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
    values (v_item.id, v_at, v_qty, 'receipt', 'receipt', v_id, v_cost, u.id);
    v_total := v_total + round(v_qty * v_cost, 2);
  end loop;
  update stock_receipts set total_cost = v_total where id = v_id;
  perform rsa_link_attachments(p->'attachment_ids', 'receipt', v_id, u);

  if coalesce(p->'expense'->>'pay_mode', 'none') <> 'none' and v_total > 0 then
    v_exp := rsa_expense_insert(u, (p->'expense') || jsonb_build_object(
      'amount', v_total, 'occurred_at', v_at, 'supplier_id', v_sup.id, 'payee', coalesce(v_sup.name, p->>'supplier_name'),
      'description', coalesce(nullif(p->'expense'->>'description', ''), 'ซื้อของเข้าร้าน ' || coalesce(v_sup.name, p->>'supplier_name', '')),
      'doc_no', p->>'ref_no'), v_id);
    update stock_receipts set expense_id = v_exp where id = v_id;
    update attachments set linked_type = 'receipt' where linked_type = 'expense' and linked_id = v_exp; -- evidence lives on the receipt
  end if;
  perform rsa_audit(u, 'receipt.create', 'receipt', v_id::text, null, jsonb_build_object('total', v_total, 'lines', jsonb_array_length(p->'lines'), 'expense_id', v_exp));
  return rsa_receipt_json(v_id);
end $$;

create or replace function rsa__receipt_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(rsa_receipt_json(r.id) order by r.received_at desc), '[]') from stock_receipts r
           where rsa_bdate(r.received_at) between rsa_date(p, 'from', rsa_today() - 30) and rsa_date(p, 'to'));
end $$;

create or replace function rsa__receipt_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v stock_receipts; r record;
begin
  perform rsa_need(u, 'stock.cancel');
  select * into v from stock_receipts where id = rsa_uuid(p, 'receipt_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบใบรับของ หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update stock_receipts set status = 'cancelled', cancelled_at = now(), cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  for r in select * from stock_ledger where source_type = 'receipt' and source_id = v.id and kind = 'receipt' loop
    insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
    values (r.stock_item_id, -r.qty, 'receipt_reversal', 'receipt', v.id, r.unit_cost, u.id);
  end loop;
  -- every bill of this receipt (one per cost category) is cancelled with it
  for r in select id from expenses where (receipt_id = v.id or id = v.expense_id) and status <> 'ยกเลิก' loop
    perform rsa__expense_cancel(u, jsonb_build_object('expense_id', r.id, 'reason', 'ยกเลิกใบรับของ ' || v.receipt_no || ': ' || (p->>'reason')));
  end loop;
  perform rsa_audit(u, 'receipt.cancel', 'receipt', v.id::text, jsonb_build_object('status', v.status), jsonb_build_object('status', 'cancelled'),
                    jsonb_build_object('reason', p->>'reason'));
  return rsa_receipt_json(v.id);
end $$;

-- ---------------------------------------------------------------- waste
create or replace function rsa__waste_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_item stock_items; v_id uuid := gen_random_uuid(); v_qty numeric := rsa_num(p, 'qty', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
begin
  perform rsa_need(u, 'waste.add');
  select * into v_item from stock_items where id = rsa_uuid(p, 'stock_item_id') and active;
  if not found then perform rsa_err('กรุณาเลือกรายการที่เสีย'); end if;
  if v_qty <= 0 then perform rsa_err('จำนวนต้องมากกว่า 0'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุสาเหตุ'); end if;
  if coalesce((select (value)::text::boolean from settings where key = 'waste_evidence_required'), false)
     and (jsonb_typeof(p->'attachment_ids') <> 'array' or jsonb_array_length(p->'attachment_ids') = 0) then
    perform rsa_err('ร้านกำหนดให้แนบรูปของเสียทุกครั้ง');
  end if;
  insert into waste_records(id, stock_item_id, item_name, unit, qty, reason, unit_cost, occurred_at, biz_date, created_by)
  values (v_id, v_item.id, v_item.name, v_item.unit, v_qty, p->>'reason', v_item.avg_cost, v_at, rsa_bdate(v_at), u.id);
  insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
  values (v_item.id, v_at, -v_qty, 'waste', 'waste', v_id, v_item.avg_cost, u.id);
  perform rsa_link_attachments(p->'attachment_ids', 'waste', v_id, u);
  perform rsa_audit(u, 'waste.create', 'waste', v_id::text, null, jsonb_build_object('item', v_item.name, 'qty', v_qty, 'reason', p->>'reason'));
  return jsonb_build_object('id', v_id);
end $$;

create or replace function rsa__waste_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(to_jsonb(w) || jsonb_build_object('created_by_name', (select display_name from app_users where id = w.created_by),
            'attachments', rsa_attachment_refs('waste', w.id)) order by w.occurred_at desc), '[]')
            from waste_records w where w.biz_date between rsa_date(p, 'from', rsa_today() - 30) and rsa_date(p, 'to'));
end $$;

create or replace function rsa__waste_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v waste_records;
begin
  perform rsa_need(u, 'stock.cancel');
  select * into v from waste_records where id = rsa_uuid(p, 'waste_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update waste_records set status = 'cancelled', cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
  values (v.stock_item_id, v.qty, 'waste_reversal', 'waste', v.id, v.unit_cost, u.id);
  perform rsa_audit(u, 'waste.cancel', 'waste', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- stock count / stocktake
create or replace function rsa_stocktake_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(t) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = t.created_by),
    'approved_by_name', (select display_name from app_users where id = t.approved_by),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) order by l.item_name), '[]') from stocktake_lines l where l.stocktake_id = t.id))
  from stocktakes t where t.id = p_id
$$;

create or replace function rsa_stocktake_insert(u app_users, p_context text, p_lines jsonb, p_note text, p_close uuid default null) returns uuid language plpgsql as $$
declare v_id uuid := gen_random_uuid(); ln jsonb; v_item stock_items; v_sys numeric; v_cnt numeric; n int := 0;
begin
  if p_context = 'opening' then perform rsa_need(u, 'master.manage'); else perform rsa_need(u, 'stock.count'); end if;
  insert into stocktakes(id, context, biz_date, close_id, note, created_by) values (v_id, p_context, rsa_today(), p_close, p_note, u.id);
  for ln in select * from jsonb_array_elements(coalesce(p_lines, '[]')) loop
    if nullif(ln->>'counted_qty', '') is null then continue; end if;
    select * into v_item from stock_items where id = rsa_uuid(ln, 'stock_item_id');
    if not found then continue; end if;
    v_sys := rsa_stock_qty(v_item.id); v_cnt := rsa_num(ln, 'counted_qty');
    if v_cnt < 0 then perform rsa_err('จำนวนนับติดลบไม่ได้'); end if;
    insert into stocktake_lines(stocktake_id, stock_item_id, item_name, system_qty, counted_qty, variance, unit_cost, note)
    values (v_id, v_item.id, v_item.name, v_sys, v_cnt, v_cnt - v_sys, rsa_num(ln, 'unit_cost'), nullif(ln->>'note', ''));
    n := n + 1;
  end loop;
  if n = 0 then
    -- nothing counted: keep no empty stocktake around (tables block deletes, so mark it rejected)
    update stocktakes set status = 'rejected', note = coalesce(p_note, '') || ' (ไม่มีรายการนับ)' where id = v_id;
    return null;
  end if;
  perform rsa_audit(u, 'stocktake.create', 'stocktake', v_id::text, null, jsonb_build_object('context', p_context, 'lines', n));
  return v_id;
end $$;

create or replace function rsa__stocktake_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid;
begin
  v_id := rsa_stocktake_insert(u, coalesce(p->>'context', 'stocktake'), p->'lines', nullif(p->>'note', ''));
  if v_id is null then perform rsa_err('ยังไม่ได้ใส่จำนวนนับ'); end if;
  if p->>'context' = 'opening' then
    perform rsa__stocktake_decide(u, jsonb_build_object('stocktake_id', v_id, 'approve', true));
  end if;
  return rsa_stocktake_json(v_id);
end $$;

create or replace function rsa__stocktake_decide(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v stocktakes; r record; v_ok boolean := coalesce((p->>'approve')::boolean, false);
begin
  perform rsa_need(u, 'stock.approve');
  select * into v from stocktakes where id = rsa_uuid(p, 'stocktake_id') for update;
  if not found or v.status <> 'pending' then perform rsa_err('ไม่พบรายการนับ หรือพิจารณาไปแล้ว'); end if;
  update stocktakes set status = case when v_ok then 'approved' else 'rejected' end, approved_at = now(), approved_by = u.id,
         note = coalesce(note, '') || coalesce(' / ' || nullif(p->>'note', ''), '') where id = v.id;
  if v_ok then
    for r in select l.*, s.avg_cost from stocktake_lines l join stock_items s on s.id = l.stock_item_id where l.stocktake_id = v.id loop
      if r.unit_cost is not null and r.unit_cost > 0 then
        update stock_items set avg_cost = r.unit_cost where id = r.stock_item_id;
      end if;
      if r.variance <> 0 then
        insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
        values (r.stock_item_id, r.variance, 'count_adjust', 'stocktake', v.id, coalesce(nullif(r.unit_cost, 0), r.avg_cost), u.id);
      end if;
    end loop;
  end if;
  perform rsa_audit(u, case when v_ok then 'stocktake.approve' else 'stocktake.reject' end, 'stocktake', v.id::text, null, null,
                    jsonb_build_object('note', p->>'note'));
  return rsa_stocktake_json(v.id);
end $$;

create or replace function rsa__stocktake_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(rsa_stocktake_json(t.id) order by t.created_at desc), '[]') from
           (select * from stocktakes t0
             where (t0.status <> 'rejected' or t0.approved_by is not null)
               and (p->>'status' is null or t0.status = p->>'status')
             order by t0.created_at desc limit 100) t);
end $$;

create or replace function rsa__stock_balance(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(x order by x->>'name'), '[]') from (
    select jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'unit', s.unit, 'kind', s.kind, 'active', s.active,
      'qty', q.qty, 'avg_cost', case when rsa_has(u, 'report.view') then s.avg_cost end,
      'value', case when rsa_has(u, 'report.view') then round(greatest(q.qty, 0) * s.avg_cost, 2) end,
      'min_qty', s.min_qty, 'reorder_qty', s.reorder_qty,
      'used_7d', coalesce((select -sum(qty) from stock_ledger l where l.stock_item_id = s.id and l.kind in ('sale','sale_reversal')
                            and l.occurred_at > now() - interval '7 days'), 0),
      'status', case when q.qty <= 0 then 'out' when q.qty <= s.min_qty then 'low' else 'ok' end,
      'suggest', case when q.qty <= s.min_qty then greatest(coalesce(nullif(s.reorder_qty, 0), s.min_qty * 2 - q.qty), 0) else 0 end,
      'used_in_recipe', exists (select 1 from recipe_lines r where r.stock_item_id = s.id),
      'pending_count', exists (select 1 from stocktake_lines l join stocktakes t on t.id = l.stocktake_id where t.status = 'pending' and l.stock_item_id = s.id)
    ) x
    from stock_items s cross join lateral (select rsa_stock_qty(s.id) qty) q
    where s.active or coalesce((p->>'include_inactive')::boolean, false)) z);
end $$;

create or replace function rsa__stock_ledger(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object('by', (select display_name from app_users where id = l.created_by)) order by l.occurred_at desc), '[]')
    from (select * from stock_ledger where stock_item_id = rsa_uuid(p, 'stock_item_id') order by occurred_at desc limit 200) l);
end $$;

-- ==================== 03_money.sql
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
        and (nullif(p->>'category_id', '') is null or e0.category_id = (p->>'category_id')::uuid
             or e0.category_id in (select id from expense_categories where parent_id = (p->>'category_id')::uuid))
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
        'loan_repaid', coalesce(sum(amount) filter (where kind = 'loan_repayment'), 0),
        'opening_debt', rsa_setting_num('opening_debt', 0),
        'debt_left', rsa_debt_left())
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

-- ==================== 04_admin.sql
-- RSA - POS Assistant : dashboard, reports, master data, users, attachments, export, API entry point
set check_function_bodies = off;

-- ---------------------------------------------------------------- dashboard & reports
create or replace function rsa__dashboard(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_date date := rsa_date(p, 'date'); v_today date := rsa_today(); v_ex jsonb := '[]'; v_n numeric; v_close daily_closes;
        v_due text := coalesce((select value #>> '{}' from settings where key = 'close_due_time'), '21:00');
begin
  perform rsa_need(u, 'report.view');
  if rsa_has(u, 'expense.approve') then perform rsa_fixed_generate(u, date_trunc('month', v_today)::date); end if;
  select * into v_close from daily_closes where biz_date = v_date;

  -- exceptions: things that need a look; nothing is forced to balance
  select count(*) into v_n from generate_series(v_today - 7, v_today - 1, interval '1 day') d
   where exists (select 1 from orders where biz_date = d::date) and not exists (select 1 from daily_closes where biz_date = d::date);
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'close_missing', 'level', 'warn', 'text', 'มี ' || v_n || ' วันที่มียอดขายแต่ยังไม่มีรายงานปิดยอด (7 วันล่าสุด)'); end if;
  -- open days (not holidays) with no sale and no report: probably a day off that was not set as a holiday
  select count(*) into v_n from generate_series(v_today - 7, v_today - 1, interval '1 day') d
   where rsa_is_open(d::date) and not exists (select 1 from orders where biz_date = d::date) and not exists (select 1 from daily_closes where biz_date = d::date)
     and d::date >= (select min(biz_date) from orders);
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'open_no_sales', 'level', 'info', 'text', 'มี ' || v_n || ' วันที่ร้านควรเปิดแต่ไม่มียอดขายและไม่มีรายงาน ถ้าวันนั้นหยุด ให้ตั้งเป็นวันหยุดร้าน'); end if;
  if v_close.id is null and v_date = v_today and to_char(now() at time zone 'Asia/Bangkok', 'HH24:MI') > v_due
     and exists (select 1 from orders where biz_date = v_today) then
    v_ex := v_ex || jsonb_build_object('kind', 'close_today', 'level', 'info', 'text', 'วันนี้ยังไม่มีรายงานปิดยอด (กำหนด ' || v_due || ')');
  end if;
  for v_close in select * from daily_closes where variance <> 0 and reviewed_at is null order by biz_date desc limit 10 loop
    v_ex := v_ex || jsonb_build_object('kind', 'cash_variance', 'level', 'warn', 'ref', v_close.id,
      'text', 'ปิดยอด ' || to_char(v_close.biz_date, 'DD/MM') || ' เงินสด' || case when v_close.variance < 0 then 'ขาด ' else 'เกิน ' end
              || to_char(abs(v_close.variance), 'FM999,999,990.00') || ' บาท: ' || coalesce(v_close.variance_reason, '-'));
  end loop;
  for v_close in select * from daily_closes where jsonb_array_length(adjustments) > 0 and reviewed_at is null order by biz_date desc limit 10 loop
    v_ex := v_ex || jsonb_build_object('kind', 'close_adjust', 'level', 'info', 'ref', v_close.id,
      'text', 'ปิดยอด ' || to_char(v_close.biz_date, 'DD/MM') || ' มีการแก้ตัวเลข ' || jsonb_array_length(v_close.adjustments) || ' จุด');
  end loop;
  select count(*) into v_n from orders o where o.status = 'cancelled' and exists (select 1 from daily_closes d where d.biz_date = o.biz_date and o.cancelled_at > d.submitted_at)
     and o.cancelled_at > now() - interval '14 days';
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'cancel_after_close', 'level', 'warn', 'text', 'มีออเดอร์ถูกยกเลิกหลังปิดยอดแล้ว ' || v_n || ' รายการ (14 วัน)'); end if;
  select count(*) into v_n from expenses where status = 'จ่ายแล้ว' and not reviewed;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'expense_review', 'level', 'info', 'text', 'ค่าใช้จ่ายที่จ่ายจากลิ้นชักแล้ว รอเจ้าของตรวจ ' || v_n || ' รายการ'); end if;
  select count(*) into v_n from expenses where status = 'รออนุมัติ';
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'expense_pending', 'level', 'info', 'text', 'ค่าใช้จ่ายรออนุมัติ ' || v_n || ' รายการ'); end if;
  select count(*) into v_n from expenses where status = 'รอทำจ่าย' and coalesce(due_date, rsa_bdate(occurred_at)) <= v_today;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'expense_due', 'level', 'warn', 'text', 'ค่าใช้จ่ายถึงกำหนดจ่าย ' || v_n || ' รายการ'); end if;
  select count(*) into v_n from stocktakes where status = 'pending';
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'stocktake_pending', 'level', 'info', 'text', 'การนับสต็อกรออนุมัติ ' || v_n || ' ครั้ง'); end if;
  select count(*) into v_n from delivery_settlements where status = 'done' and abs(system_gross - reported_gross) > 0.009;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'settlement_diff', 'level', 'warn', 'text', 'ยอด Delivery ในระบบไม่ตรงกับรายงานแพลตฟอร์ม ' || v_n || ' รอบ'); end if;
  select count(*) into v_n from orders o join channels c on c.id = o.channel_id
   where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days + 2 < v_today;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'settlement_overdue', 'level', 'warn', 'text', 'ออเดอร์ Delivery เลยกำหนดรับเงิน ' || v_n || ' ออเดอร์'); end if;
  select count(*) into v_n from money_ledger m join payment_accounts a on a.id = m.account_id
   where a.kind <> 'cash' and m.reconciled_at is null and m.biz_date < v_today - 3;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'bank_unreconciled', 'level', 'info', 'text', 'รายการเงินเข้า-ออกธนาคารยังไม่ได้ตรวจกับ statement ' || v_n || ' รายการ'); end if;
  select count(*) into v_n from stock_items s where s.active and s.min_qty > 0 and rsa_stock_qty(s.id) <= s.min_qty;
  if v_n > 0 then v_ex := v_ex || jsonb_build_object('kind', 'low_stock', 'level', 'info', 'text', 'สต็อกใกล้หมด ' || v_n || ' รายการ'); end if;
  if exists (select 1 from payment_accounts where active and not opening_confirmed)
     or exists (select 1 from channels where active and kind = 'delivery' and not fee_confirmed) then
    v_ex := v_ex || jsonb_build_object('kind', 'unconfirmed', 'level', 'info', 'text', 'ยังมีค่าตั้งต้นที่ยังไม่ยืนยัน (ยอดยกมาบัญชี / ค่าธรรมเนียม Delivery)');
  end if;

  -- costs: over budget, cost ratios, recurring bills overdue, missing documents, 5 wage paydays (14_costs.sql)
  v_ex := v_ex || rsa_cost_alerts(v_today) || rsa_receipt_alerts();

  select * into v_close from daily_closes where biz_date = v_date;
  return jsonb_build_object(
    'date', v_date,
    'holiday', not rsa_is_open(v_date),
    'sales', rsa_close_compute(v_date),
    'profit', rsa_profit(v_date, v_date),
    'month', rsa_profit(date_trunc('month', v_date)::date, v_date),
    'cash', jsonb_build_object('drawer', rsa_account_balance(rsa_drawer()),
              'all', (select coalesce(sum(rsa_account_balance(id)), 0) from payment_accounts where active)),
    'close', case when v_close.id is not null then rsa_close_json(v_close.id) end,
    'due_time', v_due,
    'exceptions', v_ex,
    'last7', (select jsonb_agg(jsonb_build_object('date', d::date,
                'net', (select coalesce(sum(total - refunded), 0) from orders where biz_date = d::date and status <> 'cancelled')) order by d)
              from generate_series(v_date - 6, v_date, interval '1 day') d)
  );
end $$;

create or replace function rsa__report_sales(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 29); v_to date := rsa_date(p, 'to'); v_g text := coalesce(p->>'group', 'day');
begin
  perform rsa_need(u, 'report.view');
  if v_g not in ('day','week','month') then v_g := 'day'; end if;
  return jsonb_build_object('from', v_from, 'to', v_to, 'group', v_g,
    'rows', (select coalesce(jsonb_agg(x order by x->>'period', x->>'channel'), '[]') from (
       select jsonb_build_object('period', to_char(date_trunc(v_g, biz_date), 'YYYY-MM-DD'), 'channel', channel_name,
         'orders', count(*), 'net', sum(total - refunded), 'discount', sum(discount), 'est_fee', sum(est_fee), 'cost', sum(cost_total)) x
       from orders where status <> 'cancelled' and biz_date between v_from and v_to
       group by date_trunc(v_g, biz_date), channel_name) t),
    -- storefront money by where it went (split bills count in both), from the money ledger
    'payments', (select coalesce(jsonb_agg(x order by (x->>'amount')::numeric desc), '[]') from (
       select jsonb_build_object('account', a.name, 'kind', a.kind,
         'amount', sum(case m.direction when 'in' then m.amount else -m.amount end),
         'orders', count(distinct m.source_id) filter (where m.direction = 'in')) x
       from money_ledger m join orders o on o.id = m.source_id join payment_accounts a on a.id = m.account_id
       where m.source_type in ('order','order_refund') and o.biz_date between v_from and v_to
       group by a.id, a.name, a.kind) t),
    'mixed_orders', (select count(*) from orders where payment_method = 'mixed' and status <> 'cancelled' and biz_date between v_from and v_to),
    'profit', rsa_profit(v_from, v_to));
end $$;

create or replace function rsa__report_products(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 29); v_to date := rsa_date(p, 'to');
begin
  perform rsa_need(u, 'report.view');
  return jsonb_build_object(
    'products', (select coalesce(jsonb_agg(x order by (x->>'revenue')::numeric desc), '[]') from (
       select jsonb_build_object('product_id', i.product_id, 'name', max(i.product_name), 'qty', sum(i.qty), 'revenue', sum(i.line_total),
         'cost', sum(coalesce(i.unit_cost, 0) * i.qty), 'gross_profit', sum(i.line_total - coalesce(i.unit_cost, 0) * i.qty),
         'cost_known', bool_and(i.cost_source <> 'none'), 'stock_linked', bool_and(i.stock_linked)) x
       from order_items i join orders o on o.id = i.order_id
       where o.status <> 'cancelled' and o.biz_date between v_from and v_to group by i.product_id) t),
    'waste', (select coalesce(jsonb_agg(x order by (x->>'cost')::numeric desc), '[]') from (
       select jsonb_build_object('item', item_name, 'unit', max(unit), 'qty', sum(qty), 'cost', round(sum(qty * unit_cost), 2), 'times', count(*)) x
       from waste_records where status = 'recorded' and biz_date between v_from and v_to group by item_name) t));
end $$;

-- ---------------------------------------------------------------- master data
create or replace function rsa_master_cols(p_entity text) returns text[] language sql immutable as $$
  select case p_entity
    when 'products' then array['sku','name','category','unit','price','est_cost','sort_order','active']
    when 'stock_items' then array['code','name','kind','unit','min_qty','reorder_qty','avg_cost','default_supplier_id','active']
    when 'units' then array['name','active']
    when 'channels' then array['name','kind','payment_method','account_id','fee_pct','fee_confirmed','settlement_days','sort_order','active']
    when 'payment_accounts' then array['name','kind','is_drawer','bank_detail','opening_balance','opening_confirmed','active']
    when 'promotions' then array['name','scope','product_ids','channel_ids','rule','value','min_qty','starts_at','ends_at','active']
    when 'suppliers' then array['name','contact_name','phone','line_id','supplies','order_days','lead_time','delivery_schedule','min_order',
                                'delivery_fee','payment_method','credit_terms','bank_detail','can_issue_receipt','can_issue_tax_invoice',
                                'return_terms','priority','note','active']
    when 'expense_categories' then array['name','tax_category','staff_allowed','active']
    when 'fixed_expenses' then array['name','category_id','payee','amount','due_day','account_id','start_month','end_month','auto_approve','active']
  end
$$;

create or replace function rsa__master_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_e text := p->>'entity'; v jsonb;
begin
  if v_e = 'fixed_expenses' then return rsa__fixed_list(u, p); end if;
  perform rsa_need(u, 'master.manage');
  if rsa_master_cols(v_e) is null then perform rsa_err('ไม่รู้จักข้อมูลประเภทนี้'); end if;
  execute format('select coalesce(jsonb_agg(to_jsonb(t) order by t.active desc, t.name), ''[]'') from %I t', v_e) into v;
  if v_e = 'products' then
    select coalesce(jsonb_agg(x || jsonb_build_object('recipe', (select coalesce(jsonb_agg(jsonb_build_object('stock_item_id', r.stock_item_id, 'qty', r.qty,
             'name', s.name, 'unit', s.unit, 'avg_cost', s.avg_cost)), '[]') from recipe_lines r join stock_items s on s.id = r.stock_item_id
             where r.product_id = (x->>'id')::uuid))), '[]') into v from jsonb_array_elements(v) x;
  end if;
  return v;
end $$;

create or replace function rsa__master_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_e text := p->>'entity'; v_data jsonb := coalesce(p->'data', '{}'); v_id uuid := rsa_uuid(p->'data', 'id');
        v_cols text[]; v_keys text[]; v_before jsonb; v_after jsonb; v_list text;
begin
  if v_e = 'fixed_expenses' then perform rsa_need(u, 'expense.approve'); else perform rsa_need(u, 'master.manage'); end if;
  v_cols := rsa_master_cols(v_e);
  if v_cols is null then perform rsa_err('ไม่รู้จักข้อมูลประเภทนี้'); end if;
  -- an empty field arrives as null: leave NOT NULL columns at their default/current value instead of failing
  select array_agg(k) into v_keys from jsonb_object_keys(v_data) k
   where k = any(v_cols)
     and not (jsonb_typeof(v_data->k) = 'null' and exists (select 1 from information_schema.columns c
              where c.table_schema = 'public' and c.table_name = v_e and c.column_name = k and c.is_nullable = 'NO'));
  if v_keys is null then perform rsa_err('ไม่มีข้อมูลให้บันทึก'); end if;
  if v_data ? 'name' and coalesce(trim(v_data->>'name'), '') = '' then perform rsa_err('กรุณาใส่ชื่อ'); end if;
  if v_e = 'payment_accounts' and coalesce((v_data->>'is_drawer')::boolean, false)
     and exists (select 1 from payment_accounts where is_drawer and active and id is distinct from v_id) then
    perform rsa_err('มีบัญชีลิ้นชักเงินสดหน้าร้านอยู่แล้ว 1 บัญชี');
  end if;
  select string_agg(quote_ident(k), ',') into v_list from unnest(v_keys) k;
  if v_id is null then
    execute format('insert into %I (%s) select %s from jsonb_populate_record(null::%I, $1) returning id', v_e, v_list, v_list, v_e)
      using v_data into v_id;
  else
    execute format('select to_jsonb(t) from %I t where id = $1', v_e) using v_id into v_before;
    if v_before is null then perform rsa_err('ไม่พบข้อมูลที่จะแก้ไข'); end if;
    execute format('update %I set (%s) = (select %s from jsonb_populate_record(null::%I, $1)) where id = $2', v_e,
      v_list, v_list, v_e) using v_data, v_id;
  end if;
  execute format('select to_jsonb(t) from %I t where id = $1', v_e) using v_id into v_after;
  if v_e = 'products' and (v_before is null or (v_before->>'price')::numeric <> (v_after->>'price')::numeric) then
    insert into product_prices(product_id, price, changed_by) values (v_id, (v_after->>'price')::numeric, u.id);
    update products set updated_at = now() where id = v_id;
  end if;
  perform rsa_audit(u, case when v_before is null then 'master.create' else 'master.update' end, v_e, v_id::text, v_before, v_after);
  return v_after;
end $$;

create or replace function rsa__recipe_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_pid uuid := rsa_uuid(p, 'product_id'); v_before jsonb; ln jsonb;
begin
  perform rsa_need(u, 'master.manage');
  if not exists (select 1 from products where id = v_pid) then perform rsa_err('ไม่พบสินค้า'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('stock_item_id', stock_item_id, 'qty', qty)), '[]') into v_before from recipe_lines where product_id = v_pid;
  delete from recipe_lines where product_id = v_pid;   -- order lines keep their own cost and stock snapshots
  for ln in select * from jsonb_array_elements(coalesce(p->'lines', '[]')) loop
    if rsa_num(ln, 'qty', 0) > 0 and rsa_uuid(ln, 'stock_item_id') is not null then
      insert into recipe_lines(product_id, stock_item_id, qty) values (v_pid, rsa_uuid(ln, 'stock_item_id'), rsa_num(ln, 'qty'))
      on conflict (product_id, stock_item_id) do update set qty = excluded.qty;
    end if;
  end loop;
  perform rsa_audit(u, 'recipe.save', 'product', v_pid::text, v_before,
    (select coalesce(jsonb_agg(jsonb_build_object('stock_item_id', stock_item_id, 'qty', qty)), '[]') from recipe_lines where product_id = v_pid));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa__settings_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_before jsonb;
begin
  perform rsa_need(u, 'settings.manage');
  if p->>'key' not in ('shop_name','close_due_time','cash_variance_tolerance','waste_evidence_required','vat_registered','tax_id') then
    perform rsa_err('ไม่รู้จักการตั้งค่านี้');
  end if;
  select to_jsonb(s) into v_before from settings s where key = p->>'key';
  insert into settings(key, value, confirmed, updated_at, updated_by) values (p->>'key', p->'value', coalesce((p->>'confirmed')::boolean, true), now(), u.id)
  on conflict (key) do update set value = excluded.value, confirmed = excluded.confirmed, updated_at = now(), updated_by = u.id;
  perform rsa_audit(u, 'settings.save', 'settings', p->>'key', v_before, jsonb_build_object('value', p->'value', 'confirmed', coalesce((p->>'confirmed')::boolean, true)));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- users & permissions (Admin)
create or replace function rsa__user_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'admin.users');
  return (select coalesce(jsonb_agg(rsa_user_json(x) || jsonb_build_object('created_at', x.created_at, 'locked', x.locked_until > now())
            order by x.active desc, x.display_name), '[]') from app_users x);
end $$;

create or replace function rsa__user_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := rsa_uuid(p, 'id'); v app_users; v_before jsonb; v_perms text[]; v_role text := p->>'role';
begin
  perform rsa_need(u, 'admin.users');
  if v_role not in ('staff','owner','admin') then perform rsa_err('กรุณาเลือกบทบาท'); end if;
  if jsonb_typeof(p->'perms') = 'array' then
    select coalesce(array_agg(x), '{}') into v_perms from jsonb_array_elements_text(p->'perms') x where x = any(rsa_all_perms());
  else
    v_perms := rsa_role_perms(v_role);
  end if;
  if v_id is null then
    if coalesce(p->>'pin', '') !~ '^[0-9]{6}$' then perform rsa_err('PIN ต้องเป็นตัวเลข 6 หลัก'); end if;
    if coalesce(p->>'username', '') !~ '^[a-z0-9._-]{2,32}$' then perform rsa_err('ชื่อผู้ใช้ใช้ได้เฉพาะ a-z 0-9 . _ - (2-32 ตัว)'); end if;
    if exists (select 1 from app_users where username = p->>'username') then perform rsa_err('ชื่อผู้ใช้นี้มีแล้ว'); end if;
    insert into app_users(username, display_name, role, perms, pin_hash, created_by)
    values (p->>'username', trim(p->>'display_name'), v_role, v_perms, crypt(p->>'pin', gen_salt('bf', 8)), u.id) returning * into v;
    perform rsa_audit(u, 'user.create', 'user', v.id::text, null, rsa_user_json(v));
  else
    select * into v from app_users where id = v_id for update;
    if not found then perform rsa_err('ไม่พบผู้ใช้'); end if;
    v_before := rsa_user_json(v);
    if v.id = u.id and (not coalesce((p->>'active')::boolean, true) or not ('admin.users' = any(v_perms))) then
      perform rsa_err('ปิดใช้งานหรือถอดสิทธิ์ผู้ดูแลของตัวเองไม่ได้');
    end if;
    update app_users set display_name = coalesce(nullif(trim(p->>'display_name'), ''), display_name), role = v_role, perms = v_perms,
           active = coalesce((p->>'active')::boolean, active), updated_at = now() where id = v.id returning * into v;
    if not v.active then update app_sessions set revoked_at = now() where user_id = v.id and revoked_at is null; end if;
    perform rsa_audit(u, case when v_before->'perms' <> to_jsonb(v.perms) then 'user.permissions' else 'user.update' end,
                      'user', v.id::text, v_before, rsa_user_json(v));
  end if;
  return rsa_user_json(v);
end $$;

create or replace function rsa__user_reset_pin(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v app_users;
begin
  if rsa_uuid(p, 'id') is distinct from u.id then perform rsa_need(u, 'admin.users'); end if;
  if coalesce(p->>'pin', '') !~ '^[0-9]{6}$' then perform rsa_err('PIN ต้องเป็นตัวเลข 6 หลัก'); end if;
  if rsa_uuid(p, 'id') = u.id and u.pin_hash <> crypt(coalesce(p->>'old_pin', ''), u.pin_hash) then
    perform rsa_err('PIN เดิมไม่ถูกต้อง');
  end if;
  update app_users set pin_hash = crypt(p->>'pin', gen_salt('bf', 8)), failed_attempts = 0, locked_until = null, updated_at = now()
   where id = rsa_uuid(p, 'id') returning * into v;
  if not found then perform rsa_err('ไม่พบผู้ใช้'); end if;
  if v.id <> u.id then update app_sessions set revoked_at = now() where user_id = v.id and revoked_at is null; end if;
  perform rsa_audit(u, 'user.reset_pin', 'user', v.id::text, null, null, jsonb_build_object('target', v.display_name));  -- PIN itself is never logged
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa__audit_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'audit.view');
  return (select coalesce(jsonb_agg(to_jsonb(a) order by a.id desc), '[]') from
    (select * from audit_log a0
      where rsa_bdate(a0.at) between rsa_date(p, 'from', rsa_today() - 7) and rsa_date(p, 'to')
        and (nullif(p->>'action', '') is null or a0.action like (p->>'action') || '%')
        and (rsa_uuid(p, 'user_id') is null or a0.user_id = rsa_uuid(p, 'user_id'))
      order by a0.id desc limit 500) a);
end $$;

-- ---------------------------------------------------------------- attachments
create or replace function rsa__attachment_upload(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid; v_len int := length(coalesce(p->>'data_b64', ''));
begin
  if v_len = 0 then perform rsa_err('ไม่มีไฟล์'); end if;
  if v_len > 2800000 then perform rsa_err('ไฟล์ใหญ่เกิน 2 MB กรุณาถ่ายใหม่หรือย่อรูป'); end if;
  if coalesce(p->>'mime', '') !~ '^(image/(jpeg|png|webp)|application/pdf)$' then perform rsa_err('รองรับเฉพาะรูปภาพ JPG/PNG/WebP หรือ PDF'); end if;
  insert into attachments(filename, mime, size_bytes, data_b64, doc_kind, created_by)
  values (coalesce(nullif(p->>'filename', ''), 'file'), p->>'mime', (v_len * 3 / 4), p->>'data_b64', nullif(p->>'doc_kind', ''), u.id)
  returning id into v_id;
  perform rsa_audit(u, 'attachment.upload', 'attachment', v_id::text, null, jsonb_build_object('filename', p->>'filename', 'doc_kind', p->>'doc_kind'));
  return jsonb_build_object('id', v_id);
end $$;

create or replace function rsa__attachment_get(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v attachments;
begin
  select * into v from attachments where id = rsa_uuid(p, 'id');
  if not found then perform rsa_err('ไม่พบไฟล์'); end if;
  if v.created_by <> u.id and not (rsa_has(u, 'expense.view_all') or rsa_has(u, 'report.view') or rsa_has(u, 'stock.view')) then
    perform rsa_err('คุณยังไม่มีสิทธิ์ดูไฟล์นี้');
  end if;
  return jsonb_build_object('id', v.id, 'filename', v.filename, 'mime', v.mime, 'data_b64', v.data_b64, 'linked_type', v.linked_type, 'linked_id', v.linked_id);
end $$;

-- ---------------------------------------------------------------- accounting / tax export
create or replace function rsa__export(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_kind text := p->>'kind'; v_from date := rsa_date(p, 'from', rsa_today() - 30); v_to date := rsa_date(p, 'to');
        v_ch uuid := rsa_uuid(p, 'channel_id'); v_user uuid := rsa_uuid(p, 'user_id'); v_status text := nullif(p->>'status', ''); v jsonb;
begin
  perform rsa_need(u, 'export.run');
  if v_kind = 'sales' then
    select coalesce(jsonb_agg(x order by x->>'created_at', x->>'order_no'), '[]') into v from (
      select jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'biz_date', o.biz_date, 'created_at', o.created_at,
        'channel', o.channel_name, 'channel_kind', o.channel_kind, 'payment_method', o.payment_method, 'order_status', o.status,
        'item_id', i.id, 'sku', i.sku, 'product', i.product_name, 'qty', i.qty, 'unit', i.unit, 'unit_price', i.unit_price,
        'line_discount', i.discount, 'promotion', i.promo_snapshot->>'name', 'line_total', i.line_total,
        'order_total', o.total, 'order_refunded', o.refunded, 'est_delivery_fee', o.est_fee, 'settlement_id', o.settlement_id,
        'unit_cost_est', i.unit_cost, 'cost_source', i.cost_source,
        'created_by', (select display_name from app_users where id = o.created_by),
        'cancelled_at', o.cancelled_at, 'cancelled_by', (select display_name from app_users where id = o.cancelled_by), 'cancel_reason', o.cancel_reason) x
      from orders o join order_items i on i.order_id = o.id
      where o.biz_date between v_from and v_to and (v_ch is null or o.channel_id = v_ch) and (v_user is null or o.created_by = v_user)
        and (v_status is null or o.status = v_status)) t;
  elsif v_kind = 'money' then
    select coalesce(jsonb_agg(x order by x->>'occurred_at'), '[]') into v from (
      select jsonb_build_object('ledger_id', m.id, 'biz_date', m.biz_date, 'occurred_at', m.occurred_at, 'account', a.name, 'account_kind', a.kind,
        'direction', case m.direction when 'in' then 'รับเข้า' else 'จ่ายออก' end, 'amount', m.amount, 'source_type', m.source_type, 'source_id', m.source_id,
        'document_no', coalesce((select order_no from orders where id = m.source_id), (select expense_no from expenses where id = m.source_id),
                                (select ref_no from delivery_settlements where id = m.source_id)),
        'note', m.note, 'reconciled_at', m.reconciled_at, 'bank_ref', m.bank_ref, 'created_by', (select display_name from app_users where id = m.created_by),
        'created_at', m.created_at) x
      from money_ledger m join payment_accounts a on a.id = m.account_id
      where m.biz_date between v_from and v_to and (v_user is null or m.created_by = v_user)) t;
  elsif v_kind = 'expenses' then
    select coalesce(jsonb_agg(x order by x->>'occurred_at'), '[]') into v from (
      select jsonb_build_object('expense_id', e.id, 'expense_no', e.expense_no, 'occurred_at', e.occurred_at, 'due_date', e.due_date,
        'category', e.category_name, 'tax_category', e.tax_category, 'payee', e.payee, 'description', e.description, 'amount', e.amount,
        'status', e.status, 'pay_account', (select name from payment_accounts where id = e.pay_account_id),
        'employee_reimbursement', (select display_name from app_users where id = e.paid_by_employee), 'doc_type', e.doc_type, 'doc_no', e.doc_no,
        'evidence_ids', (select string_agg(id::text, ' ') from attachments where (linked_type = 'expense' and linked_id = e.id) or (linked_type = 'receipt' and linked_id = e.receipt_id)),
        'stock_receipt_id', e.receipt_id, 'fixed_expense_period', e.period,
        'created_by', (select display_name from app_users where id = e.created_by), 'created_at', e.created_at,
        'approved_by', (select display_name from app_users where id = e.approved_by), 'approved_at', e.approved_at,
        'paid_by', (select display_name from app_users where id = e.paid_by), 'paid_at', e.paid_at,
        'cancelled_by', (select display_name from app_users where id = e.cancelled_by), 'cancelled_at', e.cancelled_at, 'cancel_reason', e.cancel_reason) x
      from expenses e
      where rsa_bdate(e.occurred_at) between v_from and v_to and (v_status is null or e.status = v_status) and (v_user is null or e.created_by = v_user)) t;
  elsif v_kind = 'delivery' then
    select coalesce(jsonb_agg(x order by x->>'period_from'), '[]') into v from (
      select jsonb_build_object('settlement_id', s.id, 'channel', s.channel_name, 'period_from', s.period_from, 'period_to', s.period_to,
        'system_gross', s.system_gross, 'reported_gross', s.reported_gross, 'difference', s.reported_gross - s.system_gross,
        'fee', s.fee, 'net', s.net, 'deposit_account', (select name from payment_accounts where id = s.account_id), 'deposited_at', s.deposited_at,
        'ref_no', s.ref_no, 'status', s.status, 'cancel_reason', s.cancel_reason,
        'evidence_ids', (select string_agg(id::text, ' ') from attachments where linked_type = 'settlement' and linked_id = s.id),
        'created_by', (select display_name from app_users where id = s.created_by), 'created_at', s.created_at) x
      from delivery_settlements s where s.period_to between v_from and v_to and (v_ch is null or s.channel_id = v_ch)) t;
  elsif v_kind = 'corrections' then
    select coalesce(jsonb_agg(x order by x->>'at'), '[]') into v from (
      select jsonb_build_object('type', 'order.' || e.kind, 'record_id', e.order_id, 'document_no', o.order_no, 'at', e.created_at, 'amount', e.amount,
        'original_amount', o.total, 'reason', e.reason, 'by', (select display_name from app_users where id = e.created_by)) x
        from order_events e join orders o on o.id = e.order_id where rsa_bdate(e.created_at) between v_from and v_to
      union all
      select jsonb_build_object('type', 'expense.cancel', 'record_id', id, 'document_no', expense_no, 'at', cancelled_at, 'amount', amount,
        'original_amount', amount, 'reason', cancel_reason, 'by', (select display_name from app_users where id = cancelled_by))
        from expenses where status = 'ยกเลิก' and rsa_bdate(cancelled_at) between v_from and v_to
      union all
      select jsonb_build_object('type', 'receipt.cancel', 'record_id', id, 'document_no', receipt_no, 'at', cancelled_at, 'amount', total_cost,
        'original_amount', total_cost, 'reason', cancel_reason, 'by', (select display_name from app_users where id = cancelled_by))
        from stock_receipts where status = 'cancelled' and rsa_bdate(cancelled_at) between v_from and v_to
      union all
      select jsonb_build_object('type', 'close.adjustment', 'record_id', d.id, 'document_no', to_char(d.biz_date, 'YYYY-MM-DD'), 'at', d.submitted_at,
        'field', a->>'label', 'original_amount', a->'original', 'amount', a->'corrected', 'reason', a->>'reason', 'by', coalesce(a->>'by', (select display_name from app_users where id = d.submitted_by)))
        from daily_closes d, jsonb_array_elements(d.adjustments) a where d.biz_date between v_from and v_to
      union all
      select jsonb_build_object('type', 'close.cash_variance', 'record_id', d.id, 'document_no', to_char(d.biz_date, 'YYYY-MM-DD'), 'at', d.submitted_at,
        'original_amount', d.expected_cash, 'amount', d.counted_cash, 'difference', d.variance, 'reason', d.variance_reason,
        'by', (select display_name from app_users where id = d.submitted_by))
        from daily_closes d where d.variance <> 0 and d.biz_date between v_from and v_to
      union all
      select jsonb_build_object('type', 'settlement.cancel', 'record_id', id, 'document_no', ref_no, 'at', created_at, 'amount', net, 'reason', cancel_reason,
        'by', (select display_name from app_users where id = cancelled_by)) from delivery_settlements where status = 'cancelled' and period_to between v_from and v_to
      ) t;
  elsif v_kind = 'receipts' then
    select coalesce(jsonb_agg(x order by x->>'received_at'), '[]') into v from (
      select jsonb_build_object('receipt_id', r.id, 'receipt_no', r.receipt_no, 'received_at', r.received_at, 'supplier', r.supplier_name, 'ref_no', r.ref_no,
        'item', l.item_name, 'qty', l.qty, 'unit', l.unit, 'unit_cost', l.unit_cost, 'line_total', l.line_total, 'status', r.status,
        'expense_no', (select expense_no from expenses where id = r.expense_id),
        'evidence_ids', (select string_agg(id::text, ' ') from attachments where linked_type = 'receipt' and linked_id = r.id),
        'created_by', (select display_name from app_users where id = r.created_by)) x
      from stock_receipts r join stock_receipt_lines l on l.receipt_id = r.id where rsa_bdate(r.received_at) between v_from and v_to) t;
  elsif v_kind = 'audit' then
    perform rsa_need(u, 'audit.view');
    select coalesce(jsonb_agg(jsonb_build_object('audit_id', a.id, 'at', a.at, 'user', a.user_name, 'action', a.action, 'entity', a.entity,
      'entity_id', a.entity_id, 'before', a.before, 'after', a.after, 'meta', a.meta) order by a.id), '[]') into v
      from audit_log a where rsa_bdate(a.at) between v_from and v_to and (v_user is null or a.user_id = v_user);
  else
    perform rsa_err('ไม่รู้จักประเภทรายงานส่งออก');
  end if;
  perform rsa_audit(u, 'export', 'export', v_kind, null, null,
    jsonb_build_object('kind', v_kind, 'from', v_from, 'to', v_to, 'channel_id', v_ch, 'user_id', v_user, 'status', v_status, 'rows', jsonb_array_length(v)));
  return v;
end $$;

-- ---------------------------------------------------------------- API entry point
create or replace function rsa_api(p_token text, p_action text, p_payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u app_users := rsa_session_user(p_token); p jsonb := coalesce(p_payload, '{}');
begin
  return case p_action
    when 'bootstrap'          then rsa__bootstrap(u, p)
    when 'order.create'       then rsa__order_create(u, p)
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
    when 'profit.declare'     then rsa__profit_declare(u, p)
    when 'profit.cancel'      then rsa__profit_cancel(u, p)
    when 'ledger.list'        then rsa__ledger_list(u, p)
    when 'ledger.reconcile'   then rsa__ledger_reconcile(u, p)
    when 'cashflow.summary'   then rsa__cashflow_summary(u, p)
    when 'dashboard'          then rsa__dashboard(u, p)
    when 'report.sales'       then rsa__report_sales(u, p)
    when 'report.products'    then rsa__report_products(u, p)
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
    when 'export'             then rsa__export(u, p)
    else (select jsonb_build_object('error', 'ไม่รู้จักคำสั่ง ' || p_action))
  end;
end $$;

-- Only the four entry points are callable from the browser.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'rsa%' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', r.sig); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke all on function %s from authenticated', r.sig); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function rsa_status() to anon;
    grant execute on function rsa_setup(text, text, text) to anon;
    grant execute on function rsa_login(text, text) to anon;
    grant execute on function rsa_logout(text) to anon;
    grant execute on function rsa_api(text, text, jsonb) to anon;
  end if;
end $$;

-- ==================== 05_seed.sql
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

-- ==================== 06_detail_schema.sql
-- RSA - POS Assistant : detail upgrade (schema). Safe to run again; existing data is kept.
set check_function_bodies = off;

-- ---------------------------------------------------------------- products: channel price, emoji, main raw material
alter table products add column if not exists delivery_price numeric(12,2);
alter table products add column if not exists delivery_enabled boolean not null default true;
alter table products add column if not exists emoji text;
alter table products add column if not exists main_stock_item_id uuid references stock_items(id);   -- hint only; usage comes from recipe_lines

-- ---------------------------------------------------------------- promotions: bundle "buy N for P"
alter table promotions add column if not exists buy_qty numeric(12,3);
alter table promotions add column if not exists bundle_price numeric(12,2);
alter table promotions add column if not exists storefront_only boolean not null default false;
alter table promotions drop constraint if exists promotions_rule_check;
alter table promotions add constraint promotions_rule_check check (rule in ('percent','amount_each','bundle'));

-- ---------------------------------------------------------------- orders: amount actually received, edit chain
alter table orders add column if not exists calc_total numeric(12,2);
alter table orders add column if not exists received_note text;
alter table orders add column if not exists replaces_order_id uuid references orders(id);
alter table orders add column if not exists replaced_by uuid references orders(id);

-- ---------------------------------------------------------------- waste by product (stock cut through the recipe)
alter table waste_records alter column stock_item_id drop not null;
alter table waste_records add column if not exists product_id uuid references products(id);
alter table waste_records add column if not exists close_id uuid;

-- ---------------------------------------------------------------- receiving: transport allocation, who paid
alter table stock_receipts add column if not exists goods_cost numeric(14,2) not null default 0;
alter table stock_receipts add column if not exists transport_cost numeric(14,2) not null default 0;
alter table stock_receipts add column if not exists transport_method text;
alter table stock_receipts add column if not exists pay_method text;
alter table stock_receipts add column if not exists payer text;
alter table stock_receipt_lines add column if not exists weight numeric(14,3);
alter table stock_receipt_lines add column if not exists transport_alloc numeric(14,2) not null default 0;
alter table stock_receipt_lines add column if not exists landed_unit_cost numeric(14,4);

-- ---------------------------------------------------------------- expenses: fund source, payer, reimbursement
alter table expenses add column if not exists fund_source text;
alter table expenses add column if not exists paid_by_owner boolean not null default false;
alter table expenses add column if not exists pay_ref text;
alter table fixed_expenses add column if not exists confirmed boolean not null default true;
alter table fixed_expenses add column if not exists note text;

-- ---------------------------------------------------------------- daily close: 6-step detail
alter table daily_closes add column if not exists product_counts jsonb not null default '[]';
alter table daily_closes add column if not exists delivery_counts jsonb not null default '[]';
alter table daily_closes add column if not exists cash_detail jsonb not null default '{}';
alter table daily_closes add column if not exists cash_removed numeric(14,2) not null default 0;
alter table daily_closes add column if not exists cash_removed_to uuid references payment_accounts(id);
alter table daily_closes add column if not exists transfer_id uuid;
alter table daily_closes add column if not exists on_time boolean;

-- ---------------------------------------------------------------- investment items & profit uses
alter table capital_entries alter column account_id drop not null;
alter table capital_entries alter column created_by drop not null;
alter table capital_entries add column if not exists category text;
alter table capital_entries add column if not exists counts_as_investment boolean not null default true;
alter table capital_entries add column if not exists in_payback boolean not null default true;
alter table capital_entries add column if not exists refundable_amount numeric(14,2) not null default 0;
alter table capital_entries add column if not exists data_status text not null default 'ยืนยันแล้ว';
alter table capital_entries drop constraint if exists capital_entries_kind_check;
alter table capital_entries add constraint capital_entries_kind_check
  check (kind in ('capital_in','loan_in','capital_return','loan_repayment','investment_item','owner_paid'));

alter table profit_declarations alter column account_id drop not null;
alter table profit_declarations add column if not exists paid_now boolean not null default true;
alter table profit_declarations drop constraint if exists profit_declarations_purpose_check;
alter table profit_declarations add constraint profit_declarations_purpose_check
  check (purpose in ('owner_draw','capital_return','loan_repayment','keep_working_capital','reinvest'));

-- ---------------------------------------------------------------- bank statement lines (what really came in / went out)
create table if not exists bank_lines (
  id           uuid primary key default gen_random_uuid(),
  account_id   uuid not null references payment_accounts(id),
  occurred_at  timestamptz not null,
  biz_date     date not null,
  direction    text not null check (direction in ('in','out')),
  amount       numeric(14,2) not null check (amount > 0),
  ref_no       text,
  description  text,
  status       text not null default 'done' check (status in ('done','cancelled')),
  created_at   timestamptz not null default now(),
  created_by   uuid not null references app_users(id),
  cancelled_by uuid references app_users(id),
  cancel_reason text
);
create index if not exists bank_lines_date on bank_lines(account_id, biz_date);

-- ---------------------------------------------------------------- guards for the new table
do $$
begin
  drop trigger if exists bank_lines_no_delete on bank_lines;
  create trigger bank_lines_no_delete before delete on bank_lines for each statement execute function rsa_block_delete();
  alter table bank_lines enable row level security;
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on bank_lines from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then revoke all on bank_lines from authenticated; end if;
end $$;

alter table capital_entries add column if not exists expense_id uuid references expenses(id);

-- counting in other units: [{unit, factor}] where 1 unit = factor x base unit (e.g. 1 ลูก ≈ 3.5 กก., an average)
alter table stock_items add column if not exists count_units jsonb not null default '[]';
alter table stocktake_lines add column if not exists count_detail jsonb;

-- platform payout breakdown: {commission, vat, marketing, other}
alter table delivery_settlements add column if not exists fee_breakdown jsonb not null default '{}';

-- ---------------------------------------------------------------- weekly wages from workdays
alter table app_users add column if not exists daily_wage numeric(12,2);
alter table expenses add column if not exists advance_user_id uuid references app_users(id);   -- wage advance given to this person
alter table expenses add column if not exists advance_run_id uuid;                               -- payroll run that deducted it
create table if not exists payroll_runs (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references app_users(id),
  period_from      date not null,
  period_to        date not null,
  system_days      int not null,
  days             numeric(6,2) not null,
  days_reason      text,
  day_dates        jsonb not null default '[]',
  daily_wage       numeric(12,2) not null,
  base_amount      numeric(14,2) not null,
  extras           jsonb not null default '[]',
  extras_total     numeric(14,2) not null default 0,
  gross            numeric(14,2) not null,
  advance_deducted numeric(14,2) not null default 0,
  net_paid         numeric(14,2) not null,
  expense_id       uuid references expenses(id),
  account_id       uuid references payment_accounts(id),
  pay_ref          text,
  note             text,
  status           text not null default 'done' check (status in ('done','cancelled')),
  created_at       timestamptz not null default now(),
  created_by       uuid not null references app_users(id),
  cancelled_by     uuid references app_users(id),
  cancel_reason    text
);
create unique index if not exists payroll_runs_once on payroll_runs(user_id, period_from, period_to) where status = 'done';
do $$
begin
  drop trigger if exists payroll_runs_no_delete on payroll_runs;
  create trigger payroll_runs_no_delete before delete on payroll_runs for each statement execute function rsa_block_delete();
  alter table payroll_runs enable row level security;
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on payroll_runs from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then revoke all on payroll_runs from authenticated; end if;
end $$;

-- ---------------------------------------------------------------- v7: split payment, evening markdown, staff meal / owner use
create table if not exists order_payments (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references orders(id),
  account_id uuid not null references payment_accounts(id),
  method     text not null,                 -- cash / qr (from the account kind)
  amount     numeric(12,2) not null check (amount > 0),
  created_at timestamptz not null default now()
);
create index if not exists order_payments_order on order_payments(order_id);
do $$
begin
  drop trigger if exists order_payments_no_delete on order_payments;
  create trigger order_payments_no_delete before delete on order_payments for each statement execute function rsa_block_delete();
  alter table order_payments enable row level security;
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on order_payments from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then revoke all on order_payments from authenticated; end if;
end $$;
alter table products add column if not exists markdown_price numeric(12,2);   -- evening clearance price (empty = not allowed)
alter table waste_records add column if not exists kind text not null default 'waste';
alter table waste_records drop constraint if exists waste_records_kind_check;
alter table waste_records add constraint waste_records_kind_check check (kind in ('waste','staff_meal','owner_use'));
alter table waste_records add column if not exists for_user_id uuid references app_users(id);

-- ---------------------------------------------------------------- v9: import from other systems (QR / bank lines, platform orders)
create table if not exists import_batches (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in ('bank','delivery')),
  channel_id    uuid references channels(id),
  account_id    uuid references payment_accounts(id),
  file_name     text,
  rows_total    int not null default 0,
  rows_added    int not null default 0,
  rows_skipped  int not null default 0,
  status        text not null default 'done' check (status in ('done','cancelled')),
  created_at    timestamptz not null default now(),
  created_by    uuid not null references app_users(id),
  cancelled_by  uuid references app_users(id),
  cancel_reason text
);
alter table bank_lines add column if not exists import_id uuid references import_batches(id);
create table if not exists platform_orders (
  id               uuid primary key default gen_random_uuid(),
  import_id        uuid not null references import_batches(id),
  channel_id       uuid not null references channels(id),
  external_id      text not null,
  biz_date         date not null,
  ordered_at       timestamptz not null,
  items            jsonb not null default '[]',   -- [{name, qty, gross, product_id}]
  gross            numeric(12,2) not null,         -- menu price total before anything is taken off
  shop_discount    numeric(12,2) not null default 0,
  commission       numeric(12,2) not null default 0,
  vat              numeric(12,2) not null default 0,
  other_fee        numeric(12,2) not null default 0,
  platform_status  text not null default 'completed' check (platform_status in ('completed','cancelled')),
  matched_order_id uuid references orders(id),
  added_order      boolean not null default false,  -- the order was created from this row
  status           text not null default 'done' check (status in ('done','cancelled')),
  created_at       timestamptz not null default now()
);
create unique index if not exists platform_orders_once on platform_orders(channel_id, external_id) where status = 'done';
create index if not exists platform_orders_date on platform_orders(channel_id, biz_date);
create table if not exists product_aliases (
  id            uuid primary key default gen_random_uuid(),
  channel_id    uuid not null references channels(id),
  external_name text not null,                     -- stored lower-case and trimmed
  product_id    uuid references products(id),      -- null = not a product of the shop (skip)
  created_at    timestamptz not null default now(),
  created_by    uuid references app_users(id),
  unique (channel_id, external_name)
);
do $$
declare t text;
begin
  foreach t in array array['import_batches','platform_orders','product_aliases'] loop
    execute format('drop trigger if exists %I on %I', t || '_no_delete', t);
    execute format('create trigger %I before delete on %I for each statement execute function rsa_block_delete()', t || '_no_delete', t);
    execute format('alter table %I enable row level security', t);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on %I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke all on %I from authenticated', t); end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- v10: cost groups and budgets
-- every expense category belongs to one group: A variable cost (moves with sales), B fixed cost, C not a cost (debt, capital, investment, drawing)
alter table expense_categories add column if not exists code text;
alter table expense_categories add column if not exists grp text;
alter table expense_categories add column if not exists parent_id uuid references expense_categories(id);
alter table expense_categories add column if not exists budget_method text not null default 'amount';
alter table expense_categories add column if not exists budget_amount numeric(14,2);
alter table expense_categories add column if not exists budget_pct numeric(8,4);
alter table expense_categories add column if not exists pct_base text;            -- sales | pcat:<product category> | channel
alter table expense_categories add column if not exists channel_id uuid references channels(id);
alter table expense_categories add column if not exists auto_source text;         -- delivery_gp | delivery_ads: filled from platform payouts
alter table expense_categories add column if not exists c_kind text;              -- group C: loan_repayment | capital_in | investment_item | owner_draw | advance
alter table expense_categories add column if not exists ratio_key text;           -- fruit | meatball | packaging: weekly cost ratio
alter table expense_categories add column if not exists budget_confirmed boolean not null default false;
alter table expense_categories add column if not exists sort_order int not null default 100;
do $$ begin
  alter table expense_categories add constraint expense_categories_grp_check check (grp is null or grp in ('A','B','C'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table expense_categories add constraint expense_categories_budget_check check (budget_method in ('amount','pct','fixed'));
exception when duplicate_object then null; end $$;
create unique index if not exists expense_categories_code_key on expense_categories(code) where code is not null;

-- which cost a stock item's purchase belongs to (fruit, meatballs, sauces, packaging)
alter table stock_items add column if not exists cost_category_id uuid references expense_categories(id);

-- recurring costs: monthly or weekly
alter table fixed_expenses add column if not exists frequency text not null default 'monthly';
alter table fixed_expenses alter column due_day set default 1;  -- weekly items use weekday instead
alter table fixed_expenses add column if not exists weekday int;                 -- 0 = Sunday … 6 = Saturday (weekly)
alter table fixed_expenses add column if not exists fund_source text;
do $$ begin
  alter table fixed_expenses add constraint fixed_expenses_freq_check check (frequency in ('monthly','weekly') and (frequency = 'monthly' or weekday between 0 and 6));
exception when duplicate_object then null; end $$;

-- an edited expense keeps the old row (cancelled) and points both ways
alter table expenses add column if not exists replaces_id uuid references expenses(id);
alter table expenses add column if not exists replaced_by uuid references expenses(id);
alter table expenses add column if not exists edited_at timestamptz;
alter table expenses add column if not exists edited_by uuid references app_users(id);

-- ==================== 07_detail_ops.sql
-- RSA - POS Assistant : detail upgrade (sales with channel price / bundle / received amount / edit,
-- waste by product, receiving with transport, expenses with fund source, 6-step daily close)
set check_function_bodies = off;

create or replace function rsa_setting(p_key text, p_default jsonb default null) returns jsonb language sql stable as $$
  select coalesce((select value from settings where key = p_key), p_default)
$$;

create or replace function rsa_setting_num(p_key text, p_default numeric default 0) returns numeric language sql stable as $$
  select coalesce((select nullif(value #>> '{}', '')::numeric from settings where key = p_key and jsonb_typeof(value) in ('number','string')), p_default)
$$;

create or replace function rsa_setting_bool(p_key text) returns boolean language sql stable as $$
  select coalesce((select (value #>> '{}')::boolean from settings where key = p_key and jsonb_typeof(value) = 'boolean'), false)
$$;

-- shop holidays: weekly closed days (0 = Sunday … 6 = Saturday) and one-off closed dates
create or replace function rsa_is_open(d date) returns boolean language sql stable as $$
  select not (extract(dow from d)::int in (select jsonb_array_elements_text(case when jsonb_typeof(rsa_setting('closed_weekdays')) = 'array' then rsa_setting('closed_weekdays') else '[]' end)::int)
              or to_char(d, 'YYYY-MM-DD') in (select jsonb_array_elements_text(case when jsonb_typeof(rsa_setting('closed_dates')) = 'array' then rsa_setting('closed_dates') else '[]' end)))
$$;

-- number of days the shop is open in a range (at least 1, used as the divisor of per-day averages)
create or replace function rsa_open_days(p_from date, p_to date) returns int language sql stable as $$
  select greatest(count(*)::int, 1) from generate_series(p_from, p_to, interval '1 day') g where rsa_is_open(g::date)
$$;

create or replace function rsa_has_files(p jsonb) returns boolean language sql immutable as $$
  select coalesce(jsonb_typeof(p->'attachment_ids') = 'array' and jsonb_array_length(p->'attachment_ids') > 0, false)
$$;

-- ---------------------------------------------------------------- orders
create or replace function rsa_order_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(o) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = o.created_by),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) || jsonb_build_object('emoji', (select emoji from products where id = i.product_id)) order by i.product_name), '[]')
              from order_items i where i.order_id = o.id),
    'events', (select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object('by', (select display_name from app_users where id = e.created_by)) order by e.created_at), '[]')
               from order_events e where e.order_id = o.id),
    'replaced_by_no', (select order_no from orders x where x.id = o.replaced_by),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('account_id', op.account_id, 'method', op.method, 'amount', op.amount,
                   'account', (select name from payment_accounts where id = op.account_id)) order by op.amount desc), '[]')
                 from order_payments op where op.order_id = o.id),
    'replaces_no', (select order_no from orders x where x.id = o.replaces_order_id),
    'closed', exists (select 1 from daily_closes d where d.biz_date = o.biz_date))
  from orders o where o.id = p_id
$$;

-- Staff may fix their own order on the same day before the daily close; anyone with sales.cancel may fix any order.
create or replace function rsa_order_can_edit(u app_users, v orders) returns boolean language sql stable as $$
  select rsa_has(u, 'sales.cancel')
      or (v.created_by = u.id and v.biz_date = rsa_today() and not exists (select 1 from daily_closes d where d.biz_date = v.biz_date))
$$;

create or replace function rsa__order_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_ch channels; it jsonb; ln jsonb; v_prod products; v_promo promotions;
  v_id uuid := gen_random_uuid(); v_no text; v_n int; i int;
  -- set by order.update so the corrected order keeps the original time and links back to it
  v_edit_at text := nullif(current_setting('rsa.edit_at', true), '');
  v_edit_of uuid := nullif(current_setting('rsa.edit_of', true), '')::uuid;
  v_at timestamptz; v_date date;
  v_lines jsonb := '[]'; v_bdisc jsonb := '{}';
  v_qty numeric; v_price numeric; v_gross numeric; v_pdisc numeric; v_mdisc numeric; v_line numeric;
  v_promo_id uuid; v_snap jsonb;
  v_unit_cost numeric; v_src text; v_linked boolean; v_missing boolean;
  v_sub numeric := 0; v_disc numeric := 0; v_cost numeric := 0; v_cost_ok boolean := true;
  v_existing uuid; v_calc numeric; v_total numeric; v_recv numeric; v_item_id uuid; r record;
  v_idx int[]; v_pool_qty numeric; v_pool_gross numeric; v_bundles numeric; v_bd numeric; v_rest numeric; v_share numeric; k int;
  v_md boolean; v_md_from text := nullif(rsa_setting('markdown_from') #>> '{}', ''); v_pays jsonb; v_pay jsonb; v_pacc payment_accounts; v_psum numeric := 0;
begin
  perform rsa_need(u, 'sales.add');
  if v_edit_at is not null then
    v_at := v_edit_at::timestamptz;
  elsif nullif(p->>'offline_at', '') is not null and (p->>'offline_at')::timestamptz between now() - interval '2 days' and now() then
    -- an order kept on the phone while offline keeps the time it was taken (accepted up to 2 days back)
    v_at := (p->>'offline_at')::timestamptz;
  else
    v_at := now();
  end if;
  v_date := rsa_bdate(v_at);

  if v_edit_of is null and nullif(p->>'client_ref', '') is not null then
    select id into v_existing from orders where client_ref = p->>'client_ref';
    if found then return rsa_order_json(v_existing); end if;
  end if;
  select * into v_ch from channels where id = rsa_uuid(p, 'channel_id') and active;
  if not found then perform rsa_err('กรุณาเลือกช่องทางขาย'); end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then
    perform rsa_err('ยังไม่มีสินค้าในออเดอร์');
  end if;

  -- pass 1: check every line and price it for this channel
  for it in select * from jsonb_array_elements(p->'items') loop
    select * into v_prod from products where id = rsa_uuid(it, 'product_id') and active;
    if not found then perform rsa_err('ไม่พบสินค้า หรือสินค้าถูกปิดใช้งานแล้ว'); end if;
    v_qty := rsa_num(it, 'qty', 0);
    if v_qty <= 0 then perform rsa_err('จำนวนสินค้าต้องมากกว่า 0'); end if;
    if v_ch.kind = 'delivery' and not v_prod.delivery_enabled then
      perform rsa_err('"' || v_prod.name || '" ไม่ได้เปิดขายทาง Delivery');
    end if;
    v_price := case when v_ch.kind = 'delivery' and v_prod.delivery_price is not null then v_prod.delivery_price else v_prod.price end;
    -- evening markdown: storefront only, product must have a markdown price, from the set time (owner/manager any time)
    v_md := coalesce((it->>'markdown')::boolean, false);
    if v_md then
      if v_ch.kind <> 'storefront' then perform rsa_err('ราคาลดตอนเย็นใช้ได้เฉพาะหน้าร้าน'); end if;
      if v_prod.markdown_price is null or v_prod.markdown_price >= v_price then perform rsa_err('"' || v_prod.name || '" ยังไม่ได้ตั้งราคาลดตอนเย็น'); end if;
      if not rsa_has(u, 'master.manage') and (v_md_from is null or to_char(v_at at time zone 'Asia/Bangkok', 'HH24:MI') < v_md_from) then
        perform rsa_err('ยังไม่ถึงเวลาลดราคา' || coalesce(' (เริ่ม ' || v_md_from || ' น.)', ' เจ้าของร้านยังไม่ได้ตั้งเวลา'));
      end if;
    end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('product_id', v_prod.id, 'qty', v_qty, 'price', v_price,
                 'gross', round(v_price * v_qty, 2), 'discount', rsa_num(it, 'discount', 0), 'markdown', v_md,
                 'md_price', case when v_md then v_prod.markdown_price end));
  end loop;

  -- bundle promotions ("buy N for P"): quantities of the eligible products are pooled across the order,
  -- the discount is spread over those lines by value
  for v_promo in select * from promotions pr
                  where pr.active and pr.rule = 'bundle' and coalesce(pr.buy_qty, 0) > 0 and pr.bundle_price is not null
                    and (pr.starts_at is null or pr.starts_at <= v_at) and (pr.ends_at is null or pr.ends_at > v_at)
                    and (cardinality(pr.channel_ids) = 0 or v_ch.id = any(pr.channel_ids))
                    and (not pr.storefront_only or v_ch.kind = 'storefront')
                  order by pr.created_at loop
    select array_agg(t.ord::int order by t.ord), coalesce(sum((t.l->>'qty')::numeric), 0), coalesce(sum((t.l->>'gross')::numeric), 0)
      into v_idx, v_pool_qty, v_pool_gross
      from jsonb_array_elements(v_lines) with ordinality t(l, ord)
     where not (v_bdisc ? (t.ord - 1)::text) and not coalesce((t.l->>'markdown')::boolean, false)
       and (v_promo.scope = 'all' or (t.l->>'product_id')::uuid = any(v_promo.product_ids));
    if v_pool_qty <= 0 then continue; end if;
    v_bundles := floor(v_pool_qty / v_promo.buy_qty);
    if v_bundles < 1 then continue; end if;
    v_bd := round(v_bundles * v_promo.buy_qty * v_pool_gross / v_pool_qty - v_bundles * v_promo.bundle_price, 2);
    if v_bd <= 0 then continue; end if;
    v_rest := v_bd;
    for k in 1 .. array_length(v_idx, 1) loop
      if k = array_length(v_idx, 1) then v_share := v_rest;
      else v_share := round(v_bd * ((v_lines->(v_idx[k] - 1))->>'gross')::numeric / v_pool_gross, 2); end if;
      v_rest := v_rest - v_share;
      v_bdisc := v_bdisc || jsonb_build_object((v_idx[k] - 1)::text, jsonb_build_object('discount', v_share, 'promo_id', v_promo.id,
                   'name', v_promo.name, 'rule', 'bundle', 'buy_qty', v_promo.buy_qty, 'bundle_price', v_promo.bundle_price,
                   'bundles', v_bundles, 'pooled_qty', v_pool_qty));
    end loop;
  end loop;

  insert into order_counters(biz_date, n) values (v_date, 1)
  on conflict (biz_date) do update set n = order_counters.n + 1 returning n into v_n;
  v_no := 'S' || to_char(v_date, 'YYMMDD') || '-' || lpad(v_n::text, 3, '0');

  insert into orders(id, order_no, client_ref, biz_date, created_at, channel_id, channel_name, channel_kind, payment_method, account_id,
                     subtotal, total, fee_pct, note, created_by, replaces_order_id)
  values (v_id, v_no, case when v_edit_of is null then nullif(p->>'client_ref', '') end, v_date, v_at, v_ch.id, v_ch.name, v_ch.kind, v_ch.payment_method,
          case when v_ch.kind = 'storefront' then v_ch.account_id end, 0, 0, v_ch.fee_pct,
          nullif(concat_ws(' · ', nullif(trim(p->>'note'), ''),
            case when v_edit_of is null and v_edit_at is null and v_at < now() - interval '1 minute'
                 then 'บันทึกตอนไม่มีสัญญาณ ส่งเข้าระบบ ' || to_char(now() at time zone 'Asia/Bangkok', 'DD/MM HH24:MI') end), ''),
          u.id, v_edit_of);

  -- pass 2: discounts, cost and stock per line
  i := 0;
  for ln in select * from jsonb_array_elements(v_lines) loop
    select * into v_prod from products where id = (ln->>'product_id')::uuid;
    v_qty := (ln->>'qty')::numeric; v_price := (ln->>'price')::numeric; v_gross := (ln->>'gross')::numeric;
    v_pdisc := 0; v_promo_id := null; v_snap := null;
    if coalesce((ln->>'markdown')::boolean, false) then
      v_pdisc := round((v_price - (ln->>'md_price')::numeric) * v_qty, 2);
      v_snap := jsonb_build_object('name', 'ลดราคาตอนเย็น', 'rule', 'markdown', 'markdown_price', (ln->>'md_price')::numeric, 'promo_discount', v_pdisc);
    elsif v_bdisc ? i::text then
      v_pdisc := ((v_bdisc->i::text)->>'discount')::numeric;
      v_promo_id := ((v_bdisc->i::text)->>'promo_id')::uuid;
      v_snap := (v_bdisc->i::text) - 'discount' - 'promo_id' || jsonb_build_object('promo_discount', v_pdisc);
    else
      select * into v_promo from promotions pr
       where pr.active and pr.rule in ('percent','amount_each')
         and (pr.starts_at is null or pr.starts_at <= v_at) and (pr.ends_at is null or pr.ends_at > v_at)
         and (pr.scope = 'all' or v_prod.id = any(pr.product_ids))
         and (cardinality(pr.channel_ids) = 0 or v_ch.id = any(pr.channel_ids))
         and (not pr.storefront_only or v_ch.kind = 'storefront')
         and v_qty >= pr.min_qty
       order by case pr.rule when 'percent' then round(v_gross * pr.value / 100, 2) else least(pr.value, v_price) * v_qty end desc
       limit 1;
      if found then
        v_pdisc := case v_promo.rule when 'percent' then round(v_gross * v_promo.value / 100, 2) else round(least(v_promo.value, v_price) * v_qty, 2) end;
        v_promo_id := v_promo.id;
        v_snap := jsonb_build_object('name', v_promo.name, 'rule', v_promo.rule, 'value', v_promo.value, 'promo_discount', v_pdisc);
      end if;
    end if;
    v_mdisc := least(greatest(coalesce((ln->>'discount')::numeric, 0), 0), v_gross - v_pdisc);
    v_line := v_gross - v_pdisc - v_mdisc;

    -- cost and stock: only when a recipe/usage mapping exists
    v_linked := exists (select 1 from recipe_lines where product_id = v_prod.id);
    if v_linked then
      select sum(rl.qty * s.avg_cost), bool_or(s.avg_cost <= 0) into v_unit_cost, v_missing
        from recipe_lines rl join stock_items s on s.id = rl.stock_item_id where rl.product_id = v_prod.id;
      v_src := 'recipe';
      if v_missing then v_cost_ok := false; end if;
    elsif v_prod.est_cost is not null then
      v_unit_cost := v_prod.est_cost; v_src := 'manual';
    else
      v_unit_cost := null; v_src := 'none'; v_cost_ok := false;
    end if;

    v_item_id := gen_random_uuid();
    insert into order_items(id, order_id, product_id, product_name, sku, unit, qty, unit_price, discount, promo_id, promo_snapshot,
                            line_total, unit_cost, cost_source, stock_linked)
    values (v_item_id, v_id, v_prod.id, v_prod.name, v_prod.sku, v_prod.unit, v_qty, v_price, v_pdisc + v_mdisc, v_promo_id,
            case when v_snap is not null or v_mdisc > 0 then coalesce(v_snap, '{}'::jsonb)
                 || case when v_mdisc > 0 then jsonb_build_object('manual_discount', v_mdisc) else '{}'::jsonb end end,
            v_line, v_unit_cost, v_src, v_linked);

    if v_linked then
      for r in select rl.stock_item_id, rl.qty, s.avg_cost from recipe_lines rl join stock_items s on s.id = rl.stock_item_id
                where rl.product_id = v_prod.id loop
        insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
        values (r.stock_item_id, v_at, -(r.qty * v_qty), 'sale', 'order_item', v_item_id, r.avg_cost, u.id);
      end loop;
    end if;

    v_sub := v_sub + v_gross;
    v_disc := v_disc + v_pdisc + v_mdisc;
    v_cost := v_cost + coalesce(v_unit_cost, 0) * v_qty;
    i := i + 1;
  end loop;

  -- the amount actually received may differ from the computed total (rounding, short payment); it needs a reason
  v_calc := v_sub - v_disc;
  v_recv := coalesce(rsa_num(p, 'received_amount'), v_calc);
  if v_recv < 0 then perform rsa_err('ยอดรับจริงติดลบไม่ได้'); end if;
  if v_recv <> v_calc and coalesce(trim(p->>'received_note'), '') = '' then
    perform rsa_err('ยอดรับจริง (' || v_recv || ') ไม่เท่ากับยอดคำนวณ (' || v_calc || ' บาท) กรุณาใส่เหตุผล');
  end if;
  v_total := v_recv;
  update orders set subtotal = v_sub, discount = v_disc, calc_total = v_calc, total = v_total,
         received_note = case when v_recv <> v_calc then trim(p->>'received_note') end,
         cost_total = round(v_cost, 2), cost_complete = v_cost_ok,
         est_fee = case when v_ch.kind = 'delivery' then round(v_total * v_ch.fee_pct / 100, 2) else 0 end
   where id = v_id;

  -- money in: one row per payment (split cash + QR in one bill), or the channel's account
  if v_ch.kind = 'storefront' then
    v_pays := case when jsonb_typeof(p->'payments') = 'array' and jsonb_array_length(p->'payments') > 0 then p->'payments'
                   else jsonb_build_array(jsonb_build_object('account_id', v_ch.account_id, 'amount', v_total)) end;
    for v_pay in select * from jsonb_array_elements(v_pays) loop
      select * into v_pacc from payment_accounts where id = rsa_uuid(v_pay, 'account_id') and active;
      if not found then perform rsa_err('กรุณาเลือกบัญชีรับเงินของการจ่ายแต่ละส่วน'); end if;
      if rsa_num(v_pay, 'amount', 0) < 0 then perform rsa_err('ยอดจ่ายแต่ละส่วนติดลบไม่ได้'); end if;
      v_psum := v_psum + rsa_num(v_pay, 'amount', 0);
    end loop;
    if v_psum <> v_total then perform rsa_err('ยอดจ่ายรวม (' || v_psum || ') ไม่เท่ากับยอดรับจริง (' || v_total || ' บาท)'); end if;
    for v_pay in select * from jsonb_array_elements(v_pays) loop
      select * into v_pacc from payment_accounts where id = rsa_uuid(v_pay, 'account_id');
      if rsa_num(v_pay, 'amount', 0) > 0 then
        insert into order_payments(order_id, account_id, method, amount)
        values (v_id, v_pacc.id, case v_pacc.kind when 'cash' then 'cash' else 'qr' end, rsa_num(v_pay, 'amount', 0));
        perform rsa_money(v_pacc.id, 'in', rsa_num(v_pay, 'amount', 0), 'order', v_id, v_no, u.id, v_at);
      end if;
    end loop;
    if (select count(*) from order_payments where order_id = v_id) > 1 then
      update orders set payment_method = 'mixed',
             account_id = (select account_id from order_payments where order_id = v_id order by amount desc limit 1) where id = v_id;
    elsif exists (select 1 from order_payments where order_id = v_id and account_id is distinct from v_ch.account_id) then
      update orders set account_id = (select account_id from order_payments where order_id = v_id) where id = v_id;
    end if;
  end if;
  perform rsa_audit(u, 'order.create', 'order', v_id::text, null,
    jsonb_build_object('order_no', v_no, 'total', v_total, 'calc_total', v_calc, 'channel', v_ch.name, 'replaces', v_edit_of));
  return rsa_order_json(v_id);
end $$;

-- reverse money and stock of an order (cancel or edit); caller checks permission
create or replace function rsa_order_void(u app_users, v orders, p_reason text, p_replaced_by uuid default null) returns void language plpgsql as $$
declare v_amt numeric := v.total - v.refunded; r record;
begin
  update orders set status = 'cancelled', cancelled_at = now(), cancelled_by = u.id, cancel_reason = p_reason, replaced_by = p_replaced_by
   where id = v.id;
  insert into order_events(order_id, kind, amount, reason, account_id, created_by)
  values (v.id, 'cancel', v_amt, p_reason, v.account_id, u.id);
  -- give back what each account still holds for this order (split payments go back to where they came from)
  for r in select account_id, sum(case direction when 'in' then amount else -amount end) amt from money_ledger
            where source_id = v.id and source_type in ('order','order_refund') group by account_id loop
    if r.amt > 0 then
      perform rsa_money(r.account_id, 'out', r.amt, 'order_refund', v.id,
        case when p_replaced_by is null then 'ยกเลิก ' else 'แก้ไข ' end || v.order_no, u.id);
    end if;
  end loop;
  for r in select sl.* from stock_ledger sl join order_items i on i.id = sl.source_id
            where sl.source_type = 'order_item' and sl.kind = 'sale' and i.order_id = v.id loop
    insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
    values (r.stock_item_id, -r.qty, 'sale_reversal', 'order_item', r.source_id, r.unit_cost, u.id);
  end loop;
end $$;

create or replace function rsa__order_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v orders;
begin
  perform rsa_need(u, 'sales.add');
  select * into v from orders where id = rsa_uuid(p, 'order_id') for update;
  if not found then perform rsa_err('ไม่พบออเดอร์'); end if;
  if not rsa_order_can_edit(u, v) then perform rsa_need(u, 'sales.cancel'); end if;
  if v.status = 'cancelled' then perform rsa_err('ออเดอร์นี้ยกเลิกไปแล้ว'); end if;
  if v.settlement_id is not null then perform rsa_err('ออเดอร์นี้รับเงินจากแพลตฟอร์มแล้ว ให้ใช้การคืนเงินแทน'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  perform rsa_order_void(u, v, trim(p->>'reason'));
  perform rsa_audit(u, 'order.cancel', 'order', v.id::text, jsonb_build_object('status', v.status, 'total', v.total),
                    jsonb_build_object('status', 'cancelled', 'amount', v.total - v.refunded), jsonb_build_object('reason', p->>'reason', 'order_no', v.order_no,
                    'after_close', exists (select 1 from daily_closes where biz_date = v.biz_date)));
  return rsa_order_json(v.id);
end $$;

-- Edit = cancel the old order and record a corrected one with the same time; both stay in history.
create or replace function rsa__order_update(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v orders; v_new jsonb; v_reason text := trim(coalesce(p->>'reason', ''));
begin
  perform rsa_need(u, 'sales.add');
  select * into v from orders where id = rsa_uuid(p, 'order_id') for update;
  if not found then perform rsa_err('ไม่พบออเดอร์'); end if;
  if v.status = 'cancelled' then perform rsa_err('ออเดอร์นี้ถูกยกเลิกหรือแก้ไขไปแล้ว'); end if;
  if v.settlement_id is not null then perform rsa_err('ออเดอร์นี้รับเงินจากแพลตฟอร์มแล้ว แก้ไขไม่ได้'); end if;
  if v.refunded > 0 then perform rsa_err('ออเดอร์นี้มีการคืนเงินแล้ว แก้ไขไม่ได้'); end if;
  if exists (select 1 from daily_closes where biz_date = v.biz_date) then
    perform rsa_err('วันที่ ' || to_char(v.biz_date, 'DD/MM') || ' ส่งรายงานปิดยอดแล้ว แก้ไขออเดอร์ไม่ได้ ให้ยกเลิกแล้วแจ้งเจ้าของร้าน');
  end if;
  if not rsa_order_can_edit(u, v) then perform rsa_err('แก้ไขได้เฉพาะออเดอร์ของตัวเองในวันนี้ ถ้าต้องแก้รายการอื่นให้แจ้งเจ้าของร้าน'); end if;
  if v_reason = '' then perform rsa_err('กรุณาระบุเหตุผลการแก้ไข'); end if;
  perform set_config('rsa.edit_at', v.created_at::text, true);
  perform set_config('rsa.edit_of', v.id::text, true);
  v_new := rsa__order_create(u, p - 'order_id' - 'reason' - 'client_ref' - 'offline_at');
  perform set_config('rsa.edit_at', '', true);
  perform set_config('rsa.edit_of', '', true);
  perform rsa_order_void(u, v, 'แก้ไขเป็น ' || (v_new->>'order_no') || ': ' || v_reason, (v_new->>'id')::uuid);
  perform rsa_audit(u, 'order.update', 'order', v.id::text,
    jsonb_build_object('order_no', v.order_no, 'total', v.total, 'channel', v.channel_name,
      'items', (select jsonb_agg(jsonb_build_object('product', product_name, 'qty', qty, 'line_total', line_total)) from order_items where order_id = v.id)),
    jsonb_build_object('order_no', v_new->>'order_no', 'total', (v_new->>'total')::numeric, 'channel', v_new->>'channel_name',
      'items', (select jsonb_agg(jsonb_build_object('product', product_name, 'qty', qty, 'line_total', line_total)) from order_items where order_id = (v_new->>'id')::uuid)),
    jsonb_build_object('reason', v_reason));
  return rsa_order_json((v_new->>'id')::uuid);
end $$;

-- ---------------------------------------------------------------- waste (by product through its recipe, or by stock item)
create or replace function rsa_waste_insert(u app_users, p jsonb, p_close uuid default null) returns uuid language plpgsql as $$
declare v_item stock_items; v_prod products; v_id uuid := gen_random_uuid(); v_qty numeric := rsa_num(p, 'qty', 0);
        v_at timestamptz := rsa_ts(p, 'occurred_at'); v_cost numeric; r record;
        -- waste = spoiled/lost (a cost) · staff_meal = staff ate it (welfare expense) · owner_use = owner took it (owner drawing, not a shop cost)
        v_kind text := coalesce(nullif(p->>'kind', ''), 'waste'); v_for uuid := rsa_uuid(p, 'for_user_id'); v_reason text;
begin
  perform rsa_need(u, 'waste.add');
  if v_kind not in ('waste','staff_meal','owner_use') then perform rsa_err('ประเภทรายการไม่ถูกต้อง'); end if;
  if v_qty <= 0 then perform rsa_err('จำนวนต้องมากกว่า 0'); end if;
  v_reason := coalesce(nullif(trim(p->>'reason'), ''), case v_kind when 'staff_meal' then 'สวัสดิการทีมงาน' when 'owner_use' then 'เจ้าของหยิบใช้' end);
  if v_reason is null then perform rsa_err('กรุณาระบุสาเหตุของเสีย'); end if;
  if v_for is not null and not exists (select 1 from app_users where id = v_for) then perform rsa_err('ไม่พบพนักงาน'); end if;
  if v_kind <> 'staff_meal' then v_for := null; end if;
  if v_kind = 'waste' and rsa_setting_bool('waste_evidence_required') and not rsa_has_files(p) then
    perform rsa_err('ร้านกำหนดให้แนบรูปของเสียทุกครั้ง');
  end if;
  if rsa_uuid(p, 'product_id') is not null then
    select * into v_prod from products where id = rsa_uuid(p, 'product_id');
    if not found then perform rsa_err('ไม่พบสินค้า'); end if;
    select sum(rl.qty * s.avg_cost) into v_cost from recipe_lines rl join stock_items s on s.id = rl.stock_item_id where rl.product_id = v_prod.id;
    insert into waste_records(id, product_id, item_name, unit, qty, reason, unit_cost, occurred_at, biz_date, created_by, close_id, kind, for_user_id)
    values (v_id, v_prod.id, v_prod.name, v_prod.unit, v_qty, v_reason, coalesce(v_cost, v_prod.est_cost, 0), v_at, rsa_bdate(v_at), u.id, p_close, v_kind, v_for);
    for r in select rl.stock_item_id, rl.qty, s.avg_cost from recipe_lines rl join stock_items s on s.id = rl.stock_item_id where rl.product_id = v_prod.id loop
      insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
      values (r.stock_item_id, v_at, -(r.qty * v_qty), 'waste', 'waste', v_id, r.avg_cost, u.id);
    end loop;
  else
    select * into v_item from stock_items where id = rsa_uuid(p, 'stock_item_id') and active;
    if not found then perform rsa_err('กรุณาเลือกรายการที่เสีย'); end if;
    insert into waste_records(id, stock_item_id, item_name, unit, qty, reason, unit_cost, occurred_at, biz_date, created_by, close_id, kind, for_user_id)
    values (v_id, v_item.id, v_item.name, v_item.unit, v_qty, v_reason, v_item.avg_cost, v_at, rsa_bdate(v_at), u.id, p_close, v_kind, v_for);
    insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
    values (v_item.id, v_at, -v_qty, 'waste', 'waste', v_id, v_item.avg_cost, u.id);
  end if;
  perform rsa_link_attachments(p->'attachment_ids', 'waste', v_id, u);
  perform rsa_audit(u, 'waste.create', 'waste', v_id::text, null,
    jsonb_build_object('item', coalesce(v_prod.name, v_item.name), 'qty', v_qty, 'reason', v_reason, 'kind', v_kind, 'close_id', p_close));
  return v_id;
end $$;

create or replace function rsa__waste_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid;
begin
  v_id := rsa_waste_insert(u, p);
  return jsonb_build_object('id', v_id);
end $$;

create or replace function rsa__waste_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v waste_records; r record;
begin
  perform rsa_need(u, 'stock.cancel');
  select * into v from waste_records where id = rsa_uuid(p, 'waste_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update waste_records set status = 'cancelled', cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  for r in select * from stock_ledger where source_type = 'waste' and source_id = v.id and kind = 'waste' loop
    insert into stock_ledger(stock_item_id, qty, kind, source_type, source_id, unit_cost, created_by)
    values (r.stock_item_id, -r.qty, 'waste_reversal', 'waste', v.id, r.unit_cost, u.id);
  end loop;
  perform rsa_audit(u, 'waste.cancel', 'waste', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- expenses with fund source
-- fund_source: shop_cash | shop_bank | other_account | owner_advance | employee_advance | owner_capital | credit
-- (older clients may still send pay_mode: drawer | account | employee | later)
create or replace function rsa_expense_insert(u app_users, p jsonb, p_receipt uuid default null) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid(); v_cat expense_categories; v_status text; v_acc uuid; v_emp uuid; v_owner boolean := false;
  v_amt numeric := rsa_num(p, 'amount', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
  v_is_mgr boolean := rsa_has(u, 'expense.approve'); v_no text := rsa_next_no('E');
  v_src text := coalesce(nullif(p->>'fund_source', ''), case p->>'pay_mode' when 'drawer' then 'shop_cash' when 'account' then 'other_account'
                  when 'employee' then 'employee_advance' when 'later' then 'credit' end, 'credit');
  v_ref text := nullif(trim(coalesce(p->>'pay_ref', '')), ''); v_reviewed boolean := false;
begin
  perform rsa_need(u, 'expense.add');
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if coalesce(trim(p->>'description'), '') = '' then perform rsa_err('กรุณาระบุรายละเอียดค่าใช้จ่าย'); end if;
  select * into v_cat from expense_categories where id = rsa_uuid(p, 'category_id') and active;
  if not found then perform rsa_err('กรุณาเลือกหมวดค่าใช้จ่าย'); end if;
  if not v_is_mgr and not v_cat.staff_allowed then perform rsa_err('หมวด "' || v_cat.name || '" ต้องให้เจ้าของร้านบันทึก'); end if;
  if v_cat.grp = 'C' and coalesce(v_cat.c_kind, '') <> 'advance' then
    perform rsa_err('"' || v_cat.name || '" ไม่ใช่ค่าใช้จ่าย จึงไม่นับในกำไร บันทึกที่หน้า เงิน (ชำระหนี้ / เงินเติมจากเจ้าของ / เงินลงทุน / ประกาศใช้กำไร)');
  end if;
  if p_receipt is null and v_src <> 'credit' and rsa_setting_bool('evidence_required') and not rsa_has_files(p) then
    perform rsa_err('ร้านกำหนดให้แนบหลักฐานทุกครั้ง (ใบเสร็จ / สลิป / รูปบิล)');
  end if;

  if v_src = 'shop_cash' then
    v_acc := rsa_drawer(); v_status := 'จ่ายแล้ว';
    if v_acc is null then perform rsa_err('ยังไม่ได้ตั้งบัญชีลิ้นชักเงินสด'); end if;
  elsif v_src in ('shop_bank', 'other_account') then
    if v_src = 'other_account' then perform rsa_need(u, 'expense.pay'); end if;
    v_acc := coalesce(rsa_uuid(p, 'account_id'),
               case when v_src = 'shop_bank' then (select id from payment_accounts where active and kind = 'bank' order by created_at limit 1) end);
    if v_acc is null then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
    if not rsa_has(u, 'expense.pay') and v_acc is distinct from (select id from payment_accounts where active and kind = 'bank' order by created_at limit 1) then
      perform rsa_err('พนักงานเลือกจ่ายได้จากบัญชีร้านหลักเท่านั้น');
    end if;
    if v_ref is null then perform rsa_err('จ่ายผ่านบัญชีต้องใส่เลขอ้างอิง / เลขที่สลิป'); end if;
    v_status := 'จ่ายแล้ว';
  elsif v_src = 'employee_advance' then
    v_emp := coalesce(rsa_uuid(p, 'employee_id'), u.id);
    v_status := case when v_is_mgr then 'รอทำจ่าย' else 'รออนุมัติ' end;
  elsif v_src = 'owner_advance' then
    v_owner := true;
    v_status := case when v_is_mgr then 'รอทำจ่าย' else 'รออนุมัติ' end;
  elsif v_src = 'owner_capital' then
    perform rsa_need(u, 'cashflow.manage');
    v_status := 'จ่ายแล้ว';
  elsif v_src = 'credit' then
    v_status := case when v_is_mgr and coalesce((p->>'approve')::boolean, true) then 'รอทำจ่าย' else 'รออนุมัติ' end;
  else
    perform rsa_err('แหล่งเงินไม่ถูกต้อง');
  end if;
  v_reviewed := v_status = 'จ่ายแล้ว' and v_is_mgr;

  insert into expenses(id, expense_no, occurred_at, due_date, category_id, category_name, tax_category, payee, supplier_id, description, amount,
    status, pay_account_id, paid_by_employee, paid_by_owner, fund_source, pay_ref, doc_type, doc_no, ocr_snapshot, receipt_id, reviewed, created_by,
    approved_at, approved_by, paid_at, paid_by)
  values (v_id, v_no, v_at, nullif(p->>'due_date', '')::date, v_cat.id, v_cat.name, v_cat.tax_category, nullif(trim(p->>'payee'), ''),
    rsa_uuid(p, 'supplier_id'), trim(p->>'description'), v_amt, v_status, v_acc, v_emp, v_owner, v_src, v_ref,
    nullif(p->>'doc_type', ''), nullif(p->>'doc_no', ''),
    case when jsonb_typeof(p->'ocr_snapshot') = 'object' then p->'ocr_snapshot' end, p_receipt, v_reviewed, u.id,
    case when v_status = 'รอทำจ่าย' or v_reviewed then now() end,
    case when v_status = 'รอทำจ่าย' or v_reviewed then u.id end,
    case when v_status = 'จ่ายแล้ว' then v_at end,
    case when v_status = 'จ่ายแล้ว' then u.id end);

  if v_status = 'จ่ายแล้ว' and v_acc is not null then
    perform rsa_money(v_acc, 'out', v_amt, 'expense', v_id, trim(p->>'description'), u.id, v_at);
  end if;
  if v_cat.tax_category = 'เงินเบิกล่วงหน้าพนักงาน' then
    -- a wage advance: money leaves now, the cost is recognised when the weekly wage is paid
    if rsa_uuid(p, 'advance_user_id') is null or not exists (select 1 from app_users where id = rsa_uuid(p, 'advance_user_id')) then
      perform rsa_err('เบิกค่าแรงล่วงหน้า กรุณาเลือกพนักงานที่เบิก');
    end if;
    if v_status <> 'จ่ายแล้ว' then perform rsa_err('เบิกค่าแรงล่วงหน้าต้องจ่ายจากเงินสดหรือบัญชีร้าน'); end if;
    update expenses set advance_user_id = rsa_uuid(p, 'advance_user_id') where id = v_id;
  end if;
  if v_src = 'owner_capital' then
    -- the owner paid and does not want it back: it becomes owner capital (no cash moved in the shop)
    insert into capital_entries(kind, party, amount, occurred_at, account_id, note, created_by, expense_id, category)
    values ('owner_paid', coalesce(nullif(trim(p->>'owner_name'), ''), 'เจ้าของ'), v_amt, v_at, null, 'เจ้าของจ่ายแทนร้าน ' || v_no, u.id, v_id, 'จ่ายแทนร้าน');
  end if;
  perform rsa_link_attachments(p->'attachment_ids', 'expense', v_id, u);
  perform rsa_audit(u, 'expense.create', 'expense', v_id::text, null,
    jsonb_build_object('amount', v_amt, 'status', v_status, 'fund_source', v_src, 'category', v_cat.name));
  return v_id;
end $$;

create or replace function rsa_expense_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(e) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = e.created_by),
    'approved_by_name', (select display_name from app_users where id = e.approved_by),
    'paid_by_name', (select display_name from app_users where id = e.paid_by),
    'employee_name', (select display_name from app_users where id = e.paid_by_employee),
    'owed_to', case when e.paid_by_employee is not null then (select display_name from app_users where id = e.paid_by_employee)
                    when e.paid_by_owner then 'เจ้าของ' end,
    'account_name', (select name from payment_accounts where id = e.pay_account_id),
    'attachments', rsa_attachment_refs('expense', e.id) || coalesce(rsa_attachment_refs('receipt', e.receipt_id), '[]'))
  from expenses e where e.id = p_id
$$;

create or replace function rsa__expense_pay(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v expenses; v_acc payment_accounts; v_at timestamptz := rsa_ts(p, 'paid_at'); v_ref text := nullif(trim(coalesce(p->>'pay_ref', '')), '');
begin
  perform rsa_need(u, 'expense.pay');
  select * into v from expenses where id = rsa_uuid(p, 'expense_id') for update;
  if not found then perform rsa_err('ไม่พบรายการ'); end if;
  if v.status = 'รออนุมัติ' then
    perform rsa_need(u, 'expense.approve');
  elsif v.status <> 'รอทำจ่าย' then
    perform rsa_err('รายการนี้จ่ายไม่ได้ (สถานะ ' || v.status || ')');
  end if;
  if v.fixed_expense_id is not null and v.tax_category = 'เงินเดือนและค่าจ้าง' then
    perform rsa_err('บิลค่าจ้างให้จ่ายที่หน้า พนักงาน / ค่าจ้าง (จ่ายตามวันทำงานจริง แล้วระบบปิดบิลนี้ให้)');
  end if;
  select * into v_acc from payment_accounts where id = rsa_uuid(p, 'account_id') and active;
  if not found then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
  if v_acc.kind <> 'cash' and v_ref is null then perform rsa_err('จ่ายผ่านบัญชีต้องใส่เลขอ้างอิง / เลขที่สลิป'); end if;
  update expenses set status = 'จ่ายแล้ว', pay_account_id = v_acc.id, paid_at = v_at, paid_by = u.id, reviewed = true,
         pay_ref = coalesce(v_ref, pay_ref),
         approved_at = coalesce(approved_at, now()), approved_by = coalesce(approved_by, u.id),
         reimbursed = (paid_by_employee is not null or paid_by_owner) where id = v.id;
  perform rsa_money(v_acc.id, 'out', v.amount, 'expense', v.id,
    case when v.paid_by_employee is not null then 'คืนเงินพนักงาน: ' when v.paid_by_owner then 'คืนเงินเจ้าของ: ' else '' end || v.description, u.id, v_at);
  perform rsa_link_attachments(p->'attachment_ids', 'expense', v.id, u);
  perform rsa_audit(u, 'expense.pay', 'expense', v.id::text, jsonb_build_object('status', v.status),
                    jsonb_build_object('status', 'จ่ายแล้ว', 'account_id', v_acc.id, 'amount', v.amount, 'pay_ref', v_ref));
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
  if exists (select 1 from payroll_runs r where r.expense_id = v.id and r.status = 'done') then
    perform rsa_err('รายการนี้เป็นค่าจ้างที่จ่ายจากวันทำงาน ให้ยกเลิกที่หน้า พนักงาน › ประวัติจ่ายค่าจ้าง');
  end if;
  if v.advance_run_id is not null then perform rsa_err('เงินเบิกนี้ถูกหักในรอบจ่ายค่าจ้างแล้ว ให้ยกเลิกรอบจ่ายค่าจ้างก่อน'); end if;
  update expenses set status = 'ยกเลิก', cancelled_at = now(), cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  if v.status = 'จ่ายแล้ว' and v.pay_account_id is not null then
    perform rsa_money(v.pay_account_id, 'in', v.amount, 'expense_reversal', v.id, 'กลับรายการ ' || v.expense_no, u.id);
  end if;
  update capital_entries set status = 'cancelled', cancelled_by = u.id, cancel_reason = 'ยกเลิกค่าใช้จ่าย ' || v.expense_no
   where expense_id = v.id and status = 'done';
  perform rsa_audit(u, 'expense.cancel', 'expense', v.id::text, jsonb_build_object('status', v.status, 'amount', v.amount),
                    jsonb_build_object('status', 'ยกเลิก'), jsonb_build_object('reason', p->>'reason'));
  return rsa_expense_json(v.id);
end $$;

-- fixed costs: only confirmed ones become bills; monthly on the due day, weekly on every set weekday of the month (never twice)
create or replace function rsa_fixed_generate(u app_users, p_month date) returns int language plpgsql as $$
declare f fixed_expenses; v_m0 date := date_trunc('month', p_month)::date; v_m1 date; v_due date; v_period text; n int := 0;
begin
  v_m1 := (v_m0 + interval '1 month - 1 day')::date;
  for f in select * from fixed_expenses where active and confirmed and amount > 0 and start_month <= v_m1 and (end_month is null or end_month >= v_m0) loop
    for v_due in
      select d::date from generate_series(v_m0, v_m1, interval '1 day') d
       where (f.frequency = 'weekly' and extract(dow from d) = f.weekday)
          or (f.frequency = 'monthly' and d::date = least(v_m0 + (f.due_day - 1), v_m1))
    loop
      if v_due < f.start_month or (f.end_month is not null and v_due > (date_trunc('month', f.end_month) + interval '1 month - 1 day')::date) then continue; end if;
      v_period := case when f.frequency = 'weekly' then to_char(v_due, 'YYYY-MM-DD') else to_char(v_m0, 'YYYY-MM') end;
      -- a wage bill whose week was already paid from the workdays screen is not needed (payroll replaces it the same way)
      if exists (select 1 from expense_categories c where c.id = f.category_id and c.tax_category = 'เงินเดือนและค่าจ้าง')
         and exists (select 1 from payroll_runs r where r.status = 'done' and v_due between r.period_from and r.period_to + 6) then continue; end if;
      insert into expenses(id, expense_no, occurred_at, due_date, category_id, category_name, tax_category, payee, description, amount, status,
                           pay_account_id, fixed_expense_id, period, fund_source, created_by, approved_at, approved_by)
      select gen_random_uuid(), rsa_next_no('E'), (v_due::timestamp + time '12:00') at time zone 'Asia/Bangkok', v_due, f.category_id, c.name, c.tax_category, f.payee,
             f.name || ' (' || case when f.frequency = 'weekly' then 'สัปดาห์ ' || to_char(v_due, 'DD/MM') else v_period end || ')', f.amount,
             case when f.auto_approve then 'รอทำจ่าย' else 'รออนุมัติ' end, f.account_id, f.id, v_period, 'credit', u.id,
             case when f.auto_approve then now() end, case when f.auto_approve then u.id end
        from (select 1) one left join expense_categories c on c.id = f.category_id
      on conflict (fixed_expense_id, period) do nothing;
      if found then n := n + 1; end if;
    end loop;
  end loop;
  if n > 0 then perform rsa_audit(u, 'fixed.generate', 'fixed_expense', to_char(v_m0, 'YYYY-MM'), null, jsonb_build_object('created', n)); end if;
  return n;
end $$;

-- ---------------------------------------------------------------- stock receiving with transport allocation
-- pay_method: shop_bank | shop_cash | credit | none ; payer: shop | owner | employee
create or replace function rsa_receipt_default_category(p jsonb) returns uuid language sql stable as $$
  select coalesce(nullif(p->>'category_id', '')::uuid, nullif(p->'expense'->>'category_id', '')::uuid,
    (select id from expense_categories where active and code = 'A00'),
    (select id from expense_categories where active and tax_category = 'ต้นทุนสินค้า' order by name limit 1))
$$;

create or replace function rsa__receipt_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_id uuid := gen_random_uuid(); ln jsonb; v_item stock_items; v_qty numeric; v_lt numeric; v_goods numeric := 0; v_basis numeric; v_bsum numeric := 0;
  v_trans numeric := greatest(rsa_num(p, 'transport_cost', 0), 0); v_method text := coalesce(nullif(p->>'transport_method', ''), rsa_setting('transport_method', '"value"') #>> '{}', 'value');
  v_cur numeric; v_sup suppliers; v_exp uuid; v_at timestamptz := rsa_ts(p, 'received_at'); v_alloc numeric; v_rest numeric; v_landed numeric;
  v_pay text := coalesce(nullif(p->>'pay_method', ''), 'none'); v_payer text := coalesce(nullif(p->>'payer', ''), 'shop'); v_src text;
  v_n int; k int := 0; r record;
begin
  perform rsa_need(u, 'stock.receive');
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then perform rsa_err('ใส่รายการรับของอย่างน้อย 1 รายการ'); end if;
  if v_method not in ('value','weight','equal') then v_method := 'value'; end if;
  if rsa_setting_bool('evidence_required') and not rsa_has_files(p) then
    perform rsa_err('ร้านกำหนดให้แนบหลักฐานทุกครั้ง (ใบเสร็จ / บิล / รูปของที่รับ)');
  end if;
  select * into v_sup from suppliers where id = rsa_uuid(p, 'supplier_id');
  insert into stock_receipts(id, receipt_no, supplier_id, supplier_name, ref_no, received_at, note, transport_cost, transport_method, pay_method, payer, created_by)
  values (v_id, rsa_next_no('R'), v_sup.id, coalesce(v_sup.name, nullif(trim(p->>'supplier_name'), '')), nullif(p->>'ref_no', ''), v_at,
          nullif(p->>'note', ''), v_trans, v_method, v_pay, v_payer, u.id);

  -- pass 1: lines at purchase price
  for ln in select * from jsonb_array_elements(p->'lines') loop
    select * into v_item from stock_items where id = rsa_uuid(ln, 'stock_item_id') and active;
    if not found then perform rsa_err('ไม่พบรายการสต็อก'); end if;
    v_qty := rsa_num(ln, 'qty', 0);
    if v_qty <= 0 then perform rsa_err('จำนวนรับเข้าของ "' || v_item.name || '" ต้องมากกว่า 0'); end if;
    v_lt := coalesce(rsa_num(ln, 'line_total'), round(v_qty * rsa_num(ln, 'unit_cost', 0), 2));
    if v_lt < 0 then perform rsa_err('ราคาติดลบไม่ได้'); end if;
    insert into stock_receipt_lines(receipt_id, stock_item_id, item_name, unit, qty, unit_cost, line_total, weight)
    values (v_id, v_item.id, v_item.name, v_item.unit, v_qty, round(v_lt / v_qty, 4), v_lt, rsa_num(ln, 'weight'));
    v_goods := v_goods + v_lt;
  end loop;

  -- pass 2: spread transport over the lines (value / weight / equal), then landed cost into the moving average
  select count(*), coalesce(sum(case v_method when 'value' then line_total when 'weight' then coalesce(weight, qty) else 1 end), 0)
    into v_n, v_bsum from stock_receipt_lines where receipt_id = v_id;
  if v_bsum <= 0 then v_method := 'equal'; v_bsum := v_n; end if;
  v_rest := v_trans;
  for r in select * from stock_receipt_lines where receipt_id = v_id order by id loop
    k := k + 1;
    v_basis := case v_method when 'value' then r.line_total when 'weight' then coalesce(r.weight, r.qty) else 1 end;
    v_alloc := case when k = v_n then v_rest else round(v_trans * v_basis / v_bsum, 2) end;
    v_rest := v_rest - v_alloc;
    v_landed := round((r.line_total + v_alloc) / r.qty, 4);
    update stock_receipt_lines set transport_alloc = v_alloc, landed_unit_cost = v_landed where id = r.id;
    select * into v_item from stock_items where id = r.stock_item_id for update;
    if v_landed > 0 then
      v_cur := greatest(rsa_stock_qty(v_item.id), 0);
      update stock_items set avg_cost = round((v_cur * avg_cost + r.qty * v_landed) / (v_cur + r.qty), 4) where id = v_item.id;
    end if;
    insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
    values (v_item.id, v_at, r.qty, 'receipt', 'receipt', v_id, v_landed, u.id);
  end loop;
  update stock_receipts set goods_cost = v_goods, total_cost = v_goods + v_trans where id = v_id;
  perform rsa_link_attachments(p->'attachment_ids', 'receipt', v_id, u);

  -- the bill for this purchase (older clients send an "expense" object with pay_mode)
  v_src := case when v_payer = 'owner' then 'owner_advance' when v_payer = 'employee' then 'employee_advance'
                when v_pay = 'shop_bank' then 'shop_bank' when v_pay = 'shop_cash' then 'shop_cash'
                when v_pay in ('credit', 'unpaid') then 'credit' end;
  if v_src is null and jsonb_typeof(p->'expense') = 'object' and coalesce(p->'expense'->>'pay_mode', 'none') <> 'none' then
    v_src := case p->'expense'->>'pay_mode' when 'drawer' then 'shop_cash' when 'account' then 'other_account'
                  when 'employee' then 'employee_advance' else 'credit' end;
  end if;
  if v_src is not null and v_goods + v_trans > 0 then
    -- purchases are the shop's real cost: split by the cost category of each stock item; transport goes to the travel category
    for r in
      select coalesce(s.cost_category_id, rsa_receipt_default_category(p)) cat_id, sum(l.line_total) amt, string_agg(l.item_name, ', ' order by l.item_name) names
        from stock_receipt_lines l join stock_items s on s.id = l.stock_item_id where l.receipt_id = v_id
       group by 1
      union all
      select coalesce((select id from expense_categories where active and code = 'A05'), rsa_receipt_default_category(p)), v_trans, 'ค่าขนส่ง / ค่าเดินทางซื้อของ'
       where v_trans > 0
    loop
      continue when r.amt <= 0;
      v_exp := rsa_expense_insert(u, coalesce(case when jsonb_typeof(p->'expense') = 'object' then p->'expense' end, '{}'::jsonb) || jsonb_build_object(
        'fund_source', v_src, 'amount', r.amt, 'occurred_at', v_at, 'supplier_id', v_sup.id,
        'payee', coalesce(v_sup.name, p->>'supplier_name'), 'pay_ref', p->>'pay_ref', 'account_id', p->>'account_id', 'employee_id', p->>'employee_id',
        'category_id', r.cat_id,
        'description', 'ซื้อของเข้าร้าน ' || coalesce(v_sup.name, p->>'supplier_name', '') || ': ' || left(r.names, 120),
        'doc_no', p->>'ref_no'), v_id);
      update stock_receipts set expense_id = coalesce(expense_id, v_exp) where id = v_id;
    end loop;
  end if;
  perform rsa_audit(u, 'receipt.create', 'receipt', v_id::text, null,
    jsonb_build_object('goods', v_goods, 'transport', v_trans, 'method', v_method, 'lines', jsonb_array_length(p->'lines'), 'expense_id', v_exp, 'fund_source', v_src));
  return rsa_receipt_json(v_id);
end $$;

-- ---------------------------------------------------------------- daily close (6 steps)
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
          'est_fee', coalesce(sum(o.est_fee) filter (where o.status <> 'cancelled'), 0),
          'cancelled_orders', count(o.id) filter (where o.status = 'cancelled' and o.replaced_by is null),
          'cancelled_amount', coalesce(sum(o.total) filter (where o.status = 'cancelled' and o.replaced_by is null), 0),
          'edited_orders', count(o.id) filter (where o.replaced_by is not null)) x
        from channels c left join orders o on o.channel_id = c.id and o.biz_date = p_date
        where c.active or o.id is not null
        group by c.id) t),
    'products', (select coalesce(jsonb_agg(x order by x->>'sort'), '[]') from (
        select jsonb_build_object('product_id', pr.id, 'name', pr.name, 'emoji', pr.emoji, 'unit', pr.unit, 'category', pr.category,
          'sort', lpad(pr.sort_order::text, 4, '0') || pr.name,
          'storefront_qty', coalesce(sum(i.qty) filter (where o.channel_kind = 'storefront'), 0),
          'storefront_net', coalesce(sum(i.line_total) filter (where o.channel_kind = 'storefront'), 0),
          'delivery_qty', coalesce(sum(i.qty) filter (where o.channel_kind = 'delivery'), 0),
          'delivery_net', coalesce(sum(i.line_total) filter (where o.channel_kind = 'delivery'), 0)) x
        from products pr
        left join order_items i on i.product_id = pr.id
             and exists (select 1 from orders o2 where o2.id = i.order_id and o2.biz_date = p_date and o2.status <> 'cancelled')
        left join orders o on o.id = i.order_id
        where pr.active or i.id is not null
        group by pr.id) t),
    'total_net', (select coalesce(sum(total - refunded), 0) from orders where biz_date = p_date and status <> 'cancelled'),
    'orders_count', (select count(*) from orders where biz_date = p_date and status <> 'cancelled'),
    'storefront_net', (select coalesce(sum(total - refunded), 0) from orders where biz_date = p_date and status <> 'cancelled' and channel_kind = 'storefront'),
    'delivery_net', (select coalesce(sum(total - refunded), 0) from orders where biz_date = p_date and status <> 'cancelled' and channel_kind = 'delivery'),
    -- money that went to accounts other than the drawer (QR / transfer), including the QR part of split bills
    'qr_sales', (select coalesce(sum(case m.direction when 'in' then m.amount else -m.amount end), 0)
                   from money_ledger m join orders o on o.id = m.source_id
                  where m.source_type in ('order','order_refund') and o.biz_date = p_date and o.channel_kind = 'storefront'
                    and m.account_id is distinct from v_drawer),
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
                      from expenses e where e.pay_account_id = v_drawer and e.status = 'จ่ายแล้ว' and rsa_bdate(e.paid_at) = p_date),
    'advance_rows', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'expense_no', e.expense_no, 'description', e.description,
                        'amount', e.amount, 'status', e.status, 'owed_to', coalesce((select display_name from app_users where id = e.paid_by_employee), 'เจ้าของ'))
                        order by e.occurred_at), '[]')
                      from expenses e where (e.paid_by_employee is not null or e.paid_by_owner) and e.status <> 'ยกเลิก' and rsa_bdate(e.occurred_at) = p_date),
    'waste_rows', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'item_name', w.item_name, 'product_id', w.product_id, 'qty', w.qty, 'unit', w.unit,
                        'reason', w.reason, 'kind', w.kind, 'status', w.status, 'cost', round(w.qty * w.unit_cost, 2)) order by w.occurred_at), '[]')
                      from waste_records w where w.biz_date = p_date and w.status = 'recorded')
  ) into v;
  return v || jsonb_build_object('expected_cash',
     (v->>'starting_cash')::numeric + (v->>'cash_in_orders')::numeric - (v->>'cash_out_refunds')::numeric
     - (v->>'cash_out_expenses')::numeric - (v->>'cash_transfers_net_out')::numeric + (v->>'cash_other_adjust')::numeric);
end $$;

create or replace function rsa__close_preview(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_date date := rsa_date(p, 'date'); v_close uuid;
begin
  if not (rsa_has(u, 'closing.add') or rsa_has(u, 'closing.view_all')) then perform rsa_need(u, 'closing.add'); end if;
  select id into v_close from daily_closes where biz_date = v_date;
  return jsonb_build_object('computed', rsa_close_compute(v_date),
    'close', case when v_close is not null then rsa_close_json(v_close) end,
    'stock', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'unit', s.unit, 'code', s.code,
                'system_qty', rsa_stock_qty(s.id)) order by s.code nulls last, s.name), '[]')
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

create or replace function rsa__close_submit(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_date date := rsa_date(p, 'date'); c jsonb; v_id uuid := gen_random_uuid(); v_start numeric; v_sys_start numeric;
  v_counted numeric := rsa_num(p, 'counted_cash'); v_expected numeric; v_var numeric; v_adj numeric; v_st uuid;
  v_tol numeric := rsa_setting_num('cash_variance_tolerance', 0);
  v_due text := coalesce(rsa_setting('close_due_time') #>> '{}', '21:00');
  v_adjs jsonb := coalesce(p->'adjustments', '[]');
  v_removed numeric := greatest(rsa_num(p, 'cash_removed', 0), 0); v_to payment_accounts; v_tr uuid; v_tr_at timestamptz;
  v_cash_sys numeric; v_cash_rep numeric; v_qr_rep numeric; ln jsonb; v_pc jsonb := '[]'; v_dc jsonb := '[]'; v_on_time boolean; x jsonb;
begin
  perform rsa_need(u, 'closing.add');
  perform pg_advisory_xact_lock(hashtext('close' || v_date));
  if exists (select 1 from daily_closes where biz_date = v_date) then
    perform rsa_err('วันที่ ' || to_char(v_date, 'DD/MM/YYYY') || ' ส่งรายงานปิดยอดแล้ว หากต้องแก้ไขให้เจ้าของร้านแก้ในหน้าประวัติ');
  end if;
  if v_date > rsa_today() then perform rsa_err('ยังปิดยอดล่วงหน้าไม่ได้'); end if;
  if v_counted is null or v_counted < 0 then perform rsa_err('กรุณาใส่ยอดเงินสดที่นับได้จริง'); end if;

  -- step 3: waste found at closing becomes waste records (stock is cut now)
  for ln in select * from jsonb_array_elements(coalesce(p->'waste_lines', '[]')) loop
    if rsa_num(ln, 'qty', 0) > 0 then perform rsa_waste_insert(u, ln || jsonb_build_object('occurred_at',
         case when v_date < rsa_today() then (v_date + time '23:59')::timestamp at time zone 'Asia/Bangkok' else now() end), v_id); end if;
  end loop;

  -- step 5 (part): cash taken out of the shop is a transfer to a named account, never money that just disappears
  if v_removed > 0 then
    select * into v_to from payment_accounts where id = rsa_uuid(p, 'cash_removed_to') and active and not is_drawer;
    if not found then perform rsa_err('เงินสดนำออก ' || v_removed || ' บาท กรุณาเลือกว่านำไปเข้าบัญชีไหน'); end if;
    v_tr := gen_random_uuid();
    v_tr_at := case when v_date < rsa_today() then (v_date + time '23:59')::timestamp at time zone 'Asia/Bangkok' else now() end;
    insert into transfers(id, from_account, to_account, amount, occurred_at, reason, created_by)
    values (v_tr, rsa_drawer(), v_to.id, v_removed, v_tr_at,
            'นำเงินสดออกตอนปิดยอด ' || to_char(v_date, 'DD/MM/YYYY') || coalesce(' · ' || nullif(trim(p->>'cash_removed_note'), ''), ''), u.id);
    perform rsa_money(rsa_drawer(), 'out', v_removed, 'transfer', v_tr, 'นำเงินสดออก → ' || v_to.name, u.id, v_tr_at);
    perform rsa_money(v_to.id, 'in', v_removed, 'transfer', v_tr, 'เงินสดจากหน้าร้าน ' || to_char(v_date, 'DD/MM'), u.id, v_tr_at);
  end if;

  c := rsa_close_compute(v_date);
  v_sys_start := (c->>'starting_cash')::numeric;
  v_start := coalesce(rsa_num(p, 'starting_cash'), v_sys_start);
  if v_start <> v_sys_start then
    if coalesce(trim(p->>'starting_cash_reason'), '') = '' then perform rsa_err('แก้เงินทอนต้นวันต้องใส่เหตุผล'); end if;
    v_adjs := v_adjs || jsonb_build_array(jsonb_build_object('field', 'starting_cash', 'label', 'เงินทอนต้นวัน',
               'original', v_sys_start, 'corrected', v_start, 'reason', p->>'starting_cash_reason'));
  end if;
  -- step 5: cash the customers paid; a correction to the system figure is kept with its reason
  -- net of cancellations / refunds paid back in cash, i.e. what customers really left in the drawer
  v_cash_sys := (c->>'cash_in_orders')::numeric - (c->>'cash_out_refunds')::numeric;
  v_cash_rep := coalesce(rsa_num(p, 'cash_sales'), v_cash_sys);
  if v_cash_rep <> v_cash_sys then
    if coalesce(trim(p->>'cash_sales_reason'), '') = '' then perform rsa_err('ยอดเงินสดที่ลูกค้าจ่ายไม่ตรงกับออเดอร์ (' || v_cash_sys || ' บาท) กรุณาใส่เหตุผล'); end if;
    v_adjs := v_adjs || jsonb_build_array(jsonb_build_object('field', 'cash_sales', 'label', 'เงินสดที่ลูกค้าจ่าย',
               'original', v_cash_sys, 'corrected', v_cash_rep, 'reason', p->>'cash_sales_reason'));
  end if;
  v_qr_rep := rsa_num(p, 'qr_sales');
  if v_qr_rep is not null and v_qr_rep <> (c->>'qr_sales')::numeric then
    if coalesce(trim(p->>'qr_sales_reason'), '') = '' then perform rsa_err('ยอด QR / โอน ไม่ตรงกับออเดอร์ (' || (c->>'qr_sales') || ' บาท) กรุณาใส่เหตุผล'); end if;
    v_adjs := v_adjs || jsonb_build_array(jsonb_build_object('field', 'qr_sales', 'label', 'ยอด QR / โอน',
               'original', (c->>'qr_sales')::numeric, 'corrected', v_qr_rep, 'reason', p->>'qr_sales_reason'));
  end if;
  v_expected := (c->>'expected_cash')::numeric - v_sys_start + v_start - v_cash_sys + v_cash_rep;
  v_var := v_counted - v_expected;
  if abs(v_var) > v_tol and coalesce(trim(p->>'variance_reason'), '') = '' then
    perform rsa_err('เงินสด' || case when v_var < 0 then 'ขาด ' else 'เกิน ' end || abs(v_var) || ' บาท (เกินเกณฑ์ ' || v_tol || ' บาท) กรุณาใส่คำอธิบาย');
  end if;

  -- step 1 and 2: what staff counted per product (storefront) and per platform (delivery), next to the system figures
  for ln in select * from jsonb_array_elements(coalesce(p->'product_counts', '[]')) loop
    x := null;
    select x0 into x from jsonb_array_elements(c->'products') x0 where x0->>'product_id' = ln->>'product_id';
    if x is null or nullif(ln->>'counted_qty', '') is null then continue; end if;
    v_pc := v_pc || jsonb_build_array(jsonb_build_object('product_id', x->>'product_id', 'name', x->>'name', 'unit', x->>'unit',
              'system_qty', (x->>'storefront_qty')::numeric, 'counted_qty', rsa_num(ln, 'counted_qty'),
              'diff', rsa_num(ln, 'counted_qty') - (x->>'storefront_qty')::numeric, 'note', nullif(trim(ln->>'note'), '')));
  end loop;
  for ln in select * from jsonb_array_elements(coalesce(p->'delivery_counts', '[]')) loop
    x := null;
    select x0 into x from jsonb_array_elements(c->'channels') x0 where x0->>'channel_id' = ln->>'channel_id' and x0->>'kind' = 'delivery';
    if x is null then continue; end if;
    v_dc := v_dc || jsonb_build_array(jsonb_build_object('channel_id', x->>'channel_id', 'name', x->>'name',
              'system_orders', (x->>'orders')::int, 'app_orders', rsa_num(ln, 'orders'),
              'system_gross', (x->>'net')::numeric, 'app_gross', rsa_num(ln, 'gross'),
              'diff', coalesce(rsa_num(ln, 'gross'), (x->>'net')::numeric) - (x->>'net')::numeric, 'note', nullif(trim(ln->>'note'), '')));
  end loop;

  -- step 4: raw material counts go to the owner as a stocktake to approve
  if jsonb_typeof(p->'stock_counts') = 'array' and jsonb_array_length(p->'stock_counts') > 0 and rsa_has(u, 'stock.count') then
    v_st := rsa_stocktake_insert(u, 'close', p->'stock_counts', 'นับตอนปิดยอด ' || to_char(v_date, 'DD/MM/YYYY'), v_id);
  end if;

  v_on_time := v_date = rsa_today() and to_char(now() at time zone 'Asia/Bangkok', 'HH24:MI') <= v_due;

  insert into daily_closes(id, biz_date, submitted_by, coworker_ids, summary, starting_cash, cash_sales, cash_refunds, cash_expenses,
    cash_transfers_out, expected_cash, counted_cash, variance, variance_reason, stock_note, note, adjustments, stocktake_id,
    product_counts, delivery_counts, cash_detail, cash_removed, cash_removed_to, transfer_id, on_time)
  values (v_id, v_date, u.id,
    coalesce((select array_agg(distinct (x1)::uuid) from jsonb_array_elements_text(coalesce(p->'coworker_ids', '[]')) x1 where (x1)::uuid <> u.id), '{}'),
    c, v_start, v_cash_rep, (c->>'cash_out_refunds')::numeric, (c->>'cash_out_expenses')::numeric,
    (c->>'cash_transfers_net_out')::numeric, v_expected, v_counted, v_var, nullif(trim(p->>'variance_reason'), ''),
    nullif(p->>'stock_note', ''), nullif(trim(p->>'note'), ''), v_adjs, v_st, v_pc, v_dc,
    jsonb_build_object('cash_sales_system', v_cash_sys, 'cash_sales', v_cash_rep, 'qr_system', (c->>'qr_sales')::numeric, 'qr_sales', coalesce(v_qr_rep, (c->>'qr_sales')::numeric),
      'store_spent', (c->>'cash_out_expenses')::numeric, 'removed', v_removed, 'removed_to', v_to.name, 'removed_note', nullif(trim(p->>'cash_removed_note'), ''),
      'float', rsa_setting_num('starting_float', 0), 'tolerance', v_tol, 'due_time', v_due),
    v_removed, v_to.id, v_tr, v_on_time);

  -- The drawer balance follows the counted cash; the difference stays visible as an adjustment entry.
  v_adj := v_counted - (c->>'expected_cash')::numeric;
  if v_adj <> 0 then
    perform rsa_money((c->>'drawer_account')::uuid, case when v_adj > 0 then 'in' else 'out' end, abs(v_adj), 'adjustment', v_id,
      'ผลต่างเงินสดจากการปิดยอด ' || to_char(v_date, 'DD/MM/YYYY'), u.id, now());
    update money_ledger set biz_date = v_date where source_type = 'adjustment' and source_id = v_id;
  end if;
  perform rsa_audit(u, 'close.submit', 'daily_close', v_id::text, null,
    jsonb_build_object('biz_date', v_date, 'expected', v_expected, 'counted', v_counted, 'variance', v_var, 'removed', v_removed,
      'on_time', v_on_time, 'adjustments', v_adjs));
  return rsa_close_json(v_id);
end $$;

-- Workday rule: each submitted daily close counts one workday for the submitter and every co-worker named on it
-- (at most once per person per date). On time / late is counted for the person who submitted.
create or replace function rsa__close_workdays(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', date_trunc('month', rsa_today())::date); v_to date := rsa_date(p, 'to');
        v_all boolean := rsa_has(u, 'closing.view_all') and not coalesce((p->>'mine')::boolean, false);
begin
  if not (rsa_has(u, 'closing.add') or rsa_has(u, 'closing.view_all')) then perform rsa_need(u, 'closing.add'); end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('user_id', w.user_id, 'display_name', x.display_name, 'days', w.days, 'dates', w.dates,
                   'submitted', w.submitted, 'on_time', w.on_time, 'late', w.late, 'variance_days', w.variance_days) order by x.display_name), '[]')
    from (select user_id, count(distinct biz_date) days, jsonb_agg(distinct biz_date) dates,
                 count(*) filter (where is_submitter) submitted,
                 count(*) filter (where is_submitter and on_time) on_time,
                 count(*) filter (where is_submitter and on_time is not true) late,
                 count(*) filter (where is_submitter and variance <> 0) variance_days
            from (select d.biz_date, d.submitted_by user_id, true is_submitter, d.on_time, d.variance from daily_closes d where d.biz_date between v_from and v_to
                  union all
                  select d.biz_date, cw, false, d.on_time, d.variance from daily_closes d, unnest(d.coworker_ids) cw where d.biz_date between v_from and v_to) s
           group by user_id) w join app_users x on x.id = w.user_id
    where v_all or w.user_id = u.id);
end $$;

-- ==================== 08_detail_reports.sql
-- RSA - POS Assistant : detail upgrade (period reports, bank lines, investment / payback, profit uses,
-- cash forecast, settings, exports, API entry point)
set check_function_bodies = off;

-- ---------------------------------------------------------------- period KPIs
create or replace function rsa_kpi(p_from date, p_to date) returns jsonb language sql stable as $$
  with o as (
    select coalesce(sum(total - refunded), 0) revenue,
           coalesce(sum(total - refunded) filter (where channel_kind = 'storefront'), 0) storefront,
           coalesce(sum(total - refunded) filter (where channel_kind = 'delivery'), 0) delivery,
           count(*) orders, coalesce(sum(discount), 0) discount
      from orders where status <> 'cancelled' and biz_date between p_from and p_to),
  md as (select coalesce(sum(i.discount), 0) markdown from order_items i join orders o on o.id = i.order_id
          where o.status <> 'cancelled' and o.biz_date between p_from and p_to and i.promo_snapshot->>'rule' = 'markdown'),
  pr as (select rsa_profit(p_from, p_to) j),
  d as (select coalesce(sum(variance), 0) variance, count(*) closes, count(*) filter (where on_time) on_time,
               count(*) filter (where variance <> 0) variance_days
          from daily_closes where biz_date between p_from and p_to)
  select jsonb_build_object('from', p_from, 'to', p_to,
    'revenue', o.revenue, 'storefront', o.storefront, 'delivery', o.delivery, 'orders', o.orders, 'discount', o.discount, 'markdown', md.markdown,
    'avg_ticket', case when o.orders > 0 then round(o.revenue / o.orders, 2) else 0 end,
    'gross_profit', (pr.j->>'gross_profit')::numeric, 'net_profit', (pr.j->>'net_profit')::numeric,
    'margin_pct', case when o.revenue > 0 then round((pr.j->>'gross_profit')::numeric * 100 / o.revenue, 1) end,
    'waste', (pr.j->>'waste')::numeric,
    'waste_pct', case when o.revenue > 0 then round((pr.j->>'waste')::numeric * 100 / o.revenue, 1) end,
    'staff_meals', (pr.j->>'staff_meals')::numeric, 'owner_use', (pr.j->>'owner_use')::numeric,
    'expenses', (pr.j->>'expenses')::numeric, 'var_costs', (pr.j->>'var_costs')::numeric, 'fixed_costs', (pr.j->>'fixed_costs')::numeric,
    'cash_variance', d.variance, 'closes', d.closes, 'on_time', d.on_time, 'variance_days', d.variance_days,
    'profit_complete', pr.j->'complete', 'profit_flags', pr.j->'flags')
  from o, md, pr, d
$$;

create or replace function rsa_owed_reimburse() returns numeric language sql stable as $$
  select coalesce(sum(amount), 0) from expenses where (paid_by_employee is not null or paid_by_owner) and status in ('รออนุมัติ','รอทำจ่าย')
$$;

create or replace function rsa_cash_total() returns numeric language sql stable as $$
  select coalesce(sum(rsa_account_balance(id)), 0) from payment_accounts where active
$$;

create or replace function rsa_delivery_receivable() returns numeric language sql stable as $$
  select coalesce(sum(total - refunded - est_fee), 0) from orders where channel_kind = 'delivery' and status <> 'cancelled' and settlement_id is null
$$;

create or replace function rsa__report_overview(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 6); v_to date := rsa_date(p, 'to'); v_n int; v_pf date; v_pt date;
        v_month date := date_trunc('month', rsa_today())::date;
begin
  perform rsa_need(u, 'report.view');
  if v_to < v_from then perform rsa_err('ช่วงวันที่ไม่ถูกต้อง'); end if;
  v_n := v_to - v_from + 1; v_pt := v_from - 1; v_pf := v_from - v_n;
  return jsonb_build_object('from', v_from, 'to', v_to, 'days', v_n, 'prev_from', v_pf, 'prev_to', v_pt,
    'kpi', rsa_kpi(v_from, v_to),
    'prev', rsa_kpi(v_pf, v_pt),
    'now', jsonb_build_object(
      'cash', rsa_cash_total(),
      'drawer', rsa_account_balance(rsa_drawer()),
      'delivery_receivable', rsa_delivery_receivable(),
      'owed_reimburse', rsa_owed_reimburse(),
      'payables', (select coalesce(sum(amount), 0) from expenses where status in ('รออนุมัติ','รอทำจ่าย')),
      'low_stock', (select count(*) from stock_items s where s.active and s.min_qty > 0 and rsa_stock_qty(s.id) <= s.min_qty),
      'min_working_capital', rsa_setting_num('min_working_capital', 0),
      'profit_target', rsa_setting_num('profit_target', 0),
      'profit_target_confirmed', coalesce((select confirmed from settings where key = 'profit_target'), false),
      'month_net_profit', (rsa_profit(v_month, rsa_today())->>'net_profit')::numeric),
    'series', (select jsonb_agg(jsonb_build_object('date', d::date,
        'storefront', coalesce((select sum(total - refunded) from orders where biz_date = d::date and status <> 'cancelled' and channel_kind = 'storefront'), 0),
        'delivery', coalesce((select sum(total - refunded) from orders where biz_date = d::date and status <> 'cancelled' and channel_kind = 'delivery'), 0),
        'orders', (select count(*) from orders where biz_date = d::date and status <> 'cancelled')) order by d)
      from generate_series(v_from, v_to, interval '1 day') d),
    'channels', (select coalesce(jsonb_agg(jsonb_build_object('name', c.channel_name, 'kind', c.kind, 'net', c.net, 'orders', c.n) order by c.net desc), '[]')
      from (select channel_name, max(channel_kind) kind, sum(total - refunded) net, count(*) n from orders
             where status <> 'cancelled' and biz_date between v_from and v_to group by channel_name) c),
    'top_products', (select coalesce(jsonb_agg(x order by (x->>'revenue')::numeric desc), '[]') from (
       select jsonb_build_object('product_id', i.product_id, 'name', max(i.product_name), 'emoji', max(pr.emoji), 'qty', sum(i.qty), 'revenue', sum(i.line_total)) x
         from order_items i join orders o on o.id = i.order_id left join products pr on pr.id = i.product_id
        where o.status <> 'cancelled' and o.biz_date between v_from and v_to
        group by i.product_id order by sum(i.line_total) desc limit 5) t));
end $$;

create or replace function rsa__report_products(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 29); v_to date := rsa_date(p, 'to'); v_days int;
begin
  perform rsa_need(u, 'report.view');
  v_days := rsa_open_days(v_from, v_to);
  return jsonb_build_object('from', v_from, 'to', v_to, 'open_days', v_days, 'days', v_to - v_from + 1,
    'products', (select coalesce(jsonb_agg(x order by (x->>'revenue')::numeric desc), '[]') from (
       select jsonb_build_object('product_id', pr.id, 'name', pr.name, 'emoji', pr.emoji, 'sku', pr.sku, 'category', pr.category, 'unit', pr.unit,
         'price', pr.price, 'delivery_price', pr.delivery_price, 'active', pr.active,
         'qty', coalesce(sum(i.qty), 0), 'revenue', coalesce(sum(i.line_total), 0),
         'storefront_qty', coalesce(sum(i.qty) filter (where o.channel_kind = 'storefront'), 0),
         'delivery_qty', coalesce(sum(i.qty) filter (where o.channel_kind = 'delivery'), 0),
         'discount', coalesce(sum(i.discount), 0),
         'markdown_qty', coalesce(sum(i.qty) filter (where i.promo_snapshot->>'rule' = 'markdown'), 0),
         'markdown_discount', coalesce(sum(i.discount) filter (where i.promo_snapshot->>'rule' = 'markdown'), 0),
         'cost', coalesce(sum(coalesce(i.unit_cost, 0) * i.qty), 0),
         'gross_profit', coalesce(sum(i.line_total - coalesce(i.unit_cost, 0) * i.qty), 0),
         'margin_pct', case when coalesce(sum(i.line_total), 0) > 0
                          then round(sum(i.line_total - coalesce(i.unit_cost, 0) * i.qty) * 100 / sum(i.line_total), 1) end,
         'avg_per_day', round(coalesce(sum(i.qty), 0) / v_days, 2),
         'cost_known', coalesce(bool_and(i.cost_source <> 'none'), exists (select 1 from recipe_lines r where r.product_id = pr.id) or pr.est_cost is not null),
         'has_recipe', exists (select 1 from recipe_lines r where r.product_id = pr.id),
         'waste_qty', (select coalesce(sum(w.qty), 0) from waste_records w where w.product_id = pr.id and w.status = 'recorded' and w.kind = 'waste' and w.biz_date between v_from and v_to)) x
       from products pr
       left join order_items i on i.product_id = pr.id
            and exists (select 1 from orders o2 where o2.id = i.order_id and o2.status <> 'cancelled' and o2.biz_date between v_from and v_to)
       left join orders o on o.id = i.order_id
       where pr.active or i.id is not null
       group by pr.id) t),
    'waste', (select coalesce(jsonb_agg(x order by (x->>'cost')::numeric desc), '[]') from (
       select jsonb_build_object('item', item_name, 'kind', kind, 'unit', max(unit), 'qty', sum(qty), 'cost', round(sum(qty * unit_cost), 2), 'times', count(*),
         'reasons', jsonb_agg(distinct reason)) x
       from waste_records where status = 'recorded' and biz_date between v_from and v_to group by item_name, kind) t),
    'used', (select jsonb_build_object(
       'waste', coalesce(round(sum(qty * unit_cost) filter (where kind = 'waste'), 2), 0),
       'staff_meal', coalesce(round(sum(qty * unit_cost) filter (where kind = 'staff_meal'), 2), 0),
       'owner_use', coalesce(round(sum(qty * unit_cost) filter (where kind = 'owner_use'), 2), 0))
       from waste_records where status = 'recorded' and biz_date between v_from and v_to),
    'markdown', (select jsonb_build_object('lines', count(*), 'qty', coalesce(sum(i.qty), 0), 'discount', coalesce(sum(i.discount), 0))
         from order_items i join orders o on o.id = i.order_id
        where o.status <> 'cancelled' and o.biz_date between v_from and v_to and i.promo_snapshot->>'rule' = 'markdown'),
    'promotions', (select coalesce(jsonb_agg(x), '[]') from (
       select jsonb_build_object('name', i.promo_snapshot->>'name', 'lines', count(*), 'discount', sum(coalesce((i.promo_snapshot->>'promo_discount')::numeric, 0))) x
         from order_items i join orders o on o.id = i.order_id
        where o.status <> 'cancelled' and o.biz_date between v_from and v_to and i.promo_snapshot ? 'name'
          and coalesce(i.promo_snapshot->>'rule', '') <> 'markdown'
        group by i.promo_snapshot->>'name') t));
end $$;

create or replace function rsa__report_delivery(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 29); v_to date := rsa_date(p, 'to');
begin
  perform rsa_need(u, 'report.view');
  return jsonb_build_object('from', v_from, 'to', v_to,
    'rows', (select coalesce(jsonb_agg(x order by x->>'date' desc, x->>'channel'), '[]') from (
       select jsonb_build_object('date', o.biz_date, 'channel_id', o.channel_id, 'channel', o.channel_name, 'orders', count(*),
         'gross', sum(o.total - o.refunded), 'est_fee', sum(o.est_fee), 'est_net', sum(o.total - o.refunded - o.est_fee),
         'fee_pct', max(o.fee_pct), 'expected_date', o.biz_date + max(c.settlement_days),
         'settled_orders', count(*) filter (where o.settlement_id is not null),
         'status', case when bool_and(o.settlement_id is not null) then 'รับเงินแล้ว'
                        when o.biz_date + max(c.settlement_days) < rsa_today() then 'เลยกำหนด' else 'รอรับเงิน' end) x
         from orders o join channels c on c.id = o.channel_id
        where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.biz_date between v_from and v_to
        group by o.biz_date, o.channel_id, o.channel_name) t),
    'channels', (select coalesce(jsonb_agg(jsonb_build_object('channel_id', c.id, 'name', c.name, 'fee_pct', c.fee_pct, 'fee_confirmed', c.fee_confirmed,
         'settlement_days', c.settlement_days,
         'gross', (select coalesce(sum(total - refunded), 0) from orders o where o.channel_id = c.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
         'orders', (select count(*) from orders o where o.channel_id = c.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
         'unsettled', (select coalesce(sum(total - refunded - est_fee), 0) from orders o where o.channel_id = c.id and o.status <> 'cancelled' and o.settlement_id is null))
         order by c.sort_order), '[]') from channels c where c.kind = 'delivery' and c.active),
    'settlements', (select coalesce(jsonb_agg(to_jsonb(s) || jsonb_build_object('account_name', (select name from payment_accounts where id = s.account_id))
         order by s.deposited_at desc), '[]') from delivery_settlements s where s.period_to between v_from and v_to));
end $$;

create or replace function rsa__report_expenses(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', date_trunc('month', rsa_today())::date); v_to date := rsa_date(p, 'to');
begin
  perform rsa_need(u, 'expense.view_all');
  return jsonb_build_object('from', v_from, 'to', v_to,
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', category_name, 'tax_category', tax, 'amount', amt, 'count', n) order by amt desc), '[]') from (
        select coalesce(category_name, '-') category_name, max(tax_category) tax, sum(amount) amt, count(*) n from expenses
         where status <> 'ยกเลิก' and rsa_bdate(occurred_at) between v_from and v_to group by category_name) t),
    'by_source', (select coalesce(jsonb_agg(jsonb_build_object('fund_source', fs, 'amount', amt, 'count', n) order by amt desc), '[]') from (
        select coalesce(fund_source, 'credit') fs, sum(amount) amt, count(*) n from expenses
         where status <> 'ยกเลิก' and rsa_bdate(occurred_at) between v_from and v_to group by coalesce(fund_source, 'credit')) t),
    'by_status', (select coalesce(jsonb_object_agg(status, amt), '{}') from (
        select status, sum(amount) amt from expenses where rsa_bdate(occurred_at) between v_from and v_to group by status) t),
    'owed', (select coalesce(jsonb_agg(jsonb_build_object('owed_to', owed_to, 'amount', amt, 'count', n)), '[]') from (
        select coalesce((select display_name from app_users where id = paid_by_employee), 'เจ้าของ') owed_to, sum(amount) amt, count(*) n
          from expenses where (paid_by_employee is not null or paid_by_owner) and status in ('รออนุมัติ','รอทำจ่าย')
         group by 1) t),
    'no_evidence', (select count(*) from expenses e where e.status <> 'ยกเลิก' and rsa_bdate(e.occurred_at) between v_from and v_to
         and not exists (select 1 from attachments a where (a.linked_type = 'expense' and a.linked_id = e.id) or (a.linked_type = 'receipt' and a.linked_id = e.receipt_id))),
    'total', (select coalesce(sum(amount), 0) from expenses where status <> 'ยกเลิก' and rsa_bdate(occurred_at) between v_from and v_to));
end $$;

create or replace function rsa__report_staff(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', date_trunc('month', rsa_today())::date); v_to date := rsa_date(p, 'to');
begin
  perform rsa_need(u, 'report.view');
  return jsonb_build_object('from', v_from, 'to', v_to,
    'workdays', rsa__close_workdays(u, jsonb_build_object('from', v_from, 'to', v_to)),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('user_id', x.id, 'display_name', x.display_name, 'role', x.role, 'active', x.active,
        'orders', (select count(*) from orders o where o.created_by = x.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
        'sales', (select coalesce(sum(total - refunded), 0) from orders o where o.created_by = x.id and o.status <> 'cancelled' and o.biz_date between v_from and v_to),
        'cancels', (select count(*) from orders o where o.cancelled_by = x.id and o.replaced_by is null and rsa_bdate(o.cancelled_at) between v_from and v_to),
        'edits', (select count(*) from orders o where o.cancelled_by = x.id and o.replaced_by is not null and rsa_bdate(o.cancelled_at) between v_from and v_to),
        'waste', (select coalesce(round(sum(qty * unit_cost), 2), 0) from waste_records w where w.created_by = x.id and w.status = 'recorded' and w.biz_date between v_from and v_to),
        'expenses', (select coalesce(sum(amount), 0) from expenses e where e.created_by = x.id and e.status <> 'ยกเลิก' and rsa_bdate(e.occurred_at) between v_from and v_to),
        'owed', (select coalesce(sum(amount), 0) from expenses e where e.paid_by_employee = x.id and e.status in ('รออนุมัติ','รอทำจ่าย')))
        order by x.active desc, x.display_name), '[]') from app_users x where x.role <> 'admin' or x.active));
end $$;

-- ---------------------------------------------------------------- stock balance with daily use and reorder suggestion
create or replace function rsa__stock_balance(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  return (select coalesce(jsonb_agg(x order by x->>'code', x->>'name'), '[]') from (
    select jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'unit', s.unit, 'kind', s.kind, 'active', s.active,
      'qty', q.qty, 'avg_cost', case when rsa_has(u, 'report.view') then s.avg_cost end,
      'value', case when rsa_has(u, 'report.view') then round(greatest(q.qty, 0) * s.avg_cost, 2) end,
      'min_qty', s.min_qty, 'reorder_qty', s.reorder_qty,
      'used_7d', coalesce((select -sum(qty) from stock_ledger l where l.stock_item_id = s.id and l.kind in ('sale','sale_reversal')
                            and l.occurred_at > now() - interval '7 days'), 0),
      'avg_daily_use', a.avg_use,
      'days_left', case when a.avg_use > 0 then round(greatest(q.qty, 0) / a.avg_use, 1) end,
      'status', case when q.qty <= 0 then 'out' when q.qty <= s.min_qty then 'low' else 'ok' end,
      -- use per day x 2 days + minimum - on hand (falls back to reorder qty when there is no usage history yet)
      'suggest', case when a.avg_use > 0 then greatest(ceil((a.avg_use * 2 + s.min_qty - q.qty) * 10) / 10, 0)
                      when q.qty <= s.min_qty then greatest(coalesce(nullif(s.reorder_qty, 0), s.min_qty * 2 - q.qty), 0) else 0 end,
      'last_received', (select max(occurred_at) from stock_ledger l where l.stock_item_id = s.id and l.kind = 'receipt'),
      'last_cost', case when rsa_has(u, 'report.view') then (select unit_cost from stock_ledger l where l.stock_item_id = s.id and l.kind = 'receipt' order by occurred_at desc limit 1) end,
      'used_in_recipe', exists (select 1 from recipe_lines r where r.stock_item_id = s.id),
      'products', (select coalesce(jsonb_agg(pr.name), '[]') from products pr where pr.main_stock_item_id = s.id or exists (select 1 from recipe_lines r where r.stock_item_id = s.id and r.product_id = pr.id)),
      'pending_count', exists (select 1 from stocktake_lines l join stocktakes t on t.id = l.stocktake_id where t.status = 'pending' and l.stock_item_id = s.id)
    ) x
    from stock_items s
    cross join lateral (select rsa_stock_qty(s.id) qty) q
    cross join lateral (select round(coalesce((select -sum(qty) from stock_ledger l where l.stock_item_id = s.id
                          and l.kind in ('sale','sale_reversal','waste','waste_reversal') and l.occurred_at > now() - interval '14 days'), 0)
                          / rsa_open_days(rsa_today() - 13, rsa_today()), 3) avg_use) a
    where s.active or coalesce((p->>'include_inactive')::boolean, false)) z);
end $$;

-- ---------------------------------------------------------------- bank statement lines and reconciliation
create or replace function rsa__bank_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_amt numeric := rsa_num(p, 'amount', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
        v_acc payment_accounts;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v_acc from payment_accounts where id = rsa_uuid(p, 'account_id') and kind <> 'cash';
  if not found then perform rsa_err('กรุณาเลือกบัญชีธนาคาร'); end if;
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if coalesce(p->>'direction', '') not in ('in','out') then perform rsa_err('เลือกเงินเข้า หรือ เงินออก'); end if;
  insert into bank_lines(id, account_id, occurred_at, biz_date, direction, amount, ref_no, description, created_by)
  values (v_id, v_acc.id, v_at, rsa_bdate(v_at), p->>'direction', v_amt, nullif(trim(p->>'ref_no'), ''), nullif(trim(p->>'description'), ''), u.id);
  perform rsa_link_attachments(p->'attachment_ids', 'bank_line', v_id, u);
  perform rsa_audit(u, 'bank.create', 'bank_line', v_id::text, null,
    jsonb_build_object('account', v_acc.name, 'direction', p->>'direction', 'amount', v_amt, 'ref_no', p->>'ref_no'));
  return (select to_jsonb(b) from bank_lines b where id = v_id);
end $$;

create or replace function rsa__bank_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'cashflow.view');
  return (select coalesce(jsonb_agg(to_jsonb(b) || jsonb_build_object('account_name', (select name from payment_accounts where id = b.account_id),
            'by', (select display_name from app_users where id = b.created_by), 'attachments', rsa_attachment_refs('bank_line', b.id))
            order by b.occurred_at desc), '[]')
          from bank_lines b where b.biz_date between rsa_date(p, 'from', rsa_today() - 30) and rsa_date(p, 'to')
           and (rsa_uuid(p, 'account_id') is null or b.account_id = rsa_uuid(p, 'account_id')));
end $$;

create or replace function rsa__bank_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v bank_lines;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from bank_lines where id = rsa_uuid(p, 'id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update bank_lines set status = 'cancelled', cancelled_by = u.id, cancel_reason = trim(p->>'reason') where id = v.id;
  perform rsa_audit(u, 'bank.cancel', 'bank_line', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

-- What the system expects in the account (QR / transfer orders, platform payouts, deposits, payments)
-- next to what the statement shows, per day.
create or replace function rsa__bank_recon(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_from date := rsa_date(p, 'from', rsa_today() - 13); v_to date := rsa_date(p, 'to');
        v_acc uuid := coalesce(rsa_uuid(p, 'account_id'), (select id from payment_accounts where active and kind = 'bank' order by created_at limit 1));
begin
  perform rsa_need(u, 'cashflow.view');
  if v_acc is null then return jsonb_build_object('account_id', null, 'days', '[]'); end if;
  return jsonb_build_object('account_id', v_acc, 'account_name', (select name from payment_accounts where id = v_acc), 'from', v_from, 'to', v_to,
    'days', (select jsonb_agg(jsonb_build_object('date', d::date,
        'qr_orders', coalesce((select sum(case direction when 'in' then amount else -amount end) from money_ledger m
                      where m.account_id = v_acc and m.biz_date = d::date and m.source_type in ('order','order_refund')), 0),
        'settlements', coalesce((select sum(case direction when 'in' then amount else -amount end) from money_ledger m
                      where m.account_id = v_acc and m.biz_date = d::date and m.source_type = 'settlement'), 0),
        'expected_in', coalesce((select sum(amount) from money_ledger m where m.account_id = v_acc and m.biz_date = d::date and m.direction = 'in'), 0),
        'expected_out', coalesce((select sum(amount) from money_ledger m where m.account_id = v_acc and m.biz_date = d::date and m.direction = 'out'), 0),
        'actual_in', coalesce((select sum(amount) from bank_lines b where b.account_id = v_acc and b.biz_date = d::date and b.status = 'done' and b.direction = 'in'), 0),
        'actual_out', coalesce((select sum(amount) from bank_lines b where b.account_id = v_acc and b.biz_date = d::date and b.status = 'done' and b.direction = 'out'), 0),
        'lines', (select count(*) from bank_lines b where b.account_id = v_acc and b.biz_date = d::date and b.status = 'done')) order by d desc)
      from generate_series(v_from, v_to, interval '1 day') d),
    'system_balance', rsa_account_balance(v_acc));
end $$;

-- ---------------------------------------------------------------- capital, investment items, payback
create or replace function rsa_floor_check(p_amount numeric) returns void language plpgsql as $$
declare v_min numeric := rsa_setting_num('min_working_capital', 0); v_left numeric;
begin
  if v_min <= 0 then return; end if;
  v_left := rsa_cash_total() - p_amount;
  if v_left < v_min then
    perform rsa_err('ต้องกันเงินหมุนขั้นต่ำ ' || to_char(v_min, 'FM999,999,990') || ' บาท ถ้าจ่ายรายการนี้จะเหลือ '
                    || to_char(v_left, 'FM999,999,990.00') || ' บาท');
  end if;
end $$;

create or replace function rsa__capital_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_kind text := p->>'kind'; v_amt numeric := rsa_num(p, 'amount', 0); v_at timestamptz := rsa_ts(p, 'occurred_at');
begin
  perform rsa_need(u, 'cashflow.manage');
  if v_kind not in ('capital_in','loan_in','capital_return','loan_repayment','investment_item') then perform rsa_err('ประเภทรายการไม่ถูกต้อง'); end if;
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if v_kind = 'investment_item' then
    if coalesce(trim(p->>'category'), '') = '' then perform rsa_err('กรุณาระบุรายการลงทุน เช่น ค่าเซ้ง เงินประกัน'); end if;
    insert into capital_entries(id, kind, party, amount, occurred_at, account_id, note, created_by, category, counts_as_investment, in_payback,
                                refundable_amount, data_status)
    values (v_id, 'investment_item', coalesce(nullif(trim(p->>'party'), ''), 'เจ้าของ'), v_amt, v_at, null, nullif(p->>'note', ''), u.id, trim(p->>'category'),
            coalesce((p->>'counts_as_investment')::boolean, true), coalesce((p->>'in_payback')::boolean, true),
            greatest(rsa_num(p, 'refundable_amount', 0), 0), coalesce(nullif(p->>'data_status', ''), 'ยืนยันแล้ว'));
  else
    if coalesce(trim(p->>'party'), '') = '' then perform rsa_err('กรุณาระบุชื่อผู้ลงทุนหรือเจ้าหนี้'); end if;
    if rsa_uuid(p, 'account_id') is null then perform rsa_err('กรุณาเลือกบัญชี'); end if;
    if v_kind in ('capital_return','loan_repayment') then
      if v_amt > rsa_account_balance(rsa_uuid(p, 'account_id')) then perform rsa_err('ยอดเงินในบัญชีที่เลือกไม่พอ'); end if;
      perform rsa_floor_check(v_amt);
    end if;
    insert into capital_entries(id, kind, party, amount, occurred_at, account_id, note, created_by, category)
    values (v_id, v_kind, trim(p->>'party'), v_amt, v_at, rsa_uuid(p, 'account_id'), nullif(p->>'note', ''), u.id, nullif(trim(p->>'category'), ''));
    perform rsa_money(rsa_uuid(p, 'account_id'), case when v_kind in ('capital_in','loan_in') then 'in' else 'out' end, v_amt, 'capital', v_id,
      trim(p->>'party'), u.id, v_at);
  end if;
  perform rsa_audit(u, 'capital.create', 'capital', v_id::text, null, jsonb_build_object('kind', v_kind, 'amount', v_amt, 'party', p->>'party', 'category', p->>'category'));
  return jsonb_build_object('id', v_id);
end $$;

-- investment items carry no cash movement, so their review fields may be corrected (every change is audited)
create or replace function rsa__investment_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v capital_entries;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from capital_entries where id = rsa_uuid(p, 'id') and kind = 'investment_item' and status = 'done' for update;
  if not found then perform rsa_err('ไม่พบรายการลงทุน'); end if;
  update capital_entries set
    amount = coalesce(nullif(rsa_num(p, 'amount'), 0), amount),
    category = coalesce(nullif(trim(p->>'category'), ''), category),
    refundable_amount = coalesce(rsa_num(p, 'refundable_amount'), refundable_amount),
    counts_as_investment = coalesce((p->>'counts_as_investment')::boolean, counts_as_investment),
    in_payback = coalesce((p->>'in_payback')::boolean, in_payback),
    data_status = coalesce(nullif(p->>'data_status', ''), data_status),
    occurred_at = coalesce(nullif(p->>'occurred_at', '')::timestamptz, occurred_at),
    note = coalesce(nullif(p->>'note', ''), note)
   where id = v.id;
  perform rsa_audit(u, 'investment.save', 'capital', v.id::text, to_jsonb(v), (select to_jsonb(c) from capital_entries c where id = v.id));
  return (select to_jsonb(c) from capital_entries c where id = v.id);
end $$;

create or replace function rsa__capital_cancel(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v capital_entries;
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from capital_entries where id = rsa_uuid(p, 'capital_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบรายการ หรือยกเลิกไปแล้ว'); end if;
  if v.profit_declaration_id is not null then perform rsa_err('รายการนี้มาจากการประกาศใช้กำไร ให้ยกเลิกที่การประกาศ'); end if;
  if v.expense_id is not null then perform rsa_err('รายการนี้มาจากค่าใช้จ่ายที่เจ้าของจ่ายแทน ให้ยกเลิกที่ค่าใช้จ่าย'); end if;
  if coalesce(trim(p->>'reason'), '') = '' then perform rsa_err('กรุณาระบุเหตุผลการยกเลิก'); end if;
  update capital_entries set status = 'cancelled', cancelled_by = u.id, cancel_reason = p->>'reason' where id = v.id;
  if v.account_id is not null then
    perform rsa_money(v.account_id, case when v.kind in ('capital_in','loan_in') then 'out' else 'in' end, v.amount, 'capital', v.id, 'กลับรายการ ' || v.party, u.id);
  end if;
  perform rsa_audit(u, 'capital.cancel', 'capital', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function rsa__payback_summary(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_today date := rsa_today(); v_av jsonb := rsa_profit_available(); v_base numeric; v_profit numeric; v_avg numeric; v_debt numeric; v_paid numeric;
begin
  perform rsa_need(u, 'cashflow.view');
  select coalesce(sum(amount - refundable_amount) filter (where in_payback), 0) into v_base
    from capital_entries where kind = 'investment_item' and status = 'done' and counts_as_investment;
  v_profit := (v_av->>'cumulative_net')::numeric;
  v_avg := round((rsa_profit(v_today - 89, v_today)->>'net_profit')::numeric / 3, 2);
  -- debt: one formula everywhere (rsa_debt_left): opening debt + loans taken − repayments
  v_debt := rsa_setting_num('opening_debt', 0) + (select coalesce(sum(amount), 0) from capital_entries where kind = 'loan_in' and status = 'done');
  select coalesce(sum(amount), 0) into v_paid from capital_entries where kind = 'loan_repayment' and status = 'done';
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(to_jsonb(c) order by c.occurred_at), '[]') from capital_entries c where c.kind = 'investment_item' and c.status = 'done'),
    'investment_total', (select coalesce(sum(amount), 0) from capital_entries where kind = 'investment_item' and status = 'done' and counts_as_investment),
    'refundable', (select coalesce(sum(refundable_amount), 0) from capital_entries where kind = 'investment_item' and status = 'done' and counts_as_investment),
    'payback_base', v_base,
    'cash_capital_in', (select coalesce(sum(amount), 0) from capital_entries where kind in ('capital_in','owner_paid') and status = 'done'),
    'capital_returned', (select coalesce(sum(amount), 0) from capital_entries where kind = 'capital_return' and status = 'done'),
    'profit_to_date', v_profit,
    'profit_complete', v_av->'complete',
    'remaining', greatest(v_base - greatest(v_profit, 0), 0),
    'progress_pct', case when v_base > 0 then least(round(greatest(v_profit, 0) * 100 / v_base, 1), 100) end,
    'avg_month_profit', v_avg,
    'months_left', case when v_avg > 0 and v_base > v_profit then ceil((v_base - greatest(v_profit, 0)) / v_avg) end,
    'opening_debt', v_debt,
    'opening_debt_confirmed', coalesce((select confirmed from settings where key = 'opening_debt'), false),
    'debt_paid', v_paid,
    'debt_left', greatest(v_debt - v_paid, 0),
    'needs_review', (select count(*) from capital_entries where kind = 'investment_item' and status = 'done' and data_status <> 'ยืนยันแล้ว'));
end $$;

-- ---------------------------------------------------------------- profit uses
create or replace function rsa__profit_declare(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_amt numeric := rsa_num(p, 'amount', 0); v_av jsonb := rsa_profit_available();
        v_acc uuid := rsa_uuid(p, 'account_id'); v_purpose text := p->>'purpose'; v_at timestamptz := rsa_ts(p, 'declared_at');
        v_keep boolean; v_now boolean;
begin
  perform rsa_need(u, 'cashflow.manage');
  if v_purpose not in ('owner_draw','capital_return','loan_repayment','keep_working_capital','reinvest') then perform rsa_err('กรุณาเลือกวิธีใช้กำไร'); end if;
  v_keep := v_purpose in ('keep_working_capital','reinvest');
  v_now := not v_keep and coalesce((p->>'paid_now')::boolean, true);
  if v_amt <= 0 then perform rsa_err('จำนวนเงินต้องมากกว่า 0'); end if;
  if not v_keep and coalesce(trim(p->>'recipient'), '') = '' then perform rsa_err('กรุณาระบุผู้รับเงิน'); end if;
  if v_now and v_acc is null then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
  if v_amt > (v_av->>'available')::numeric then
    perform rsa_err('กำไรที่ประกาศได้ตอนนี้ ' || (v_av->>'available') || ' บาท ยอดที่ขอเกินกว่านั้น');
  end if;
  if v_now then
    if v_amt > rsa_account_balance(v_acc) then perform rsa_err('ยอดเงินในบัญชีที่เลือกไม่พอ'); end if;
    perform rsa_floor_check(v_amt);
  end if;
  insert into profit_declarations(id, amount, declared_at, recipient, purpose, account_id, basis_available, note, paid_now, created_by)
  values (v_id, v_amt, v_at, coalesce(nullif(trim(p->>'recipient'), ''), 'ร้าน'), v_purpose, case when v_now then v_acc end,
          (v_av->>'available')::numeric, nullif(p->>'note', ''), v_now, u.id);
  if v_now then perform rsa_profit_payout(u, v_id, v_acc, v_at); end if;
  perform rsa_audit(u, 'profit.declare', 'profit_declaration', v_id::text, null,
    jsonb_build_object('amount', v_amt, 'purpose', v_purpose, 'recipient', p->>'recipient', 'paid_now', v_now, 'available_before', v_av->'available'));
  return jsonb_build_object('id', v_id);
end $$;

create or replace function rsa_profit_payout(u app_users, p_id uuid, p_acc uuid, p_at timestamptz) returns void language plpgsql as $$
declare v profit_declarations;
begin
  select * into v from profit_declarations where id = p_id;
  if v.purpose in ('capital_return','loan_repayment') then
    insert into capital_entries(kind, party, amount, occurred_at, account_id, profit_declaration_id, note, created_by)
    values (v.purpose, v.recipient, v.amount, p_at, p_acc, v.id, 'จากการประกาศใช้กำไร', u.id);
  end if;
  perform rsa_money(p_acc, 'out', v.amount, 'profit', v.id, 'ประกาศใช้กำไร: ' || v.recipient, u.id, p_at);
end $$;

-- pay a declared profit that was set aside to pay later
create or replace function rsa__profit_pay(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v profit_declarations; v_acc uuid := rsa_uuid(p, 'account_id'); v_at timestamptz := rsa_ts(p, 'paid_at');
begin
  perform rsa_need(u, 'cashflow.manage');
  select * into v from profit_declarations where id = rsa_uuid(p, 'declaration_id') for update;
  if not found or v.status <> 'done' then perform rsa_err('ไม่พบรายการ'); end if;
  if v.paid_now or v.purpose in ('keep_working_capital','reinvest') then perform rsa_err('รายการนี้ไม่มียอดค้างจ่าย'); end if;
  if v_acc is null then perform rsa_err('กรุณาเลือกบัญชีที่จ่ายเงิน'); end if;
  if v.amount > rsa_account_balance(v_acc) then perform rsa_err('ยอดเงินในบัญชีที่เลือกไม่พอ'); end if;
  perform rsa_floor_check(v.amount);
  update profit_declarations set paid_now = true, account_id = v_acc where id = v.id;
  perform rsa_profit_payout(u, v.id, v_acc, v_at);
  perform rsa_audit(u, 'profit.pay', 'profit_declaration', v.id::text, null, jsonb_build_object('account_id', v_acc, 'amount', v.amount));
  return jsonb_build_object('ok', true);
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
  if v.account_id is not null and v.paid_now then
    perform rsa_money(v.account_id, 'in', v.amount, 'profit', v.id, 'กลับรายการประกาศใช้กำไร', u.id);
  end if;
  perform rsa_audit(u, 'profit.cancel', 'profit_declaration', v.id::text, null, null, jsonb_build_object('reason', p->>'reason'));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- cash forecast 7 / 14 / 30 days
create or replace function rsa__cashflow_forecast(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_today date := rsa_today(); v_cash numeric := rsa_cash_total(); v_sales numeric; v_spend numeric; v_out numeric;
        v_min numeric := rsa_setting_num('min_working_capital', 0);
begin
  perform rsa_need(u, 'cashflow.view');
  -- averages from real history (estimates, shown as such)
  -- per open day (holidays have no sales and are skipped when projecting forward)
  select coalesce(sum(total - refunded), 0) / rsa_open_days(v_today - 14, v_today - 1) into v_sales from orders
   where channel_kind = 'storefront' and status <> 'cancelled' and biz_date between v_today - 14 and v_today - 1;
  select coalesce(sum(amount), 0) / 30 into v_spend from expenses
   where status = 'จ่ายแล้ว' and fixed_expense_id is null and rsa_bdate(paid_at) between v_today - 30 and v_today - 1;
  select coalesce(sum(case direction when 'out' then amount else 0 end), 0) / 30 into v_out from money_ledger m
   where m.biz_date between v_today - 30 and v_today - 1 and m.source_type in ('expense')
     and exists (select 1 from payment_accounts a where a.id = m.account_id);
  return jsonb_build_object('today', v_today, 'cash_now', v_cash, 'min_working_capital', v_min,
    'avg_daily_storefront', round(v_sales, 2), 'avg_daily_spend', round(v_spend, 2), 'avg_daily_outflow', round(v_out, 2),
    'runway_days', case when v_out > 0 then floor(v_cash / v_out) end,
    'horizons', (select jsonb_agg(jsonb_build_object('days', d,
        'delivery_in', (select coalesce(sum(o.total - o.refunded - o.est_fee), 0) from orders o join channels c on c.id = o.channel_id
                        where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days <= v_today + d),
        'est_sales', round(v_sales * (select count(*) from generate_series(v_today + 1, v_today + d, interval '1 day') g where rsa_is_open(g::date)), 2),
        'payables', (select coalesce(sum(amount), 0) from expenses where status in ('รออนุมัติ','รอทำจ่าย') and coalesce(due_date, rsa_bdate(occurred_at)) <= v_today + d),
        -- this month's recurring bills already exist as payables; later months (monthly and weekly) come from the recurring list
        'fixed', rsa_fixed_upcoming((date_trunc('month', v_today) + interval '1 month')::date, v_today + d),
        'debt', rsa_debt_due(v_today + d),
        'est_spend', round(v_spend * d, 2)) order by d) from unnest(array[7,14,30]) d),
    'unconfirmed_fixed', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'amount', amount, 'due_day', due_day)), '[]')
                          from fixed_expenses where active and not confirmed),
    'daily', (select jsonb_agg(jsonb_build_object('date', v_today + n,
        'balance', round(v_cash + v_sales * (select count(*) from generate_series(v_today + 1, v_today + n, interval '1 day') g where rsa_is_open(g::date)) - v_spend * n
          + (select coalesce(sum(o.total - o.refunded - o.est_fee), 0) from orders o join channels c on c.id = o.channel_id
              where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days <= v_today + n)
          - (select coalesce(sum(amount), 0) from expenses where status in ('รออนุมัติ','รอทำจ่าย') and coalesce(due_date, rsa_bdate(occurred_at)) <= v_today + n), 2))
        order by n) from generate_series(0, 30) n));
end $$;

-- ---------------------------------------------------------------- bootstrap, master data, settings
create or replace function rsa__bootstrap(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare is_mgr boolean := rsa_has(u, 'master.manage') or rsa_has(u, 'expense.approve');
begin
  return jsonb_build_object(
    'me', rsa_user_json(u),
    'today', rsa_today(),
    'now', now(),
    'settings', (select coalesce(jsonb_object_agg(key, jsonb_build_object('value', value, 'confirmed', confirmed)), '{}') from settings),
    'channels', (select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order, c.name), '[]') from channels c where c.active),
    'accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'is_drawer', a.is_drawer) order by a.is_drawer desc, a.name), '[]')
                   from payment_accounts a where a.active),
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', p2.id, 'sku', p2.sku, 'name', p2.name, 'category', p2.category,
                   'unit', p2.unit, 'price', p2.price, 'delivery_price', p2.delivery_price, 'markdown_price', p2.markdown_price, 'delivery_enabled', p2.delivery_enabled,
                   'emoji', p2.emoji, 'sort_order', p2.sort_order,
                   'has_recipe', exists (select 1 from recipe_lines r where r.product_id = p2.id)) order by p2.sort_order, p2.name), '[]')
                   from products p2 where p2.active),
    'promotions', (select coalesce(jsonb_agg(to_jsonb(pr)), '[]') from promotions pr
                   where pr.active and (pr.starts_at is null or pr.starts_at <= now()) and (pr.ends_at is null or pr.ends_at > now())),
    'stock_items', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'unit', s.unit, 'kind', s.kind, 'count_units', s.count_units, 'avg_cost', case when rsa_has(u, 'expense.approve') then s.avg_cost end) order by s.code nulls last, s.name), '[]')
                   from stock_items s where s.active),
    'units', (select coalesce(jsonb_agg(name order by name), '[]') from units where active),
    'categories', (select coalesce(jsonb_agg(to_jsonb(c) order by coalesce(c.grp, 'B'), c.sort_order, c.code nulls last, c.name), '[]') from expense_categories c
                   where c.active and c.auto_source is null and (is_mgr or (c.staff_allowed and coalesce(c.grp, 'B') <> 'C'))
                     and (coalesce(c.grp, 'B') <> 'C' or c.c_kind = 'advance' or rsa_has(u, 'cashflow.manage'))),
    'suppliers', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name), '[]') from suppliers s where s.active),
    'users', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'display_name', x.display_name, 'role', x.role) order by x.display_name), '[]')
                   from app_users x where x.active),
    'closed_today', exists (select 1 from daily_closes where biz_date = rsa_today()),
    'holiday_today', not rsa_is_open(rsa_today())
  );
end $$;

create or replace function rsa_setting_keys() returns text[] language sql immutable as $$
  select array['shop_name','close_due_time','cash_variance_tolerance','waste_evidence_required','vat_registered','tax_id',
    'close_time','reminder_times','starting_float','min_working_capital','opening_debt','transport_default','transport_method',
    'market_trip_km','market_trips_per_week','profit_target','evidence_required','waste_reasons','payroll_week_start','product_categories',
    'markdown_from','closed_weekdays','closed_dates','cost_ratio_limits','budget_over_alert_pct','monthly_plan','debt_schedule','lease_end','kpi_targets']
$$;

create or replace function rsa__settings_save(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_before jsonb; v_key text := p->>'key'; v_val jsonb := p->'value';
begin
  perform rsa_need(u, 'settings.manage');
  if not (v_key = any(rsa_setting_keys())) then perform rsa_err('ไม่รู้จักการตั้งค่านี้'); end if;
  if v_key in ('close_due_time','close_time') and coalesce(v_val #>> '{}', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    perform rsa_err('รูปแบบเวลาต้องเป็น HH:MM เช่น 20:00');
  end if;
  if v_key = 'reminder_times' and (jsonb_typeof(v_val) <> 'array'
     or exists (select 1 from jsonb_array_elements_text(v_val) t where t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$')) then
    perform rsa_err('เวลาเตือนต้องเป็นรายการเวลา HH:MM');
  end if;
  if v_key in ('cash_variance_tolerance','starting_float','min_working_capital','opening_debt','transport_default','market_trip_km',
               'market_trips_per_week','profit_target') and (jsonb_typeof(v_val) <> 'number' or (v_val #>> '{}')::numeric < 0) then
    perform rsa_err('ค่านี้ต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป');
  end if;
  if v_key = 'transport_method' and coalesce(v_val #>> '{}', '') not in ('value','weight','equal') then perform rsa_err('วิธีจัดสรรค่าขนส่งไม่ถูกต้อง'); end if;
  if v_key = 'payroll_week_start' and (jsonb_typeof(v_val) <> 'number' or (v_val #>> '{}')::int not between 0 and 6) then perform rsa_err('วันเริ่มสัปดาห์ต้องเป็น 0–6 (0 = อาทิตย์, 1 = จันทร์)'); end if;
  if v_key = 'product_categories' and jsonb_typeof(v_val) <> 'array' then perform rsa_err('หมวดสินค้าต้องเป็นรายการ'); end if;
  if v_key = 'markdown_from' and coalesce(v_val #>> '{}', '') !~ '^(([01][0-9]|2[0-3]):[0-5][0-9])?$' then perform rsa_err('รูปแบบเวลาต้องเป็น HH:MM เช่น 19:00 (เว้นว่าง = ไม่ใช้)'); end if;
  if v_key = 'closed_weekdays' and (jsonb_typeof(v_val) <> 'array'
     or exists (select 1 from jsonb_array_elements(v_val) t where jsonb_typeof(t) <> 'number' or (t #>> '{}')::int not between 0 and 6)) then
    perform rsa_err('วันหยุดประจำต้องเป็นรายการวัน 0–6');
  end if;
  if v_key = 'closed_dates' and (jsonb_typeof(v_val) <> 'array'
     or exists (select 1 from jsonb_array_elements_text(v_val) t where t !~ '^\d{4}-\d{2}-\d{2}$')) then
    perform rsa_err('วันหยุดพิเศษต้องเป็นวันที่ YYYY-MM-DD');
  end if;
  if v_key = 'closed_dates' then
    v_val := (select coalesce(jsonb_agg(d order by d), '[]') from (select distinct t d from jsonb_array_elements_text(v_val) t) x);
  end if;
  if v_key = 'cost_ratio_limits' and (jsonb_typeof(v_val) <> 'object'
     or exists (select 1 from jsonb_each(v_val) t where jsonb_typeof(t.value) <> 'number' or (t.value #>> '{}')::numeric not between 0 and 1)) then
    perform rsa_err('เกณฑ์ต้นทุนต้องเป็นสัดส่วน 0–1 เช่น ผลไม้ 0.65');
  end if;
  if v_key = 'kpi_targets' and (jsonb_typeof(v_val) <> 'object'
     or exists (select 1 from jsonb_each(v_val) t where jsonb_typeof(t.value) <> 'number' or (t.value #>> '{}')::numeric < 0)) then
    perform rsa_err('เป้า KPI ต้องเป็นตัวเลขตั้งแต่ 0 ขึ้นไป');
  end if;
  if v_key = 'budget_over_alert_pct' and (jsonb_typeof(v_val) <> 'number' or (v_val #>> '{}')::numeric not between 0 and 1) then
    perform rsa_err('เกณฑ์แจ้งเตือนเกินงบต้องเป็นสัดส่วน 0–1 เช่น 0.1');
  end if;
  if v_key = 'monthly_plan' and (jsonb_typeof(v_val) <> 'object'
     or exists (select 1 from jsonb_each(v_val) t where t.key !~ '^\d{4}-\d{2}$' or jsonb_typeof(t.value) <> 'object')) then
    perform rsa_err('แผนรายเดือนต้องเป็น { "YYYY-MM": { sales_target, net_profit_target } }');
  end if;
  if v_key = 'debt_schedule' and (jsonb_typeof(v_val) <> 'array'
     or exists (select 1 from jsonb_array_elements(v_val) t where coalesce(t->>'due', '') !~ '^\d{4}-\d{2}-\d{2}$' or jsonb_typeof(t->'amount') <> 'number')) then
    perform rsa_err('ตารางหนี้ต้องเป็นรายการ { due: YYYY-MM-DD, amount }');
  end if;
  if v_key in ('waste_evidence_required','vat_registered','evidence_required') and jsonb_typeof(v_val) <> 'boolean' then perform rsa_err('ค่านี้ต้องเป็น ใช่ / ไม่ใช่'); end if;
  select to_jsonb(s) into v_before from settings s where key = v_key;
  insert into settings(key, value, confirmed, updated_at, updated_by) values (v_key, v_val, coalesce((p->>'confirmed')::boolean, true), now(), u.id)
  on conflict (key) do update set value = excluded.value, confirmed = excluded.confirmed, updated_at = now(), updated_by = u.id;
  perform rsa_audit(u, 'settings.save', 'settings', v_key, v_before, jsonb_build_object('value', v_val, 'confirmed', coalesce((p->>'confirmed')::boolean, true)));
  return jsonb_build_object('ok', true);
end $$;

-- what still needs the owner's confirmation before numbers can be trusted
create or replace function rsa__setup_checklist(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'report.view');
  return (select coalesce(jsonb_agg(x), '[]') from (
    select jsonb_build_object('kind', 'setting', 'key', s.key, 'text', 'ตั้งค่า "' || s.key || '" ยังไม่ยืนยัน', 'value', s.value) x
      from settings s where not s.confirmed and s.key = any(rsa_setting_keys())
    union all
    select jsonb_build_object('kind', 'account', 'id', a.id, 'text', 'ยอดยกมาบัญชี "' || a.name || '" ยังไม่ยืนยัน') from payment_accounts a where a.active and not a.opening_confirmed
    union all
    select jsonb_build_object('kind', 'channel', 'id', c.id, 'text', 'ค่าธรรมเนียม ' || c.name || ' (' || c.fee_pct || '%) ยังไม่ยืนยัน') from channels c where c.active and c.kind = 'delivery' and not c.fee_confirmed
    union all
    select jsonb_build_object('kind', 'fixed', 'id', f.id, 'text', 'ค่าใช้จ่ายประจำ "' || f.name || '" ' || f.amount || ' บาท ยังไม่ยืนยัน') from fixed_expenses f where f.active and not f.confirmed
    union all
    select jsonb_build_object('kind', 'investment', 'id', c.id, 'text', 'เงินลงทุน "' || c.category || '" ' || c.amount || ' บาท ' || c.data_status)
      from capital_entries c where c.kind = 'investment_item' and c.status = 'done' and c.data_status <> 'ยืนยันแล้ว'
    union all
    select jsonb_build_object('kind', 'recipe', 'id', pr.id, 'text', 'สินค้า "' || pr.name || '" ยังไม่มีสูตรการใช้วัตถุดิบ (ยังคิดต้นทุนและตัดสต็อกไม่ได้)')
      from products pr where pr.active and pr.est_cost is null and not exists (select 1 from recipe_lines r where r.product_id = pr.id)
    union all
    select jsonb_build_object('kind', 'stock_cost', 'id', s.id, 'text', 'วัตถุดิบ "' || s.name || '" ยังไม่มีต้นทุน') from stock_items s where s.active and s.avg_cost <= 0
  ) t);
end $$;

-- ---------------------------------------------------------------- exports: central ledger and monthly tax prep
create or replace function rsa__export2(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_kind text := p->>'kind'; v_from date := rsa_date(p, 'from', rsa_today() - 30); v_to date := rsa_date(p, 'to'); v jsonb;
begin
  if v_kind not in ('ledger', 'tax_monthly') then return rsa__export(u, p); end if;
  perform rsa_need(u, 'export.run');
  if v_kind = 'ledger' then
    select coalesce(jsonb_agg(x order by x->>'วันที่', x->>'เวลา', x->>'_id'), '[]') into v from (
      select jsonb_build_object(
        'วันที่', m.biz_date, 'เวลา', to_char(m.occurred_at at time zone 'Asia/Bangkok', 'HH24:MI'),
        'เลขที่เอกสาร', coalesce(o.order_no, e.expense_no, s.ref_no, to_char(d.biz_date, '"CLOSE-"YYYYMMDD'), ''),
        'ประเภทรายการ', case m.source_type when 'order' then 'รับเงินขาย' when 'order_refund' then 'คืนเงิน/ยกเลิกขาย' when 'expense' then 'จ่ายค่าใช้จ่าย'
                         when 'expense_reversal' then 'กลับรายการค่าใช้จ่าย' when 'settlement' then 'รับเงินแพลตฟอร์ม' when 'transfer' then 'โอนระหว่างบัญชี'
                         when 'capital' then 'เงินทุน/เงินกู้' when 'profit' then 'ใช้กำไร' when 'adjustment' then 'ปรับยอดเงินสดจากปิดยอด' else m.source_type end,
        'รายละเอียด', m.note,
        'หมวด/ภาษี', coalesce(e.tax_category, e.category_name, case when m.source_type in ('order','order_refund','settlement') then 'รายได้จากการขาย' end, ''),
        'บัญชี', a.name,
        'รับเข้า', case when m.direction = 'in' then m.amount else 0 end,
        'จ่ายออก', case when m.direction = 'out' then m.amount else 0 end,
        'คงเหลือบัญชี', a.opening_balance + sum(case m.direction when 'in' then m.amount else -m.amount end)
                           over (partition by m.account_id order by m.occurred_at, m.created_at, m.id),
        'ที่มา', m.source_type || ':' || m.source_id,
        'อ้างอิงธนาคาร', coalesce(m.bank_ref, e.pay_ref, s.ref_no, ''),
        'หลักฐาน', (select count(*) from attachments t where t.linked_id = m.source_id or (e.receipt_id is not null and t.linked_id = e.receipt_id)),
        'ผู้บันทึก', (select display_name from app_users where id = m.created_by),
        'ผู้อนุมัติ', (select display_name from app_users where id = e.approved_by),
        'สถานะ', coalesce(e.status, o.status, s.status, ''),
        'กระทบยอดแล้ว', case when m.reconciled_at is not null then 'ใช่' else '' end,
        'หมายเหตุ', coalesce(o.cancel_reason, e.cancel_reason, ''),
        '_id', m.id) x, m.biz_date bd
      from money_ledger m join payment_accounts a on a.id = m.account_id
      left join orders o on o.id = m.source_id and m.source_type in ('order','order_refund')
      left join expenses e on e.id = m.source_id and m.source_type in ('expense','expense_reversal')
      left join delivery_settlements s on s.id = m.source_id and m.source_type = 'settlement'
      left join daily_closes d on d.id = m.source_id and m.source_type = 'adjustment') t
    where bd between v_from and v_to;
    select coalesce(jsonb_agg(x - '_id'), '[]') into v from jsonb_array_elements(v) x;
  else
    select coalesce(jsonb_agg(x order by x->>'เดือน', x->>'ลำดับ'), '[]') into v from (
      select jsonb_build_object('เดือน', to_char(mo, 'YYYY-MM'), 'ลำดับ', '1', 'กลุ่ม', 'รายได้', 'รายการ', 'ยอดขายหน้าร้าน',
        'จำนวนเงิน', (select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and channel_kind = 'storefront' and date_trunc('month', biz_date) = mo),
        'จำนวนรายการ', (select count(*) from orders where status <> 'cancelled' and channel_kind = 'storefront' and date_trunc('month', biz_date) = mo), 'หมายเหตุ', '') x
        from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') mo
      union all
      select jsonb_build_object('เดือน', to_char(mo, 'YYYY-MM'), 'ลำดับ', '2', 'กลุ่ม', 'รายได้', 'รายการ', 'ยอดขาย Delivery (ก่อนหักค่าธรรมเนียม)',
        'จำนวนเงิน', (select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and channel_kind = 'delivery' and date_trunc('month', biz_date) = mo),
        'จำนวนรายการ', (select count(*) from orders where status <> 'cancelled' and channel_kind = 'delivery' and date_trunc('month', biz_date) = mo), 'หมายเหตุ', '')
        from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') mo
      union all
      select jsonb_build_object('เดือน', to_char(mo, 'YYYY-MM'), 'ลำดับ', '3', 'กลุ่ม', 'หักจากรายได้', 'รายการ', 'ค่าธรรมเนียมแพลตฟอร์ม',
        'จำนวนเงิน', (select coalesce(sum(fee), 0) from delivery_settlements where status = 'done' and date_trunc('month', period_to) = mo)
                    + (select coalesce(sum(est_fee), 0) from orders where status <> 'cancelled' and channel_kind = 'delivery' and settlement_id is null and date_trunc('month', biz_date) = mo),
        'จำนวนรายการ', (select count(*) from delivery_settlements where status = 'done' and date_trunc('month', period_to) = mo),
        'หมายเหตุ', 'ส่วนที่ยังไม่ได้รับเงินเป็นค่าประมาณ')
        from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') mo
      union all
      select jsonb_build_object('เดือน', to_char(mo, 'YYYY-MM'), 'ลำดับ', '4', 'กลุ่ม', 'ต้นทุน', 'รายการ', 'ต้นทุนขายประมาณ (จากสูตร)',
        'จำนวนเงิน', (select coalesce(sum(cost_total), 0) from orders where status <> 'cancelled' and date_trunc('month', biz_date) = mo),
        'จำนวนรายการ', null, 'หมายเหตุ', 'ค่าประมาณจากสูตรการใช้วัตถุดิบ')
        from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') mo
      union all
      select jsonb_build_object('เดือน', g.mo, 'ลำดับ', '5', 'กลุ่ม', 'ค่าใช้จ่าย', 'รายการ', g.cat,
        'จำนวนเงิน', g.amt, 'จำนวนรายการ', g.n, 'หมายเหตุ', case when g.noev > 0 then 'ไม่มีหลักฐาน ' || g.noev || ' รายการ' else '' end)
        from (select to_char(date_trunc('month', e.occurred_at at time zone 'Asia/Bangkok'), 'YYYY-MM') mo,
                     coalesce(e.tax_category, e.category_name, 'ไม่ระบุหมวด') cat, sum(e.amount) amt, count(*) n,
                     count(*) filter (where not exists (select 1 from attachments t where t.linked_id = e.id or t.linked_id = e.receipt_id)) noev
                from expenses e where e.status in ('จ่ายแล้ว','รอทำจ่าย') and rsa_bdate(e.occurred_at) between date_trunc('month', v_from)::date and v_to
               group by 1, 2) g
      union all
      select jsonb_build_object('เดือน', '', 'ลำดับ', '9', 'กลุ่ม', 'หมายเหตุ', 'รายการ', 'เอกสารนี้เป็นสรุปเตรียมข้อมูลให้นักบัญชี ไม่ใช่แบบยื่นภาษี',
        'จำนวนเงิน', null, 'จำนวนรายการ', null, 'หมายเหตุ', '')
    ) t;
  end if;
  perform rsa_audit(u, 'export', 'export', v_kind, null, null, jsonb_build_object('kind', v_kind, 'from', v_from, 'to', v_to, 'rows', jsonb_array_length(v)));
  return v;
end $$;

-- ---------------------------------------------------------------- API entry point
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
    when 'report.products'    then rsa__report_products(u, p)
    when 'report.delivery'    then rsa__report_delivery(u, p)
    when 'report.expenses'    then rsa__report_expenses(u, p)
    when 'report.staff'       then rsa__report_staff(u, p)
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
    else (select jsonb_build_object('error', 'ไม่รู้จักคำสั่ง ' || p_action))
  end;
end $$;


-- ==================== 09_detail_seed.sql
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

-- rent and investment as in the business transfer booking of 5 Oct 2569 (unconfirmed until the new lease is signed)
insert into fixed_expenses(name, category_id, amount, due_day, start_month, confirmed, note)
select 'ค่าเช่าร้าน', (select id from expense_categories where name = 'ค่าเช่า'), 5800, 1, date_trunc('month', rsa_today())::date, false,
       'ตามข้อตกลงจองรับโอนกิจการ 5 ต.ค. 2569 (สัญญาเช่า 6 เดือน) รอสัญญาเช่าใหม่ยืนยันวันเริ่มเช่าและวันครบกำหนด (ยังไม่สร้างบิลจนกว่าจะยืนยัน)'
where not exists (select 1 from fixed_expenses where name = 'ค่าเช่าร้าน');

insert into capital_entries(kind, party, amount, occurred_at, category, counts_as_investment, in_payback, refundable_amount, data_status, note)
select 'investment_item', 'เจ้าของ', v.amt, now(), v.cat, true, true, v.refund, 'ต้องตรวจทาน', v.note
from (values ('ค่าโอนกิจการ (รวมอุปกรณ์ตามบัญชีแนบท้าย 1)', 47500::numeric, 0::numeric,
              'ตามข้อตกลงจอง 5 ต.ค. 2569 · รวมค่าจอง 7,000 ที่ชำระแล้ว · ส่วนที่เหลือ 40,500 ชำระภายใน 31 ต.ค. 2569 พร้อมสัญญาเช่าใหม่'),
             ('เงินประกัน / ค่าแรกเข้า', 5800, 0, 'ตามเงื่อนไขเช่าก่อนจอง · ยังไม่รู้ว่าคืนได้เท่าไร ตรวจกับสัญญาเช่าใหม่')) v(cat, amt, refund, note)
where not exists (select 1 from capital_entries where kind = 'investment_item');

-- databases installed before the contract figures were known: correct only the untouched sample rows (unconfirmed, still at the old values)
update fixed_expenses set amount = 5800,
       note = 'ตามข้อตกลงจองรับโอนกิจการ 5 ต.ค. 2569 (สัญญาเช่า 6 เดือน) รอสัญญาเช่าใหม่ยืนยันวันเริ่มเช่าและวันครบกำหนด (ยังไม่สร้างบิลจนกว่าจะยืนยัน)'
 where name = 'ค่าเช่าร้าน' and amount = 6000 and not confirmed;
update capital_entries set category = 'ค่าโอนกิจการ (รวมอุปกรณ์ตามบัญชีแนบท้าย 1)', amount = 47500,
       note = 'ตามข้อตกลงจอง 5 ต.ค. 2569 · รวมค่าจอง 7,000 ที่ชำระแล้ว · ส่วนที่เหลือ 40,500 ชำระภายใน 31 ต.ค. 2569 พร้อมสัญญาเช่าใหม่'
 where kind = 'investment_item' and category = 'ค่าเซ้ง / Key money' and amount = 50000 and data_status = 'ต้องตรวจทาน' and created_by is null and status = 'done';
update capital_entries set category = 'เงินประกัน / ค่าแรกเข้า', amount = 5800, refundable_amount = 0,
       note = 'ตามเงื่อนไขเช่าก่อนจอง · ยังไม่รู้ว่าคืนได้เท่าไร ตรวจกับสัญญาเช่าใหม่'
 where kind = 'investment_item' and category = 'เงินประกัน / Deposit' and amount = 11600 and data_status = 'ต้องตรวจทาน' and created_by is null and status = 'done';
-- the booking fee is part of the 47,500 transfer price, so the separate row would count it twice: cancel it (kept in history)
update capital_entries set status = 'cancelled', cancel_reason = 'ค่าจอง 7,000 เป็นส่วนหนึ่งของค่าโอนกิจการ 47,500 (ข้อตกลงจอง 5 ต.ค. 2569) ไม่นับซ้ำ'
 where kind = 'investment_item' and category = 'ค่าจอง / Booking fee' and amount = 7000 and data_status = 'ต้องตรวจทาน' and created_by is null and status = 'done';

-- wages: advances are not costs by themselves (they are deducted from the weekly wage, which is the cost)
insert into expense_categories(name, tax_category, staff_allowed) values ('เบิกค่าแรงล่วงหน้า', 'เงินเบิกล่วงหน้าพนักงาน', false) on conflict (name) do nothing;
insert into settings(key, value, confirmed) values ('payroll_week_start', '1', false) on conflict (key) do nothing;
-- v7: evening markdown start time and shop holidays (empty until the owner sets them)
insert into settings(key, value, confirmed) values ('markdown_from', '""', false), ('closed_weekdays', '[]', false), ('closed_dates', '[]', true)
on conflict (key) do nothing;

-- ==================== 10_count_units.sql
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

-- ==================== 11_delivery_recon.sql
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
            'fee_pct', (select fee_pct from channels where id = rsa_uuid(p, 'channel_id')),
            -- what the imported platform file says for the same days (fills the payout form)
            'platform', (select case when count(*) > 0 then jsonb_build_object('orders', count(*), 'gross', sum(po.gross), 'discount', sum(po.shop_discount),
                           'commission', sum(po.commission), 'vat', sum(po.vat), 'other', sum(po.other_fee)) end
                         from platform_orders po where po.channel_id = rsa_uuid(p, 'channel_id') and po.status = 'done' and po.platform_status = 'completed'
                           and po.biz_date between rsa_date(p, 'from') and rsa_date(p, 'to')))
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

-- ==================== 12_payroll.sql
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
    when 'receipt.set_price'  then rsa__receipt_set_price(u, p)
    when 'receipt.review'     then rsa__receipt_review(u, p)
    when 'stock.unit_set'     then rsa__stock_unit_set(u, p)
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
    when 'data.purge'         then rsa__data_purge(u, p)
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

-- ==================== 13_import.sql
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

-- ==================== 14_costs.sql
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

-- ==================== 15_dashboard.sql
-- RSA - POS Assistant : the overview in one call (today live, KPIs, this month against the plan, what to do)
-- and the money plan by month (what must be paid, whether the money is there). Safe to run again.
set check_function_bodies = off;

-- ---------------------------------------------------------------- small helpers
create or replace function rsa_open_count(p_from date, p_to date) returns int language sql stable as $$
  select count(*)::int from generate_series(p_from, p_to, interval '1 day') g where p_from <= p_to and rsa_is_open(g::date)
$$;

-- delivery money expected in by a date (unsettled orders after the channel's settlement days)
create or replace function rsa_delivery_in(p_to date) returns numeric language sql stable as $$
  select coalesce(sum(o.total - o.refunded - o.est_fee), 0) from orders o join channels c on c.id = o.channel_id
   where o.channel_kind = 'delivery' and o.status <> 'cancelled' and o.settlement_id is null and o.biz_date + c.settlement_days <= p_to
$$;

create or replace function rsa_kpi_tone(v numeric, t numeric) returns text language sql immutable as $$
  select case when v is null or coalesce(t, 0) = 0 then 'none' when v >= t then 'ok' when v >= t * 0.85 then 'warn' else 'bad' end
$$;

create or replace function rsa_th_day(d date) returns text language sql immutable as $$
  select extract(day from d)::int || ' ' || (array['ม.ค.','ก.พ.','มี.ค.','เม.ย.','พ.ค.','มิ.ย.','ก.ค.','ส.ค.','ก.ย.','ต.ค.','พ.ย.','ธ.ค.'])[extract(month from d)::int]
$$;

-- ---------------------------------------------------------------- overview
create or replace function rsa__dashboard_home(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  t date := rsa_today(); m0 date; m1 date; v_dash jsonb; v_cc jsonb; v_sm jsonb; v_plan jsonb; kt jsonb;
  v_open_all int; v_open_done int; v_open_left int; v_target numeric; v_day_target numeric; v_to_date numeric; v_need numeric;
  v_today numeric; v_sf numeric; v_dl numeric; v_orders int; v_dl_n int; v_dl_avg numeric; v_sticks numeric; v_fruit numeric;
  v_fruit7 numeric; v_waste7 numeric; v_waste_pct numeric; v_kpis jsonb; v_cash numeric := rsa_cash_total(); v_min numeric := rsa_setting_num('min_working_capital', 0);
  v_lw jsonb; v_ratios jsonb; v_ratio_bad jsonb; v_net numeric; v_net_t numeric; v_checks jsonb := '[]'; v_level text;
  v_todo jsonb := '[]'; v_due14 numeric; v_spare numeric; v_now time := (now() at time zone 'Asia/Bangkok')::time; v_past int;
  v_live jsonb; v_tips jsonb := '[]'; v_k jsonb;
begin
  perform rsa_need(u, 'report.view');
  m0 := date_trunc('month', t)::date; m1 := (m0 + interval '1 month - 1 day')::date;
  v_dash := rsa__dashboard(u, jsonb_build_object('date', t));
  v_cc := rsa_costs_compute(t); v_sm := v_cc->'summary';
  v_plan := coalesce(rsa_setting('monthly_plan', '{}') -> to_char(m0, 'YYYY-MM'), '{}');
  kt := '{"meatball_sticks":115,"fruit_storefront":1350,"delivery_bills":6,"delivery_avg":140,"waste_pct":0.05}'::jsonb
        || case when jsonb_typeof(rsa_setting('kpi_targets')) = 'object' then rsa_setting('kpi_targets') else '{}' end;

  -- sales against the month target, paced by open days
  v_open_all := greatest(rsa_open_count(m0, m1), 1); v_open_done := rsa_open_count(m0, t); v_open_left := rsa_open_count(t + 1, m1);
  v_target := nullif(v_plan->>'sales_target', '')::numeric;
  v_day_target := coalesce(nullif(v_plan->>'daily_target', '')::numeric, case when v_target > 0 then round(v_target / v_open_all, 2) end);
  v_to_date := case when v_target > 0 then round(v_target * v_open_done / v_open_all, 2) end;
  v_need := case when v_target > 0 and v_open_left > 0 then greatest(round((v_target - (v_cc->>'sales')::numeric) / v_open_left, 2), 0) end;

  -- today's KPIs from the orders
  select coalesce(sum(total - refunded), 0), coalesce(sum(total - refunded) filter (where channel_kind = 'storefront'), 0),
         coalesce(sum(total - refunded) filter (where channel_kind = 'delivery'), 0), count(*), count(*) filter (where channel_kind = 'delivery')
    into v_today, v_sf, v_dl, v_orders, v_dl_n from orders where biz_date = t and status <> 'cancelled';
  v_dl_avg := case when v_dl_n > 0 then round(v_dl / v_dl_n, 2) end;
  select coalesce(sum(i.qty) filter (where pr.category ~ '(ลูกชิ้น|ทอด)'), 0), coalesce(sum(i.line_total) filter (where pr.category ~ 'ผลไม้'), 0)
    into v_sticks, v_fruit from order_items i join orders o on o.id = i.order_id left join products pr on pr.id = i.product_id
   where o.biz_date = t and o.status <> 'cancelled' and o.channel_kind = 'storefront';
  select coalesce(sum(i.line_total), 0) into v_fruit7 from order_items i join orders o on o.id = i.order_id join products pr on pr.id = i.product_id
   where o.biz_date between t - 6 and t and o.status <> 'cancelled' and pr.category ~ 'ผลไม้';
  select coalesce(sum(qty * unit_cost), 0) into v_waste7 from waste_records where status = 'recorded' and kind = 'waste' and biz_date between t - 6 and t;
  v_waste_pct := case when v_fruit7 > 0 then round(v_waste7 / v_fruit7, 3) end;
  v_kpis := jsonb_build_array(
    jsonb_build_object('key', 'today', 'label', 'ยอดวันนี้', 'value', v_today, 'unit', 'baht', 'target', v_day_target, 'tone', rsa_kpi_tone(v_today, v_day_target), 'href', 'sales'),
    jsonb_build_object('key', 'sticks', 'label', 'ลูกชิ้นหน้าร้าน', 'value', v_sticks, 'unit', 'ไม้', 'target', kt->'meatball_sticks', 'tone', rsa_kpi_tone(v_sticks, (kt->>'meatball_sticks')::numeric), 'href', 'products'),
    jsonb_build_object('key', 'fruit', 'label', 'ผลไม้หน้าร้าน', 'value', v_fruit, 'unit', 'baht', 'target', kt->'fruit_storefront', 'tone', rsa_kpi_tone(v_fruit, (kt->>'fruit_storefront')::numeric), 'href', 'products'),
    jsonb_build_object('key', 'bills', 'label', 'บิล Delivery', 'value', v_dl_n, 'unit', 'บิล', 'target', kt->'delivery_bills', 'tone', rsa_kpi_tone(v_dl_n, (kt->>'delivery_bills')::numeric), 'href', 'delivery'),
    jsonb_build_object('key', 'avg', 'label', 'เฉลี่ยต่อบิล Delivery', 'value', v_dl_avg, 'unit', 'baht', 'target', kt->'delivery_avg', 'tone', rsa_kpi_tone(v_dl_avg, (kt->>'delivery_avg')::numeric), 'href', 'delivery'),
    jsonb_build_object('key', 'waste', 'label', 'ของเสีย 7 วัน', 'value', v_waste_pct, 'unit', 'pct', 'target', kt->'waste_pct', 'max', true, 'href', 'products',
      'tone', case when v_waste_pct is null then 'none' when v_waste_pct <= (kt->>'waste_pct')::numeric then 'ok' when v_waste_pct <= (kt->>'waste_pct')::numeric * 1.4 then 'warn' else 'bad' end));

  -- business status: profit pace, money, raw-material cost (last complete week)
  select x into v_lw from jsonb_array_elements(v_cc->'weeks') x where (x->>'complete')::boolean order by x->>'from' desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('key', r.key, 'ratio', (r.value->>'ratio')::numeric, 'limit', r.value->'limit')), '[]') into v_ratios
    from jsonb_each(coalesce(v_lw->'ratios', '{}')) r where r.key in ('fruit', 'meatball') and r.value->>'ratio' is not null;
  select coalesce(jsonb_agg(x), '[]') into v_ratio_bad from jsonb_array_elements(v_ratios) x where x->>'limit' is not null and (x->>'ratio')::numeric > (x->>'limit')::numeric;
  v_net := (v_sm->>'net_profit')::numeric; v_net_t := nullif(v_sm->>'net_target_to_date', '')::numeric;
  if v_min > 0 and v_cash < v_min then v_checks := v_checks || jsonb_build_array(jsonb_build_array('bad', 'เงินต่ำกว่าเงินหมุนขั้นต่ำ ' || to_char(v_min - v_cash, 'FM999,999,990') || ' บาท')); end if;
  if v_net < 0 then v_checks := v_checks || jsonb_build_array(jsonb_build_array('bad', 'เดือนนี้ยังขาดทุน ' || to_char(-v_net, 'FM999,999,990') || ' บาท')); end if;
  if v_net_t > 0 and v_net >= 0 and v_net < v_net_t then v_checks := v_checks || jsonb_build_array(jsonb_build_array('warn', 'กำไรยังต่ำกว่าเป้า ' || to_char(v_net_t - v_net, 'FM999,999,990') || ' บาท')); end if;
  if v_to_date > 0 and (v_cc->>'sales')::numeric < v_to_date * 0.95 then
    v_checks := v_checks || jsonb_build_array(jsonb_build_array('warn', 'ยอดขายช้ากว่าเป้า ' || round((1 - (v_cc->>'sales')::numeric / v_to_date) * 100) || '%')); end if;
  select v_checks || coalesce(jsonb_agg(jsonb_build_array('warn', 'ต้นทุน' || case x->>'key' when 'fruit' then 'ผลไม้' else 'ลูกชิ้น' end || 'เกินเกณฑ์')), '[]')
    into v_checks from jsonb_array_elements(v_ratio_bad) x;
  v_level := case when exists (select 1 from jsonb_array_elements(v_checks) c where c->>0 = 'bad') then 'bad' when jsonb_array_length(v_checks) > 0 then 'warn' else 'ok' end;

  -- to do: today's close first, a loan installment the money cannot cover, then the usual list
  if v_dash->'close' is null or jsonb_typeof(v_dash->'close') = 'null' then
    if not (v_dash->>'holiday')::boolean then
      v_todo := v_todo || jsonb_build_object('kind', 'close_today', 'level', 'bad', 'text', 'ปิดยอดวันนี้', 'sub', 'ส่งภายใน ' || (v_dash->>'due_time') || ' น.', 'act', 'ไป');
    end if;
  end if;
  v_due14 := rsa_debt_due(t + 14); v_spare := v_cash - v_min;
  if v_due14 > 0 and v_spare < v_due14 then
    v_todo := v_todo || jsonb_build_object('kind', 'debt_short', 'level', 'bad', 'text', 'เตรียมเงินผ่อนเงินกู้ลงทุน ขาด ' || to_char(v_due14 - v_spare, 'FM999,999,990') || ' บาท',
      'sub', 'งวดครบกำหนดภายใน 14 วัน ' || to_char(v_due14, 'FM999,999,990') || ' บาท', 'act', 'ดู');
  end if;
  select v_todo || coalesce(jsonb_agg(e || jsonb_build_object('level', case when e->>'level' = 'warn' then 'warn' else 'info' end, 'act', 'ดู')), '[]')
    into v_todo from jsonb_array_elements(v_dash->'exceptions') e where e->>'kind' <> 'close_today';
  select coalesce(jsonb_agg(x order by case x->>'level' when 'bad' then 0 when 'warn' then 1 else 2 end, n), '[]') into v_todo
    from jsonb_array_elements(v_todo) with ordinality a(x, n);

  -- live: today so far against the same weekday last week at the same time, and by hour against the last 4 same weekdays
  select count(distinct biz_date) into v_past from orders where status <> 'cancelled' and biz_date in (t - 7, t - 14, t - 21, t - 28);
  v_live := jsonb_build_object('sales', v_today, 'orders', v_orders, 'storefront', v_sf, 'delivery', v_dl, 'target', v_day_target,
    'last_week', (select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and biz_date = t - 7 and (created_at at time zone 'Asia/Bangkok')::time <= v_now),
    'last_at', (select max(created_at) from orders where status <> 'cancelled' and biz_date = t),
    'now', to_char(v_now, 'HH24:MI'),
    'hours', (select jsonb_agg(jsonb_build_object('h', h,
        'today', (select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and biz_date = t and extract(hour from created_at at time zone 'Asia/Bangkok') = h),
        'avg', case when v_past > 0 then round((select coalesce(sum(total - refunded), 0) from orders where status <> 'cancelled' and biz_date in (t - 7, t - 14, t - 21, t - 28)
                                                and extract(hour from created_at at time zone 'Asia/Bangkok') = h) / v_past, 2) else 0 end) order by h)
              from generate_series(9, 22) h));

  -- what to do about the numbers (rules from the owner's alert sheet)
  if v_need is not null and v_day_target > 0 and v_need > v_day_target * 1.1 then
    v_tips := v_tips || to_jsonb('ยอดเดือนตามหลังเป้า ต้องขายเพิ่มเป็นวันละ ' || to_char(v_need, 'FM999,999,990') || ' บาท · ดันชุดคู่ / กล่องรวม 49 และเปิดแอดเฉพาะแอปที่ได้ออเดอร์'); end if;
  select x into v_k from jsonb_array_elements(v_kpis) x where x->>'key' = 'sticks';
  if v_k->>'tone' in ('warn', 'bad') then v_tips := v_tips || to_jsonb('ลูกชิ้นหน้าร้านต่ำกว่าเป้า · เช็กของพอขาย คุณภาพการทอด และชวนลูกค้าเพิ่มไม้'::text); end if;
  select x into v_k from jsonb_array_elements(v_kpis) x where x->>'key' = 'avg';
  if v_k->>'tone' in ('warn', 'bad') and v_dl_n > 0 then v_tips := v_tips || to_jsonb('บิล Delivery เล็ก · ดัน Family Set / ลูกชิ้น Mix 10 และเสนอ add-on'::text); end if;
  select x into v_k from jsonb_array_elements(v_kpis) x where x->>'key' = 'waste';
  if v_k->>'tone' in ('warn', 'bad') then v_tips := v_tips || to_jsonb('ของเสียสูง · ลดปริมาณซื้อรอบหน้า และใช้ราคาลดตอนเย็น'::text); end if;
  if jsonb_array_length(v_ratio_bad) > 0 then v_tips := v_tips || to_jsonb('ต้นทุนวัตถุดิบเกินเกณฑ์ · เช็กราคาซื้อ yield และขนาดกล่อง'::text); end if;

  return jsonb_build_object('date', t, 'month', to_char(m0, 'YYYY-MM'), 'holiday', v_dash->'holiday', 'close', v_dash->'close', 'due_time', v_dash->'due_time',
    'live', v_live, 'tips', (select coalesce(jsonb_agg(x), '[]') from (select x from jsonb_array_elements(v_tips) x limit 3) y),
    'status', jsonb_build_object('level', v_level, 'reasons', (select coalesce(jsonb_agg(c->>1), '[]') from jsonb_array_elements(v_checks) c),
      'net_profit', v_net, 'net_target_to_date', v_net_t, 'net_target', v_sm->'net_target', 'cash', v_cash, 'min_cash', v_min, 'ratios', v_ratios,
      'complete', v_sm->'complete', 'flags', v_sm->'flags'),
    'sales', jsonb_build_object('month', v_cc->'sales', 'target', v_target, 'to_date', v_to_date, 'need_per_day', v_need, 'open_left', v_open_left,
      'open_done', v_open_done, 'open_all', v_open_all, 'day_target', v_day_target),
    'kpis', v_kpis, 'todo', v_todo);
end $$;

-- ---------------------------------------------------------------- money plan by month (rest of this month + next 2)
create or replace function rsa__cashflow_months(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  t date := rsa_today(); v_cash numeric := rsa_cash_total(); v_min numeric := rsa_setting_num('min_working_capital', 0);
  v_sales numeric; v_spend numeric; v_out jsonb; v_paid numeric; v_months jsonb := '[]'; k int; m0 date; m1 date; v_from date;
  v_items jsonb; v_lines jsonb; v_start numeric; v_inflow numeric; v_total numeric; v_end numeric; v_short numeric; v_wage int; v_loan numeric; v_advice text;
begin
  perform rsa_need(u, 'cashflow.view');
  if rsa_has(u, 'expense.approve') then perform rsa_fixed_generate(u, date_trunc('month', t)::date); end if;
  select coalesce(sum(total - refunded), 0) / rsa_open_days(t - 14, t - 1) into v_sales from orders
   where channel_kind = 'storefront' and status <> 'cancelled' and biz_date between t - 14 and t - 1;
  select coalesce(sum(amount), 0) / 30 into v_spend from expenses
   where status = 'จ่ายแล้ว' and fixed_expense_id is null and rsa_bdate(paid_at) between t - 30 and t - 1;
  v_paid := coalesce((select sum(amount) from capital_entries where kind = 'loan_repayment' and status = 'done'), 0);

  -- every payment due from tomorrow on: open bills, recurring costs not billed yet, loan installments still unpaid
  select coalesce(jsonb_agg(x), '[]') into v_out from (
    select jsonb_build_object('date', greatest(coalesce(e.due_date, rsa_bdate(e.occurred_at)), t + 1), 'amount', e.amount,
             'group', case when e.tax_category = 'เงินเดือนและค่าจ้าง' then 'wage' when e.fixed_expense_id is not null then 'fixed' else 'bill' end,
             'name', coalesce((select name from fixed_expenses f where f.id = e.fixed_expense_id), e.description)) x
      from expenses e where e.status in ('รออนุมัติ','รอทำจ่าย')
    union all
    select jsonb_build_object('date', d, 'amount', f.amount, 'group', case when c.tax_category = 'เงินเดือนและค่าจ้าง' then 'wage' else 'fixed' end, 'name', f.name)
      from fixed_expenses f left join expense_categories c on c.id = f.category_id
      cross join lateral rsa_fixed_dates(f, (date_trunc('month', t) + interval '1 month')::date, t + 100) d
     where f.active and f.confirmed
    union all
    select jsonb_build_object('date', greatest(s.due, t + 1), 'amount', s.left_amt, 'group', 'loan', 'name', 'ผ่อนเงินกู้ลงทุน งวด ' || s.n)
      from (select (v->>'due')::date due, n, greatest(least((v->>'amount')::numeric, sum((v->>'amount')::numeric) over (order by v->>'due', n) - v_paid), 0) left_amt
              from jsonb_array_elements(case when jsonb_typeof(rsa_setting('debt_schedule')) = 'array' then rsa_setting('debt_schedule') else '[]' end) with ordinality a(v, n)) s
     where s.left_amt > 0) q;

  for k in 0..2 loop
    m0 := (date_trunc('month', t) + make_interval(months => k))::date; m1 := (m0 + interval '1 month - 1 day')::date;
    v_from := case when k = 0 then t + 1 else m0 end;
    select coalesce(jsonb_agg(x), '[]') into v_items from jsonb_array_elements(v_out) x where (x->>'date')::date between v_from and m1;
    select coalesce(jsonb_agg(jsonb_build_object('name', g.key, 'group', g.grp, 'amount', g.amount, 'rounds', g.rounds,
             'label', case g.grp when 'wage' then 'ค่าจ้าง ' || g.rounds || ' รอบ' when 'loan' then g.key || ' · ' || rsa_th_day(g.first_date)
                                 when 'bill' then 'ค้างจ่ายอื่น ' || g.rounds || ' รายการ' else g.key || case when g.rounds > 1 then ' ' || g.rounds || ' รอบ' else '' end end)
             order by case g.grp when 'loan' then 0 when 'wage' then 1 when 'fixed' then 2 else 3 end, g.amount desc), '[]') into v_lines
      from (select case x->>'group' when 'wage' then 'ค่าจ้าง' when 'bill' then 'ค่าใช้จ่ายค้างจ่าย' else x->>'name' end key, min(x->>'group') grp,
                   sum((x->>'amount')::numeric) amount, count(*)::int rounds, min((x->>'date')::date) first_date
              from jsonb_array_elements(v_items) x group by 1) g;
    v_start := case when k = 0 then v_cash else
      round(v_cash + v_sales * rsa_open_count(t + 1, m0 - 1) + rsa_delivery_in(m0 - 1) - v_spend * (m0 - 1 - t)
            - (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_out) x where (x->>'date')::date <= m0 - 1), 2) end;
    v_inflow := round(v_sales * rsa_open_count(v_from, m1) + rsa_delivery_in(m1) - rsa_delivery_in(v_from - 1) - v_spend * (m1 - v_from + 1), 2);
    v_total := (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_items) x);
    v_end := round(v_start + v_inflow - v_total, 2);
    v_short := case when v_end < v_min then round(v_min - v_end, 2) else 0 end;
    v_wage := (select count(*) from jsonb_array_elements(v_items) x where x->>'group' = 'wage');
    v_loan := (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_items) x where x->>'group' = 'loan');
    v_advice := case when v_short > 0 and v_loan > 0 then 'เตรียมเงินเติมจากเจ้าของ หรือคุยขอเลื่อนงวดเงินกู้ลงทุน'
                     when v_short > 0 then 'ลดการซื้อที่ไม่จำเป็น และตามเงิน Delivery ที่ค้าง'
                     when v_wage >= 5 then 'เดือนนี้จ่ายค่าจ้าง 5 รอบ กันเงินเพิ่ม 1 รอบ' else '' end;
    v_months := v_months || jsonb_build_object('month', to_char(m0, 'YYYY-MM'), 'from', v_from, 'to', m1, 'partial', k = 0, 'start_cash', v_start,
      'inflow', v_inflow, 'total', v_total, 'end_cash', v_end, 'short', v_short, 'wage_rounds', v_wage, 'loan', v_loan, 'lines', v_lines, 'advice', v_advice,
      'status', case when v_short > 0 then 'short' when v_wage >= 5 then 'five' else 'ok' end);
  end loop;

  return jsonb_build_object('today', t, 'cash', v_cash, 'min_cash', v_min, 'months', v_months,
    'daily', (select jsonb_agg(jsonb_build_object('date', t + n,
        'balance', case when n = 0 then v_cash else round(v_cash + v_sales * rsa_open_count(t + 1, t + n) + rsa_delivery_in(t + n) - v_spend * n
                     - (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_out) x where (x->>'date')::date <= t + n), 2) end,
        'loan', (select coalesce(sum((x->>'amount')::numeric), 0) from jsonb_array_elements(v_out) x where x->>'group' = 'loan' and (x->>'date')::date = t + n))
      order by n) from generate_series(0, 60) n));
end $$;

-- ==================== 16_calendar.sql
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

-- ==================== 17_purge.sql
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

-- ==================== 18_receive.sql
-- RSA - POS Assistant : receiving in any unit, price filled in later, owner review of every staff receipt,
-- required evidence (or a reason) for money already paid.
--   * A line can be bought in any unit (กก. / ลูก / หวี / เข่ง / แพ็ก …). Known factor → converted into the stock unit.
--     Unknown factor → the bill still counts; the stock waits ("รอใส่ตัวแปลง") until the owner sets 1 <unit> ≈ x <stock unit>.
--   * "ไม่รู้ราคา": goods enter stock now, the bill waits for the owner to fill the price and how it was paid.
--   * Every receipt a staff member records waits in the owner's queue until checked.
set check_function_bodies = off;

alter table stock_receipt_lines add column if not exists buy_unit text;
alter table stock_receipt_lines add column if not exists buy_qty numeric(14,3);
alter table stock_receipt_lines add column if not exists unit_pending boolean not null default false;
alter table stock_receipt_lines add column if not exists stock_posted boolean not null default true;
alter table stock_receipts add column if not exists price_pending boolean not null default false;
alter table stock_receipts add column if not exists pay_ref text;
alter table stock_receipts add column if not exists no_evidence_reason text;
alter table stock_receipts add column if not exists reviewed_at timestamptz;
alter table stock_receipts add column if not exists reviewed_by uuid references app_users(id);
alter table expenses add column if not exists no_evidence_reason text;
-- receipts made before this version are not put in the review queue
insert into settings(key, value, confirmed) values ('receipt_review_since', to_jsonb(now()), true) on conflict (key) do nothing;

-- 1 <unit> of a stock item in its stock unit (null = not known yet)
create or replace function rsa_unit_factor(p_item stock_items, p_unit text) returns numeric language sql stable as $$
  select case when coalesce(nullif(trim(p_unit), ''), p_item.unit) = p_item.unit then 1::numeric
    else (select nullif(x->>'factor', '')::numeric from jsonb_array_elements(p_item.count_units) x
           where x->>'unit' = trim(p_unit) and nullif(x->>'factor', '')::numeric > 0 limit 1) end
$$;

-- remember a unit on the stock item (factor may be null = known name, size not known yet)
create or replace function rsa_unit_learn(p_item uuid, p_unit text, p_factor numeric) returns void language plpgsql as $$
declare v stock_items;
begin
  select * into v from stock_items where id = p_item for update;
  if not found or coalesce(trim(p_unit), '') = '' or trim(p_unit) = v.unit then return; end if;
  if p_factor is null and exists (select 1 from jsonb_array_elements(v.count_units) x where x->>'unit' = trim(p_unit)) then return; end if;
  update stock_items set count_units = coalesce((select jsonb_agg(x) from jsonb_array_elements(v.count_units) x where x->>'unit' <> trim(p_unit)), '[]')
         || jsonb_build_array(jsonb_build_object('unit', trim(p_unit), 'factor', p_factor))
   where id = p_item;
end $$;

-- spread transport over the lines and put the lines whose quantity is known into stock
create or replace function rsa_receipt_post(u app_users, p_id uuid) returns void language plpgsql as $$
declare v stock_receipts; r record; v_n int; v_bsum numeric; v_basis numeric; v_alloc numeric; v_rest numeric; v_landed numeric; v_cur numeric; v_item stock_items; k int := 0; v_method text;
begin
  select * into v from stock_receipts where id = p_id;
  v_method := coalesce(v.transport_method, 'value');
  select count(*), coalesce(sum(case v_method when 'value' then line_total when 'weight' then coalesce(weight, buy_qty, qty) else 1 end), 0)
    into v_n, v_bsum from stock_receipt_lines where receipt_id = p_id;
  if v_bsum <= 0 then v_method := 'equal'; v_bsum := v_n; end if;
  v_rest := v.transport_cost;
  for r in select * from stock_receipt_lines where receipt_id = p_id order by id loop
    k := k + 1;
    v_basis := case v_method when 'value' then r.line_total when 'weight' then coalesce(r.weight, r.buy_qty, r.qty) else 1 end;
    v_alloc := case when k = v_n then v_rest else round(v.transport_cost * v_basis / v_bsum, 2) end;
    v_rest := v_rest - v_alloc;
    v_landed := case when r.unit_pending then null else round((r.line_total + v_alloc) / r.qty, 4) end;
    update stock_receipt_lines set transport_alloc = v_alloc, landed_unit_cost = v_landed,
           unit_cost = case when r.unit_pending then 0 else round(r.line_total / r.qty, 4) end where id = r.id;
    if not r.stock_posted and not r.unit_pending then
      select * into v_item from stock_items where id = r.stock_item_id for update;
      if not v.price_pending and v_landed > 0 then
        v_cur := greatest(rsa_stock_qty(v_item.id), 0);
        update stock_items set avg_cost = round((v_cur * avg_cost + r.qty * v_landed) / (v_cur + r.qty), 4) where id = v_item.id;
      end if;
      insert into stock_ledger(stock_item_id, occurred_at, qty, kind, source_type, source_id, unit_cost, created_by)
      values (v_item.id, v.received_at, r.qty, 'receipt', 'receipt', p_id, case when v.price_pending then null else v_landed end, u.id);
      update stock_receipt_lines set stock_posted = true where id = r.id;
    end if;
  end loop;
end $$;

-- the bills of a priced receipt: one per cost category, transport to the travel category
create or replace function rsa_receipt_bills(u app_users, p_id uuid, p jsonb) returns void language plpgsql as $$
declare v stock_receipts; v_src text; v_exp uuid; r record; v_sup suppliers;
begin
  select * into v from stock_receipts where id = p_id;
  select * into v_sup from suppliers where id = v.supplier_id;
  v_src := case when v.payer = 'owner' then 'owner_advance' when v.payer = 'employee' then 'employee_advance'
                when v.pay_method = 'shop_bank' then 'shop_bank' when v.pay_method = 'shop_cash' then 'shop_cash'
                when v.pay_method in ('credit', 'unpaid') then 'credit' end;
  if v_src is null or v.goods_cost + v.transport_cost <= 0 then return; end if;
  for r in
    select coalesce(s.cost_category_id, rsa_receipt_default_category(p)) cat_id, sum(l.line_total) amt, string_agg(l.item_name, ', ' order by l.item_name) names
      from stock_receipt_lines l join stock_items s on s.id = l.stock_item_id where l.receipt_id = p_id
     group by 1
    union all
    select coalesce((select id from expense_categories where active and code = 'A05'), rsa_receipt_default_category(p)), v.transport_cost, 'ค่าขนส่ง / ค่าเดินทางซื้อของ'
     where v.transport_cost > 0
  loop
    continue when r.amt <= 0;
    v_exp := rsa_expense_insert(u, jsonb_build_object(
      'fund_source', v_src, 'amount', r.amt, 'occurred_at', v.received_at, 'supplier_id', v.supplier_id,
      'payee', coalesce(v_sup.name, v.supplier_name), 'pay_ref', v.pay_ref, 'account_id', p->>'account_id', 'employee_id', coalesce(p->>'employee_id', v.created_by::text),
      'category_id', r.cat_id, 'description', 'ซื้อของเข้าร้าน ' || coalesce(v_sup.name, v.supplier_name, '') || ': ' || left(r.names, 120),
      'doc_no', v.ref_no), p_id);
    update stock_receipts set expense_id = coalesce(expense_id, v_exp) where id = p_id;
  end loop;
end $$;

create or replace function rsa__receipt_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare
  v_id uuid := gen_random_uuid(); ln jsonb; v_item stock_items; v_q numeric; v_lt numeric; v_goods numeric := 0; v_f numeric; v_unit text;
  v_trans numeric := greatest(rsa_num(p, 'transport_cost', 0), 0); v_method text := coalesce(nullif(p->>'transport_method', ''), rsa_setting('transport_method', '"value"') #>> '{}', 'value');
  v_sup suppliers; v_at timestamptz := rsa_ts(p, 'received_at'); v_later boolean := coalesce((p->>'price_later')::boolean, false);
  v_pay text := nullif(p->>'pay_method', ''); v_payer text := coalesce(nullif(p->>'payer', ''), 'shop');
  v_noev text := nullif(trim(coalesce(p->>'no_evidence_reason', '')), ''); v_mgr boolean := rsa_has(u, 'expense.approve');
begin
  perform rsa_need(u, 'stock.receive');
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then perform rsa_err('ใส่รายการรับของอย่างน้อย 1 รายการ'); end if;
  if v_method not in ('value','weight','equal') then v_method := 'value'; end if;
  select * into v_sup from suppliers where id = rsa_uuid(p, 'supplier_id');
  if v_sup.id is null and coalesce(trim(p->>'supplier_name'), '') = '' then perform rsa_err('กรุณาระบุว่าซื้อจากร้านไหน / ใคร'); end if;
  -- older clients send an "expense" object with pay_mode
  if v_pay is null and jsonb_typeof(p->'expense') = 'object' then
    v_pay := case p->'expense'->>'pay_mode' when 'drawer' then 'shop_cash' when 'account' then 'shop_bank' when 'employee' then 'shop_cash'
                  when 'later' then 'credit' when 'none' then 'none' end;
    if p->'expense'->>'pay_mode' = 'employee' then v_payer := 'employee'; end if;
  end if;
  if v_later then
    v_pay := null; v_trans := 0;
  else
    if v_pay is null then perform rsa_err('กรุณาเลือกวิธีจ่ายเงิน (ถ้าไม่รู้ราคา ให้ติ๊ก "ไม่รู้ราคา")'); end if;
    if v_pay = 'none' then v_pay := null; end if;
    if not rsa_has_files(p) and v_noev is null then perform rsa_err('แนบรูปบิล / สลิป หรือใส่เหตุผลว่าทำไมไม่มีบิล'); end if;
    if v_pay = 'shop_bank' and v_payer = 'shop' and coalesce(trim(p->>'pay_ref'), '') = '' then perform rsa_err('จ่ายจากบัญชีร้าน ใส่เลขอ้างอิง / เลขที่สลิปด้วย'); end if;
  end if;
  insert into stock_receipts(id, receipt_no, supplier_id, supplier_name, ref_no, received_at, note, transport_cost, transport_method, pay_method, payer, created_by,
                             price_pending, pay_ref, no_evidence_reason, reviewed_at, reviewed_by)
  values (v_id, rsa_next_no('R'), v_sup.id, coalesce(v_sup.name, nullif(trim(p->>'supplier_name'), '')), nullif(p->>'ref_no', ''), v_at,
          nullif(p->>'note', ''), v_trans, v_method, v_pay, case when v_later then null else v_payer end, u.id,
          v_later, nullif(trim(p->>'pay_ref'), ''), v_noev,
          case when v_mgr and not v_later then now() end, case when v_mgr and not v_later then u.id end);

  for ln in select * from jsonb_array_elements(p->'lines') loop
    select * into v_item from stock_items where id = rsa_uuid(ln, 'stock_item_id') and active;
    if not found then perform rsa_err('ไม่พบรายการสต็อก'); end if;
    v_q := coalesce(rsa_num(ln, 'buy_qty'), rsa_num(ln, 'qty'), 0);
    if v_q <= 0 then perform rsa_err('จำนวนรับเข้าของ "' || v_item.name || '" ต้องมากกว่า 0'); end if;
    v_unit := coalesce(nullif(trim(ln->>'unit'), ''), v_item.unit);
    -- a factor typed on the line is remembered on the stock item
    if rsa_num(ln, 'factor') > 0 and v_unit <> v_item.unit then perform rsa_unit_learn(v_item.id, v_unit, rsa_num(ln, 'factor')); select * into v_item from stock_items where id = v_item.id; end if;
    if v_unit <> v_item.unit then perform rsa_unit_learn(v_item.id, v_unit, null); end if;
    v_f := rsa_unit_factor(v_item, v_unit);
    v_lt := case when v_later then 0 else coalesce(rsa_num(ln, 'line_total'), round(v_q * rsa_num(ln, 'unit_cost', 0), 2)) end;
    if v_lt < 0 then perform rsa_err('ราคาติดลบไม่ได้'); end if;
    if not v_later and v_lt <= 0 then perform rsa_err('ใส่ราคาของ "' || v_item.name || '" (ถ้าไม่รู้ราคา ให้ติ๊ก "ไม่รู้ราคา")'); end if;
    insert into stock_receipt_lines(receipt_id, stock_item_id, item_name, unit, qty, unit_cost, line_total, weight, buy_unit, buy_qty, unit_pending, stock_posted)
    values (v_id, v_item.id, v_item.name, case when v_f is null then v_unit else v_item.unit end, case when v_f is null then v_q else round(v_q * v_f, 3) end,
            0, v_lt, rsa_num(ln, 'weight'), v_unit, v_q, v_f is null, false);
    v_goods := v_goods + v_lt;
  end loop;
  update stock_receipts set goods_cost = v_goods, total_cost = v_goods + v_trans where id = v_id;
  perform rsa_receipt_post(u, v_id);
  perform rsa_link_attachments(p->'attachment_ids', 'receipt', v_id, u);
  if not v_later then perform rsa_receipt_bills(u, v_id, p); end if;
  perform rsa_audit(u, 'receipt.create', 'receipt', v_id::text, null,
    jsonb_build_object('goods', v_goods, 'transport', v_trans, 'price_later', v_later, 'lines', jsonb_array_length(p->'lines')));
  return rsa_receipt_json(v_id);
end $$;

-- owner fills the price of a "ไม่รู้ราคา" receipt
create or replace function rsa__receipt_set_price(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v stock_receipts; ln jsonb; r record; v_lt numeric; v_goods numeric := 0; v_landed numeric; v_cur numeric; v_pay text := nullif(p->>'pay_method', '');
begin
  perform rsa_need(u, 'expense.approve');
  select * into v from stock_receipts where id = rsa_uuid(p, 'receipt_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบใบรับของ หรือยกเลิกไปแล้ว'); end if;
  if not v.price_pending then perform rsa_err('ใบรับของนี้ใส่ราคาแล้ว'); end if;
  if v_pay is null then perform rsa_err('กรุณาเลือกวิธีจ่ายเงิน'); end if;
  if not rsa_has_files(p) and coalesce(trim(p->>'no_evidence_reason'), '') = '' then perform rsa_err('แนบรูปบิล / สลิป หรือใส่เหตุผลว่าทำไมไม่มีบิล'); end if;
  for r in select * from stock_receipt_lines where receipt_id = v.id loop
    select x into ln from jsonb_array_elements(coalesce(p->'lines', '[]')) x where x->>'id' = r.id::text;
    v_lt := rsa_num(ln, 'line_total', 0);
    if v_lt <= 0 then perform rsa_err('ใส่ราคาของ "' || r.item_name || '" ให้ครบทุกรายการ'); end if;
    update stock_receipt_lines set line_total = v_lt where id = r.id;
    v_goods := v_goods + v_lt;
  end loop;
  update stock_receipts set price_pending = false, pay_method = case when v_pay = 'none' then null else v_pay end, payer = coalesce(nullif(p->>'payer', ''), 'shop'),
         pay_ref = nullif(trim(p->>'pay_ref'), ''), no_evidence_reason = nullif(trim(p->>'no_evidence_reason'), ''),
         transport_cost = greatest(rsa_num(p, 'transport_cost', v.transport_cost), 0), goods_cost = v_goods,
         total_cost = v_goods + greatest(rsa_num(p, 'transport_cost', v.transport_cost), 0), reviewed_at = now(), reviewed_by = u.id
   where id = v.id;
  perform rsa_receipt_post(u, v.id);
  -- goods already in stock came in at the old average: move the average toward the real landed cost
  for r in select l.*, s.avg_cost from stock_receipt_lines l join stock_items s on s.id = l.stock_item_id where l.receipt_id = v.id and l.stock_posted and l.landed_unit_cost > 0 loop
    v_cur := greatest(rsa_stock_qty(r.stock_item_id), r.qty);
    update stock_items set avg_cost = round(greatest(avg_cost + r.qty * (r.landed_unit_cost - avg_cost) / v_cur, 0), 4) where id = r.stock_item_id;
  end loop;
  perform rsa_link_attachments(p->'attachment_ids', 'receipt', v.id, u);
  perform rsa_receipt_bills(u, v.id, p);
  perform rsa_audit(u, 'receipt.price', 'receipt', v.id::text, null, jsonb_build_object('goods', v_goods, 'pay_method', v_pay));
  return rsa_receipt_json(v.id);
end $$;

-- a unit size known now (receiving, the owner's sheet, or the stock item form): waiting receipt lines go into stock
create or replace function rsa_unit_post_pending(p_item uuid) returns int language plpgsql as $$
declare v_item stock_items; r record; v_f numeric; n int := 0; v_u app_users;
begin
  select * into v_item from stock_items where id = p_item;
  for r in select l.*, s.created_by rcv_by from stock_receipt_lines l join stock_receipts s on s.id = l.receipt_id
            where l.stock_item_id = p_item and l.unit_pending and s.status <> 'cancelled' loop
    v_f := rsa_unit_factor(v_item, r.buy_unit);
    continue when v_f is null;
    update stock_receipt_lines set qty = round(r.buy_qty * v_f, 3), unit = v_item.unit, unit_pending = false where id = r.id;
    select * into v_u from app_users where id = r.rcv_by;
    perform rsa_receipt_post(v_u, r.receipt_id);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function rsa_stock_units_changed() returns trigger language plpgsql as $$
begin
  if new.count_units is distinct from old.count_units then perform rsa_unit_post_pending(new.id); end if;
  return new;
end $$;
drop trigger if exists stock_items_units_changed on stock_items;
create trigger stock_items_units_changed after update of count_units on stock_items for each row execute function rsa_stock_units_changed();

create or replace function rsa__stock_unit_set(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_item stock_items; v_f numeric := rsa_num(p, 'factor', 0); v_unit text := trim(coalesce(p->>'unit', '')); n int;
begin
  perform rsa_need(u, 'master.manage');
  select * into v_item from stock_items where id = rsa_uuid(p, 'stock_item_id');
  if not found then perform rsa_err('ไม่พบวัตถุดิบ'); end if;
  if v_unit = '' or v_f <= 0 then perform rsa_err('ใส่ชื่อหน่วยและจำนวนให้ครบ เช่น 1 หวี ≈ 1.2 ' || v_item.unit); end if;
  select count(*) into n from stock_receipt_lines l join stock_receipts s on s.id = l.receipt_id
   where l.stock_item_id = v_item.id and l.unit_pending and l.buy_unit = v_unit and s.status <> 'cancelled';
  perform rsa_unit_learn(v_item.id, v_unit, v_f);   -- the trigger puts the waiting lines into stock
  perform rsa_audit(u, 'stock.unit_set', 'stock_item', v_item.id::text, null, jsonb_build_object('unit', v_unit, 'factor', v_f, 'lines', n));
  return jsonb_build_object('ok', true, 'lines', n, 'units', (select count_units from stock_items where id = v_item.id));
end $$;

create or replace function rsa__receipt_review(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v stock_receipts;
begin
  perform rsa_need(u, 'expense.approve');
  select * into v from stock_receipts where id = rsa_uuid(p, 'receipt_id') for update;
  if not found or v.status = 'cancelled' then perform rsa_err('ไม่พบใบรับของ หรือยกเลิกไปแล้ว'); end if;
  if v.price_pending then perform rsa_err('ใส่ราคาก่อน แล้วจึงตรวจได้'); end if;
  update stock_receipts set reviewed_at = now(), reviewed_by = u.id where id = v.id;
  perform rsa_audit(u, 'receipt.review', 'receipt', v.id::text);
  return rsa_receipt_json(v.id);
end $$;

-- receipts waiting for the owner: price, unit size, or a check
create or replace function rsa_receipt_needs(p_id uuid) returns text language sql stable as $$
  select case when r.status = 'cancelled' then null
              when r.price_pending then 'price'
              when exists (select 1 from stock_receipt_lines l where l.receipt_id = r.id and l.unit_pending) then 'unit'
              when r.reviewed_at is null and r.created_at >= coalesce((rsa_setting('receipt_review_since') #>> '{}')::timestamptz, now()) then 'review' end
    from stock_receipts r where r.id = p_id
$$;

create or replace function rsa_receipt_json(p_id uuid) returns jsonb language sql stable as $$
  select to_jsonb(r) || jsonb_build_object(
    'created_by_name', (select display_name from app_users where id = r.created_by),
    'reviewed_by_name', (select display_name from app_users where id = r.reviewed_by),
    'needs', rsa_receipt_needs(r.id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object('stock_unit', s.unit) order by l.id), '[]')
                from stock_receipt_lines l join stock_items s on s.id = l.stock_item_id where l.receipt_id = r.id),
    'attachments', rsa_attachment_refs('receipt', r.id),
    'expense', (select jsonb_build_object('id', e.id, 'expense_no', e.expense_no, 'status', e.status, 'amount', e.amount) from expenses e where e.id = r.expense_id))
  from stock_receipts r where r.id = p_id
$$;

create or replace function rsa__receipt_list(u app_users, p jsonb) returns jsonb language plpgsql as $$
begin
  perform rsa_need(u, 'stock.view');
  if coalesce((p->>'queue')::boolean, false) then
    perform rsa_need(u, 'expense.approve');
    return (select coalesce(jsonb_agg(rsa_receipt_json(r.id) order by r.received_at), '[]') from stock_receipts r where rsa_receipt_needs(r.id) is not null);
  end if;
  return (select coalesce(jsonb_agg(rsa_receipt_json(r.id) order by r.received_at desc), '[]') from stock_receipts r
           where rsa_bdate(r.received_at) between rsa_date(p, 'from', rsa_today() - 30) and rsa_date(p, 'to')
             and (rsa_has(u, 'expense.approve') or r.created_by = u.id));   -- staff see the receipts they recorded
end $$;

-- dashboard "ต้องทำ"
create or replace function rsa_receipt_alerts() returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('kind', 'receipt_' || k, 'level', case k when 'price' then 'warn' else 'info' end,
           'text', case k when 'price' then 'รับของรอใส่ราคา ' when 'unit' then 'รับของรอใส่ตัวแปลงหน่วย ' else 'รับของรอตรวจ ' end || n || ' ใบ')), '[]')
    from (select rsa_receipt_needs(id) k, count(*) n from stock_receipts where status <> 'cancelled' group by 1) x where k is not null
$$;

-- form path for expenses: how it was paid must be chosen, and money already paid needs a picture or a reason
create or replace function rsa__expense_create(u app_users, p jsonb) returns jsonb language plpgsql as $$
declare v_id uuid; v_src text := coalesce(nullif(p->>'fund_source', ''), nullif(p->>'pay_mode', ''));
begin
  if v_src is null then perform rsa_err('กรุณาเลือกว่าจ่ายจากเงินไหน'); end if;
  if v_src not in ('credit', 'later') and not rsa_has_files(p)
     and not exists (select 1 from expense_categories c where c.id = rsa_uuid(p, 'category_id') and c.grp = 'C' and coalesce(c.c_kind, '') <> 'advance') and coalesce(trim(p->>'no_evidence_reason'), '') = '' then
    perform rsa_err('แนบรูปใบเสร็จ / สลิป หรือใส่เหตุผลว่าทำไมไม่มีหลักฐาน');
  end if;
  v_id := rsa_expense_insert(u, p);   -- separate statement so the read below sees the new row
  if coalesce(trim(p->>'no_evidence_reason'), '') <> '' then update expenses set no_evidence_reason = trim(p->>'no_evidence_reason') where id = v_id; end if;
  return rsa_expense_json(v_id);
end $$;

-- ==================== 99_grants.sql
-- RSA - POS Assistant : lock every function away from the browser except the five entry points (runs last)
-- Only the five entry points are callable from the browser.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'rsa%' loop
    execute format('revoke all on function %s from public', r.sig);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon', r.sig); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke all on function %s from authenticated', r.sig); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function rsa_status() to anon;
    grant execute on function rsa_setup(text, text, text) to anon;
    grant execute on function rsa_login(text, text) to anon;
    grant execute on function rsa_logout(text) to anon;
    grant execute on function rsa_api(text, text, jsonb) to anon;
  end if;
end $$;
