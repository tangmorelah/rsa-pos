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
