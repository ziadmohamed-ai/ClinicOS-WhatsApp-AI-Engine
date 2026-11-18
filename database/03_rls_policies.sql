-- =====================================================================
-- ClinicOS Row-Level Security (RLS) Policies (One Supabase Project per Clinic)
-- Usage:
--   psql -v ON_ERROR_STOP=1 -v clinic_id=<CLINIC_UUID> -f database/03_rls_policies.sql
-- =====================================================================

\if :{?clinic_id}
\else
DO $$
BEGIN
  RAISE EXCEPTION 'Missing required psql variable clinic_id. Run: psql -v ON_ERROR_STOP=1 -v clinic_id=<clinic-uuid> -f database/03_rls_policies.sql';
END $$;
\endif

SELECT pg_catalog.set_config('clinicos.rls_clinic_id', :'clinic_id', false);

DO $$
DECLARE
  v_raw text := btrim(coalesce(current_setting('clinicos.rls_clinic_id', true), ''));
  v_uuid uuid;
BEGIN
  IF v_raw = '' OR v_raw = ':clinic_id' THEN
    RAISE EXCEPTION 'Empty or unset psql variable clinic_id. Pass a valid clinic UUID via -v clinic_id=<uuid>.';
  END IF;
  BEGIN
    v_uuid := v_raw::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Invalid clinic_id UUID "%". Pass a valid UUID via -v clinic_id=<uuid>.', v_raw;
  END;
END $$;

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
CREATE POLICY clinicos_runtime_clinic_scope ON public.clinics
  FOR SELECT TO clinicos_api_owner
  USING (id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.providers;
CREATE POLICY clinicos_runtime_clinic_scope ON public.providers
  FOR SELECT TO clinicos_api_owner
  USING (clinic_id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.services;
CREATE POLICY clinicos_runtime_clinic_scope ON public.services
  FOR SELECT TO clinicos_api_owner
  USING (clinic_id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.provider_services;
CREATE POLICY clinicos_runtime_clinic_scope ON public.provider_services
  FOR SELECT TO clinicos_api_owner
  USING (clinic_id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.working_hours;
CREATE POLICY clinicos_runtime_clinic_scope ON public.working_hours
  FOR SELECT TO clinicos_api_owner
  USING (clinic_id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.contacts;
CREATE POLICY clinicos_runtime_clinic_scope ON public.contacts
  FOR ALL TO clinicos_api_owner
  USING (clinic_id = (:'clinic_id')::uuid)
  WITH CHECK (clinic_id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.conversations;
CREATE POLICY clinicos_runtime_clinic_scope ON public.conversations
  FOR ALL TO clinicos_api_owner
  USING (clinic_id = (:'clinic_id')::uuid)
  WITH CHECK (clinic_id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.messages;
CREATE POLICY clinicos_runtime_clinic_scope ON public.messages
  FOR ALL TO clinicos_api_owner
  USING (clinic_id = (:'clinic_id')::uuid)
  WITH CHECK (clinic_id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.appointments;
CREATE POLICY clinicos_runtime_clinic_scope ON public.appointments
  FOR ALL TO clinicos_api_owner
  USING (clinic_id = (:'clinic_id')::uuid)
  WITH CHECK (clinic_id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_clinic_scope ON public.outbox;
CREATE POLICY clinicos_runtime_clinic_scope ON public.outbox
  FOR ALL TO clinicos_api_owner
  USING (clinic_id = (:'clinic_id')::uuid)
  WITH CHECK (clinic_id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_system_events_insert ON public.system_events;
CREATE POLICY clinicos_runtime_system_events_insert ON public.system_events
  FOR INSERT TO clinicos_api_owner
  WITH CHECK (clinic_id IS NULL OR clinic_id = (:'clinic_id')::uuid);

DROP POLICY IF EXISTS clinicos_runtime_system_events_select ON public.system_events;
CREATE POLICY clinicos_runtime_system_events_select ON public.system_events
  FOR SELECT TO clinicos_api_owner
  USING (clinic_id = (:'clinic_id')::uuid);

GRANT SELECT ON TABLE public.clinics, public.providers, public.services, public.provider_services, public.working_hours, public.system_events TO clinicos_api_owner;
GRANT SELECT, INSERT, UPDATE ON TABLE public.contacts, public.conversations, public.messages, public.appointments, public.outbox TO clinicos_api_owner;
GRANT INSERT ON TABLE public.system_events TO clinicos_api_owner;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO clinicos_api_owner;
