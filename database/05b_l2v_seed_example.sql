-- =====================================================================
-- EXAMPLE SEED DATA — EDIT BEFORE USE
--
-- ClinicOS Add-on 05b: Lead-to-Visit (l2v) Example Staff, SLA & Templates
-- (Example, edit before use — contains only fake +20100000000x numbers)
--
-- Run AFTER database/01..05 (and optionally after database/04_seed_data.sql).
-- Replaces no existing clinic settings or non-L2V whatsapp_templates keys,
-- and is 100% idempotent: running a second time changes no rows, timestamps,
-- or settings.
-- =====================================================================

do $$
declare
  v_clinic_id       uuid;
  v_mgr_contact_id  uuid;
  v_rep1_contact_id uuid;
  v_rep2_contact_id uuid;
  v_templates       jsonb := jsonb_build_object(
    'lead_handoff', jsonb_build_object(
      'name', 'lead_handoff',
      'language_codes', jsonb_build_object('ar', 'ar')
    ),
    'sla_breach', jsonb_build_object(
      'name', 'sla_breach',
      'language_codes', jsonb_build_object('ar', 'ar')
    ),
    'sla_breach_no_rep', jsonb_build_object(
      'name', 'sla_breach_no_rep',
      'language_codes', jsonb_build_object('ar', 'ar')
    )
  );
  v_merged_settings jsonb;
begin
  -- Resolve target clinic: demo clinic from 04_seed_data.sql if present,
  -- otherwise the oldest clinic row (e.g. in a test or single-clinic install).
  v_clinic_id := coalesce(
    (select id from public.clinics where id = '5b201616-fdf0-4a37-8863-bd050ea90376'),
    (select id from public.clinics order by created_at limit 1)
  );

  if v_clinic_id is null then
    raise exception 'No clinic found in public.clinics. Seed a clinic before running 05b_l2v_seed_example.sql.';
  end if;

  -- 1. Upsert example manager and two reception reps into public.contacts.
  --    WHERE clause ensures a second run with unchanged values touches 0 rows
  --    and preserves contacts.updated_at.
  insert into public.contacts (clinic_id, phone_e164, name, language)
  values
    (v_clinic_id, '+201000000001', 'مدير الاستقبال (مثال)', 'ar'),
    (v_clinic_id, '+201000000002', 'موظف استقبال 1 (مثال)', 'ar'),
    (v_clinic_id, '+201000000003', 'موظف استقبال 2 (مثال)', 'ar')
  on conflict (clinic_id, phone_e164) do update
    set name = excluded.name
  where public.contacts.name is distinct from excluded.name;

  select id into v_mgr_contact_id
    from public.contacts
   where clinic_id = v_clinic_id and phone_e164 = '+201000000001';

  select id into v_rep1_contact_id
    from public.contacts
   where clinic_id = v_clinic_id and phone_e164 = '+201000000002';

  select id into v_rep2_contact_id
    from public.contacts
   where clinic_id = v_clinic_id and phone_e164 = '+201000000003';

  -- 2. Upsert l2v.settings (15-minute SLA + manager contact).
  insert into l2v.settings (clinic_id, sla_minutes, manager_contact_id)
  values (v_clinic_id, 15, v_mgr_contact_id)
  on conflict (clinic_id) do update
    set sla_minutes        = excluded.sla_minutes,
        manager_contact_id = excluded.manager_contact_id
  where l2v.settings.sla_minutes is distinct from excluded.sla_minutes
     or l2v.settings.manager_contact_id is distinct from excluded.manager_contact_id;

  -- 3. Upsert the two reception reps into l2v.reps without touching last_assigned_at.
  insert into l2v.reps (clinic_id, contact_id, name, is_active)
  values
    (v_clinic_id, v_rep1_contact_id, 'موظف استقبال 1 (مثال)', true),
    (v_clinic_id, v_rep2_contact_id, 'موظف استقبال 2 (مثال)', true)
  on conflict (contact_id) do update
    set clinic_id = excluded.clinic_id,
        name      = excluded.name,
        is_active = excluded.is_active
  where l2v.reps.clinic_id is distinct from excluded.clinic_id
     or l2v.reps.name is distinct from excluded.name
     or l2v.reps.is_active is distinct from excluded.is_active;

  -- 4. Merge lead_handoff, sla_breach, and sla_breach_no_rep into
  --    public.clinics.settings.whatsapp_templates without wiping existing
  --    settings or other whatsapp_templates keys.
  select jsonb_set(
           coalesce(c.settings, '{}'::jsonb),
           '{whatsapp_templates}',
           coalesce(c.settings -> 'whatsapp_templates', '{}'::jsonb) || v_templates,
           true
         )
    into v_merged_settings
    from public.clinics c
   where c.id = v_clinic_id;

  update public.clinics c
     set settings = v_merged_settings
   where c.id = v_clinic_id
     and c.settings is distinct from v_merged_settings;
end $$;
