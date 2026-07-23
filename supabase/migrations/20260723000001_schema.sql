-- ============================================================
-- YOLDA · 001_schema.sql
-- Extensions, enums, tables, indexes, public_profiles view
-- Target: Supabase (Postgres 15+)
-- ============================================================

-- ---------- extensions ----------
create extension if not exists "uuid-ossp";
create extension if not exists pg_cron;          -- for booking-expiry job (002)

-- ---------- enums ----------
create type gender_t            as enum ('male','female','other','unspecified');
create type chattiness_t        as enum ('quiet','depends','chatty');
create type pref3_t             as enum ('yes','no','depends');         -- music/smoking/pets
create type recurrence_t        as enum ('once','weekly');
create type ride_status_t       as enum ('published','full','started','completed','cancelled');
create type booking_status_t    as enum ('pending','awaiting_group','confirmed','declined','cancelled','expired','completed');
create type payment_method_t    as enum ('cash','card','wallet');
create type payment_status_t    as enum ('unpaid','authorized','paid','refunded','failed');
create type invite_via_t        as enum ('link','direct');
create type passenger_status_t  as enum ('pending','confirmed','declined');
create type review_role_t       as enum ('rider','driver');
create type conversation_type_t as enum ('booking','group','parcel');
create type stored_method_t     as enum ('card','m10','birbank','epul','portmanat');
create type txn_type_t          as enum ('charge','refund','payout');
create type txn_status_t        as enum ('pending','settled','failed','reversed');
create type payout_status_t     as enum ('pending','processing','sent','failed');
create type platform_t          as enum ('ios','android');
create type report_reason_t     as enum ('no_show','dangerous_driving','harassment','scam','inappropriate_content','other');
create type report_status_t     as enum ('open','in_review','resolved','dismissed');
create type notification_t      as enum (
  'followed_driver_posted','booking_request','booking_approved','booking_declined',
  'booking_cancelled','group_invite_accepted','message','ride_reminder',
  'review_prompt','ride_cancelled','payout_sent',
  'parcel_request','parcel_accepted','parcel_declined','parcel_delivered'
);
create type parcel_size_t   as enum ('envelope','shoebox','small_bag','suitcase');
create type parcel_status_t as enum ('pending','accepted','declined','in_transit','delivered','cancelled');
create type badge_category_t as enum ('driver','rider','universal');
create type point_reason_t   as enum (
  'ride_completed','review_left','five_star_bonus','referral_completed',
  'group_booking_bonus','parcel_activity','streak_milestone',
  'cancellation_penalty','no_show_penalty','report_penalty'
);

-- ============================================================
-- USERS, TRUST, PREFERENCES
-- ============================================================

-- Mirrors auth.users 1-to-1. Row created by trigger on signup (002).
create table public.users (
  id             uuid primary key references auth.users(id) on delete cascade,
  phone          text unique not null,
  email          text,
  full_name      text not null default '',
  photo_url      text not null default '',
  bio            text,
  gender         gender_t not null default 'unspecified',
  date_of_birth  date,
  created_at     timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  is_deleted     boolean not null default false
);

create table public.user_verifications (
  user_id            uuid primary key references public.users(id) on delete cascade,
  phone_verified_at  timestamptz,
  email_verified_at  timestamptz,
  id_verified_at     timestamptz,
  selfie_verified_at timestamptz,
  id_document_url    text                       -- private bucket path; admin-only
);

create table public.user_preferences (
  user_id      uuid primary key references public.users(id) on delete cascade,
  chattiness   chattiness_t not null default 'depends',
  music        pref3_t      not null default 'depends',
  smoking      pref3_t      not null default 'no',
  pets         pref3_t      not null default 'depends',
  notify_push  boolean      not null default true,
  notify_email boolean      not null default true,
  notify_sms   boolean      not null default false,
  language     text         not null default 'az'
);

create table public.driver_profiles (
  user_id             uuid primary key references public.users(id) on delete cascade,
  license_number      text,
  license_verified_at timestamptz,
  license_url         text,                     -- private bucket path
  rating_avg          numeric(3,2) not null default 0,
  rating_count        int          not null default 0,
  ride_count          int          not null default 0,
  follower_count      int          not null default 0
);

