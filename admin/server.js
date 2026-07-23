// SameWay admin panel — single-file Express server.
// Design rules: service-role key lives ONLY here (never in a browser
// bundle); UI follows the DESIGN.md trust zone (light, violet/azure,
// no gamification color). Auth is a shared password + signed cookie —
// right-sized for a solo-operator launch; swap for Supabase-auth roles
// when there's a second admin.
import express from "express";
import crypto from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import ws from "ws";
import { mountDataAdmin } from "./data-admin.js";

const {
  SUPABASE_URL,
  SUPABASE_SECRET_KEY,
  ADMIN_PASSWORD,
  SESSION_SECRET,
  PORT = "8080",
  HOST = "127.0.0.1",
} = process.env;

for (const [k, v] of Object.entries({ SUPABASE_URL, SUPABASE_SECRET_KEY, ADMIN_PASSWORD, SESSION_SECRET })) {
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
}

// supabase-js always constructs a Realtime client, even though this
// panel only does REST reads/writes. On Node < 22 there's no native
// WebSocket, so hand it `ws` explicitly or startup throws.
const db = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, {
  auth: { persistSession: false },
  realtime: { transport: ws },
});
const app = express();
app.use(express.urlencoded({ extended: false }));
app.use(express.static("public", { maxAge: "1d" }));

// ── tiny signed-cookie session ─────────────────────────────────────
const sign = (v) => crypto.createHmac("sha256", SESSION_SECRET).update(v).digest("hex");
const SESSION_VALUE = "sw-admin-1";
const COOKIE = `sw=${SESSION_VALUE}.${sign(SESSION_VALUE)}`;

function authed(req) {
  const raw = (req.headers.cookie || "").split(";").map((s) => s.trim()).find((s) => s.startsWith("sw="));
  if (!raw) return false;
  const [, val] = raw.split("=");
  const [v, sig] = (val || "").split(".");
  if (!v || !sig) return false;
  const expect = sign(v);
  return sig.length === expect.length &&
    crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expect)) && v === SESSION_VALUE;
}
function requireAuth(req, res, next) {
  if (authed(req)) return next();
  res.redirect("/login");
}

