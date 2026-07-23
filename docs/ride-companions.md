# Ride companions — "who else is on this ride"

## What this is

On a BlaBlaCar ride detail screen — including a **past, already-completed**
ride — there's an "Other passengers" section. Tap it and you see everyone
else confirmed on that ride, grouped by their booking, e.g. "Oliwia (+1)"
meaning Oliwia and one companion booked separately from you. Tap her name
and you land on her full public profile, with rate/report/message all
still available. None of this has a time limit — it worked identically
on a ride from weeks earlier.

We didn't have this. Our `booking_passengers` RLS policy
(`bp_select_member`) correctly scopes visibility to **your own booking
group only** — which is right for the passenger-management data itself
(invite tokens, pending slots, etc.), but it meant there was no way to
see *other* groups riding the same car. This closes that gap.

## Why it matters

This is one of the more obvious trust signals in the whole product —
"who am I riding with" is something every rider and driver actually
wants to know, and hiding it because our booking model happens to be
group-based was an accidental gap, not a deliberate design choice.

## What we built

**`ride_companions(p_ride_id uuid)`** — a function, not a relaxed table
policy. Reasoning: `booking_passengers` carries invite-flow plumbing
(pending slots, invite tokens) we don't want broadly exposed just to
solve a much narrower need. The function returns only the safe summary:

```sql
select * from ride_companions('<ride-id>');
```

```
booking_id | lead_user_id | lead_name | lead_photo_url | companion_count
-----------+--------------+-----------+----------------+-----------------
 ...       | ...          | Oliwia    | https://...    | 1
 ...       | ...          | Bystander | https://...    | 0
```

- **Grouped by lead passenger**, with a companion count — matches the
  "Oliwia (+1)" pattern exactly rather than a flat list of every
  individual name.
- **Excludes the caller's own booking** — the real screen is titled
  "Other passengers," so that filtering happens once here instead of
  the client re-doing it every time.
- **No time cutoff.** Works on a ride from a year ago exactly the same
  as one from yesterday, matching observed BlaBlaCar behaviour. There
  was never a design reason for a cutoff — it just hadn't been asked
  for before now.
- **Gated on the caller having actually ridden.** You must be a
  confirmed passenger (or the driver) of that specific ride yourself,
  or you get an empty list — not an error, just nothing. This isn't a
  general "look up anyone's ride roster" tool.

## What did NOT need to change

Checked before building, so nothing got duplicated:

- **Messaging** — conversations are already **per-booking**, not
  per-ride (confirmed by reading `trg_booking_conversation`). Your
  chat thread with the driver and Oliwia's chat thread with the driver
  are already separate. That matches what was observed (you can
  message the driver from an old ride; nothing suggested a shared
  group thread with Oliwia) — no change needed here.
- **Reviews** — `reviews_insert` already has no time cutoff, only
  requires the booking to be `completed` and the reviewer to have been
  a member of it. Rating an old ride already worked before this
  migration.
- **Reporting** — `reports_insert` only checks `reporter_id = auth.uid()`;
  it takes any `reported_user_id`. Reporting someone you saw via
  `ride_companions` needs zero schema change — the report table was
  never scoped to "people in your own booking" in the first place.

## Screen implications (not built yet — noting for whoever builds the UI)

- Ride detail screen (S-10 in the screen map) needs an "Other
  passengers" row/link, shown whenever `ride_companions()` returns at
  least one row — including on past-ride views, not just upcoming ones.
- Tapping a companion name should route to their public profile
  (already exists as a screen) using `lead_user_id` — no new profile
  screen needed, just a new entry point into the existing one.
- The companion count badge ("+1") reads directly off the
  `companion_count` column — no extra query needed per row.
