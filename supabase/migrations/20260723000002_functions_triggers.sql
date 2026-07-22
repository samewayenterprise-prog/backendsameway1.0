-- ============================================================
-- YOLDA · 002_functions_triggers.sql
-- Helpers, atomic RPCs, counter triggers, message filter,
-- notification fan-out, booking expiry job
-- ============================================================

-- ---------- signup: mirror auth.users into public ----------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.users (id, phone, email)
  values (new.id, coalesce(new.phone,''), new.email)
  on conflict (id) do nothing;

  insert into public.user_preferences (user_id) values (new.id)
  on conflict do nothing;

  insert into public.user_verifications (user_id, phone_verified_at)
  values (new.id, case when new.phone is not null then now() end)
  on conflict do nothing;

  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- membership helpers (SECURITY DEFINER avoids RLS recursion) ----------
create or replace function public.is_ride_driver(p_ride uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from rides r where r.id = p_ride and r.driver_id = auth.uid());
$$;

create or replace function public.is_booking_member(p_booking uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from bookings b
    where b.id = p_booking
      and (b.lead_passenger_id = auth.uid()
           or exists (select 1 from booking_passengers bp
                      where bp.booking_id = b.id and bp.user_id = auth.uid())
           or exists (select 1 from rides r
                      where r.id = b.ride_id and r.driver_id = auth.uid()))
  );
$$;

create or replace function public.is_conversation_member(p_conv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from conversation_participants
                 where conversation_id = p_conv and user_id = auth.uid());
$$;

-- ============================================================
-- ATOMIC BOOKING RPCs
-- Clients call these; direct INSERT on bookings is blocked by RLS.
-- ============================================================

-- Create a booking (solo = group of 1). Locks the ride row, checks
-- seats + ladies_only, decrements inventory, seeds passenger rows.
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
begin
  if p_seat_count < 1 or p_seat_count > 7 then
    raise exception 'invalid_seat_count';
  end if;

  select * into v_ride from rides where id = p_ride_id for update;
  if not found then raise exception 'ride_not_found'; end if;
  if v_ride.status <> 'published' then raise exception 'ride_not_bookable'; end if;
  if v_ride.departure_at <= now() then raise exception 'ride_departed'; end if;
  if v_ride.driver_id = auth.uid() then raise exception 'own_ride'; end if;
  if v_ride.seats_available < p_seat_count then raise exception 'not_enough_seats'; end if;

  if v_ride.ladies_only then
    select gender into v_gender from users where id = auth.uid();
    if v_gender <> 'female' then raise exception 'ladies_only_ride'; end if;
  end if;

  -- hold seats immediately
  update rides set
    seats_available = seats_available - p_seat_count,
    status = case when seats_available - p_seat_count = 0 then 'full' else status end
  where id = p_ride_id;

  v_status := case
    when p_seat_count > 1              then 'awaiting_group'   -- friends must join
    when v_ride.instant_book           then 'confirmed'
    else 'pending'                                             -- driver must approve
  end;

  insert into bookings (ride_id, lead_passenger_id, pickup_stop_id, dropoff_stop_id,
                        seat_count, total_price, payment_method, status,
                        driver_approved_at, expires_at)
  values (p_ride_id, auth.uid(), p_pickup, p_dropoff,
          p_seat_count, p_seat_count * v_ride.price_per_seat, p_payment, v_status,
          case when v_status = 'confirmed' then now() end,
          case when v_status = 'awaiting_group'
               then now() + interval '30 minutes'              -- group-confirm window
               else v_ride.departure_at end)
  returning id into v_booking;

  -- lead passenger row (confirmed) + empty slots for invitees
  insert into booking_passengers (booking_id, user_id, invited_via, status, joined_at)
  values (v_booking, auth.uid(), 'direct', 'confirmed', now());

  insert into booking_passengers (booking_id, invited_via, status)
  select v_booking, 'link', 'pending' from generate_series(2, p_seat_count);

  -- notify driver unless instant-booked
  if v_status = 'pending' then
    insert into notifications (user_id, type, data)
    values (v_ride.driver_id, 'booking_request',
            jsonb_build_object('booking_id', v_booking, 'ride_id', p_ride_id));
  end if;

  return v_booking;