// ── layout (trust-zone styling per DESIGN.md, light-first) ─────────
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const fmtDate = (d) => (d ? new Date(d).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" }) : "—");

function layout(title, body, active = "") {
  const tab = (href, label, key) =>
    `<a href="${href}" class="tab${active === key ? " on" : ""}">${label}</a>`;
  return `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} · SameWay Admin</title>
<link rel="icon" type="image/x-icon" href="/favicon.ico">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<style>
:root{--bg:#F6F4FB;--sf:#fff;--ln:#E1DCEF;--tx:#241E38;--sub:#6E6690;--vi:#5B23FF;--az:#008BFF;--ok:#1FA866;--er:#E03A57}
*{box-sizing:border-box;margin:0}
body{font-family:Inter,system-ui,sans-serif;background:var(--bg);color:var(--tx)}
header{display:flex;align-items:center;gap:18px;padding:14px 22px;background:var(--sf);border-bottom:1px solid var(--ln)}
header .brand{display:flex;align-items:center;gap:10px;font-size:15px;font-weight:800;text-decoration:none;color:var(--tx)}
header .brand img{height:26px;width:auto;display:block}
header .brand .sep{color:var(--sub);font-weight:600}
.tab{color:var(--sub);text-decoration:none;font-weight:600;font-size:13.5px;padding:6px 10px;border-radius:8px}
.tab.on{color:#fff;background:var(--vi)}
main{max-width:1060px;margin:26px auto;padding:0 20px}
h1{font-size:20px;margin-bottom:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px;margin-bottom:22px}
.card{background:var(--sf);border:1px solid var(--ln);border-radius:14px;padding:14px 16px}
.card .n{font-size:24px;font-weight:800}
.card .l{font-size:11px;color:var(--sub);text-transform:uppercase;letter-spacing:.5px;margin-top:2px}
table{width:100%;border-collapse:collapse;background:var(--sf);border:1px solid var(--ln);border-radius:14px;overflow:hidden}
th,td{padding:10px 12px;text-align:left;font-size:13px;border-bottom:1px solid var(--ln);vertical-align:top}
th{font-size:11px;color:var(--sub);text-transform:uppercase;letter-spacing:.5px}
tr:last-child td{border-bottom:none}
.btn{display:inline-block;background:var(--vi);color:#fff;border:none;border-radius:9px;padding:8px 14px;font-weight:700;font-size:13px;cursor:pointer;text-decoration:none}
.btn.ghost{background:#fff;color:var(--vi);border:1.5px solid var(--vi)}
.btn.dgr{background:var(--er)}
.badge{display:inline-block;border:1px solid var(--ln);border-radius:99px;padding:2px 9px;font-size:11px;font-weight:700}
.badge.ok{color:var(--ok);border-color:var(--ok)}
.badge.er{color:var(--er);border-color:var(--er)}
.sub{color:var(--sub);font-size:12px}
img.doc{max-width:230px;border-radius:10px;border:1px solid var(--ln);display:block}
form.inline{display:inline}
input[type=text],input[type=password]{padding:10px 12px;border:1.5px solid var(--ln);border-radius:10px;font-size:14px;width:100%;max-width:340px}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.section{margin-bottom:26px}
.pillnav{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:14px}
.pillnav a{color:var(--sub);text-decoration:none;font-size:12.5px;font-weight:700;padding:5px 12px;border:1px solid var(--ln);border-radius:99px;background:#fff}
.pillnav a.on{background:var(--vi);color:#fff;border-color:var(--vi)}
.mrow{display:grid;grid-template-columns:1fr 60px 90px 120px 1fr 120px;gap:8px;align-items:center;padding:8px 12px;font-size:12.5px;border-bottom:1px solid var(--ln)}
.mrow.head{font-size:10.5px;color:var(--sub);text-transform:uppercase;letter-spacing:.4px;font-weight:700}
.mrow select,.mrow input[type=text]{padding:5px 7px;border:1.5px solid var(--ln);border-radius:7px;font-size:12px;width:100%}
.mrow .btn{padding:5px 10px;font-size:11.5px}
.regionhead{font-weight:800;font-size:13.5px;margin:20px 0 8px;padding-bottom:4px;border-bottom:2px solid var(--vi)}
.subhead{font-weight:700;font-size:11.5px;color:var(--sub);margin:10px 0 4px;text-transform:uppercase;letter-spacing:.4px}
</style></head><body>
<header><a class="brand" href="/"><img src="/sameway-mark.png" alt="SameWay"><span>SAME<span style="color:var(--vi)">WAY</span></span><span class="sep">·</span><span style="font-weight:600;color:var(--sub)">Admin</span></a>
${tab("/", "Dashboard", "dash")}${tab("/kyc", "KYC", "kyc")}${tab("/reports", "Reports", "rep")}${tab("/users", "Users", "usr")}${tab("/markets", "Markets", "mkt")}${tab("/ops", "Ops", "ops")}${tab("/settings", "Settings", "set")}<a href="/data" target="_blank" class="tab">All Tables ↗</a>
<span style="flex:1"></span><a class="tab" href="/logout">Log out</a></header>
<main>${body}</main></body></html>`;
}

// ── auth routes ────────────────────────────────────────────────────
app.get("/login", (_req, res) => {
  res.send(layout("Login", `
    <div style="text-align:center;margin-bottom:24px">
      <img src="/sameway-mark.png" alt="SameWay" style="height:64px;width:auto">
      <div style="font-weight:800;font-size:18px;margin-top:8px">SAME<span style="color:var(--vi)">WAY</span> <span style="color:var(--sub);font-weight:600">· Admin</span></div>
    </div>
    <form method="post" action="/login" class="card" style="max-width:380px;margin:0 auto">
      <p class="sub" style="margin-bottom:10px">Ops access only.</p>
      <input type="password" name="password" placeholder="Admin password" autofocus>
      <div style="margin-top:12px"><button class="btn">Enter</button></div>
    </form>`));
});
app.post("/login", (req, res) => {
  const given = Buffer.from(String(req.body.password || ""));
  const want = Buffer.from(ADMIN_PASSWORD);
  const ok = given.length === want.length && crypto.timingSafeEqual(given, want);
  if (!ok) return res.send(layout("Login", `<h1>Wrong password</h1><a class="btn ghost" href="/login">Try again</a>`));
  res.setHeader("Set-Cookie", `${COOKIE}; HttpOnly; Path=/; Max-Age=43200; SameSite=Lax`);
  res.redirect("/");
});
app.get("/logout", (_req, res) => {
  res.setHeader("Set-Cookie", "sw=; Path=/; Max-Age=0");
  res.redirect("/login");
});

// ── dashboard ──────────────────────────────────────────────────────
app.get("/", requireAuth, async (_req, res, next) => {
  try {
    const count = async (table, mod) => {
      let q = db.from(table).select("*", { count: "exact", head: true });
      if (mod) q = mod(q);
      const { count: c } = await q;
      return c ?? 0;
    };
    const nowIso = new Date().toISOString();
    const [users, kyc, reports, rides, bookings, parcels, unsent] = await Promise.all([
      count("users"),
      count("user_verifications", (q) => q.not("id_document_url", "is", null).or("id_verified_at.is.null,selfie_verified_at.is.null")),
      count("reports", (q) => q.in("status", ["open", "in_review"])),
      count("rides", (q) => q.gte("departure_at", nowIso).eq("status", "published")),
      count("bookings", (q) => q.eq("status", "confirmed")),
      count("parcels", (q) => q.in("status", ["accepted", "in_transit"])),
      count("notifications", (q) => q.is("sent_at", null)),
    ]);
    const { data: rev } = await db.from("transactions")
      .select("amount_platform").eq("type", "charge").eq("status", "settled").limit(1000);
    const revenue = (rev ?? []).reduce((s, r) => s + Number(r.amount_platform || 0), 0).toFixed(2);

    const cards = [
      [users, "Users"], [kyc, "KYC pending"], [reports, "Open reports"],
      [rides, "Upcoming rides"], [bookings, "Confirmed bookings"],
      [parcels, "Parcels in flight"], [unsent, "Push backlog"], [`${revenue} ₼`, "Platform revenue (settled)"],
    ].map(([n, l]) => `<div class="card"><div class="n">${esc(n)}</div><div class="l">${esc(l)}</div></div>`).join("");

    const { data: latest } = await db.from("users")
      .select("full_name, phone, created_at").order("created_at", { ascending: false }).limit(8);
    const rows = (latest ?? []).map((u) =>
      `<tr><td>${esc(u.full_name || "—")}</td><td>${esc(u.phone)}</td><td class="sub">${fmtDate(u.created_at)}</td></tr>`).join("");

    res.send(layout("Dashboard", `
      <h1>Dashboard</h1>
      <div class="grid">${cards}</div>
      <div class="section"><h1 style="font-size:15px">Latest signups</h1>
      <table><tr><th>Name</th><th>Phone</th><th>Joined</th></tr>${rows || `<tr><td colspan=3 class="sub">No users yet</td></tr>`}</table></div>`, "dash"));
  } catch (e) { next(e); }
});

// ── KYC queue ──────────────────────────────────────────────────────
app.get("/kyc", requireAuth, async (_req, res, next) => {
  try {
    const { data: pending } = await db.from("user_verifications")
      .select("user_id, id_verified_at, selfie_verified_at, id_document_url")
      .not("id_document_url", "is", null)
      .or("id_verified_at.is.null,selfie_verified_at.is.null")
      .limit(30);

    const ids = (pending ?? []).map((p) => p.user_id);
    const { data: us } = ids.length
      ? await db.from("users").select("id, full_name, phone, created_at").in("id", ids)
      : { data: [] };
    const byId = new Map((us ?? []).map((u) => [u.id, u]));

    const blocks = [];
    for (const p of pending ?? []) {
      const u = byId.get(p.user_id) || {};
      const signed = async (path) => {
        const { data } = await db.storage.from("documents").createSignedUrl(path, 600);
        return data?.signedUrl || null;
      };
      const idUrl = await signed(p.id_document_url);
      const selfieUrl = await signed(`${p.user_id}/selfie.jpg`); // path convention set by the mobile app
      blocks.push(`
        <div class="card section">
          <div class="row" style="justify-content:space-between">
            <div><b>${esc(u.full_name || "No name yet")}</b> · ${esc(u.phone || "")}
              <div class="sub">joined ${fmtDate(u.created_at)} · id ${p.id_verified_at ? "✓" : "—"} · selfie ${p.selfie_verified_at ? "✓" : "—"}</div>
            </div>
            <div class="row">
              <form class="inline" method="post" action="/kyc/${p.user_id}/approve"><button class="btn">Approve both</button></form>
              <form class="inline" method="post" action="/kyc/${p.user_id}/reject"><button class="btn dgr">Reject</button></form>
            </div>
          </div>
          <div class="row" style="margin-top:12px">
            <div>${idUrl ? `<img class="doc" src="${idUrl}">` : `<span class="badge er">ID image missing</span>`}<div class="sub">Document</div></div>
            <div>${selfieUrl ? `<img class="doc" src="${selfieUrl}">` : `<span class="badge er">Selfie missing</span>`}<div class="sub">Selfie</div></div>
          </div>
        </div>`);
    }
    res.send(layout("KYC", `<h1>KYC queue</h1>${blocks.join("") || `<p class="sub">Queue is empty — nothing waiting for review.</p>`}`, "kyc"));
  } catch (e) { next(e); }
});

app.post("/kyc/:uid/approve", requireAuth, async (req, res, next) => {
  try {
    const now = new Date().toISOString();
    await db.from("user_verifications")
      .update({ id_verified_at: now, selfie_verified_at: now })
      .eq("user_id", req.params.uid);
    res.redirect("/kyc");
  } catch (e) { next(e); }
});

app.post("/kyc/:uid/reject", requireAuth, async (req, res, next) => {
  try {
    // Clearing the document path removes them from the queue and forces
    // a fresh capture in the app. (Gap to close later: a "rejected —
    // please redo" state surfaced to the user; today they simply remain
    // unverified.)
    await db.from("user_verifications")
      .update({ id_verified_at: null, selfie_verified_at: null, id_document_url: null })
      .eq("user_id", req.params.uid);
    res.redirect("/kyc");
  } catch (e) { next(e); }
});

// ── reports ────────────────────────────────────────────────────────
app.get("/reports", requireAuth, async (_req, res, next) => {
  try {
    const { data: reps } = await db.from("reports")
      .select("*").in("status", ["open", "in_review"])
      .order("created_at", { ascending: true }).limit(40);

    const ids = [...new Set((reps ?? []).flatMap((r) => [r.reporter_id, r.reported_user_id]).filter(Boolean))];
    const { data: us } = ids.length
      ? await db.from("users").select("id, full_name, phone").in("id", ids)
      : { data: [] };
    const byId = new Map((us ?? []).map((u) => [u.id, u]));
    const who = (id) => { const u = byId.get(id); return u ? `${esc(u.full_name || "—")} (${esc(u.phone)})` : "—"; };

    const rows = (reps ?? []).map((r) => `
      <tr>
        <td><span class="badge">${esc(r.reason)}</span><div class="sub">${fmtDate(r.created_at)}</div></td>
        <td>${who(r.reporter_id)}</td>
        <td>${r.reported_user_id ? who(r.reported_user_id) : "—"}</td>
        <td>${esc(r.description || "")}</td>
        <td class="row">
          <form class="inline" method="post" action="/reports/${r.id}/resolve"><button class="btn dgr">Uphold</button></form>
          <form class="inline" method="post" action="/reports/${r.id}/dismiss"><button class="btn ghost">Dismiss</button></form>
        </td>
      </tr>`).join("");

    res.send(layout("Reports", `
      <h1>Reports</h1>
      <p class="sub" style="margin-bottom:10px">Uphold = status <b>resolved</b> → the reputation penalty fires automatically (−10 no-show, −20 otherwise). Dismiss = no penalty.</p>
      <table><tr><th>Reason</th><th>Reporter</th><th>Reported</th><th>Details</th><th></th></tr>
      ${rows || `<tr><td colspan=5 class="sub">No open reports.</td></tr>`}</table>`, "rep"));
  } catch (e) { next(e); }
});

app.post("/reports/:id/resolve", requireAuth, async (req, res, next) => {
  try { await db.from("reports").update({ status: "resolved" }).eq("id", req.params.id); res.redirect("/reports"); }
  catch (e) { next(e); }
});
app.post("/reports/:id/dismiss", requireAuth, async (req, res, next) => {
  try { await db.from("reports").update({ status: "dismissed" }).eq("id", req.params.id); res.redirect("/reports"); }
  catch (e) { next(e); }
});

// ── users ──────────────────────────────────────────────────────────
app.get("/users", requireAuth, async (req, res, next) => {
  try {
    const q = String(req.query.q || "").trim();
    let list = [];
    if (q) {
      const { data } = await db.from("users")
        .select("id, full_name, phone, created_at, is_deleted")
        .or(`phone.ilike.%${q}%,full_name.ilike.%${q}%`)
        .limit(30);
      list = data ?? [];
    } else {
      const { data } = await db.from("users")
        .select("id, full_name, phone, created_at, is_deleted")
        .order("created_at", { ascending: false }).limit(30);
      list = data ?? [];
    }
    const ids = list.map((u) => u.id);
    const { data: vs } = ids.length
      ? await db.from("user_verifications").select("user_id, id_verified_at, selfie_verified_at").in("user_id", ids)
      : { data: [] };
    const vById = new Map((vs ?? []).map((v) => [v.user_id, v]));

    const rows = list.map((u) => {
      const v = vById.get(u.id) || {};
      const verified = v.id_verified_at && v.selfie_verified_at;
      return `<tr>
        <td>${esc(u.full_name || "—")}${u.is_deleted ? ' <span class="badge er">deleted</span>' : ""}</td>
        <td>${esc(u.phone)}</td>
        <td>${verified ? '<span class="badge ok">verified</span>' : '<span class="badge">phone only</span>'}</td>
        <td class="sub">${fmtDate(u.created_at)}</td>
      </tr>`;
    }).join("");

    res.send(layout("Users", `
      <h1>Users</h1>
      <form method="get" action="/users" class="row section">
        <input type="text" name="q" value="${esc(q)}" placeholder="Search phone or name">
        <button class="btn">Search</button>
      </form>
      <table><tr><th>Name</th><th>Phone</th><th>Status</th><th>Joined</th></tr>
      ${rows || `<tr><td colspan=4 class="sub">No matches.</td></tr>`}</table>`, "usr"));
  } catch (e) { next(e); }
});

// ── markets (country registry) ─────────────────────────────────────
const REGIONS = ["Africa", "Asia", "Europe", "North America", "South America", "Oceania", "Antarctica"];

app.get("/markets", requireAuth, async (req, res, next) => {
  try {
    const q = String(req.query.q || "").trim();
    const region = String(req.query.region || "").trim();
    const activeOnly = req.query.active === "1";

    let query = db.from("countries").select("*").order("region").order("subregion").order("name");
    if (q) query = query.or(`name.ilike.%${q}%,iso2.ilike.%${q}%`);
    if (region) query = query.eq("region", region);
    if (activeOnly) query = query.eq("is_active", true);
    const { data: countries } = await query;

    const { count: activeCount } = await db.from("countries")
      .select("*", { count: "exact", head: true }).eq("is_active", true);
    const { count: connectedCount } = await db.from("countries")
      .select("*", { count: "exact", head: true }).eq("payment_status", "connected");

    const pill = (href, label, on) => `<a href="${href}" class="${on ? "on" : ""}">${esc(label)}</a>`;
    const pills = [
      pill(`/markets${activeOnly ? "?active=1" : ""}`, "All regions", !region),
      ...REGIONS.map((r) => pill(
        `/markets?region=${encodeURIComponent(r)}${activeOnly ? "&active=1" : ""}`, r, region === r
      )),
    ].join("");

    // group by region then subregion for headers
    const groups = new Map();
    for (const c of countries ?? []) {
      const key = `${c.region}|||${c.subregion}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(c);
    }

    let lastRegion = null;
    const rows = [];
    for (const [key, list] of groups) {
      const [rg, sub] = key.split("|||");
      if (rg !== lastRegion) { rows.push(`<div class="regionhead">${esc(rg)}</div>`); lastRegion = rg; }
      if (sub !== rg) rows.push(`<div class="subhead">${esc(sub)}</div>`);
      rows.push(`<div class="mrow head"><div>Country</div><div>ISO</div><div>Currency</div><div>Payment</div><div>Provider</div><div>Active</div></div>`);
      for (const c of list) {
        rows.push(`
          <form class="mrow" method="post" action="/markets/${c.iso2}">
            <div>${esc(c.name)}</div>
            <div class="sub">${esc(c.iso2)}</div>
            <div><input type="text" name="currency_code" value="${esc(c.currency_code || "")}" placeholder="—" maxlength="3" style="text-transform:uppercase"></div>
            <div>
              <select name="payment_status">
                ${["not_connected", "pending", "connected", "suspended"].map((s) =>
                  `<option value="${s}" ${c.payment_status === s ? "selected" : ""}>${s}</option>`).join("")}
              </select>
            </div>
            <div><input type="text" name="payment_provider" value="${esc(c.payment_provider || "")}" placeholder="e.g. epoint"></div>
            <div class="row" style="gap:8px">
              <label class="row" style="gap:4px;font-size:11px" title="Market open">
                <input type="checkbox" name="is_active" value="1" ${c.is_active ? "checked" : ""}> ${c.is_active ? "ON" : "OFF"}
              </label>
              <button class="btn ghost">Save</button>
            </div>
          </form>`);
      }
    }

    res.send(layout("Markets", `
      <h1>Markets</h1>
      <div class="grid" style="grid-template-columns:repeat(auto-fill,minmax(180px,1fr))">
        <div class="card"><div class="n">${activeCount ?? 0}</div><div class="l">Active markets</div></div>
        <div class="card"><div class="n">${connectedCount ?? 0}</div><div class="l">Payments connected</div></div>
        <div class="card"><div class="n">${(countries ?? []).length}</div><div class="l">Shown below</div></div>
      </div>
      <form method="get" action="/markets" class="row section">
        <input type="text" name="q" value="${esc(q)}" placeholder="Search country or ISO code">
        ${region ? `<input type="hidden" name="region" value="${esc(region)}">` : ""}
        <label class="row" style="gap:6px"><input type="checkbox" name="active" value="1" ${activeOnly ? "checked" : ""} onchange="this.form.submit()"> Active only</label>
        <button class="btn ghost">Search</button>
      </form>
      <div class="pillnav">${pills}</div>
      <div class="card" style="padding:4px 0">${rows.join("") || `<div class="sub" style="padding:14px">No matches.</div>`}</div>
    `, "mkt"));
  } catch (e) { next(e); }
});

app.post("/markets/:iso2", requireAuth, async (req, res, next) => {
  try {
    const patch = {
      is_active: req.body.is_active === "1",
      payment_status: req.body.payment_status,
      payment_provider: req.body.payment_provider?.trim() || null,
      currency_code: req.body.currency_code?.trim().toUpperCase() || null,
    };
    await db.from("countries").update(patch).eq("iso2", req.params.iso2.toUpperCase());
    res.redirect(req.get("Referer") || "/markets");
  } catch (e) { next(e); }
});

app.post("/settings/pricing", requireAuth, async (req, res, next) => {
  try {
    const num = (v, min, max) => {
      const n = Number(v);
      return Number.isFinite(n) && n >= min && n <= max ? n : null;
    };
    const patch = {};
    const fuel = num(req.body.fuel_price_per_litre, 0, 100);
    const cons = num(req.body.fuel_consumption_l_100km, 1, 50);
    const wear = num(req.body.vehicle_wear_per_km, 0, 10);
    // Hard-bounded: above ~1.5 the cost-sharing/non-profit argument
    // weakens, which is the whole point of the ceiling. The DB has a
    // CHECK for this too — this is just a friendlier first line.
    const mult = num(req.body.price_ceiling_multiplier, 1.0, 2.0);
    if (fuel !== null) patch.fuel_price_per_litre = fuel;
    if (cons !== null) patch.fuel_consumption_l_100km = cons;
    if (wear !== null) patch.vehicle_wear_per_km = wear;
    if (mult !== null) patch.price_ceiling_multiplier = mult;
    if (Object.keys(patch).length) {
      await db.from("platform_settings").update(patch).eq("id", 1);
    }
    res.redirect("/settings");
  } catch (e) { next(e); }
});

app.post("/settings/gate", requireAuth, async (req, res, next) => {
  try {
    const patch = {};
    const rides = parseInt(String(req.body.fee_gate_min_daily_rides), 10);
    const fill = Number(req.body.fee_gate_min_fill_rate);
    if (Number.isInteger(rides) && rides >= 0) patch.fee_gate_min_daily_rides = rides;
    if (Number.isFinite(fill) && fill >= 0 && fill <= 1) patch.fee_gate_min_fill_rate = fill;
    if (Object.keys(patch).length) {
      await db.from("platform_settings").update(patch).eq("id", 1);
    }
    res.redirect("/settings");
  } catch (e) { next(e); }
});

// ── ops (cron health + liquidity gate) ─────────────────────────────
app.get("/ops", requireAuth, async (_req, res, next) => {
  try {
    const { data: liq } = await db.rpc("corridor_liquidity", { p_days: 7 });
    const { data: jobs, error: jobErr } = await db.from("job_health").select("*");
    const { data: pendingJobs } = await db
      .from("notification_jobs")
      .select("*", { count: "exact", head: true })
      .is("processed_at", null);

    const ready = liq?.ready_for_fees;
    const liqCard = liq ? `
      <div class="card section">
        <div class="row" style="justify-content:space-between">
          <div>
            <b>Fee readiness</b>
            ${ready ? '<span class="badge ok">THRESHOLD MET</span>'
                    : '<span class="badge">BUILDING LIQUIDITY</span>'}
            <div class="sub">Last ${esc(liq.window_days)} days · turning the fee on before the marketplace is liquid suppresses the supply you're trying to build.</div>
          </div>
        </div>
        <div class="grid" style="margin-top:12px;grid-template-columns:repeat(auto-fill,minmax(160px,1fr))">
          <div class="card"><div class="n">${esc(liq.rides_per_day)}</div><div class="l">Rides / day (need ${esc(liq.min_daily_rides)})</div></div>
          <div class="card"><div class="n">${Math.round((liq.fill_rate ?? 0) * 100)}%</div><div class="l">Seat fill rate (need ${Math.round((liq.min_fill_rate ?? 0) * 100)}%)</div></div>
          <div class="card"><div class="n">${esc(liq.seats_booked)}/${esc(liq.seats_offered)}</div><div class="l">Seats booked / offered</div></div>
        </div>
      </div>` : `<div class="card section sub">Liquidity data unavailable — is migration 0012 applied?</div>`;

    const jobRows = (jobs ?? []).map((j) => {
      const stale = j.last_run_at
        ? `<span class="sub">${fmtDate(j.last_run_at)}</span>`
        : `<span class="badge er">never run</span>`;
      const status = j.last_run_ok === true ? '<span class="badge ok">ok</span>'
                   : j.last_run_ok === false ? '<span class="badge er">failed</span>'
                   : '<span class="badge">—</span>';
      return `<tr>
        <td><b>${esc(j.job_name)}</b>${j.active ? "" : ' <span class="badge er">inactive</span>'}</td>
        <td class="sub">${esc(j.schedule)}</td>
        <td>${stale}</td>
        <td>${status}</td>
        <td class="sub">${esc(j.last_error || "")}</td>
      </tr>`;
    }).join("");

    res.send(layout("Ops", `
      <h1>Operations</h1>
      ${liqCard}
      <div class="section">
        <h1 style="font-size:15px">Scheduled jobs</h1>
        <p class="sub" style="margin-bottom:8px">pg_cron does not retry, silently skips overlapping runs, and raises no alerts — this table is the only visibility.</p>
        <table><tr><th>Job</th><th>Schedule</th><th>Last run</th><th>Status</th><th>Error</th></tr>
        ${jobRows || `<tr><td colspan=5 class="sub">${jobErr ? esc(jobErr.message) : "No jobs found."}</td></tr>`}</table>
      </div>
      <div class="card">
        <div class="sb"><b>Notification queue backlog</b><b>${pendingJobs ?? 0}</b></div>
        <div class="sub">Unprocessed follower fan-out jobs. Should hover near zero; a growing number means the worker isn't running.</div>
      </div>`, "ops"));
  } catch (e) { next(e); }
});

// ── settings (platform fee toggle) ─────────────────────────────────
app.get("/settings", requireAuth, async (_req, res, next) => {
  try {
    const { data: s } = await db.from("platform_settings")
      .select("*")
      .eq("id", 1).maybeSingle();

    const status = s?.fees_enabled
      ? `<span class="badge ok">FEES ON</span>`
      : `<span class="badge">FEES OFF · platform is free</span>`;

    res.send(layout("Settings", `
      <h1>Platform settings</h1>
      <div class="card section">
        <div class="row" style="justify-content:space-between">
          <div>
            <b>Platform revenue</b> ${status}
            <div class="sub">Booking fee ${s?.booking_fee_azn ?? "1.50"} ₼/seat · parcel cut ${s?.parcel_platform_pct ?? 10}% · last changed ${fmtDate(s?.updated_at)}</div>
          </div>
          <form method="post" action="/settings/toggle-fees" class="inline">
            <input type="hidden" name="to" value="${s?.fees_enabled ? "off" : "on"}">
            <button class="btn ${s?.fees_enabled ? "dgr" : ""}">Turn ${s?.fees_enabled ? "OFF" : "ON"}</button>
          </form>
        </div>
      </div>
      <div class="card">
        <b>How the toggle works</b>
        <div class="sub" style="margin-top:6px">
          OFF: new bookings get fee_amount=0 and parcel platform cut=0. Riders pay drivers directly in cash (or the seat price on card); SameWay makes nothing. Existing in-flight charges keep flowing — the flip only affects new bookings and new parcel charges.<br><br>
          ON: bookings stamp the configured fee per seat, payments-watcher charges it online, and parcel charges take the configured %. Toggle takes effect on the very next booking (create_booking reads this row fresh each time).
        </div>
      </div>
      <form method="post" action="/settings/fees" class="card section">
        <b>Fee amounts</b> <span class="sub">(only used when fees are ON)</span>
        <div class="row" style="margin-top:10px">
          <label>Booking fee (AZN/seat)
            <input type="text" name="booking_fee_azn" value="${s?.booking_fee_azn ?? "1.50"}">
          </label>
          <label>Parcel platform cut (%)
            <input type="text" name="parcel_platform_pct" value="${s?.parcel_platform_pct ?? 10}">
          </label>
        </div>
        <div style="margin-top:10px"><button class="btn ghost">Save amounts</button></div>
      </form>

      <form method="post" action="/settings/pricing" class="card section">
        <b>Cost-share ceiling parameters</b>
        <div class="sub" style="margin:6px 0 10px">
          These set the <b>maximum</b> a driver may charge per seat — the mechanism that keeps SameWay a cost-sharing platform rather than an unlicensed taxi service. Drivers cannot publish above the computed ceiling. Raising the multiplier above ~1.5 weakens the non-profit argument; don't, without legal advice. Per-country overrides live on the Markets page. See <code>docs/pricing-and-legal.md</code>.
        </div>
        <div class="row">
          <label>Fuel price (AZN/L)
            <input type="text" name="fuel_price_per_litre" value="${s?.fuel_price_per_litre ?? "1.200"}">
          </label>
          <label>Consumption (L/100km)
            <input type="text" name="fuel_consumption_l_100km" value="${s?.fuel_consumption_l_100km ?? "8.00"}">
          </label>
          <label>Vehicle wear (AZN/km)
            <input type="text" name="vehicle_wear_per_km" value="${s?.vehicle_wear_per_km ?? "0.080"}">
          </label>
          <label>Ceiling multiplier
            <input type="text" name="price_ceiling_multiplier" value="${s?.price_ceiling_multiplier ?? "1.25"}">
          </label>
        </div>
        <div style="margin-top:10px"><button class="btn ghost">Save pricing</button></div>
      </form>

      <form method="post" action="/settings/gate" class="card section">
        <b>Fee activation thresholds</b>
        <div class="sub" style="margin:6px 0 10px">Liquidity levels the corridor should reach before switching fees on. Current progress is on the <a href="/ops" style="color:var(--az)">Ops</a> page.</div>
        <div class="row">
          <label>Min rides / day
            <input type="text" name="fee_gate_min_daily_rides" value="${s?.fee_gate_min_daily_rides ?? 20}">
          </label>
          <label>Min fill rate (0–1)
            <input type="text" name="fee_gate_min_fill_rate" value="${s?.fee_gate_min_fill_rate ?? "0.60"}">
          </label>
        </div>
        <div style="margin-top:10px"><button class="btn ghost">Save thresholds</button></div>
      </form>`, "set"));
  } catch (e) { next(e); }
});

app.post("/settings/toggle-fees", requireAuth, async (req, res, next) => {
  try {
    const on = String(req.body.to || "") === "on";
    await db.from("platform_settings")
      .update({ fees_enabled: on }).eq("id", 1);
    res.redirect("/settings");
  } catch (e) { next(e); }
});

app.post("/settings/fees", requireAuth, async (req, res, next) => {
  try {
    const fee = Number(req.body.booking_fee_azn);
    const pct = parseInt(String(req.body.parcel_platform_pct), 10);
    const patch = {};
    if (Number.isFinite(fee) && fee >= 0) patch.booking_fee_azn = fee;
    if (Number.isInteger(pct) && pct >= 0 && pct <= 50) patch.parcel_platform_pct = pct;
    if (Object.keys(patch).length) {
      await db.from("platform_settings").update(patch).eq("id", 1);
    }
    res.redirect("/settings");
  } catch (e) { next(e); }
});

// ── errors ─────────────────────────────────────────────────────────
// ── table admin (auto-CRUD for every table, the Django-admin
// equivalent) — mounted at /data, separate login-free-standing UI
// (AdminJS's own React frontend), gated by the same ADMIN_PASSWORD.
// See docs/data-admin.md for the safety model (which tables are full
// CRUD vs read-only vs hidden) and the real bug this had to work
// around in @adminjs/sql.
await mountDataAdmin(app);

app.use((err, _req, res, _next) => {
  console.error(err);
  res.status(500).send(layout("Error", `<h1>Something broke</h1><pre class="sub">${esc(err.message)}</pre>`));
});

app.listen(Number(PORT), HOST, () =>
  console.log(`SameWay admin on http://${HOST}:${PORT} (${HOST === "127.0.0.1" ? "tunnel-only" : "public"})`));
