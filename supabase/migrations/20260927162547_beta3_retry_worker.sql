-- Apply after beta-signup is deployed and David approves production activation.
-- The token is encrypted in Vault and read at each run; it is never in cron.job.
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'beta_worker_secret') then
    raise exception 'Vault secret beta_worker_secret must exist before scheduling';
  end if;
end $$;

select cron.schedule(
  'zodis-beta3-retry',
  '*/5 * * * *',
  $job$
    select net.http_post(
      url := 'https://gsxfdekilabnalxuqose.supabase.co/functions/v1/beta-signup',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-worker-secret',
        (select decrypted_secret from vault.decrypted_secrets where name = 'beta_worker_secret')
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 20000
    );
  $job$
);
