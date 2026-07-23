-- ============================================================
-- 015 · RIDE INQUIRIES — pre-booking "Negocjuj" path
--
-- Found by direct comparison against BlaBlaCar: before ever tapping
-- "Book," there's a separate "Negotiate" button that opens four
-- templated questions (different meeting point / different drop-off /
-- another special request / just want to chat), leading to a message
-- thread with the driver. This is NOT the same thing as our existing
-- "boost your chances" message (screen 45) — that one fires AFTER a
-- booking request already exists. This is earlier: no booking, no
-- request, just a question.
--
-- Checked before building: our conversations table already has
-- nullable booking_id (so a ride-only thread is structurally
-- possible), but nothing ever created one pre-booking — the only
-- insert path is trg_booking_conversation, gated on a booking reaching
-- 'confirmed'. That's a real, complete gap, not a partial one.
-- ============================================================

-- Enum values must be added as their own statement before use
-- elsewhere in this file (Postgres allows using a new enum value
-- later in the same transaction, but not within the same command that
-- adds it) — kept as the very first statement here for exactly that
-- reason. If this migration ever errors specifically on the enum
-- value being "unsafe to use," that's the tell — split this into two
-- migration files rather than debugging the function body.
alter type public.conversation_type_t add value if not exists 'inquiry';

create type public.inquiry_template_t as enum (
  'meeting_point',      -- "Inny punkt spotkania"
  'dropoff_point',       -- "Inne miejsce podwiezienia"
  'special_request',     -- "Mam kolejną prośbę specjalną"
  'just_chat'             -- "Chcę tylko pogadać"
);

-- Which rider started this thread — lets us find-or-reuse a rider's
-- existing inquiry on a ride instead of spawning a new one every time
-- they tap the button again. Nullable: only meaningful for inquiry
-- conversations, existing booking/group/parcel conversations are
-- unaffected.
alter table public.conversations
  add column if not exists initiator_id uuid references public.users(id);

-- One inquiry thread per (ride, rider) — enforced atomically via
-- ON CONFLICT below, not just application-level checking.
create unique index if not exists conv_ride_initiator_inquiry_uq
  on public.conversations(ride_id, initiator_id)
  where type = 'inquiry';

-- Tags the first message of an inquiry with which template prompted
-- it, so the client can render an icon/label without parsing body
-- text. Null on every other message (regular chat, system messages).
alter table public.messages
  add column if not exists inquiry_template inquiry_template_t;

create or replace function public.start_ride_inquiry(
  p_ride_id  uuid,
  p_template inquiry_template_t,
  p_message  text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_driver uuid;
  v_conv   uuid;
  v_body   text;
begin
  select driver_id into v_driver from rides where id = p_ride_id;
  if v_driver is null then raise exception 'ride_not_found'; end if;
  if v_driver = auth.uid() then raise exception 'cannot_inquire_own_ride'; end if;

  -- Atomic find-or-create: the partial unique index is the conflict
  -- target, so a double-tap or a retry can never create two threads
  -- for the same rider on the same ride.
  insert into conversations (ride_id, type, initiator_id)
  values (p_ride_id, 'inquiry', auth.uid())
  on conflict (ride_id, initiator_id) where type = 'inquiry'
  do nothing
  returning id into v_conv;

  if v_conv is null then
    select id into v_conv from conversations
    where ride_id = p_ride_id and type = 'inquiry' and initiator_id = auth.uid();

    insert into conversation_participants (conversation_id, user_id)
    values (v_conv, auth.uid())
    on conflict do nothing;
  else
    insert into conversation_participants (conversation_id, user_id)
    values (v_conv, auth.uid()), (v_conv, v_driver)
    on conflict do nothing;
  end if;

  -- Sensible default per template if the rider sends the prompt as-is
  -- without editing it (the reference screen shows an editable,
  -- pre-filled box, not a mandatory free-text field).
  v_body := coalesce(nullif(trim(p_message), ''),
    case p_template
      when 'meeting_point'   then 'Could we use a different meeting point?'
      when 'dropoff_point'   then 'Could we use a different drop-off point?'
      when 'special_request' then 'I have a special request about this ride.'
      when 'just_chat'       then 'Hi! I had a question before booking.'
    end);

  -- Existing messages_scrub (contact-info filtering) and
  -- messages_notify (push to other participants) triggers fire on
  -- this insert exactly as they do for any other message — no
  -- duplicate logic needed here.
  insert into messages (conversation_id, sender_id, body, inquiry_template)
  values (v_conv, auth.uid(), v_body, p_template);

  return v_conv;
end $$;

grant execute on function public.start_ride_inquiry(uuid, inquiry_template_t, text) to authenticated;

comment on function public.start_ride_inquiry is
  'Pre-booking inquiry — the "Negocjuj" path. Distinct from the
   post-request message on screen 45. Creates (or reuses) a
   ride-scoped conversation between the caller and the ride''s driver,
   with no booking required to exist. RLS needs no changes: existing
   conv_select/msg_select/cp_select policies key off
   conversation_participants membership, which this function populates
   directly via SECURITY DEFINER — the same pattern create_booking uses
   for its own RLS-protected inserts.';

-- No RLS policy changes: is_conversation_member() already grants read
-- access to anyone in conversation_participants, and this function is
-- the only writer for 'inquiry'-type conversations, so existing
-- conv_select / msg_select / cp_select policies are sufficient as-is.
