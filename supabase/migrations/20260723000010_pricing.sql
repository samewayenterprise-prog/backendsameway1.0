-- ============================================================
-- 010 · PRICING — cost-share ceiling + market guidance
--
-- TWO SEPARATE MECHANISMS, often confused. Both are here because they
-- solve different problems:
--
--   1. COST-SHARE CEILING (hard, legal). A driver must not PROFIT from
--      a ride, or the activity stops being "cost-sharing carpooling"
--      and becomes unlicensed commercial passenger transport. In
--      Azerbaijan there is no carpooling-specific statute, so the only
--      safe harbour is the non-profit framing; anything resembling
--      commercial transport falls under the AYNA taxi permit regime.
--      This is BlaBlaCar's load-bearing legal mechanism, not a UX
--      nicety. Enforced as a hard block in a trigger — a driver
--      CANNOT publish above it.
--
--   2. MARKET GUIDANCE (soft, UX). Compares the driver's price against
--      what other drivers actually charge on the same corridor and
--      returns percentile stats, so the client can render a meter:
--      "your price is above most rides on this route — you'll fill
--      seats slower." Advisory only, never blocks.
--
-- The ceiling protects the company. The meter protects the driver's
-- fill rate. Shipping only the meter would leave the legal exposure
-- wide open, which is why both exist.
--
-- Pricing inputs are configurable globally and overridable per country
-- (fuel prices differ enormously across markets), so opening a new
-- market means setting its parameters, not editing this function.
-- ============================================================

-- ------------------------------------------------------------
-- A · distance helper (haversine, no PostGIS dependency)
-- ------------------------------------------------------------
create or replace function public.haversine_km(
  lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric
) returns numeric
language sql immutable as $$
  select round(
    (6371 * 2 * asin(sqrt(
      power(sin(radians(lat2 - lat1) / 2), 2) +
      cos(radians(lat1)) * cos(radians(lat2)) *
      power(sin(radians(lng2 - lng1) / 2), 2)
    )))::numeric, 2)
$$;

comment on function public.haversine_km is
  'Great-circle distance in km. Straight-line, so it UNDERSTATES real road distance — deliberately conservative for a price ceiling (a tighter ceiling is the safe direction to err). Replace with the Directions API road distance stored on the route when that is wired.';

-- ------------------------------------------------------------
-- B · pricing parameters
-- Global defaults on platform_settings; per-country overrides on
-- countries (nullable — null means "use the global default").
-- ------------------------------------------------------------
alter table public.platform_settings
  add column if not exists fuel_price_per_litre numeric(10,3) not null default 1.200,
  add column if not exists fuel_consumption_l_100km numeric(5,2) not null default 8.00,
  add column if not exists vehicle_wear_per_km numeric(10,3) not null default 0.080,
  add column if not exists road_distance_factor numeric(4,2) not null default 1.30
    check (road_distance_factor >= 1.00 and road_distance_factor <= 2.00),
  add column if not exists base_trip_cost_azn numeric(10,2) not null default 3.00,
  add column if not exists price_ceiling_multiplier numeric(4,2) not null default 1.25
    check (price_ceiling_multiplier >= 1.00 and price_ceiling_multiplier <= 2.00);

comment on column public.platform_settings.price_ceiling_multiplier is
  'Headroom above bare computed cost, for route/vehicle variance (tolls, older cars, detours). 1.00 = strict cost only. Above ~1.5 the non-profit argument weakens — do not raise without legal advice.';

comment on column public.platform_settings.road_distance_factor is
  'Straight-line distance understates road distance (Baku–Ganja: 298 km vs ~375 km real, ~26%). Without this correction the ceiling blocks legitimate prices. Drop to 1.00 once real road distance from the Directions API is stored on the route.';

comment on column public.platform_settings.base_trip_cost_azn is
  'Fixed cost of making a trip at all — vehicle prep, waiting, parking, the driver''s time getting to the pickup. Not distance-proportional, which is why pure per-km maths gives absurd ceilings on short hops. Modelled as a real cost rather than a post-hoc floor, so the no-profit invariant still holds by construction at every seat count.';

alter table public.countries
  add column if not exists fuel_price_per_litre numeric(10,3),
  add column if not exists fuel_consumption_l_100km numeric(5,2),
  add column if not exists vehicle_wear_per_km numeric(10,3),
  add column if not exists road_distance_factor numeric(4,2),
  add column if not exists base_trip_cost_azn numeric(10,2),
  add column if not exists price_ceiling_multiplier numeric(4,2);

