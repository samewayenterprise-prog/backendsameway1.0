-- ============================================================
-- 011 · INTEGRITY & SAFETY
--   A. Seat-inventory invariant enforced by the database
--   B. Read-time booking expiry (don't trust the sweeper alone)
--   C. Driver streak decoupled from completing trips  ← SAFETY
--   D. Parcel declared-value cap
-- ============================================================

-- ------------------------------------------------------------
-- A · seat inventory invariant
-- create_booking already locks the ride row and checks availability.
-- This is the belt-and-braces layer: even a future code path with a
-- bug cannot drive inventory negative or above capacity — the write
-- fails atomically instead of silently overselling a car.
-- ------------------------------------------------------------
alter table public.rides
  add constraint rides_seats_available_sane
  check (seats_available >= 0 and seats_available <= seats_total);

-- ------------------------------------------------------------
-- B · read-time expiry
-- pg_cron runs the expiry sweep every minute, so a hold can outlive
-- its expires_at by up to ~60s (longer if a run is skipped, since
-- pg_cron does not retry). Anything that acts on a booking must
-- therefore treat expires_at as authoritative at read time rather
-- than trusting that the sweeper has already run.
--
-- The gap this closes: accept_booking_invite validated the INVITE's
-- expiry but never the BOOKING's, so a friend could join a group
-- whose hold had already lapsed and whose seats were about to be
-- released.
-- ------------------------------------------------------------
create or replace function public.accept_booking_invite(p_token text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_inv  booking_invites%rowtype;
  v_slot uuid;
  v_b    bookings%rowtype;
begin
  select * into v_inv from booking_invites
  where token = p_token and expires_at > now()
  for update;
  if not found then raise exception 'invite_invalid'; end if;

  select * into v_b from bookings where id = v_inv.booking_id for update;
  if v_b.status not in ('awaiting_group','pending','confirmed') then
    raise exception 'booking_closed';
  end if;

  -- read-time expiry: the hold has lapsed even if the sweeper has not
  -- yet flipped the row. Expire it here rather than letting someone
  -- join a group that is seconds from losing its seats.
  if v_b.status in ('pending','awaiting_group') and v_b.expires_at < now() then
    update bookings set status = 'expired' where id = v_b.id;
    perform public.release_seats(v_b.id);
    raise exception 'booking_expired';
  end if;

  if exists (select 1 from booking_passengers
             where booking_id = v_b.id and user_id = auth.uid()) then
    raise exception 'already_joined';
  end if;

  select id into v_slot from booking_passengers
  where booking_id = v_b.id and user_id is null and status = 'pending'
  order by id limit 1 for update;
  if v_slot is null then raise exception 'group_full'; end if;

  update booking_passengers
     set user_id = auth.uid(), status = 'confirmed', joined_at = now()
   where id = v_slot;

  update booking_invites set used_by = auth.uid(), used_at = now()
   where id = v_inv.id;

  -- last slot claimed → group is complete, advance the booking
  if not exists (select 1 from booking_passengers
                 where booking_id = v_b.id and status = 'pending') then
    update bookings
       set status = case when (select instant_book from rides where id = v_b.ride_id)
                         then 'confirmed' else 'pending' end,
           driver_approved_at = case when (select instant_book from rides where id = v_b.ride_id)
                                     then now() end
     where id = v_b.id;
  end if;

  return v_b.id;
end $$;

-- ------------------------------------------------------------
-- C · STREAK SAFETY — decouple driver streaks from completing trips
--
-- The problem: a per-route streak that only advances when a ride is
-- COMPLETED tells a driver "drive this Friday or lose 12 weeks of
-- progress." That is precisely the mechanic Uber was criticised for —
-- gamification that pressures a driver toward a marginal, fatigued or
-- unsafe trip. On an intercity night route it is a foreseeable
-- safety and liability problem, not a theoretical one.
--
-- The fix: the driver's route streak now advances when they PUBLISH
-- availability on that route, not when a trip completes. Showing up
-- and offering the seats is what the streak rewards. If nobody books,
-- or the driver cancels because they are tired or the weather is bad,
-- the streak is untouched — there is no longer any streak-driven
-- reason to make a trip they should not make.
--
-- Freeze allowance also doubles (1 → 2 per quarter) so an ordinary
-- gap week is forgiving rather than punishing.
--
-- Client-side counterpart (not enforceable here, must hold in the app):
-- never show drivers "you're one ride away from losing your streak"
-- style nudges. Rider-side streaks stay on completion — a passenger
-- taking a seat carries none of the same safety pressure.
-- ------------------------------------------------------------

-- C1 · advance the route streak on publish
create or replace function public.trg_streak_on_publish()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.route_id is null or new.status <> 'published' then
    return new;
  end if;

  insert into route_streaks (driver_id, route_id, current_weeks, longest_weeks, last_ride_at)
  values (new.driver_id, new.route_id, 1, 1, new.departure_at)
  on conflict (driver_id, route_id) do update set
    quarter_start = case when route_streaks.quarter_start < now() - interval '13 weeks'
                         then now() else route_streaks.quarter_start end,
    freezes_used  = case when route_streaks.quarter_start < now() - interval '13 weeks'
                         then 0 else route_streaks.freezes_used end,
    current_weeks = case
      when route_streaks.last_ride_at > new.departure_at - interval '10 days'
        then route_streaks.current_weeks + 1
      when route_streaks.last_ride_at > new.departure_at - interval '17 days'
           and route_streaks.freezes_used < 2                    -- was 1
        then route_streaks.current_weeks + 1
      else 1
    end,
    longest_weeks = greatest(route_streaks.longest_weeks,
      case when route_streaks.last_ride_at > new.departure_at - interval '10 days'
           then route_streaks.current_weeks + 1
           when route_streaks.last_ride_at > new.departure_at - interval '17 days'
                and route_streaks.freezes_used < 2
           then route_streaks.current_weeks + 1
           else 1 end),
    freezes_used = case
      when route_streaks.last_ride_at <= new.departure_at - interval '10 days'
           and route_streaks.last_ride_at > new.departure_at - interval '17 days'
           and route_streaks.freezes_used < 2
        then route_streaks.freezes_used + 1
      else route_streaks.freezes_used
    end,
    last_ride_at = new.departure_at
  where route_streaks.last_ride_at < new.departure_at;   -- idempotent re-publish

  return new;
end $$;

create trigger rides_streak_on_publish
  after insert on public.rides
  for each row execute function public.trg_streak_on_publish();

-- C2 · completion trigger, with the driver route-streak block removed.
-- Points, milestones, badges, rank progression and the rider commute
-- streak all stay exactly as they were.
create or replace function public.trg_gamify_ride_completed()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_booking record;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then

    perform public.award_points(new.driver_id, 10, 'ride_completed', new.id);
    perform public.check_driver_milestones(new.driver_id);

    -- NOTE: driver route-streak advancement deliberately NOT here any
    -- more — it moved to trg_streak_on_publish (see C above). Do not
    -- reintroduce it without re-reading that rationale.

    for v_booking in
      select b.lead_passenger_id as rider_id
      from bookings b where b.ride_id = new.id and b.status = 'completed'
    loop
      perform public.award_points(v_booking.rider_id, 5, 'ride_completed', new.id);

      insert into rider_streaks (user_id, current_weeks, longest_weeks, last_booking_at)
      values (v_booking.rider_id, 1, 1, new.departure_at)
      on conflict (user_id) do update set
        quarter_start = case when rider_streaks.quarter_start < now() - interval '13 weeks'
                             then now() else rider_streaks.quarter_start end,
        freezes_used = case when rider_streaks.quarter_start < now() - interval '13 weeks'
                            then 0 else rider_streaks.freezes_used end,
        current_weeks = case
          when rider_streaks.last_booking_at > new.departure_at - interval '10 days'
            then rider_streaks.current_weeks + 1
          when rider_streaks.last_booking_at > new.departure_at - interval '17 days'
               and rider_streaks.freezes_used < 2
            then rider_streaks.current_weeks + 1
          else 1
        end,
        longest_weeks = greatest(rider_streaks.longest_weeks,
          case when rider_streaks.last_booking_at > new.departure_at - interval '10 days'
               then rider_streaks.current_weeks + 1
               when rider_streaks.last_booking_at > new.departure_at - interval '17 days'
                    and rider_streaks.freezes_used < 2
               then rider_streaks.current_weeks + 1
               else 1 end),
        freezes_used = case
          when rider_streaks.last_booking_at <= new.departure_at - interval '10 days'
               and rider_streaks.last_booking_at > new.departure_at - interval '17 days'
               and rider_streaks.freezes_used < 2
            then rider_streaks.freezes_used + 1
          else rider_streaks.freezes_used
        end,
        last_booking_at = new.departure_at;

      if (select current_weeks from rider_streaks where user_id = v_booking.rider_id) % 4 = 0 then
        perform public.award_points(v_booking.rider_id, 10, 'streak_milestone', new.id);
      end if;

      if (select count(*) from bookings b2 join rides r2 on r2.id = b2.ride_id
          where b2.lead_passenger_id = v_booking.rider_id
            and r2.driver_id = new.driver_id and b2.status = 'completed') >= 3
      then
        perform public.award_badge(v_booking.rider_id, 'rider_regular');
      end if;

      if (select count(distinct (r3.from_address, r3.to_address))
          from bookings b3 join rides r3 on r3.id = b3.ride_id
          where b3.lead_passenger_id = v_booking.rider_id and b3.status = 'completed') >= 5
      then
        perform public.award_badge(v_booking.rider_id, 'rider_explorer');
      end if;

      perform public.check_rank_progression(v_booking.rider_id);
    end loop;

    if new.route_id is not null
       and (select current_weeks from route_streaks
            where driver_id = new.driver_id and route_id = new.route_id) % 4 = 0
    then
      perform public.award_points(new.driver_id, 10, 'streak_milestone', new.id);
    end if;

    perform public.check_rank_progression(new.driver_id);
  end if;
  return new;
end $$;

-- ------------------------------------------------------------
-- D · parcel declared value + cap
-- Crowdshipping's recurring failure mode is disputes over lost or
-- damaged goods. A declared value with a hard cap bounds the platform's
-- exposure and gives the terms of service something concrete to point
-- at. Senders wanting to move something worth more than the cap should
-- use an insured courier, and the UI should say so.
-- ------------------------------------------------------------
alter table public.platform_settings
  add column if not exists parcel_max_declared_value numeric(10,2) not null default 200.00;

alter table public.parcels
  add column if not exists declared_value numeric(10,2) check (declared_value >= 0);

create or replace function public.trg_parcel_value_cap()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_cap numeric;
begin
  select parcel_max_declared_value into v_cap from platform_settings where id = 1;
  if new.declared_value is not null and v_cap is not null and new.declared_value > v_cap then
    raise exception
      'parcel_value_above_cap: declared value % exceeds the % AZN limit for SameWay parcels. Higher-value items need an insured courier.',
      new.declared_value, v_cap
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger parcels_value_cap
  before insert or update of declared_value on public.parcels
  for each row execute function public.trg_parcel_value_cap();
