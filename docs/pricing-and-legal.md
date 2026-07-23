# Pricing, the cost-share ceiling, and the legal posture

## Why there are two price mechanisms

They are constantly confused, so: they solve different problems and you
need both.

| | Cost-share ceiling | Market guidance ("the meter") |
|---|---|---|
| Purpose | Keeps SameWay legally a **carpooling** platform, not an unlicensed taxi service | Helps a driver actually fill their seats |
| Behaviour | **Hard block** — publish is rejected above it | **Advisory** — never blocks |
| Derived from | Fuel + wear ÷ occupants, per market | What other drivers charge on the same corridor |
| Where | `trg_enforce_price_ceiling` on `routes` and `rides` | `ride_price_guidance()` RPC, rendered on the publish price screen |

Shipping only the meter would leave the legal exposure completely open.
Shipping only the ceiling would give drivers no idea what price fills a car.

## The legal reasoning (why the ceiling is not optional)

The line that matters everywhere SameWay might operate is **cost-sharing
carpooling** (legal, non-commercial) versus **commercial passenger
transport** (requires a permit). The test regulators and courts apply is
whether **the driver profits**. BlaBlaCar's price caps are the mechanism
that keeps them on the legal side of it — courts in Spain and elsewhere
have upheld their model specifically because drivers only defray costs
and the platform, not the driver, takes the fee.

Azerbaijan has no carpooling-specific statute. Taxis are heavily
regulated (AYNA: permits, pass cards, driver training, vehicle age and
Euro-5 standards). With no carve-out for carpooling, the only safe
harbour is the non-profit cost-sharing framing — anything that looks
like commercial transport falls under the taxi permit regime, exposing
both drivers and potentially the platform.

**This is why a driver cannot publish above the ceiling.** It is not a
UX guardrail that can be relaxed for growth.

## How the ceiling is computed

```
road_km   = haversine_km × road_distance_factor
trip_cost = base_trip_cost                            (fixed)
          + road_km × (consumption ÷ 100) × fuel_price (fuel)
          + road_km × wear_per_km                      (wear)

ceiling_per_seat = LEAST(
    (trip_cost ÷ (seats + 1)) × ceiling_multiplier,   -- cost split, with headroom
     trip_cost ÷ seats                                 -- hard no-profit bound
) truncated down to 2dp
```

Three things in that formula are load-bearing, each because removing it
broke the invariant during testing:

- **`seats + 1`** puts the driver in a seat — they bear their own share.
- **The `LEAST` with `trip_cost ÷ seats`** is not redundant. The
  multiplier alone starts permitting profit once seats > 4; at the 8
  seats the schema allows, a van could have charged well above cost.
- **Truncating, not rounding.** Rounding up pushes `seats × ceiling` a
  few qapik past trip cost.

**`base_trip_cost`** models the fixed cost of making a trip at all
(vehicle prep, waiting, getting to the pickup). Without it, pure per-km
maths gives nonsense on short hops — Baku–Sumqayit came out at 1.44 ₼
per seat against a real ~2–3 ₼ fare. It is a modelled cost, not a
floor, so the no-profit bound still applies on top of it.

Worked example — Baku–Ganja (298 km straight-line → 387 km road-adjusted):

```
base                          =  3.00 ₼
fuel  387 × 0.08 × 1.20       = 37.15 ₼
wear  387 × 0.080             = 30.96 ₼
trip cost                     = 71.11 ₼

3 seats: min(71.11÷4×1.25, 71.11÷3) = 22.23 ₼ ceiling
4 seats: min(71.11÷5×1.25, 71.11÷4) = 17.78 ₼ ceiling
```

A 15 ₼ fare passes at every seat count. Verified across three corridors
× eight seat counts that total collected never exceeds trip cost.

Distance uses **straight-line (haversine) × `road_distance_factor`**
(default 1.30). Straight-line alone understated Baku–Ganja by 26% and
made the ceiling block legitimate prices. Once the Directions API road
distance is stored on the route, set the factor to 1.00 and use it
directly.

## Per-market parameters

Global defaults live on `platform_settings`; each country can override
them on `countries` (fuel prices vary enormously between markets).
`cost_share_ceiling()` coalesces country → global.

Opening a new market therefore means **setting its fuel price,
consumption, wear and multiplier** — not editing any function. If a
country has no overrides it inherits the global defaults, which are
calibrated for Azerbaijan and will be wrong elsewhere. Set them.

## The meter (client contract)

`ride_price_guidance(from_lat, from_lng, to_lat, to_lng, seats, price)`
returns:

```jsonc
{
  "distance_km": 375.2,
  "ceiling": 20.63,          // hard max — publishing above this fails
  "suggested_min": 14.00,    // market p25, clamped to ceiling
  "suggested_max": 17.00,    // market p75, clamped to ceiling
  "market_median": 15.00,
  "market_p25": 14.00,
  "market_p75": 17.00,
  "sample_size": 12,         // comparable rides found
  "your_price": 19.00,
  "position": "above"        // below | competitive | above | over_ceiling
}
```

Suggested UI on the price screen (P-60 in the screen map):

- **`competitive`** — green, "Good price. Rides in this range fill fastest."
- **`below`** — blue, "Cheaper than most. You'll fill fast."
- **`above`** — amber, "Higher than most rides on this route — you may not fill your seats." Show the market range.
- **`over_ceiling`** — red, publish disabled: "SameWay is a cost-sharing platform. The most you can charge on this route is X ₼ per seat."

When `sample_size < 5` there are too few comparable rides to speak
about "the market" — fall back to showing the ceiling and a suggested
band derived from it, and don't display percentile language.

## Failure mode to know about

If a country's parameters are later tightened below an existing route's
price, the **next nightly generation run for that route will fail**
rather than silently publishing an illegal price. That is intended. It
will surface in `job_runs` (see cron monitoring) — the fix is to notify
affected drivers to reprice, not to loosen the ceiling.
