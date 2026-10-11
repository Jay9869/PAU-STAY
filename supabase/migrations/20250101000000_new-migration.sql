-- =====================================================================
-- PAU HOSTEL PORTAL (PAUstay): SUPABASE SCHEMA
-- Run this once in a FRESH Supabase project: SQL Editor -> New query -> paste -> Run.
--
-- What it gives you:
--   * Tables, enums, indexes and the "one active entry/room per student" rules
--   * Row Level Security on every table (students see only their own data)
--   * Server-side RPC functions for the whole queue + checkout + payment flow
--   * Public views for the homepage and hostel pages (cached-friendly)
--   * Seed data: settings, 13 hostels, room types, placeholder rooms
--   * pg_cron jobs for timers and revocations (last section)
--
-- Rules the app must follow:
--   1. The React client NEVER writes status columns. It only calls the RPCs below.
--   2. Money is stored in KOBO (bigint). Show naira = kobo / 100. Paystack also uses kobo.
--   3. Only the service_role key (Edge Functions) may call confirm_payment, fail_payment,
--      create_pending_payment, get_payment_link_public. Never put that key in the browser.
--
-- Sign-up (client): pass the profile as metadata so the trigger can create the student row:
--   supabase.auth.signUp({ email, password, options: { data: {
--     first_name, last_name, matric_no, phone, gender: 'male' | 'female' } } })
--
-- RPCs the client calls (supabase.rpc):
--   join_queue(p_room_type_id), leave_queue(), heartbeat(), get_my_status(),
--   claim_turn(p_entry_id), choose_plan(p_reservation_id, p_plan),
--   create_parent_link(p_reservation_id, p_parent_name, p_parent_phone, p_parent_email)
-- RPCs your Edge Functions call (service role):
--   create_pending_payment(...), confirm_payment(...), fail_payment(...),
--   get_payment_link_public(p_token)
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- ENUMS ----------
create type public.gender_t         as enum ('male', 'female');
create type public.room_status      as enum ('available', 'in_checkout', 'awaiting_payment', 'partially_booked', 'booked', 'revoked');
create type public.queue_status     as enum ('waiting', 'claimable', 'claimed', 'expired', 'left', 'dropped', 'completed');
create type public.reservation_status as enum ('in_checkout', 'awaiting_payment', 'partially_booked', 'booked', 'revoked', 'expired');
create type public.plan_t           as enum ('full', 'installment');
create type public.payment_kind     as enum ('full', 'deposit', 'balance');
create type public.payer_type_t     as enum ('student', 'parent');
create type public.payment_status   as enum ('pending', 'success', 'failed', 'refunded');
create type public.link_status      as enum ('active', 'used', 'expired', 'cancelled');
create type public.refund_reason    as enum ('late_payment', 'room_taken', 'revoked_minus_fee', 'manual');
create type public.refund_status    as enum ('pending', 'processed', 'failed');
create type public.staff_role_t     as enum ('pau_affairs', 'hostel_manager', 'admin');

-- ---------- SETTINGS (everything configurable lives here) ----------
create table public.settings (
  key         text primary key,
  value       text not null,
  description text
);

