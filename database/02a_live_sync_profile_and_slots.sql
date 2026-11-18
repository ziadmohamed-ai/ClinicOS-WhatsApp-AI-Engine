-- =====================================================================
-- 02a: objects that exist in the live ClinicOS database but were missing
-- from this repository (schema drift). Run AFTER 02_booking_and_outbox_rpcs.sql.
--
-- Extracted read-only from the live database catalog (pg_get_functiondef);
-- the function bodies below are the live definitions, unchanged.
--   * contacts.patient_profile (jsonb, not null, default '{}')
--   * public.get_patient_profile(p_clinic_id, p_contact_id)
--   * public.update_patient_profile(p_clinic_id, p_contact_id, p_profile_patch)
--   * public.get_available_slots(..., p_limit, p_ignore_appointment_id)  (7 parameters)
--     The 6-parameter overload from 02 stays; the workflow calls the 7-parameter one.
-- Idempotent: safe to run twice.
-- =====================================================================

ALTER TABLE public.contacts
  ADD COLUMN IF NOT EXISTS patient_profile jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION public.get_patient_profile(p_clinic_id uuid, p_contact_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_ct public.contacts%ROWTYPE;
  v_tz text := 'Asia/Riyadh';
  v_recent_appts jsonb := '[]'::jsonb;
  v_last_appt record;
  v_total_visits int := 0;
  v_prof jsonb;
  v_cancelled_obj jsonb := NULL;
  v_cancelled_ts timestamptz;
BEGIN
  IF p_clinic_id IS NULL OR p_contact_id IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  SELECT coalesce(c.timezone, 'Asia/Riyadh') INTO v_tz
  FROM public.clinics c WHERE c.id = p_clinic_id;

  SELECT * INTO v_ct
  FROM public.contacts ct
  WHERE ct.clinic_id = p_clinic_id AND ct.id = p_contact_id;

  IF NOT FOUND THEN
    RETURN '{}'::jsonb;
  END IF;

  v_prof := coalesce(v_ct.patient_profile, '{}'::jsonb);

  SELECT count(*)::int INTO v_total_visits
  FROM public.appointments a
  WHERE a.clinic_id = p_clinic_id
    AND a.contact_id = p_contact_id
    AND a.status IN ('confirmed', 'completed');

  SELECT
    a.id AS appointment_id,
    a.service_id,
    s.code AS service_code,
    s.name_ar AS service_name_ar,
    s.name_en AS service_name_en,
    a.provider_id,
    p.name AS provider_name,
    a.starts_at,
    a.status
  INTO v_last_appt
  FROM public.appointments a
  LEFT JOIN public.services s ON s.id = a.service_id
  LEFT JOIN public.providers p ON p.id = a.provider_id
  WHERE a.clinic_id = p_clinic_id
    AND a.contact_id = p_contact_id
  ORDER BY a.created_at DESC, a.id DESC
  LIMIT 1;

  IF v_prof ? 'last_cancelled_appointment' AND jsonb_typeof(v_prof->'last_cancelled_appointment') = 'object' THEN
    BEGIN
      v_cancelled_ts := (v_prof #>> '{last_cancelled_appointment,cancelled_at}')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      v_cancelled_ts := now();
    END;
    IF v_cancelled_ts IS NULL OR v_cancelled_ts >= now() - interval '12 hours' THEN
      v_cancelled_obj := v_prof->'last_cancelled_appointment';
    END IF;
  END IF;

  SELECT coalesce(jsonb_agg(r.item), '[]'::jsonb)
  INTO v_recent_appts
  FROM (
    SELECT jsonb_build_object(
      'appointment_id', a.id,
      'service_code', s.code,
      'service_name_ar', s.name_ar,
      'doctor_name', p.name,
      'status', a.status,
      'starts_at_utc', a.starts_at,
      'display_date_ar', private.format_local_date(a.starts_at AT TIME ZONE v_tz, 'ar'),
      'display_time_ar', private.format_local_time(a.starts_at AT TIME ZONE v_tz, 'ar')
    ) AS item
    FROM public.appointments a
    LEFT JOIN public.services s ON s.id = a.service_id
    LEFT JOIN public.providers p ON p.id = a.provider_id
    WHERE a.clinic_id = p_clinic_id
      AND a.contact_id = p_contact_id
    ORDER BY a.created_at DESC, a.id DESC
    LIMIT 4
  ) r;

  RETURN jsonb_build_object(
    'contact_id', v_ct.id,
    'whatsapp_name', v_ct.name,
    'preferred_name', coalesce(v_prof->>'registered_name', v_prof->>'preferred_name', nullif(split_part(btrim(coalesce(v_ct.name, '')), ' ', 1), '')),
    'registered_name', v_prof->>'registered_name',
    'booking_phone', v_prof->>'booking_phone',
    'language', coalesce(v_ct.language, 'ar'),
    'preferred_dialect', coalesce(v_prof->>'preferred_dialect', CASE WHEN v_ct.language = 'en' THEN 'en' ELSE 'ar-EG' END),
    'is_returning_patient', (v_total_visits > 0 OR v_last_appt.appointment_id IS NOT NULL),
    'total_visits_count', v_total_visits,
    'last_service_id', coalesce(v_prof->>'last_service_id', v_last_appt.service_id::text),
    'last_service_code', coalesce(v_prof->>'last_service_code', v_last_appt.service_code),
    'last_service_name', coalesce(v_prof->>'last_service_name', v_last_appt.service_name_ar),
    'last_provider_id', coalesce(v_prof->>'last_provider_id', v_last_appt.provider_id::text),
    'last_provider_name', coalesce(v_prof->>'last_provider_name', v_last_appt.provider_name),
    'last_cancelled_appointment', v_cancelled_obj,
    'recent_appointments', v_recent_appts,
    'notes', coalesce(v_prof->>'notes', '')
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_patient_profile(p_clinic_id uuid, p_contact_id uuid, p_profile_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_clean_patch jsonb;
  v_new_profile jsonb;
  v_pref_name text;
  v_lang text;
BEGIN
  IF p_clinic_id IS NULL OR p_contact_id IS NULL OR p_profile_patch IS NULL OR jsonb_typeof(p_profile_patch) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
  END IF;

  SELECT coalesce(jsonb_object_agg(e.k, e.v), '{}'::jsonb)
  INTO v_clean_patch
  FROM jsonb_each(p_profile_patch) AS e(k, v)
  WHERE jsonb_typeof(e.v) <> 'null'
    AND e.k IN (
      'preferred_name',
      'preferred_dialect',
      'last_service_id',
      'last_service_code',
      'last_service_name',
      'last_provider_id',
      'last_provider_name',
      'last_cancelled_appointment',
      'notes'
    );

  IF pg_column_size(v_clean_patch) > 4096 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'patch_too_large');
  END IF;

  v_pref_name := nullif(left(btrim(coalesce(v_clean_patch->>'preferred_name', '')), 80), '');
  v_lang := CASE
    WHEN v_clean_patch->>'preferred_dialect' = 'en' THEN 'en'
    WHEN v_clean_patch->>'preferred_dialect' IN ('ar-EG', 'ar-SA', 'ar') THEN 'ar'
    ELSE NULL
  END;

  UPDATE public.contacts ct
  SET patient_profile = coalesce(ct.patient_profile, '{}'::jsonb) || v_clean_patch || jsonb_build_object('updated_at', now()),
      name = COALESCE(v_pref_name, ct.name),
      language = COALESCE(v_lang, ct.language)
  WHERE ct.clinic_id = p_clinic_id
    AND ct.id = p_contact_id
  RETURNING ct.patient_profile INTO v_new_profile;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'patient_profile', v_new_profile);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_available_slots(p_clinic_id uuid, p_service_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_provider_id uuid, p_limit integer, p_ignore_appointment_id uuid)
 RETURNS TABLE(provider_id uuid, provider_name text, starts_at timestamp with time zone, ends_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_timezone text;
    v_settings jsonb;
    v_slot_step_minutes integer;
    v_min_notice_minutes integer;
    v_max_days_ahead integer;
    v_start_day timestamp without time zone;
    v_end_day timestamp without time zone;
BEGIN
    IF p_clinic_id IS NULL
       OR p_service_id IS NULL
       OR p_from IS NULL
       OR p_to IS NULL
       OR p_from > p_to
       OR p_limit IS NULL
       OR p_limit <= 0 THEN
        RETURN;
    END IF;

    SELECT c.timezone, c.settings
    INTO v_timezone, v_settings
    FROM public.clinics AS c
    WHERE c.id = p_clinic_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    BEGIN
        v_slot_step_minutes := COALESCE((v_settings ->> 'slot_step_minutes')::integer, 30);
        v_min_notice_minutes := COALESCE((v_settings ->> 'min_notice_minutes')::integer, 60);
        v_max_days_ahead := COALESCE((v_settings ->> 'max_days_ahead')::integer, 30);
    EXCEPTION
        WHEN invalid_text_representation OR numeric_value_out_of_range THEN
            RETURN;
    END;

    IF v_slot_step_minutes <= 0 OR v_min_notice_minutes < 0 OR v_max_days_ahead < 0 THEN
        RETURN;
    END IF;

    v_start_day := GREATEST(
        ((p_from AT TIME ZONE v_timezone)::date)::timestamp,
        ((now() AT TIME ZONE v_timezone)::date)::timestamp
    );
    v_end_day := LEAST(
        ((p_to AT TIME ZONE v_timezone)::date)::timestamp,
        (((now() + make_interval(days => v_max_days_ahead)) AT TIME ZONE v_timezone)::date)::timestamp
    );

    IF v_start_day > v_end_day THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH service AS (
        SELECT s.duration_minutes
        FROM public.services AS s
        WHERE s.id = p_service_id
          AND s.clinic_id = p_clinic_id
          AND s.active
    ),
    offered_work AS (
        SELECT
            p.id AS offered_provider_id,
            p.name AS offered_provider_name,
            wh.weekday,
            wh.start_time,
            wh.end_time,
            service.duration_minutes
        FROM service
        JOIN public.provider_services AS ps
          ON ps.clinic_id = p_clinic_id
         AND ps.service_id = p_service_id
        JOIN public.providers AS p
          ON p.id = ps.provider_id
         AND p.clinic_id = ps.clinic_id
         AND p.active
        JOIN public.working_hours AS wh
          ON wh.clinic_id = p.clinic_id
         AND wh.provider_id = p.id
        WHERE p_provider_id IS NULL OR p.id = p_provider_id
    ),
    local_days AS (
        SELECT day_series.day_value::date AS local_day
        FROM generate_series(v_start_day, v_end_day, interval '1 day') AS day_series(day_value)
    ),
    local_slots AS (
        SELECT
            offered_work.offered_provider_id,
            offered_work.offered_provider_name,
            offered_work.duration_minutes,
            offered_work.end_time,
            local_days.local_day,
            slot_series.local_start,
            slot_series.local_start AT TIME ZONE v_timezone AS slot_start
        FROM offered_work
        CROSS JOIN local_days
        CROSS JOIN LATERAL generate_series(
            local_days.local_day + offered_work.start_time,
            local_days.local_day + offered_work.end_time
                - make_interval(mins => offered_work.duration_minutes),
            make_interval(mins => v_slot_step_minutes)
        ) AS slot_series(local_start)
        WHERE extract(dow FROM local_days.local_day)::smallint = offered_work.weekday
    ),
    slot_ranges AS (
        SELECT
            local_slots.offered_provider_id,
            local_slots.offered_provider_name,
            local_slots.duration_minutes,
            local_slots.end_time,
            local_slots.local_day,
            local_slots.local_start,
            local_slots.slot_start,
            local_slots.slot_start
                + make_interval(mins => local_slots.duration_minutes) AS slot_end
        FROM local_slots
    )
    SELECT
        slot_ranges.offered_provider_id,
        slot_ranges.offered_provider_name,
        slot_ranges.slot_start,
        slot_ranges.slot_end
    FROM slot_ranges
    WHERE slot_ranges.local_start = slot_ranges.slot_start AT TIME ZONE v_timezone
      AND slot_ranges.slot_start >= p_from
      AND slot_ranges.slot_start <= p_to
      AND slot_ranges.slot_start >= now() + make_interval(mins => v_min_notice_minutes)
      AND slot_ranges.slot_start <= now() + make_interval(days => v_max_days_ahead)
      AND slot_ranges.slot_end AT TIME ZONE v_timezone
            <= slot_ranges.local_day + slot_ranges.end_time
      AND NOT EXISTS (
          SELECT 1
          FROM public.appointments AS a
          WHERE a.clinic_id = p_clinic_id
            AND a.provider_id = slot_ranges.offered_provider_id
            AND a.status = 'confirmed'
            AND (p_ignore_appointment_id IS NULL OR a.id <> p_ignore_appointment_id)
            AND tstzrange(a.starts_at, a.ends_at, '[)')
                && tstzrange(slot_ranges.slot_start, slot_ranges.slot_end, '[)')
      )
    ORDER BY slot_ranges.slot_start, slot_ranges.offered_provider_name,
             slot_ranges.offered_provider_id
    LIMIT LEAST(p_limit, 20);
END;
$function$;

-- Execution rights: same as the live database (no anon, no authenticated).
REVOKE ALL ON FUNCTION public.get_patient_profile(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_patient_profile(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_available_slots(uuid, uuid, timestamptz, timestamptz, uuid, integer, uuid) FROM PUBLIC, anon, authenticated;
