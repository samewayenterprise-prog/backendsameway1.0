-- ============================================================
-- 013 · RIDE COMPANIONS — cross-booking passenger visibility
--
-- Gap found by comparing against BlaBlaCar directly: on a ride detail
-- screen (including a PAST, completed ride), BlaBlaCar shows "Other
-- passengers — Oliwia (+1)" even though Oliwia booked in a separate
-- group from the viewer. Tapping her opens her public profile, and
-- she can be rated/reported/messaged from there. None of this has a
-- time cutoff — it works identically on old rides.
--
-- Our booking_passengers RLS (bp_select_member, is_booking_member) is
-- scoped to ONE booking. It correctly hides other bookings' passenger
-- rows at the table level — which is right, we don't want to just
-- relax that policy, since booking_passengers carries invite/contact
-- plumbing we don't want broadly exposed. Instead: a narrow,
-- purpose-built SECURITY DEFINER function that returns only the safe
-- "who else is on this ride" summary, gated on the caller actually
-- having been a confirmed participant of THAT ride themselves.
-- ============================================================

create or replace function public.ride_companions(p_ride_id uuid)
returns table (
  booking_id      uuid,
  lead_user_id    uuid,
  lead_name       text,
  lead_photo_url  text,
  companion_count int
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_caller_is_participant boolean;
begin
  -- Gate: caller must themselves be a confirmed passenger or the
  -- driver on this ride. Anyone else gets nothing — this function is
  -- not a general-purpose ride roster lookup.
  select exists (
    select 1 from rides r where r.id = p_ride_id and r.driver_id = (select auth.uid())
    union
    select 1 from bookings b
    join booking_passengers bp on bp.booking_id = b.id
    where b.ride_id = p_ride_id
      and bp.user_id = (select auth.uid())
      and bp.status = 'confirmed'
      and b.status in ('confirmed', 'completed')
  ) into v_caller_is_participant;

  if not v_caller_is_participant then
    return;                                      -- empty result, not an error
  end if;

  -- "Other passengers" — matches the real screen title, so the
  -- caller's own booking is excluded here rather than left for the
  -- client to filter out every time.
  return query
    select
      b.id,
      b.lead_passenger_id,
      u.full_name,
      u.photo_url,
      (select count(*)::int - 1 from booking_passengers bp2
         where bp2.booking_id = b.id and bp2.status = 'confirmed')
    from bookings b
    join users u on u.id = b.lead_passenger_id
    where b.ride_id = p_ride_id
      and b.status in ('confirmed', 'completed')
      and u.is_deleted = false
      and b.lead_passenger_id <> (select auth.uid())
    order by b.created_at;
end $$;

comment on function public.ride_companions is
  'Cross-booking "who else is on this ride" list, grouped by lead
   passenger with a companion count — mirrors BlaBlaCar''s "Oliwia (+1)"
   pattern. Works on past/completed rides with no time cutoff, matching
   observed BlaBlaCar behaviour. Gated on the caller having actually
   been a confirmed participant (or the driver) of this specific ride;
   returns nothing otherwise rather than raising, so a client can call
   it speculatively without special-casing errors.';

grant execute on function public.ride_companions(uuid) to authenticated;

-- Reporting a companion glimpsed this way already works with zero
-- schema change: reports.reported_user_id takes any user id, and
-- there is no booking-membership requirement on the reports table —
-- confirmed by reading 003_rls.sql (reports_insert only checks
-- reporter_id = auth.uid()). Noted here so that fact is documented
-- next to the feature it supports, not just implied.
