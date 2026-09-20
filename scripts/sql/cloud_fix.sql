-- ==============================================================
-- StylePOS — Supabase schema PATCH 7  ("Fix cloud sync" one-paste)
-- Supersedes patches 5 and 6 — running this ONE file brings any
-- cloud fully up to date.
-- Where: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- Safe to run more than once, on any cloud state, and it never
-- touches your data — only adds what is missing.
--
-- Why: StylePOS v1.16+ pushes a few fields/tables older clouds never
-- got (stock movement device tags, promo columns, promotions,
-- purchasing, attendance) and v1.22+ reads multi-branch RPCs
-- (branch tree, branch switching, cross-branch sales overview).
-- Without them the app showed "this app is newer than the cloud
-- database — run the latest Supabase schema patch SQL". This file
-- brings ANY cloud fully up to date in one run.
-- ==============================================================

-- ---------- A. columns on the core tables -------------------------------
alter table public.sales
  add column if not exists device text not null default '';
alter table public.sales
  add column if not exists promo_code text;
alter table public.sales
  add column if not exists promo_discount double precision not null default 0;

alter table public.stock_movements
  add column if not exists device_id text;
alter table public.stock_movements
  add column if not exists updated_at timestamptz not null default now();
alter table public.sale_items
  add column if not exists updated_at timestamptz not null default now();
alter table public.sale_items
  add column if not exists unit_cost numeric not null default 0;

alter table public.app_users
  add column if not exists permissions jsonb not null default '{}'::jsonb;
alter table public.app_users
  add column if not exists commission_rate numeric not null default 0;

-- keep updated_at fresh on the child tables (skipped patch 3 safe)
drop trigger if exists set_updated_at_sale_items on public.sale_items;
create trigger set_updated_at_sale_items
  before update on public.sale_items
  for each row execute function public.touch_updated_at();
drop trigger if exists set_updated_at_stock_movements on public.stock_movements;
create trigger set_updated_at_stock_movements
  before update on public.stock_movements
  for each row execute function public.touch_updated_at();

-- ---------- B. promotions (coupons + campaigns) --------------------------
create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default my_shop_id(),
  name text not null,
  code text not null,
  kind text not null default 'coupon',      -- coupon | campaign
  type text not null default 'percent',     -- percent | fixed
  value numeric not null default 0,
  min_subtotal numeric not null default 0,
  starts_at timestamptz,
  ends_at timestamptz,
  usage_limit integer not null default 0,   -- 0 = unlimited
  used_count integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  deleted boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.promotions enable row level security;
drop policy if exists "promotions_all" on public.promotions;
create policy "promotions_all" on public.promotions
  for all using (shop_id = my_shop_id()) with check (shop_id = my_shop_id());
drop policy if exists "promotions_select" on public.promotions;
create policy "promotions_select" on public.promotions
  for select using (shop_id = my_shop_id());
drop trigger if exists trg_touch on public.promotions;
create trigger trg_touch before update on public.promotions
  for each row execute function touch_updated_at();

-- ---------- C. purchasing + commissions (Task 28) ------------------------
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

-- ---------- D. attendance (clock in / clock out) -------------------------
create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null default my_shop_id(),
  user_id uuid,                             -- the staff member (app_users id)
  clock_in timestamptz not null default now(),
  clock_out timestamptz,                    -- null while on duty
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_attendance_user on public.attendance(user_id);
alter table public.attendance enable row level security;
drop policy if exists "attendance_all" on public.attendance;
create policy "attendance_all" on public.attendance
  for all using (shop_id = my_shop_id()) with check (shop_id = my_shop_id());
drop policy if exists "attendance_select" on public.attendance;
create policy "attendance_select" on public.attendance
  for select using (shop_id = my_shop_id());
drop trigger if exists trg_touch on public.attendance;
create trigger trg_touch before update on public.attendance
  for each row execute function touch_updated_at();

-- ---------- E. realtime (idempotent joins) -------------------------------
do $$ begin
  alter publication supabase_realtime add table public.promotions;
exception when others then null;  -- already a member: fine
end $$;
do $$ begin
  alter publication supabase_realtime add table public.suppliers;
exception when others then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.purchase_orders;
exception when others then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.purchase_order_items;
exception when others then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.commissions;
exception when others then null;
end $$;
do $$ begin
  alter publication supabase_realtime add table public.attendance;
exception when others then null;
end $$;

-- ---------- F. multi-branch (shops tree + switching) ---------------------
-- v1.22: a manager can run several shops (branches) from one account.
-- Each branch is its own workspace (own catalog/staff/sales); the
-- manager creates and switches branches from Settings -> Branches.
alter table public.shops
  add column if not exists parent_shop_id uuid references public.shops(id) on delete cascade;

