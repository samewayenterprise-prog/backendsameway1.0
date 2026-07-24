-- ============================================================
-- 018 · FIX uncast CASE → enum inserts on notifications.type
--
-- Sibling of migration 017. Same root cause, different tables, found
-- the same way: driving the real booking flow end-to-end instead of
-- trusting that the RPCs worked.
--
-- THE RULE (worth internalising — this is the third time it has bitten):
--   UPDATE t SET enum_col = CASE WHEN c THEN 'a' ELSE 'b' END   -- OK
--   INSERT INTO t (enum_col) VALUES (CASE WHEN c THEN 'a' ELSE 'b' END)  -- FAILS
-- In the UPDATE the CASE sits in *assignment context*, so the unknown
-- literals are coerced straight to the target enum. In the INSERT ...
-- VALUES form the CASE is typed first — two unknown literals resolve
-- to `text` — and there is no implicit text → enum cast, so it raises:
--   column "type" is of type notification_t but expression is of
--   type text
-- Every CASE whose branches are ALL bare literals therefore needs an
-- explicit ::enum_type when it feeds an enum column in VALUES.
--
-- IMPACT BEFORE THIS FIX:
--   * respond_booking() raised every single time → a driver could not
--     approve OR decline a booking at all. The whole approval path was
--     dead, and because the exception aborts the transaction, the
--     status update was rolled back with it.
--   * respond_parcel() had the identical defect on the parcel path.
--
-- Both functions are recreated verbatim below with ONLY the cast added
-- (respond_booking is still the 0002 definition; note that
-- accept_booking_invite had the same shape in 0002 but migration 011
-- already rewrote it and dropped that notifications insert, so it
-- needs nothing here).
-- ============================================================

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
          (case when p_approve then 'booking_approved'
                else 'booking_declined' end)::notification_t,
          jsonb_build_object('booking_id', p_booking));
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
          (case when p_approve then 'parcel_accepted'
                else 'parcel_declined' end)::notification_t,
          jsonb_build_object('parcel_id', p_parcel));
  -- payment charge is triggered by an Edge Function watching for
  -- status = 'accepted' (keeps Epoint calls out of Postgres).
end $$;
