# Dev auth — phone sign-in with NO SMS provider

Decision (2026-07-23): SMS provider selection is deferred. Until one is
wired (Twilio vs a local AZ gateway — still open, see tech doc §7), we
use **test phone numbers with fixed OTPs**, so the mobile app's existing
`signInWithOtp` / `verifyOTP` flow works unchanged and nothing is sent.

## Hosted project (the one the app points at)

Supabase Dashboard → **Authentication** → sign-in providers → **Phone**:

1. Enable the Phone provider (leave the SMS provider fields empty /
   whichever provider is preselected — it won't be called for test numbers).
2. Find **Test phone numbers / Test OTPs** on that same Phone provider
   screen and add entries like:

   ```
   +994501234567 = 123456
   +994551234567 = 123456
   ```

3. Save.

Now in the app: enter `+994 50 123 45 67` → **Send code** succeeds
without any SMS → enter `123456` on the verify screen → session created,
`handle_new_user` trigger fires, users/preferences/verifications rows
appear. Repeat with the second number for a second test account
(driver + rider testing).

Notes
- Test numbers can sign in repeatedly; they behave like normal users in
  the database — delete their rows to reset.
- The verify screen accepts 4 *or* 6 digits; Supabase test OTPs are
  6-digit, which the screen already handles.
- Real numbers will still fail until an SMS provider is configured —
  that's expected and fine for now.

## Local development (`supabase start`)

`supabase/config.toml` in this repo ships the same two test numbers under
`[auth.sms.test_otp]`, so local stacks behave identically.

## When we pick a real SMS provider

Fill the provider credentials on the same dashboard screen (or in
config.toml for local), keep the test numbers for CI/dev, and nothing in
the mobile app changes.
