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
