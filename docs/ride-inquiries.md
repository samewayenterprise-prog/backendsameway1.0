# Ride inquiries — the pre-booking "Negocjuj" path

## What this is

Found by direct comparison against BlaBlaCar. On a ride's detail
screen, before ever tapping "Book," there's a separate **"Negotiate"**
button. It doesn't open a price field — it opens four templated
questions:

- Different meeting point
- Different drop-off point
- Another special request
- Just want to chat

Pick one, get a pre-filled (editable) message, send it, and you land in
a normal-looking chat thread with the driver — with **no booking
request behind it at all**.

## Why this is a different feature, not a variant of what we have

We already have a "boost your chances" message (screen 45, `create_booking`
flow). The critical difference: **screen 45 fires after a booking
request exists** — you've already committed to requesting a seat, and
the message is trying to improve your odds of approval. "Negocjuj"
fires **before any request exists at all** — it's a way to ask a
question and decide whether to book, not to strengthen a booking
you've already started.

## What we checked before building (and confirmed was a real, total gap)

- `conversations.booking_id` is nullable, so a ride-only thread was
  always structurally *possible* — but:
- The **only** code path that ever inserted a conversation was
  `trg_booking_conversation`, gated on a booking reaching `'confirmed'`.
  Nothing created one earlier.
- `conversation_type_t` had no type for this — only `booking`, `group`,
  `parcel`.
- RLS (`is_conversation_member`) is correctly circular for bootstrapping:
  you can only read/write a conversation you're already a participant
  of, and nothing added a rider as a participant before a booking
  existed. So even a raw table insert wouldn't have been usable by a
  client.

Conclusion: zero partial coverage, a clean gap to fill.

## What we built (migration 0015)

**`start_ride_inquiry(ride_id, template, message)`** — a
`SECURITY DEFINER` RPC, same pattern as `create_booking`: it does the
INSERT into RLS-protected tables itself, so no policy changes were
needed. Existing `conv_select` / `msg_select` / `cp_select` already key
off `conversation_participants` membership — this function just
populates that table correctly.

- **Find-or-reuse, not spawn-a-new-thread-every-tap.** A `(ride_id,
  initiator_id)` partial unique index (`where type = 'inquiry'`) means
  a rider asking a second question on the same ride lands in their
  *same* thread with the driver, not a new one. The insert uses
  `ON CONFLICT ... DO NOTHING` against that index and falls back to a
  `SELECT` for the existing row — atomic, race-safe against a rapid
  double-tap.
- **One thread per (ride, rider) pair, but many riders can each have
  their own thread with the same driver** — verified by hand-tracing
  five scenarios (new inquiry, repeat inquiry same rider, a second
  rider, a driver trying to inquire their own ride, a concurrent
  double-tap) against the SQL before shipping.
- **Blocked**: a driver cannot inquire about their own ride
  (`cannot_inquire_own_ride`).
- **Template is tagged on the message**, not just baked into body text —
  `messages.inquiry_template` (nullable, only set on the first message
  of an inquiry) lets the client show an icon/label without parsing
  text.
- **Existing `messages_scrub` (contact-info filtering) and
  `messages_notify` (push to the driver) triggers fire automatically**
  on this insert exactly as they do for any other message — nothing
  duplicated.

## A known Postgres caveat, documented so it isn't mysterious later

`ALTER TYPE ... ADD VALUE` (adding `'inquiry'` to `conversation_type_t`)
has a real Postgres restriction: a newly added enum value can be used
later in the same transaction, but **not** within the very same command
that adds it. It's placed as the first statement in the migration file
for exactly that reason. If this migration ever fails specifically on
that enum value being "unsafe to use in this transaction," that's the
tell — the fix is splitting it into two migration files, not debugging
the function body.

## Screen implications (not built yet — for whoever builds the UI)

- Ride detail screen needs a **"Negotiate"** button alongside "Book,"
  opening the four-template picker, then a pre-filled editable message
  box (matches the reference exactly).
- The resulting thread should look like a normal chat thread — no new
  UI needed there, just route into the existing messages screen using
  the returned `conversation_id`.
- If a rider later actually books the ride, that creates a **separate**
  `'booking'`-type conversation via the existing trigger — the inquiry
  thread and the booking thread are intentionally different
  conversations. Worth deciding later whether the UI should visually
  link them (e.g. "continued from your question") — not addressed
  here, a product decision.