end $$;

-- Generate an invite link token for a group booking (lead only).
create or replace function public.create_booking_invite(p_booking uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare v_token text;
begin
  if not exists (select 1 from bookings
                 where id = p_booking and lead_passenger_id = auth.uid()
                   and status in ('awaiting_group','pending','confirmed')) then
    raise exception 'not_lead_or_closed';
  end if;

  insert into booking_invites (booking_id, created_by, expires_at)
  values (p_booking, auth.uid(), now() + interval '24 hours')
  returning token into v_token;

  return v_token;
end $$;

-- Invitee accepts via token → claims a pending passenger slot.
create or replace function public.accept_booking_invite(p_token text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_inv  booking_invites%rowtype;
  v_slot uuid;
  v_b    bookings%rowtype;
begin
  -- Link is multi-use: valid until expiry or until the group fills.
  select * into v_inv from booking_invites
  where token = p_token and expires_at > now()
  for update;
  if not found then raise exception 'invite_invalid'; end if;

  select * into v_b from bookings where id = v_inv.booking_id for update;
  if v_b.status not in ('awaiting_group','pending','confirmed') then
    raise exception 'booking_closed';
  end if;

  -- already in this group?
  if exists (select 1 from booking_passengers
             where booking_id = v_b.id and user_id = auth.uid()) then
    raise exception 'already_joined';
  end if;

  select id into v_slot from booking_passengers
  where booking_id = v_b.id and user_id is null and status = 'pending'
  limit 1 for update skip locked;
  if v_slot is null then raise exception 'group_full'; end if;

  update booking_passengers
  set user_id = auth.uid(), status = 'confirmed', joined_at = now()
  where id = v_slot;

  update booking_invites set used_by = auth.uid(), used_at = now()
  where id = v_inv.id;                          -- audit trail of last redeemer; link stays live

  -- if the whole group is now confirmed → advance booking
  if not exists (select 1 from booking_passengers
                 where booking_id = v_b.id and status = 'pending') then
    update bookings
    set status = case when (select instant_book from rides where id = v_b.ride_id)
                      then 'confirmed' else 'pending' end,
        driver_approved_at = case when (select instant_book from rides where id = v_b.ride_id)
                                  then now() end,
        expires_at = (select departure_at from rides where id = v_b.ride_id)
    where id = v_b.id;

    insert into notifications (user_id, type, data)
    select r.driver_id,
           case when r.instant_book then 'booking_approved' else 'booking_request' end,
           jsonb_build_object('booking_id', v_b.id, 'ride_id', r.id)
    from rides r where r.id = v_b.ride_id;
  end if;

  insert into notifications (user_id, type, data)
  values (v_b.lead_passenger_id, 'group_invite_accepted',
          jsonb_build_object('booking_id', v_b.id, 'user_id', auth.uid()));

  return v_b.id;
end $$;

-- Driver approves or declines a pending booking.
create or replace function public.respond_booking(p_booking uuid, p_approve boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare v_b bookings%rowtype;
begin
  select b.* into v_b from bookings b
  join rides r on r.id = b.ride_id
  where b.id = p_booking and r.driver_id = auth.uid()
  for update;
  if not found then raise exception 'not_your_booking'; end if;
  if v_b.status <> 'pending' then raise exception 'not_pending'; end if;

  if p_approve then
    update bookings set status = 'confirmed', driver_approved_at = now()
    where id = p_booking;
  else
    update bookings set status = 'declined' where id = p_booking;
    perform public.release_seats(p_booking);
  end if;

  insert into notifications (user_id, type, data)
  values (v_b.lead_passenger_id,
          case when p_approve then 'booking_approved' else 'booking_declined' end,
          jsonb_build_object('booking_id', p_booking));
end $$;

-- ============================================================
-- PARCEL RPCs
-- Sender creates a request against a ride that accepts parcels;
-- driver accepts/declines; either side marks delivered.
-- Payment is prepaid-only, charged after driver accepts (Edge
-- Function calls Epoint once status flips to 'accepted').
-- ============================================================

create or replace function public.create_parcel(
  p_ride_id        uuid,
  p_recipient_name text,
  p_recipient_phone text,
  p_size           parcel_size_t,
  p_weight_kg      numeric,
  p_description    text,
  p_photo_url      text,
  p_price          numeric,
  p_prohibited_ack boolean
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_ride rides%rowtype; v_parcel uuid; v_open_count int;
begin
  if not p_prohibited_ack then raise exception 'must_ack_prohibited_items'; end if;

  select * into v_ride from rides where id = p_ride_id for update;
  if not found then raise exception 'ride_not_found'; end if;
  if not v_ride.accepts_parcels then raise exception 'ride_not_parcel_enabled'; end if;
  if v_ride.status not in ('published','full') then raise exception 'ride_not_bookable'; end if;
  if v_ride.driver_id = auth.uid() then raise exception 'own_ride'; end if;

  select count(*) into v_open_count from parcels
  where ride_id = p_ride_id and status in ('pending','accepted','in_transit');
  if v_open_count >= v_ride.parcel_capacity then raise exception 'parcel_capacity_full'; end if;

  insert into parcels (ride_id, sender_id, recipient_name, recipient_phone,
                       size, weight_kg, description, photo_url, price, prohibited_ack)
  values (p_ride_id, auth.uid(), p_recipient_name, p_recipient_phone,
          p_size, p_weight_kg, p_description, p_photo_url, p_price, true)
  returning id into v_parcel;

  insert into notifications (user_id, type, data)
  values (v_ride.driver_id, 'parcel_request',
          jsonb_build_object('parcel_id', v_parcel, 'ride_id', p_ride_id));

  return v_parcel;
end $$;

create or replace function public.respond_parcel(p_parcel uuid, p_approve boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare v_p parcels%rowtype;
begin
  select p.* into v_p from parcels p
  join rides r on r.id = p.ride_id
  where p.id = p_parcel and r.driver_id = auth.uid() for update;
  if not found then raise exception 'not_your_parcel'; end if;
  if v_p.status <> 'pending' then raise exception 'not_pending'; end if;

  update parcels set
    status = case when p_approve then 'accepted' else 'declined' end,
    accepted_at = case when p_approve then now() end
  where id = p_parcel;

  insert into notifications (user_id, type, data)
  values (v_p.sender_id,
          case when p_approve then 'parcel_accepted' else 'parcel_declined' end,
          jsonb_build_object('parcel_id', p_parcel));
  -- payment charge is triggered by an Edge Function watching for
  -- status = 'accepted' (keeps Epoint calls out of Postgres).
end $$;

create or replace function public.mark_parcel_delivered(p_parcel uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_p parcels%rowtype;
begin
  select p.* into v_p from parcels p
  join rides r on r.id = p.ride_id
  where p.id = p_parcel and r.driver_id = auth.uid() for update;
  if not found then raise exception 'not_your_parcel'; end if;
  if v_p.status <> 'in_transit' and v_p.status <> 'accepted' then
    raise exception 'not_deliverable';
  end if;

  update parcels set status = 'delivered', delivered_at = now() where id = p_parcel;

  insert into notifications (user_id, type, data)
  values (v_p.sender_id, 'parcel_delivered', jsonb_build_object('parcel_id', p_parcel));
end $$;


create or replace function public.cancel_booking(p_booking uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_b bookings%rowtype;
begin
  select * into v_b from bookings
  where id = p_booking and lead_passenger_id = auth.uid() for update;
  if not found then raise exception 'not_your_booking'; end if;
  if v_b.status in ('cancelled','declined','expired','completed') then
    raise exception 'already_closed';
  end if;

  update bookings set status = 'cancelled' where id = p_booking;
  perform public.release_seats(p_booking);

  insert into notifications (user_id, type, data)
  select r.driver_id, 'booking_cancelled', jsonb_build_object('booking_id', p_booking)
  from rides r join bookings b on b.ride_id = r.id where b.id = p_booking;
end $$;

-- Return held seats to the ride.
create or replace function public.release_seats(p_booking uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_b bookings%rowtype;
begin
  select * into v_b from bookings where id = p_booking;
  update rides set
    seats_available = least(seats_total, seats_available + v_b.seat_count),
    status = case when status = 'full' then 'published' else status end
  where id = v_b.ride_id;
end $$;

-- Expire stale group bookings (pg_cron, every minute).
create or replace function public.expire_stale_bookings()
returns int
language plpgsql security definer set search_path = public as $$
declare v_count int := 0; v_b record;
begin
  for v_b in
    select id from bookings
    where status in ('pending','awaiting_group') and expires_at < now()
    for update skip locked
  loop
    update bookings set status = 'expired' where id = v_b.id;
    perform public.release_seats(v_b.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

select cron.schedule('expire-bookings', '* * * * *',
                     $$select public.expire_stale_bookings()$$);

-- ============================================================
-- COUNTER TRIGGERS (driver_profiles denormalized fields)
-- ============================================================

create or replace function public.trg_follow_counter()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into driver_profiles (user_id, follower_count) values (new.driver_id, 1)
    on conflict (user_id) do update
      set follower_count = driver_profiles.follower_count + 1;
  elsif tg_op = 'DELETE' then
    update driver_profiles set follower_count = greatest(0, follower_count - 1)
    where user_id = old.driver_id;
  end if;
  return coalesce(new, old);
end $$;

create trigger follows_counter
  after insert or delete on public.follows
  for each row execute function public.trg_follow_counter();

create or replace function public.trg_review_counter()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- only reviews OF the driver move driver stats (reviewer role = rider)
  if new.role = 'rider' then
    insert into driver_profiles (user_id, rating_avg, rating_count)
    values (new.reviewee_id, new.rating, 1)
    on conflict (user_id) do update set
      rating_avg  = round(((driver_profiles.rating_avg * driver_profiles.rating_count)
                          + new.rating) / (driver_profiles.rating_count + 1.0), 2),
      rating_count = driver_profiles.rating_count + 1;
  end if;
  return new;
end $$;

create trigger reviews_counter
  after insert on public.reviews
  for each row execute function public.trg_review_counter();

create or replace function public.trg_ride_completed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    update driver_profiles set ride_count = ride_count + 1
    where user_id = new.driver_id;

    -- close out confirmed bookings + prompt both sides to review
    update bookings set status = 'completed'
    where ride_id = new.id and status = 'confirmed';

    insert into notifications (user_id, type, data)
    select b.lead_passenger_id, 'review_prompt',
           jsonb_build_object('booking_id', b.id, 'ride_id', new.id)
    from bookings b where b.ride_id = new.id and b.status = 'completed';

    insert into notifications (user_id, type, data)
    values (new.driver_id, 'review_prompt', jsonb_build_object('ride_id', new.id));
  end if;
  return new;
end $$;

create trigger rides_completed
  after update on public.rides
  for each row execute function public.trg_ride_completed();

-- ============================================================
-- GAMIFICATION ENGINE
-- ============================================================

create or replace function public.award_points(
  p_user uuid, p_amount int, p_reason point_reason_t, p_ref uuid default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into user_points (user_id, balance, lifetime_earned)
  values (p_user, p_amount, greatest(p_amount,0))
  on conflict (user_id) do update set
    balance = user_points.balance + p_amount,
    lifetime_earned = user_points.lifetime_earned + greatest(p_amount,0);

  insert into point_transactions (user_id, delta, reason, ref_id)
  values (p_user, p_amount, p_reason, p_ref);
end $$;

create or replace function public.award_badge(p_user uuid, p_code text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_badge uuid;
begin
  select id into v_badge from badges where code = p_code;
  if v_badge is null then return; end if;   -- unknown code, no-op

  insert into user_badges (user_id, badge_id)
  values (p_user, v_badge)
  on conflict do nothing;
end $$;

-- Checks milestone badges after counters change. Cheap — only
-- fires from the two triggers below, not on a schedule.
create or replace function public.check_driver_milestones(p_driver uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_rides int; v_followers int;
begin
  select ride_count, follower_count into v_rides, v_followers
  from driver_profiles where user_id = p_driver;

  if v_rides >= 1   then perform public.award_badge(p_driver, 'driver_rookie');       end if;
  if v_rides >= 25  then perform public.award_badge(p_driver, 'driver_regular');      end if;
  if v_rides >= 100 then perform public.award_badge(p_driver, 'driver_veteran');      end if;
  if v_rides >= 500 then perform public.award_badge(p_driver, 'driver_road_captain'); end if;

  if v_followers >= 10  then perform public.award_badge(p_driver, 'driver_rising_star');    end if;
  if v_followers >= 50  then perform public.award_badge(p_driver, 'driver_local_favorite'); end if;
  if v_followers >= 200 then perform public.award_badge(p_driver, 'driver_city_icon');      end if;
end $$;

-- Re-check follower badges on every new follow (cheap, single row).
create or replace function public.trg_follow_milestones()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform public.check_driver_milestones(new.driver_id);
  end if;
  return coalesce(new, old);
end $$;

create trigger follows_milestones
  after insert on public.follows
  for each row execute function public.trg_follow_milestones();

-- Points + streaks + ride-count badges, on ride completion.
create or replace function public.trg_gamify_ride_completed()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_booking record;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then

    perform public.award_points(new.driver_id, 10, 'ride_completed', new.id);
    perform public.check_driver_milestones(new.driver_id);

    -- driver's per-route streak (only for rides generated from a recurring route)
    -- freeze rule: miss one week and a freeze is available this quarter →
    -- streak survives, freeze is spent. Miss with no freeze left → resets.
    if new.route_id is not null then
      insert into route_streaks (driver_id, route_id, current_weeks, longest_weeks, last_ride_at)
      values (new.driver_id, new.route_id, 1, 1, new.departure_at)
      on conflict (driver_id, route_id) do update set
        quarter_start = case when route_streaks.quarter_start < now() - interval '13 weeks'
                             then now() else route_streaks.quarter_start end,
        freezes_used = case when route_streaks.quarter_start < now() - interval '13 weeks'
                            then 0 else route_streaks.freezes_used end,
        current_weeks = case
          when route_streaks.last_ride_at > new.departure_at - interval '10 days'
            then route_streaks.current_weeks + 1
          when route_streaks.last_ride_at > new.departure_at - interval '17 days'
               and route_streaks.freezes_used < 1
            then route_streaks.current_weeks + 1               -- freeze covers the miss
          else 1
        end,
        longest_weeks = greatest(route_streaks.longest_weeks,
          case when route_streaks.last_ride_at > new.departure_at - interval '10 days'
               then route_streaks.current_weeks + 1
               when route_streaks.last_ride_at > new.departure_at - interval '17 days'
                    and route_streaks.freezes_used < 1
               then route_streaks.current_weeks + 1
               else 1 end),
        freezes_used = case
          when route_streaks.last_ride_at <= new.departure_at - interval '10 days'
               and route_streaks.last_ride_at > new.departure_at - interval '17 days'
               and route_streaks.freezes_used < 1
            then route_streaks.freezes_used + 1
          else route_streaks.freezes_used
        end,
        last_ride_at = new.departure_at;
    end if;

    -- riders on this ride: points + commute streak (same freeze rule) + badges
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
               and rider_streaks.freezes_used < 1
            then rider_streaks.current_weeks + 1
          else 1
        end,
        longest_weeks = greatest(rider_streaks.longest_weeks,
          case when rider_streaks.last_booking_at > new.departure_at - interval '10 days'
               then rider_streaks.current_weeks + 1
               when rider_streaks.last_booking_at > new.departure_at - interval '17 days'
                    and rider_streaks.freezes_used < 1
               then rider_streaks.current_weeks + 1
               else 1 end),
        freezes_used = case
          when rider_streaks.last_booking_at <= new.departure_at - interval '10 days'
               and rider_streaks.last_booking_at > new.departure_at - interval '17 days'
               and rider_streaks.freezes_used < 1
            then rider_streaks.freezes_used + 1
          else rider_streaks.freezes_used
        end,
        last_booking_at = new.departure_at;

      -- streak milestone bonus — every completed 4-week block
      if (select current_weeks from rider_streaks where user_id = v_booking.rider_id) % 4 = 0 then
        perform public.award_points(v_booking.rider_id, 10, 'streak_milestone', new.id);
      end if;

      -- "Regular" — 3+ completed rides with this same driver
      if (select count(*) from bookings b2 join rides r2 on r2.id = b2.ride_id
          where b2.lead_passenger_id = v_booking.rider_id
            and r2.driver_id = new.driver_id and b2.status = 'completed') >= 3
      then
        perform public.award_badge(v_booking.rider_id, 'rider_regular');
      end if;

      -- "Explorer" — 5+ distinct corridors (from_address/to_address pairs)
      if (select count(distinct (r3.from_address, r3.to_address))
          from bookings b3 join rides r3 on r3.id = b3.ride_id
          where b3.lead_passenger_id = v_booking.rider_id and b3.status = 'completed') >= 5
      then
        perform public.award_badge(v_booking.rider_id, 'rider_explorer');
      end if;

      perform public.check_rank_progression(v_booking.rider_id);
    end loop;

    -- route streak milestone bonus (driver side)
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

create trigger rides_gamify_completed
  after update on public.rides
  for each row execute function public.trg_gamify_ride_completed();

-- Small points nudge for leaving a review (closes the rating loop).
create or replace function public.trg_gamify_review()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.award_points(new.reviewer_id, 2, 'review_left', new.id);
  if new.rating = 5 then
    perform public.award_points(new.reviewee_id, 3, 'five_star_bonus', new.id);
  end if;
  return new;
end $$;

create trigger reviews_gamify
  after insert on public.reviews
  for each row execute function public.trg_gamify_review();

-- ============================================================
-- RANK PROGRESSION
-- Requires BOTH months-since-first-completed-activity AND lifetime
-- reps ≥ threshold. Ranks never downgrade — only ever moves up.
-- ============================================================
create or replace function public.check_rank_progression(p_user uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_first_ride timestamptz;
  v_months     int;
  v_reps       int;
  v_current    int;
  v_target     ranks%rowtype;
begin
  select min(departure_at) into v_first_ride
  from rides r
  where r.driver_id = p_user and r.status = 'completed'
  union all
  select min(r.departure_at) from bookings b join rides r on r.id = b.ride_id
  where b.lead_passenger_id = p_user and b.status = 'completed'
  order by 1 limit 1;

  if v_first_ride is null then return; end if;

  v_months := extract(month from age(now(), v_first_ride))
            + extract(year from age(now(), v_first_ride)) * 12;
  select coalesce(balance, 0) into v_reps from user_points where user_id = p_user;
  select coalesce((select r.rank_number from user_ranks ur
                   join ranks r on r.id = ur.rank_id where ur.user_id = p_user), 0)
    into v_current;

  select * into v_target from ranks
  where min_months <= v_months and min_reps <= coalesce(v_reps,0)
    and rank_number > v_current
  order by rank_number desc limit 1;

  if found then
    insert into user_ranks (user_id, rank_id, achieved_at)
    values (p_user, v_target.id, now())
    on conflict (user_id) do update set
      rank_id = excluded.rank_id, achieved_at = now();
  end if;
end $$;

-- ============================================================
-- REPUTATION PENALTIES
-- ============================================================

-- Cancelling a CONFIRMED booking is a broken commitment; cancelling
-- a still-pending request costs nothing (no commitment existed yet).
create or replace function public.trg_cancellation_penalty()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'confirmed' and new.status = 'cancelled' then
    perform public.award_points(new.lead_passenger_id, -5, 'cancellation_penalty', new.id);
  end if;
  return new;
end $$;

create trigger bookings_cancellation_penalty
  after update on public.bookings
  for each row execute function public.trg_cancellation_penalty();

-- A driver cancelling an already-published ride affects everyone
-- who had confirmed — penalize the driver once per ride cancelled.
create or replace function public.trg_ride_cancel_penalty()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'cancelled' and old.status in ('published','full') then
    perform public.award_points(new.driver_id, -5, 'cancellation_penalty', new.id);
  end if;
  return new;
end $$;

create trigger rides_cancel_penalty
  after update on public.rides
  for each row execute function public.trg_ride_cancel_penalty();

-- Report resolution: 'resolved' means the report was upheld against
-- the reported user. no_show gets a smaller penalty than everything
-- else (dangerous driving, harassment, scams, etc.).
create or replace function public.trg_report_penalty()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'resolved' and old.status is distinct from 'resolved'
     and new.reported_user_id is not null
  then
    if new.reason = 'no_show' then
      perform public.award_points(new.reported_user_id, -10, 'no_show_penalty', new.id);
    else
      perform public.award_points(new.reported_user_id, -20, 'report_penalty', new.id);
    end if;
  end if;
  return new;
end $$;

create trigger reports_penalty
  after update on public.reports
  for each row execute function public.trg_report_penalty();

-- ============================================================
-- FOLLOW → NOTIFY FAN-OUT
-- In-app inbox rows written here; Edge Function watches
-- notifications (or rides) inserts and fires FCM.
-- ============================================================

create or replace function public.trg_ride_fanout()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into notifications (user_id, type, data)
  select f.follower_id, 'followed_driver_posted',
         jsonb_build_object('ride_id', new.id, 'driver_id', new.driver_id,
                            'from', new.from_address, 'to', new.to_address,
                            'departure_at', new.departure_at)
  from follows f
  where f.driver_id = new.driver_id;
  return new;
end $$;

create trigger rides_fanout
  after insert on public.rides
  for each row execute function public.trg_ride_fanout();

-- ============================================================
-- MESSAGE CONTACT-INFO FILTER (BlaBla-style)
-- Scrubs phone numbers, emails, URLs before insert.
-- ============================================================

create or replace function public.trg_scrub_message()
returns trigger language plpgsql as $$
begin
  if not new.is_system then
    new.body := regexp_replace(new.body,
      '(\+?\d[\d\s\-\(\)]{7,}\d)', '■■■', 'g');                       -- phones
    new.body := regexp_replace(new.body,
      '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '■■■', 'g'); -- emails
    new.body := regexp_replace(new.body,
      '(https?://\S+|www\.\S+)', '■■■', 'gi');                         -- urls
  end if;
  return new;
end $$;

create trigger messages_scrub
  before insert on public.messages
  for each row execute function public.trg_scrub_message();

-- ---------- message → notify other participants ----------
create or replace function public.trg_message_notify()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into notifications (user_id, type, data)
  select cp.user_id, 'message',
         jsonb_build_object('conversation_id', new.conversation_id,
                            'message_id', new.id)
  from conversation_participants cp
  where cp.conversation_id = new.conversation_id
    and cp.user_id <> coalesce(new.sender_id,'00000000-0000-0000-0000-000000000000');
  return new;
end $$;

create trigger messages_notify
  after insert on public.messages
  for each row execute function public.trg_message_notify();

-- ============================================================
-- CONVERSATION AUTO-CREATE on booking confirm
-- ============================================================

create or replace function public.trg_booking_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_conv uuid;
begin
  if new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    insert into conversations (ride_id, booking_id, type)
    values (new.ride_id,
            new.id,
            case when new.seat_count > 1 then 'group' else 'booking' end)
    returning id into v_conv;

    insert into conversation_participants (conversation_id, user_id)
    select v_conv, r.driver_id from rides r where r.id = new.ride_id
    union
    select v_conv, bp.user_id from booking_passengers bp
    where bp.booking_id = new.id and bp.user_id is not null
    on conflict do nothing;
  end if;
  return new;
end $$;

create trigger bookings_conversation
  after update on public.bookings
  for each row execute function public.trg_booking_conversation();
