-- ============================================================
-- 005 · OPS SUPPORT
-- Fills the services-layer gaps found while wiring Edge Functions:
--   A. notifications.sent_at — dispatch tracking for the FCM worker
--   B. routes parcel prefs — so generated rides inherit them
--   C. generate_recurring_rides() — the nightly generator that was
--      designed (routes.generated_until watermark, unique
--      (route_id, departure_at) slot) but never implemented. This is
--      the heart of the follow loop: generator inserts rides →
--      existing rides_fanout trigger notifies followers → the
--      notify-dispatch Edge Function delivers the push.
--   D. pg_cron schedule + a partial index for the refund queue
-- Additive-only, like 004.
-- ============================================================

-- ------------------------------------------------------------
-- A · dispatch tracking
-- ------------------------------------------------------------
alter table public.notifications
  add column if not exists sent_at timestamptz;

create index if not exists notif_unsent_idx
  on public.notifications(created_at)
  where sent_at is null;

-- ------------------------------------------------------------
-- B · per-route parcel preferences (mirrors the per-ride columns)
-- Recurring drivers set these once; the generator copies them onto
-- every materialized ride.
-- ------------------------------------------------------------
alter table public.routes
  add column if not exists accepts_parcels   boolean not null default false,
  add column if not exists parcel_capacity   int     not null default 0
    check (parcel_capacity between 0 and 3),
  add column if not exists parcel_price_base numeric(10,2);

-- ------------------------------------------------------------
-- C · recurring-ride generator
-- Materializes rides for active weekly routes HORIZON days ahead.
-- Idempotent: the one_per_route_slot unique constraint absorbs any
-- overlap, and generated_until only ever moves forward.
-- ------------------------------------------------------------
create or replace function public.generate_recurring_rides(p_horizon_days int default 28)
returns int
language plpgsql security definer set search_path = public as $$
declare
  v_route   routes%rowtype;
  v_day     date;
  v_from    date;
  v_until   date := current_date + p_horizon_days;
  v_created int  := 0;
begin
  for v_route in
    select * from routes
    where is_active
      and recurrence = 'weekly'
      and cardinality(recurrence_days) > 0
      and (generated_until is null or generated_until < v_until)
  loop
    v_from := greatest(current_date + 1,
                       coalesce(v_route.generated_until + 1, current_date + 1));

    v_day := v_from;
    while v_day <= v_until loop
      -- isodow: 1=Mon … 7=Sun — same convention as recurrence_days
      if extract(isodow from v_day)::int = any (v_route.recurrence_days) then
        insert into rides (
          route_id, driver_id, vehicle_id,
          from_address, from_lat, from_lng,
          to_address,   to_lat,   to_lng,
          departure_at, seats_total, seats_available, price_per_seat,
          status, accepts_cash, accepts_card, instant_book, ladies_only,
          accepts_parcels, parcel_capacity, parcel_price_base
        ) values (
          v_route.id, v_route.driver_id, v_route.vehicle_id,
          v_route.from_address, v_route.from_lat, v_route.from_lng,
          v_route.to_address,   v_route.to_lat,   v_route.to_lng,
          (v_day + v_route.departure_time)::timestamptz,
          v_route.max_seats, v_route.max_seats, v_route.price_per_seat,
          'published', v_route.accepts_cash, v_route.accepts_card,
          v_route.instant_book, v_route.ladies_only,
          v_route.accepts_parcels, v_route.parcel_capacity, v_route.parcel_price_base
        )
        on conflict on constraint one_per_route_slot do nothing;

        if found then v_created := v_created + 1; end if;
      end if;
      v_day := v_day + 1;
    end loop;

    update routes set generated_until = v_until where id = v_route.id;
  end loop;

  return v_created;
end $$;

revoke execute on function public.generate_recurring_rides(int) from public, anon, authenticated;

-- Nightly at 03:00 UTC — follows the existing expire-bookings pattern.
select cron.schedule(
  'generate-recurring-rides',
  '0 3 * * *',
  $$select public.generate_recurring_rides()$$
);

-- ------------------------------------------------------------
-- D · refund queue index for the payments watcher
-- ------------------------------------------------------------
create index if not exists txn_refund_pending_idx
  on public.transactions(created_at)
  where type = 'refund' and status = 'pending';
