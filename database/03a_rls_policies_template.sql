-- =====================================================================
-- ClinicOS Row-Level Security (RLS) Policies — Supabase SQL Editor Template
-- (One Supabase Project per Clinic — Pure SQL alternative to 03_rls_policies.sql)
--
-- Instructions for Supabase SQL Editor (no psql required):
--   1. Copy the contents of this file into the Supabase SQL Editor.
--   2. Replace the single placeholder <CLINIC_UUID> below with your clinic's
--      UUID (printed as CLINIC_ID=<uuid> by scripts/new_clinic.sh, or from
--      SELECT id FROM public.clinics;).
--   3. Click "Run". If the placeholder is left unreplaced or is not a valid
--      UUID, this script fails closed with RAISE EXCEPTION.
-- =====================================================================

DO $$
DECLARE
  -- STEP 1: Replace the placeholder below with your clinic UUID:
  v_raw_clinic_id text := btrim('<CLINIC_UUID>');
  v_placeholder   text := '<' || 'CLINIC_UUID' || '>';
  v_clinic_id     uuid;
BEGIN
  IF v_raw_clinic_id = '' OR v_raw_clinic_id = v_placeholder OR position(v_placeholder in v_raw_clinic_id) > 0 THEN
    RAISE EXCEPTION 'Unreplaced placeholder % in database/03a_rls_policies_template.sql. Replace % with your clinic UUID before running in Supabase SQL Editor.', v_placeholder, v_placeholder;
  END IF;

  BEGIN
    v_clinic_id := v_raw_clinic_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Invalid clinic_id UUID "%" in database/03a_rls_policies_template.sql. Replace % with a valid clinic UUID.', v_raw_clinic_id, v_placeholder;
  END;

  ALTER TABLE public.clinics ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.providers ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.services ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.provider_services ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.working_hours ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.contacts ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.appointments ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.outbox ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.system_events ENABLE ROW LEVEL SECURITY;

  DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.clinics;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_clinic_scope ON public.clinics FOR SELECT TO clinicos_api_owner USING (id = (%L)::uuid)',
    v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.providers;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_clinic_scope ON public.providers FOR SELECT TO clinicos_api_owner USING (clinic_id = (%L)::uuid)',
    v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.services;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_clinic_scope ON public.services FOR SELECT TO clinicos_api_owner USING (clinic_id = (%L)::uuid)',
    v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.provider_services;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_clinic_scope ON public.provider_services FOR SELECT TO clinicos_api_owner USING (clinic_id = (%L)::uuid)',
    v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.working_hours;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_clinic_scope ON public.working_hours FOR SELECT TO clinicos_api_owner USING (clinic_id = (%L)::uuid)',
    v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.contacts;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_clinic_scope ON public.contacts FOR ALL TO clinicos_api_owner USING (clinic_id = (%L)::uuid) WITH CHECK (clinic_id = (%L)::uuid)',
    v_clinic_id::text, v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.conversations;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_clinic_scope ON public.conversations FOR ALL TO clinicos_api_owner USING (clinic_id = (%L)::uuid) WITH CHECK (clinic_id = (%L)::uuid)',
    v_clinic_id::text, v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.messages;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_clinic_scope ON public.messages FOR ALL TO clinicos_api_owner USING (clinic_id = (%L)::uuid) WITH CHECK (clinic_id = (%L)::uuid)',
    v_clinic_id::text, v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.appointments;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_clinic_scope ON public.appointments FOR ALL TO clinicos_api_owner USING (clinic_id = (%L)::uuid) WITH CHECK (clinic_id = (%L)::uuid)',
    v_clinic_id::text, v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.outbox;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_clinic_scope ON public.outbox FOR ALL TO clinicos_api_owner USING (clinic_id = (%L)::uuid) WITH CHECK (clinic_id = (%L)::uuid)',
    v_clinic_id::text, v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_system_events_insert ON public.system_events;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_system_events_insert ON public.system_events FOR INSERT TO clinicos_api_owner WITH CHECK (clinic_id IS NULL OR clinic_id = (%L)::uuid)',
    v_clinic_id::text
  );

  DROP POLICY IF EXISTS clinicos_runtime_system_events_select ON public.system_events;
  EXECUTE format(
    'CREATE POLICY clinicos_runtime_system_events_select ON public.system_events FOR SELECT TO clinicos_api_owner USING (clinic_id = (%L)::uuid)',
    v_clinic_id::text
  );
END $$;

GRANT SELECT ON TABLE public.clinics, public.providers, public.services, public.provider_services, public.working_hours, public.system_events TO clinicos_api_owner;
GRANT SELECT, INSERT, UPDATE ON TABLE public.contacts, public.conversations, public.messages, public.appointments, public.outbox TO clinicos_api_owner;
GRANT INSERT ON TABLE public.system_events TO clinicos_api_owner;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO clinicos_api_owner;
