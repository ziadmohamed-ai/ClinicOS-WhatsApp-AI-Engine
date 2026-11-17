-- =====================================================================
-- ClinicOS add-on 05: Lead-to-Visit Engine (schema "l2v")
--
-- Runs AFTER database/01..04 of ClinicOS. It does NOT duplicate anything
-- ClinicOS already has: contacts, conversations, messages, appointments,
-- the outbox, reminders and opt-out handling are all reused.
-- It adds only: lead capture, qualification score, round-robin handoff to
-- reception reps, SLA escalation, and a KPI function.
--
-- Every WhatsApp message goes through public.enqueue_message() (idempotency,
-- opt-out checks, payload validation) and is sent by the existing outbox
-- workflow. Template names come from clinics.settings.whatsapp_templates.<key>
-- exactly like the rest of ClinicOS.
--
-- Reps and the manager are stored as rows in public.contacts so the existing
-- outbox can message them. Use l2v.is_staff() in "Parse Turn & State" so a rep
-- tapping a button is NOT routed to the AI receptionist (see README section
-- "Workflow changes").
-- =====================================================================

create schema if not exists l2v;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

create table l2v.settings (
  clinic_id          uuid primary key references public.clinics (id) on delete cascade,
  sla_minutes        integer not null default 15 check (sla_minutes between 1 and 240),
  manager_contact_id uuid references public.contacts (id) on delete set null,
  open_time          time,
  close_time         time,
  open_days          smallint[] check (open_days is null or open_days <@ array[0,1,2,3,4,5,6]::smallint[]),
  created_at         timestamptz not null default now(),
  constraint settings_hours_not_equal check (open_time is null or close_time is null or open_time <> close_time)
);
alter table l2v.settings add column if not exists open_time time;
alter table l2v.settings add column if not exists close_time time;
alter table l2v.settings add column if not exists open_days smallint[];
create index settings_manager_idx on l2v.settings (manager_contact_id);

create table l2v.reps (
  id               uuid primary key default gen_random_uuid(),
  clinic_id        uuid not null references public.clinics (id) on delete cascade,
  contact_id       uuid not null unique references public.contacts (id) on delete cascade,
  name             text not null,
  is_active        boolean not null default true,
  last_assigned_at timestamptz,
  created_at       timestamptz not null default now()
);
create index reps_rotation_idx
  on l2v.reps (clinic_id, last_assigned_at nulls first)
  where is_active;

create table l2v.leads (
  id                 uuid primary key default gen_random_uuid(),
  clinic_id          uuid not null references public.clinics (id) on delete cascade,
  contact_id         uuid not null references public.contacts (id) on delete cascade,
  source             text not null
                     check (source in ('click_to_whatsapp', 'lead_form', 'website', 'manual', 'organic')),
  campaign           text,
  referral           jsonb,
  treatment_interest text,
  status             text not null default 'new'
                     check (status in ('new', 'hot', 'warm', 'cold', 'closed')),
  score              smallint check (score between 0 and 100),
  budget_band        text check (budget_band in ('low', 'mid', 'high', 'unknown')),
  timing             text check (timing in ('now', 'this_month', 'later', 'unknown')),
  first_inbound_at   timestamptz not null default now(),
  created_at         timestamptz not null default now()
);
-- one open lead per patient; a closed lead frees the contact for a new one
create unique index leads_one_open_per_contact
  on l2v.leads (contact_id)
  where status <> 'closed';
create index leads_clinic_created_idx on l2v.leads (clinic_id, created_at desc);

create table l2v.assignments (
  id           uuid primary key default gen_random_uuid(),
  lead_id      uuid not null references l2v.leads (id) on delete cascade,
  rep_id       uuid not null references l2v.reps (id),
  attempt      smallint not null default 1,
  status       text not null default 'pending'
               check (status in ('pending', 'acked', 'escalated', 'closed_booked')),
  assigned_at  timestamptz not null default now(),
  sla_due_at   timestamptz not null,
  acked_at     timestamptz,
  escalated_at timestamptz
);
create index assignments_lead_idx on l2v.assignments (lead_id);
create index assignments_rep_idx  on l2v.assignments (rep_id, assigned_at);
create index assignments_pending_due_idx on l2v.assignments (sla_due_at) where status = 'pending';
create unique index assignments_one_live_per_lead
  on l2v.assignments (lead_id)
  where status in ('pending', 'acked');

