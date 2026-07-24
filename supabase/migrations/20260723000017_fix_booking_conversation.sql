-- ============================================================
-- 017 · FIX booking → conversation auto-create
--
-- Two real bugs, both found by driving the booking flow end-to-end
-- against a local replica while building the web messaging UI. Both
-- were latent only because no real booking had been completed yet.
--
-- BUG 1 — the trigger body never ran successfully at all.
--   insert into conversations (ride_id, booking_id, type)
--   values (..., case when new.seat_count > 1 then 'group'
--                     else 'booking' end)
-- The CASE yields `text`, the column is `conversation_type_t`, and
-- Postgres will not implicitly cast text → enum in an INSERT value
-- list. So the statement raised:
--   column "type" is of type conversation_type_t but expression is
--   of type text
-- Because this trigger fires on the same UPDATE that respond_booking
-- performs, the exception propagated and **the entire approval RPC
-- failed**. A driver could not approve a booking at all.
-- (Same class of bug as the to_jsonb(new) fix in migration 014 —
-- worth remembering that PL/pgSQL is strict about enum casts.)
--
-- BUG 2 — the trigger only fired on UPDATE.
-- create_booking() writes instant-book bookings straight to
-- status='confirmed' in the INSERT; no UPDATE ever happens for that
-- path. So even with bug 1 fixed, instant-book riders would silently
-- get no conversation and no way to message their driver — the more
-- common path, since instant book is the option we actively promote.
--
-- Fix: cast the enum explicitly, fire on INSERT OR UPDATE, decide
-- per-operation (TG_OP) rather than relying on OLD being readable in
-- an INSERT trigger, make it idempotent, and include the lead
-- passenger explicitly so a solo booking still produces a two-person
-- conversation even if no booking_passengers row exists.
-- ============================================================

create or replace function public.trg_booking_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_conv   uuid;
  v_should boolean;
begin
  -- Decide explicitly per operation. OLD is not assigned during an
  -- INSERT trigger, so it must never be referenced on that path.
  if tg_op = 'INSERT' then
    v_should := (new.status = 'confirmed');
  else
    v_should := (new.status = 'confirmed'
                 and old.status is distinct from 'confirmed');
  end if;

  if not v_should then
    return new;
  end if;

  -- Idempotent: never a second conversation for the same booking,
  -- whichever path (or replay) gets here.
  if exists (select 1 from conversations where booking_id = new.id) then
    return new;
  end if;

  insert into conversations (ride_id, booking_id, type)
  values (
    new.ride_id,
    new.id,
    (case when new.seat_count > 1 then 'group' else 'booking' end)::conversation_type_t
  )
  returning id into v_conv;

  -- Driver + lead passenger + any additional group passengers.
  -- The lead is listed explicitly: create_booking does not necessarily
  -- write a booking_passengers row for a solo booking, and without
  -- this the rider would be missing from their own conversation.
  insert into conversation_participants (conversation_id, user_id)
  select v_conv, r.driver_id
    from rides r
   where r.id = new.ride_id
  union
  select v_conv, new.lead_passenger_id
  union
  select v_conv, bp.user_id
    from booking_passengers bp
   where bp.booking_id = new.id
     and bp.user_id is not null
  on conflict do nothing;

  return new;
end $$;

drop trigger if exists bookings_conversation on public.bookings;

create trigger bookings_conversation
  after insert or update on public.bookings
  for each row execute function public.trg_booking_conversation();

-- ------------------------------------------------------------
-- Backfill: any booking that reached 'confirmed' before this fix
-- has no conversation. Create one for each so existing riders and
-- drivers can actually talk. Safe to re-run.
-- ------------------------------------------------------------
do $$
declare b record; v_conv uuid;
begin
  for b in
    select bk.id, bk.ride_id, bk.lead_passenger_id, bk.seat_count
      from bookings bk
     where bk.status in ('confirmed','completed')
       and not exists (select 1 from conversations c where c.booking_id = bk.id)
  loop
    insert into conversations (ride_id, booking_id, type)
    values (b.ride_id, b.id,
            (case when b.seat_count > 1 then 'group' else 'booking' end)::conversation_type_t)
    returning id into v_conv;

    insert into conversation_participants (conversation_id, user_id)
    select v_conv, r.driver_id from rides r where r.id = b.ride_id
    union
    select v_conv, b.lead_passenger_id
    union
    select v_conv, bp.user_id from booking_passengers bp
     where bp.booking_id = b.id and bp.user_id is not null
    on conflict do nothing;
  end loop;
end $$;