create table public.vehicles (
  id                   uuid primary key default gen_random_uuid(),
  driver_id            uuid not null references public.users(id) on delete cascade,
  make                 text not null,
  model                text not null,
  color                text not null,
  year                 int,
  plate_number         text not null,
  seats                int  not null check (seats between 2 and 8),
  registration_doc_url text,                    -- private bucket path
  verified_at          timestamptz,
  is_active            boolean not null default true
);
create index vehicles_driver_idx on public.vehicles(driver_id);

-- ============================================================
-- ROUTES (templates) & RIDES (instances)
-- ============================================================

create table public.routes (
  id              uuid primary key default gen_random_uuid(),
  driver_id       uuid not null references public.users(id) on delete cascade,
  vehicle_id      uuid not null references public.vehicles(id),
  from_address    text not null,
  from_lat        numeric(9,6) not null,
  from_lng        numeric(9,6) not null,
  to_address      text not null,
  to_lat          numeric(9,6) not null,
  to_lng          numeric(9,6) not null,
  recurrence      recurrence_t not null default 'once',
  recurrence_days int[] not null default '{}',   -- 1=Mon … 7=Sun
  departure_time  time not null,
  price_per_seat  numeric(10,2) not null check (price_per_seat >= 0),
  max_seats       int not null check (max_seats between 1 and 7),
  accepts_cash    boolean not null default true,
  accepts_card    boolean not null default false,
  instant_book    boolean not null default false,
  max_2_in_back   boolean not null default false,
  ladies_only     boolean not null default false,
  is_active       boolean not null default true,
  generated_until date
);
create index routes_driver_idx on public.routes(driver_id) where is_active;

create table public.route_stops (
  id                uuid primary key default gen_random_uuid(),
  route_id          uuid not null references public.routes(id) on delete cascade,
  order_index       int  not null,
  address           text not null,
  lat               numeric(9,6) not null,
  lng               numeric(9,6) not null,
  price_from_origin numeric(10,2),
  unique (route_id, order_index)
);

create table public.rides (
  id                  uuid primary key default gen_random_uuid(),
  route_id            uuid references public.routes(id) on delete set null,
  driver_id           uuid not null references public.users(id) on delete cascade,
  vehicle_id          uuid not null references public.vehicles(id),
  from_address        text not null,
  from_lat            numeric(9,6) not null,
  from_lng            numeric(9,6) not null,
  to_address          text not null,
  to_lat              numeric(9,6) not null,
  to_lng              numeric(9,6) not null,
  departure_at        timestamptz not null,
  arrival_estimate_at timestamptz,
  seats_total         int not null check (seats_total between 1 and 7),
  seats_available     int not null check (seats_available >= 0),
  price_per_seat      numeric(10,2) not null check (price_per_seat >= 0),
  status              ride_status_t not null default 'published',
  polyline            text,
  notes               text,
  accepts_cash        boolean not null default true,
  accepts_card        boolean not null default false,
  instant_book        boolean not null default false,
  ladies_only         boolean not null default false,
  created_at          timestamptz not null default now(),
  accepts_parcels     boolean not null default false,
  parcel_capacity     int not null default 0,       -- 0..3 concurrent parcels
  parcel_price_base   numeric(10,2),                -- driver's starting price; per-parcel price can vary
  constraint seats_le_total check (seats_available <= seats_total),
  constraint one_per_route_slot unique (route_id, departure_at)  -- idempotent generation
);
create index rides_search_idx    on public.rides(departure_at, status);
create index rides_driver_idx    on public.rides(driver_id, departure_at desc);
create index rides_from_geo_idx  on public.rides(from_lat, from_lng);
create index rides_to_geo_idx    on public.rides(to_lat, to_lng);

create table public.ride_stops (
  id                   uuid primary key default gen_random_uuid(),
  ride_id              uuid not null references public.rides(id) on delete cascade,
  order_index          int  not null,
  address              text not null,
  lat                  numeric(9,6) not null,
  lng                  numeric(9,6) not null,
  estimated_arrival_at timestamptz,
  price_from_origin    numeric(10,2),
  unique (ride_id, order_index)
);

