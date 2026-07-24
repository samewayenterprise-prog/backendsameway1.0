-- ============================================================
-- 019 · FIX ride completion — duplicate column assignment
--
-- THE BUG: trg_gamify_ride_completed() assigned `freezes_used` TWICE
-- in the same ON CONFLICT ... DO UPDATE SET list (once to reset the
-- quarterly freeze allowance, once to spend a freeze). Postgres
-- rejects that outright:
--     multiple assignments to same column "freezes_used"
-- Present in BOTH the route_streaks (driver) and rider_streaks
-- upserts.
--
-- IMPACT: this trigger fires on the same UPDATE as trg_ride_completed,
-- so the exception aborted the whole statement. **No ride could ever
-- be marked completed.** That silently blocked the entire end-of-ride
-- chain: bookings never closed, review prompts never sent, ratings
-- could never be left (the reviews RLS policy requires a completed
-- booking), and driver ride counts never incremented.
--
-- Found by driving a ride from published → completed against a local
-- replica while building the web ratings UI. Never surfaced before
-- because no ride had been completed on a real database yet.
--
-- THE FIX: hoist the quarter rollover into its own UPDATE statement
-- ahead of each upsert, leaving exactly one `freezes_used` assignment
-- in the SET list. This is also more correct than the original intent:
-- the freeze arithmetic in the upsert now reads the already-reset
-- allowance, instead of the stale pre-reset value it would have seen.
--
-- The function is otherwise reproduced unchanged.
-- ============================================================

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
      -- [017/019 FIX] Quarter rollover is now its own statement. It used
      -- to be a second `freezes_used = ...` inside the ON CONFLICT SET
      -- list, which Postgres rejects outright ("multiple assignments to
      -- same column"). Doing it first also makes the freeze arithmetic
      -- below read the already-reset allowance, which is what the rule
      -- always intended.
      update route_streaks
         set quarter_start = now(), freezes_used = 0
       where driver_id = new.driver_id
         and route_id  = new.route_id
         and quarter_start < now() - interval '13 weeks';

      insert into route_streaks (driver_id, route_id, current_weeks, longest_weeks, last_ride_at)
      values (new.driver_id, new.route_id, 1, 1, new.departure_at)
      on conflict (driver_id, route_id) do update set
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

      -- [017/019 FIX] same quarter-rollover fix as the driver streak above
      update rider_streaks
         set quarter_start = now(), freezes_used = 0
       where user_id = v_booking.rider_id
         and quarter_start < now() - interval '13 weeks';

      insert into rider_streaks (user_id, current_weeks, longest_weeks, last_booking_at)
      values (v_booking.rider_id, 1, 1, new.departure_at)
      on conflict (user_id) do update set
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
