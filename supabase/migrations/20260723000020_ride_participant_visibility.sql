-- ============================================================
-- 020 · Ride visibility for the people who were actually ON the ride
--
-- THE GAP: rides_select has always been
--     status in ('published','full') or driver_id = auth.uid()
-- which covers the two cases we designed for — public browsing of
-- open rides, and a driver seeing their own. It never covered the
-- third: *a passenger who booked this ride*.
--
-- The moment a ride leaves 'published'/'full' — i.e. as soon as it is
-- started, completed or cancelled — every passenger instantly loses
-- read access to the ride row itself, even though their booking row
-- survives and still points at it.
--
-- IMPACT (all found by driving the real flow, not by reading policies):
--   * "My bookings" showed a completed trip with a blank route: the
--     rides embed silently resolved to null.
--   * The messages inbox and thread header lost their route context
--     for exactly the conversations most likely to still be in use
--     (right after the trip).
--   * Worst: the ratings page loads the ride to find the driver to
--     rate. With the ride invisible it 404'd — so a rider could never
--     rate a completed trip. The whole post-ride ratings loop, which
--     the driver reputation system depends on, was unreachable from
--     the passenger side.
--
-- Note this was NOT caught by the reviews RLS policy tests: those
-- assert that a non-participant cannot insert a review. The policy is
-- correct. The hole was upstream, in whether the rider could even
-- load the page that lets them submit one.
--
-- THE FIX: a SECURITY DEFINER helper (so it can look across bookings
-- and conversations without tripping their own RLS or recursing into
-- rides_select) that answers "was this person part of this ride?" —
-- as driver, as lead passenger, as a group passenger, or as a member
-- of a conversation attached to the ride (which also covers pre-
-- booking inquiry threads from migration 016).
--
-- This widens read access ONLY to people who already demonstrably
-- belong to the ride. Strangers still see published/full rides and
-- nothing else.
-- ============================================================

create or replace function public.is_ride_participant(p_ride uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select
    exists (
      select 1 from rides r
       where r.id = p_ride and r.driver_id = auth.uid()
    )
    or exists (
      select 1 from bookings b
       where b.ride_id = p_ride
         and (
           b.lead_passenger_id = auth.uid()
           or exists (
             select 1 from booking_passengers bp
              where bp.booking_id = b.id and bp.user_id = auth.uid()
           )
         )
    )
    or exists (
      select 1
        from conversations c
        join conversation_participants cp on cp.conversation_id = c.id
       where c.ride_id = p_ride and cp.user_id = auth.uid()
    );
$$;

comment on function public.is_ride_participant(uuid) is
  'True if the current user was part of this ride (driver, lead passenger, group passenger, or a member of a conversation on it). Used by rides_select so participants keep access after the ride leaves published state.';

-- Supporting indexes for the paths this helper walks. bookings(ride_id)
-- and conversations(ride_id) are both hit on every non-public ride read.
create index if not exists bookings_ride_idx      on public.bookings(ride_id);
create index if not exists conversations_ride_idx on public.conversations(ride_id);

drop policy if exists rides_select on public.rides;
create policy rides_select on public.rides
  for select using (
    status in ('published','full')
    or driver_id = (select auth.uid())
    or public.is_ride_participant(id)
  );