-- ============================================================
-- BOOKING & GROUP BOOKING
-- ============================================================

create table public.bookings (
  id                 uuid primary key default gen_random_uuid(),
  ride_id            uuid not null references public.rides(id) on delete cascade,
  lead_passenger_id  uuid not null references public.users(id),
  pickup_stop_id     uuid references public.ride_stops(id),
  dropoff_stop_id    uuid references public.ride_stops(id),
  seat_count         int not null check (seat_count between 1 and 7),
  total_price        numeric(10,2) not null,
  payment_method     payment_method_t not null default 'cash',
  payment_status     payment_status_t not null default 'unpaid',
  status             booking_status_t not null default 'pending',
  driver_approved_at timestamptz,
  expires_at         timestamptz not null,
  created_at         timestamptz not null default now()
);
create index bookings_ride_idx   on public.bookings(ride_id);
create index bookings_lead_idx   on public.bookings(lead_passenger_id, created_at desc);
create index bookings_expiry_idx on public.bookings(expires_at)
  where status in ('pending','awaiting_group');

create table public.booking_passengers (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references public.bookings(id) on delete cascade,
  user_id     uuid references public.users(id),         -- null until invitee accepts
  invited_via invite_via_t not null default 'direct',
  status      passenger_status_t not null default 'pending',
  joined_at   timestamptz
);
create index bp_booking_idx on public.booking_passengers(booking_id);
create index bp_user_idx    on public.booking_passengers(user_id);

create table public.booking_invites (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  token      text unique not null default encode(extensions.gen_random_bytes(16),'hex'),
  created_by uuid not null references public.users(id),
  expires_at timestamptz not null,
  used_by    uuid references public.users(id),
  used_at    timestamptz
);
create index invites_booking_idx on public.booking_invites(booking_id);

-- ============================================================
-- PARCEL DELIVERY
-- Attaches to an existing ride (no solo parcel-only trips in v1).
-- Prepaid only — no rider present to build trust, so cash is
-- not offered here even though it's offered for seat bookings.
-- ============================================================
create table public.parcels (
  id                 uuid primary key default gen_random_uuid(),
  ride_id            uuid not null references public.rides(id),
  sender_id          uuid not null references public.users(id),
  recipient_name     text not null,
  recipient_phone    text not null,          -- recipient may not have the app
  size               parcel_size_t not null,
  weight_kg          numeric(5,2) not null check (weight_kg > 0 and weight_kg <= 20),
  description        text,
  photo_url          text,
  price              numeric(10,2) not null check (price >= 0),
  status             parcel_status_t not null default 'pending',
  payment_status     payment_status_t not null default 'unpaid',
  prohibited_ack     boolean not null default false,
  created_at         timestamptz not null default now(),
  accepted_at        timestamptz,
  delivered_at       timestamptz,
  constraint prohibited_ack_required check (prohibited_ack = true)
);
create index parcels_ride_idx   on public.parcels(ride_id);
create index parcels_sender_idx on public.parcels(sender_id, created_at desc);

-- Prohibited-items list is enforced by UI acknowledgment + ToS,
-- not by content scanning. Standard categories (mirrors BlaBlaCar):
-- cash/valuables, ID documents & passports, perishables, live
-- animals, weapons/ammunition, flammables & hazardous materials,
-- illegal goods, fragile items without proper packaging.

-- ============================================================
-- SOCIAL & REVIEWS
-- ============================================================

create table public.follows (
  follower_id uuid not null references public.users(id) on delete cascade,
  driver_id   uuid not null references public.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, driver_id),
  constraint no_self_follow check (follower_id <> driver_id)
);
create index follows_driver_idx on public.follows(driver_id);

