# Žodis Beta 3 onboarding — activation runbook

Status: branch only. Do not apply the migration, deploy the function, switch the
landing page, or start the retry worker until David approves the production
checkpoint. No historical request is replayed or admitted.

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
- `functions/beta-signup/index.ts` accepts a public form POST from the
  canonical `https://www.zodis.app`, calls the RPC through the server-only
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

## Controlled preview testing

During pre-cutover validation only, the Edge Function also accepts the exact Vercel branch-preview origin `https://zodis-landing-git-codex-beta3-o-f88ddc-davids-projects-25f8617a.vercel.app`, and Turnstile hostname validation accepts the matching host. Remove this preview allowance before final production activation.
