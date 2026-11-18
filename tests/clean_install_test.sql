-- Clean-install verification against an EMPTY scratch Postgres cluster.
-- Runs database/01, 02, 02a, 03, 04 (or generated clinic seed), 05, 05b in order with ON_ERROR_STOP
-- and default check_function_bodies = on, verifies log_workflow_error single-clinic resolution,
-- verifies cross-clinic RLS isolation for clinicos_api_owner, and verifies workflow pg_proc signatures.
\set ON_ERROR_STOP on

DO $$ BEGIN
  ASSERT current_setting('check_function_bodies') = 'on',
    'check_function_bodies must remain on (got ' || current_setting('check_function_bodies') || ')';
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')                 THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated')        THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role')         THEN CREATE ROLE service_role NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'clinicos_api_owner')   THEN CREATE ROLE clinicos_api_owner NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'clinicos_n8n_runtime') THEN CREATE ROLE clinicos_n8n_runtime NOLOGIN; END IF;
END $$;

-- Stub Supabase Vault view referenced by private.get_clinicos_meta_secret (LANGUAGE sql)
CREATE SCHEMA IF NOT EXISTS vault;
CREATE TABLE IF NOT EXISTS vault.decrypted_secrets (
  name TEXT PRIMARY KEY,
  decrypted_secret TEXT
);

\i :repo/database/01_schema.sql
\i :repo/database/02_booking_and_outbox_rpcs.sql
\i :step_02a
\i :rls_sql

-- T9: Before any clinic row exists (0 clinics), log_workflow_error must raise a clear error (never fall back to a fixed UUID)
DO $$
BEGIN
  BEGIN
    PERFORM public.log_workflow_error('ClinicOS - Main Engine', 'exec-0', 'NodeA', 'TestError');
    RAISE EXCEPTION 'Expected log_workflow_error to fail when 0 clinics exist';
  EXCEPTION WHEN raise_exception THEN
    ASSERT sqlerrm LIKE '%requires exactly 1 clinic row%found 0%',
      'Unexpected 0-clinic error from log_workflow_error: ' || sqlerrm;
  END;
END $$;

\i :seed_sql
\i :repo/database/05_lead_engine.sql
\i :repo/database/05b_l2v_seed_example.sql

-- Re-run seed scripts to confirm idempotency
\i :seed_sql
\i :repo/database/05b_l2v_seed_example.sql

SELECT pg_catalog.set_config('clinicos.test_clinic_id', :'clinic_id', false);

DO $$
DECLARE
  v_target_clinic uuid := current_setting('clinicos.test_clinic_id')::uuid;
  v_clinic_cnt integer;
  v_wh_cnt integer;
  v_log_res jsonb;
  v_snap jsonb;
  v_other_clinic uuid := 'ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid;
  v_other_prov uuid := 'ffffffff-ffff-4fff-8fff-fffffffffff1'::uuid;
  v_other_svc uuid := 'ffffffff-ffff-4fff-8fff-fffffffffff2'::uuid;
  v_other_contact uuid;
  v_other_conv uuid;
