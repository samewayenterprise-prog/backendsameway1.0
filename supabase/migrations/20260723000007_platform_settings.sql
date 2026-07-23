-- ============================================================
-- 007 · PLATFORM SETTINGS (fee toggle)
-- One-row singleton table holding runtime-adjustable platform config.
-- Primary use today: switch the platform's revenue on and off — the
-- "free for 3 months" cold-start policy. Toggled from the admin panel;
-- takes effect on the next booking / next parcel charge (no restart).
--
-- Row shape is intentionally small: bools + numerics only, no JSON
-- freeform. Adding a new knob = adding a column, which forces a
-- migration and code review rather than silently changing behavior.
-- ============================================================

create table if not exists public.platform_settings (
  id                       int primary key default 1 check (id = 1),
  fees_enabled             boolean not null default false,   -- launch = free
  booking_fee_azn          numeric(10,2) not null default 1.50 check (booking_fee_azn >= 0),
  parcel_platform_pct      int not null default 10 check (parcel_platform_pct between 0 and 50),
  updated_at               timestamptz not null default now(),
  updated_by               uuid references public.users(id)
);

-- Seed the singleton. Launch state: FEES OFF.
insert into public.platform_settings (id) values (1)
on conflict (id) do nothing;

-- Auto-stamp updated_at on any change.
create or replace function public.trg_platform_settings_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger platform_settings_touch
  before update on public.platform_settings
  for each row execute function public.trg_platform_settings_touch();

-- Clients can READ (mobile app may want to show "SameWay is free right
-- now" copy) but never WRITE. Writes come from the admin panel via
-- service role.
alter table public.platform_settings enable row level security;
create policy platform_settings_read on public.platform_settings
  for select using (true);

-- ------------------------------------------------------------
-- Hook the toggle into create_booking:
-- when fees_enabled is true, stamp bookings.fee_amount to the
-- configured booking_fee_azn; otherwise leave it at 0 (dormant).
-- The payments-watcher already ignores 0-fee bookings, so a flip
-- to OFF stops new fees mid-day cleanly; existing charges keep flowing.
-- ------------------------------------------------------------
create or replace function public.create_booking(
  p_ride_id     uuid,
  p_seat_count  int,
  p_payment     payment_method_t default 'cash',
  p_pickup      uuid default null,
  p_dropoff     uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_ride    rides%rowtype;
  v_booking uuid;
  v_gender  gender_t;
  v_status  booking_status_t;
  v_fee     numeric(10,2);
begin
  if p_seat_count < 1 or p_seat_count > 7 then
    raise exception 'invalid_seat_count';
  end if;

  select * into v_ride from rides where id = p_ride_id for update;
  if not found then raise exception 'ride_not_found'; end if;
  if v_ride.status <> 'published' then raise exception 'ride_not_bookable'; end if;
  if v_ride.seats_available < p_seat_count then raise exception 'not_enough_seats'; end if;

  if v_ride.ladies_only then
    select gender into v_gender from users where id = auth.uid();
    if v_gender <> 'female' then raise exception 'ladies_only'; end if;
  end if;

  -- Read the fee setting fresh on every booking so a mid-day toggle
  -- takes effect on the very next call.
  select case when fees_enabled then booking_fee_azn else 0 end
    into v_fee
    from platform_settings where id = 1;

  update rides
     set seats_available = seats_available - p_seat_count
   where id = p_ride_id;

  v_status := case
    when p_seat_count > 1              then 'awaiting_group'
    when v_ride.instant_book           then 'confirmed'
    else 'pending'
  end;

  insert into bookings (ride_id, lead_passenger_id, pickup_stop_id, dropoff_stop_id,
                        seat_count, total_price, fee_amount, payment_method, status,
                        driver_approved_at, expires_at)
  values (p_ride_id, auth.uid(), p_pickup, p_dropoff,
          p_seat_count, p_seat_count * v_ride.price_per_seat,
          v_fee * p_seat_count,                           -- fee scales per seat
          p_payment, v_status,
          case when v_status = 'confirmed' then now() end,
          case when v_status = 'awaiting_group'
               then now() + interval '30 minutes'
               else v_ride.departure_at end)
  returning id into v_booking;

  insert into booking_passengers (booking_id, user_id, invited_via, status, joined_at)
  values (v_booking, auth.uid(), 'direct', 'confirmed', now());

  insert into booking_passengers (booking_id, invited_via, status)
  select v_booking, 'link', 'pending' from generate_series(2, p_seat_count);

  if v_status = 'pending' then
    insert into notifications (user_id, type, data)
    values (v_ride.driver_id, 'booking_request',
            jsonb_build_object('booking_id', v_booking, 'ride_id', p_ride_id));
  end if;

  return v_booking;
end $$;
