// payments-watcher — the money loop, run on a schedule (every minute).
// Four passes, all idempotent:
//   1. Accepted parcels with no settled charge → charge sender (prepaid
//      rule), mark parcel paid. Platform keeps PARCEL_PLATFORM_PCT
//      (default 10%), driver gets the rest — the 5 ₼ → 4.50 ₼ split
//      shown on screen 51.
//   2. Confirmed bookings with fee_amount > 0 and no fee charge →
//      charge, then record via the record_booking_fee() RPC from 004.
//      (Fee launches at 0 ₼ so this pass is dormant until a corridor
//      flips it on — the machinery gets exercised in sandbox anyway.)
//   3. Pending refund rows (queued by the 004 trigger when fee-bearing
//      bookings die) → execute refund, settle the row.
//   4. Pending payout rows (created weekly by batch_driver_payouts(),
//      006) → execute via the provider, flip to 'sent' or 'failed'.
import { serviceClient } from "../_shared/service.ts";
import { provider } from "../_shared/payments.ts";

Deno.serve(async (_req) => {
  const db = serviceClient();
  const pay = provider();

  // Read the platform-level fee setting. Falls back to env for local
  // dev where the settings table may not exist yet.
  const { data: settings } = await db
    .from("platform_settings")
    .select("fees_enabled, parcel_platform_pct")
    .eq("id", 1)
    .maybeSingle();
  const feesOn = settings?.fees_enabled ?? false;
  const pct = feesOn
    ? (settings?.parcel_platform_pct ?? Number(Deno.env.get("PARCEL_PLATFORM_PCT") ?? "10"))
    : 0;

  const out = { parcels: 0, fees: 0, refunds: 0, payouts: 0, errors: [] as string[] };

  // ── 1 · parcel charges ────────────────────────────────────────────
  const { data: parcels, error: pErr } = await db
    .from("parcels")
    .select("id, sender_id, price, ride_id, rides!inner(driver_id)")
    .eq("status", "accepted")
    .neq("payment_status", "paid");
  if (pErr) out.errors.push(`parcels query: ${pErr.message}`);

  for (const p of parcels ?? []) {
    const driverId = (p as any).rides.driver_id as string;
    const res = await pay.charge({
      amountAzn: p.price,
      payerId: p.sender_id,
      reference: `parcel:${p.id}`,
    });
    if (!res.ok) { out.errors.push(`parcel ${p.id}: ${res.error}`); continue; }

    const amountPlatform = Number((p.price * pct / 100).toFixed(2));
    const { error: tErr } = await db.from("transactions").insert({
      parcel_id: p.id,
      payer_id: p.sender_id,
      driver_id: driverId,
      provider: pay.name,
      provider_txn_id: res.providerTxnId,
      type: "charge",
      amount_total: p.price,
      amount_driver: Number((p.price - amountPlatform).toFixed(2)),
      amount_platform: amountPlatform,
      status: "settled",
      settled_at: new Date().toISOString(),
    });
    // Unique (provider, provider_txn_id) absorbs retries — a duplicate
    // insert error here means a previous run already settled it.
    if (!tErr) {
      await db.from("parcels").update({ payment_status: "paid" }).eq("id", p.id);
      out.parcels++;
    } else if (!tErr.message.includes("duplicate")) {
      out.errors.push(`parcel txn ${p.id}: ${tErr.message}`);
    }
  }

  // ── 2 · booking fees ──────────────────────────────────────────────
  const { data: feeBookings, error: fErr } = await db
    .from("bookings")
    .select("id, lead_passenger_id, fee_amount")
    .eq("status", "confirmed")
    .gt("fee_amount", 0);
  if (fErr) out.errors.push(`fee query: ${fErr.message}`);

  for (const b of feeBookings ?? []) {
    const { data: existing } = await db
      .from("transactions")
      .select("id")
      .eq("booking_id", b.id)
      .eq("type", "charge")
      .limit(1);
    if (existing && existing.length > 0) continue;

    const res = await pay.charge({
      amountAzn: b.fee_amount,
      payerId: b.lead_passenger_id,
      reference: `fee:${b.id}`,
    });
    if (!res.ok) { out.errors.push(`fee ${b.id}: ${res.error}`); continue; }

    const { error: rpcErr } = await db.rpc("record_booking_fee", {
      p_booking: b.id,
      p_provider_txn: res.providerTxnId,
    });
    if (rpcErr) out.errors.push(`fee rpc ${b.id}: ${rpcErr.message}`);
    else out.fees++;
  }

  // ── 3 · refund queue ──────────────────────────────────────────────
  const { data: refunds, error: rErr } = await db
    .from("transactions")
    .select("id, booking_id, amount_platform")
    .eq("type", "refund")
    .eq("status", "pending");
  if (rErr) out.errors.push(`refund query: ${rErr.message}`);

  for (const r of refunds ?? []) {
    const { data: orig } = await db
      .from("transactions")
      .select("provider_txn_id")
      .eq("booking_id", r.booking_id)
      .eq("type", "charge")
      .limit(1)
      .maybeSingle();

    const res = await pay.refund({
      amountAzn: r.amount_platform,
      originalProviderTxnId: orig?.provider_txn_id ?? null,
      reference: `refund:${r.id}`,
    });
    if (!res.ok) { out.errors.push(`refund ${r.id}: ${res.error}`); continue; }

    await db.from("transactions").update({
      provider_txn_id: res.providerTxnId,
      status: "settled",
      settled_at: new Date().toISOString(),
    }).eq("id", r.id);
    out.refunds++;
  }

  // ── 4 · payouts ────────────────────────────────────────────────────
  const { data: payoutRows, error: poErr } = await db
    .from("payouts")
    .select("id, driver_id, amount")
    .eq("status", "pending");
  if (poErr) out.errors.push(`payout query: ${poErr.message}`);

  // Note: if this function crashes between the 'processing' write and
  // the provider response, a payout can get stuck in 'processing'
  // forever (no longer picked up by the `pending` filter above). Not
  // handled here — add a "stuck >1h in processing" sweep before this
  // runs unattended at real volume; fine for now at sandbox/test scale.
  for (const p of payoutRows ?? []) {
    await db.from("payouts").update({ status: "processing" }).eq("id", p.id);

    const res = await pay.payout({
      amountAzn: p.amount,
      driverId: p.driver_id,
      reference: `payout:${p.id}`,
    });

    if (!res.ok) {
      await db.from("payouts").update({ status: "failed" }).eq("id", p.id);
      out.errors.push(`payout ${p.id}: ${res.error}`);
      continue;
    }
    await db.from("payouts")
      .update({ status: "sent", provider_payout_id: res.providerTxnId })
      .eq("id", p.id);
    out.payouts++;
  }

  return new Response(JSON.stringify(out), {
    headers: { "content-type": "application/json" },
    status: out.errors.length ? 207 : 200,
  });
});