-- Azerbaijan launch parameters (AI-95 ≈ 1.20 ₼/L at time of writing).
-- Verified against real coordinates and the design's own reference fare:
--   Baku–Ganja, straight-line 298 km × 1.30 road factor = 387 km
--   fuel 387 × 0.08 × 1.20 = 37.15 ₼
--   wear 387 × 0.080       = 30.96 ₼
--   trip cost              = 68.11 ₼
--   3 seats: ÷4 × 1.25     = 21.28 ₼ ceiling   (15 ₼ mock passes)
--   4 seats: ÷5 × 1.25     = 17.03 ₼ ceiling   (15 ₼ mock passes)
--   a 40 ₼ "taxi" fare is rejected at every seat count
--   Baku–Sumqayit 26 km: distance maths → 1.9 ₼, floored to 3.00 ₼
update public.countries
   set fuel_price_per_litre     = 1.200,
       fuel_consumption_l_100km = 8.00,
       vehicle_wear_per_km      = 0.080,
       road_distance_factor     = 1.30,
       base_trip_cost_azn       = 3.00,
       price_ceiling_multiplier = 1.25
 where iso2 = 'AZ';

-- ------------------------------------------------------------
-- C · the ceiling
-- Per-seat maximum such that a full car still does not profit the
-- driver: total trip cost is divided across seats + 1 (the driver
-- occupies one seat and bears that share personally).
-- ------------------------------------------------------------
create or replace function public.cost_share_ceiling(
  p_distance_km numeric,
  p_seats       int,
  p_iso2        char(2) default 'AZ'
) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  v_fuel_price numeric; v_consumption numeric;
  v_wear numeric; v_mult numeric;
  v_road_factor numeric; v_base numeric;
  v_road_km numeric; v_trip_cost numeric; v_ceiling numeric;
begin
  if p_distance_km is null or p_distance_km <= 0 or p_seats is null or p_seats < 1 then
    return null;                                   -- unknown → no ceiling enforced
  end if;

  select coalesce(c.fuel_price_per_litre,     s.fuel_price_per_litre),
         coalesce(c.fuel_consumption_l_100km, s.fuel_consumption_l_100km),
         coalesce(c.vehicle_wear_per_km,      s.vehicle_wear_per_km),
         coalesce(c.price_ceiling_multiplier, s.price_ceiling_multiplier),
         coalesce(c.road_distance_factor,     s.road_distance_factor),
         coalesce(c.base_trip_cost_azn,       s.base_trip_cost_azn)
    into v_fuel_price, v_consumption, v_wear, v_mult, v_road_factor, v_base
    from platform_settings s
    left join countries c on c.iso2 = p_iso2
   where s.id = 1;

  if v_fuel_price is null then return null; end if;

  -- Correct straight-line to approximate road distance.
  v_road_km := p_distance_km * v_road_factor;

  -- Fixed component + distance components. Including the fixed cost
  -- is what makes short trips come out sane without a floor hack.
  v_trip_cost := coalesce(v_base, 0)
               + (v_road_km * (v_consumption / 100.0) * v_fuel_price)
               + (v_road_km * v_wear);

  -- Two bounds, take the lower:
  --   a) cost split across occupants (driver included), plus headroom
  --   b) HARD INVARIANT: total collected from passengers must never
  --      exceed the trip's cost, i.e. per-seat ≤ trip_cost / seats.
  --
  -- Bound (b) is not redundant. With the multiplier, (a) alone starts
  -- permitting profit once seats > 4 — collected = trip × N × mult/(N+1),
  -- which exceeds trip cost when mult·N > N+1. At the 8 seats this
  -- schema allows, a van could have charged well above cost. That is
  -- the precise thing that turns cost-sharing into unlicensed commercial
  -- transport, so it is clamped explicitly rather than left to the
  -- multiplier's arithmetic.
  v_ceiling := least(
    (v_trip_cost / (p_seats + 1)) * v_mult,
    v_trip_cost / p_seats
  );

  -- Truncate rather than round to 2dp: rounding UP can push
  -- seats × ceiling a few qapik past trip cost, which technically
  -- breaks the no-profit invariant. Always round the driver's
  -- ceiling down.
  return (floor(v_ceiling * 100) / 100)::numeric(10,2);
end $$;