BEGIN
  ASSERT current_setting('check_function_bodies') = 'on',
    'check_function_bodies must still be on after install';

  SELECT count(*)::int INTO v_clinic_cnt FROM public.clinics;
  ASSERT v_clinic_cnt = 1, 'Expected exactly 1 clinic in public.clinics, got ' || v_clinic_cnt;

  SELECT count(*)::int INTO v_wh_cnt FROM public.working_hours WHERE clinic_id = v_target_clinic;
  ASSERT v_wh_cnt = 12, 'Expected 12 idempotent working_hours rows for clinic, got ' || v_wh_cnt;

  -- T9: With 1 clinic row, log_workflow_error succeeds and logs against that clinic
  v_log_res := public.log_workflow_error('ClinicOS - Main Engine', 'exec-1', 'NodeA', 'TestError');
  ASSERT (v_log_res ->> 'ok')::boolean = true, 'Expected log_workflow_error ok=true on 1-clinic DB';
  ASSERT (SELECT clinic_id FROM public.system_events WHERE id = (v_log_res ->> 'event_id')::bigint) = v_target_clinic,
    'log_workflow_error must attribute event to the single clinic';

  -- T9: Verify get_clinic_snapshot returns non-empty timezone and utc_offset
  v_snap := public.get_clinic_snapshot(v_target_clinic);
  ASSERT coalesce(v_snap ->> 'timezone', '') <> '' AND coalesce(v_snap ->> 'utc_offset', '') ~ '^[+-][0-9]{2}:[0-9]{2}$',
    'get_clinic_snapshot must return timezone and utc_offset, got ' || coalesce(v_snap::text, 'null');

  -- Insert a foreign 2nd clinic to test: (a) log_workflow_error rejects >1 clinics, and (b) RLS hides foreign clinic rows in DO/role block below
  INSERT INTO public.clinics (id, name, timezone, settings)
  VALUES (v_other_clinic, 'Foreign Clinic B', 'Africa/Cairo', '{}'::jsonb);

  -- Upgrade v4: a clinic without settings.emergency_number must get NULL (never a guessed national number)
  ASSERT (public.get_clinic_snapshot(v_other_clinic) -> 'emergency_number') = 'null'::jsonb,
    'get_clinic_snapshot must return emergency_number = null when the clinic has not configured one';

  BEGIN
    PERFORM public.log_workflow_error('ClinicOS - Main Engine', 'exec-2', 'NodeB', 'TestError');
    RAISE EXCEPTION 'Expected log_workflow_error to fail when 2 clinics exist';
  EXCEPTION WHEN raise_exception THEN
    ASSERT sqlerrm LIKE '%requires exactly 1 clinic row%found 2%',
      'Unexpected 2-clinic error from log_workflow_error: ' || sqlerrm;
  END;

  INSERT INTO public.providers (id, clinic_id, name, specialty, active)
  VALUES (v_other_prov, v_other_clinic, 'Foreign Doctor', 'Dental', true);

  INSERT INTO public.services (id, clinic_id, code, name_ar, name_en, duration_minutes, price, active)
  VALUES (v_other_svc, v_other_clinic, 'FOREIGN_SVC', 'خدمة أخرى', 'Foreign Service', 30, 100, true);

  INSERT INTO public.contacts (clinic_id, phone_e164, name)
  VALUES (v_other_clinic, '+201999999999', 'Foreign Patient')
  RETURNING id INTO v_other_contact;

  INSERT INTO public.conversations (clinic_id, contact_id, status)
  VALUES (v_other_clinic, v_other_contact, 'bot')
  RETURNING id INTO v_other_conv;

  INSERT INTO public.messages (clinic_id, conversation_id, direction, body)
  VALUES (v_other_clinic, v_other_conv, 'in', 'hello foreign');

  INSERT INTO public.appointments (clinic_id, contact_id, provider_id, service_id, starts_at, ends_at, status)
  VALUES (v_other_clinic, v_other_contact, v_other_prov, v_other_svc, now() + interval '5 days', now() + interval '5 days 30 minutes', 'confirmed');

  INSERT INTO public.outbox (clinic_id, contact_id, kind, payload, idempotency_key)
  VALUES (v_other_clinic, v_other_contact, 'text', '{"text":"foreign"}'::jsonb, 'foreign-outbox-1');

  INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
  VALUES (v_other_clinic, 'error', 'test', 'foreign_evt', '{}'::jsonb);

  RAISE NOTICE 'Clean install schema + seeds (01, 02, 02a, 03, 04, 05, 05b) + idempotency + log_workflow_error guards: OK';
END $$;

-- T9 RLS isolation test: clinicos_api_owner must see ONLY :clinic_id rows and ZERO rows of Foreign Clinic B
SET ROLE clinicos_api_owner;
DO $$
DECLARE
  v_target_clinic uuid := current_setting('clinicos.test_clinic_id')::uuid;
  v_other_clinic uuid := 'ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid;
BEGIN
  ASSERT (SELECT count(*) FROM public.clinics WHERE id = v_target_clinic) = 1, 'RLS: target clinic visible';
  ASSERT (SELECT count(*) FROM public.clinics WHERE id = v_other_clinic) = 0, 'RLS: foreign clinic hidden';
  ASSERT (SELECT count(*) FROM public.providers WHERE clinic_id = v_other_clinic) = 0, 'RLS: foreign providers hidden';
  ASSERT (SELECT count(*) FROM public.services WHERE clinic_id = v_other_clinic) = 0, 'RLS: foreign services hidden';
  ASSERT (SELECT count(*) FROM public.contacts WHERE clinic_id = v_other_clinic) = 0, 'RLS: foreign contacts hidden';
  ASSERT (SELECT count(*) FROM public.conversations WHERE clinic_id = v_other_clinic) = 0, 'RLS: foreign conversations hidden';
  ASSERT (SELECT count(*) FROM public.messages WHERE clinic_id = v_other_clinic) = 0, 'RLS: foreign messages hidden';
  ASSERT (SELECT count(*) FROM public.appointments WHERE clinic_id = v_other_clinic) = 0, 'RLS: foreign appointments hidden';
  ASSERT (SELECT count(*) FROM public.outbox WHERE clinic_id = v_other_clinic) = 0, 'RLS: foreign outbox hidden';
  ASSERT (SELECT count(*) FROM public.system_events WHERE clinic_id = v_other_clinic) = 0, 'RLS: foreign system_events hidden';

  BEGIN
    INSERT INTO public.contacts (clinic_id, phone_e164, name)
    VALUES (v_other_clinic, '+201888888888', 'Cross-Tenant Write Attempt');
    RAISE EXCEPTION 'RLS allowed clinicos_api_owner to insert into foreign clinic!';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  RAISE NOTICE 'RLS cross-clinic isolation (second clinic invisible & unwritable for clinicos_api_owner): OK';
END $$;
RESET ROLE;

DELETE FROM public.clinics WHERE id = 'ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid;

\i :wf_checks_sql
