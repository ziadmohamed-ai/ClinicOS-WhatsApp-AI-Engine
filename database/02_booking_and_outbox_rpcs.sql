-- =====================================================================
-- ClinicOS Production RPCs & Functions (Synced with Live Supabase DB)
-- =====================================================================

-- ---------------------------------------------------------------------
-- private.build_whatsapp_message(p_settings jsonb, p_template_key text, p_language text, p_text text, p_params text[], p_in_window boolean)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.build_whatsapp_message(p_settings jsonb, p_template_key text, p_language text, p_text text, p_params text[], p_in_window boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_lang text := CASE WHEN p_language = 'en' THEN 'en' ELSE 'ar' END;
    v_cfg jsonb := p_settings #> ARRAY['whatsapp_templates', p_template_key];
    v_name text;
    v_code text;
    v_params jsonb;
BEGIN
    IF coalesce(p_in_window, false) THEN
        RETURN jsonb_build_object('kind', 'text', 'payload', jsonb_build_object('text', p_text));
    END IF;

    v_name := btrim(v_cfg ->> 'name');
    IF v_name IS NULL OR v_name = '' THEN
        RETURN jsonb_build_object('kind', 'text', 'payload', jsonb_build_object('text', p_text));
    END IF;

    v_code := coalesce(nullif(btrim(v_cfg #>> ARRAY['language_codes', v_lang]), ''), v_lang);

    -- Meta rejects template params containing newlines/tabs or >4 consecutive spaces.
    SELECT coalesce(
               jsonb_agg(
                   jsonb_build_object(
                       'type', 'text',
                       'text', coalesce(nullif(left(btrim(regexp_replace(coalesce(u.v, ''), '\s+', ' ', 'g')), 300), ''), '-')
                   )
                   ORDER BY u.ord
               ),
               '[]'::jsonb
           )
    INTO v_params
    FROM unnest(coalesce(p_params, ARRAY[]::text[])) WITH ORDINALITY AS u(v, ord);

    RETURN jsonb_build_object(
        'kind', 'template',
        'payload', jsonb_build_object(
            'template', jsonb_build_object(
                'name', v_name,
                'language', jsonb_build_object('code', v_code),
                'components', CASE
                    WHEN jsonb_array_length(v_params) = 0 THEN '[]'::jsonb
                    ELSE jsonb_build_array(jsonb_build_object('type', 'body', 'parameters', v_params))
                END
            )
        )
    );
END;
$function$;

-- ---------------------------------------------------------------------
-- private.claim_outbox_batch_with_route(p_batch_size integer, p_clinic_id uuid)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.claim_outbox_batch_with_route(p_batch_size integer DEFAULT 10, p_clinic_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(outbox_id uuid, clinic_id uuid, contact_id uuid, recipient_phone text, message_kind text, payload jsonb, attempt_count integer, max_attempts integer, claim_token uuid, claimed_at timestamp with time zone, phone_number_id text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  SELECT
    claimed.outbox_id,
    claimed.clinic_id,
    claimed.contact_id,
    claimed.recipient_phone,
    claimed.message_kind,
    claimed.payload,
    claimed.attempt_count,
    claimed.max_attempts,
    claimed.claim_token,
    claimed.claimed_at,
    NULLIF(pg_catalog.btrim(clinic.settings->>'whatsapp_phone_number_id'), '') AS phone_number_id
  FROM public.claim_outbox_batch(p_batch_size, p_clinic_id) AS claimed
  LEFT JOIN public.clinics AS clinic
    ON clinic.id = claimed.clinic_id
  ORDER BY claimed.claimed_at, claimed.outbox_id;
$function$;

-- ---------------------------------------------------------------------
-- private.get_clinicos_meta_secret(p_secret_name text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.get_clinicos_meta_secret(p_secret_name text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
  SELECT ds.decrypted_secret
  FROM vault.decrypted_secrets AS ds
  WHERE p_secret_name IN ('clinicos_meta_app_secret','clinicos_meta_verify_token')
    AND ds.name = p_secret_name
  LIMIT 1;
$function$;

-- ---------------------------------------------------------------------
-- public.apply_outbox_delivery_status(p_clinic_id uuid, p_provider_message_id text, p_status text, p_provider_timestamp timestamp with time zone, p_error_code text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_outbox_delivery_status(p_clinic_id uuid, p_provider_message_id text, p_status text, p_provider_timestamp timestamp with time zone DEFAULT NULL::timestamp with time zone, p_error_code text DEFAULT NULL::text)
 RETURNS TABLE(outbox_id uuid, delivery_status text, outcome text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_outbox_id uuid;
    v_current_status text;
    v_current_at timestamptz;
    v_current_error_code text;
    v_current_rank integer;
    v_incoming_rank integer;
    v_event_at timestamptz := COALESCE(p_provider_timestamp, now());
BEGIN
    IF p_clinic_id IS NULL
       OR p_provider_message_id IS NULL
       OR btrim(p_provider_message_id) = ''
       OR length(p_provider_message_id) > 512
       OR p_provider_message_id ~ '[[:cntrl:]]'
       OR p_status IS NULL
       OR p_status NOT IN ('sent', 'delivered', 'read', 'failed')
       OR (p_error_code IS NOT NULL AND p_error_code !~ '^[a-z0-9][a-z0-9_.:-]{0,79}$')
       OR (p_status <> 'failed' AND p_error_code IS NOT NULL) THEN
        RAISE EXCEPTION 'clinic, provider message id, supported status, and sanitized failure code are required'
            USING ERRCODE = '22023';
    END IF;

    SELECT o.id, o.delivery_status, o.delivery_status_at, o.delivery_error_code
    INTO v_outbox_id, v_current_status, v_current_at, v_current_error_code
    FROM public.outbox AS o
    WHERE o.clinic_id = p_clinic_id
      AND o.provider_message_id = p_provider_message_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT NULL::uuid, NULL::text, 'not_found'::text;
        RETURN;
    END IF;

    v_current_rank := CASE v_current_status
        WHEN 'sent' THEN 1
        WHEN 'failed' THEN 2
        WHEN 'delivered' THEN 3
        WHEN 'read' THEN 4
        ELSE 0
    END;
    v_incoming_rank := CASE p_status
        WHEN 'sent' THEN 1
        WHEN 'failed' THEN 2
        WHEN 'delivered' THEN 3
        WHEN 'read' THEN 4
        ELSE 0
    END;

    IF v_incoming_rank > v_current_rank THEN
        UPDATE public.outbox AS o
        SET delivery_status = p_status,
            delivery_status_at = v_event_at,
            delivery_error_code = CASE WHEN p_status = 'failed' THEN p_error_code ELSE NULL END
        WHERE o.id = v_outbox_id;

        RETURN QUERY SELECT v_outbox_id, p_status, 'applied'::text;
    ELSIF p_status = v_current_status THEN
        UPDATE public.outbox AS o
        SET delivery_status_at = CASE
                WHEN v_current_at IS NULL OR v_event_at > v_current_at THEN v_event_at
                ELSE v_current_at
            END,
            delivery_error_code = CASE
                WHEN p_status = 'failed'
                 AND p_error_code IS NOT NULL
                 AND (v_current_at IS NULL OR v_event_at >= v_current_at)
                    THEN p_error_code
                ELSE v_current_error_code
            END
        WHERE o.id = v_outbox_id;

        RETURN QUERY SELECT v_outbox_id, p_status, 'already_applied'::text;
    ELSE
        RETURN QUERY SELECT v_outbox_id, v_current_status, 'ignored_stale'::text;
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------
-- public.apply_voice_transcription(p_batch_result jsonb, p_transcript text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_voice_transcription(p_batch_result jsonb, p_transcript text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_clean text := btrim(coalesce(p_transcript, ''));
    v_clinic_id uuid;
    v_message_id uuid;
BEGIN
    IF p_batch_result IS NULL OR jsonb_typeof(p_batch_result) <> 'object' THEN
        RETURN jsonb_build_object('ok', false, 'messages', '[]'::jsonb);
    END IF;

    IF v_clean = '' OR jsonb_typeof(p_batch_result->'messages') <> 'array' OR jsonb_array_length(p_batch_result->'messages') = 0 THEN
        RETURN p_batch_result;
    END IF;

    BEGIN
        v_clinic_id := (p_batch_result #>> '{messages,0,clinic_id}')::uuid;
        v_message_id := (p_batch_result #>> '{messages,0,message_id}')::uuid;
    EXCEPTION WHEN OTHERS THEN
        RETURN p_batch_result;
    END;

    IF v_clinic_id IS NOT NULL AND v_message_id IS NOT NULL THEN
        UPDATE public.messages
        SET body = left(v_clean, 4096),
            payload = jsonb_set(
                coalesce(payload, '{}'::jsonb),
                '{transcription}',
                to_jsonb(left(v_clean, 4096))
            )
        WHERE clinic_id = v_clinic_id
          AND id = v_message_id;
    END IF;

    RETURN jsonb_set(
        p_batch_result,
        '{messages,0,body}',
        to_jsonb(left(v_clean, 4096))
    );
END;
$function$;

-- ---------------------------------------------------------------------
-- public.authorize_outbox_send(p_outbox_id uuid, p_claim_token uuid)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.authorize_outbox_send(p_outbox_id uuid, p_claim_token uuid)
 RETURNS TABLE(authorized boolean, reason text, outbox_id uuid, clinic_id uuid, phone_number_id text, contact_id uuid, recipient_phone text, message_kind text, payload jsonb, attempt_count integer, max_attempts integer, claim_token uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_clinic_id uuid;
    v_contact_id uuid;
    v_opted_out_at timestamptz;
    v_communications_opted_out_at timestamptz;
    v_phone text;
    v_phone_number_id_type text;
    v_phone_number_id text;
    v_row public.outbox%ROWTYPE;
    v_send_token uuid;
BEGIN
    authorized := false;
    reason := 'invalid_request';
    outbox_id := p_outbox_id;
    IF p_outbox_id IS NULL OR p_claim_token IS NULL THEN
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT o.clinic_id, o.contact_id
    INTO v_clinic_id, v_contact_id
    FROM public.outbox AS o
    WHERE o.id = p_outbox_id;

    IF NOT FOUND THEN
        reason := 'not_found';
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT ct.opted_out_at, ct.communications_opted_out_at, ct.phone_e164
    INTO v_opted_out_at, v_communications_opted_out_at, v_phone
    FROM public.contacts AS ct
    WHERE ct.clinic_id = v_clinic_id
      AND ct.id = v_contact_id
    FOR UPDATE OF ct;

    IF NOT FOUND THEN
        reason := 'contact_not_found';
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT o.*
    INTO v_row
    FROM public.outbox AS o
    WHERE o.id = p_outbox_id
    FOR UPDATE OF o;

    IF NOT FOUND THEN
        reason := 'not_found';
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_row.clinic_id IS DISTINCT FROM v_clinic_id
       OR v_row.contact_id IS DISTINCT FROM v_contact_id
       OR v_row.status <> 'processing'
       OR v_row.claim_token IS DISTINCT FROM p_claim_token THEN
        reason := 'stale_claim';
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_row.send_authorized_at IS NOT NULL THEN
        reason := 'already_authorized';
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_communications_opted_out_at IS NOT NULL THEN
        UPDATE public.outbox AS o
        SET status = 'dead', locked_at = NULL, claim_token = gen_random_uuid(),
            last_error = 'communications_opted_out'
        WHERE o.id = p_outbox_id;
        INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
        VALUES (v_clinic_id, 'warn', 'authorize_outbox_send', 'outbox_message_dead',
                jsonb_build_object('outbox_id', p_outbox_id, 'contact_id', v_contact_id, 'reason', 'communications_opted_out'));
        reason := 'communications_opted_out';
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_row.is_marketing AND v_opted_out_at IS NOT NULL THEN
        UPDATE public.outbox AS o
        SET status = 'dead', locked_at = NULL, claim_token = gen_random_uuid(),
            last_error = 'contact_opted_out'
        WHERE o.id = p_outbox_id;
        INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
        VALUES (v_clinic_id, 'warn', 'authorize_outbox_send', 'outbox_message_dead',
                jsonb_build_object('outbox_id', p_outbox_id, 'contact_id', v_contact_id, 'reason', 'contact_opted_out'));
        reason := 'contact_opted_out';
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_row.locked_at IS NULL
       OR v_row.locked_at < clock_timestamp() - interval '15 minutes' THEN
        UPDATE public.outbox AS o
        SET status = 'failed',
            next_attempt_at = clock_timestamp() + interval '30 seconds',
            locked_at = NULL, claim_token = NULL,
            last_error = 'claim_expired_before_authorization'
        WHERE o.id = p_outbox_id;
        reason := 'claim_expired';
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_row.attempts > v_row.max_attempts THEN
        UPDATE public.outbox AS o
        SET status = 'dead', locked_at = NULL, claim_token = gen_random_uuid(),
            last_error = 'max_attempts_exhausted'
        WHERE o.id = p_outbox_id;
        INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
        VALUES (v_clinic_id, 'error', 'authorize_outbox_send', 'outbox_message_dead',
                jsonb_build_object('outbox_id', p_outbox_id, 'contact_id', v_contact_id, 'reason', 'max_attempts_exhausted'));
        reason := 'max_attempts_exhausted';
        RETURN NEXT;
        RETURN;
    END IF;

    IF v_row.kind <> 'template'
       AND NOT EXISTS (
           SELECT 1
           FROM public.conversations AS cv
           WHERE cv.clinic_id = v_clinic_id
             AND cv.contact_id = v_contact_id
             AND cv.status <> 'closed'
             AND cv.last_inbound_at >= clock_timestamp() - interval '24 hours'
             AND cv.last_inbound_at <= clock_timestamp()
       ) THEN
        UPDATE public.outbox AS o
        SET status = 'dead', locked_at = NULL, claim_token = gen_random_uuid(),
            last_error = 'session_window_closed'
        WHERE o.id = p_outbox_id;
        INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
        VALUES (v_clinic_id, 'warn', 'authorize_outbox_send', 'outbox_message_dead',
                jsonb_build_object('outbox_id', p_outbox_id, 'contact_id', v_contact_id, 'reason', 'session_window_closed'));
        reason := 'session_window_closed';
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT jsonb_typeof(c.settings->'whatsapp_phone_number_id'),
           c.settings->>'whatsapp_phone_number_id'
    INTO v_phone_number_id_type, v_phone_number_id
    FROM public.clinics AS c
    WHERE c.id = v_clinic_id;

    IF NOT FOUND
       OR v_phone_number_id_type IS DISTINCT FROM 'string'
       OR v_phone_number_id IS NULL
       OR v_phone_number_id = ''
       OR v_phone_number_id ~ '(^[[:space:]]|[[:space:]]$)' THEN
        UPDATE public.outbox AS o
        SET status = 'dead', locked_at = NULL, claim_token = gen_random_uuid(),
            last_error = 'whatsapp_route_not_configured'
        WHERE o.id = p_outbox_id;
        INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
        VALUES (v_clinic_id, 'error', 'authorize_outbox_send', 'outbox_message_dead',
                jsonb_build_object('outbox_id', p_outbox_id, 'contact_id', v_contact_id, 'reason', 'whatsapp_route_not_configured'));
        reason := 'route_not_configured';
        RETURN NEXT;
        RETURN;
    END IF;

    v_send_token := gen_random_uuid();
    UPDATE public.outbox AS o
    SET claim_token = v_send_token,
        locked_at = clock_timestamp(),
        send_authorized_at = clock_timestamp()
    WHERE o.id = p_outbox_id;

    authorized := true;
    reason := 'authorized';
    clinic_id := v_row.clinic_id;
    phone_number_id := v_phone_number_id;
    contact_id := v_row.contact_id;
    recipient_phone := v_phone;
    message_kind := v_row.kind;
    payload := v_row.payload;
    attempt_count := v_row.attempts;
    max_attempts := v_row.max_attempts;
    claim_token := v_send_token;
    RETURN NEXT;
END;
$function$;

-- ---------------------------------------------------------------------
-- public.book_appointment(p_clinic_id uuid, p_contact_id uuid, p_provider_id uuid, p_service_id uuid, p_starts_at timestamp with time zone, p_source text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.book_appointment(p_clinic_id uuid, p_contact_id uuid, p_provider_id uuid, p_service_id uuid, p_starts_at timestamp with time zone, p_source text DEFAULT 'whatsapp'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_timezone text;
    v_settings jsonb;
    v_language text;
    v_provider_name text;
    v_service_name text;
    v_duration_minutes integer;
    v_slot_step_minutes integer;
    v_min_notice_minutes integer;
    v_max_days_ahead integer;
    v_start_local timestamp without time zone;
    v_end_at timestamptz;
    v_end_local timestamp without time zone;
    v_template text;
    v_message text;
    v_appointment_id uuid;
BEGIN
    IF p_clinic_id IS NULL OR p_contact_id IS NULL OR p_provider_id IS NULL
       OR p_service_id IS NULL OR p_starts_at IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    SELECT c.timezone, c.settings
    INTO v_timezone, v_settings
    FROM public.clinics AS c
    WHERE c.id = p_clinic_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    SELECT ct.language
    INTO v_language
    FROM public.contacts AS ct
    WHERE ct.id = p_contact_id
      AND ct.clinic_id = p_clinic_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    SELECT a.id
    INTO v_appointment_id
    FROM public.appointments AS a
    WHERE a.clinic_id = p_clinic_id
      AND a.contact_id = p_contact_id
      AND a.provider_id = p_provider_id
      AND a.service_id = p_service_id
      AND a.starts_at = p_starts_at
      AND a.status = 'confirmed'
    ORDER BY a.created_at, a.id
    LIMIT 1;

    IF FOUND THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = p_contact_id
          AND status <> 'closed';

        RETURN jsonb_build_object(
            'ok', true,
            'appointment_id', v_appointment_id,
            'idempotent', true
        );
    END IF;

    SELECT s.duration_minutes,
           CASE WHEN v_language = 'en' THEN s.name_en ELSE s.name_ar END,
           p.name
    INTO v_duration_minutes, v_service_name, v_provider_name
    FROM public.services AS s
    JOIN public.provider_services AS ps
      ON ps.clinic_id = s.clinic_id
     AND ps.service_id = s.id
     AND ps.provider_id = p_provider_id
    JOIN public.providers AS p
      ON p.id = ps.provider_id
     AND p.clinic_id = ps.clinic_id
    WHERE s.id = p_service_id
      AND s.clinic_id = p_clinic_id
      AND s.active
      AND p.active;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'service_not_offered');
    END IF;

    BEGIN
        v_slot_step_minutes := COALESCE((v_settings ->> 'slot_step_minutes')::integer, 30);
        v_min_notice_minutes := COALESCE((v_settings ->> 'min_notice_minutes')::integer, 60);
        v_max_days_ahead := COALESCE((v_settings ->> 'max_days_ahead')::integer, 30);
    EXCEPTION
        WHEN invalid_text_representation OR numeric_value_out_of_range THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END;

    IF v_slot_step_minutes <= 0 OR v_min_notice_minutes < 0 OR v_max_days_ahead < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    IF p_starts_at < now() + make_interval(mins => v_min_notice_minutes) THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = p_contact_id
          AND status <> 'closed';

        PERFORM public.enqueue_message(
            p_clinic_id,
            p_contact_id,
            'text',
            jsonb_build_object(
                'text',
                CASE WHEN v_language = 'en'
                    THEN 'That appointment time has passed the minimum booking notice window. Please ask me for new available times.'
                    ELSE 'عفواً الميعاد ده اقترب جداً وانتهت مهلة الحجز المتاحة له قولي أشوفلك أقرب ميعاد تاني'
                END
            ),
            'appt-too-soon-' || p_contact_id::text || '-' || extract(epoch from p_starts_at)::bigint::text,
            false
        );

        RETURN jsonb_build_object('ok', false, 'reason', 'too_soon');
    END IF;

    IF p_starts_at > now() + make_interval(days => v_max_days_ahead) THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = p_contact_id
          AND status <> 'closed';

        PERFORM public.enqueue_message(
            p_clinic_id,
            p_contact_id,
            'text',
            jsonb_build_object(
                'text',
                CASE WHEN v_language = 'en'
                    THEN 'That date is beyond the maximum advance booking window. Please choose a closer date.'
                    ELSE 'عفواً التاريخ ده أبعد من الفترة المتاحة للحجز حالياً تحب نشوف ميعاد أقرب؟'
                END
            ),
            'appt-too-far-' || p_contact_id::text || '-' || extract(epoch from p_starts_at)::bigint::text,
            false
        );

        RETURN jsonb_build_object('ok', false, 'reason', 'too_far');
    END IF;

    v_start_local := p_starts_at AT TIME ZONE v_timezone;
    v_end_at := p_starts_at + make_interval(mins => v_duration_minutes);
    v_end_local := v_end_at AT TIME ZONE v_timezone;

    IF NOT EXISTS (
        SELECT 1
        FROM public.working_hours AS wh
        WHERE wh.clinic_id = p_clinic_id
          AND wh.provider_id = p_provider_id
          AND wh.weekday = extract(dow FROM v_start_local)::smallint
          AND v_start_local::time >= wh.start_time
          AND v_end_local <= date_trunc('day', v_start_local) + wh.end_time
    ) THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = p_contact_id
          AND status <> 'closed';

        PERFORM public.enqueue_message(
            p_clinic_id,
            p_contact_id,
            'text',
            jsonb_build_object(
                'text',
                CASE WHEN v_language = 'en'
                    THEN 'That time is outside the doctor working hours. Please ask me for available times.'
                    ELSE 'عفواً التوقيت ده خارج مواعيد عمل الدكتور حالياً قولي أعرضلك المواعيد المتاحة'
                END
            ),
            'appt-outside-hours-' || p_contact_id::text || '-' || extract(epoch from p_starts_at)::bigint::text,
            false
        );

        RETURN jsonb_build_object('ok', false, 'reason', 'outside_hours');
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.working_hours AS wh
        WHERE wh.clinic_id = p_clinic_id
          AND wh.provider_id = p_provider_id
          AND wh.weekday = extract(dow FROM v_start_local)::smallint
          AND v_start_local::time >= wh.start_time
          AND v_end_local <= date_trunc('day', v_start_local) + wh.end_time
          AND mod(
              extract(epoch FROM (
                  v_start_local - (date_trunc('day', v_start_local) + wh.start_time)
              )),
              v_slot_step_minutes::numeric * 60
          ) = 0
    ) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    v_template := v_settings #>> ARRAY['messages', 'booking_confirmed', v_language];
    IF v_template IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    BEGIN
        INSERT INTO public.appointments (
            clinic_id, contact_id, provider_id, service_id,
            starts_at, ends_at, source
        )
        VALUES (
            p_clinic_id, p_contact_id, p_provider_id, p_service_id,
            p_starts_at, v_end_at, p_source
        )
        RETURNING id INTO v_appointment_id;
    EXCEPTION
        WHEN exclusion_violation THEN
            SELECT a.id
            INTO v_appointment_id
            FROM public.appointments AS a
            WHERE a.clinic_id = p_clinic_id
              AND a.contact_id = p_contact_id
              AND a.provider_id = p_provider_id
              AND a.service_id = p_service_id
              AND a.starts_at = p_starts_at
              AND a.status = 'confirmed'
            ORDER BY a.created_at, a.id
            LIMIT 1;

            IF FOUND THEN
                UPDATE public.conversations
                SET state = state - 'pending_booking'
                WHERE clinic_id = p_clinic_id
                  AND contact_id = p_contact_id
                  AND status <> 'closed';

                RETURN jsonb_build_object(
                    'ok', true,
                    'appointment_id', v_appointment_id,
                    'idempotent', true
                );
            END IF;

            UPDATE public.conversations
            SET state = state - 'pending_booking'
            WHERE clinic_id = p_clinic_id
              AND contact_id = p_contact_id
              AND status <> 'closed';

            PERFORM public.enqueue_message(
                p_clinic_id,
                p_contact_id,
                'text',
                jsonb_build_object(
                    'text',
                    CASE WHEN v_language = 'en'
                        THEN 'That time is no longer available, so nothing was booked. Please ask me for available times again.'
                        ELSE 'الميعاد ده اتشغل للأسف قبل ما نأكده ومتمش تسجيل الحجز تحب أعرضلك المواعيد المتاحة تاني؟'
                    END
                ),
                'appt-slot-taken-' || p_contact_id::text || '-' || extract(epoch from p_starts_at)::bigint::text,
                false
            );

            RETURN jsonb_build_object('ok', false, 'reason', 'slot_taken');
    END;

    UPDATE public.conversations
    SET state = state - 'pending_booking'
    WHERE clinic_id = p_clinic_id
      AND contact_id = p_contact_id
      AND status <> 'closed';

    -- Always build confirmation text deterministically from DB template
    v_message := replace(
        replace(
            replace(
                replace(v_template, '{{service}}', v_service_name),
                '{{doctor}}', v_provider_name
            ),
            '{{date}}', to_char(v_start_local, 'YYYY-MM-DD')
        ),
        '{{time}}', to_char(v_start_local, 'HH24:MI')
    );

    PERFORM public.enqueue_message(
        p_clinic_id,
        p_contact_id,
        'text',
        jsonb_build_object('text', v_message),
        'appt-confirm-' || v_appointment_id::text,
        false
    );

    RETURN jsonb_build_object(
        'ok', true,
        'appointment_id', v_appointment_id,
        'starts_at', p_starts_at,
        'message_text', v_message
    );
END;
$function$;

-- ---------------------------------------------------------------------
-- public.book_appointment(p_clinic_id uuid, p_contact_id uuid, p_provider_id uuid, p_service_id uuid, p_starts_at timestamp with time zone, p_source text, p_custom_message text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.book_appointment(p_clinic_id uuid, p_contact_id uuid, p_provider_id uuid, p_service_id uuid, p_starts_at timestamp with time zone, p_source text DEFAULT 'whatsapp'::text, p_custom_message text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_timezone text;
    v_settings jsonb;
    v_language text;
    v_provider_name text;
    v_service_name text;
    v_duration_minutes integer;
    v_slot_step_minutes integer;
    v_min_notice_minutes integer;
    v_max_days_ahead integer;
    v_start_local timestamp without time zone;
    v_end_at timestamptz;
    v_end_local timestamp without time zone;
    v_template text;
    v_message text;
    v_appointment_id uuid;
BEGIN
    -- Audit Point 2: p_custom_message is intentionally ignored; confirmation text is always built deterministically from DB template.
    IF p_clinic_id IS NULL OR p_contact_id IS NULL OR p_provider_id IS NULL
       OR p_service_id IS NULL OR p_starts_at IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    SELECT c.timezone, c.settings
    INTO v_timezone, v_settings
    FROM public.clinics AS c
    WHERE c.id = p_clinic_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    SELECT ct.language
    INTO v_language
    FROM public.contacts AS ct
    WHERE ct.id = p_contact_id
      AND ct.clinic_id = p_clinic_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    SELECT a.id
    INTO v_appointment_id
    FROM public.appointments AS a
    WHERE a.clinic_id = p_clinic_id
      AND a.contact_id = p_contact_id
      AND a.provider_id = p_provider_id
      AND a.service_id = p_service_id
      AND a.starts_at = p_starts_at
      AND a.status = 'confirmed'
    ORDER BY a.created_at, a.id
    LIMIT 1;

    IF FOUND THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = p_contact_id
          AND status <> 'closed';

        RETURN jsonb_build_object(
            'ok', true,
            'appointment_id', v_appointment_id,
            'idempotent', true
        );
    END IF;

    SELECT s.duration_minutes,
           CASE WHEN v_language = 'en' THEN s.name_en ELSE s.name_ar END,
           p.name
    INTO v_duration_minutes, v_service_name, v_provider_name
    FROM public.services AS s
    JOIN public.provider_services AS ps
      ON ps.clinic_id = s.clinic_id
     AND ps.service_id = s.id
     AND ps.provider_id = p_provider_id
    JOIN public.providers AS p
      ON p.id = ps.provider_id
     AND p.clinic_id = ps.clinic_id
    WHERE s.id = p_service_id
      AND s.clinic_id = p_clinic_id
      AND s.active
      AND p.active;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'service_not_offered');
    END IF;

    BEGIN
        v_slot_step_minutes := COALESCE((v_settings ->> 'slot_step_minutes')::integer, 30);
        v_min_notice_minutes := COALESCE((v_settings ->> 'min_notice_minutes')::integer, 60);
        v_max_days_ahead := COALESCE((v_settings ->> 'max_days_ahead')::integer, 30);
    EXCEPTION
        WHEN invalid_text_representation OR numeric_value_out_of_range THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END;

    IF v_slot_step_minutes <= 0 OR v_min_notice_minutes < 0 OR v_max_days_ahead < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    IF p_starts_at < now() + make_interval(mins => v_min_notice_minutes) THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = p_contact_id
          AND status <> 'closed';

        PERFORM public.enqueue_message(
            p_clinic_id,
            p_contact_id,
            'text',
            jsonb_build_object(
                'text',
                CASE WHEN v_language = 'en'
                    THEN 'That appointment time has passed the minimum booking notice window. Please ask me for new available times.'
                    ELSE 'عفواً الميعاد ده اقترب جداً وانتهت مهلة الحجز المتاحة له قولي أشوفلك أقرب ميعاد تاني'
                END
            ),
            'appt-too-soon-' || p_contact_id::text || '-' || extract(epoch from p_starts_at)::bigint::text,
            false
        );

        RETURN jsonb_build_object('ok', false, 'reason', 'too_soon');
    END IF;

    IF p_starts_at > now() + make_interval(days => v_max_days_ahead) THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = p_contact_id
          AND status <> 'closed';

        PERFORM public.enqueue_message(
            p_clinic_id,
            p_contact_id,
            'text',
            jsonb_build_object(
                'text',
                CASE WHEN v_language = 'en'
                    THEN 'That date is beyond the maximum advance booking window. Please choose a closer date.'
                    ELSE 'عفواً التاريخ ده أبعد من الفترة المتاحة للحجز حالياً تحب نشوف ميعاد أقرب؟'
                END
            ),
            'appt-too-far-' || p_contact_id::text || '-' || extract(epoch from p_starts_at)::bigint::text,
            false
        );

        RETURN jsonb_build_object('ok', false, 'reason', 'too_far');
    END IF;

    v_start_local := p_starts_at AT TIME ZONE v_timezone;
    v_end_at := p_starts_at + make_interval(mins => v_duration_minutes);
    v_end_local := v_end_at AT TIME ZONE v_timezone;

    IF NOT EXISTS (
        SELECT 1
        FROM public.working_hours AS wh
        WHERE wh.clinic_id = p_clinic_id
          AND wh.provider_id = p_provider_id
          AND wh.weekday = extract(dow FROM v_start_local)::smallint
          AND v_start_local::time >= wh.start_time
          AND v_end_local <= date_trunc('day', v_start_local) + wh.end_time
    ) THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = p_contact_id
          AND status <> 'closed';

        PERFORM public.enqueue_message(
            p_clinic_id,
            p_contact_id,
            'text',
            jsonb_build_object(
                'text',
                CASE WHEN v_language = 'en'
                    THEN 'That time is outside the doctor working hours. Please ask me for available times.'
                    ELSE 'عفواً التوقيت ده خارج مواعيد عمل الدكتور حالياً قولي أعرضلك المواعيد المتاحة'
                END
            ),
            'appt-outside-hours-' || p_contact_id::text || '-' || extract(epoch from p_starts_at)::bigint::text,
            false
        );

        RETURN jsonb_build_object('ok', false, 'reason', 'outside_hours');
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.working_hours AS wh
        WHERE wh.clinic_id = p_clinic_id
          AND wh.provider_id = p_provider_id
          AND wh.weekday = extract(dow FROM v_start_local)::smallint
          AND v_start_local::time >= wh.start_time
          AND v_end_local <= date_trunc('day', v_start_local) + wh.end_time
          AND mod(
              extract(epoch FROM (
                  v_start_local - (date_trunc('day', v_start_local) + wh.start_time)
              )),
              v_slot_step_minutes::numeric * 60
          ) = 0
    ) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    v_template := v_settings #>> ARRAY['messages', 'booking_confirmed', v_language];
    IF v_template IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    BEGIN
        INSERT INTO public.appointments (
            clinic_id, contact_id, provider_id, service_id,
            starts_at, ends_at, source
        )
        VALUES (
            p_clinic_id, p_contact_id, p_provider_id, p_service_id,
            p_starts_at, v_end_at, COALESCE(p_source, 'whatsapp')
        )
        RETURNING id INTO v_appointment_id;
    EXCEPTION
        WHEN exclusion_violation THEN
            SELECT a.id
            INTO v_appointment_id
            FROM public.appointments AS a
            WHERE a.clinic_id = p_clinic_id
              AND a.contact_id = p_contact_id
              AND a.provider_id = p_provider_id
              AND a.service_id = p_service_id
              AND a.starts_at = p_starts_at
              AND a.status = 'confirmed'
            ORDER BY a.created_at, a.id
            LIMIT 1;

            IF FOUND THEN
                UPDATE public.conversations
                SET state = state - 'pending_booking'
                WHERE clinic_id = p_clinic_id
                  AND contact_id = p_contact_id
                  AND status <> 'closed';

                RETURN jsonb_build_object(
                    'ok', true,
                    'appointment_id', v_appointment_id,
                    'idempotent', true
                );
            END IF;

            UPDATE public.conversations
            SET state = state - 'pending_booking'
            WHERE clinic_id = p_clinic_id
              AND contact_id = p_contact_id
              AND status <> 'closed';

            PERFORM public.enqueue_message(
                p_clinic_id,
                p_contact_id,
                'text',
                jsonb_build_object(
                    'text',
                    CASE WHEN v_language = 'en'
                        THEN 'That time is no longer available, so nothing was booked. Please ask me for available times again.'
                        ELSE 'الميعاد ده اتشغل للأسف قبل ما نأكده ومتمش تسجيل الحجز تحب أعرضلك المواعيد المتاحة تاني؟'
                    END
                ),
                'appt-slot-taken-' || p_contact_id::text || '-' || extract(epoch from p_starts_at)::bigint::text,
                false
            );

            RETURN jsonb_build_object('ok', false, 'reason', 'slot_taken');
    END;

    UPDATE public.conversations
    SET state = state - 'pending_booking'
    WHERE clinic_id = p_clinic_id
      AND contact_id = p_contact_id
      AND status <> 'closed';

    -- Always build confirmation text deterministically from DB template
    v_message := replace(
        replace(
            replace(
                replace(v_template, '{{service}}', v_service_name),
                '{{doctor}}', v_provider_name
            ),
            '{{date}}', to_char(v_start_local, 'YYYY-MM-DD')
        ),
        '{{time}}', to_char(v_start_local, 'HH24:MI')
    );

    PERFORM public.enqueue_message(
        p_clinic_id,
        p_contact_id,
        'text',
        jsonb_build_object('text', v_message),
        'appt-confirm-' || v_appointment_id::text,
        false
    );

    RETURN jsonb_build_object(
        'ok', true,
        'appointment_id', v_appointment_id,
        'starts_at', p_starts_at,
        'message_text', v_message
    );
END;
$function$;

-- ---------------------------------------------------------------------
-- public.cancel_appointment(p_clinic_id uuid, p_appointment_id uuid, p_contact_id uuid, p_reason text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_appointment(p_clinic_id uuid, p_appointment_id uuid, p_contact_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_appointment public.appointments%ROWTYPE;
    v_timezone text;
    v_settings jsonb;
    v_language text;
    v_provider_name text;
    v_service_name text;
    v_start_local timestamp without time zone;
    v_template text;
    v_message text;
BEGIN
    IF p_clinic_id IS NULL OR p_contact_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    IF p_appointment_id IS NOT NULL THEN
        SELECT a.*
        INTO v_appointment
        FROM public.appointments AS a
        WHERE a.clinic_id = p_clinic_id
          AND a.id = p_appointment_id
        FOR UPDATE;

        IF FOUND THEN
            IF v_appointment.contact_id <> p_contact_id THEN
                RETURN jsonb_build_object('ok', false, 'reason', 'not_owner');
            END IF;
            IF v_appointment.status = 'cancelled' THEN
                RETURN jsonb_build_object(
                    'ok', true,
                    'appointment_id', v_appointment.id,
                    'status', 'cancelled',
                    'idempotent', true
                );
            END IF;
        END IF;
    ELSE
        SELECT a.*
        INTO v_appointment
        FROM public.appointments AS a
        WHERE a.clinic_id = p_clinic_id
          AND a.contact_id = p_contact_id
          AND a.status = 'confirmed'
          AND a.starts_at >= now()
        ORDER BY a.starts_at ASC
        LIMIT 1
        FOR UPDATE;
    END IF;

    IF v_appointment.id IS NULL OR v_appointment.status <> 'confirmed' THEN
        SELECT COALESCE(ct.language, 'ar') INTO v_language
        FROM public.contacts ct
        WHERE ct.id = p_contact_id AND ct.clinic_id = p_clinic_id;

        v_message := CASE WHEN v_language = 'en'
            THEN 'We could not find an active upcoming appointment to cancel. How else can we help you?'
            ELSE 'ملقيناش موعد مؤكد قادم مسجل ليك حالياً عشان نلغيه، تحب أساعدك في حجز موعد جديد؟'
        END;

        PERFORM public.enqueue_message(
            p_clinic_id, p_contact_id, 'text',
            jsonb_build_object('text', v_message),
            'appt-cancel-notfound-' || p_contact_id::text || '-' || to_char(now(), 'YYYYMMDDHH24MI'),
            false
        );
        RETURN jsonb_build_object('ok', false, 'reason', 'appointment_not_found');
    END IF;

    SELECT c.timezone,
           c.settings,
           ct.language,
           p.name,
           CASE WHEN ct.language = 'en' THEN s.name_en ELSE s.name_ar END
    INTO v_timezone, v_settings, v_language, v_provider_name, v_service_name
    FROM public.clinics AS c
    JOIN public.contacts AS ct
      ON ct.id = v_appointment.contact_id
     AND ct.clinic_id = v_appointment.clinic_id
    JOIN public.providers AS p
      ON p.id = v_appointment.provider_id
     AND p.clinic_id = v_appointment.clinic_id
    JOIN public.services AS s
      ON s.id = v_appointment.service_id
     AND s.clinic_id = v_appointment.clinic_id
    WHERE c.id = v_appointment.clinic_id;

    UPDATE public.appointments AS a
    SET status = 'cancelled',
        cancelled_at = now(),
        cancel_reason = COALESCE(p_reason, 'cancelled_by_patient_whatsapp')
    WHERE a.id = v_appointment.id
      AND a.clinic_id = p_clinic_id;

    UPDATE public.conversations
    SET state = state - 'pending_booking'
    WHERE clinic_id = p_clinic_id
      AND contact_id = p_contact_id
      AND status <> 'closed';

    v_template := COALESCE(
        v_settings #>> ARRAY['messages', 'booking_cancelled', v_language],
        CASE WHEN v_language = 'en'
            THEN 'Your {{service}} appointment with {{doctor}} on {{date}} at {{time}} has been cancelled.'
            ELSE 'تم إلغاء موعد {{service}} مع {{doctor}} يوم {{date}} الساعة {{time}} بنجاح، وتنورنا في أي وقت.'
        END
    );

    v_start_local := v_appointment.starts_at AT TIME ZONE v_timezone;
    v_message := replace(
        replace(
            replace(
                replace(v_template, '{{service}}', v_service_name),
                '{{doctor}}', v_provider_name
            ),
            '{{date}}', to_char(v_start_local, 'YYYY-MM-DD')
        ),
        '{{time}}', to_char(v_start_local, 'HH24:MI')
    );

    PERFORM public.enqueue_message(
        p_clinic_id,
        p_contact_id,
        'text',
        jsonb_build_object('text', v_message),
        'appt-cancel-' || v_appointment.id::text,
        false
    );

    RETURN jsonb_build_object(
        'ok', true,
        'appointment_id', v_appointment.id,
        'status', 'cancelled',
        'message_text', v_message
    );
END;
$function$;

-- ---------------------------------------------------------------------
-- public.cancel_patient_appointments_from_chat(p_clinic_id uuid, p_contact_id uuid)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_patient_appointments_from_chat(p_clinic_id uuid, p_contact_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN
    RETURN public.cancel_appointment(
        p_clinic_id,
        NULL::uuid,
        p_contact_id,
        'cancelled_by_patient_whatsapp'
    );
END;
$function$;

-- ---------------------------------------------------------------------
-- public.claim_outbox_batch(p_batch_size integer, p_clinic_id uuid)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_outbox_batch(p_batch_size integer DEFAULT 10, p_clinic_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(outbox_id uuid, clinic_id uuid, contact_id uuid, recipient_phone text, message_kind text, payload jsonb, attempt_count integer, max_attempts integer, claim_token uuid, claimed_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
#variable_conflict use_column
DECLARE
    v_rec record;
    v_message text;
    v_msg jsonb;
    v_date text;
    v_time text;
BEGIN
    IF p_batch_size IS NULL OR p_batch_size < 1 OR p_batch_size > 100 THEN
        RAISE EXCEPTION 'p_batch_size must be between 1 and 100'
            USING ERRCODE = '22023';
    END IF;

    -- 0. Auto-resume stale 'human' conversations back to 'bot' after timeout
    UPDATE public.conversations cv
    SET status = 'bot'
    FROM public.clinics c
    WHERE cv.clinic_id = c.id
      AND cv.status = 'human'
      AND (p_clinic_id IS NULL OR cv.clinic_id = p_clinic_id)
      AND COALESCE(cv.last_inbound_at, cv.created_at)
          <= now() - make_interval(hours => GREATEST(COALESCE((c.settings ->> 'human_handoff_timeout_hours')::integer, 12), 1));

    -- 1A. Enqueue due appointment reminders (at least 30 min after booking creation so confirmation & reminder don't collide)
    FOR v_rec IN
        SELECT
            a.id AS appointment_id,
            a.clinic_id AS appt_clinic_id,
            a.contact_id AS appt_contact_id,
            a.starts_at,
            c.timezone,
            c.settings AS clinic_settings,
            coalesce(ct.language, 'ar') AS lang,
            p.name AS provider_name,
            CASE WHEN ct.language = 'en' THEN s.name_en ELSE s.name_ar END AS service_name,
            COALESCE(
                c.settings #>> ARRAY['messages', 'appointment_reminder', coalesce(ct.language, 'ar')],
                CASE WHEN ct.language = 'en'
                    THEN 'Appointment reminder: {{service}} with {{doctor}} on {{date}} at {{time}}. We look forward to seeing you!'
                    ELSE 'تذكير بموعدك: {{service}} مع {{doctor}} بتاريخ {{date}} الساعة {{time}}. نتطلع لرؤيتك!'
                END
            ) AS template_text,
            EXISTS (
                SELECT 1 FROM public.conversations cv
                WHERE cv.clinic_id = a.clinic_id
                  AND cv.contact_id = a.contact_id
                  AND cv.status <> 'closed'
                  AND cv.last_inbound_at >= now() - interval '23 hours'
                  AND cv.last_inbound_at <= now()
            ) AS in_window
        FROM public.appointments a
        JOIN public.clinics c ON c.id = a.clinic_id
        JOIN public.contacts ct ON ct.id = a.contact_id AND ct.clinic_id = a.clinic_id
        JOIN public.providers p ON p.id = a.provider_id AND p.clinic_id = a.clinic_id
        JOIN public.services s ON s.id = a.service_id AND s.clinic_id = a.clinic_id
        WHERE a.status = 'confirmed'
          AND a.reminder_sent_at IS NULL
          AND (p_clinic_id IS NULL OR a.clinic_id = p_clinic_id)
          AND ct.communications_opted_out_at IS NULL
          AND a.created_at <= now() - interval '30 minutes'
          AND a.starts_at > now()
          AND a.starts_at <= now() + make_interval(hours => COALESCE((c.settings ->> 'reminder_hours_before')::integer, 24))
        ORDER BY a.starts_at, a.id
        FOR UPDATE OF a SKIP LOCKED
    LOOP
        v_date := to_char(v_rec.starts_at AT TIME ZONE v_rec.timezone, 'YYYY-MM-DD');
        v_time := to_char(v_rec.starts_at AT TIME ZONE v_rec.timezone, 'HH24:MI');
        v_message := replace(replace(replace(replace(v_rec.template_text,
            '{{service}}', v_rec.service_name),
            '{{doctor}}', v_rec.provider_name),
            '{{date}}', v_date),
            '{{time}}', v_time);

        v_msg := private.build_whatsapp_message(
            v_rec.clinic_settings, 'appointment_reminder', v_rec.lang, v_message,
            ARRAY[v_rec.service_name, v_rec.provider_name, v_date, v_time],
            v_rec.in_window
        );

        INSERT INTO public.outbox (clinic_id, contact_id, kind, payload, is_marketing, idempotency_key)
        VALUES (
            v_rec.appt_clinic_id, v_rec.appt_contact_id,
            v_msg ->> 'kind', v_msg -> 'payload', false,
            'appt-reminder-' || v_rec.appointment_id::text
        )
        ON CONFLICT (clinic_id, idempotency_key) DO NOTHING;

        UPDATE public.appointments
        SET reminder_sent_at = now()
        WHERE id = v_rec.appointment_id
          AND clinic_id = v_rec.appt_clinic_id;
    END LOOP;

    -- 1B. Enqueue post-visit follow-ups (2 hours after ends_at)
    FOR v_rec IN
        SELECT
            a.id AS appointment_id,
            a.clinic_id AS appt_clinic_id,
            a.contact_id AS appt_contact_id,
            c.settings AS clinic_settings,
            coalesce(ct.language, 'ar') AS lang,
            p.name AS provider_name,
            CASE WHEN ct.language = 'en' THEN s.name_en ELSE s.name_ar END AS service_name,
            COALESCE(
                c.settings #>> ARRAY['messages', 'post_visit_followup', coalesce(ct.language, 'ar')],
                CASE WHEN ct.language = 'en'
                    THEN 'We hope your {{service}} visit with {{doctor}} went well! Reply anytime if you have any questions.'
                    ELSE 'حمداً لله على سلامتك! نتمنى أن تكون زيارتك لـ {{service}} مع {{doctor}} كانت مريحة. لو عندك أي استفسار إحنا في خدمتك دائماً.'
                END
            ) AS template_text,
            EXISTS (
                SELECT 1 FROM public.conversations cv
                WHERE cv.clinic_id = a.clinic_id
                  AND cv.contact_id = a.contact_id
                  AND cv.status <> 'closed'
                  AND cv.last_inbound_at >= now() - interval '23 hours'
                  AND cv.last_inbound_at <= now()
            ) AS in_window
        FROM public.appointments a
        JOIN public.clinics c ON c.id = a.clinic_id
        JOIN public.contacts ct ON ct.id = a.contact_id AND ct.clinic_id = a.clinic_id
        JOIN public.providers p ON p.id = a.provider_id AND p.clinic_id = a.clinic_id
        JOIN public.services s ON s.id = a.service_id AND s.clinic_id = a.clinic_id
        WHERE a.status = 'confirmed'
          AND a.followup_sent_at IS NULL
          AND (p_clinic_id IS NULL OR a.clinic_id = p_clinic_id)
          AND ct.communications_opted_out_at IS NULL
          AND a.ends_at + interval '2 hours' <= now()
          AND a.ends_at >= now() - interval '24 hours'
        ORDER BY a.ends_at, a.id
        FOR UPDATE OF a SKIP LOCKED
    LOOP
        v_message := replace(replace(v_rec.template_text,
            '{{service}}', v_rec.service_name),
            '{{doctor}}', v_rec.provider_name);

        v_msg := private.build_whatsapp_message(
            v_rec.clinic_settings, 'post_visit_followup', v_rec.lang, v_message,
            ARRAY[v_rec.service_name, v_rec.provider_name],
            v_rec.in_window
        );

        INSERT INTO public.outbox (clinic_id, contact_id, kind, payload, is_marketing, idempotency_key)
        VALUES (
            v_rec.appt_clinic_id, v_rec.appt_contact_id,
            v_msg ->> 'kind', v_msg -> 'payload', false,
            'appt-followup-' || v_rec.appointment_id::text
        )
        ON CONFLICT (clinic_id, idempotency_key) DO NOTHING;

        UPDATE public.appointments
        SET followup_sent_at = now()
        WHERE id = v_rec.appointment_id
          AND clinic_id = v_rec.appt_clinic_id;
    END LOOP;

    -- 2. Expire stale processing claims
    WITH stale AS (
        SELECT o.id, o.clinic_id, o.send_authorized_at
        FROM public.outbox AS o
        WHERE o.status = 'processing'
          AND (o.locked_at IS NULL OR o.locked_at < now() - interval '15 minutes')
          AND (p_clinic_id IS NULL OR o.clinic_id = p_clinic_id)
        ORDER BY o.locked_at NULLS FIRST, o.created_at, o.id
        LIMIT p_batch_size
        FOR UPDATE OF o SKIP LOCKED
    ),
    marked_stale AS (
        UPDATE public.outbox AS o
        SET status = CASE WHEN stale.send_authorized_at IS NULL THEN 'failed' ELSE 'dead' END,
            next_attempt_at = CASE
                WHEN stale.send_authorized_at IS NULL THEN now() + interval '30 seconds'
                ELSE o.next_attempt_at
            END,
            locked_at = NULL,
            claim_token = CASE WHEN stale.send_authorized_at IS NULL THEN NULL ELSE o.claim_token END,
            last_error = CASE
                WHEN stale.send_authorized_at IS NULL THEN 'claim_expired_before_authorization'
                ELSE 'delivery_outcome_unknown'
            END
        FROM stale
        WHERE o.id = stale.id
        RETURNING o.id, o.clinic_id, o.status, o.last_error
    )
    INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
    SELECT ms.clinic_id, 'error', 'outbox', 'outbox_message_dead',
           jsonb_build_object('outbox_id', ms.id, 'reason', ms.last_error)
    FROM marked_stale ms
    WHERE ms.status = 'dead';

    -- 3. Claim due outbox batch
    RETURN QUERY
    WITH candidates AS (
        SELECT
            o.id,
            c.communications_opted_out_at IS NOT NULL AS all_messages_opted_out,
            (o.is_marketing AND c.opted_out_at IS NOT NULL) AS contact_opted_out,
            (
                o.kind <> 'template'
                AND NOT EXISTS (
                    SELECT 1
                    FROM public.conversations AS cv
                    WHERE cv.clinic_id = o.clinic_id
                      AND cv.contact_id = o.contact_id
                      AND cv.status <> 'closed'
                      AND cv.last_inbound_at >= now() - interval '24 hours'
                      AND cv.last_inbound_at <= now()
                )
            ) AS session_window_closed,
            o.attempts >= o.max_attempts AS attempts_exhausted
        FROM public.outbox AS o
        JOIN public.contacts AS c
          ON c.clinic_id = o.clinic_id
         AND c.id = o.contact_id
        WHERE o.status IN ('pending', 'failed')
          AND o.next_attempt_at <= now()
          AND (p_clinic_id IS NULL OR o.clinic_id = p_clinic_id)
        ORDER BY o.next_attempt_at, o.created_at, o.id
        LIMIT p_batch_size
        FOR UPDATE OF o SKIP LOCKED
    ),
    changed AS (
        UPDATE public.outbox AS o
        SET status = CASE
                WHEN candidates.all_messages_opted_out THEN 'dead'
                WHEN candidates.contact_opted_out THEN 'dead'
                WHEN candidates.session_window_closed THEN 'dead'
                WHEN candidates.attempts_exhausted THEN 'dead'
                ELSE 'processing'
            END,
            attempts = CASE
                WHEN candidates.all_messages_opted_out
                  OR candidates.contact_opted_out
                  OR candidates.session_window_closed
                  OR candidates.attempts_exhausted THEN o.attempts
                ELSE o.attempts + 1
            END,
            locked_at = CASE
                WHEN candidates.all_messages_opted_out
                  OR candidates.contact_opted_out
                  OR candidates.session_window_closed
                  OR candidates.attempts_exhausted THEN NULL
                ELSE now()
            END,
            claim_token = CASE
                WHEN candidates.all_messages_opted_out
                  OR candidates.contact_opted_out
                  OR candidates.session_window_closed
                  OR candidates.attempts_exhausted THEN o.claim_token
                ELSE gen_random_uuid()
            END,
            send_authorized_at = CASE
                WHEN candidates.all_messages_opted_out
                  OR candidates.contact_opted_out
                  OR candidates.session_window_closed
                  OR candidates.attempts_exhausted THEN o.send_authorized_at
                ELSE NULL
            END,
            last_error = CASE
                WHEN candidates.all_messages_opted_out THEN 'communications_opted_out'
                WHEN candidates.contact_opted_out THEN 'contact_opted_out'
                WHEN candidates.session_window_closed THEN 'session_window_closed'
                WHEN candidates.attempts_exhausted THEN 'max_attempts_exhausted'
                ELSE NULL
            END
        FROM candidates
        WHERE o.id = candidates.id
        RETURNING o.id, o.clinic_id, o.contact_id, o.kind, o.payload, o.status,
                  o.attempts, o.max_attempts, o.claim_token, o.locked_at, o.last_error
    ),
    dead_events AS (
        INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
        SELECT ch.clinic_id, 'error', 'outbox', 'outbox_message_dead',
               jsonb_build_object(
                   'outbox_id', ch.id,
                   'contact_id', ch.contact_id,
                   'reason', ch.last_error,
                   'attempts', ch.attempts
               )
        FROM changed ch
        WHERE ch.status = 'dead'
    )
    SELECT changed.id, changed.clinic_id, changed.contact_id, c.phone_e164, changed.kind,
           changed.payload, changed.attempts, changed.max_attempts, changed.claim_token,
           changed.locked_at
    FROM changed
    JOIN public.contacts AS c
      ON c.clinic_id = changed.clinic_id
     AND c.id = changed.contact_id
    WHERE changed.status = 'processing'
    ORDER BY changed.locked_at, changed.id;
END;
$function$;

-- ---------------------------------------------------------------------
-- public.classify_whatsapp_opt_out_scope(p_body text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.classify_whatsapp_opt_out_scope(p_body text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  SELECT CASE
    WHEN regexp_replace(
           translate(
             regexp_replace(lower(btrim(coalesce(p_body,''))), '[\u064B-\u065F\u0670\u0640]', '', 'g'),
             'أإآةى', 'اااهي'
           ),
           '[.!؟?،,؛;\s]+$', ''
         ) = ANY (ARRAY[
        'stop','unsubscribe','stop all','stop please','please stop','opt out','opt-out',
        'ايقاف','توقف','اوقف',
        'الغاء الاشتراك','ايقاف الاشتراك',
        'ايقاف الرسائل','اوقف الرسائل','ايقاف الرسايل','اوقف الرسايل',
        'ايقاف كل الرسائل','اوقف كل الرسائل','ايقاف كل الرسايل','اوقف كل الرسايل'
      ]::text[])
      THEN 'all_communications'
    WHEN regexp_replace(
           translate(
             regexp_replace(lower(btrim(coalesce(p_body,''))), '[\u064B-\u065F\u0670\u0640]', '', 'g'),
             'أإآةى', 'اااهي'
           ),
           '[.!؟?،,؛;\s]+$', ''
         ) = ANY (ARRAY[
        'stop offers','stop marketing','stop promotions','offers off',
        'الغاء العروض','ايقاف العروض','اوقف العروض',
        'الغاء التسويق','ايقاف التسويق','اوقف التسويق',
        'الغاء الرسائل التسويقيه','الغاء الرسايل التسويقيه',
        'ايقاف الرسائل التسويقيه','ايقاف الرسايل التسويقيه'
      ]::text[])
      THEN 'marketing'
    ELSE NULL
  END;
$function$;

-- ---------------------------------------------------------------------
-- public.enqueue_message(p_clinic_id uuid, p_contact_id uuid, p_kind text, p_payload jsonb, p_idempotency_key text, p_is_marketing boolean)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enqueue_message(p_clinic_id uuid, p_contact_id uuid, p_kind text, p_payload jsonb, p_idempotency_key text, p_is_marketing boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_opted_out timestamptz;
    v_communications_opted_out timestamptz;
    v_outbox_id uuid;
BEGIN
    IF p_clinic_id IS NULL OR p_contact_id IS NULL
       OR p_kind IS NULL
       OR p_kind NOT IN ('text', 'interactive_list', 'interactive_buttons', 'template')
       OR p_payload IS NULL
       OR jsonb_typeof(p_payload) <> 'object'
       OR p_idempotency_key IS NULL
       OR p_idempotency_key !~ '^[A-Za-z0-9:_./+=-]{1,200}$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    IF p_kind = 'text' THEN
        IF jsonb_typeof(p_payload -> 'text') IS DISTINCT FROM 'string'
           OR btrim(p_payload ->> 'text') = ''
           OR length(p_payload ->> 'text') > 4096 THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payload');
        END IF;
    ELSIF p_kind = 'interactive_list' THEN
        IF p_payload #>> '{interactive,type}' IS DISTINCT FROM 'list'
           OR jsonb_typeof(p_payload #> '{interactive,body,text}') IS DISTINCT FROM 'string'
           OR jsonb_typeof(p_payload #> '{interactive,action,sections}') IS DISTINCT FROM 'array' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payload');
        END IF;
    ELSIF p_kind = 'interactive_buttons' THEN
        IF p_payload #>> '{interactive,type}' IS DISTINCT FROM 'button'
           OR jsonb_typeof(p_payload #> '{interactive,body,text}') IS DISTINCT FROM 'string'
           OR jsonb_typeof(p_payload #> '{interactive,action,buttons}') IS DISTINCT FROM 'array'
           OR jsonb_array_length(p_payload #> '{interactive,action,buttons}') NOT BETWEEN 1 AND 3 THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payload');
        END IF;
    ELSIF p_kind = 'template' THEN
        IF jsonb_typeof(p_payload #> '{template,name}') IS DISTINCT FROM 'string'
           OR jsonb_typeof(p_payload #> '{template,language,code}') IS DISTINCT FROM 'string' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payload');
        END IF;
    END IF;

    SELECT ct.opted_out_at, ct.communications_opted_out_at
    INTO v_opted_out, v_communications_opted_out
    FROM public.contacts AS ct
    WHERE ct.id = p_contact_id
      AND ct.clinic_id = p_clinic_id
    FOR UPDATE OF ct;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    IF v_communications_opted_out IS NOT NULL THEN
        RETURN jsonb_build_object('ok', true, 'enqueued', false, 'reason', 'communications_opted_out');
    END IF;

    IF v_opted_out IS NOT NULL AND COALESCE(p_is_marketing, false) THEN
        RETURN jsonb_build_object('ok', true, 'enqueued', false, 'reason', 'opted_out');
    END IF;

    INSERT INTO public.outbox (clinic_id, contact_id, kind, payload, is_marketing, idempotency_key)
    VALUES (p_clinic_id, p_contact_id, p_kind, p_payload, COALESCE(p_is_marketing, false), p_idempotency_key)
    ON CONFLICT (clinic_id, idempotency_key) DO NOTHING
    RETURNING id INTO v_outbox_id;

    IF v_outbox_id IS NULL THEN
        SELECT o.id INTO v_outbox_id
        FROM public.outbox AS o
        WHERE o.clinic_id = p_clinic_id
          AND o.idempotency_key = p_idempotency_key;

        RETURN jsonb_build_object('ok', true, 'enqueued', false, 'reason', 'duplicate', 'outbox_id', v_outbox_id);
    END IF;

    RETURN jsonb_build_object('ok', true, 'enqueued', true, 'outbox_id', v_outbox_id);
END;
$function$;

-- ---------------------------------------------------------------------
-- public.get_available_slots(p_clinic_id uuid, p_service_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_provider_id uuid, p_limit integer)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_available_slots(p_clinic_id uuid, p_service_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_provider_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 10)
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
        FROM generate_series(
            ((p_from AT TIME ZONE v_timezone)::date)::timestamp,
            ((p_to AT TIME ZONE v_timezone)::date)::timestamp,
            interval '1 day'
        ) AS day_series(day_value)
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
            AND tstzrange(a.starts_at, a.ends_at, '[)')
                && tstzrange(slot_ranges.slot_start, slot_ranges.slot_end, '[)')
      )
    ORDER BY slot_ranges.slot_start, slot_ranges.offered_provider_name,
             slot_ranges.offered_provider_id
    LIMIT p_limit;
END;
$function$;

-- ---------------------------------------------------------------------
-- public.get_clinic_snapshot(p_clinic_id uuid)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_clinic_snapshot(p_clinic_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  WITH tz AS (
    SELECT
      c.*,
      extract(epoch FROM ((now() AT TIME ZONE c.timezone) - (now() AT TIME ZONE 'UTC')))::integer AS offset_sec
    FROM public.clinics c
    WHERE c.id = p_clinic_id
  ),
  tz_fmt AS (
    SELECT
      tz.*,
      CASE WHEN tz.offset_sec >= 0 THEN '+' ELSE '-' END
        || to_char((abs(tz.offset_sec) || ' seconds')::interval, 'HH24:MI') AS utc_offset
    FROM tz
  )
  SELECT jsonb_build_object(
    'clinic_name', c.name,
    'timezone', c.timezone,
    'utc_offset', c.utc_offset,
    'now_local', to_char(now() AT TIME ZONE c.timezone, 'YYYY-MM-DD"T"HH24:MI:SS') || c.utc_offset,
    'weekday', trim(to_char(now() AT TIME ZONE c.timezone, 'FMDay')),
    'weekday_number_sunday_is_0', extract(dow FROM now() AT TIME ZONE c.timezone)::int,
    'location', c.settings ->> 'location',
    'parking', c.settings ->> 'parking',
    'payment_methods', coalesce(c.settings -> 'payment_methods', '[]'::jsonb),
    'installments_available', coalesce((c.settings ->> 'installments_available')::boolean, false),
    'emergency_number', coalesce(c.settings ->> 'emergency_number', '997'),
    'services', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', s.id, 'code', s.code, 'name_ar', s.name_ar, 'name_en', s.name_en,
               'duration_minutes', s.duration_minutes, 'price', s.price
             ) ORDER BY s.code)
      FROM public.services s
      WHERE s.clinic_id = c.id AND s.active
    ), '[]'::jsonb),
    'providers', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name, 'specialty', p.specialty,
               'service_codes', coalesce((
                 SELECT jsonb_agg(s2.code ORDER BY s2.code)
                 FROM public.provider_services ps
                 JOIN public.services s2
                   ON s2.id = ps.service_id AND s2.clinic_id = ps.clinic_id
                 WHERE ps.provider_id = p.id AND ps.clinic_id = p.clinic_id AND s2.active
               ), '[]'::jsonb)
             ) ORDER BY p.name)
      FROM public.providers p
      WHERE p.clinic_id = c.id AND p.active
    ), '[]'::jsonb),
    'working_hours', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'provider_id', wh.provider_id, 'weekday', wh.weekday,
               'start', to_char(wh.start_time, 'HH24:MI'), 'end', to_char(wh.end_time, 'HH24:MI')
             ) ORDER BY wh.provider_id, wh.weekday)
      FROM public.working_hours wh
      WHERE wh.clinic_id = c.id
    ), '[]'::jsonb),
    'faq', coalesce(c.settings -> 'faq', '[]'::jsonb)
  )
  FROM tz_fmt c;
$function$;

-- ---------------------------------------------------------------------
-- public.get_conversation_context(p_clinic_id uuid, p_contact_id uuid, p_limit integer, p_exclude_message_id uuid)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_conversation_context(p_clinic_id uuid, p_contact_id uuid, p_limit integer DEFAULT 8, p_exclude_message_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  SELECT coalesce(jsonb_agg(h.item ORDER BY h.at), '[]'::jsonb)
  FROM (
    SELECT x.at, x.item
    FROM (
      SELECT m.created_at AS at,
             jsonb_build_object('role', 'patient', 'text', left(coalesce(m.body, ''), 500), 'at', m.created_at) AS item
      FROM public.messages m
      JOIN public.conversations cv
        ON cv.id = m.conversation_id AND cv.clinic_id = m.clinic_id
      WHERE m.clinic_id = p_clinic_id
        AND cv.contact_id = p_contact_id
        AND m.direction = 'in'
        AND m.body IS NOT NULL
        AND btrim(m.body) <> ''
        AND (p_exclude_message_id IS NULL OR m.id <> p_exclude_message_id)
      UNION ALL
      SELECT coalesce(o.sent_at, o.created_at) AS at,
             jsonb_build_object(
               'role', 'clinic',
               'text', left(CASE o.kind
                              WHEN 'text' THEN coalesce(o.payload ->> 'text', '')
                              WHEN 'template' THEN '[template message]'
                              ELSE '[interactive message]'
                            END, 500),
               'at', coalesce(o.sent_at, o.created_at)
             ) AS item
      FROM public.outbox o
      WHERE o.clinic_id = p_clinic_id
        AND o.contact_id = p_contact_id
        AND o.status = 'sent'
    ) x
    ORDER BY x.at DESC
    LIMIT greatest(least(coalesce(p_limit, 8), 20), 1)
  ) h;
$function$;

-- ---------------------------------------------------------------------
-- public.get_conversation_fresh_state(p_clinic_id uuid, p_conversation_id uuid, p_message_id uuid)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_conversation_fresh_state(p_clinic_id uuid, p_conversation_id uuid, p_message_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  SELECT jsonb_build_object(
    'status', cv.status,
    'state', coalesce(cv.state, '{}'::jsonb),
    'is_superseded', CASE
      WHEN p_message_id IS NULL THEN false
      ELSE EXISTS (
        SELECT 1
        FROM public.messages m
        JOIN public.messages m2
          ON m2.clinic_id = m.clinic_id
         AND m2.conversation_id = m.conversation_id
        WHERE m.clinic_id = p_clinic_id
          AND m.id = p_message_id
          AND m2.direction = 'in'
          AND (
            m2.created_at > m.created_at
            OR (m2.created_at = m.created_at AND m2.id > m.id)
          )
      )
    END
  )
  FROM public.conversations cv
  WHERE cv.clinic_id = p_clinic_id
    AND cv.id = p_conversation_id;
$function$;

-- ---------------------------------------------------------------------
-- public.get_patient_upcoming_appointments(p_clinic_id uuid, p_contact_id uuid)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_patient_upcoming_appointments(p_clinic_id uuid, p_contact_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'appointment_id', a.id,
        'service_code', s.code,
        'service_name_ar', s.name_ar,
        'service_name_en', s.name_en,
        'doctor_name', p.name,
        'starts_at_utc', a.starts_at,
        'local_date', to_char(a.starts_at AT TIME ZONE c.timezone, 'YYYY-MM-DD'),
        'local_time', to_char(a.starts_at AT TIME ZONE c.timezone, 'HH24:MI'),
        'status', a.status
      )
      ORDER BY a.starts_at ASC
    ),
    '[]'::jsonb
  )
  FROM public.appointments a
  JOIN public.clinics c ON c.id = a.clinic_id
  LEFT JOIN public.services s ON s.id = a.service_id
  LEFT JOIN public.providers p ON p.id = a.provider_id
  WHERE a.clinic_id = p_clinic_id
    AND a.contact_id = p_contact_id
    AND a.status = 'confirmed'
    AND a.starts_at >= now();
$function$;

-- ---------------------------------------------------------------------
-- public.ingest_inbound_message(p_clinic_id uuid, p_phone text, p_contact_name text, p_provider_message_id text, p_message_type text, p_body text, p_payload jsonb, p_message_timestamp timestamp with time zone)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ingest_inbound_message(p_clinic_id uuid, p_phone text, p_contact_name text, p_provider_message_id text, p_message_type text, p_body text, p_payload jsonb DEFAULT NULL::jsonb, p_message_timestamp timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_phone text;
    v_received_at timestamptz;
    v_timeout_hours integer;
    v_contact_id uuid;
    v_language text;
    v_opted_out boolean;
    v_marketing_opted_out boolean;
    v_opt_out_scope text;
    v_conversation_id uuid;
    v_conversation_status text;
    v_last_inbound_at timestamptz;
    v_state jsonb;
    v_message_id uuid;
BEGIN
    v_phone := '+' || regexp_replace(coalesce(p_phone, ''), '^\+', '');

    IF p_clinic_id IS NULL
       OR v_phone !~ '^\+[1-9][0-9]{7,14}$'
       OR p_provider_message_id IS NULL
       OR btrim(p_provider_message_id) = ''
       OR length(p_provider_message_id) > 512
       OR p_provider_message_id ~ '[[:cntrl:]]'
       OR p_message_type IS NULL
       OR p_message_type !~ '^[a-z_]{1,40}$'
       OR length(coalesce(p_body, '')) > 4096
       OR length(coalesce(p_contact_name, '')) > 200 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    SELECT greatest(coalesce((c.settings ->> 'human_handoff_timeout_hours')::integer, 12), 1)
    INTO v_timeout_hours
    FROM public.clinics c
    WHERE c.id = p_clinic_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    v_received_at := least(coalesce(p_message_timestamp, now()), now());

    INSERT INTO public.contacts AS ct (clinic_id, phone_e164, name)
    VALUES (p_clinic_id, v_phone, nullif(btrim(p_contact_name), ''))
    ON CONFLICT (clinic_id, phone_e164)
    DO UPDATE SET name = coalesce(ct.name, excluded.name)
    RETURNING ct.id, ct.language,
              (ct.communications_opted_out_at IS NOT NULL),
              (ct.opted_out_at IS NOT NULL)
    INTO v_contact_id, v_language, v_opted_out, v_marketing_opted_out;

    SELECT cv.id, cv.status, cv.state, cv.last_inbound_at
    INTO v_conversation_id, v_conversation_status, v_state, v_last_inbound_at
    FROM public.conversations cv
    WHERE cv.clinic_id = p_clinic_id
      AND cv.contact_id = v_contact_id
      AND cv.status <> 'closed'
    ORDER BY cv.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        BEGIN
            INSERT INTO public.conversations (clinic_id, contact_id)
            VALUES (p_clinic_id, v_contact_id)
            RETURNING id, status, state, last_inbound_at
            INTO v_conversation_id, v_conversation_status, v_state, v_last_inbound_at;
        EXCEPTION WHEN unique_violation THEN
            SELECT cv.id, cv.status, cv.state, cv.last_inbound_at
            INTO v_conversation_id, v_conversation_status, v_state, v_last_inbound_at
            FROM public.conversations cv
            WHERE cv.clinic_id = p_clinic_id
              AND cv.contact_id = v_contact_id
              AND cv.status <> 'closed'
            ORDER BY cv.created_at DESC
            LIMIT 1
            FOR UPDATE;
        END;
    END IF;

    INSERT INTO public.messages (
        clinic_id, conversation_id, direction, provider_message_id,
        message_type, body, payload, delivery_status, created_at
    )
    VALUES (
        p_clinic_id, v_conversation_id, 'in', btrim(p_provider_message_id),
        p_message_type, p_body, p_payload, 'received', clock_timestamp()
    )
    ON CONFLICT (clinic_id, provider_message_id) WHERE provider_message_id IS NOT NULL
    DO NOTHING
    RETURNING id INTO v_message_id;

    v_opt_out_scope := public.classify_whatsapp_opt_out_scope(p_body);

    IF v_message_id IS NULL THEN
        RETURN jsonb_build_object(
            'ok', true,
            'is_duplicate', true,
            'contact_id', v_contact_id,
            'conversation_id', v_conversation_id,
            'conversation_status', v_conversation_status,
            'conversation_state', v_state,
            'opted_out', v_opted_out,
            'marketing_opted_out', v_marketing_opted_out,
            'opt_out_scope', v_opt_out_scope,
            'language', v_language
        );
    END IF;

    IF v_opt_out_scope = 'all_communications' THEN
        PERFORM public.set_communications_opt_out(p_clinic_id, v_contact_id, true);
    ELSIF v_opt_out_scope = 'marketing' THEN
        PERFORM public.set_opt_out(p_clinic_id, v_contact_id, true);
    END IF;

    SELECT (ct.communications_opted_out_at IS NOT NULL),
           (ct.opted_out_at IS NOT NULL)
    INTO v_opted_out, v_marketing_opted_out
    FROM public.contacts AS ct
    WHERE ct.clinic_id = p_clinic_id AND ct.id = v_contact_id;

    IF v_conversation_status = 'human'
       AND v_last_inbound_at IS NOT NULL
       AND v_last_inbound_at < v_received_at - make_interval(hours => v_timeout_hours) THEN
        v_conversation_status := 'bot';
    END IF;

    UPDATE public.conversations cv
    SET status = v_conversation_status,
        last_inbound_at = GREATEST(COALESCE(cv.last_inbound_at, v_received_at), v_received_at),
        followup_count = 0
    WHERE cv.id = v_conversation_id;

    RETURN jsonb_build_object(
        'ok', true,
        'is_duplicate', false,
        'contact_id', v_contact_id,
        'conversation_id', v_conversation_id,
        'message_id', v_message_id,
        'conversation_status', v_conversation_status,
        'conversation_state', v_state,
        'opted_out', v_opted_out,
        'marketing_opted_out', v_marketing_opted_out,
        'opt_out_scope', v_opt_out_scope,
        'language', v_language
    );
END;
$function$;

-- ---------------------------------------------------------------------
-- public.ingest_meta_webhook_batch(p_payload jsonb)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ingest_meta_webhook_batch(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_entry jsonb;
  v_change jsonb;
  v_value jsonb;
  v_meta jsonb;
  v_message jsonb;
  v_contact jsonb;
  v_status jsonb;
  v_phone_number_id text;
  v_clinic_id uuid;
  v_phone text;
  v_contact_name text;
  v_message_id text;
  v_message_type text;
  v_body text;
  v_message_timestamp timestamptz;
  v_provider_timestamp timestamptz;
  v_status_value text;
  v_error_code text;
  v_ingest jsonb;
  v_status_row record;
  v_new_messages jsonb := '[]'::jsonb;
  v_status_results jsonb := '[]'::jsonb;
  v_entries integer := 0;
  v_messages integer := 0;
  v_statuses integer := 0;
  v_duplicates integer := 0;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_payload->'entry') IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payload');
  END IF;

  FOR v_entry IN
    SELECT value FROM jsonb_array_elements(p_payload->'entry')
  LOOP
    IF jsonb_typeof(v_entry->'changes') IS DISTINCT FROM 'array' THEN
      CONTINUE;
    END IF;

    FOR v_change IN
      SELECT value FROM jsonb_array_elements(v_entry->'changes')
    LOOP
      v_value := v_change->'value';
      IF jsonb_typeof(v_value) IS DISTINCT FROM 'object' THEN
        CONTINUE;
      END IF;

      v_meta := v_value->'metadata';
      v_phone_number_id := v_meta->>'phone_number_id';
      v_clinic_id := public.resolve_whatsapp_clinic(v_phone_number_id);

      IF v_clinic_id IS NULL THEN
        INSERT INTO public.system_events (level, source, event_type, details)
        VALUES (
          'error',
          'webhook',
          'unconfigured_phone_number_id',
          jsonb_build_object('phone_number_id', v_phone_number_id)
        );
        CONTINUE;
      END IF;

      v_entries := v_entries + 1;

      IF jsonb_typeof(v_value->'messages') = 'array' THEN
        FOR v_message IN
          SELECT value FROM jsonb_array_elements(v_value->'messages')
        LOOP
          v_phone := v_message->>'from';
          v_message_id := v_message->>'id';
          v_message_type := coalesce(v_message->>'type','unknown');

          SELECT c.value #>> '{profile,name}'
            INTO v_contact_name
          FROM jsonb_array_elements(coalesce(v_value->'contacts','[]'::jsonb)) AS c(value)
          WHERE c.value->>'wa_id' = v_phone
          LIMIT 1;

          v_body := CASE v_message_type
            WHEN 'text' THEN v_message #>> '{text,body}'
            WHEN 'interactive' THEN coalesce(
              v_message #>> '{interactive,button_reply,title}',
              v_message #>> '{interactive,list_reply,title}',
              v_message #>> '{interactive,button_reply,id}',
              v_message #>> '{interactive,list_reply,id}'
            )
            WHEN 'button' THEN coalesce(
              v_message #>> '{button,text}',
              v_message #>> '{button,payload}'
            )
            ELSE NULL
          END;

          IF coalesce(v_message->>'timestamp','') ~ '^[0-9]{1,15}$' THEN
            v_message_timestamp := to_timestamp((v_message->>'timestamp')::double precision);
          ELSE
            v_message_timestamp := now();
          END IF;

          v_ingest := public.ingest_inbound_message(
            v_clinic_id,
            v_phone,
            v_contact_name,
            v_message_id,
            v_message_type,
            left(v_body, 4096),
            v_message,
            v_message_timestamp
          );

          IF coalesce((v_ingest->>'ok')::boolean, false) IS NOT TRUE THEN
            INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
            VALUES (
              v_clinic_id,
              'error',
              'webhook',
              'inbound_message_rejected',
              jsonb_build_object(
                'reason', v_ingest->>'reason',
                'provider_message_id', v_message_id,
                'phone', v_phone
              )
            );
            CONTINUE;
          END IF;

          IF coalesce((v_ingest->>'is_duplicate')::boolean, false) THEN
            v_duplicates := v_duplicates + 1;
          ELSE
            v_messages := v_messages + 1;
            v_new_messages := v_new_messages || jsonb_build_array(
              jsonb_build_object(
                'clinic_id', v_clinic_id,
                'phone_number_id', v_phone_number_id,
                'phone', v_phone,
                'contact_name', v_contact_name,
                'provider_message_id', v_message_id,
                'message_type', v_message_type,
                'body', v_body,
                'message_timestamp', v_message_timestamp,
                'contact_id', v_ingest->>'contact_id',
                'conversation_id', v_ingest->>'conversation_id',
                'message_id', v_ingest->>'message_id',
                'conversation_status', v_ingest->>'conversation_status',
                'conversation_state', coalesce(v_ingest->'conversation_state','{}'::jsonb),
                'opted_out', coalesce((v_ingest->>'opted_out')::boolean, false),
                'marketing_opted_out', coalesce((v_ingest->>'marketing_opted_out')::boolean, false),
                'opt_out_scope', v_ingest->>'opt_out_scope',
                'language', coalesce(v_ingest->>'language', 'ar'),
                'payload', v_message
              )
            );
          END IF;
        END LOOP;
      END IF;

      IF jsonb_typeof(v_value->'statuses') = 'array' THEN
        FOR v_status IN
          SELECT value FROM jsonb_array_elements(v_value->'statuses')
        LOOP
          v_message_id := v_status->>'id';
          v_status_value := v_status->>'status';
          v_error_code := v_status #>> '{errors,0,code}';

          IF coalesce(v_status->>'timestamp','') ~ '^[0-9]{1,15}$' THEN
            v_provider_timestamp := to_timestamp((v_status->>'timestamp')::double precision);
          ELSE
            v_provider_timestamp := now();
          END IF;

          FOR v_status_row IN
            SELECT * FROM public.apply_outbox_delivery_status(
              v_clinic_id,
              v_message_id,
              v_status_value,
              v_provider_timestamp,
              v_error_code
            )
          LOOP
            v_status_results := v_status_results || jsonb_build_array(to_jsonb(v_status_row));
          END LOOP;

          v_statuses := v_statuses + 1;
        END LOOP;
      END IF;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'entries_processed', v_entries,
    'messages_persisted', v_messages,
    'duplicates_ignored', v_duplicates,
    'statuses_processed', v_statuses,
    'messages', v_new_messages,
    'statuses', v_status_results
  );
END;
$function$;

-- ---------------------------------------------------------------------
-- public.log_workflow_error(p_workflow_name text, p_execution_id text, p_last_node text, p_error_class text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_workflow_error(p_workflow_name text, p_execution_id text, p_last_node text, p_error_class text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_clinic_id uuid;
  v_event_id bigint;
  v_exec_id text := nullif(left(btrim(coalesce(p_execution_id, '')), 64), '');
  v_node text := coalesce(nullif(left(btrim(coalesce(p_last_node, '')), 120), ''), 'unknown');
  v_err text := coalesce(nullif(left(btrim(coalesce(p_error_class, '')), 200), ''), 'Error');
BEGIN
  IF p_workflow_name IS NULL
     OR btrim(p_workflow_name) = ''
     OR p_workflow_name !~ '^ClinicOS[A-Za-z0-9 _—–-]{0,100}$'
     OR (v_exec_id IS NOT NULL AND v_exec_id !~ '^[0-9A-Za-z_:-]{1,64}$') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
  END IF;

  SELECT id INTO v_clinic_id FROM public.clinics LIMIT 1;
  IF v_clinic_id IS NULL THEN
    v_clinic_id := '5b201616-fdf0-4a37-8863-bd050ea90376'::uuid;
  END IF;

  INSERT INTO public.system_events (
    clinic_id, level, source, event_type, details
  )
  VALUES (
    v_clinic_id,
    'error', 'n8n', 'workflow_execution_failed',
    jsonb_build_object(
      'workflow_name', btrim(p_workflow_name),
      'execution_id', v_exec_id,
      'last_node', v_node,
      'error_class', v_err
    )
  )
  RETURNING id INTO v_event_id;

  RETURN jsonb_build_object('ok', true, 'event_id', v_event_id);
END;
$function$;

-- ---------------------------------------------------------------------
-- public.mark_outbox_failure(p_outbox_id uuid, p_claim_token uuid, p_failure_class text, p_error_code text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_outbox_failure(p_outbox_id uuid, p_claim_token uuid, p_failure_class text, p_error_code text)
 RETURNS TABLE(outbox_id uuid, status text, outcome text, next_attempt_at timestamp with time zone, attempt_count integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_clinic_id uuid;
    v_status text;
    v_last_error text;
    v_next_attempt_at timestamptz;
    v_attempts integer;
    v_max_attempts integer;
    v_claim_token uuid;
    v_expected_error text;
    v_authorized boolean;
    v_class text;
    c_definite_codes constant text[] := ARRAY['http_401', 'http_429', 'meta_190', 'meta_130429', 'meta_131056'];
BEGIN
    IF p_outbox_id IS NULL OR p_claim_token IS NULL
       OR p_failure_class IS NULL
       OR p_failure_class NOT IN ('retryable', 'permanent', 'unknown')
       OR p_error_code IS NULL
       OR p_error_code !~ '^[a-z0-9][a-z0-9_.:-]{0,79}$' THEN
        RAISE EXCEPTION 'a valid claim, failure class, and sanitized lowercase error code are required'
            USING ERRCODE = '22023';
    END IF;

    SELECT (o.send_authorized_at IS NOT NULL), o.clinic_id
    INTO v_authorized, v_clinic_id
    FROM public.outbox AS o
    WHERE o.id = p_outbox_id
      AND o.status = 'processing'
      AND o.claim_token = p_claim_token
    FOR UPDATE OF o;

    v_class := CASE
        WHEN p_failure_class = 'retryable'
             AND COALESCE(v_authorized, false)
             AND p_error_code <> ALL (c_definite_codes)
            THEN 'unknown'
        ELSE p_failure_class
    END;

    UPDATE public.outbox AS o
    SET status = CASE
            WHEN v_class IN ('permanent', 'unknown') THEN 'dead'
            WHEN o.attempts >= o.max_attempts THEN 'dead'
            ELSE 'failed'
        END,
        next_attempt_at = CASE
            WHEN v_class = 'retryable' AND o.attempts < o.max_attempts
                THEN now() + make_interval(
                    secs => LEAST(
                        900::numeric,
                        30::numeric * power(2::numeric, GREATEST(o.attempts - 1, 0))
                    )::double precision
                )
            ELSE o.next_attempt_at
        END,
        locked_at = NULL,
        last_error = CASE
            WHEN v_class = 'unknown' THEN 'delivery_outcome_unknown:' || p_error_code
            WHEN v_class = 'permanent' THEN 'permanent:' || p_error_code
            WHEN o.attempts >= o.max_attempts THEN 'max_attempts:' || p_error_code
            ELSE 'retryable:' || p_error_code
        END
    WHERE o.id = p_outbox_id
      AND o.status = 'processing'
      AND o.claim_token = p_claim_token
    RETURNING o.status, o.last_error, o.next_attempt_at, o.attempts
    INTO v_status, v_last_error, v_next_attempt_at, v_attempts;

    IF FOUND THEN
        IF p_error_code IN ('meta_190', 'http_401') THEN
            INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
            VALUES (
                v_clinic_id,
                'error',
                'outbox',
                'whatsapp_auth_failure',
                jsonb_build_object(
                    'outbox_id', p_outbox_id,
                    'error_code', p_error_code,
                    'attempts', v_attempts,
                    'status', v_status
                )
            );
        END IF;

        IF v_status = 'dead' THEN
            INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
            VALUES (
                v_clinic_id,
                'error',
                'outbox',
                'outbox_message_dead',
                jsonb_build_object(
                    'outbox_id', p_outbox_id,
                    'failure_class', p_failure_class,
                    'error_code', p_error_code,
                    'last_error', v_last_error,
                    'attempts', v_attempts
                )
            );
        END IF;

        RETURN QUERY SELECT p_outbox_id, v_status, 'recorded'::text,
                            v_next_attempt_at, v_attempts;
        RETURN;
    END IF;

    SELECT o.status, o.last_error, o.next_attempt_at, o.attempts,
           o.max_attempts, o.claim_token, o.clinic_id
    INTO v_status, v_last_error, v_next_attempt_at, v_attempts,
         v_max_attempts, v_claim_token, v_clinic_id
    FROM public.outbox AS o
    WHERE o.id = p_outbox_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT p_outbox_id, 'missing'::text, 'not_found'::text,
                            NULL::timestamptz, NULL::integer;
        RETURN;
    END IF;

    v_expected_error := CASE
        WHEN p_failure_class = 'unknown' THEN 'delivery_outcome_unknown:' || p_error_code
        WHEN p_failure_class = 'permanent' THEN 'permanent:' || p_error_code
        WHEN v_attempts >= v_max_attempts THEN 'max_attempts:' || p_error_code
        ELSE 'retryable:' || p_error_code
    END;

    IF v_claim_token = p_claim_token
       AND v_status IN ('failed', 'dead')
       AND (
            v_last_error = v_expected_error
            OR (p_failure_class = 'retryable'
                AND v_status = 'dead'
                AND v_last_error = 'delivery_outcome_unknown:' || p_error_code)
       ) THEN
        RETURN QUERY SELECT p_outbox_id, v_status, 'already_recorded'::text,
                            v_next_attempt_at, v_attempts;
    ELSE
        RETURN QUERY SELECT p_outbox_id, v_status, 'stale_claim'::text,
                            v_next_attempt_at, v_attempts;
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------
-- public.mark_outbox_sent(p_outbox_id uuid, p_claim_token uuid, p_provider_message_id text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_outbox_sent(p_outbox_id uuid, p_claim_token uuid, p_provider_message_id text)
 RETURNS TABLE(outbox_id uuid, status text, outcome text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_clinic_id uuid;
    v_contact_id uuid;
    v_current_status text;
    v_current_provider_message_id text;
    v_current_claim_token uuid;
BEGIN
    IF p_outbox_id IS NULL OR p_claim_token IS NULL
       OR p_provider_message_id IS NULL
       OR btrim(p_provider_message_id) = ''
       OR length(p_provider_message_id) > 512
       OR p_provider_message_id ~ '[[:cntrl:]]' THEN
        RAISE EXCEPTION 'outbox id, claim token, and a valid provider message id are required'
            USING ERRCODE = '22023';
    END IF;

    UPDATE public.outbox AS o
    SET status = 'sent',
        provider_message_id = p_provider_message_id,
        sent_at = COALESCE(o.sent_at, now()),
        delivery_status = COALESCE(o.delivery_status, 'sent'),
        delivery_status_at = COALESCE(o.delivery_status_at, o.sent_at, now()),
        delivery_error_code = NULL,
        locked_at = NULL,
        last_error = NULL
    WHERE o.id = p_outbox_id
      AND o.claim_token = p_claim_token
      AND (
          o.status = 'processing'
          OR (o.status = 'dead' AND o.last_error LIKE 'delivery_outcome_unknown%')
      )
    RETURNING o.clinic_id, o.contact_id
    INTO v_clinic_id, v_contact_id;

    IF FOUND THEN
        UPDATE public.conversations AS cv
        SET last_outbound_at = now()
        WHERE cv.clinic_id = v_clinic_id
          AND cv.contact_id = v_contact_id
          AND cv.status <> 'closed';

        RETURN QUERY SELECT p_outbox_id, 'sent'::text, 'sent'::text;
        RETURN;
    END IF;

    SELECT o.status, o.provider_message_id, o.claim_token
    INTO v_current_status, v_current_provider_message_id, v_current_claim_token
    FROM public.outbox AS o
    WHERE o.id = p_outbox_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT p_outbox_id, 'missing'::text, 'not_found'::text;
    ELSIF v_current_status = 'sent'
       AND v_current_provider_message_id = p_provider_message_id
       AND v_current_claim_token = p_claim_token THEN
        RETURN QUERY SELECT p_outbox_id, v_current_status, 'already_sent'::text;
    ELSE
        RETURN QUERY SELECT p_outbox_id, v_current_status, 'stale_claim'::text;
    END IF;
END;
$function$;

-- ---------------------------------------------------------------------
-- public.reschedule_appointment(p_clinic_id uuid, p_appointment_id uuid, p_contact_id uuid, p_new_starts_at timestamp with time zone)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reschedule_appointment(p_clinic_id uuid, p_appointment_id uuid, p_contact_id uuid, p_new_starts_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_old public.appointments%ROWTYPE;
    v_timezone text;
    v_settings jsonb;
    v_language text;
    v_provider_name text;
    v_service_name text;
    v_duration_minutes integer;
    v_slot_step_minutes integer;
    v_min_notice_minutes integer;
    v_max_days_ahead integer;
    v_start_local timestamp without time zone;
    v_end_at timestamptz;
    v_end_local timestamp without time zone;
    v_template text;
    v_message text;
    v_new_appointment_id uuid;
    v_fail_msg text;
BEGIN
    IF p_clinic_id IS NULL OR p_contact_id IS NULL OR p_new_starts_at IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    IF p_appointment_id IS NOT NULL THEN
        SELECT a.*
        INTO v_old
        FROM public.appointments AS a
        WHERE a.clinic_id = p_clinic_id
          AND a.id = p_appointment_id
        FOR UPDATE;

        IF FOUND AND v_old.contact_id <> p_contact_id THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'not_owner');
        END IF;
    ELSE
        SELECT a.*
        INTO v_old
        FROM public.appointments AS a
        WHERE a.clinic_id = p_clinic_id
          AND a.contact_id = p_contact_id
          AND a.status = 'confirmed'
          AND a.starts_at >= now()
        ORDER BY a.starts_at ASC
        LIMIT 1
        FOR UPDATE;
    END IF;

    IF v_old.id IS NULL OR v_old.status <> 'confirmed' THEN
        SELECT COALESCE(ct.language, 'ar') INTO v_language
        FROM public.contacts ct
        WHERE ct.id = p_contact_id AND ct.clinic_id = p_clinic_id;

        v_fail_msg := CASE WHEN v_language = 'en'
            THEN 'We could not find an active upcoming appointment to reschedule. Would you like to book a new appointment?'
            ELSE 'ملقيناش موعد قادم مؤكد عشان نعدله، تحب نحجزلك موعد جديد؟'
        END;

        PERFORM public.enqueue_message(
            p_clinic_id, p_contact_id, 'text',
            jsonb_build_object('text', v_fail_msg),
            'appt-resched-notfound-' || p_contact_id::text || '-' || extract(epoch from p_new_starts_at)::bigint::text,
            false
        );

        RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
    END IF;

    IF v_old.starts_at = p_new_starts_at THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = v_old.contact_id
          AND status <> 'closed';

        RETURN jsonb_build_object(
            'ok', true,
            'appointment_id', v_old.id,
            'previous_appointment_id', v_old.id,
            'starts_at', v_old.starts_at,
            'idempotent', true
        );
    END IF;

    SELECT c.timezone,
           c.settings,
           ct.language,
           p.name,
           CASE WHEN ct.language = 'en' THEN s.name_en ELSE s.name_ar END,
           s.duration_minutes
    INTO v_timezone, v_settings, v_language, v_provider_name,
         v_service_name, v_duration_minutes
    FROM public.clinics AS c
    JOIN public.contacts AS ct
      ON ct.id = v_old.contact_id
     AND ct.clinic_id = v_old.clinic_id
    JOIN public.services AS s
      ON s.id = v_old.service_id
     AND s.clinic_id = v_old.clinic_id
     AND s.active
    JOIN public.provider_services AS ps
      ON ps.clinic_id = v_old.clinic_id
     AND ps.service_id = s.id
     AND ps.provider_id = v_old.provider_id
    JOIN public.providers AS p
      ON p.id = ps.provider_id
     AND p.clinic_id = ps.clinic_id
     AND p.active
    WHERE c.id = v_old.clinic_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'service_not_offered');
    END IF;

    BEGIN
        v_slot_step_minutes := COALESCE((v_settings ->> 'slot_step_minutes')::integer, 30);
        v_min_notice_minutes := COALESCE((v_settings ->> 'min_notice_minutes')::integer, 60);
        v_max_days_ahead := COALESCE((v_settings ->> 'max_days_ahead')::integer, 30);
    EXCEPTION
        WHEN invalid_text_representation OR numeric_value_out_of_range THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END;

    IF v_slot_step_minutes <= 0 OR v_min_notice_minutes < 0 OR v_max_days_ahead < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    v_start_local := p_new_starts_at AT TIME ZONE v_timezone;
    v_end_at := p_new_starts_at + make_interval(mins => v_duration_minutes);
    v_end_local := v_end_at AT TIME ZONE v_timezone;

    IF p_new_starts_at < now() + make_interval(mins => v_min_notice_minutes) THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = v_old.contact_id
          AND status <> 'closed';

        v_fail_msg := CASE WHEN v_language = 'en'
            THEN 'Sorry, the new time is too soon. Your original appointment is still confirmed as is.'
            ELSE 'معلش الوقت الجديد اقترب جداً، بس اطمن موعدك الحالي لسه زي ما هو ماتلغاش. تحب نختار وقت تاني؟'
        END;
        PERFORM public.enqueue_message(
            p_clinic_id, v_old.contact_id, 'text',
            jsonb_build_object('text', v_fail_msg),
            'appt-resched-soon-' || v_old.id::text || '-' || extract(epoch from p_new_starts_at)::bigint::text,
            false
        );
        RETURN jsonb_build_object('ok', false, 'reason', 'too_soon');
    END IF;

    IF p_new_starts_at > now() + make_interval(days => v_max_days_ahead) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'too_far');
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.working_hours AS wh
        WHERE wh.clinic_id = v_old.clinic_id
          AND wh.provider_id = v_old.provider_id
          AND wh.weekday = extract(dow FROM v_start_local)::smallint
          AND v_start_local::time >= wh.start_time
          AND v_end_local <= date_trunc('day', v_start_local) + wh.end_time
    ) THEN
        UPDATE public.conversations
        SET state = state - 'pending_booking'
        WHERE clinic_id = p_clinic_id
          AND contact_id = v_old.contact_id
          AND status <> 'closed';

        v_fail_msg := CASE WHEN v_language = 'en'
            THEN 'Sorry, the new time is outside working hours. Your current appointment is still kept as is.'
            ELSE 'معلش الوقت الجديد خارج مواعيد العمل، موعدك الحالي لسه زي ما هو ماتلغاش. تحب نختار وقت تاني؟'
        END;
        PERFORM public.enqueue_message(
            p_clinic_id, v_old.contact_id, 'text',
            jsonb_build_object('text', v_fail_msg),
            'appt-resched-hours-' || v_old.id::text || '-' || extract(epoch from p_new_starts_at)::bigint::text,
            false
        );
        RETURN jsonb_build_object('ok', false, 'reason', 'outside_hours');
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.working_hours AS wh
        WHERE wh.clinic_id = v_old.clinic_id
          AND wh.provider_id = v_old.provider_id
          AND wh.weekday = extract(dow FROM v_start_local)::smallint
          AND v_start_local::time >= wh.start_time
          AND v_end_local <= date_trunc('day', v_start_local) + wh.end_time
          AND mod(
              extract(epoch FROM (
                  v_start_local - (date_trunc('day', v_start_local) + wh.start_time)
              )),
              v_slot_step_minutes::numeric * 60
          ) = 0
    ) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    v_template := COALESCE(
        v_settings #>> ARRAY['messages', 'booking_rescheduled', v_language],
        v_settings #>> ARRAY['messages', 'booking_confirmed', v_language]
    );
    IF v_template IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    -- Subtransaction block guarantees atomic rollback of v_old cancellation if INSERT fails
    BEGIN
        UPDATE public.appointments AS a
        SET status = 'cancelled',
            cancelled_at = now(),
            cancel_reason = 'rescheduled'
        WHERE a.id = v_old.id
          AND a.clinic_id = p_clinic_id;

        INSERT INTO public.appointments (
            clinic_id, contact_id, provider_id, service_id,
            starts_at, ends_at, source
        )
        VALUES (
            v_old.clinic_id,
            v_old.contact_id,
            v_old.provider_id,
            v_old.service_id,
            p_new_starts_at,
            v_end_at,
            COALESCE(v_old.source, 'whatsapp')
        )
        RETURNING id INTO v_new_appointment_id;
    EXCEPTION
        WHEN exclusion_violation THEN
            -- Subtransaction automatically rolled back the UPDATE on v_old!
            UPDATE public.conversations
            SET state = state - 'pending_booking'
            WHERE clinic_id = p_clinic_id
              AND contact_id = v_old.contact_id
              AND status <> 'closed';

            v_fail_msg := CASE WHEN v_language = 'en'
                THEN 'Sorry, that slot was just taken. Your original appointment is still confirmed.'
                ELSE 'معلش الموعد الجديد ده اتحجز دلوقتي، بس اطمن موعدك القديم لسه زي ما هو ماتلغاش. تحب نختار وقت تاني؟'
            END;
            PERFORM public.enqueue_message(
                p_clinic_id, v_old.contact_id, 'text',
                jsonb_build_object('text', v_fail_msg),
                'appt-resched-taken-' || v_old.id::text || '-' || extract(epoch from p_new_starts_at)::bigint::text,
                false
            );
            RETURN jsonb_build_object('ok', false, 'reason', 'slot_taken');
    END;

    UPDATE public.conversations
    SET state = state - 'pending_booking'
    WHERE clinic_id = p_clinic_id
      AND contact_id = v_old.contact_id
      AND status <> 'closed';

    v_message := replace(
        replace(
            replace(
                replace(v_template, '{{service}}', v_service_name),
                '{{doctor}}', v_provider_name
            ),
            '{{date}}', to_char(v_start_local, 'YYYY-MM-DD')
        ),
        '{{time}}', to_char(v_start_local, 'HH24:MI')
    );

    PERFORM public.enqueue_message(
        p_clinic_id,
        v_old.contact_id,
        'text',
        jsonb_build_object('text', v_message),
        'appt-reschedule-' || v_old.id::text || '-' || v_new_appointment_id::text,
        false
    );

    RETURN jsonb_build_object(
        'ok', true,
        'appointment_id', v_new_appointment_id,
        'previous_appointment_id', v_old.id,
        'starts_at', p_new_starts_at,
        'message_text', v_message
    );
END;
$function$;

-- ---------------------------------------------------------------------
-- public.resolve_whatsapp_clinic(p_phone_number_id text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_whatsapp_clinic(p_phone_number_id text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_clinic_id uuid;
  v_match_count integer;
BEGIN
  IF p_phone_number_id IS NULL
     OR p_phone_number_id !~ '^[0-9]{5,32}$' THEN
    RETURN NULL;
  END IF;

  SELECT count(*), (array_agg(c.id ORDER BY c.id))[1]
    INTO v_match_count, v_clinic_id
  FROM public.clinics AS c
  WHERE c.settings->>'whatsapp_phone_number_id' = p_phone_number_id;

  IF v_match_count <> 1 THEN
    RETURN NULL;
  END IF;

  RETURN v_clinic_id;
END
$function$;

-- ---------------------------------------------------------------------
-- public.set_communications_opt_out(p_clinic_id uuid, p_contact_id uuid, p_opted_out boolean)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_communications_opt_out(p_clinic_id uuid, p_contact_id uuid, p_opted_out boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_is_opted_out boolean;
BEGIN
    IF p_clinic_id IS NULL OR p_contact_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    -- Same contact-first, outbox-second lock order as authorization and enqueue.
    UPDATE public.contacts AS ct
    SET communications_opted_out_at = CASE
        WHEN COALESCE(p_opted_out, true) THEN COALESCE(ct.communications_opted_out_at, now())
        ELSE NULL
    END
    WHERE ct.id = p_contact_id
      AND ct.clinic_id = p_clinic_id
    RETURNING (ct.communications_opted_out_at IS NOT NULL) INTO v_is_opted_out;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
    END IF;

    IF v_is_opted_out THEN
        UPDATE public.outbox AS o
        SET status = 'dead',
            locked_at = NULL,
            last_error = CASE
                WHEN o.status = 'processing' AND o.send_authorized_at IS NOT NULL
                    THEN 'delivery_outcome_unknown:communications_opt_out_race'
                ELSE 'communications_opted_out'
            END,
            claim_token = CASE
                WHEN o.status = 'processing' AND o.send_authorized_at IS NOT NULL
                    THEN o.claim_token
                ELSE gen_random_uuid()
            END
        WHERE o.clinic_id = p_clinic_id
          AND o.contact_id = p_contact_id
          AND o.status IN ('pending', 'failed', 'processing');
    END IF;

    INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
    VALUES (
        p_clinic_id, 'info', 'set_communications_opt_out',
        CASE WHEN v_is_opted_out THEN 'contact_all_messages_opted_out' ELSE 'contact_all_messages_opted_in' END,
        jsonb_build_object('contact_id', p_contact_id)
    );

    RETURN jsonb_build_object('ok', true, 'opted_out', v_is_opted_out, 'scope', 'all_communications');
END;
$function$;

-- ---------------------------------------------------------------------
-- public.set_contact_language(p_clinic_id uuid, p_contact_id uuid, p_language text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_contact_language(p_clinic_id uuid, p_contact_id uuid, p_language text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
begin
  if p_clinic_id is null or p_contact_id is null or p_language is null or p_language not in ('ar', 'en') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_request');
  end if;

  update public.contacts ct
  set language = p_language
  where ct.id = p_contact_id
    and ct.clinic_id = p_clinic_id;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'language', p_language);
end;
$function$;

-- ---------------------------------------------------------------------
-- public.set_opt_out(p_clinic_id uuid, p_contact_id uuid, p_opted_out boolean)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_opt_out(p_clinic_id uuid, p_contact_id uuid, p_opted_out boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_is_opted_out boolean;
BEGIN
    IF p_clinic_id IS NULL OR p_contact_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    -- Lock order everywhere: contact first, outbox second.
    UPDATE public.contacts AS ct
    SET opted_out_at = CASE
        WHEN COALESCE(p_opted_out, true) THEN COALESCE(ct.opted_out_at, now())
        ELSE NULL
    END
    WHERE ct.id = p_contact_id
      AND ct.clinic_id = p_clinic_id
    RETURNING (ct.opted_out_at IS NOT NULL) INTO v_is_opted_out;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
    END IF;

    IF v_is_opted_out THEN
        UPDATE public.outbox AS o
        SET status = 'dead',
            locked_at = NULL,
            last_error = CASE
                WHEN o.status = 'processing' AND o.send_authorized_at IS NOT NULL
                    THEN 'delivery_outcome_unknown:opt_out_race'
                ELSE 'contact_opted_out'
            END,
            claim_token = CASE
                WHEN o.status = 'processing' AND o.send_authorized_at IS NOT NULL
                    THEN o.claim_token
                ELSE gen_random_uuid()
            END
        WHERE o.clinic_id = p_clinic_id
          AND o.contact_id = p_contact_id
          AND o.status IN ('pending', 'failed', 'processing')
          AND o.is_marketing;
    END IF;

    INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
    VALUES (
        p_clinic_id, 'info', 'set_opt_out',
        CASE WHEN v_is_opted_out THEN 'contact_marketing_opted_out' ELSE 'contact_marketing_opted_in' END,
        jsonb_build_object('contact_id', p_contact_id)
    );

    RETURN jsonb_build_object('ok', true, 'opted_out', v_is_opted_out);
END;
$function$;

-- ---------------------------------------------------------------------
-- public.update_conversation(p_clinic_id uuid, p_conversation_id uuid, p_status text, p_state_patch jsonb, p_replace_state boolean)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_conversation(p_clinic_id uuid, p_conversation_id uuid, p_status text DEFAULT NULL::text, p_state_patch jsonb DEFAULT NULL::jsonb, p_replace_state boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_status text;
    v_state jsonb;
    v_contact_id uuid;
    v_patient_phone text;
    v_patient_name text;
    v_last_msg_id uuid;
    v_last_msg_body text;
    v_settings jsonb;
    v_staff_phone text;
    v_staff_contact_id uuid;
    v_staff_lang text;
    v_staff_in_window boolean;
    v_alert_template text;
    v_alert_text text;
    v_msg jsonb;
BEGIN
    IF p_clinic_id IS NULL OR p_conversation_id IS NULL
       OR (p_status IS NOT NULL AND p_status NOT IN ('bot', 'human', 'closed'))
       OR (p_state_patch IS NOT NULL AND jsonb_typeof(p_state_patch) <> 'object')
       OR pg_column_size(coalesce(p_state_patch, '{}'::jsonb)) > 16384 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_request');
    END IF;

    BEGIN
        UPDATE public.conversations cv
        SET status = coalesce(p_status, cv.status),
            state = CASE
                WHEN coalesce(p_replace_state, false) THEN coalesce(p_state_patch, '{}'::jsonb)
                WHEN p_state_patch IS NULL THEN cv.state
                ELSE (cv.state || p_state_patch) - ARRAY(
                    SELECT k FROM jsonb_each(p_state_patch) AS e(k, v) WHERE jsonb_typeof(v) = 'null'
                )
            END
        WHERE cv.id = p_conversation_id
          AND cv.clinic_id = p_clinic_id
        RETURNING cv.status, cv.state, cv.contact_id INTO v_status, v_state, v_contact_id;
    EXCEPTION WHEN unique_violation THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'conflict');
    END;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
    END IF;

    IF p_status = 'human' THEN
        SELECT ct.phone_e164, coalesce(ct.name, 'مريض')
        INTO v_patient_phone, v_patient_name
        FROM public.contacts ct
        WHERE ct.id = v_contact_id AND ct.clinic_id = p_clinic_id;

        SELECT m.id, coalesce(m.body, '[' || m.message_type || ']')
        INTO v_last_msg_id, v_last_msg_body
        FROM public.messages m
        WHERE m.clinic_id = p_clinic_id
          AND m.conversation_id = p_conversation_id
          AND m.direction = 'in'
        ORDER BY m.created_at DESC
        LIMIT 1;

        INSERT INTO public.system_events (clinic_id, level, source, event_type, details)
        VALUES (
            p_clinic_id, 'info', 'update_conversation', 'human_handoff_requested',
            jsonb_build_object(
                'conversation_id', p_conversation_id,
                'contact_id', v_contact_id,
                'patient_phone', v_patient_phone
            )
        );

        SELECT c.settings,
               btrim(c.settings ->> 'staff_whatsapp_phone'),
               COALESCE(
                   c.settings #>> '{messages,human_handoff_staff_alert,ar}',
                   '🔔 تنبيه استقبال العيادة: المريض {{patient_name}} ({{patient_phone}}) يحتاج لتدخل بشري.' || E'\n' || 'آخر رسالة: {{message}}'
               )
        INTO v_settings, v_staff_phone, v_alert_template
        FROM public.clinics c
        WHERE c.id = p_clinic_id;

        IF v_staff_phone IS NOT NULL AND v_staff_phone <> '' THEN
            v_staff_phone := '+' || regexp_replace(v_staff_phone, '^\+', '');
            IF v_staff_phone ~ '^\+[1-9][0-9]{7,14}$' AND v_staff_phone IS DISTINCT FROM v_patient_phone THEN
                INSERT INTO public.contacts (clinic_id, phone_e164, name)
                VALUES (p_clinic_id, v_staff_phone, 'Clinic Reception Staff')
                ON CONFLICT (clinic_id, phone_e164)
                DO UPDATE SET name = COALESCE(public.contacts.name, EXCLUDED.name)
                RETURNING id, coalesce(language, 'ar') INTO v_staff_contact_id, v_staff_lang;

                SELECT EXISTS (
                    SELECT 1 FROM public.conversations cv
                    WHERE cv.clinic_id = p_clinic_id
                      AND cv.contact_id = v_staff_contact_id
                      AND cv.status <> 'closed'
                      AND cv.last_inbound_at >= now() - interval '23 hours'
                      AND cv.last_inbound_at <= now()
                ) INTO v_staff_in_window;

                v_alert_text := replace(replace(replace(v_alert_template,
                    '{{patient_name}}', coalesce(v_patient_name, 'مريض')),
                    '{{patient_phone}}', coalesce(v_patient_phone, '')),
                    '{{message}}', left(coalesce(v_last_msg_body, ''), 500));

                v_msg := private.build_whatsapp_message(
                    v_settings, 'human_handoff_staff_alert', v_staff_lang, v_alert_text,
                    ARRAY[coalesce(v_patient_name, 'مريض'), coalesce(v_patient_phone, ''), left(coalesce(v_last_msg_body, ''), 300)],
                    v_staff_in_window
                );

                PERFORM public.enqueue_message(
                    p_clinic_id,
                    v_staff_contact_id,
                    v_msg ->> 'kind',
                    v_msg -> 'payload',
                    'handoff-staff:' || p_conversation_id::text || ':' || coalesce(v_last_msg_id::text, '0'),
                    false
                );
            END IF;
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'status', v_status, 'state', v_state);
END;
$function$;

-- ---------------------------------------------------------------------
-- public.update_message_transcription(p_clinic_id uuid, p_message_id uuid, p_transcription text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_message_transcription(p_clinic_id uuid, p_message_id uuid, p_transcription text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
    v_updated boolean := false;
BEGIN
    UPDATE public.messages
    SET body = p_transcription,
        payload = jsonb_set(
            coalesce(payload, '{}'::jsonb),
            '{transcription}',
            to_jsonb(p_transcription)
        )
    WHERE clinic_id = p_clinic_id AND id = p_message_id;

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    RETURN jsonb_build_object(
        'ok', true,
        'updated', v_updated,
        'message_id', p_message_id
    );
END;
$function$;

-- ---------------------------------------------------------------------
-- public.verify_meta_webhook_challenge(p_mode text, p_verify_token text, p_challenge text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verify_meta_webhook_challenge(p_mode text, p_verify_token text, p_challenge text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_expected_token text;
BEGIN
  IF p_mode IS DISTINCT FROM 'subscribe'
     OR p_verify_token IS NULL
     OR btrim(p_verify_token) = ''
     OR p_challenge IS NULL
     OR length(p_challenge) > 512 THEN
    RETURN NULL;
  END IF;

  v_expected_token := private.get_clinicos_meta_secret('clinicos_meta_verify_token');
  IF v_expected_token IS NOT NULL
     AND v_expected_token <> ''
     AND p_verify_token = v_expected_token THEN
    RETURN p_challenge;
  END IF;

  RETURN NULL;
END
$function$;

-- ---------------------------------------------------------------------
-- public.verify_meta_webhook_signature(p_raw_body_base64 text, p_signature_header text)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verify_meta_webhook_signature(p_raw_body_base64 text, p_signature_header text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_app_secret text;
  v_expected bytea;
  v_supplied bytea;
  v_diff integer := 0;
  v_i integer;
  v_raw_body bytea;
BEGIN
  IF p_raw_body_base64 IS NULL OR p_signature_header IS NULL
     OR length(p_raw_body_base64) > 22000000
     OR length(p_signature_header) <> 71
     OR lower(left(p_signature_header,7)) <> 'sha256='
     OR substring(p_signature_header from 8) !~ '^[0-9a-fA-F]{64}$' THEN
    RETURN false;
  END IF;

  v_app_secret := private.get_clinicos_meta_secret('clinicos_meta_app_secret');
  IF v_app_secret IS NULL OR v_app_secret = '' THEN
    RETURN false;
  END IF;

  BEGIN
    v_raw_body := decode(p_raw_body_base64,'base64');
    v_supplied := decode(substring(p_signature_header from 8),'hex');
  EXCEPTION WHEN OTHERS THEN
    RETURN false;
  END;

  v_expected := extensions.hmac(v_raw_body,convert_to(v_app_secret,'UTF8'),'sha256');
  IF octet_length(v_expected) <> 32 OR octet_length(v_supplied) <> 32 THEN
    RETURN false;
  END IF;

  FOR v_i IN 0..31 LOOP
    v_diff := v_diff | (get_byte(v_expected,v_i) # get_byte(v_supplied,v_i));
  END LOOP;

  RETURN v_diff = 0;
END
$function$;

