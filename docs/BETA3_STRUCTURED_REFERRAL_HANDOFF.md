# Beta 3 structured signup referral — review branch

This change is prepared for review. It has **not** been deployed to zodis.app, the live Edge Function, or production Supabase. The production request/admission/delivery path is unchanged.

## Behaviour
- Nine required dropdown options with stable `referralSource` values, plus an optional 200-character detail only for Other.
- The new Edge Function validates source and detail before Turnstile/RPC, derives a human-readable `note`, and passes canonical fields to a five-argument service-only RPC. It continues to set technical `source = 'zodis.app'`.
- The original three-argument RPC remains service-only as an intentional legacy wrapper during rollout. The Edge Function chooses it only when `referralSource` is absent; a present invalid value is rejected, never downgraded to legacy.
- Two nullable columns leave historical `note` values untouched. The new source/detail checks constrain non-null values. Duplicate lookup precedes insertion, so an existing row's referral is not overwritten.
- Discord still reads the existing human-readable `note` and technical `source`. Resend, Turnstile, admission lock/cap, allowlist and retry worker code were not edited.

## Controlled promotion order — only after explicit approval
1. Verify migration and new RPC on an isolated Supabase branch/test database. Check the old three-argument RPC and new five-argument RPC, source constraints, RLS and grants. Do not seed production.
2. Apply the reviewed migration to production. The old website and old Edge Function continue using the three-argument RPC.
3. Deploy the new Edge Function with `referrals.mjs` included in its bundle. Verify legacy free-text form submissions still work before touching the website. Ensure PostgREST sees the new five-argument signature.
4. Deploy the reviewed website. Cached/in-flight old forms continue through the legacy three-argument path. New forms must be published **after** the backend is confirmed ready so every new-form request stores structured referral fields; the `note` payload also keeps an old Edge Function from rejecting a new-form request during a transient rollback.
5. After approval, use David's specified +test2 address for one real Turnstile-secured Reddit smoke test. Verify the row, allowlist, single welcome email and Discord ping, then remove only that test row and allowlist entry. Never remove learner rows.

## Verification gate before merging/promotion
- Run `node --test tests/structuredReferral.test.mjs`, the full repository test suite (if configured), Edge Function checks, migration dry-run, build/HTML validation and `git diff --check`.
- Check dropdown and Other input at mobile and desktop widths in light and dark themes.
- Test an existing cached old form against new backend, all nine values, Other blank/nonblank, invalid source, 200/201 characters, duplicate and already allowlisted email, 100-user cap and concurrent last slot, Origin/Turnstile/honeypot/request-size checks, and unchanged email/Discord retry paths.

This review branch intentionally does not add UTM/referrer acquisition data or learner-app changes.
