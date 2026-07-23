// data-admin.js — the Django-admin equivalent: auto-generated CRUD for
// every table in the schema, mounted at /data alongside the hand-built
// pages (Dashboard, KYC, Reports, Markets, Ops, Settings).
//
// Why this exists: those hand-built pages cover the workflows we
// designed for (KYC review, report moderation, market rollout). But
// ~37 tables exist and only a handful have any admin visibility at
// all — everything else (vehicles, routes, ranks, badges, streaks,
// device tokens, ...) has been invisible to ops. AdminJS auto-
// introspects the real Postgres schema and generates list/show/edit/
// new/delete screens for whatever we point it at, the same category
// of tool as Django admin — just not Django, since we're not on Django.
//
// SAFETY MODEL — this is the part that matters. A blanket "expose
// every table with full CRUD" would let someone directly edit
// driver_profiles.rating_avg, or a transactions row, or a payout,
// bypassing every integrity rule built today (the no-profit price
// ceiling, the trigger-owned counters, the column-level privilege
// locks, the ledger-only-via-service-role design). Three tiers,
// applied per table below:
//
//   FULL   — safe to edit directly: reference/config data, or things
//            ops genuinely needs to fix (a typo'd plate number, a
//            stuck device token). Triggers still fire on any write
//            through this tool exactly as they do from the app, so
//            e.g. the price-ceiling trigger still protects rides/
//            routes even here — that's a real safety property of
//            going through Postgres triggers rather than an ORM.
//   READ   — list + show only (new/edit/delete disabled). For
//            anything that's an RPC-only state machine (bookings),
//            a financial ledger (transactions/payouts/driver_balances),
//            or trigger-derived (streaks, ranks, points) — direct
//            edits there don't run the release-seats/ledger logic the
//            RPCs do, so they'd corrupt state even though the write
//            itself would "succeed."
//   HIDDEN — not registered at all. Currently just user_verifications:
//            it holds a private document storage path, and the
//            existing KYC page already handles it correctly (signed
//            URLs, approve/reject actually reviewing the document).
//            Exposing the raw table here would be a shortcut around
//            actually looking at someone's ID before approving them.
//
// New tables added later should be triaged into one of these three
// before being added below — don't default to FULL for something
// touched by a trigger or an RPC without checking first.

import AdminJS from "adminjs";
import AdminJSExpress from "@adminjs/express";
import Adapter, { Database, Resource } from "@adminjs/sql";

AdminJS.registerAdapter({ Database, Resource });

const READ_ONLY_ACTIONS = {
  new: { isAccessible: false },
  edit: { isAccessible: false },
  delete: { isAccessible: false },
  bulkDelete: { isAccessible: false },
};

// Tables where direct writes bypass an RPC state machine, a financial
// ledger, or trigger-derived state. List + show only.
const READ_ONLY_TABLES = new Set([
  "bookings", "booking_passengers", "booking_invites",
  "transactions", "driver_balances", "payouts", "payment_methods",
  "notifications", "notification_jobs", "job_runs",
  "reviews", "point_transactions", "user_points", "user_ranks",
  "route_streaks", "rider_streaks",
  "conversations", "conversation_participants",
  "reports", // the dedicated Reports page is the intended write path
]);

// messages: moderation needs delete (remove abusive content) but not
// edit (never rewrite what someone actually sent) or new (nobody
// should be able to inject a message as another user).
const MESSAGES_ACTIONS = {
  new: { isAccessible: false },
  edit: { isAccessible: false },
};

// Not registered at all — see HIDDEN rationale above.
const HIDDEN_TABLES = new Set(["user_verifications"]);

// Trigger-owned counters, visible but not editable even on an
// otherwise-full-CRUD resource — mirrors the column-level privilege
// locks already enforced in RLS (003/012), applied here too so the
// admin UI doesn't invite an edit that the database would silently
// have allowed a service-role connection to make.
const READ_ONLY_PROPERTIES = {
  driver_profiles: ["rating_avg", "rating_count", "ride_count", "follower_count"],
  users: ["created_at"],
};

