-- =====================================================================
-- ClinicOS Production Database Schema (PostgreSQL 17 / Supabase)
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "btree_gist";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1. Clinics Table
CREATE TABLE IF NOT EXISTS public.clinics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    timezone TEXT NOT NULL DEFAULT 'Asia/Riyadh',
    settings JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Providers (Doctors & Specialists)
CREATE TABLE IF NOT EXISTS public.providers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    specialty TEXT,
    active BOOLEAN NOT NULL DEFAULT true
);
CREATE INDEX IF NOT EXISTS idx_providers_clinic ON public.providers(clinic_id) WHERE active;

-- 3. Services Offered
CREATE TABLE IF NOT EXISTS public.services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    name_ar TEXT NOT NULL,
    name_en TEXT NOT NULL,
    duration_minutes INTEGER NOT NULL DEFAULT 30,
    price NUMERIC,
    active BOOLEAN NOT NULL DEFAULT true,
    CONSTRAINT uq_clinic_service_code UNIQUE (clinic_id, code)
);

-- 4. Provider Services Mapping
CREATE TABLE IF NOT EXISTS public.provider_services (
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    provider_id UUID NOT NULL REFERENCES public.providers(id) ON DELETE CASCADE,
    service_id UUID NOT NULL REFERENCES public.services(id) ON DELETE CASCADE,
    PRIMARY KEY (clinic_id, provider_id, service_id)
);

-- 5. Working Hours
CREATE TABLE IF NOT EXISTS public.working_hours (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    provider_id UUID NOT NULL REFERENCES public.providers(id) ON DELETE CASCADE,
    weekday SMALLINT NOT NULL CHECK (weekday BETWEEN 0 AND 6), -- 0=Sunday, 6=Saturday
    start_time TIME NOT NULL,
    end_time TIME NOT NULL,
    CONSTRAINT chk_working_hours_order CHECK (end_time > start_time)
);
CREATE INDEX IF NOT EXISTS idx_working_hours_lookup ON public.working_hours(clinic_id, provider_id, weekday);

-- 6. Contacts (Patients)
CREATE TABLE IF NOT EXISTS public.contacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    phone_e164 TEXT NOT NULL,
    name TEXT,
    language TEXT NOT NULL DEFAULT 'ar',
    opted_out_at TIMESTAMPTZ,
    communications_opted_out_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_clinic_contact_phone UNIQUE (clinic_id, phone_e164)
);
CREATE INDEX IF NOT EXISTS idx_contacts_lookup ON public.contacts(clinic_id, phone_e164);

-- 7. Conversations
CREATE TABLE IF NOT EXISTS public.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    contact_id UUID NOT NULL REFERENCES public.contacts(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'bot' CHECK (status IN ('bot', 'human', 'closed')),
    state JSONB NOT NULL DEFAULT '{}'::jsonb,
    last_inbound_at TIMESTAMPTZ,
    last_outbound_at TIMESTAMPTZ,
    followup_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_conversations_contact ON public.conversations(clinic_id, contact_id, status);

-- 8. Messages
CREATE TABLE IF NOT EXISTS public.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
    direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
    provider_message_id TEXT,
    message_type TEXT NOT NULL DEFAULT 'text',
    body TEXT,
    payload JSONB,
    delivery_status TEXT NOT NULL DEFAULT 'received',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_messages_provider_id ON public.messages(clinic_id, provider_message_id) WHERE provider_message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_messages_conversation ON public.messages(clinic_id, conversation_id, created_at DESC);

-- 9. Appointments (with Exclusion Constraint to prevent double-booking)
CREATE TABLE IF NOT EXISTS public.appointments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    contact_id UUID NOT NULL REFERENCES public.contacts(id) ON DELETE CASCADE,
    provider_id UUID NOT NULL REFERENCES public.providers(id) ON DELETE CASCADE,
    service_id UUID NOT NULL REFERENCES public.services(id) ON DELETE CASCADE,
    starts_at TIMESTAMPTZ NOT NULL,
    ends_at TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'cancelled', 'completed', 'no_show')),
    source TEXT NOT NULL DEFAULT 'whatsapp',
    cancel_reason TEXT,
    cancelled_at TIMESTAMPTZ,
    reminder_sent_at TIMESTAMPTZ,
    followup_sent_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT appointments_no_overlap EXCLUDE USING gist (
        provider_id WITH =,
        tstzrange(starts_at, ends_at, '[)') WITH &&
    ) WHERE (status = 'confirmed')
);
CREATE INDEX IF NOT EXISTS idx_appointments_patient ON public.appointments(clinic_id, contact_id, status, starts_at);
CREATE INDEX IF NOT EXISTS idx_appointments_provider_schedule ON public.appointments(provider_id, starts_at) WHERE (status = 'confirmed');

-- 10. Outbox (Asynchronous message queue for WhatsApp Cloud API)
CREATE TABLE IF NOT EXISTS public.outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id UUID NOT NULL REFERENCES public.clinics(id) ON DELETE CASCADE,
    contact_id UUID NOT NULL REFERENCES public.contacts(id) ON DELETE CASCADE,
    kind TEXT NOT NULL DEFAULT 'text' CHECK (kind IN ('text', 'template', 'interactive_list', 'interactive_buttons')),
    payload JSONB NOT NULL,
    is_marketing BOOLEAN NOT NULL DEFAULT false,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'sent', 'failed', 'dead')),
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 5,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_at TIMESTAMPTZ,
    claim_token UUID,
    provider_message_id TEXT,
    last_error TEXT,
    idempotency_key TEXT,
    sent_at TIMESTAMPTZ,
    delivery_status TEXT,
    delivery_status_at TIMESTAMPTZ,
    delivery_error_code TEXT,
    send_authorized_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_outbox_idempotency UNIQUE (clinic_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_outbox_due ON public.outbox(status, next_attempt_at) WHERE status IN ('pending', 'failed');

-- 11. System Events (Audit trail & error logging)
CREATE TABLE IF NOT EXISTS public.system_events (
    id BIGSERIAL PRIMARY KEY,
    clinic_id UUID REFERENCES public.clinics(id) ON DELETE CASCADE,
    level TEXT NOT NULL DEFAULT 'info' CHECK (level IN ('info', 'warn', 'error')),
    source TEXT NOT NULL,
    event_type TEXT NOT NULL,
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_system_events_created ON public.system_events(clinic_id, level, created_at DESC);