-- ---------------------------------------------------------------------
-- Internal helper: queue one WhatsApp message through ClinicOS' outbox.
-- Uses the clinic's template config; falls back to plain text when no
-- template is configured (works only inside the 24h window).
-- ---------------------------------------------------------------------
create function l2v._notify(
  p_clinic_id      uuid,
  p_contact_id     uuid,
  p_template_key   text,
  p_fallback_text  text,
  p_params         text[],
  p_button_payload text,
  p_idempotency    text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_settings jsonb;
  v_msg      jsonb;
begin
  select c.settings into v_settings from public.clinics c where c.id = p_clinic_id;

  v_msg := private.build_whatsapp_message(
    coalesce(v_settings, '{}'::jsonb), p_template_key, 'ar', p_fallback_text, p_params, false
  );

  if p_button_payload is not null and v_msg ->> 'kind' = 'template' then
    v_msg := jsonb_set(
      v_msg,
      '{payload,template,components}',
      coalesce(v_msg #> '{payload,template,components}', '[]'::jsonb)
        || jsonb_build_array(jsonb_build_object(
             'type', 'button', 'sub_type', 'quick_reply', 'index', '0',
             'parameters', jsonb_build_array(
               jsonb_build_object('type', 'payload', 'payload', p_button_payload))))
    );
  end if;

  perform public.enqueue_message(
    p_clinic_id, p_contact_id, v_msg ->> 'kind', v_msg -> 'payload', p_idempotency, false
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Public API (called by n8n through the ClinicOS runtime role)
-- ---------------------------------------------------------------------

-- Is this phone an active rep or the manager? Use it to bypass the AI receptionist.
create function l2v.is_staff(p_clinic_id uuid, p_phone_e164 text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.contacts c
     where c.clinic_id = p_clinic_id
       and c.phone_e164 = p_phone_e164
       and (
         exists (
           select 1 from l2v.reps r
            where r.clinic_id = p_clinic_id
              and r.contact_id = c.id
              and r.is_active
         )
         or exists (
           select 1 from l2v.settings s
            where s.clinic_id = p_clinic_id
              and s.manager_contact_id = c.id
         )
       )
  );
$$;

-- Call right after ClinicOS ingests the first message of a new patient.
-- Creates the lead, or returns the open one for this contact.
create function l2v.capture_lead(
  p_clinic_id   uuid,
  p_contact_id  uuid,
  p_source      text default 'click_to_whatsapp',
  p_campaign    text default null,
  p_treatment   text default null,
  p_referral    jsonb default null,
  p_received_at timestamptz default now()
)
returns table (lead_id uuid, is_new boolean)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.contacts c where c.id = p_contact_id and c.clinic_id = p_clinic_id) then
    raise exception 'contact % does not belong to clinic %', p_contact_id, p_clinic_id;
  end if;
  if exists (select 1 from l2v.reps r where r.clinic_id = p_clinic_id and r.contact_id = p_contact_id and r.is_active)
     or exists (select 1 from l2v.settings s where s.clinic_id = p_clinic_id and s.manager_contact_id = p_contact_id) then
    raise exception 'contact % is staff, not a lead', p_contact_id;
  end if;

  return query
  insert into l2v.leads as l
         (clinic_id, contact_id, source, campaign, treatment_interest, referral, first_inbound_at)
  values (p_clinic_id, p_contact_id, p_source, p_campaign, p_treatment, p_referral, coalesce(p_received_at, now()))
  on conflict (contact_id) where status <> 'closed'
  do update set
    source             = case
                           when l.source = 'organic' and excluded.source <> 'organic' then excluded.source
                           else l.source
                         end,
    campaign           = coalesce(l.campaign, excluded.campaign),
    treatment_interest = coalesce(l.treatment_interest, excluded.treatment_interest),
    referral           = coalesce(l.referral, excluded.referral)
  returning l.id, (xmax = 0);
end;
$$;

-- Guarded capture for the inbound webhook gate:
--   * returns no row (does not raise) if the contact is active staff (rep or manager)
--   * if a patient with a previously converted lead returns from a NEW ad click (distinct source/referral),
--     closes the converted lead so a fresh funnel lead is opened
--   * creates/returns the open lead ONLY if the message has a referral
--     OR the contact has no confirmed/completed appointment in this clinic
create function l2v.capture_lead_guarded(
  p_clinic_id   uuid,
  p_contact_id  uuid,
  p_source      text default 'click_to_whatsapp',
  p_campaign    text default null,
  p_referral    jsonb default null,
  p_received_at timestamptz default now()
)
returns table (lead_id uuid, is_new boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_referral boolean;
  v_open_lead    l2v.leads%rowtype;
begin
  if not exists (select 1 from public.contacts c where c.id = p_contact_id and c.clinic_id = p_clinic_id) then
    raise exception 'contact % does not belong to clinic %', p_contact_id, p_clinic_id;
  end if;

  if exists (select 1 from l2v.reps r where r.clinic_id = p_clinic_id and r.contact_id = p_contact_id and r.is_active)
     or exists (select 1 from l2v.settings s where s.clinic_id = p_clinic_id and s.manager_contact_id = p_contact_id) then
    return;
  end if;

  v_has_referral := p_referral is not null
                and p_referral <> 'null'::jsonb
                and p_referral <> '{}'::jsonb;

  if not v_has_referral and exists (
    select 1
      from public.appointments ap
     where ap.clinic_id = p_clinic_id
       and ap.contact_id = p_contact_id
       and ap.status in ('confirmed', 'completed')
  ) then
    return;
  end if;

  if v_has_referral then
    select l.* into v_open_lead
      from l2v.leads l
     where l.clinic_id = p_clinic_id
       and l.contact_id = p_contact_id
       and l.status <> 'closed'
     for update;

    if found
       and coalesce(v_open_lead.referral ->> 'source_id', v_open_lead.referral::text, '')
           is distinct from coalesce(p_referral ->> 'source_id', p_referral::text, '')
       and exists (
         select 1
           from public.appointments ap
          where ap.clinic_id = p_clinic_id
            and ap.contact_id = p_contact_id
            and ap.created_at >= v_open_lead.created_at
            and ap.status in ('confirmed', 'completed')
       ) then
      update l2v.leads set status = 'closed' where id = v_open_lead.id;
    end if;
  end if;

  return query
  select *
    from l2v.capture_lead(
      p_clinic_id, p_contact_id, p_source, p_campaign, null, p_referral, p_received_at
    );
end;
$$;

-- Is the clinic currently within configured l2v.settings working hours?
-- Default NULL (no l2v.settings row, or open_time/close_time/open_days all NULL) = always open.
create function l2v.is_clinic_open(p_clinic_id uuid, p_at timestamptz default now())
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz         text := 'Africa/Cairo';
  v_open_time  time;
  v_close_time time;
  v_open_days  smallint[];
  v_local_ts   timestamp;
  v_local_dow  smallint;
  v_local_time time;
begin
  if p_clinic_id is null then
    return true;
  end if;

  select coalesce(nullif(c.timezone, ''), 'Africa/Cairo')
    into v_tz
    from public.clinics c
   where c.id = p_clinic_id;

  select s.open_time, s.close_time, s.open_days
    into v_open_time, v_close_time, v_open_days
    from l2v.settings s
   where s.clinic_id = p_clinic_id;

  if not found or (v_open_time is null and v_close_time is null and v_open_days is null) then
    return true;
  end if;

  v_local_ts   := coalesce(p_at, now()) at time zone v_tz;
  v_local_dow  := extract(dow from v_local_ts)::smallint;
  v_local_time := v_local_ts::time;

  if v_open_days is not null and not (v_local_dow = any (v_open_days)) then
    return false;
  end if;

  if v_open_time is not null and v_close_time is not null then
    if v_open_time < v_close_time then
      return v_local_time >= v_open_time and v_local_time < v_close_time;
    else
      return v_local_time >= v_open_time or v_local_time < v_close_time;
    end if;
  elsif v_open_time is not null then
    return v_local_time >= v_open_time;
  elsif v_close_time is not null then
    return v_local_time < v_close_time;
  end if;

  return true;
end;
$$;

-- Internal assignment helper allowing an explicit SLA start timestamp (e.g. opening time).
create function l2v._assign_lead_at(
  p_lead_id         uuid,
  p_exclude_rep_ids uuid[] default '{}',
  p_sla_start_at    timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lead    l2v.leads%rowtype;
  v_phone   text;
  v_sla     integer;
  v_rep     l2v.reps%rowtype;
  v_attempt smallint;
  v_base_ts timestamptz;
  v_id      uuid;
begin
  select * into v_lead from l2v.leads where id = p_lead_id for update;
  if not found then
    raise exception 'lead % not found', p_lead_id;
  end if;

  -- idempotent: a live assignment already exists
  select a.id into v_id
    from l2v.assignments a
   where a.lead_id = p_lead_id and a.status in ('pending', 'acked');
  if found then
    return v_id;
  end if;

  select coalesce((select s.sla_minutes from l2v.settings s where s.clinic_id = v_lead.clinic_id), 15)
    into v_sla;
  select c.phone_e164 into v_phone from public.contacts c where c.id = v_lead.contact_id;

  select r.* into v_rep
    from l2v.reps r
   where r.clinic_id = v_lead.clinic_id
     and r.is_active
     and r.id <> all (p_exclude_rep_ids)
   order by r.last_assigned_at nulls first, r.created_at
   for update skip locked
   limit 1;
  if not found then
    return null;
  end if;

  select coalesce(max(a.attempt), 0) + 1 into v_attempt
    from l2v.assignments a where a.lead_id = p_lead_id;

  v_base_ts := coalesce(p_sla_start_at, now());

  insert into l2v.assignments (lead_id, rep_id, attempt, sla_due_at)
  values (p_lead_id, v_rep.id, v_attempt, v_base_ts + make_interval(mins => v_sla))
  returning id into v_id;

  update l2v.reps set last_assigned_at = now() where id = v_rep.id;

  perform l2v._notify(
    v_lead.clinic_id, v_rep.contact_id, 'lead_handoff',
    'عميل جديد جاهز للتواصل: ' || coalesce(nullif(v_lead.treatment_interest, ''), '-')
      || ' (' || v_phone || '). تواصل معاه خلال ' || v_sla || ' دقيقة وإلا هيتحوّل لزميلك.',
    array[coalesce(nullif(v_lead.treatment_interest, ''), '-'), v_phone, v_sla::text],
    'l2v_ack:' || v_id::text,
    'l2v:handoff:' || v_id::text
  );

  return v_id;
end;
$$;

-- Round-robin: the active rep assigned least recently gets the lead.
-- Returns the assignment id, or null when no eligible rep is left.
create function l2v.assign_lead(p_lead_id uuid, p_exclude_rep_ids uuid[] default '{}')
returns uuid
language sql
security definer
set search_path = ''
as $$
  select l2v._assign_lead_at(p_lead_id, p_exclude_rep_ids, now());
$$;

-- Deterministic scoring. Hot (>= 70) leads are assigned immediately when the clinic is open;
-- when closed, a new hot lead stays hot and unassigned until l2v.release_overnight() runs.
-- score = timing points + budget points; hot >= 70, warm 30..69, cold < 30.
create function l2v.set_qualification(
  p_lead_id     uuid,
  p_budget_band text,
  p_timing      text,
  p_treatment   text default null
)
returns table (status text, score smallint, assignment_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_score     integer;
  v_status    text;
  v_clinic_id uuid;
  v_assign    uuid;
begin
  v_score :=
    case p_timing when 'now' then 60 when 'this_month' then 35 when 'later' then 10 else 0 end
  + case p_budget_band when 'high' then 40 when 'mid' then 25 when 'low' then 5 else 0 end;

  v_status := case when v_score >= 70 then 'hot' when v_score >= 30 then 'warm' else 'cold' end;

  update l2v.leads l
     set budget_band = p_budget_band,
         timing = p_timing,
         score = v_score,
         status = case when l.status = 'closed' then l.status else v_status end,
         treatment_interest = coalesce(p_treatment, l.treatment_interest)
   where l.id = p_lead_id
   returning l.clinic_id into v_clinic_id;

  if not found then
    raise exception 'lead % not found', p_lead_id;
  end if;

  if v_status = 'hot' then
    if not exists (select 1 from l2v.assignments a where a.lead_id = p_lead_id) then
      if l2v.is_clinic_open(v_clinic_id) then
        v_assign := l2v.assign_lead(p_lead_id);
      else
        v_assign := null;
      end if;
    else
      select a.id into v_assign
        from l2v.assignments a
       where a.lead_id = p_lead_id and a.status in ('pending', 'acked')
       limit 1;
    end if;
  end if;

  return query select v_status, v_score::smallint, v_assign;
end;
$$;

-- Qualify by contact_id: finds the contact's open lead in this clinic and calls
-- l2v.set_qualification. Returns no row (does not raise) if there is no open lead.
create function l2v.qualify_contact(
  p_clinic_id   uuid,
  p_contact_id  uuid,
  p_budget_band text,
  p_timing      text,
  p_treatment   text default null
)
returns table (status text, score smallint, assignment_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lead l2v.leads%rowtype;
begin
  select l.* into v_lead
    from l2v.leads l
   where l.clinic_id = p_clinic_id
     and l.contact_id = p_contact_id
     and l.status <> 'closed';

  if not found then
    return;
  end if;

  return query
  select *
    from l2v.set_qualification(
      v_lead.id,
      coalesce(p_budget_band, v_lead.budget_band),
      coalesce(p_timing, v_lead.timing),
      p_treatment
    );
end;
$$;

-- A rep tapped the quick-reply button. Inbound button taps reach ClinicOS as text
-- (the title), so the rep is identified by phone and the OLDEST pending lead is acked.
-- reason: 'ok' | 'escalated' (the lead already moved to a colleague) | 'none'
create function l2v.rep_ack(p_clinic_id uuid, p_phone_e164 text)
returns table (acked boolean, assignment_id uuid, lead_id uuid, reason text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rep uuid;
  v_a   l2v.assignments%rowtype;
begin
  select r.id into v_rep
    from l2v.reps r
    join public.contacts c on c.id = r.contact_id
   where r.clinic_id = p_clinic_id
     and r.is_active
     and c.phone_e164 = p_phone_e164;
  if not found then
    return query select false, null::uuid, null::uuid, 'none'::text;
    return;
  end if;

  select a.* into v_a
    from l2v.assignments a
   where a.rep_id = v_rep and a.status = 'pending'
   order by a.assigned_at
   limit 1
     for update skip locked;

  if found then
    update l2v.assignments set status = 'acked', acked_at = now() where id = v_a.id;
    return query select true, v_a.id, v_a.lead_id, 'ok'::text;
    return;
  end if;

  select a.* into v_a
    from l2v.assignments a
   where a.rep_id = v_rep and a.status = 'escalated'
     and a.escalated_at > now() - interval '24 hours'
   order by a.escalated_at desc
   limit 1;
  if found then
    return query select false, v_a.id, v_a.lead_id, 'escalated'::text;
  else
    return query select false, null::uuid, null::uuid, 'none'::text;
  end if;
end;
$$;

-- Explicitly close an open lead (won or archived), freeing the contact's
-- unique open-lead slot for future campaigns while preserving KPI history.
create function l2v.close_lead(p_clinic_id uuid, p_lead_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_closed boolean := false;
begin
  if p_clinic_id is null or p_lead_id is null then
    return false;
  end if;

  update l2v.leads l
     set status = 'closed'
   where l.clinic_id = p_clinic_id
     and l.id = p_lead_id
     and l.status <> 'closed';

  get diagnostics v_closed = row_count;
  return coalesce(v_closed, false);
end;
$$;

-- Once the clinic is open, assigns all unassigned hot leads in round-robin order
-- with SLA starting at the clinic's opening time (idempotent; skips closed clinics
-- and leads whose patient already booked).
create function l2v.release_overnight()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r          record;
  v_tz       text;
  v_open_t   time;
  v_close_t  time;
  v_local_ts timestamp;
  v_open_at  timestamptz;
  v_new      uuid;
  v_count    integer := 0;
begin
  for r in
    select l.id as lead_id, l.clinic_id, l.created_at
      from l2v.leads l
     where l.status = 'hot'
       and l2v.is_clinic_open(l.clinic_id)
       and not exists (
         select 1 from l2v.assignments a where a.lead_id = l.id
       )
       and not exists (
         select 1 from public.appointments ap
          where ap.clinic_id = l.clinic_id
            and ap.contact_id = l.contact_id
            and ap.created_at >= l.created_at
            and ap.status in ('confirmed', 'completed')
       )
     order by l.created_at, l.id
       for update of l skip locked
     limit 50
  loop
    select coalesce(nullif(c.timezone, ''), 'Africa/Cairo'), s.open_time, s.close_time
      into v_tz, v_open_t, v_close_t
      from public.clinics c
      left join l2v.settings s on s.clinic_id = c.id
     where c.id = r.clinic_id;

    if v_open_t is not null then
      v_local_ts := now() at time zone v_tz;
      if v_close_t is not null and v_open_t > v_close_t and v_local_ts::time < v_close_t then
        v_open_at := ((v_local_ts::date - 1) + v_open_t) at time zone v_tz;
      else
        v_open_at := (v_local_ts::date + v_open_t) at time zone v_tz;
      end if;
    else
      v_open_at := now();
    end if;

    v_new := l2v._assign_lead_at(r.lead_id, '{}'::uuid[], greatest(v_open_at, r.created_at));
    if v_new is not null then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

-- Run every minute from n8n. Closes assignments whose patient already booked,
-- then (while the clinic is open) moves overdue ones to the next rep and alerts the manager.
-- Returns the number of escalated assignments.
create function l2v.escalate_overdue()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r         record;
  v_new     uuid;
  v_to_name text;
  v_count   integer := 0;
begin
  -- the AI receptionist already booked this patient: no rep action needed
  update l2v.assignments a
     set status = 'closed_booked'
    from l2v.leads l
   where a.lead_id = l.id
     and a.status = 'pending'
     and exists (
       select 1 from public.appointments ap
        where ap.clinic_id = l.clinic_id
          and ap.contact_id = l.contact_id
          and ap.created_at >= l.created_at
          and ap.status in ('confirmed', 'completed')
     );

  for r in
    select a.id, a.lead_id, a.rep_id,
           l.clinic_id, l.treatment_interest,
           lc.phone_e164 as lead_phone,
           rp.name as from_rep,
           s.manager_contact_id,
           coalesce(s.sla_minutes, 15) as sla_minutes
      from l2v.assignments a
      join l2v.leads l      on l.id = a.lead_id
      join public.contacts lc on lc.id = l.contact_id
      join l2v.reps rp      on rp.id = a.rep_id
      left join l2v.settings s on s.clinic_id = l.clinic_id
     where a.status = 'pending'
       and a.sla_due_at <= now()
       and l2v.is_clinic_open(l.clinic_id)
     order by a.sla_due_at
       for update of a skip locked
     limit 50
  loop
    update l2v.assignments set status = 'escalated', escalated_at = now() where id = r.id;

    v_new := l2v.assign_lead(
      r.lead_id,
      array(select x.rep_id from l2v.assignments x where x.lead_id = r.lead_id)
    );

    v_to_name := null;
    if v_new is not null then
      select rp.name into v_to_name
        from l2v.assignments x join l2v.reps rp on rp.id = x.rep_id
       where x.id = v_new;
    end if;

    if r.manager_contact_id is not null then
      if v_new is null then
        perform l2v._notify(
          r.clinic_id, r.manager_contact_id, 'sla_breach_no_rep',
          'تنبيه: العميل ' || r.lead_phone || ' ما اتسلّمش لأي موظف وكل الموظفين جرّبوا. محتاج تدخلك.',
          array[r.lead_phone],
          null,
          'l2v:breach:' || r.id::text
        );
      else
        perform l2v._notify(
          r.clinic_id, r.manager_contact_id, 'sla_breach',
          'تنبيه: ' || r.from_rep || ' اتأخر على العميل ' || r.lead_phone || ' أكتر من '
            || r.sla_minutes || ' دقيقة، واتحوّل العميل لـ' || v_to_name || '.',
          array[r.from_rep, r.lead_phone, r.sla_minutes::text, v_to_name],
          null,
          'l2v:breach:' || r.id::text
        );
      end if;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Daily KPIs for the clinic report (clinic timezone).
--   avg_first_reply_s : seconds from first inbound message to first outbound WhatsApp reply
--                       (measures the bot's instant auto-reply via outbox.sent_at or messages out;
--                        does not measure reception staff response speed)
--   booked_leads      : leads whose patient got a confirmed/completed appointment after the lead
--   no_shows / visits : appointments that started that day and are resolved (completed or no_show)
create function l2v.kpi_daily(p_clinic_id uuid, p_from date, p_to date)
returns table (
  day               date,
  leads             integer,
  hot_leads         integer,
  avg_first_reply_s integer,
  escalations       integer,
  booked_leads      integer,
  visits            integer,
  no_shows          integer,
  leads_ads         integer,
  leads_organic     integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with tz as (
    select coalesce(nullif(c.timezone, ''), 'UTC') as name from public.clinics c where c.id = p_clinic_id
  ), days as (
    select d::date as day
      from generate_series(p_from, p_to, interval '1 day') d
     where p_clinic_id is not null and p_from is not null and p_to is not null and p_from <= p_to
  ), lead_stats as (
    select (l.created_at at time zone tz.name)::date as day,
           count(*)::integer as leads,
           count(*) filter (where l.status = 'hot')::integer as hot_leads,
           avg(fr.first_out - l.first_inbound_at) filter (where fr.first_out is not null) as avg_reply,
           count(*) filter (where exists (
             select 1 from public.appointments ap
              where ap.clinic_id = l.clinic_id
                and ap.contact_id = l.contact_id
                and ap.created_at >= l.created_at
                and ap.status in ('confirmed', 'completed')))::integer as booked_leads,
           count(*) filter (where l.source <> 'organic')::integer as leads_ads,
           count(*) filter (where l.source = 'organic')::integer as leads_organic
      from l2v.leads l
      cross join tz
      left join lateral (
        select nullif(least(
          coalesce((
            select min(m.created_at)
              from public.messages m
              join public.conversations cv on cv.id = m.conversation_id
             where cv.clinic_id = l.clinic_id
               and cv.contact_id = l.contact_id
               and m.direction = 'out'
               and m.created_at >= l.first_inbound_at
          ), 'infinity'::timestamptz),
          coalesce((
            select min(coalesce(o.sent_at, o.created_at))
              from public.outbox o
             where o.clinic_id = l.clinic_id
               and o.contact_id = l.contact_id
               and o.status = 'sent'
               and coalesce(o.sent_at, o.created_at) >= l.first_inbound_at
          ), 'infinity'::timestamptz)
        ), 'infinity'::timestamptz) as first_out
      ) fr on true
     where l.clinic_id = p_clinic_id
       and (l.created_at at time zone tz.name)::date between p_from and p_to
     group by 1
  ), esc as (
    select (a.escalated_at at time zone tz.name)::date as day, count(*)::integer as escalations
      from l2v.assignments a
      join l2v.leads l on l.id = a.lead_id
      cross join tz
     where l.clinic_id = p_clinic_id
       and a.escalated_at is not null
       and (a.escalated_at at time zone tz.name)::date between p_from and p_to
     group by 1
  ), appt as (
    select (ap.starts_at at time zone tz.name)::date as day,
           count(*) filter (where ap.status in ('completed', 'no_show'))::integer as visits,
           count(*) filter (where ap.status = 'no_show')::integer as no_shows
      from public.appointments ap
      cross join tz
     where ap.clinic_id = p_clinic_id
       and (ap.starts_at at time zone tz.name)::date between p_from and p_to
     group by 1
  )
  select d.day,
         coalesce(ls.leads, 0),
         coalesce(ls.hot_leads, 0),
         extract(epoch from ls.avg_reply)::integer,
         coalesce(e.escalations, 0),
         coalesce(ls.booked_leads, 0),
         coalesce(ap.visits, 0),
         coalesce(ap.no_shows, 0),
         coalesce(ls.leads_ads, 0),
         coalesce(ls.leads_organic, 0)
    from days d
    left join lead_stats ls on ls.day = d.day
    left join esc e         on e.day = d.day
    left join appt ap       on ap.day = d.day
   order by d.day;
$$;

-- Latest leads for the clinic dashboard (max 50), with phone numbers masked
-- so all digits except the last 3 digits are replaced with '*'.
create function l2v.recent_leads(p_clinic_id uuid, p_limit integer default 50)
returns table (
  lead_id            uuid,
  phone_masked       text,
  status             text,
  source             text,
  score              smallint,
  campaign           text,
  treatment_interest text,
  created_at         timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  with lim as (
    select least(greatest(coalesce(p_limit, 50), 1), 50) as n
  ),
  raw_leads as (
    select l.id as lead_id,
           pg_catalog.regexp_replace(coalesce(c.phone_e164, ''), '[^0-9]', '', 'g') as digits,
           l.status,
           l.source,
           l.score,
           l.campaign,
           l.treatment_interest,
           l.created_at
      from l2v.leads l
      join public.contacts c
        on c.id = l.contact_id
       and c.clinic_id = l.clinic_id
     where p_clinic_id is not null
       and l.clinic_id = p_clinic_id
     order by l.created_at desc, l.id desc
     limit (select n from lim)
  )
  select r.lead_id,
         case
           when length(r.digits) <= 3 then '***'
           else '+' || repeat('*', length(r.digits) - 3) || right(r.digits, 3)
         end as phone_masked,
         r.status,
         r.source,
         r.score,
         r.campaign,
         r.treatment_interest,
         r.created_at
    from raw_leads r;
$$;

-- ---------------------------------------------------------------------
-- Security: RLS on with no policies (nothing readable directly); all access
-- goes through the SECURITY DEFINER functions above. Only the ClinicOS runtime
-- role (and Supabase service_role) may call them.
-- ---------------------------------------------------------------------
alter table l2v.settings    enable row level security;
alter table l2v.reps        enable row level security;
alter table l2v.leads       enable row level security;
alter table l2v.assignments enable row level security;

revoke all on schema l2v from public, anon, authenticated;
revoke all on all tables    in schema l2v from public, anon, authenticated;
revoke all on all functions in schema l2v from public, anon, authenticated;

do $$
declare
  v_role text;
begin
  foreach v_role in array array['clinicos_api_owner', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = v_role) then
      execute format('grant usage on schema l2v to %I', v_role);
      execute format('grant execute on function
        l2v.is_staff(uuid, text),
        l2v.is_clinic_open(uuid, timestamptz),
        l2v.capture_lead(uuid, uuid, text, text, text, jsonb, timestamptz),
        l2v.capture_lead_guarded(uuid, uuid, text, text, jsonb, timestamptz),
        l2v.assign_lead(uuid, uuid[]),
        l2v.set_qualification(uuid, text, text, text),
        l2v.qualify_contact(uuid, uuid, text, text, text),
        l2v.rep_ack(uuid, text),
        l2v.close_lead(uuid, uuid),
        l2v.release_overnight(),
        l2v.escalate_overdue(),
        l2v.kpi_daily(uuid, date, date),
        l2v.recent_leads(uuid, integer)
        to %I', v_role);
    end if;
  end loop;
end $$;