create or replace function public.my_root_shop_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select coalesce(s.parent_shop_id, s.id)
  from public.shops s
  where s.id = (select shop_id from public.app_users where id = auth.uid())
$$;

-- branch-tree visibility: staff see their own shop, the manager also
-- sees the root shop and every branch under it (Branches.list())
drop policy if exists shops_select on public.shops;
create policy shops_select on public.shops
  for select to authenticated
  using (
    id = public.my_shop_id()
    or id = public.my_root_shop_id()
    or parent_shop_id = public.my_root_shop_id()
  );

create or replace function public.create_branch(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_cur  uuid;
  v_root uuid;
  v_sid  uuid;
  v_code text;
begin
  if v_uid is null then
    raise exception 'Sign in first';
  end if;
  if not exists (
    select 1 from public.app_users where id = v_uid and role = 'admin'
  ) then
    raise exception 'Only a manager can create branches.';
  end if;

  select shop_id into v_cur from public.app_users where id = v_uid;
  if v_cur is null then
    raise exception 'You are not part of a shop yet.';
  end if;

  select coalesce(parent_shop_id, id) into v_root
    from public.shops where id = v_cur;

  loop
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (select 1 from public.shops where shops.code = v_code);
  end loop;

  insert into public.shops (code, name, parent_shop_id)
    values (v_code, coalesce(nullif(trim(p_name), ''), 'New branch'), v_root)
    returning id into v_sid;

  return v_sid;
end;
$$;
grant execute on function public.create_branch(text) to authenticated;

create or replace function public.switch_to_shop(p_shop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_root uuid;
begin
  if v_uid is null then
    raise exception 'Sign in first';
  end if;
  if not exists (
    select 1 from public.app_users where id = v_uid and role = 'admin'
  ) then
    raise exception 'Only a manager can switch branches.';
  end if;

  select coalesce(parent_shop_id, id) into v_root
    from public.shops
    where id = (select shop_id from public.app_users where id = v_uid);

  if v_root is null or p_shop_id is null or not exists (
    select 1 from public.shops s
    where s.id = p_shop_id and (s.id = v_root or s.parent_shop_id = v_root)
  ) then
    raise exception 'That shop is not one of your branches.';
  end if;

  update public.app_users set shop_id = p_shop_id where id = v_uid;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.switch_to_shop(uuid) to authenticated;

-- ---------- G. branch sales overview (owner's cross-branch totals) -------
-- Powers Reports -> "Branch sales": per-shop completed revenue, all-time
-- and today, for the caller's whole branch tree. Manager-only. The app
-- passes its local-midnight epoch so "today" matches the OWNER'S clock,
-- not the server's.
create or replace function public.branch_sales_overview(
  p_today_epoch double precision default null
)
returns table (
  shop_id uuid,
  name text,
  code text,
  is_current boolean,
  all_orders bigint,
  all_revenue double precision,
  today_orders bigint,
  today_revenue double precision
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_cur  uuid;
  v_root uuid;
  v_day  timestamptz;
begin
  if v_uid is null then
    raise exception 'Sign in first';
  end if;
  if not exists (
    select 1 from public.app_users where id = v_uid and role = 'admin'
  ) then
    raise exception 'Only a manager can view branch sales.';
  end if;

  select shop_id into v_cur from public.app_users where id = v_uid;
  select coalesce(parent_shop_id, id) into v_root
    from public.shops where id = v_cur;

  v_day := case
    when p_today_epoch is null then date_trunc('day', now())
    else to_timestamp(p_today_epoch)
  end;

  return query
    select
      s.id,
      s.name,
      s.code,
      (s.id = v_cur),
      count(sal.id),
      coalesce(sum(case when sal.status = 'completed'
                        then sal.total else 0 end), 0)::double precision,
      count(sal.id) filter (where sal.created_at >= v_day),
      coalesce(sum(case when sal.status = 'completed'
                          and sal.created_at >= v_day
                        then sal.total else 0 end), 0)::double precision
    from public.shops s
    left join public.sales sal on sal.shop_id = s.id
    where s.id = v_root or s.parent_shop_id = v_root
    group by s.id, s.name, s.code
    order by min(s.created_at), s.name;
end;
$$;
grant execute on function public.branch_sales_overview(double precision) to authenticated;

-- ==============================================================
-- DONE. Back in StylePOS: open the cloud menu (Sync pill) and tap
-- "Retry now" — or just wait a minute; the next sync succeeds.
-- Then Reports -> "Branch sales" lights up with every branch's totals.
-- ==============================================================