function resourceOptions(table) {
  const options = { actions: {} };

  if (table === "messages") {
    options.actions = { ...MESSAGES_ACTIONS };
  } else if (READ_ONLY_TABLES.has(table)) {
    options.actions = { ...READ_ONLY_ACTIONS };
  }

  const lockedProps = READ_ONLY_PROPERTIES[table];
  if (lockedProps) {
    options.properties = {};
    for (const p of lockedProps) {
      options.properties[p] = { isDisabled: true };
    }
  }
  return options;
}

// Every table in the schema as of migration 0016, minus the hidden
// ones. Grouped into nav sections purely for readability in the
// sidebar — doesn't affect access at all.
const NAV = {
  "People": ["users", "user_preferences", "driver_profiles", "vehicles", "blocks", "follows"],
  "Rides": ["routes", "route_stops", "rides", "ride_stops"],
  "Booking": ["bookings", "booking_passengers", "booking_invites"],
  "Parcels": ["parcels"],
  "Money": ["transactions", "driver_balances", "payouts", "payment_methods", "platform_settings"],
  "Gamification": ["ranks", "badges", "user_ranks", "user_points", "point_transactions", "route_streaks", "rider_streaks", "user_badges"],
  "Messaging": ["conversations", "conversation_participants", "messages"],
  "Trust & Safety": ["reports", "reviews"],
  "Markets": ["countries"],
  "Ops (system)": ["device_tokens", "notifications", "notification_jobs", "job_runs"],
};

function navFor(table) {
  for (const [group, tables] of Object.entries(NAV)) {
    if (tables.includes(table)) return { name: group, icon: "Database" };
  }
  return { name: "Other", icon: "Database" };
}

export async function mountDataAdmin(app, requireAuth) {
  const dbUrl = process.env.SUPABASE_DB_URL;
  if (!dbUrl) {
    console.warn(
      "SUPABASE_DB_URL not set — /data (table admin) not mounted. " +
      "See docs/data-admin.md for where to find this connection string."
    );
    return;
  }

  const db = await new Adapter("postgresql", {
    connectionString: dbUrl,
    database: "postgres",
  }).init();

  const allTables = db.tables().map((t) => t.tableName);
  const resources = [];

  for (const table of allTables) {
    if (HIDDEN_TABLES.has(table)) continue;
    resources.push({
      resource: db.table(table),
      options: {
        navigation: navFor(table),
        ...resourceOptions(table),
      },
    });
  }

  const admin = new AdminJS({
    resources,
    rootPath: "/data",
    branding: {
      companyName: "SameWay",
      logo: "/sameway-mark.png",
      favicon: "/favicon.ico",
      withMadeWithLove: false,
      // Real brand hex values (matches admin/server.js's --vi/--az CSS
      // vars), not a full reskin — AdminJS's component layout/fonts
      // still look like AdminJS. This is the "same colors" half of
      // unification, not "identical framework" — that would mean
      // hand-building pages for all ~30 tables instead of using this
      // tool at all. See docs/data-admin.md.
      theme: {
        colors: {
          primary100: "#5B23FF",
          primary80: "#7C4DFF",
          primary60: "#9D77FF",
          primary40: "#BEA1FF",
          primary20: "#DFCBFF",
          accent: "#008BFF",
        },
      },
    },
  });

  // No separate AdminJS login. This was two logins for one panel —
  // log into admin.sameway.io, then log in AGAIN for /data with the
  // same password. Instead: an unauthenticated AdminJS router, gated
  // by the SAME signed-cookie session (`requireAuth`, defined in
  // server.js) as every other page. Log in once; /data just works.
  const router = AdminJSExpress.buildRouter(admin);

  app.use(admin.options.rootPath, requireAuth, router);
  console.log(`Table admin mounted at ${admin.options.rootPath} (${resources.length} tables)`);
}