create table public.reviews (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid references public.bookings(id) on delete cascade,
  parcel_id   uuid references public.parcels(id) on delete cascade,
  ride_id     uuid not null references public.rides(id) on delete cascade,
  reviewer_id uuid not null references public.users(id),
  reviewee_id uuid not null references public.users(id),
  role        review_role_t not null,          -- role of the REVIEWER
  rating      int not null check (rating between 1 and 5),
  comment     text,
  created_at  timestamptz not null default now(),
  constraint review_exactly_one_subject check (
    (booking_id is not null and parcel_id is null) or
    (booking_id is null and parcel_id is not null)
  ),
  unique (booking_id, reviewer_id, reviewee_id),
  unique (parcel_id, reviewer_id, reviewee_id)
);
create index reviews_reviewee_idx on public.reviews(reviewee_id, created_at desc);

-- ============================================================
-- MESSAGING
-- ============================================================

create table public.conversations (
  id         uuid primary key default gen_random_uuid(),
  ride_id    uuid not null references public.rides(id) on delete cascade,
  booking_id uuid references public.bookings(id) on delete cascade,
  parcel_id  uuid references public.parcels(id) on delete cascade,
  type       conversation_type_t not null default 'booking',
  created_at timestamptz not null default now()
);
create index conv_booking_idx on public.conversations(booking_id);
create index conv_parcel_idx  on public.conversations(parcel_id);

create table public.conversation_participants (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id         uuid not null references public.users(id) on delete cascade,
  last_read_at    timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
create index cp_user_idx on public.conversation_participants(user_id);

create table public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid references public.users(id),      -- null for system
  body            text not null,
  is_system       boolean not null default false,
  created_at      timestamptz not null default now()
);
create index messages_conv_idx on public.messages(conversation_id, created_at);

-- ============================================================
-- PAYMENTS (provider-agnostic, first provider = 'epoint')
-- ============================================================

create table public.payment_methods (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.users(id) on delete cascade,
  type           stored_method_t not null,
  provider       text not null default 'epoint',
  provider_token text not null,                 -- token only; never store PAN
  last4          text,
  label          text not null default '',
  is_default     boolean not null default false
);
create index pm_user_idx on public.payment_methods(user_id);

create table public.transactions (
  id                uuid primary key default gen_random_uuid(),
  booking_id        uuid references public.bookings(id),
  parcel_id         uuid references public.parcels(id),
  payer_id          uuid not null references public.users(id),
  driver_id         uuid not null references public.users(id),
  payment_method_id uuid references public.payment_methods(id),
  provider          text not null default 'epoint',
  provider_txn_id   text,
  type              txn_type_t not null,
  amount_total      numeric(10,2) not null,
  amount_driver     numeric(10,2) not null,
  amount_platform   numeric(10,2) not null,
  currency          text not null default 'AZN',
  status            txn_status_t not null default 'pending',
  created_at        timestamptz not null default now(),
  settled_at        timestamptz,
  constraint txn_exactly_one_subject check (
    (booking_id is not null and parcel_id is null) or
    (booking_id is null and parcel_id is not null)
  )
);
create index txn_booking_idx on public.transactions(booking_id);
create index txn_parcel_idx  on public.transactions(parcel_id);
create index txn_driver_idx  on public.transactions(driver_id, created_at desc);
create unique index txn_provider_uq on public.transactions(provider, provider_txn_id)
  where provider_txn_id is not null;            -- webhook idempotency

create table public.payouts (
  id                 uuid primary key default gen_random_uuid(),
  driver_id          uuid not null references public.users(id),
  amount             numeric(10,2) not null check (amount > 0),
  currency           text not null default 'AZN',
  provider_payout_id text,
  status             payout_status_t not null default 'pending',
  created_at         timestamptz not null default now()
);
create index payouts_driver_idx on public.payouts(driver_id, created_at desc);

create table public.driver_balances (
  driver_id       uuid primary key references public.users(id) on delete cascade,
  pending         numeric(12,2) not null default 0,
  available       numeric(12,2) not null default 0,
  lifetime_earned numeric(12,2) not null default 0
);

-- ============================================================
-- SYSTEM: notifications, push, safety
-- ============================================================

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  type       notification_t not null,
  data       jsonb not null default '{}',
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index notif_user_idx on public.notifications(user_id, created_at desc);

