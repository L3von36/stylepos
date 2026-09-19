-- Task 28 cloud patch (idempotent): suppliers, purchase orders, commissions,
-- cost snapshot on sale_items, staff permissions + commission rate.

-- ---------- suppliers -------------------------------------------------------
create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default my_shop_id(),
  name text not null,
  phone text,
  email text,
  address text,
  notes text,
  created_at timestamptz not null default now(),
  deleted boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.suppliers enable row level security;
drop policy if exists "suppliers_all" on public.suppliers;
create policy "suppliers_all" on public.suppliers
  for all using (shop_id = my_shop_id()) with check (shop_id = my_shop_id());
drop policy if exists "suppliers_select" on public.suppliers;
create policy "suppliers_select" on public.suppliers
  for select using (shop_id = my_shop_id());
drop trigger if exists trg_touch on public.suppliers;
create trigger trg_touch before update on public.suppliers
  for each row execute function touch_updated_at();

-- ---------- purchase orders -------------------------------------------------
create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default my_shop_id(),
  supplier_id uuid,
  status text not null default 'draft',   -- draft|ordered|received|cancelled
  order_date timestamptz,
  expected_date timestamptz,
  received_date timestamptz,
  notes text,
  created_by uuid,
  created_at timestamptz not null default now(),
  deleted boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.purchase_orders enable row level security;
drop policy if exists "purchase_orders_all" on public.purchase_orders;
create policy "purchase_orders_all" on public.purchase_orders
  for all using (shop_id = my_shop_id()) with check (shop_id = my_shop_id());
drop policy if exists "purchase_orders_select" on public.purchase_orders;
create policy "purchase_orders_select" on public.purchase_orders
  for select using (shop_id = my_shop_id());
drop trigger if exists trg_touch on public.purchase_orders;
create trigger trg_touch before update on public.purchase_orders
  for each row execute function touch_updated_at();

create table if not exists public.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default my_shop_id(),
  po_id uuid not null,
  variant_id uuid,
  product_name text not null default '',
  variant_desc text not null default '',
  sku text not null default '',
  qty_ordered integer not null default 0,
  qty_received integer not null default 0,
  unit_cost numeric not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_po_items_po on public.purchase_order_items(po_id);
alter table public.purchase_order_items enable row level security;
drop policy if exists "po_items_all" on public.purchase_order_items;
create policy "po_items_all" on public.purchase_order_items
  for all using (shop_id = my_shop_id()) with check (shop_id = my_shop_id());
drop policy if exists "po_items_select" on public.purchase_order_items;
create policy "po_items_select" on public.purchase_order_items
  for select using (shop_id = my_shop_id());
drop trigger if exists trg_touch on public.purchase_order_items;
create trigger trg_touch before update on public.purchase_order_items
  for each row execute function touch_updated_at();

-- ---------- commissions -----------------------------------------------------
create table if not exists public.commissions (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default my_shop_id(),
  user_id uuid,                             -- the salesperson (app_users id)
  sale_id uuid,                             -- null for manual adjustments
  amount numeric not null default 0,
  basis text not null default 'sale',       -- sale|adjustment
  status text not null default 'pending',   -- pending|paid
  note text,
  period text not null default '',          -- YYYY-MM payout bucket
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_commissions_user on public.commissions(user_id);
alter table public.commissions enable row level security;
drop policy if exists "commissions_all" on public.commissions;
create policy "commissions_all" on public.commissions
  for all using (shop_id = my_shop_id()) with check (shop_id = my_shop_id());
drop policy if exists "commissions_select" on public.commissions;
create policy "commissions_select" on public.commissions
  for select using (shop_id = my_shop_id());
drop trigger if exists trg_touch on public.commissions;
create trigger trg_touch before update on public.commissions
  for each row execute function touch_updated_at();

-- ---------- cost snapshot on sale lines (true margin per sale) --------------
alter table public.sale_items add column if not exists unit_cost numeric not null default 0;

-- ---------- staff permissions + commission rate ------------------------------
alter table public.app_users add column if not exists permissions jsonb not null default '{}'::jsonb;
alter table public.app_users add column if not exists commission_rate numeric not null default 0;

-- ---------- realtime ---------------------------------------------------------
alter publication supabase_realtime add table public.suppliers;
alter publication supabase_realtime add table public.purchase_orders;
alter publication supabase_realtime add table public.purchase_order_items;
alter publication supabase_realtime add table public.commissions;
