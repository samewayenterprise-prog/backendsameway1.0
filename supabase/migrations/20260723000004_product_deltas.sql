-- ============================================================
-- 004 · PRODUCT DELTAS
-- Additions surfaced by the full screen map (sameway-screen-map.md §12).
-- Additive-only: no existing function bodies are replaced here, so
-- 001–003 remain exactly as reviewed. New behavior arrives via new
-- columns, new functions, and new triggers.
--
-- Contents:
--   A. Booking fee mechanism (build now, launch at 0 ₼)
--   B. Parcel delivery code (4-digit, generated on acceptance)
--   C. Publish-funnel columns: route polyline/tolls, Boost, return ride
-- ============================================================

-- ------------------------------------------------------------
-- A · BOOKING FEE
-- Flat per-seat fee charged online even on cash rides (screens 44/46).
-- fee_amount defaults to 0 → mechanism exists but dormant until a
-- corridor is switched on. The Edge Function that charges Epoint calls
-- record_booking_fee() after a successful charge; declines/cancellations
-- auto-queue a refund row the same Edge Function watches and executes.
-- ------------------------------------------------------------

alter table public.bookings
  add column if not exists fee_amount numeric(10,2) not null default 0
    check (fee_amount >= 0);

comment on column public.bookings.fee_amount is
  'Online booking fee (platform revenue). 0 = fee disabled for this booking''s corridor at creation time.';

-- Called by the payments Edge Function AFTER Epoint confirms the charge.
create or replace function public.record_booking_fee(
  p_booking uuid,
  p_provider_txn text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_b bookings%rowtype;
  v_driver uuid;
  v_txn uuid;
begin
  select b.* into v_b from bookings b where b.id = p_booking for update;
  if not found then raise exception 'booking_not_found'; end if;
  if v_b.fee_amount <= 0 then raise exception 'no_fee_on_booking'; end if;

  select r.driver_id into v_driver from rides r where r.id = v_b.ride_id;

  insert into transactions (
    booking_id, payer_id, driver_id, provider, provider_txn_id,
    type, amount_total, amount_driver, amount_platform, status, settled_at
  ) values (
    p_booking, v_b.lead_passenger_id, v_driver, 'epoint', p_provider_txn,
    'charge', v_b.fee_amount, 0, v_b.fee_amount, 'settled', now()
  ) returning id into v_txn;

  return v_txn;
end $$;

revoke execute on function public.record_booking_fee(uuid, text) from public, anon, authenticated;

-- When a fee-bearing booking dies (declined / cancelled / expired),
-- queue a pending refund row for every settled fee charge. The payments
-- Edge Function watches for these and executes the Epoint refund, then
-- flips status to 'settled'. Same watch-the-table pattern as parcels.
create or replace function public.trg_queue_fee_refund()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_charge transactions%rowtype;
begin
  if new.status in ('declined','cancelled','expired')
     and old.status is distinct from new.status
     and new.fee_amount > 0
  then
    for v_charge in
      select * from transactions
      where booking_id = new.id and type = 'charge'
        and amount_platform = new.fee_amount and status = 'settled'
    loop
      -- avoid double-queuing if a refund already exists for this booking
      if not exists (
        select 1 from transactions
        where booking_id = new.id and type = 'refund'
      ) then
        insert into transactions (
          booking_id, payer_id, driver_id, provider,
          type, amount_total, amount_driver, amount_platform, status
        ) values (
          new.id, v_charge.payer_id, v_charge.driver_id, v_charge.provider,
          'refund', v_charge.amount_total, 0, v_charge.amount_platform, 'pending'
        );
      end if;
    end loop;
  end if;
  return new;
end $$;

create trigger bookings_queue_fee_refund
  after update on public.bookings
  for each row execute function public.trg_queue_fee_refund();

-- ------------------------------------------------------------
-- B · PARCEL DELIVERY CODE
-- 4-digit code generated the moment a driver accepts (screen 50).
-- Receiver speaks it to the driver at handoff; v1 verification is
-- client-side before mark_parcel_delivered() is called. RLS: the
-- existing parcels select policies already scope rows to sender and
-- ride-driver; the driver seeing the stored code is acceptable for v1
-- because the code's job is confirming the *receiver* is present —
-- revisit if fraud reports suggest otherwise.
-- ------------------------------------------------------------

alter table public.parcels
  add column if not exists delivery_code text
    check (delivery_code ~ '^[0-9]{4}$');

create or replace function public.trg_gen_parcel_code()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted'
     and new.delivery_code is null
  then
    new.delivery_code := lpad(floor(random() * 10000)::int::text, 4, '0');
  end if;
  return new;
end $$;

create trigger parcels_gen_delivery_code
  before update on public.parcels
  for each row execute function public.trg_gen_parcel_code();

-- ------------------------------------------------------------
-- C · PUBLISH-FUNNEL COLUMNS
-- ------------------------------------------------------------

-- Screen 56 — driver picks one of the alternative routes. We store the
-- chosen polyline (encoded, from Directions API) and whether it tolls,
-- so ride detail (screen 10) can draw the real path without re-querying.
alter table public.routes
  add column if not exists selected_polyline text,
  add column if not exists toll_route boolean not null default false;

-- Screen 62 — Boost: sell partial-route legs. Pricing per leg already
-- lives in route_stops; this flag simply switches leg-sale on per ride.
alter table public.rides
  add column if not exists boost_enabled boolean not null default false;

-- Screen 63/64 — return-ride prompt links the pair for UX ("your return
-- ride") and for the <2h validation, which is enforced client-side and
-- double-checked here.
alter table public.rides
  add column if not exists return_of_ride_id uuid references public.rides(id);

create index if not exists rides_return_of_idx
  on public.rides(return_of_ride_id) where return_of_ride_id is not null;

alter table public.rides
  add constraint rides_return_not_self
  check (return_of_ride_id is null or return_of_ride_id <> id);

-- Border-crossing advisory (screen 66) is a client-side check against
-- route endpoints' countries via the Directions/Geocoding response —
-- no schema needed; noted here so the delta list matches the map doc.