create table public.device_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.users(id) on delete cascade,
  fcm_token    text not null unique,
  platform     platform_t not null,
  last_seen_at timestamptz not null default now()
);
create index dt_user_idx on public.device_tokens(user_id);

create table public.reports (
  id                  uuid primary key default gen_random_uuid(),
  reporter_id         uuid not null references public.users(id),
  reported_user_id    uuid references public.users(id),
  reported_ride_id    uuid references public.rides(id),
  reported_message_id uuid references public.messages(id),
  reason              report_reason_t not null,
  description         text not null default '',
  status              report_status_t not null default 'open',
  created_at          timestamptz not null default now()
);

create table public.blocks (
  blocker_id uuid not null references public.users(id) on delete cascade,
  blocked_id uuid not null references public.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint no_self_block check (blocker_id <> blocked_id)
);

-- ============================================================
-- GAMIFICATION
-- Catalog-based badges (not a hardcoded enum) so new badges
-- ship as data, not migrations. Points are non-monetary in v1
-- — cosmetic/status only, never redeemable for cash — keeps
-- fraud/finance surface out of the retention system.
-- ============================================================

create table public.badges (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null,           -- 'driver_rookie','rider_explorer_5', etc.
  category    badge_category_t not null,
  name        text not null,
  description text not null,
  icon        text not null default ''
);

create table public.user_badges (
  user_id   uuid not null references public.users(id) on delete cascade,
  badge_id  uuid not null references public.badges(id) on delete cascade,
  earned_at timestamptz not null default now(),
  primary key (user_id, badge_id)
);

create table public.user_points (
  user_id         uuid primary key references public.users(id) on delete cascade,
  balance         int not null default 0,
  lifetime_earned int not null default 0
);

create table public.point_transactions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  delta      int not null,
  reason     point_reason_t not null,
  ref_id     uuid,                            -- ride_id / review_id / referred user_id
  created_at timestamptz not null default now()
);
create index ptxn_user_idx on public.point_transactions(user_id, created_at desc);

-- Driver's per-route streak — "running this route 8 weeks straight".
-- One freeze per rolling 13-week quarter: miss a week, streak
-- survives once; miss twice in the same quarter, it resets.
create table public.route_streaks (
  driver_id      uuid not null references public.users(id) on delete cascade,
  route_id       uuid not null references public.routes(id) on delete cascade,
  current_weeks  int not null default 0,
  longest_weeks  int not null default 0,
  last_ride_at   timestamptz,
  freezes_used   int not null default 0,
  quarter_start  timestamptz not null default now(),
  primary key (driver_id, route_id)
);

-- Rider's commute streak — consecutive weeks with ≥1 completed booking.
create table public.rider_streaks (
  user_id         uuid primary key references public.users(id) on delete cascade,
  current_weeks   int not null default 0,
  longest_weeks   int not null default 0,
  last_booking_at timestamptz,
  freezes_used    int not null default 0,
  quarter_start   timestamptz not null default now()
);

-- ============================================================
-- RANK LADDER — 30 ranks, 7 eras. Data-driven catalog: tuning
-- thresholds is an UPDATE, adding an era is an INSERT, never a
-- migration. Reaching a rank requires BOTH min_months (since a
-- user's first completed ride/booking — hard time gate, cannot
-- be bought) AND min_reps (lifetime reputation, see 002 for how
-- reps are earned/lost). Ranks never downgrade once achieved.
-- ============================================================
create table public.ranks (
  id         uuid primary key default gen_random_uuid(),
  rank_number int unique not null,
  era        text not null,
  name       text not null,
  min_months int not null,
  min_reps   int not null
);

create table public.user_ranks (
  user_id     uuid primary key references public.users(id) on delete cascade,
  rank_id     uuid not null references public.ranks(id),
  achieved_at timestamptz not null default now()
);

