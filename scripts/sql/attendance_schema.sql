-- Attendance cloud patch (v1.15.1 follow-up): the app has pushed/pulled
-- shifts since the cloud-attendance feature shipped, but this table was
-- never applied to the cloud — every sync cycle failed with a
-- PostgrestException on 'attendance' (red "Sync issue" pill).
-- Idempotent; mirrors the Task 28 ops-schema pattern.

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

-- realtime: clock in/out mirrors instantly on the manager's device
alter publication supabase_realtime add table public.attendance;
