// Payment provider abstraction. PAYMENTS_MODE=sandbox (default) settles
// everything instantly with deterministic txn ids so the whole money
// flow — parcel prepay, booking fee, refund queue — is testable today
// with zero external credentials. Switching to Epoint later means
// implementing the two methods below against their API and setting
// PAYMENTS_MODE=epoint; nothing else in the system changes.

export interface ChargeParams {
  amountAzn: number;
  payerId: string;
  reference: string; // deterministic per subject, e.g. parcel:<id> / fee:<booking id>
}

export interface RefundParams {
  amountAzn: number;
  originalProviderTxnId: string | null;
  reference: string;
}

export interface PayoutParams {
  amountAzn: number;
  driverId: string;
  reference: string; // deterministic, e.g. payout:<payouts.id>
}

export interface PaymentResult {
  ok: boolean;
  providerTxnId: string;
  error?: string;
}

export interface PaymentProvider {
  name: string;
  charge(p: ChargeParams): Promise<PaymentResult>;
  refund(p: RefundParams): Promise<PaymentResult>;
  payout(p: PayoutParams): Promise<PaymentResult>;
}

class SandboxProvider implements PaymentProvider {
  name = "sandbox";
  // Deterministic ids + the txn_provider_uq unique index make retries
  // naturally idempotent: a duplicate insert simply fails and the row
  // that already exists wins.
  charge(p: ChargeParams): Promise<PaymentResult> {
    return Promise.resolve({ ok: true, providerTxnId: `sbx_${p.reference}` });
  }
  refund(p: RefundParams): Promise<PaymentResult> {
    return Promise.resolve({ ok: true, providerTxnId: `sbx_rf_${p.reference}` });
  }
  payout(p: PayoutParams): Promise<PaymentResult> {
    return Promise.resolve({ ok: true, providerTxnId: `sbx_po_${p.reference}` });
  }
}

class EpointProvider implements PaymentProvider {
  name = "epoint";
  // ── TODO (fill from Epoint API docs before flipping PAYMENTS_MODE) ──
  // 1. Endpoints: card-storage charge (token payments) + refund + payout.
  //    Epoint supports 24/7 payouts to any AZ bank card per the tech doc.
  // 2. Signature: Epoint uses base64(json) + signature over
  //    private_key + data + private_key (verify exact scheme in docs).
  // 3. Env: EPOINT_PUBLIC_KEY, EPOINT_PRIVATE_KEY (set via
  //    `supabase secrets set`).
  // 4. Map their response codes → PaymentResult.
  // 5. For checkout-style payments (screen 46 with a new card), the
  //    client opens Epoint's page and the epoint-webhook function (to
  //    be added) confirms — this provider handles saved-token charges.
  // 6. Payout needs the driver's payout method on file (bank card per
  //    settings screen SE-40) — fetch it inside this method or pass it
  //    in via PayoutParams once that lookup is wired.
  private key = Deno.env.get("EPOINT_PUBLIC_KEY");
  charge(_p: ChargeParams): Promise<PaymentResult> {
    return Promise.resolve({
      ok: false,
      providerTxnId: "",
      error: "epoint_not_configured — see TODO in _shared/payments.ts",
    });
  }
  refund(_p: RefundParams): Promise<PaymentResult> {
    return Promise.resolve({
      ok: false,
      providerTxnId: "",
      error: "epoint_not_configured — see TODO in _shared/payments.ts",
    });
  }
  payout(_p: PayoutParams): Promise<PaymentResult> {
    return Promise.resolve({
      ok: false,
      providerTxnId: "",
      error: "epoint_not_configured — see TODO in _shared/payments.ts",
    });
  }
}

export function provider(): PaymentProvider {
  return (Deno.env.get("PAYMENTS_MODE") ?? "sandbox") === "epoint"
    ? new EpointProvider()
    : new SandboxProvider();
}