insert into public.ranks (rank_number, era, name, min_months, min_reps) values
  (1,  'Garage Days',   'Bumper Kart',           0,  0),
  (2,  'Garage Days',   'Test Driver',           0,  20),
  (3,  'Garage Days',   'Stalled at Green',      1,  50),
  (4,  'Garage Days',   'Learner Plates',        2,  90),
  (5,  'Street Level',  'Street Racer',          2,  150),
  (6,  'Street Level',  'Corner Cutter',         3,  220),
  (7,  'Street Level',  'Drifter',               4,  300),
  (8,  'Street Level',  'Burnout Artist',        6,  400),
  (9,  'Licensed',      'Track Day Regular',     6,  550),
  (10, 'Licensed',      'Late Braker',           8,  720),
  (11, 'Licensed',      'Overtaker',             10, 920),
  (12, 'Licensed',      'Hot Lapper',            12, 1150),
  (13, 'Pro Circuit',   'Pace Setter',           12, 1450),
  (14, 'Pro Circuit',   'Rain Master',           14, 1800),
  (15, 'Pro Circuit',   'Podium Chaser',         16, 2200),
  (16, 'Pro Circuit',   'Front Row Starter',     18, 2650),
  (17, 'Elite Grid',    'Pole Sitter',           18, 3150),
  (18, 'Elite Grid',    'Fastest Lap',           20, 3700),
  (19, 'Elite Grid',    'Race Winner',           22, 4300),
  (20, 'Elite Grid',    'Title Contender',       24, 4950),
  (21, 'Championship',  'Champion',              24, 5650),
  (22, 'Championship',  'Triple Crown',          26, 6400),
  (23, 'Championship',  'Record Holder',         27, 7200),
  (24, 'Championship',  'Hall of Famer',         28, 8050),
  (25, 'Championship',  'Living Legend',         30, 8950),
  (26, 'Immortals',     'Checkered Flag',        30, 9900),
  (27, 'Immortals',     'The Final Boss',        32, 10900),
  (28, 'Immortals',     'The Myth',              34, 11950),
  (29, 'Immortals',     'GOAT',                  35, 13050),
  (30, 'Immortals',     'SameWay One',           36, 14200)
on conflict (rank_number) do nothing;

-- Seed catalog — extend freely without a schema migration.
insert into public.badges (code, category, name, description, icon) values
  ('driver_rookie',        'driver', 'Rookie Driver',   '1st completed ride',                    '🚗'),
  ('driver_regular',       'driver', 'Regular Driver',  '25 completed rides',                     '🚙'),
  ('driver_veteran',       'driver', 'Veteran Driver',  '100 completed rides',                    '🏁'),
  ('driver_road_captain',  'driver', 'Road Captain',    '500 completed rides',                    '⭐'),
  ('driver_rising_star',   'driver', 'Rising Star',     '10 followers',                           '🌱'),
  ('driver_local_favorite','driver', 'Local Favorite',  '50 followers',                           '💛'),
  ('driver_city_icon',     'driver', 'City Icon',       '200 followers',                          '🏙️'),
  ('rider_regular',        'rider',  'Regular',         '3+ completed rides with the same driver','🤝'),
  ('rider_explorer',       'rider',  'Explorer',        '5 different corridors ridden',           '🗺️'),
  ('universal_referrer',   'universal','Connector',     '3 friends completed a ride via your invite','🔗')
on conflict (code) do nothing;

-- users RLS is owner-only (phone/email/DOB are private).
-- Everyone else reads people through this view.
-- security_invoker=false → runs as owner, bypassing users RLS
-- but exposing ONLY safe columns.
-- ============================================================
create view public.public_profiles
with (security_invoker = false) as
select
  u.id,
  u.full_name,
  u.photo_url,
  u.bio,
  u.gender,                                    -- needed for ladies_only checks
  date_part('year', age(u.date_of_birth))::int as age,
  u.created_at,
  (v.phone_verified_at  is not null) as phone_verified,
  (v.id_verified_at     is not null) as id_verified,
  (v.selfie_verified_at is not null) as selfie_verified
from public.users u
left join public.user_verifications v on v.user_id = u.id
where u.is_deleted = false;

-- Comfort preferences view (base table is owner-only; ride
-- participants see chattiness/music/smoking/pets through this).
create view public.public_preferences
with (security_invoker = false) as
select user_id, chattiness, music, smoking, pets
from public.user_preferences;

grant select on public.public_preferences to authenticated;

grant select on public.public_profiles to authenticated, anon;
