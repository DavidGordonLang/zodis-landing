-- Remove the preview-only capacity test helper after controlled validation.
drop function if exists public.beta_submit_request_testcap(text,text,text,integer);
