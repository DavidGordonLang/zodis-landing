-- Final Beta 3 signup cutover. Apply only after David explicitly approves activation.
-- This disables the legacy direct browser INSERT path after the Edge Function and
-- landing bundle are ready to take over. No public read policy is added.
drop policy if exists "landing page can submit beta requests" on public.beta_requests;
revoke insert on public.beta_requests from anon, authenticated;
