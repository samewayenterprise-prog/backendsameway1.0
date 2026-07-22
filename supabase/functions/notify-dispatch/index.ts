// notify-dispatch — delivers undelivered notification rows via FCM.
// Run on a schedule (every minute). The DB triggers already write the
// rows (follow fan-out, booking events, parcel events); this worker
// only handles transport. With no FCM_SERVER_KEY set it runs in
// log-only mode and still marks rows sent, so dev environments don't
// pile up an endless backlog.
import { serviceClient } from "../_shared/service.ts";

// Original, human-readable push copy per notification type. Anything
// unlisted falls back to the app name + a generic line.
const COPY: Record<string, { title: string; body: (d: any) => string }> = {
  followed_driver_posted: {
    title: "New ride from a driver you follow",
    body: (d) => `${d.from ?? "?"} → ${d.to ?? "?"} — grab a seat before it fills.`,
  },
  booking_request: {
    title: "New booking request",
    body: () => "A rider wants a seat — review it before it expires.",
  },
  booking_approved: {
    title: "You're in! Booking approved",
    body: (d) => `${d.from ?? ""} → ${d.to ?? ""}`.trim() || "See you at the pickup.",
  },
  booking_declined: {
    title: "Booking declined",
    body: () => "That one didn't work out — there are other rides waiting.",
  },
  parcel_accepted: {
    title: "Parcel accepted",
    body: () => "Your courier said yes. Payment confirmed, code is ready.",
  },
  parcel_delivered: {
    title: "Parcel delivered 📦",
    body: () => "Code confirmed at handoff. Rate your courier?",
  },
};

Deno.serve(async (_req) => {
  const db = serviceClient();
  const fcmKey = Deno.env.get("FCM_SERVER_KEY");
  const out = { fetched: 0, pushed: 0, logOnly: !fcmKey, errors: [] as string[] };

  const { data: rows, error } = await db
    .from("notifications")
    .select("id, user_id, type, data")
    .is("sent_at", null)
    .order("created_at", { ascending: true })
    .limit(200);
  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }
  out.fetched = rows?.length ?? 0;
  if (!rows || rows.length === 0) {
    return new Response(JSON.stringify(out), { status: 200 });
  }

  // Tokens for every recipient in this batch, one query.
  const userIds = [...new Set(rows.map((r) => r.user_id))];
  const { data: tokens } = await db
    .from("device_tokens")
    .select("user_id, fcm_token")
    .in("user_id", userIds);
  const byUser = new Map<string, string[]>();
  for (const t of tokens ?? []) {
    const list = byUser.get(t.user_id) ?? [];
    list.push(t.fcm_token);
    byUser.set(t.user_id, list);
  }

  for (const n of rows) {
    const copy = COPY[n.type] ?? {
      title: "SameWay",
      body: () => "You have an update — open the app.",
    };
    const targets = byUser.get(n.user_id) ?? [];

    if (fcmKey && targets.length > 0) {
      for (const token of targets) {
        try {
          const res = await fetch("https://fcm.googleapis.com/fcm/send", {
            method: "POST",
            headers: {
              "content-type": "application/json",
              authorization: `key=${fcmKey}`,
            },
            body: JSON.stringify({
              to: token,
              notification: { title: copy.title, body: copy.body(n.data) },
              data: { type: n.type, ...n.data },
            }),
          });
          if (res.ok) out.pushed++;
          else out.errors.push(`fcm ${n.id}: HTTP ${res.status}`);
          // TODO: on NotRegistered responses, delete the dead token row.
          // TODO: migrate to FCM HTTP v1 (OAuth service account) before
          // scale — the legacy key endpoint is the fastest to wire, not
          // the long-term one.
        } catch (e) {
          out.errors.push(`fcm ${n.id}: ${(e as Error).message}`);
        }
      }
    }
    // Mark sent regardless: no tokens = nothing to deliver, and
    // log-only mode should not create an infinite backlog.
    await db.from("notifications")
      .update({ sent_at: new Date().toISOString() })
      .eq("id", n.id);
  }

  return new Response(JSON.stringify(out), {
    headers: { "content-type": "application/json" },
    status: out.errors.length ? 207 : 200,
  });
});