-- ---------- CORE TABLES ----------
create table public.hostels (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  gender      public.gender_t not null,
  distance_m  int  not null default 0,
  photo_url   text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table public.room_types (
  id          uuid primary key default gen_random_uuid(),
  hostel_id   uuid not null references public.hostels(id) on delete cascade,
  capacity    int  not null check (capacity between 1 and 4),
  price_kobo  bigint not null check (price_kobo > 0),
  unique (hostel_id, capacity)
);

create table public.rooms (
  id           uuid primary key default gen_random_uuid(),
  hostel_id    uuid not null references public.hostels(id) on delete cascade,
  room_type_id uuid not null references public.room_types(id) on delete cascade,
  number       text not null,
  floor        int,
  wing         text,
  status       public.room_status not null default 'available',
  unique (hostel_id, number)
);
create index rooms_type_status_idx on public.rooms (room_type_id, status);

-- students.id = auth.users.id
create table public.students (
  id          uuid primary key references auth.users(id) on delete cascade,
  matric_no   text not null,
  first_name  text not null,
  last_name   text not null,
  phone       text not null,
  email       text not null,
  gender      public.gender_t not null,
  created_at  timestamptz not null default now()
);
create unique index students_matric_uidx on public.students (upper(matric_no));

create table public.staff_roles (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       public.staff_role_t not null,
  hostel_id  uuid references public.hostels(id) on delete cascade,
  unique (user_id, role, hostel_id)
);

create table public.queue_entries (
  id                uuid primary key default gen_random_uuid(),
  seq               bigint generated always as identity,   -- strict ordering inside a queue
  room_type_id      uuid not null references public.room_types(id) on delete cascade,
  student_id        uuid not null references public.students(id) on delete cascade,
  status            public.queue_status not null default 'waiting',
  joined_at         timestamptz not null default now(),
  last_heartbeat_at timestamptz not null default now(),
  notify_opt_in     boolean not null default true,         -- stays in line while offline if true
  claim_expires_at  timestamptz,
  assigned_room_id  uuid references public.rooms(id)
);
create index queue_type_status_seq_idx on public.queue_entries (room_type_id, status, seq);
-- A student can have only ONE active queue entry at a time
create unique index queue_one_active_per_student
  on public.queue_entries (student_id) where status in ('waiting', 'claimable', 'claimed');

create table public.reservations (
  id                  uuid primary key default gen_random_uuid(),
  student_id          uuid not null references public.students(id),
  room_id             uuid not null references public.rooms(id),
  queue_entry_id      uuid references public.queue_entries(id),
  plan                public.plan_t,
  amount_total_kobo   bigint not null,
  amount_paid_kobo    bigint not null default 0,
  status              public.reservation_status not null default 'in_checkout',
  checkout_expires_at timestamptz,
  balance_due_at      timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (amount_paid_kobo >= 0 and amount_paid_kobo <= amount_total_kobo)
);
-- One active reservation per room, and one active reservation per student
create unique index reservations_one_active_per_room
  on public.reservations (room_id) where status in ('in_checkout', 'awaiting_payment', 'partially_booked', 'booked');
create unique index reservations_one_active_per_student
  on public.reservations (student_id) where status in ('in_checkout', 'awaiting_payment', 'partially_booked', 'booked');
create index reservations_checkout_idx on public.reservations (status, checkout_expires_at);
create index reservations_balance_idx  on public.reservations (status, balance_due_at);

-- Parent / sponsor links (no login needed to pay)
create table public.payment_links (
  id             uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  token          text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  kind           public.payment_kind not null,
  amount_kobo    bigint not null,
  parent_name    text,
  parent_phone   text,
  parent_email   text,
  expires_at     timestamptz not null,
  status         public.link_status not null default 'active',
  created_at     timestamptz not null default now(),
  used_at        timestamptz
);
create index payment_links_res_idx on public.payment_links (reservation_id);

create table public.payments (
  id              uuid primary key default gen_random_uuid(),
  reservation_id  uuid not null references public.reservations(id) on delete cascade,
  payment_link_id uuid references public.payment_links(id),
  reference       text not null unique,                    -- Paystack reference, idempotency key
  amount_kobo     bigint not null check (amount_kobo > 0),
  kind            public.payment_kind not null,
  payer_type      public.payer_type_t not null,
  payer_name      text,
  payer_email     text,
  status          public.payment_status not null default 'pending',
  paystack_event  jsonb,
  paid_at         timestamptz,
  created_at      timestamptz not null default now()
);
create index payments_res_idx    on public.payments (reservation_id);
create index payments_status_idx on public.payments (status, created_at);

-- Refunds always go back to the ORIGINAL payer (they point at the payment)
create table public.refunds (
  id                uuid primary key default gen_random_uuid(),
  payment_id        uuid not null references public.payments(id) on delete cascade,
  amount_kobo       bigint not null check (amount_kobo > 0),
  reason            public.refund_reason not null,
  status            public.refund_status not null default 'pending',
  paystack_refund_ref text,
  created_at        timestamptz not null default now(),
  processed_at      timestamptz
);

create table public.phases (
  id        uuid primary key default gen_random_uuid(),
  name      text not null,
  starts_at timestamptz not null,
  ends_at   timestamptz not null
);

-- Outbox: an Edge Function (or cron) reads 'pending' rows and sends email/SMS/push
create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete cascade,
  recipient  text,                                          -- for parents: phone or email
  channel    text not null default 'email',
  template   text not null,
  payload    jsonb not null default '{}'::jsonb,
  status     text not null default 'pending',
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
create index notifications_status_idx on public.notifications (status, created_at);

create table public.audit_log (
  id         bigint generated always as identity primary key,
  actor      uuid,
  action     text not null,
  entity     text,
  entity_id  uuid,
  details    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.rate_limits (
  user_id      uuid not null,
  action       text not null,
  window_start timestamptz not null,
  hits         int not null default 0,
  primary key (user_id, action, window_start)
);

-- ---------- HELPERS ----------
create or replace function public.setting_text(k text) returns text
language sql stable as $$ select value from public.settings where key = k $$;

create or replace function public.setting_int(k text) returns int
language sql stable as $$ select value::int from public.settings where key = k $$;

create or replace function public.setting_ts(k text) returns timestamptz
language sql stable as $$ select value::timestamptz from public.settings where key = k $$;

-- Balance deadline = semester start minus N days (end of that day)
create or replace function public.balance_deadline() returns timestamptz
language sql stable as $$
  select ((public.setting_text('semester_start_date')::date - public.setting_int('balance_days_before_semester'))
          + time '23:59:59')::timestamptz
$$;

create or replace function public.set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
create trigger reservations_updated_at before update on public.reservations
  for each row execute function public.set_updated_at();

create or replace function public.audit(p_actor uuid, p_action text, p_entity text, p_entity_id uuid, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_log(actor, action, entity, entity_id, details) values (p_actor, p_action, p_entity, p_entity_id, p_details)
$$;

create or replace function public.notify(p_student uuid, p_template text, p_payload jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications(student_id, template, payload) values (p_student, p_template, p_payload)
$$;

-- Staff helpers (used by RLS policies)
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff_roles where user_id = auth.uid())
$$;

create or replace function public.current_student_gender() returns public.gender_t
language sql stable security definer set search_path = public as $$
  select s.gender from public.students s where s.id = auth.uid()
$$;

create or replace function public.has_role(r public.staff_role_t) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff_roles where user_id = auth.uid() and role = r)
$$;

create or replace function public.manages_hostel(h uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff_roles
    where user_id = auth.uid()
      and (role in ('admin', 'pau_affairs') or (role = 'hostel_manager' and hostel_id = h)))
$$;

-- Fixed-window rate limiter, per signed-in user (campus Wi-Fi shares IPs, so we limit per student)
create or replace function public.check_rate_limit(p_action text, p_max int, p_window_seconds int)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_start timestamptz; v_hits int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  v_start := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into public.rate_limits(user_id, action, window_start, hits) values (v_uid, p_action, v_start, 1)
  on conflict (user_id, action, window_start) do update set hits = public.rate_limits.hits + 1
  returning hits into v_hits;
  if v_hits > p_max then raise exception 'rate_limited'; end if;
end $$;

-- ---------- SIGN-UP TRIGGER: school email only + create the student row ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_domain text := public.setting_text('allowed_email_domain');
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  -- No profile metadata = staff/admin account (created by you). It gets no student row.
  if coalesce(m->>'matric_no', '') = '' then return new; end if;

  if coalesce(v_domain, '') <> '' and lower(split_part(new.email, '@', 2)) <> lower(v_domain) then
    raise exception 'Sign-up is limited to @% email addresses', v_domain;
  end if;

  insert into public.students (id, matric_no, first_name, last_name, phone, email, gender)
  values (new.id, upper(trim(m->>'matric_no')), trim(m->>'first_name'), trim(m->>'last_name'),
          trim(m->>'phone'), lower(new.email), (m->>'gender')::public.gender_t);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- QUEUE ENGINE ----------
-- Amount the student/parent currently owes on a reservation
create or replace function public.amount_due_kobo(p_reservation_id uuid) returns bigint
language sql stable as $$
  select case
    when r.plan is null then null
    when r.plan = 'full' then r.amount_total_kobo - r.amount_paid_kobo
    when r.amount_paid_kobo = 0 then round(r.amount_total_kobo * public.setting_int('deposit_percent') / 100.0)::bigint
    else r.amount_total_kobo - r.amount_paid_kobo
  end
  from public.reservations r where r.id = p_reservation_id
$$;

-- Internal: hand out turns (claimable) to the first waiting students, one per free room
create or replace function public.promote_next(p_room_type_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_slots int; v_entry record;
begin
  perform pg_advisory_xact_lock(hashtext(p_room_type_id::text));
  loop
    select (select count(*) from public.rooms where room_type_id = p_room_type_id and status = 'available')
         - (select count(*) from public.queue_entries where room_type_id = p_room_type_id and status = 'claimable')
    into v_slots;
    exit when v_slots <= 0;

    select id, student_id into v_entry from public.queue_entries
    where room_type_id = p_room_type_id and status = 'waiting'
    order by seq limit 1 for update skip locked;
    exit when not found;

    update public.queue_entries
       set status = 'claimable',
           claim_expires_at = now() + make_interval(secs => public.setting_int('claim_seconds'))
     where id = v_entry.id;

    perform public.notify(v_entry.student_id, 'your_turn',
      jsonb_build_object('entry_id', v_entry.id, 'claim_seconds', public.setting_int('claim_seconds')));
  end loop;
end $$;

create or replace function public.get_my_status() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_res record; v_q record; v_pos int; v_len int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_res from public.reservations
  where student_id = v_uid and status in ('in_checkout', 'awaiting_payment', 'partially_booked', 'booked') limit 1;
  if found then
    return jsonb_build_object(
      'state', v_res.status, 'reservation_id', v_res.id, 'room_id', v_res.room_id, 'plan', v_res.plan,
      'amount_total_kobo', v_res.amount_total_kobo, 'amount_paid_kobo', v_res.amount_paid_kobo,
      'amount_due_kobo', public.amount_due_kobo(v_res.id),
      'expires_at', v_res.checkout_expires_at, 'balance_due_at', v_res.balance_due_at, 'server_now', now());
  end if;

  select * into v_q from public.queue_entries
  where student_id = v_uid and status in ('waiting', 'claimable') limit 1;
  if found then
    select count(*) into v_pos from public.queue_entries
      where room_type_id = v_q.room_type_id and status in ('waiting', 'claimable') and seq <= v_q.seq;
    select count(*) into v_len from public.queue_entries
      where room_type_id = v_q.room_type_id and status in ('waiting', 'claimable');
    return jsonb_build_object(
      'state', v_q.status, 'entry_id', v_q.id, 'room_type_id', v_q.room_type_id,
      'position', v_pos, 'queue_length', v_len, 'claim_expires_at', v_q.claim_expires_at, 'server_now', now());
  end if;

  return jsonb_build_object('state', 'none', 'server_now', now());
end $$;

create or replace function public.join_queue(p_room_type_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_student public.students%rowtype;
  v_gender public.gender_t;
  v_open_at timestamptz;
  v_open int; v_waiting int; v_cap int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.check_rate_limit('join_queue', 5, 60);

  if not exists (select 1 from auth.users where id = v_uid and email_confirmed_at is not null) then
    raise exception 'email_not_verified';
  end if;
  select * into v_student from public.students where id = v_uid;
  if not found then raise exception 'no_student_profile'; end if;

  v_open_at := public.setting_ts('open_at');
  if v_open_at is not null and now() < v_open_at then raise exception 'booking_not_open'; end if;

  select h.gender into v_gender
  from public.room_types rt join public.hostels h on h.id = rt.hostel_id
  where rt.id = p_room_type_id and h.is_active;
  if not found then raise exception 'room_type_not_found'; end if;
  if v_gender <> v_student.gender then raise exception 'gender_mismatch'; end if;

  perform pg_advisory_xact_lock(hashtext(p_room_type_id::text));

  if exists (select 1 from public.reservations where student_id = v_uid
             and status in ('in_checkout', 'awaiting_payment', 'partially_booked', 'booked')) then
    raise exception 'already_has_room';
  end if;
  if exists (select 1 from public.queue_entries where student_id = v_uid
             and status in ('waiting', 'claimable', 'claimed')) then
    raise exception 'already_in_queue';
  end if;

  select count(*) into v_open from public.rooms
   where room_type_id = p_room_type_id and status in ('available', 'in_checkout', 'awaiting_payment');
  if v_open = 0 then raise exception 'sold_out'; end if;

  select count(*) into v_waiting from public.queue_entries
   where room_type_id = p_room_type_id and status in ('waiting', 'claimable');
  v_cap := public.setting_int('queue_cap_multiplier') * v_open;
  if v_waiting >= v_cap then raise exception 'queue_full'; end if;

  insert into public.queue_entries (room_type_id, student_id) values (p_room_type_id, v_uid);
  perform public.promote_next(p_room_type_id);
  perform public.audit(v_uid, 'join_queue', 'room_type', p_room_type_id);
  return public.get_my_status();
end $$;

create or replace function public.leave_queue() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_rt uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  update public.queue_entries set status = 'left'
   where student_id = v_uid and status in ('waiting', 'claimable')
   returning room_type_id into v_rt;
  if v_rt is not null then
    perform public.promote_next(v_rt);
    perform public.audit(v_uid, 'leave_queue', 'room_type', v_rt);
  end if;
  return public.get_my_status();
end $$;

-- Call every ~20s from /queue so we know the student is still here
create or replace function public.heartbeat() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update public.queue_entries set last_heartbeat_at = now()
   where student_id = auth.uid() and status in ('waiting', 'claimable');
end $$;

-- Student confirms presence on their turn: locks a room and starts the 10:00 window
create or replace function public.claim_turn(p_entry_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_entry record; v_room uuid; v_price bigint; v_res uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_entry from public.queue_entries where id = p_entry_id and student_id = v_uid for update;
  if not found then raise exception 'entry_not_found'; end if;
  if v_entry.status <> 'claimable' then raise exception 'not_your_turn'; end if;
  if v_entry.claim_expires_at < now() then raise exception 'claim_expired'; end if;

  perform pg_advisory_xact_lock(hashtext(v_entry.room_type_id::text));

  select id into v_room from public.rooms
   where room_type_id = v_entry.room_type_id and status = 'available'
   order by number limit 1 for update skip locked;

  if v_room is null then
    update public.queue_entries set status = 'expired' where id = v_entry.id;
    return jsonb_build_object('state', 'none', 'error', 'room_gone', 'server_now', now());
  end if;

  select price_kobo into v_price from public.room_types where id = v_entry.room_type_id;

  update public.rooms set status = 'in_checkout' where id = v_room;
  update public.queue_entries set status = 'claimed', assigned_room_id = v_room where id = v_entry.id;
  insert into public.reservations (student_id, room_id, queue_entry_id, amount_total_kobo, status, checkout_expires_at)
  values (v_uid, v_room, v_entry.id, v_price, 'in_checkout',
          now() + make_interval(mins => public.setting_int('checkout_minutes')))
  returning id into v_res;

  perform public.audit(v_uid, 'claim_turn', 'reservation', v_res);
  return public.get_my_status();
end $$;

create or replace function public.choose_plan(p_reservation_id uuid, p_plan public.plan_t) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_res public.reservations%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into v_res from public.reservations where id = p_reservation_id and student_id = v_uid for update;
  if not found then raise exception 'reservation_not_found'; end if;
  if v_res.status not in ('in_checkout', 'awaiting_payment') or v_res.checkout_expires_at <= now() then
    raise exception 'hold_expired';
  end if;
  if v_res.amount_paid_kobo > 0 then raise exception 'payment_already_started'; end if;

  -- Late-booking rule: installment only if the balance deadline is far enough away
  if p_plan = 'installment'
     and public.balance_deadline() < now() + make_interval(days => public.setting_int('min_days_for_installment')) then
    raise exception 'installment_not_available';
  end if;

  update public.reservations set plan = p_plan where id = p_reservation_id;
  perform public.audit(v_uid, 'choose_plan', 'reservation', p_reservation_id, jsonb_build_object('plan', p_plan));
  return public.get_my_status();
end $$;

-- Student sends the bill to a parent/sponsor. Extends the hold ONCE (to parent_hold_minutes).
create or replace function public.create_parent_link(
  p_reservation_id uuid, p_parent_name text, p_parent_phone text, p_parent_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_res public.reservations%rowtype;
  v_kind public.payment_kind; v_expires timestamptz; v_amount bigint; v_id uuid; v_token text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  perform public.check_rate_limit('parent_link', 10, 3600);

  select * into v_res from public.reservations where id = p_reservation_id and student_id = v_uid for update;
  if not found then raise exception 'reservation_not_found'; end if;
  if coalesce(p_parent_phone, '') = '' and coalesce(p_parent_email, '') = '' then
    raise exception 'parent_contact_required';
  end if;

  if v_res.status in ('in_checkout', 'awaiting_payment') then
    if v_res.plan is null then raise exception 'plan_not_chosen'; end if;
    if v_res.checkout_expires_at <= now() then raise exception 'hold_expired'; end if;
    v_kind := case v_res.plan when 'full' then 'full'::public.payment_kind else 'deposit'::public.payment_kind end;
    if v_res.status = 'in_checkout' then
      update public.reservations
         set status = 'awaiting_payment',
             checkout_expires_at = now() + make_interval(mins => public.setting_int('parent_hold_minutes'))
       where id = p_reservation_id
       returning checkout_expires_at into v_expires;
      update public.rooms set status = 'awaiting_payment' where id = v_res.room_id;
    else
      v_expires := v_res.checkout_expires_at;   -- already extended once, never extend again
    end if;
  elsif v_res.status = 'partially_booked' then
    v_kind := 'balance';
    v_expires := v_res.balance_due_at;
  else
    raise exception 'reservation_not_payable';
  end if;

  v_amount := public.amount_due_kobo(p_reservation_id);
  update public.payment_links set status = 'cancelled' where reservation_id = p_reservation_id and status = 'active';

  insert into public.payment_links (reservation_id, kind, amount_kobo, parent_name, parent_phone, parent_email, expires_at)
  values (p_reservation_id, v_kind, v_amount, p_parent_name, p_parent_phone, p_parent_email, v_expires)
  returning id, token into v_id, v_token;

  -- Outbox row so your sender can SMS/email the parent (the link is built from the token)
  insert into public.notifications (student_id, recipient, channel, template, payload)
  values (v_uid, coalesce(nullif(p_parent_phone, ''), p_parent_email),
          case when coalesce(p_parent_phone, '') <> '' then 'sms' else 'email' end,
          'parent_payment_link',
          jsonb_build_object('token', v_token, 'amount_kobo', v_amount, 'expires_at', v_expires, 'parent_name', p_parent_name));

  perform public.audit(v_uid, 'create_parent_link', 'payment_link', v_id);
  return jsonb_build_object('link_id', v_id, 'token', v_token, 'kind', v_kind,
                            'amount_kobo', v_amount, 'expires_at', v_expires, 'server_now', now());
end $$;

-- ---------- PAYMENT FUNCTIONS (service role / Edge Functions only) ----------
-- Step 1: before opening Paystack, record a pending payment for the exact amount due
create or replace function public.create_pending_payment(
  p_reservation_id uuid, p_reference text, p_payer_type public.payer_type_t,
  p_payer_name text, p_payer_email text,
  p_link_id uuid default null, p_student_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_res public.reservations%rowtype; v_kind public.payment_kind; v_amount bigint;
  v_link public.payment_links%rowtype; v_id uuid;
begin
  select * into v_res from public.reservations where id = p_reservation_id for update;
  if not found then raise exception 'reservation_not_found'; end if;
  if p_student_id is not null and v_res.student_id <> p_student_id then raise exception 'forbidden'; end if;

  if v_res.status in ('in_checkout', 'awaiting_payment') then
    if v_res.plan is null then raise exception 'plan_not_chosen'; end if;
    if v_res.checkout_expires_at <= now() then raise exception 'hold_expired'; end if;
    v_kind := case v_res.plan when 'full' then 'full'::public.payment_kind else 'deposit'::public.payment_kind end;
  elsif v_res.status = 'partially_booked' then
    if v_res.balance_due_at <= now() then raise exception 'deadline_passed'; end if;
    v_kind := 'balance';
  else
    raise exception 'reservation_not_payable';
  end if;

  v_amount := public.amount_due_kobo(p_reservation_id);

  if p_link_id is not null then
    select * into v_link from public.payment_links
     where id = p_link_id and reservation_id = p_reservation_id and status = 'active' and expires_at > now();
    if not found then raise exception 'link_invalid'; end if;
    if v_link.amount_kobo <> v_amount then raise exception 'amount_changed'; end if;
  end if;

  insert into public.payments (reservation_id, payment_link_id, reference, amount_kobo, kind, payer_type, payer_name, payer_email)
  values (p_reservation_id, p_link_id, p_reference, v_amount, v_kind, p_payer_type, p_payer_name, p_payer_email)
  returning id into v_id;

  return jsonb_build_object('payment_id', v_id, 'reference', p_reference, 'amount_kobo', v_amount, 'kind', v_kind);
end $$;

-- Safe, minimal data for the public /pay/:token page
create or replace function public.get_payment_link_public(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v record; v_status text;
begin
  select l.id as link_id, l.status as link_status, l.kind, l.amount_kobo, l.expires_at, l.reservation_id,
         r.status as res_status, r.plan, s.first_name, left(s.last_name, 1) as last_initial,
         h.name as hostel_name, rt.capacity
    into v
    from public.payment_links l
    join public.reservations r on r.id = l.reservation_id
    join public.students s on s.id = r.student_id
    join public.rooms ro on ro.id = r.room_id
    join public.hostels h on h.id = ro.hostel_id
    join public.room_types rt on rt.id = ro.room_type_id
   where l.token = p_token;
  if not found then return jsonb_build_object('status', 'not_found'); end if;

  v_status := case
    when v.link_status = 'used' then 'used'
    when v.link_status = 'cancelled' then 'cancelled'
    when v.expires_at <= now() then 'expired'
    when v.kind = 'balance' and v.res_status <> 'partially_booked' then 'room_released'
    when v.kind <> 'balance' and v.res_status not in ('in_checkout', 'awaiting_payment') then 'room_released'
    else 'active' end;

  return jsonb_build_object(
    'status', v_status, 'reservation_id', v.reservation_id,
    'student_first_name', v.first_name, 'student_last_initial', v.last_initial,
    'hostel_name', v.hostel_name, 'room_type', (v.capacity::text || '-Man Room'), 'plan', v.plan, 'kind', v.kind,
    'amount_kobo', v.amount_kobo, 'expires_at', v.expires_at,
    'seconds_remaining', greatest(0, floor(extract(epoch from (v.expires_at - now()))))::int);
end $$;

-- Step 2: called ONLY by the verified Paystack webhook. Idempotent on reference.
create or replace function public.confirm_payment(p_reference text, p_amount_kobo bigint, p_event jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pay public.payments%rowtype; v_res public.reservations%rowtype; v_room public.rooms%rowtype;
  v_valid boolean; v_new_paid bigint; v_open int; v_reason public.refund_reason; v_new_status public.reservation_status;
begin
  select * into v_pay from public.payments where reference = p_reference for update;
  if not found then return jsonb_build_object('result', 'unknown_reference'); end if;
  if v_pay.status in ('success', 'refunded') then return jsonb_build_object('result', 'duplicate'); end if;

  if p_amount_kobo <> v_pay.amount_kobo then
    update public.payments set status = 'failed', paystack_event = p_event where id = v_pay.id;
    perform public.audit(null, 'payment_amount_mismatch', 'payment', v_pay.id,
                         jsonb_build_object('expected', v_pay.amount_kobo, 'got', p_amount_kobo));
    return jsonb_build_object('result', 'amount_mismatch');   -- review manually: money may have moved
  end if;

  select * into v_res  from public.reservations where id = v_pay.reservation_id for update;
  select * into v_room from public.rooms where id = v_res.room_id for update;

  v_valid := case v_pay.kind
               when 'balance' then v_res.status = 'partially_booked'
               else v_res.status in ('in_checkout', 'awaiting_payment') end;

  update public.payments set status = 'success', paid_at = now(), paystack_event = p_event where id = v_pay.id;
  if v_pay.payment_link_id is not null then
    update public.payment_links set status = 'used', used_at = now() where id = v_pay.payment_link_id;
  end if;

  -- Paid too late / room already released: refund the full amount to the original payer
  if not v_valid then
    v_reason := case
      when v_res.status = 'booked' then 'manual'::public.refund_reason
      when v_room.status = 'available' then 'late_payment'::public.refund_reason
      else 'room_taken'::public.refund_reason end;
    insert into public.refunds (payment_id, amount_kobo, reason) values (v_pay.id, v_pay.amount_kobo, v_reason);
    perform public.notify(v_res.student_id, 'payment_refunded', jsonb_build_object('reason', v_reason));
    perform public.audit(null, 'payment_refund_queued', 'payment', v_pay.id, jsonb_build_object('reason', v_reason));
    return jsonb_build_object('result', 'refund_queued', 'reason', v_reason);
  end if;

  v_new_paid := v_res.amount_paid_kobo + v_pay.amount_kobo;
  if v_new_paid >= v_res.amount_total_kobo then
    v_new_status := 'booked';
    update public.reservations set amount_paid_kobo = v_new_paid, status = 'booked' where id = v_res.id;
    update public.rooms set status = 'booked' where id = v_res.room_id;
  else
    v_new_status := 'partially_booked';
    update public.reservations
       set amount_paid_kobo = v_new_paid, status = 'partially_booked',
           balance_due_at = coalesce(balance_due_at, public.balance_deadline())
     where id = v_res.id;
    update public.rooms set status = 'partially_booked' where id = v_res.room_id;
  end if;

  update public.queue_entries set status = 'completed' where id = v_res.queue_entry_id and status = 'claimed';

  -- If this room type is now fully taken, tell everyone still waiting it is gone
  select count(*) into v_open from public.rooms
   where room_type_id = v_room.room_type_id and status in ('available', 'in_checkout', 'awaiting_payment');
  if v_open = 0 then
    insert into public.notifications (student_id, template, payload)
    select student_id, 'room_type_sold_out', jsonb_build_object('room_type_id', v_room.room_type_id)
      from public.queue_entries where room_type_id = v_room.room_type_id and status in ('waiting', 'claimable');
    update public.queue_entries set status = 'expired'
     where room_type_id = v_room.room_type_id and status in ('waiting', 'claimable');
  end if;

  perform public.notify(v_res.student_id, 'payment_confirmed',
    jsonb_build_object('status', v_new_status, 'amount_kobo', v_pay.amount_kobo, 'payer_type', v_pay.payer_type));
  perform public.audit(null, 'payment_confirmed', 'payment', v_pay.id, jsonb_build_object('status', v_new_status));
  return jsonb_build_object('result', 'confirmed', 'reservation_status', v_new_status);
end $$;

create or replace function public.fail_payment(p_reference text, p_event jsonb default null) returns void
language sql security definer set search_path = public as $$
  update public.payments set status = 'failed', paystack_event = p_event
   where reference = p_reference and status = 'pending'
$$;

-- ---------- TIMERS (run by pg_cron) ----------
create or replace function public.expire_holds() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_rt uuid; v_types uuid[] := '{}';
begin
  -- 1) Students who did not claim their turn in time
  for r in
    with ex as (
      update public.queue_entries set status = 'expired'
       where status = 'claimable' and claim_expires_at < now()
       returning room_type_id, student_id)
    select * from ex
  loop
    perform public.notify(r.student_id, 'claim_missed');
    v_types := v_types || r.room_type_id;
  end loop;

  -- 2) Drop silent students who opted out of notifications
  update public.queue_entries set status = 'dropped'
   where status = 'waiting' and notify_opt_in = false
     and last_heartbeat_at < now() - make_interval(secs => public.setting_int('heartbeat_timeout_seconds'));

  -- 3) Expired checkout holds (skip any with a payment still being confirmed in the last 15 min)
  for r in
    with ex as (
      update public.reservations res set status = 'expired'
       where res.status in ('in_checkout', 'awaiting_payment') and res.checkout_expires_at < now()
         and not exists (select 1 from public.payments p
                          where p.reservation_id = res.id and p.status = 'pending'
                            and p.created_at > now() - interval '15 minutes')
       returning res.room_id, res.student_id, res.queue_entry_id)
    select * from ex
  loop
    update public.rooms set status = 'available' where id = r.room_id returning room_type_id into v_rt;
    update public.queue_entries set status = 'expired' where id = r.queue_entry_id;
    update public.payment_links set status = 'expired' where reservation_id in
      (select id from public.reservations where room_id = r.room_id and status = 'expired') and status = 'active';
    perform public.notify(r.student_id, 'hold_expired');
    v_types := v_types || v_rt;
  end loop;

  -- 4) Give freed rooms to the next students in line
  for v_rt in select distinct unnest(v_types) loop
    perform public.promote_next(v_rt);
  end loop;
end $$;

-- Deadline passed on a 50% deposit: revoke, free the room, queue a refund minus the admin fee
create or replace function public.revoke_overdue() returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_rt uuid; v_fee bigint; v_pay uuid; v_types uuid[] := '{}';
begin
  for r in
    with rv as (
      update public.reservations set status = 'revoked'
       where status = 'partially_booked' and balance_due_at < now()
       returning id, room_id, student_id, amount_paid_kobo)
    select * from rv
  loop
    update public.rooms set status = 'available' where id = r.room_id returning room_type_id into v_rt;
    v_fee := round(r.amount_paid_kobo * public.setting_int('admin_fee_percent') / 100.0)::bigint;
    select id into v_pay from public.payments
     where reservation_id = r.id and status = 'success' order by paid_at desc limit 1;
    if v_pay is not null and r.amount_paid_kobo - v_fee > 0 then
      insert into public.refunds (payment_id, amount_kobo, reason)
      values (v_pay, r.amount_paid_kobo - v_fee, 'revoked_minus_fee');
    end if;
    update public.payment_links set status = 'expired' where reservation_id = r.id and status = 'active';
    perform public.notify(r.student_id, 'reservation_revoked',
      jsonb_build_object('paid_kobo', r.amount_paid_kobo, 'fee_kobo', v_fee, 'refund_kobo', r.amount_paid_kobo - v_fee));
    perform public.audit(null, 'revoke_overdue', 'reservation', r.id);
    v_types := v_types || v_rt;
  end loop;

  for v_rt in select distinct unnest(v_types) loop
    perform public.promote_next(v_rt);
  end loop;
end $$;

-- Reminders to students AND parents before the balance deadline (14, 7, 3, 1 days)
create or replace function public.queue_balance_reminders() returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in
    select res.id, res.student_id, res.balance_due_at,
           ceil(extract(epoch from (res.balance_due_at - now())) / 86400)::int as days_left
      from public.reservations res
     where res.status = 'partially_booked' and res.balance_due_at > now()
  loop
    if r.days_left in (14, 7, 3, 1)
       and not exists (select 1 from public.notifications n
                        where n.student_id = r.student_id and n.template = 'balance_reminder'
                          and n.payload->>'days_left' = r.days_left::text
                          and n.payload->>'reservation_id' = r.id::text) then
      perform public.notify(r.student_id, 'balance_reminder',
        jsonb_build_object('days_left', r.days_left, 'reservation_id', r.id, 'balance_due_at', r.balance_due_at));
      insert into public.notifications(student_id, recipient, channel, template, payload)
      select r.student_id,
             coalesce(nullif(pl.parent_phone, ''), pl.parent_email),
             case when coalesce(nullif(pl.parent_phone, ''), '') <> '' then 'sms' else 'email' end,
             'balance_reminder_parent',
             jsonb_build_object('days_left', r.days_left, 'reservation_id', r.id, 'balance_due_at', r.balance_due_at)
        from public.payment_links pl
       where pl.reservation_id = r.id and pl.status = 'active'
         and coalesce(nullif(pl.parent_phone, ''), nullif(pl.parent_email, '')) is not null;
    end if;
  end loop;
end $$;

create or replace function public.cleanup_rate_limits() returns void
language sql security definer set search_path = public as $$
  delete from public.rate_limits where window_start < now() - interval '2 hours'
$$;

-- ---------- PUBLIC VIEWS (homepage + hostel pages; aggregates only, no personal data) ----------
create or replace view public.hostel_cards as
select h.id, h.name, h.gender, h.distance_m, h.photo_url,
       count(r.id)::int as total_rooms,
       (count(r.id) filter (where r.status = 'available'))::int as available_rooms,
       (select min(rt.price_kobo) from public.room_types rt where rt.hostel_id = h.id) as from_price_kobo,
       (select min(rt.price_kobo) from public.room_types rt where rt.hostel_id = h.id) / 100 as from_price_naira
  from public.hostels h
  left join public.rooms r on r.hostel_id = h.id
 where h.is_active
 group by h.id;

create or replace view public.room_type_cards as
select rt.id as room_type_id, rt.hostel_id, rt.capacity, rt.price_kobo, rt.price_kobo / 100 as price_naira,
       count(r.id)::int as total_rooms,
       (count(r.id) filter (where r.status = 'available'))::int as available_rooms,
       (select count(*) from public.queue_entries q
         where q.room_type_id = rt.id and q.status in ('waiting', 'claimable'))::int as queue_length,
       case
         when count(r.id) filter (where r.status = 'available') > 0 then 'available'
         when count(r.id) filter (where r.status in ('in_checkout', 'awaiting_payment')) > 0 then 'in_checkout'
         when count(r.id) filter (where r.status = 'partially_booked') > 0 then 'partially_booked'
         else 'booked' end as status
  from public.room_types rt
  left join public.rooms r on r.room_type_id = rt.id
 group by rt.id;

-- ---------- ROW LEVEL SECURITY ----------
alter table public.settings       enable row level security;
alter table public.hostels        enable row level security;
alter table public.room_types     enable row level security;
alter table public.rooms          enable row level security;
alter table public.students       enable row level security;
alter table public.staff_roles    enable row level security;
alter table public.queue_entries  enable row level security;
alter table public.reservations   enable row level security;
alter table public.payment_links  enable row level security;
alter table public.payments       enable row level security;
alter table public.refunds        enable row level security;
alter table public.phases         enable row level security;
alter table public.notifications  enable row level security;
alter table public.audit_log      enable row level security;
alter table public.rate_limits    enable row level security;   -- no policies: only definer functions touch it

-- Public browsing (homepage works before login; gender is enforced when joining a queue)
create policy settings_read   on public.settings   for select using (true);
create policy hostels_read    on public.hostels    for select using (
  auth.uid() is null or public.is_staff() or public.current_student_gender() = gender
);
create policy room_types_read on public.room_types for select using (
  auth.uid() is null or public.is_staff() or exists (
    select 1 from public.hostels h
    where h.id = room_types.hostel_id and public.current_student_gender() = h.gender
  )
);
create policy phases_read     on public.phases     for select using (true);

-- Admin / PAU Affairs configuration
create policy settings_write on public.settings for update
  using (public.has_role('admin') or public.has_role('pau_affairs'))
  with check (public.has_role('admin') or public.has_role('pau_affairs'));
create policy hostels_write on public.hostels for all
  using (public.has_role('admin') or public.has_role('pau_affairs'))
  with check (public.has_role('admin') or public.has_role('pau_affairs'));
create policy room_types_write on public.room_types for all
  using (public.manages_hostel(hostel_id)) with check (public.manages_hostel(hostel_id));

-- Rooms: staff of that hostel, or the student currently holding the room
create policy rooms_read on public.rooms for select using (
  auth.uid() is null
  or public.manages_hostel(hostel_id)
  or exists (select 1 from public.hostels h where h.id = hostel_id and public.current_student_gender() = h.gender)
  or exists (select 1 from public.reservations r
              where r.room_id = rooms.id and r.student_id = auth.uid()
                and r.status in ('in_checkout', 'awaiting_payment', 'partially_booked', 'booked')));
create policy rooms_insert on public.rooms for insert with check (public.manages_hostel(hostel_id));
create policy rooms_update on public.rooms for update
  using (public.manages_hostel(hostel_id)) with check (public.manages_hostel(hostel_id));

-- Students: own row (can edit name/phone only; see column grants below)
create policy students_read   on public.students for select using (id = auth.uid() or public.is_staff());
create policy students_update on public.students for update using (id = auth.uid()) with check (id = auth.uid());

create policy staff_roles_read on public.staff_roles for select
  using (user_id = auth.uid() or public.has_role('admin'));

create policy queue_read on public.queue_entries for select
  using (student_id = auth.uid() or public.is_staff());

create policy reservations_read on public.reservations for select using (
  student_id = auth.uid()
  or exists (select 1 from public.rooms ro where ro.id = reservations.room_id and public.manages_hostel(ro.hostel_id)));

create policy payments_read on public.payments for select using (
  exists (select 1 from public.reservations r
           where r.id = payments.reservation_id
             and (r.student_id = auth.uid()
                  or exists (select 1 from public.rooms ro where ro.id = r.room_id and public.manages_hostel(ro.hostel_id)))));

create policy payment_links_read on public.payment_links for select using (
  exists (select 1 from public.reservations r where r.id = payment_links.reservation_id and r.student_id = auth.uid())
  or public.is_staff());

create policy refunds_read on public.refunds for select using (
  exists (select 1 from public.payments p join public.reservations r on r.id = p.reservation_id
           where p.id = refunds.payment_id and r.student_id = auth.uid())
  or public.has_role('admin') or public.has_role('pau_affairs'));

create policy notifications_read on public.notifications for select using (student_id = auth.uid());
create policy audit_read on public.audit_log for select
  using (public.has_role('admin') or public.has_role('pau_affairs'));

-- ---------- GRANTS ----------
-- Lock everything down, then open only what the app needs. All state changes go through RPCs.
revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;
grant update (first_name, last_name, phone) on public.students to authenticated;
grant update on public.settings to authenticated;
grant insert, update, delete on public.hostels, public.room_types to authenticated;
grant insert (hostel_id, room_type_id, number, floor, wing) on public.rooms to authenticated;
grant update (number, floor, wing) on public.rooms to authenticated;
grant select on public.hostel_cards, public.room_type_cards to anon, authenticated;

-- Functions: internal ones are locked; client RPCs are for signed-in users only
revoke all on function
  public.promote_next(uuid), public.expire_holds(), public.revoke_overdue(),
  public.queue_balance_reminders(), public.cleanup_rate_limits(),
  public.audit(uuid, text, text, uuid, jsonb), public.notify(uuid, text, jsonb),
  public.check_rate_limit(text, int, int),
  public.create_pending_payment(uuid, text, public.payer_type_t, text, text, uuid, uuid),
  public.get_payment_link_public(text),
  public.confirm_payment(text, bigint, jsonb), public.fail_payment(text, jsonb)
from public, anon, authenticated;

grant execute on function
  public.create_pending_payment(uuid, text, public.payer_type_t, text, text, uuid, uuid),
  public.get_payment_link_public(text),
  public.confirm_payment(text, bigint, jsonb), public.fail_payment(text, jsonb)
to service_role;

revoke all on function
  public.join_queue(uuid), public.leave_queue(), public.heartbeat(), public.get_my_status(),
  public.claim_turn(uuid), public.choose_plan(uuid, public.plan_t),
  public.create_parent_link(uuid, text, text, text)
from public, anon;

grant execute on function
  public.join_queue(uuid), public.leave_queue(), public.heartbeat(), public.get_my_status(),
  public.claim_turn(uuid), public.choose_plan(uuid, public.plan_t),
  public.create_parent_link(uuid, text, text, text)
to authenticated;

-- ---------- REALTIME (queue position + reservation timers update live; RLS still applies) ----------
do $$ begin alter publication supabase_realtime add table public.queue_entries; exception when others then null; end $$;
do $$ begin alter publication supabase_realtime add table public.reservations;  exception when others then null; end $$;

-- ---------- SEED DATA (placeholders: replace with real figures) ----------
insert into public.settings (key, value, description) values
  ('allowed_email_domain',        'pau.edu.ng',  'Sign-ups must use this email domain. Confirm the real one. Empty = allow any.'),
  ('open_at',                     (now() - interval '1 day')::text, 'Booking opens at this time. Set a future time for launch.'),
  ('semester_start_date',         '2027-01-18',  'Placeholder. Balance deadline = this minus balance_days_before_semester.'),
  ('balance_days_before_semester','30',          'Installment balance is due this many days before the semester'),
  ('min_days_for_installment',    '45',          'Installment hidden if the balance deadline is closer than this many days away'),
  ('deposit_percent',             '50',          'Deposit for installment plan'),
  ('admin_fee_percent',           '10',          'Non-refundable fee kept when an installment reservation is revoked'),
  ('claim_seconds',               '60',          'Seconds a student has to confirm it is their turn'),
  ('checkout_minutes',            '10',          'Exclusive checkout window'),
  ('parent_hold_minutes',         '30',          'Hold extension when a parent link is created (once)'),
  ('queue_cap_multiplier',        '5',           'Max waiting students = this x open rooms of the room type'),
  ('heartbeat_timeout_seconds',   '180',         'Drop silent waiting students who opted out of notifications')
on conflict (key) do nothing;

insert into public.hostels (name, gender, distance_m, photo_url)
select n, g::public.gender_t, d, 'https://placehold.co/800x500?text=' || replace(n, ' ', '+')
from (values
  ('Enterprise Development Center', 'male',   300),
  ('Emerald',                       'male',   450),
  ('Amethyst',                      'male',   600),
  ('Faith',                         'male',   750),
  ('The Pod Living',                'male',   900),
  ('Cooperative Kings',             'male',  1200),
  ('Cooperative Queens',            'female', 350),
  ('Redwood',                       'female', 500),
  ('Pearl',                         'female', 650),
  ('Queen Mary',                    'female', 800),
  ('Trinity',                       'female', 950),
  ('Trezadel',                      'female',1100),
  ('Cedar House',                   'female',1400)
) as t(n, g, d)
on conflict (name) do nothing;

-- Placeholder prices in KOBO: 1-man 900k, 2-man 700k, 3-man 550k, 4-man 450k naira
insert into public.room_types (hostel_id, capacity, price_kobo)
select h.id, c.capacity, c.price_kobo
from public.hostels h
cross join (values (1, 90000000::bigint), (2, 70000000::bigint), (3, 55000000::bigint), (4, 45000000::bigint)) as c(capacity, price_kobo)
on conflict (hostel_id, capacity) do nothing;

-- Placeholder rooms: 6 single, 12 double, 8 triple, 6 quad per hostel
insert into public.rooms (hostel_id, room_type_id, number, floor, wing)
select rt.hostel_id, rt.id, (rt.capacity * 1000 + g)::text, 1 + (g - 1) / 6, case when g % 2 = 0 then 'B' else 'A' end
from public.room_types rt
cross join lateral generate_series(1, case rt.capacity when 1 then 6 when 2 then 12 when 3 then 8 else 6 end) as g
on conflict (hostel_id, number) do nothing;

insert into public.phases (name, starts_at, ends_at)
select 'Open booking', public.setting_ts('open_at'), public.setting_ts('open_at') + interval '30 days'
where not exists (select 1 from public.phases);

-- ---------- CRON JOBS (pg_cron) ----------
-- If the extension line fails, enable pg_cron in Dashboard -> Database -> Extensions and re-run this section.
-- If '15 seconds' is rejected by your pg_cron version, use '* * * * *' (every minute) for expire-holds.
create extension if not exists pg_cron with schema cron;

do $$ begin
  if not exists (select 1 from cron.job where jobname = 'pau-expire-holds') then
    perform cron.schedule('pau-expire-holds', '*/1 * * * *', 'select public.expire_holds()');
  end if;
end $$;

do $$ begin
  if not exists (select 1 from cron.job where jobname = 'pau-revoke-overdue') then
    perform cron.schedule('pau-revoke-overdue', '*/10 * * * *', 'select public.revoke_overdue()');
  end if;
end $$;

do $$ begin
  if not exists (select 1 from cron.job where jobname = 'pau-balance-reminders') then
    perform cron.schedule('pau-balance-reminders', '0 8 * * *', 'select public.queue_balance_reminders()');
  end if;
end $$;

do $$ begin
  if not exists (select 1 from cron.job where jobname = 'pau-cleanup-ratelimits') then
    perform cron.schedule('pau-cleanup-ratelimits', '30 * * * *', 'select public.cleanup_rate_limits()');
  end if;
end $$;

-- ---------- HOW TO MAKE STAFF ----------
-- 1. In Dashboard -> Authentication -> Users, add the staff user (no profile metadata needed).
-- 2. Run, with their user id:
--    insert into public.staff_roles (user_id, role) values ('<user-uuid>', 'admin');
--    insert into public.staff_roles (user_id, role, hostel_id) values ('<user-uuid>', 'hostel_manager', '<hostel-uuid>');