-- ------------------------------------------------------------
-- D · market guidance — powers the price meter
-- Compares against other drivers' published prices on a comparable
-- corridor. "Comparable" = both endpoints within p_radius_km.
-- ------------------------------------------------------------
create or replace function public.ride_price_guidance(
  p_from_lat numeric, p_from_lng numeric,
  p_to_lat   numeric, p_to_lng   numeric,
  p_seats    int,
  p_price    numeric default null,
  p_iso2     char(2) default 'AZ',
  p_radius_km numeric default 25
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_distance numeric;
  v_ceiling  numeric;
  v_median numeric; v_p25 numeric; v_p75 numeric; v_n int;
  v_sug_min numeric; v_sug_max numeric;
  v_position text;
begin
  v_distance := haversine_km(p_from_lat, p_from_lng, p_to_lat, p_to_lng);
  v_ceiling  := cost_share_ceiling(v_distance, p_seats, p_iso2);

  -- Comparable rides: same corridor, still upcoming, recently listed.
  -- Full scan over a bounded set at launch volume; revisit with a
  -- geo index (earthdistance/PostGIS) once ride counts grow.
  select count(*),
         percentile_cont(0.25) within group (order by r.price_per_seat),
         percentile_cont(0.50) within group (order by r.price_per_seat),
         percentile_cont(0.75) within group (order by r.price_per_seat)
    into v_n, v_p25, v_median, v_p75
    from rides r
   where r.status = 'published'
     and r.departure_at > now()
     and r.created_at > now() - interval '60 days'
     and haversine_km(r.from_lat, r.from_lng, p_from_lat, p_from_lng) <= p_radius_km
     and haversine_km(r.to_lat,   r.to_lng,   p_to_lat,   p_to_lng)   <= p_radius_km;

  -- Suggested band: the middle of the market, never above the ceiling.
  -- With too few comparables, fall back to a band under the ceiling so
  -- the very first drivers on a corridor still get useful guidance.
  if v_n >= 5 then
    v_sug_min := least(v_p25, coalesce(v_ceiling, v_p25));
    v_sug_max := least(v_p75, coalesce(v_ceiling, v_p75));
  else
    v_sug_min := round(coalesce(v_ceiling, 0) * 0.60, 2);
    v_sug_max := round(coalesce(v_ceiling, 0) * 0.85, 2);
  end if;

  if p_price is null then
    v_position := null;
  elsif v_ceiling is not null and p_price > v_ceiling then
    v_position := 'over_ceiling';                  -- will be REJECTED on publish
  elsif p_price > coalesce(v_sug_max, p_price) then
    v_position := 'above';                         -- allowed, fills slower
  elsif p_price < coalesce(v_sug_min, p_price) then
    v_position := 'below';                         -- cheap; fills fast
  else
    v_position := 'competitive';
  end if;

  return jsonb_build_object(
    'distance_km',     v_distance,
    'ceiling',         v_ceiling,
    'suggested_min',   v_sug_min,
    'suggested_max',   v_sug_max,
    'market_median',   v_median,
    'market_p25',      v_p25,
    'market_p75',      v_p75,
    'sample_size',     v_n,
    'your_price',      p_price,
    'position',        v_position
  );
end $$;

grant execute on function public.ride_price_guidance(
  numeric, numeric, numeric, numeric, int, numeric, char, numeric
) to authenticated;

comment on function public.ride_price_guidance is
  'Advisory pricing data for the publish screen price meter. Returns the hard ceiling plus corridor percentiles so the client can show where the driver sits against the market. Never blocks — enforcement is trg_enforce_price_ceiling.';

-- ------------------------------------------------------------
-- E · enforcement — the hard block
-- ------------------------------------------------------------
create or replace function public.trg_enforce_price_ceiling()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_seats int;
  v_distance numeric;
  v_ceiling numeric;
begin
  v_seats := coalesce(
    case when tg_table_name = 'routes' then new.max_seats else new.seats_total end, 0);

  v_distance := haversine_km(new.from_lat, new.from_lng, new.to_lat, new.to_lng);
  v_ceiling  := cost_share_ceiling(v_distance, v_seats, 'AZ');

  if v_ceiling is not null and new.price_per_seat > v_ceiling then
    raise exception
      'price_above_cost_share_ceiling: % exceeds the maximum of % AZN per seat for a % km trip with % seats. SameWay is a cost-sharing platform — drivers share travel costs, they do not profit from rides.',
      new.price_per_seat, v_ceiling, v_distance, v_seats
      using errcode = 'check_violation';
  end if;

  return new;
end $$;

create trigger routes_price_ceiling
  before insert or update of price_per_seat, max_seats on public.routes
  for each row execute function public.trg_enforce_price_ceiling();

create trigger rides_price_ceiling
  before insert or update of price_per_seat, seats_total on public.rides
  for each row execute function public.trg_enforce_price_ceiling();

-- Note: the nightly generator copies price_per_seat from an already
-- validated route, so generated rides pass by construction. If a
-- country's parameters are later tightened below an existing route's
-- price, the NEXT generation run for that route will fail loudly
-- rather than silently publishing an illegal price — intended.
