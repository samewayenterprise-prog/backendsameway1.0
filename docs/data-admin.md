# Table admin — the Django-admin equivalent

## What this is

Every hand-built page in this panel (Dashboard, KYC, Reports, Markets,
Ops, Settings) covers a workflow we specifically designed for. But the
schema has 37 tables, and only a handful ever got a bespoke page —
everything else (vehicles, routes, ranks, badges, streaks, device
tokens, ...) had **zero admin visibility**.

This is the fix: mounted at **`/data`**, it auto-generates list / show
/ edit / new / delete screens for every table by introspecting the
real Postgres schema directly — no manual page per table, the same
category of tool as Django's admin (built on **AdminJS**, since we're
not on Django).

## The safety model — read this before adding a new table

A blanket "expose every table with full CRUD" would let someone
directly edit `driver_profiles.rating_avg`, or a `transactions` row, or
a `payout`, bypassing every integrity rule built earlier today: the
no-profit price ceiling, the trigger-owned counters, the RLS/privilege
locks, the ledger-only-via-service-role design. So every table is
triaged into one of three tiers in `admin/data-admin.js`:

| Tier | Meaning | Applies to |
|---|---|---|
| **FULL** | Safe to edit directly | Reference/config data, or things ops genuinely needs to fix (a typo'd plate, a stuck device token). Triggers still fire on any write through here exactly as they do from the app — the price-ceiling trigger still protects `rides`/`routes` even through this tool, which is a real safety property of going through Postgres triggers rather than an ORM. |
| **READ-ONLY** | List + show only, new/edit/delete disabled | Anything that's an RPC-only state machine (`bookings`), a financial ledger (`transactions`, `payouts`, `driver_balances`), or trigger-derived (`route_streaks`, `user_ranks`, `point_transactions`) — direct edits there skip the release-seats/ledger logic the RPCs run, so the write would "succeed" while corrupting state. |
| **HIDDEN** | Not registered at all | Just `user_verifications` — it holds a private document storage path, and the existing KYC page already handles it correctly with signed URLs and an actual review step. Exposing the raw table here would be a shortcut around actually looking at someone's ID before approving them. |

**New tables added later must be triaged into one of these three before
being added to `data-admin.js` — don't default to FULL for something
touched by a trigger or an RPC without checking first.**

Individual columns can also be locked on an otherwise-FULL resource —
`driver_profiles.rating_avg/rating_count/ride_count/follower_count` are
visible but not editable, mirroring the column-level privilege locks
already enforced in RLS.

## A real bug this had to work around — three parts, same root cause

`@adminjs/sql` (v2.2.6) has a genuine bug, not a quirk of local testing:
**every real Supabase project has both `auth.users` and `public.users`**,
and the library's introspection queries for the `users` table specifically
assume table names are unique across the whole database — they never
qualify by schema. Three separate places in the same file break because
of this one assumption:

**1. Foreign-key detection** finds the table by bare name:
```diff
- where c.conrelid = (select oid from pg_class where relname = '${table}')
+ where c.conrelid = (select c2.oid from pg_class c2 join pg_namespace n2
+   on n2.oid = c2.relnamespace where c2.relname = '${table}' and n2.nspname = '${schemaName}')
```
Without this, the subquery matches both schemas' `users` tables at once
and Postgres throws "more than one row returned by a subquery" —
`users` gets silently dropped from the introspected resource list, no
error surfaced to the app.

**2. Primary-key detection** joins `information_schema.key_column_usage`
on table name only, missing schema:
```diff
  .leftJoin('information_schema.key_column_usage as kcu', (c) => c
    .on('kcu.column_name', 'col.column_name')
-   .on('kcu.table_name', 'col.table_name'))
+   .on('kcu.table_name', 'col.table_name')
+   .on('kcu.table_schema', 'col.table_schema'))
```
Same root cause, different query — this one doesn't error, it silently
duplicates rows (once per schema match) instead.

**3. Those duplicated rows collide with a second, independent problem**:
`public.users.id` is legitimately *both* the primary key *and* a foreign
key (referencing `auth.users(id)`) — completely standard Supabase
practice. `information_schema.key_column_usage` correctly returns one
row per constraint a column participates in, so even with fix #2 applied,
`id` still produces two rows (one for the PK constraint, one for the FK
constraint), and whichever arrives second silently overwrites the first
in the resource's property map. If that's the non-PK row, primary-key
detection breaks entirely (`idColumn` resolves to `undefined`, and the
whole resource becomes unusable — AdminJS refuses to build a resource
with no detected primary key). Fixed by deduplicating in JS, preferring
whichever row is actually flagged `PRIMARY KEY` when a column has more
than one:
```diff
- const columns = await query;
+ const rawColumns = await query;
+ const byColumn = new Map();
+ for (const col of rawColumns) {
+   const existing = byColumn.get(col.column_name);
+   if (!existing || col.key_type === 'PRIMARY KEY') {
+     byColumn.set(col.column_name, col);
+   }
+ }
+ const columns = Array.from(byColumn.values());
```

All three needed fixing together — stopping after #1 alone left `users`
appearing in the table list but with its primary key undetected, which
would have surfaced later as a broken resource rather than a clean error.

**The fix**: patched via [`patch-package`](https://github.com/ds300/patch-package)
(a standard tool for exactly this — pinning a fix to a third-party bug
without forking or waiting on upstream). Lives at
`admin/patches/@adminjs+sql+2.2.6.patch`, applied automatically by the
`postinstall` script in `package.json` — every `npm install` reapplies
it, including the VPS's first install. **Verified this specifically**:
ran a clean `rm -rf node_modules && npm install` and confirmed all three
patched sections were back in place before trusting it, then re-ran the
full end-to-end HTTP test (real login, real session, real `users` query
returning correct data) against that freshly-reinstalled copy.

A workaround was considered and rejected: registering a
`public.users_admin` view instead of the real table would dodge the
name collision, but views have no primary-key constraint at all, so
that would trade the schema-collision bug for a guaranteed "no primary
key detected" failure on every single row — strictly worse. It would
also break every other table's auto-linked "click to view this
passenger" relation, since AdminJS matches relations by table name and
the real FK still points at `users`, not `users_admin`. Patching the
actual bug was the more correct fix, not a workaround with a worse
trade-off.

## Login

Same single-operator password model as the rest of the panel — reuses
`ADMIN_PASSWORD` and `SESSION_SECRET`, no separate user table. A fixed
identity (`admin@sameway.internal`) is returned on successful auth.
Session store is in-memory: a panel restart logs everyone out, which is
an acceptable trade-off for a low-traffic internal tool rather than
adding a session-store dependency for it. Revisit if this becomes a
multi-person-login tool later.

## Setup

Needs one more environment variable beyond what the rest of the panel
uses: **`SUPABASE_DB_URL`** — a direct Postgres connection string
(different from the `SUPABASE_URL`/`SUPABASE_SECRET_KEY` REST-API
credentials already in use elsewhere). Find it in Supabase Dashboard →
Project Settings → Database → Connection string. Add it to
`/etc/sameway-admin.env` on the VPS, same as every other secret.

Without `SUPABASE_DB_URL` set, `mountDataAdmin()` logs a warning and
skips mounting entirely — the rest of the panel still works normally,
it just won't have the `/data` tab functional.

## Verified before shipping

- Clean `rm -rf node_modules && npm install` from scratch → all three
  patch sections auto-apply → confirmed by grepping the freshly
  installed file for each patched section.
- Full local Postgres instance loaded with all 16 real migrations
  (with a hand-built stand-in for Supabase's `auth`/`storage`/`cron`
  schemas and roles, since this sandbox has no live Supabase project)
  — 37 tables came back correctly, `users` included.
- Confirmed `users`'s primary key resolves correctly
  (`idProperty.path() === 'id'`) despite `id` being both a primary key
  and a foreign key on the same column — the scenario that broke
  without fix #3.
- Confirmed a table with a genuine foreign key to `users` (`vehicles.
  driver_id`) still correctly resolves `referenced_table: "users"` —
  the schema-qualification fix didn't accidentally break real FK
  detection for tables that aren't named `users`.
- Logged in via the real login form (real HTTP POST, not a mocked
  session), followed the returned session cookie, and fetched real
  resource data through the actual JSON API
  (`/data/api/resources/users/actions/list` — not just the bare
  `/data/users` path, which turns out to serve the same SPA shell
  regardless of whether the resource is valid, a false-positive trap
  worth knowing about if testing this further). Response contained the
  correct paginated metadata and the actual seeded test row.
- Confirmed `user_verifications` is genuinely unreachable via the API,
  and confirmed `transactions`'s `new` action is genuinely forbidden —
  AdminJS reports action-level access errors via the JSON response
  body (`baseError.type: "ForbiddenError"`), not via HTTP status code,
  which is worth knowing if debugging this further.
- Booted the actual, complete `server.js` (not an isolated test file)
  and confirmed both the pre-existing bespoke pages and the new `/data`
  mount respond correctly side by side on the same running process.
