# Žodis Beta 3 onboarding — activation runbook

Status: controlled backend validation is complete. The core schema/RPC migration
and dormant `beta-signup` Edge Function are live in the active Supabase project,
but the public landing page still uses the legacy direct INSERT path. Do not merge
the landing PR, apply the final cutover migration, or start the retry worker until
David approves the production checkpoint. No historical request is replayed or admitted.

## Components

- `migrations/20260927142652_beta3_onboarding_automation.sql` extends
  `beta_requests` and adds three service-role-only RPCs while deliberately
  leaving the current landing-page INSERT policy intact for controlled testing.
- `migrations/20260927183000_beta3_onboarding_cutover.sql` is the explicit
  production switch: it removes the legacy direct anonymous INSERT path only
  after final approval. An advisory transaction lock serialises the cap
  decision. The two existing owner addresses are excluded from the external
  tester count. Existing requests and allowlist rows return the neutral
  `received` result without a new email or status change.
- `functions/beta-signup/index.ts` accepts public form POSTs only from
  `https://www.zodis.app` and `https://zodis.app`, calls the RPC through the server-only
  service role, and attempts both deliveries. A separate worker invocation
  authenticated by `BETA_WORKER_SECRET` drains pending/failed jobs. Set
  `verify_jwt = false` for this public endpoint; the handler checks the origin
  and separate worker secret. The browser contains neither provider keys nor
  the service role key.
- Each channel has pending/sending/sent/failed, attempts, timestamps, a claim
  token and an error. Stale claims can be retried after ten minutes. Resend
  uses a deterministic `Idempotency-Key` per request and status. Its 24-hour
  key retention means an ambiguous attempt older than 23 hours is stopped for
  human review; do not manually resend before checking provider logs.
  Discord webhooks do not provide equivalent exactly-once delivery; an
  ambiguous timeout can result in a repeated notification.
- Suppressed addresses retain the decision but cannot be claimed for email.
  Suppression is an operational admin action, never a public delete endpoint.

## Required configuration before activation

1. Verify `zodis.app` in Resend with DNS records at the authoritative provider;
   preserve unrelated records and nameservers. Create a send-only key.
2. Verify the Žodis signup Discord channel and configure its webhook.
3. Create a Cloudflare Turnstile **Managed** widget named `Žodis Beta signup`
   for both `zodis.app` and `www.zodis.app`. Replace the
   `__TURNSTILE_SITE_KEY__` placeholder in `index.html` with its public
   sitekey. Store its private secret only as the Supabase Edge Function secret
   `TURNSTILE_SECRET_KEY`. The function validates Siteverify success, hostname
   and the `beta-signup` action before any admission decision.
4. Configure Supabase Edge Function secrets `RESEND_API_KEY`,
   `DISCORD_BETA_WEBHOOK_URL`, and `BETA_WORKER_SECRET`. The runtime already
   supplies `SUPABASE_URL` and `SUPABASE_SECRET_KEYS`. Never put values in
   this repository or a PR.
5. Store the same `BETA_WORKER_SECRET` value encrypted in Vault as
   `beta_worker_secret`. After the function is deployed, apply
   `20260927162547_beta3_retry_worker.sql` to enable `pg_cron` and `pg_net`
   and call the worker every five minutes. The cron job reads its header from
   Vault at run time. Monitor `beta_requests` rows in `failed` or
   `sending` state and alert on four exhausted attempts. The worker can be
   invoked manually with the same secret after resolving a provider outage.
6. Before cutover, it is safe to deploy the function and apply the core
   onboarding migration for controlled validation because the current direct
   landing INSERT remains available.
7. At the approved cutover: merge/deploy the landing PR, apply
   `20260927183000_beta3_onboarding_cutover.sql`, apply the retry migration,
   then verify the live form. This sequencing avoids a deliberate signup outage.

## Validation gate

Use only controlled addresses belonging to David. On an isolated database or
in a transaction that is rolled back, test: under cap, case-folded duplicate,
pre-existing allowlist, 100/100 waitlist, two concurrent last-place
transactions, and no changes to owners. Never seed 99 fake live users.

Test Turnstile with the real production widget plus Cloudflare's official
test credentials where appropriate; verify missing/invalid/replayed tokens are
rejected before the admission RPC is called. Test actual Resend and Discord
delivery with a controlled alias, check one
Resend provider ID and one Discord message, then repeat the request and retry
worker to verify no second email. Simulate a provider failure, inspect the
persisted failure and retry to sent. Check suppression. Sign in to the app
with that same address and confirm the existing allowlist gate; a different
address must remain blocked. Confirm both landing outcomes, current build,
RLS and that the browser receives no secret. Do not touch real historical
applicants or recruit users during validation.

## Email copy

Welcome subject: `You're in the Žodis Beta`

> Hi,
>
> You're in the Žodis Beta. Open the app at https://learning-lithuanian.vercel.app and sign in with the same email address you used to request access.
>
> To add it to your phone: https://www.zodis.app/setup/
> A quick guide: https://www.zodis.app/userguide/
>
> This is a small beta, and I'd love to hear what works or feels confusing. Just reply to this email. I'm learning Lithuanian too, so honest feedback really helps.
>
> David

Waitlist subject: `Your Žodis Beta waitlist place`

> Hi,
>
> Thanks for asking to try Žodis. The current Beta is full, but I've recorded your place on the waitlist. I'll be in touch when a place opens up.
>
> I'm learning Lithuanian too and really appreciate your interest.
>
> David

From: `David from Žodis <hello@zodis.app>`; Reply-To:
`davidgordonlang@gmail.com`. These are operational messages only.


## Validation results

Controlled live validation completed 27 Sep 2026:

- real under-cap admission: passed; one request, one allowlist row, one Resend welcome, one Discord notification
- duplicate submission/recovery: passed; no duplicate request/allowlist row and no duplicate welcome email
- same-email app access: passed with email OTP
- real waitlist path: passed; waitlisted address was not allowlisted and received one waitlist email + one Discord notification
- true concurrent last-slot race: passed with overlapping requests; advisory lock serialized admission and prevented over-cap admission
- provider failure/retry: passed for Discord and email; failed state persisted, retry moved to sent, completed delivery was not sent again
- suppression: passed; suppressed pending email was not claimed
- missing/invalid Turnstile token: both rejected with HTTP 403 before any request row was created
- preview-only cap/origin/helper paths were removed after validation
- retry scheduler preflight: corrected non-relocatable extension install syntax; `pg_net` and `pg_cron` installed successfully, a named five-minute cron job was created and verified, then unscheduled and both extensions removed again

The remaining production actions are the approved landing merge, final cutover migration, retry-worker migration/schedule, and post-cutover smoke verification.
