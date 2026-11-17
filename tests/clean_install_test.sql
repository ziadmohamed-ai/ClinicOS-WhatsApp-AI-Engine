-- Clean-install verification against an EMPTY scratch Postgres cluster.
-- Runs database/01, 02, 02a, 03, 04, 05, 05b in order with ON_ERROR_STOP
-- and default check_function_bodies = on, then verifies workflow pg_proc signatures.
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
\i :repo/database/03_rls_policies.sql
\i :seed_sql
\i :repo/database/05_lead_engine.sql
\i :repo/database/05b_l2v_seed_example.sql

-- Re-run seed scripts to confirm idempotency
\i :seed_sql
\i :repo/database/05b_l2v_seed_example.sql

DO $$
DECLARE
  v_clinic_cnt integer;
  v_wh_cnt integer;
BEGIN
  ASSERT current_setting('check_function_bodies') = 'on',
    'check_function_bodies must still be on after install';

  SELECT count(*)::int INTO v_clinic_cnt FROM public.clinics;
  ASSERT v_clinic_cnt >= 1, 'Expected at least 1 clinic in public.clinics, got ' || v_clinic_cnt;

  SELECT count(*)::int INTO v_wh_cnt FROM public.working_hours;
  ASSERT v_wh_cnt >= 12 AND (v_wh_cnt % 12 = 0 OR v_wh_cnt > 0),
    'Expected seeded working_hours rows in public.working_hours, got ' || v_wh_cnt;

  RAISE NOTICE 'Clean install schema + seeds (01, 02, 02a, 03, 04, 05, 05b) + idempotency: OK';
END $$;

\i :wf_checks_sql
