-- =====================================================================
-- ClinicOS Row-Level Security (RLS) Policies (Hardcoded Clinic Scope)
-- =====================================================================

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

CREATE POLICY clinicos_runtime_clinic_scope ON public.clinics
  FOR SELECT TO clinicos_api_owner
  USING (id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_clinic_scope ON public.providers
  FOR SELECT TO clinicos_api_owner
  USING (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_clinic_scope ON public.services
  FOR SELECT TO clinicos_api_owner
  USING (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_clinic_scope ON public.provider_services
  FOR SELECT TO clinicos_api_owner
  USING (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_clinic_scope ON public.working_hours
  FOR SELECT TO clinicos_api_owner
  USING (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_clinic_scope ON public.contacts
  FOR ALL TO clinicos_api_owner
  USING (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid)
  WITH CHECK (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_clinic_scope ON public.conversations
  FOR ALL TO clinicos_api_owner
  USING (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid)
  WITH CHECK (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_clinic_scope ON public.messages
  FOR ALL TO clinicos_api_owner
  USING (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid)
  WITH CHECK (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_clinic_scope ON public.appointments
  FOR ALL TO clinicos_api_owner
  USING (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid)
  WITH CHECK (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_clinic_scope ON public.outbox
  FOR ALL TO clinicos_api_owner
  USING (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid)
  WITH CHECK (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_system_events_insert ON public.system_events
  FOR INSERT TO clinicos_api_owner
  WITH CHECK (clinic_id IS NULL OR clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

CREATE POLICY clinicos_runtime_system_events_select ON public.system_events
  FOR SELECT TO clinicos_api_owner
  USING (clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid);

GRANT SELECT ON TABLE public.clinics, public.providers, public.services, public.provider_services, public.working_hours, public.system_events TO clinicos_api_owner;
GRANT SELECT, INSERT, UPDATE ON TABLE public.contacts, public.conversations, public.messages, public.appointments, public.outbox TO clinicos_api_owner;
GRANT INSERT ON TABLE public.system_events TO clinicos_api_owner;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO clinicos_api_owner;

