-- Tests for database/05_lead_engine.sql against the REAL ClinicOS schema.
-- Run with tests/l2v/run_local.sh (scratch Postgres cluster, never production).
-- Manual run: psql -v ON_ERROR_STOP=1 -v repo=/path/to/checkout -v fns=/path/to/real_fns.sql -f tests/l2v/l2v_addon_test.sql
\set ON_ERROR_STOP on

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon')               then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated')      then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role')       then create role service_role nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'clinicos_api_owner') then create role clinicos_api_owner nologin; end if;
end $$;

create schema if not exists private;
\i :repo/database/01_schema.sql
\i :fns
\i :repo/database/05_lead_engine.sql

do $$
declare
  v_clinic uuid; v_p1 uuid; v_p2 uuid; v_rep1 uuid; v_rep2 uuid; v_mgr uuid;
  v_prov uuid; v_svc uuid; v_conv uuid;
  v_lead uuid; v_lead2 uuid; v_lead3 uuid; v_new boolean;
  v_q record; v_ack record; v_a1 uuid; v_a2 uuid; v_n integer; v_cnt integer;
  v_kind text; v_payload jsonb; v_row record;
begin
  insert into public.clinics (name, timezone, settings) values (
    'Test Clinic', 'Africa/Cairo',
    '{"whatsapp_templates":{
        "lead_handoff":{"name":"lead_handoff","language_codes":{"ar":"ar","en":"en"}},
        "sla_breach":{"name":"sla_breach","language_codes":{"ar":"ar"}},
        "sla_breach_no_rep":{"name":"sla_breach_no_rep","language_codes":{"ar":"ar"}}}}'::jsonb
  ) returning id into v_clinic;

  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201111111111', 'Sara')   returning id into v_p1;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201222222222', 'Omar')   returning id into v_p2;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201000000011', 'Ahmed')  returning id into v_rep1;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201000000012', 'Mohamed') returning id into v_rep2;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201000000001', 'Manager') returning id into v_mgr;

  insert into l2v.settings (clinic_id, manager_contact_id) values (v_clinic, v_mgr);
  insert into l2v.reps (clinic_id, contact_id, name) values (v_clinic, v_rep1, 'Ahmed');
  insert into l2v.reps (clinic_id, contact_id, name) values (v_clinic, v_rep2, 'Mohamed');

  -- is_staff
  assert l2v.is_staff(v_clinic, '+201000000011'), 'rep is staff';
  assert l2v.is_staff(v_clinic, '+201000000001'), 'manager is staff';
  assert not l2v.is_staff(v_clinic, '+201111111111'), 'patient is not staff';

  -- 1. capture + dedupe + guards
  select * into v_lead, v_new from l2v.capture_lead(v_clinic, v_p1, 'click_to_whatsapp', 'camp1', 'botox', '{"source_id":"ad1"}'::jsonb);
  assert v_new, 'first capture is new';
  select * into v_lead2, v_new from l2v.capture_lead(v_clinic, v_p1, 'click_to_whatsapp');
  assert v_lead2 = v_lead and not v_new, 'second capture returns the open lead';
  begin
    perform l2v.capture_lead(v_clinic, v_rep1);
    raise exception 'staff captured as lead';
  exception when raise_exception then
    assert sqlerrm like '%is staff%', 'staff guard message, got ' || sqlerrm;
  end;
  begin
    perform l2v.capture_lead(gen_random_uuid(), v_p1);
    raise exception 'foreign clinic accepted';
  exception when raise_exception then
    assert sqlerrm like '%does not belong%', 'clinic guard, got ' || sqlerrm;
  end;

  -- 2. qualification thresholds
  select * into v_q from l2v.set_qualification(v_lead, 'low', 'later');
  assert v_q.status = 'cold' and v_q.score = 15 and v_q.assignment_id is null, 'cold';
  select * into v_q from l2v.set_qualification(v_lead, 'low', 'now');
  assert v_q.status = 'warm' and v_q.score = 65 and v_q.assignment_id is null, 'warm';
  select count(*) into v_cnt from public.outbox; assert v_cnt = 0, 'no outbox rows before hot';
  select * into v_q from l2v.set_qualification(v_lead, 'mid', 'now');
  assert v_q.status = 'hot' and v_q.score = 85 and v_q.assignment_id is not null, 'hot + assigned';
  v_a1 := v_q.assignment_id;
  select * into v_q from l2v.set_qualification(v_lead, 'mid', 'now');
  assert v_q.assignment_id = v_a1, 'assignment idempotent';

  -- 3. handoff went through the REAL public.enqueue_message into the ClinicOS outbox
  select count(*) into v_cnt from public.outbox where contact_id = v_rep1 and idempotency_key = 'l2v:handoff:' || v_a1::text;
  assert v_cnt = 1, 'exactly one handoff outbox row, got ' || v_cnt;
  select kind, payload into v_kind, v_payload from public.outbox where contact_id = v_rep1;
  assert v_kind = 'template', 'handoff is a template, got ' || v_kind;
  assert v_payload #>> '{template,name}' = 'lead_handoff', 'template name from clinic settings';
  assert v_payload #>> '{template,components,0,type}' = 'body', 'body component first';
  assert v_payload #>> '{template,components,1,sub_type}' = 'quick_reply', 'button component present';
  assert v_payload #>> '{template,components,1,parameters,0,payload}' = 'l2v_ack:' || v_a1::text, 'button carries assignment id';
  assert (select count(*) from public.outbox where is_marketing) = 0, 'handoff is not marketing';

  -- 4. not due -> nothing; due -> escalate to second rep + manager alert
  assert l2v.escalate_overdue() = 0, 'nothing overdue';
  update l2v.assignments set sla_due_at = now() - interval '1 minute' where id = v_a1;
  assert l2v.escalate_overdue() = 1, 'one escalation';
  select id into v_a2 from l2v.assignments where lead_id = v_lead and status = 'pending';
  assert v_a2 is not null and v_a2 <> v_a1, 'new pending assignment';
  assert (select r.name from l2v.assignments a join l2v.reps r on r.id = a.rep_id where a.id = v_a2) = 'Mohamed', 'went to second rep';
  assert (select count(*) from public.outbox where contact_id = v_mgr and payload #>> '{template,name}' = 'sla_breach') = 1, 'manager alerted';
  assert (select count(*) from public.outbox where contact_id = v_rep2) = 1, 'second rep notified';
  -- running escalation again must not duplicate anything
  assert l2v.escalate_overdue() = 0, 'second run is a no-op';
  assert (select count(*) from public.outbox where contact_id = v_mgr) = 1, 'no duplicate manager alert';

  -- 5. rep_ack
  select * into v_ack from l2v.rep_ack(v_clinic, '+201000000011');
  assert not v_ack.acked and v_ack.reason = 'escalated', 'late ack tells rep the lead moved, got ' || v_ack.reason;
  select * into v_ack from l2v.rep_ack(v_clinic, '+201999999999');
  assert not v_ack.acked and v_ack.reason = 'none', 'unknown phone';
  select * into v_ack from l2v.rep_ack(v_clinic, '+201000000012');
  assert v_ack.acked and v_ack.reason = 'ok' and v_ack.assignment_id = v_a2, 'assigned rep acks';
  select * into v_ack from l2v.rep_ack(v_clinic, '+201000000012');
  assert not v_ack.acked, 'second tap has nothing pending';

  -- 6. nobody left -> manager told, no pending assignment
  select * into v_lead2, v_new from l2v.capture_lead(v_clinic, v_p2, 'lead_form', 'camp2', 'laser');
  perform l2v.set_qualification(v_lead2, 'high', 'now');           -- Ahmed (oldest last_assigned_at)
  update l2v.assignments set sla_due_at = now() - interval '1 minute' where lead_id = v_lead2 and status = 'pending';
  perform l2v.escalate_overdue();                                  -- -> Mohamed
  update l2v.assignments set sla_due_at = now() - interval '1 minute' where lead_id = v_lead2 and status = 'pending';
  perform l2v.escalate_overdue();                                  -- -> none
  assert (select count(*) from l2v.assignments where lead_id = v_lead2 and status = 'pending') = 0, 'no pending left';
  assert (select count(*) from public.outbox where contact_id = v_mgr and payload #>> '{template,name}' = 'sla_breach_no_rep') = 1, 'no-rep alert sent';

  -- 7. patient booked by the AI before the SLA ran out -> assignment closes, nobody is escalated
  update l2v.leads set status = 'closed' where id in (v_lead, v_lead2);
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201333333333', 'Laila') returning id into v_p2;
  select * into v_lead3, v_new from l2v.capture_lead(v_clinic, v_p2, 'click_to_whatsapp', 'camp3', 'hydrafacial');
  perform l2v.set_qualification(v_lead3, 'high', 'now');
  insert into public.providers (clinic_id, name) values (v_clinic, 'Dr L') returning id into v_prov;
  insert into public.services (clinic_id, code, name_ar, name_en) values (v_clinic, 'HYDRA', 'هيدرافيشل', 'Hydrafacial') returning id into v_svc;
  insert into public.appointments (clinic_id, contact_id, provider_id, service_id, starts_at, ends_at)
  values (v_clinic, v_p2, v_prov, v_svc, now() + interval '1 day', now() + interval '1 day 30 minutes');
  update l2v.assignments set sla_due_at = now() - interval '1 minute' where lead_id = v_lead3;
  v_n := (select count(*) from public.outbox where contact_id = v_mgr);
  assert l2v.escalate_overdue() = 0, 'booked lead is not escalated';
  assert (select status from l2v.assignments where lead_id = v_lead3) = 'closed_booked', 'assignment closed_booked';
  assert (select count(*) from public.outbox where contact_id = v_mgr) = v_n, 'manager not alerted for a booked lead';

  -- 8. opted-out rep: no error, no outbox row (ClinicOS enqueue_message enforces it)
  update public.contacts set communications_opted_out_at = now() where id = v_rep1;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201444444444', 'Nour') returning id into v_p2;
  select * into v_lead2, v_new from l2v.capture_lead(v_clinic, v_p2, 'website');
  v_n := (select count(*) from public.outbox where contact_id = v_rep1);
  perform l2v.set_qualification(v_lead2, 'high', 'now');           -- assignment goes to Ahmed (opted out)
  assert (select count(*) from public.outbox where contact_id = v_rep1) = v_n, 'opted-out rep gets no message';

  -- 9. KPI: first reply latency from ClinicOS messages, bookings, no-shows
  update l2v.leads set first_inbound_at = now() - interval '1 hour', created_at = now() - interval '1 hour' where id = v_lead3;
  insert into public.conversations (clinic_id, contact_id) values (v_clinic, (select contact_id from l2v.leads where id = v_lead3)) returning id into v_conv;
  insert into public.messages (clinic_id, conversation_id, direction, created_at) values (v_clinic, v_conv, 'in',  now() - interval '1 hour');
  insert into public.messages (clinic_id, conversation_id, direction, created_at) values (v_clinic, v_conv, 'out', now() - interval '1 hour' + interval '8 seconds');
  insert into public.appointments (clinic_id, contact_id, provider_id, service_id, starts_at, ends_at, status)
  values (v_clinic, v_p1, v_prov, v_svc, now() - interval '2 hours', now() - interval '90 minutes', 'no_show');
  select * into v_row from l2v.kpi_daily(v_clinic, (now() at time zone 'Africa/Cairo')::date - 1, (now() at time zone 'Africa/Cairo')::date + 1)
   where leads > 0 limit 1;
  assert v_row.leads >= 1, 'kpi sees leads';
  raise notice 'KPI row: %', v_row;
  assert (select sum(no_shows) from l2v.kpi_daily(v_clinic, current_date - 1, current_date + 1)) = 1, 'kpi sees the no-show';
  assert (select max(avg_first_reply_s) from l2v.kpi_daily(v_clinic, current_date - 1, current_date + 1)) = 8, 'first reply = 8s';

  -- 10. T2: capture_lead_guarded and qualify_contact (5 cases)
  -- Case 1: happy path (new patient captured via referral, then qualified via qualify_contact)
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201555555555', 'Hana') returning id into v_p2;
  select * into v_lead, v_new
    from l2v.capture_lead_guarded(v_clinic, v_p2, 'click_to_whatsapp', 'camp_t2', '{"source_id":"ad_t2"}'::jsonb);
  assert v_lead is not null and v_new, 'T2 happy path: capture_lead_guarded creates open lead';
  select * into v_q from l2v.qualify_contact(v_clinic, v_p2, 'high', 'now', 'veneers');
  assert v_q.status = 'hot' and v_q.score = 100 and v_q.assignment_id is not null,
    'T2 happy path: qualify_contact scores hot and assigns';
  assert (select treatment_interest from l2v.leads where id = v_lead) = 'veneers',
    'T2 happy path: qualify_contact updates treatment';

  -- Case 2: no open lead -> qualify_contact returns no row and does not raise
  update l2v.leads set status = 'closed' where id = v_lead;
  select count(*) into v_cnt from l2v.qualify_contact(v_clinic, v_p2, 'high', 'now', 'veneers');
  assert v_cnt = 0, 'T2 no open lead: qualify_contact returns 0 rows, got ' || v_cnt;

  -- Case 3: staff -> capture_lead_guarded returns no row (rep & manager) instead of raising
  select count(*) into v_cnt
    from l2v.capture_lead_guarded(v_clinic, v_rep1, 'click_to_whatsapp', 'camp_staff', '{"source_id":"ad_staff"}'::jsonb);
  assert v_cnt = 0, 'T2 staff (rep): capture_lead_guarded returns 0 rows, got ' || v_cnt;
  select count(*) into v_cnt from l2v.capture_lead_guarded(v_clinic, v_mgr);
  assert v_cnt = 0, 'T2 staff (manager): capture_lead_guarded returns 0 rows, got ' || v_cnt;
  select count(*) into v_cnt from l2v.qualify_contact(v_clinic, v_rep1, 'high', 'now');
  assert v_cnt = 0, 'T2 staff: qualify_contact returns 0 rows, got ' || v_cnt;

  -- Case 4: existing patient (confirmed appointment) without referral -> returns no row
  insert into public.appointments (clinic_id, contact_id, provider_id, service_id, starts_at, ends_at, status)
  values (v_clinic, v_p2, v_prov, v_svc, now() + interval '3 days', now() + interval '3 days 30 minutes', 'confirmed');
  select count(*) into v_cnt from l2v.capture_lead_guarded(v_clinic, v_p2, 'organic', null, null);
  assert v_cnt = 0, 'T2 existing patient without referral: returns 0 rows, got ' || v_cnt;

  -- Case 5: existing patient (confirmed appointment) WITH referral -> captures lead
  select * into v_lead, v_new
    from l2v.capture_lead_guarded(v_clinic, v_p2, 'click_to_whatsapp', 'retarg_camp', '{"source_id":"ad_retarg"}'::jsonb);
  assert v_lead is not null and v_new, 'T2 existing patient with referral: captures new open lead';
  select * into v_lead2, v_new
    from l2v.capture_lead_guarded(v_clinic, v_p2, 'click_to_whatsapp', 'retarg_camp', '{"source_id":"ad_retarg"}'::jsonb);
  assert v_lead2 = v_lead and not v_new, 'T2 existing patient with referral: idempotent on open lead';

  raise notice 'T2 tests: happy_path, no_open_lead, staff, existing_no_referral, existing_with_referral: OK';

  -- Ensure rep1 is opted back in so handoff outbox assertions apply regardless of rotation order
  update public.contacts set communications_opted_out_at = null where id = v_rep1;

  -- (1) Qualify again after closed_booked -> still 1 assignment and 1 handoff row
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201666666666', 'Salma') returning id into v_p2;
  select * into v_lead, v_new
    from l2v.capture_lead_guarded(v_clinic, v_p2, 'click_to_whatsapp', 'camp_booked', '{"source_id":"ad_booked"}'::jsonb);
  select * into v_q from l2v.qualify_contact(v_clinic, v_p2, 'high', 'now', 'implant');
  v_a1 := v_q.assignment_id;
  assert v_a1 is not null, 'T2 booked guard: initial hot qualification assigns rep';
  assert (select count(*) from l2v.assignments where lead_id = v_lead) = 1, 'T2 booked guard: 1 assignment initially';
  assert (select count(*) from public.outbox where idempotency_key = 'l2v:handoff:' || v_a1::text) = 1,
    'T2 booked guard: 1 handoff row initially';
  insert into public.appointments (clinic_id, contact_id, provider_id, service_id, starts_at, ends_at, status)
  values (v_clinic, v_p2, v_prov, v_svc, now() + interval '4 days', now() + interval '4 days 30 minutes', 'confirmed');
  update l2v.assignments set sla_due_at = now() - interval '1 minute' where lead_id = v_lead;
  perform l2v.escalate_overdue();
  assert (select status from l2v.assignments where id = v_a1) = 'closed_booked',
    'T2 booked guard: assignment became closed_booked';
  v_n := (select count(*) from public.outbox);
  select * into v_q from l2v.qualify_contact(v_clinic, v_p2, 'high', 'now', 'implant');
  assert v_q.assignment_id is null, 'T2 booked guard: repeat qualify returns null assignment_id';
  assert (select count(*) from l2v.assignments where lead_id = v_lead) = 1,
    'T2 booked guard: still 1 assignment after re-qualify';
  assert (select count(*) from public.outbox) = v_n,
    'T2 booked guard: still 1 handoff row (no new outbox row)';

  -- (2) Qualify again after the escalation chain is exhausted -> no new assignment
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201777777777', 'Tarek') returning id into v_p2;
  select * into v_lead, v_new
    from l2v.capture_lead_guarded(v_clinic, v_p2, 'click_to_whatsapp', 'camp_exh', '{"source_id":"ad_exh"}'::jsonb);
  perform l2v.qualify_contact(v_clinic, v_p2, 'high', 'now', 'ortho');
  update l2v.assignments set sla_due_at = now() - interval '1 minute' where lead_id = v_lead and status = 'pending';
  perform l2v.escalate_overdue();
  update l2v.assignments set sla_due_at = now() - interval '1 minute' where lead_id = v_lead and status = 'pending';
  perform l2v.escalate_overdue();
  assert (select count(*) from l2v.assignments where lead_id = v_lead) = 2,
    'T2 exhausted guard: 2 escalated assignments total';
  assert (select count(*) from l2v.assignments where lead_id = v_lead and status = 'pending') = 0,
    'T2 exhausted guard: no pending assignment remains';
  v_n := (select count(*) from public.outbox);
  select * into v_q from l2v.qualify_contact(v_clinic, v_p2, 'high', 'now', 'ortho');
  assert v_q.assignment_id is null, 'T2 exhausted guard: repeat qualify returns null assignment_id';
  assert (select count(*) from l2v.assignments where lead_id = v_lead) = 2,
    'T2 exhausted guard: no new assignment created after exhaustion';
  assert (select count(*) from public.outbox) = v_n,
    'T2 exhausted guard: no new outbox handoff row after exhaustion';

  -- (3) Warm first, turns hot later -> still gets assigned once
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201888888888', 'Dina') returning id into v_p2;
  select * into v_lead, v_new
    from l2v.capture_lead_guarded(v_clinic, v_p2, 'click_to_whatsapp', 'camp_warm', '{"source_id":"ad_warm"}'::jsonb);
  select * into v_q from l2v.qualify_contact(v_clinic, v_p2, 'low', 'now', 'whitening');
  assert v_q.status = 'warm' and v_q.score = 65 and v_q.assignment_id is null,
    'T2 warm->hot: warm turn has no assignment';
  assert (select count(*) from l2v.assignments where lead_id = v_lead) = 0,
    'T2 warm->hot: 0 assignments while warm';
  select * into v_q from l2v.qualify_contact(v_clinic, v_p2, 'high', 'now', 'whitening');
  assert v_q.status = 'hot' and v_q.score = 100 and v_q.assignment_id is not null,
    'T2 warm->hot: assigned once lead turns hot';
  assert (select count(*) from l2v.assignments where lead_id = v_lead) = 1,
    'T2 warm->hot: exactly 1 assignment created';
  assert (select count(*) from public.outbox where idempotency_key = 'l2v:handoff:' || v_q.assignment_id::text) = 1,
    'T2 warm->hot: handoff outbox row queued';

  -- (4) capture_lead_guarded with NULL p_received_at creates the lead and sets first_inbound_at to non-null
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201999999991', 'Karim') returning id into v_p2;
  select * into v_lead, v_new
    from l2v.capture_lead_guarded(v_clinic, v_p2, 'organic', null, null, null);
  assert v_lead is not null and v_new, 'T3 null received_at: capture_lead_guarded creates open lead';
  assert (select first_inbound_at from l2v.leads where id = v_lead) is not null,
    'T3 null received_at: first_inbound_at defaulted via coalesce(p_received_at, now())';

  raise notice 'T2 re-qualify guards: after_closed_booked, after_chain_exhausted, warm_to_hot, null_received_at: OK';

  raise notice 'ALL ADD-ON TESTS PASSED';
end $$;

-- permissions
set role anon;
do $$ begin
  begin perform 1 from l2v.leads limit 1; raise exception 'anon read leads';
  exception when insufficient_privilege then raise notice 'anon table denied'; end;
  begin perform l2v.escalate_overdue(); raise exception 'anon executed function';
  exception when insufficient_privilege then raise notice 'anon function denied'; end;
  begin perform l2v.capture_lead_guarded(gen_random_uuid(), gen_random_uuid()); raise exception 'anon executed capture_lead_guarded';
  exception when insufficient_privilege then null; end;
  begin perform l2v.qualify_contact(gen_random_uuid(), gen_random_uuid(), 'low', 'later'); raise exception 'anon executed qualify_contact';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set role clinicos_api_owner;
do $$ begin
  perform l2v.is_staff(gen_random_uuid(), '+20');
  perform l2v.qualify_contact(gen_random_uuid(), gen_random_uuid(), 'low', 'later');
  begin perform 1 from l2v.leads limit 1; raise exception 'runtime role read table directly';
  exception when insufficient_privilege then raise notice 'runtime role: functions yes, tables no'; end;
end $$;
reset role;

-- 11. T7: database/05b_l2v_seed_example.sql double-execution idempotency & merge test
do $$
begin
  insert into public.clinics (id, name, timezone, settings)
  values (
    '00000000-0000-4000-8000-000000000099',
    'Seed Example Clinic',
    'Africa/Cairo',
    jsonb_build_object(
      'whatsapp_phone_number_id', 'YOUR_META_PHONE_NUMBER_ID',
      'slot_step_minutes', 30,
      'whatsapp_templates', jsonb_build_object(
        'appointment_reminder', jsonb_build_object(
          'name', 'appointment_reminder',
          'language_codes', jsonb_build_object('ar', 'ar')
        )
      )
    )
  );
end $$;

-- First run of 05b_l2v_seed_example.sql (multi-clinic test DB: verify 05b refuses ambiguity without clinicos.seed_clinic_id, then runs cleanly with it)
do $$
declare
  v_cnt integer;
begin
  select count(*)::int into v_cnt from public.clinics;
  assert v_cnt > 1, 'Expected >1 clinics in test DB before T7';
end $$;
set session clinicos.seed_clinic_id = '00000000-0000-4000-8000-000000000099';
\i :repo/database/05b_l2v_seed_example.sql

create temp table _t7_snapshot as
select
  (select count(*)::int from public.contacts where clinic_id = '00000000-0000-4000-8000-000000000099') as clinic_contacts_cnt,
  (select count(*)::int from public.contacts) as total_contacts_cnt,
  (select count(*)::int from l2v.settings where clinic_id = '00000000-0000-4000-8000-000000000099') as clinic_settings_cnt,
  (select count(*)::int from l2v.settings) as total_settings_cnt,
  (select count(*)::int from l2v.reps where clinic_id = '00000000-0000-4000-8000-000000000099') as clinic_reps_cnt,
  (select count(*)::int from l2v.reps) as total_reps_cnt,
  (select settings from public.clinics where id = '00000000-0000-4000-8000-000000000099') as clinic_settings_json,
  (select jsonb_agg(to_jsonb(c) order by c.phone_e164)
     from public.contacts c
    where c.clinic_id = '00000000-0000-4000-8000-000000000099') as contacts_rows,
  (select to_jsonb(s)
     from l2v.settings s
    where s.clinic_id = '00000000-0000-4000-8000-000000000099') as l2v_settings_row;

do $$
declare
  v_seed_clinic uuid := '00000000-0000-4000-8000-000000000099';
  v_mgr_id      uuid;
  v_settings    jsonb;
  v_sla         integer;
  v_sla_mgr     uuid;
begin
  -- Verify manager contact (+201000000001) and 2 reps (+201000000002, +201000000003)
  select id into v_mgr_id
    from public.contacts
   where clinic_id = v_seed_clinic and phone_e164 = '+201000000001';
  assert v_mgr_id is not null, 'T7 first run: manager contact +201000000001 seeded';

  assert (select count(*) from public.contacts
           where clinic_id = v_seed_clinic
             and phone_e164 in ('+201000000001', '+201000000002', '+201000000003')) = 3,
    'T7 first run: all 3 fake staff contacts seeded';

  -- Verify 15-minute SLA in l2v.settings linked to manager_contact_id
  select sla_minutes, manager_contact_id into v_sla, v_sla_mgr
    from l2v.settings
   where clinic_id = v_seed_clinic;
  assert v_sla = 15 and v_sla_mgr = v_mgr_id,
    'T7 first run: l2v.settings has sla_minutes=15 and manager_contact_id';

  -- Verify 2 active reps in l2v.reps
  assert (select count(*) from l2v.reps where clinic_id = v_seed_clinic and is_active) = 2,
    'T7 first run: 2 active reps in l2v.reps';
  assert l2v.is_staff(v_seed_clinic, '+201000000001'), 'T7 first run: +201000000001 is_staff';
  assert l2v.is_staff(v_seed_clinic, '+201000000002'), 'T7 first run: +201000000002 is_staff';
  assert l2v.is_staff(v_seed_clinic, '+201000000003'), 'T7 first run: +201000000003 is_staff';

  -- Verify clinics.settings merged the 3 whatsapp_templates keys without wiping existing keys
  select settings into v_settings from public.clinics where id = v_seed_clinic;
  assert v_settings ->> 'whatsapp_phone_number_id' = 'YOUR_META_PHONE_NUMBER_ID',
    'T7 first run: preserved existing settings key whatsapp_phone_number_id';
  assert (v_settings ->> 'slot_step_minutes')::int = 30,
    'T7 first run: preserved existing settings key slot_step_minutes';
  assert v_settings #>> '{whatsapp_templates,appointment_reminder,name}' = 'appointment_reminder',
    'T7 first run: preserved existing whatsapp_templates.appointment_reminder';
  assert v_settings #>> '{whatsapp_templates,lead_handoff,name}' = 'lead_handoff'
     and v_settings #>> '{whatsapp_templates,lead_handoff,language_codes,ar}' = 'ar',
    'T7 first run: seeded whatsapp_templates.lead_handoff';
  assert v_settings #>> '{whatsapp_templates,sla_breach,name}' = 'sla_breach'
     and v_settings #>> '{whatsapp_templates,sla_breach,language_codes,ar}' = 'ar',
    'T7 first run: seeded whatsapp_templates.sla_breach';
  assert v_settings #>> '{whatsapp_templates,sla_breach_no_rep,name}' = 'sla_breach_no_rep'
     and v_settings #>> '{whatsapp_templates,sla_breach_no_rep,language_codes,ar}' = 'ar',
    'T7 first run: seeded whatsapp_templates.sla_breach_no_rep';

  -- Set a non-null last_assigned_at on rep 1 before the second run to verify it is not wiped
  update l2v.reps
     set last_assigned_at = '2026-01-15 10:00:00+00'::timestamptz
   where clinic_id = v_seed_clinic
     and contact_id = (select id from public.contacts where clinic_id = v_seed_clinic and phone_e164 = '+201000000002');
end $$;

create temp table _t7_reps_before_second_run as
select jsonb_agg(to_jsonb(r) order by r.contact_id) as reps_rows
  from l2v.reps r
 where r.clinic_id = '00000000-0000-4000-8000-000000000099';

-- Second run of 05b_l2v_seed_example.sql (must be a complete no-op)
\i :repo/database/05b_l2v_seed_example.sql

do $$
declare
  v_seed_clinic uuid := '00000000-0000-4000-8000-000000000099';
  v_snap        record;
  v_reps_snap   jsonb;
begin
  select * into v_snap from _t7_snapshot;
  select reps_rows into v_reps_snap from _t7_reps_before_second_run;

  assert (select count(*)::int from public.contacts where clinic_id = v_seed_clinic) = v_snap.clinic_contacts_cnt,
    'T7 second run: clinic contacts count unchanged';
  assert (select count(*)::int from public.contacts) = v_snap.total_contacts_cnt,
    'T7 second run: total contacts count unchanged';
  assert (select count(*)::int from l2v.settings where clinic_id = v_seed_clinic) = v_snap.clinic_settings_cnt,
    'T7 second run: clinic l2v.settings count unchanged';
  assert (select count(*)::int from l2v.settings) = v_snap.total_settings_cnt,
    'T7 second run: total l2v.settings count unchanged';
  assert (select count(*)::int from l2v.reps where clinic_id = v_seed_clinic) = v_snap.clinic_reps_cnt,
    'T7 second run: clinic l2v.reps count unchanged';
  assert (select count(*)::int from l2v.reps) = v_snap.total_reps_cnt,
    'T7 second run: total l2v.reps count unchanged';
  assert (select settings from public.clinics where id = v_seed_clinic) = v_snap.clinic_settings_json,
    'T7 second run: clinics.settings JSON identical';
  assert (select jsonb_agg(to_jsonb(c) order by c.phone_e164)
            from public.contacts c
           where c.clinic_id = v_seed_clinic) = v_snap.contacts_rows,
    'T7 second run: contacts rows and updated_at timestamps identical';
  assert (select to_jsonb(s)
            from l2v.settings s
           where s.clinic_id = v_seed_clinic) = v_snap.l2v_settings_row,
    'T7 second run: l2v.settings row and created_at identical';
  assert (select jsonb_agg(to_jsonb(r) order by r.contact_id)
            from l2v.reps r
           where r.clinic_id = v_seed_clinic) = v_reps_snap,
    'T7 second run: l2v.reps rows and last_assigned_at timestamps identical';

  raise notice 'T7 seed example: first run seeded + second run idempotent: OK';
end $$;

-- Customise after seed run and verify re-running 05b_l2v_seed_example.sql
-- does not overwrite staff configuration or existing whatsapp_templates entries.
do $$
declare
  v_seed_clinic uuid := '00000000-0000-4000-8000-000000000099';
  v_real_mgr    uuid;
  v_rep1        uuid;
begin
  -- (a) change l2v.settings.sla_minutes to 30 and manager_contact_id to a real contact
  insert into public.contacts (clinic_id, phone_e164, name)
  values (v_seed_clinic, '+201099999999', 'Real Manager')
  returning id into v_real_mgr;

  update l2v.settings
     set sla_minutes        = 30,
         manager_contact_id = v_real_mgr
   where clinic_id = v_seed_clinic;

  -- (b) deactivate one rep
  select id into v_rep1
    from public.contacts
   where clinic_id = v_seed_clinic and phone_e164 = '+201000000002';

  update l2v.reps
     set is_active = false
   where clinic_id = v_seed_clinic
     and contact_id = v_rep1;

  -- (c) rename whatsapp_templates.lead_handoff.name to 'lead_handoff_v2' in public.clinics.settings
  update public.clinics
     set settings = jsonb_set(settings, '{whatsapp_templates,lead_handoff,name}', '"lead_handoff_v2"'::jsonb)
   where id = v_seed_clinic;
end $$;

\i :repo/database/05b_l2v_seed_example.sql

do $$
declare
  v_seed_clinic uuid := '00000000-0000-4000-8000-000000000099';
  v_real_mgr    uuid;
  v_rep1        uuid;
  v_sla         integer;
  v_sla_mgr     uuid;
  v_tpl_name    text;
begin
  select id into v_real_mgr
    from public.contacts
   where clinic_id = v_seed_clinic and phone_e164 = '+201099999999';

  select id into v_rep1
    from public.contacts
   where clinic_id = v_seed_clinic and phone_e164 = '+201000000002';

  select sla_minutes, manager_contact_id into v_sla, v_sla_mgr
    from l2v.settings
   where clinic_id = v_seed_clinic;

  assert v_sla = 30,
    'T7 customisation preserved: expected sla_minutes = 30, got ' || coalesce(v_sla::text, 'null');
  assert v_sla_mgr = v_real_mgr,
    'T7 customisation preserved: expected manager_contact_id = ' || v_real_mgr || ', got ' || coalesce(v_sla_mgr::text, 'null');
  assert (select is_active from l2v.reps where clinic_id = v_seed_clinic and contact_id = v_rep1) = false,
    'T7 customisation preserved: deactivated rep must remain is_active = false';

  select settings #>> '{whatsapp_templates,lead_handoff,name}' into v_tpl_name
    from public.clinics
   where id = v_seed_clinic;
  assert v_tpl_name = 'lead_handoff_v2',
    'T7 customisation preserved: expected lead_handoff.name = lead_handoff_v2, got ' || coalesce(v_tpl_name, 'null');

  raise notice 'T7 customisation preservation after re-seed: OK';
end $$;

-- 12. L2V audit fixes (active-staff checks, close_lead, source upgrade, ad re-entry,
--     escalate_overdue clinic scope, and kpi_daily outbox auto-reply latency)
do $$
declare
  v_seed_clinic uuid := '00000000-0000-4000-8000-000000000099';
  v_rep1_cid    uuid;
  v_rep2_cid    uuid;
  v_pat_a       uuid;
  v_pat_b       uuid;
  v_prov_id     uuid;
  v_svc_id      uuid;
  v_lead        uuid;
  v_lead2       uuid;
  v_new         boolean;
  v_q           record;
  v_ack         record;
  v_reply_s     integer;
  v_kpi_cnt     integer;
begin
  select id into v_rep1_cid from public.contacts where clinic_id = v_seed_clinic and phone_e164 = '+201000000002';
  select id into v_rep2_cid from public.contacts where clinic_id = v_seed_clinic and phone_e164 = '+201000000003';

  -- (a) Deactivated rep (+201000000002 was deactivated in T7 above) is no longer treated as staff
  assert not l2v.is_staff(v_seed_clinic, '+201000000002'),
    'B: deactivated rep must not be treated as staff by l2v.is_staff';
  assert l2v.is_staff(v_seed_clinic, '+201000000003'),
    'B: active rep must remain staff';

  -- Deactivated rep cannot ack even if they had a pending assignment before deactivation
  insert into public.contacts (clinic_id, phone_e164, name)
  values (v_seed_clinic, '+201119990001', 'Pat Ack Test')
  returning id into v_pat_a;
  select * into v_lead, v_new from l2v.capture_lead_guarded(v_seed_clinic, v_pat_a, 'click_to_whatsapp', 'c_ack', '{"source_id":"ad_ack"}'::jsonb);
  select * into v_q from l2v.qualify_contact(v_seed_clinic, v_pat_a, 'high', 'now', 'whitening');
  assert v_q.assignment_id is not null, 'B: active rep2 receives assignment';

  update l2v.reps set is_active = false where clinic_id = v_seed_clinic and contact_id = v_rep2_cid;
  select * into v_ack from l2v.rep_ack(v_seed_clinic, '+201000000003');
  assert not v_ack.acked and v_ack.reason = 'none',
    'B: rep_ack must refuse deactivated rep even with a pending assignment';
  update l2v.reps set is_active = true where clinic_id = v_seed_clinic and contact_id = v_rep2_cid;
  select * into v_ack from l2v.rep_ack(v_seed_clinic, '+201000000003');
  assert v_ack.acked and v_ack.reason = 'ok',
    'B: reactivated rep can ack the pending assignment';

  -- Deactivated rep messaging as patient can be captured cleanly; close_lead lifecycle & bounds
  select * into v_lead, v_new from l2v.capture_lead_guarded(v_seed_clinic, v_rep1_cid, 'organic');
  assert v_lead is not null and v_new, 'B: deactivated rep can be captured as organic lead';

  assert not l2v.close_lead(null, v_lead), 'B: close_lead rejects null clinic_id';
  assert not l2v.close_lead(v_seed_clinic, null), 'B: close_lead rejects null lead_id';
  assert not l2v.close_lead(gen_random_uuid(), v_lead), 'B: close_lead enforces clinic isolation';
  assert l2v.close_lead(v_seed_clinic, v_lead), 'B: close_lead closes open lead';
  assert (select status from l2v.leads where id = v_lead) = 'closed', 'B: lead status updated to closed';
  assert not l2v.close_lead(v_seed_clinic, v_lead), 'B: close_lead is idempotent on already-closed lead';

  -- (b) source upgrade ('organic' -> 'click_to_whatsapp') without downgrading reverse
  insert into public.contacts (clinic_id, phone_e164, name)
  values (v_seed_clinic, '+201119990002', 'Pat Upgrade')
  returning id into v_pat_b;

  select * into v_lead, v_new from l2v.capture_lead_guarded(v_seed_clinic, v_pat_b, 'organic');
  assert v_new and (select source from l2v.leads where id = v_lead) = 'organic', 'B: starts organic';

  select * into v_lead2, v_new
    from l2v.capture_lead_guarded(v_seed_clinic, v_pat_b, 'click_to_whatsapp', 'camp_up', '{"source_id":"ad_100"}'::jsonb);
  assert v_lead2 = v_lead and not v_new
     and (select source from l2v.leads where id = v_lead) = 'click_to_whatsapp'
     and (select campaign from l2v.leads where id = v_lead) = 'camp_up',
    'B: ad referral upgrades organic source and campaign';

  select * into v_lead2, v_new from l2v.capture_lead(v_seed_clinic, v_pat_b, 'organic');
  assert (select source from l2v.leads where id = v_lead) = 'click_to_whatsapp',
    'B: paid source must not downgrade back to organic';

  -- (c) kpi_daily first reply from public.outbox (status = 'sent'), ignoring failed/pending/pre-inbound outbox rows
  update l2v.leads
     set first_inbound_at = now(), created_at = now()
   where id = v_lead;

  insert into public.outbox (clinic_id, contact_id, kind, payload, status, idempotency_key, sent_at, created_at)
  values
    (v_seed_clinic, v_pat_b, 'text', '{"text":"too early"}'::jsonb, 'sent', 'kpi-early-' || v_pat_b::text, now() - interval '30 seconds', now() - interval '30 seconds'),
    (v_seed_clinic, v_pat_b, 'text', '{"text":"failed"}'::jsonb,    'failed', 'kpi-fail-' || v_pat_b::text, now() + interval '2 seconds', now() + interval '2 seconds'),
    (v_seed_clinic, v_pat_b, 'text', '{"text":"pending"}'::jsonb,   'pending', 'kpi-pend-' || v_pat_b::text, null, now() + interval '3 seconds'),
    (v_seed_clinic, v_pat_b, 'text', '{"text":"bot reply"}'::jsonb, 'sent', 'kpi-ok-' || v_pat_b::text, now() + interval '12 seconds', now() + interval '12 seconds');

  select avg_first_reply_s into v_reply_s
    from l2v.kpi_daily(v_seed_clinic, (now() at time zone 'Africa/Cairo')::date - 1, (now() at time zone 'Africa/Cairo')::date + 1)
   where leads > 0
   order by day desc
   limit 1;
  assert v_reply_s between 11 and 13,
    'B: kpi_daily measures outbox sent first reply (~12s), got ' || coalesce(v_reply_s::text, 'null');

  select count(*)::int into v_kpi_cnt from l2v.kpi_daily(v_seed_clinic, null, current_date);
  assert v_kpi_cnt = 0, 'B: kpi_daily with null date returns 0 rows cleanly';
  select count(*)::int into v_kpi_cnt from l2v.kpi_daily(v_seed_clinic, current_date + 2, current_date);
  assert v_kpi_cnt = 0, 'B: kpi_daily with inverted date range returns 0 rows cleanly';

  -- (d) Converted lead + new ad re-entry (idempotent on same source_id, opens fresh lead on new source_id or distinct no-source_id referral)
  insert into public.providers (clinic_id, name) values (v_seed_clinic, 'Dr B') returning id into v_prov_id;
  insert into public.services (clinic_id, code, name_ar, name_en) values (v_seed_clinic, 'B_SVC', 'خدمة', 'Service') returning id into v_svc_id;
  insert into public.appointments (clinic_id, contact_id, provider_id, service_id, starts_at, ends_at, status, created_at)
  values (v_seed_clinic, v_pat_b, v_prov_id, v_svc_id, now() + interval '2 days', now() + interval '2 days 30 minutes', 'confirmed', now() + interval '1 minute');

  select * into v_lead2, v_new
    from l2v.capture_lead_guarded(v_seed_clinic, v_pat_b, 'click_to_whatsapp', 'camp_up', '{"source_id":"ad_100"}'::jsonb);
  assert v_lead2 = v_lead and not v_new and (select status from l2v.leads where id = v_lead) <> 'closed',
    'B: duplicate same source_id stays on existing open lead';

  select * into v_lead2, v_new
    from l2v.capture_lead_guarded(v_seed_clinic, v_pat_b, 'click_to_whatsapp', 'camp_up2', '{"source_id":"ad_200"}'::jsonb);
  assert v_lead2 <> v_lead and v_new and (select status from l2v.leads where id = v_lead) = 'closed',
    'B: distinct ad source_id after conversion closes old lead and opens new lead';

  -- Non-source_id referral: duplicate keeps same lead, distinct referral closes after booking
  insert into public.appointments (clinic_id, contact_id, provider_id, service_id, starts_at, ends_at, status, created_at)
  values (v_seed_clinic, v_pat_b, v_prov_id, v_svc_id, now() + interval '3 days', now() + interval '3 days 30 minutes', 'confirmed', now() + interval '2 minutes');
  update l2v.leads set referral = '{"headline":"ad_A"}'::jsonb where id = v_lead2;

  select * into v_lead, v_new
    from l2v.capture_lead_guarded(v_seed_clinic, v_pat_b, 'click_to_whatsapp', 'camp_up2', '{"headline":"ad_A"}'::jsonb);
  assert v_lead = v_lead2 and not v_new, 'B: identical non-source_id referral stays idempotent';

  select * into v_lead, v_new
    from l2v.capture_lead_guarded(v_seed_clinic, v_pat_b, 'click_to_whatsapp', 'camp_up3', '{"headline":"ad_B"}'::jsonb);
  assert v_lead <> v_lead2 and v_new and (select status from l2v.leads where id = v_lead2) = 'closed',
    'B: distinct non-source_id referral after conversion opens new lead';

  raise notice 'B L2V FIXES TESTS (inactive staff/rep_ack, close_lead, source upgrade, ad re-entry, kpi_daily outbox): OK';
end $$;

set role anon;
do $$ begin
  begin perform l2v.close_lead(gen_random_uuid(), gen_random_uuid()); raise exception 'anon called close_lead';
  exception when insufficient_privilege then raise notice 'anon close_lead denied'; end;
end $$;
reset role;

set role clinicos_api_owner;
do $$ begin
  perform l2v.close_lead(gen_random_uuid(), gen_random_uuid());
  raise notice 'runtime role close_lead allowed';
end $$;
reset role;
reset clinicos.seed_clinic_id;

-- 13. T10: l2v.recent_leads phone masking (all but last 3 digits), 50-row cap, NULL guards, and role permissions
do $$
declare
  v_clinic uuid;
  v_other_clinic uuid;
  v_cid uuid;
  v_i integer;
  v_rows integer;
  v_masked text;
begin
  insert into public.clinics (name, timezone) values ('T10 Dashboard Clinic', 'Africa/Cairo') returning id into v_clinic;
  insert into public.clinics (name, timezone) values ('T10 Foreign Clinic', 'Africa/Cairo') returning id into v_other_clinic;

  -- Foreign clinic lead must never appear in v_clinic results
  insert into public.contacts (clinic_id, phone_e164, name) values (v_other_clinic, '+201009876543', 'Foreign') returning id into v_cid;
  perform l2v.capture_lead(v_other_clinic, v_cid, 'organic');

  -- Short phone edge case (<=3 digits) -> '***'
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+12', 'ShortPhone') returning id into v_cid;
  perform l2v.capture_lead(v_clinic, v_cid, 'organic');
  select phone_masked into v_masked from l2v.recent_leads(v_clinic, 50) limit 1;
  assert v_masked = '***', 'T10: <=3 digit phone must mask to ***, got ' || coalesce(v_masked, 'null');

  -- Insert 55 additional leads with strictly increasing created_at to test 50-row upper cap and E.164 masking (+*********NNN)
  for v_i in 1..55 loop
    insert into public.contacts (clinic_id, phone_e164, name)
    values (v_clinic, '+20100111' || lpad(v_i::text, 4, '0'), 'Lead ' || v_i)
    returning id into v_cid;
    perform l2v.capture_lead(v_clinic, v_cid, case when v_i % 2 = 0 then 'click_to_whatsapp' else 'organic' end, 'camp', 'تبييض');
    update l2v.leads set created_at = now() + make_interval(secs => v_i) where contact_id = v_cid;
  end loop;

  select count(*)::int into v_rows from l2v.recent_leads(v_clinic, 500);
  assert v_rows = 50, 'T10: recent_leads must cap at 50 rows even when p_limit=500, got ' || v_rows;

  select count(*)::int into v_rows from l2v.recent_leads(v_clinic, null);
  assert v_rows = 50, 'T10: recent_leads(null limit) defaults to 50 rows, got ' || v_rows;

  select count(*)::int into v_rows from l2v.recent_leads(v_clinic, -5);
  assert v_rows = 1, 'T10: recent_leads(<=0 limit) clamps to 1 row, got ' || v_rows;

  select count(*)::int into v_rows from l2v.recent_leads(null, 50);
  assert v_rows = 0, 'T10: recent_leads(null clinic) returns 0 rows';

  -- Confirm zero unmasked full phone prefixes leak and last 3 digits match
  assert not exists (
    select 1 from l2v.recent_leads(v_clinic, 50) where phone_masked like '+201%'
  ), 'T10: raw +201 prefix leaked in phone_masked!';

  select phone_masked into v_masked
    from l2v.recent_leads(v_clinic, 50)
   where phone_masked like '%055'
   limit 1;
  assert v_masked = '+*********055', 'T10: expected +*********055 for +201001110055, got ' || coalesce(v_masked, 'null');

  raise notice 'T10 recent_leads (masking, 50-row cap, clinic scope, NULL boundaries): OK';
end $$;

set role anon;
do $$ begin
  begin perform 1 from l2v.recent_leads(gen_random_uuid(), 10); raise exception 'anon called recent_leads';
  exception when insufficient_privilege then raise notice 'anon recent_leads denied'; end;
end $$;
reset role;

set role clinicos_api_owner;
do $$ begin
  perform 1 from l2v.recent_leads(gen_random_uuid(), 10);
  raise notice 'runtime role recent_leads allowed';
end $$;
reset role;

-- 14. T11: working hours (open, closed, boundary minute, Africa/Cairo, null hours = old behaviour),
--          release_overnight (round-robin, SLA starting at opening time, idempotent),
--          escalate_overdue closed suppression, and kpi_daily leads_ads / leads_organic split
do $$
declare
  v_clinic       uuid;
  v_mgr          uuid;
  v_rep1_c       uuid;
  v_rep2_c       uuid;
  v_rep1_id      uuid;
  v_rep2_id      uuid;
  v_p_null       uuid;
  v_p_closed1    uuid;
  v_p_closed2    uuid;
  v_p_org        uuid;
  v_lead_null    uuid;
  v_lead_c1      uuid;
  v_lead_c2      uuid;
  v_lead_org     uuid;
  v_new          boolean;
  v_q            record;
  v_cairo_now    timestamp;
  v_cairo_dow    smallint;
  v_other_dow    smallint;
  v_open_time    time;
  v_close_time   time;
  v_expected_due timestamptz;
  v_actual_due   timestamptz;
  v_released     integer;
  v_outbox_before integer;
  v_kpi          record;
  v_cols         text[];
begin
  -- Verify l2v.kpi_daily exact column order (existing 8 unchanged + leads_ads, leads_organic appended at end)
  select array_agg(a.attname order by a.attnum)
    into v_cols
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join unnest(p.proargnames) with ordinality as u(argname, ord)
    join lateral (select u.argname as attname, u.ord as attnum) a on true
   where n.nspname = 'l2v'
     and p.proname = 'kpi_daily'
     and u.ord > 3; -- skip 3 input params (p_clinic_id, p_from, p_to)

  assert v_cols = array[
    'day', 'leads', 'hot_leads', 'avg_first_reply_s',
    'escalations', 'booked_leads', 'visits', 'no_shows',
    'leads_ads', 'leads_organic'
  ], 'T11: kpi_daily output columns order mismatch: ' || coalesce(v_cols::text, 'null');

  insert into public.clinics (name, timezone, settings)
  values (
    'T11 Cairo Hours Clinic',
    'Africa/Cairo',
    '{"whatsapp_templates":{
        "lead_handoff":{"name":"lead_handoff","language_codes":{"ar":"ar"}},
        "sla_breach":{"name":"sla_breach","language_codes":{"ar":"ar"}},
        "sla_breach_no_rep":{"name":"sla_breach_no_rep","language_codes":{"ar":"ar"}}}}'::jsonb
  ) returning id into v_clinic;

  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201055500001', 'Mgr')  returning id into v_mgr;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201055500002', 'RepA') returning id into v_rep1_c;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201055500003', 'RepB') returning id into v_rep2_c;

  insert into l2v.settings (clinic_id, sla_minutes, manager_contact_id)
  values (v_clinic, 15, v_mgr);
  insert into l2v.reps (clinic_id, contact_id, name) values (v_clinic, v_rep1_c, 'RepA') returning id into v_rep1_id;
  insert into l2v.reps (clinic_id, contact_id, name) values (v_clinic, v_rep2_c, 'RepB') returning id into v_rep2_id;

  -- (a) NULL hours = old behaviour (always open -> immediate assignment)
  assert l2v.is_clinic_open(v_clinic, '2026-11-17 01:30:00+00'::timestamptz), 'T11: null hours must be always open';
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201155500010', 'PatNull') returning id into v_p_null;
  select * into v_lead_null, v_new from l2v.capture_lead(v_clinic, v_p_null, 'click_to_whatsapp', 'camp_ad1');
  select * into v_q from l2v.set_qualification(v_lead_null, 'high', 'now');
  assert v_q.status = 'hot' and v_q.assignment_id is not null, 'T11: null hours hot lead assigned immediately';

  -- (b) Africa/Cairo timezone & exact boundary-minute checks on 09:00..17:00 Sun..Thu (0..4)
  --     2026-11-17 is Tuesday (dow=2); Cairo is UTC+2:
  --       06:59:59Z = 08:59:59 Cairo (closed)
  --       07:00:00Z = 09:00:00 Cairo (boundary minute -> OPEN)
  --       14:59:59Z = 16:59:59 Cairo (OPEN)
  --       15:00:00Z = 17:00:00 Cairo (boundary minute -> CLOSED)
  --     2026-11-20 is Friday (dow=5 -> CLOSED even at 12:00 Cairo = 10:00Z)
  update l2v.settings
     set open_time  = time '09:00:00',
         close_time = time '17:00:00',
         open_days  = array[0,1,2,3,4]::smallint[]
   where clinic_id = v_clinic;

  assert not l2v.is_clinic_open(v_clinic, '2026-11-17 06:59:59+00'::timestamptz), 'T11 Cairo: 08:59:59 must be closed';
  assert l2v.is_clinic_open(v_clinic, '2026-11-17 07:00:00+00'::timestamptz),     'T11 Cairo: 09:00:00 opening boundary minute must be open';
  assert l2v.is_clinic_open(v_clinic, '2026-11-17 14:59:59+00'::timestamptz),     'T11 Cairo: 16:59:59 must be open';
  assert not l2v.is_clinic_open(v_clinic, '2026-11-17 15:00:00+00'::timestamptz), 'T11 Cairo: 17:00:00 closing boundary minute must be closed';
  assert not l2v.is_clinic_open(v_clinic, '2026-11-20 10:00:00+00'::timestamptz), 'T11 Cairo: Friday (dow=5) must be closed';

  -- (c) Live CLOSED clinic: hot leads stay hot & unassigned; release_overnight() and escalate_overdue() do nothing while closed
  v_cairo_now := now() at time zone 'Africa/Cairo';
  v_cairo_dow := extract(dow from v_cairo_now)::smallint;
  v_other_dow := ((v_cairo_dow + 1) % 7)::smallint;

  update l2v.settings
     set open_time  = time '09:00:00',
         close_time = time '17:00:00',
         open_days  = array[v_other_dow]::smallint[] -- today excluded -> guaranteed closed right now!
   where clinic_id = v_clinic;

  assert not l2v.is_clinic_open(v_clinic), 'T11: clinic must be closed when today is not in open_days';

  -- Expire PatNull's pending assignment and verify escalate_overdue does NOT escalate or notify manager while closed
  update l2v.assignments set sla_due_at = now() - interval '10 minutes' where lead_id = v_lead_null;
  select count(*)::int into v_outbox_before from public.outbox where clinic_id = v_clinic;
  assert l2v.escalate_overdue() = 0, 'T11: escalate_overdue must not escalate while clinic is closed';
  assert (select count(*)::int from public.outbox where clinic_id = v_clinic) = v_outbox_before,
    'T11: escalate_overdue must not notify manager or next rep while clinic is closed';
  assert (select status from l2v.assignments where lead_id = v_lead_null) = 'pending',
    'T11: overdue assignment remains pending while clinic is closed';

  -- Ack PatNull's assignment so we isolate overnight leads cleanly
  update l2v.assignments set status = 'acked', acked_at = now() where lead_id = v_lead_null;

  -- Two hot leads arrive while closed (1 ad, 1 organic) + 1 warm organic lead
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201155500011', 'Overnight1') returning id into v_p_closed1;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201155500012', 'Overnight2') returning id into v_p_closed2;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201155500013', 'WarmOrg')    returning id into v_p_org;

  select * into v_lead_c1, v_new from l2v.capture_lead(v_clinic, v_p_closed1, 'click_to_whatsapp', 'night_ad');
  update l2v.leads set created_at = now() - interval '3 hours', first_inbound_at = now() - interval '3 hours' where id = v_lead_c1;
  select * into v_q from l2v.set_qualification(v_lead_c1, 'high', 'now', 'تبييض');
  assert v_q.status = 'hot' and v_q.score = 100 and v_q.assignment_id is null,
    'T11: hot lead arriving while closed must stay hot and unassigned';

  select * into v_lead_c2, v_new from l2v.capture_lead(v_clinic, v_p_closed2, 'organic');
  update l2v.leads set created_at = now() - interval '2 hours', first_inbound_at = now() - interval '2 hours' where id = v_lead_c2;
  select * into v_q from l2v.set_qualification(v_lead_c2, 'mid', 'now', 'تنظيف');
  assert v_q.status = 'hot' and v_q.score = 85 and v_q.assignment_id is null,
    'T11: second hot lead arriving while closed must stay hot and unassigned';

  select * into v_lead_org, v_new from l2v.capture_lead(v_clinic, v_p_org, 'organic');
  perform l2v.set_qualification(v_lead_org, 'low', 'now'); -- warm (65)

  assert (select count(*) from l2v.assignments where lead_id in (v_lead_c1, v_lead_c2)) = 0,
    'T11: zero assignments created while closed';
  assert l2v.release_overnight() = 0, 'T11: release_overnight must do nothing while clinic is closed';

  -- (d) Clinic opens (exact boundary minute or 2 minutes ago in Africa/Cairo):
  --     release_overnight() assigns both unassigned hot leads round-robin (RepB then RepA, since RepA took PatNull),
  --     sets sla_due_at = opening_time + 15m, and is idempotent on repeat call!
  v_open_time  := date_trunc('minute', v_cairo_now)::time;
  v_close_time := (date_trunc('minute', v_cairo_now) + interval '2 hours')::time;
  update l2v.settings
     set open_time  = v_open_time,
         close_time = v_close_time,
         open_days  = array[v_cairo_dow]::smallint[]
   where clinic_id = v_clinic;

  assert l2v.is_clinic_open(v_clinic), 'T11: clinic must be open at opening boundary minute';

  v_released := l2v.release_overnight();
  assert v_released = 2, 'T11: release_overnight must assign the 2 unassigned hot leads, got ' || v_released;

  -- Round-robin check: RepA had PatNull earlier, so Overnight1 goes to RepB and Overnight2 goes to RepA
  assert (select rep_id from l2v.assignments where lead_id = v_lead_c1) = v_rep2_id,
    'T11: first overnight lead assigned to least-recently-assigned RepB';
  assert (select rep_id from l2v.assignments where lead_id = v_lead_c2) = v_rep1_id,
    'T11: second overnight lead assigned round-robin to RepA';

  -- SLA starting at opening time check
  v_expected_due := ((v_cairo_now::date + v_open_time) at time zone 'Africa/Cairo') + interval '15 minutes';
  select sla_due_at into v_actual_due from l2v.assignments where lead_id = v_lead_c1;
  assert v_actual_due = v_expected_due,
    'T11: expected sla_due_at = opening_time + 15m (' || v_expected_due || '), got ' || v_actual_due;

  -- Idempotency check: second call to release_overnight() assigns 0 leads and enqueues 0 new messages
  select count(*)::int into v_outbox_before from public.outbox where clinic_id = v_clinic;
  assert l2v.release_overnight() = 0, 'T11: release_overnight second call must be idempotent (0)';
  assert (select count(*)::int from public.outbox where clinic_id = v_clinic) = v_outbox_before,
    'T11: release_overnight second call must enqueue 0 duplicate handoff messages';

  -- (e) kpi_daily split: leads_ads + leads_organic = leads across multi-day window
  for v_kpi in
    select * from l2v.kpi_daily(v_clinic, (v_cairo_now::date - 1), v_cairo_now::date)
  loop
    assert v_kpi.leads_ads + v_kpi.leads_organic = v_kpi.leads,
      'T11: leads_ads + leads_organic must equal leads on ' || v_kpi.day;
  end loop;

  select sum(leads)::int as leads, sum(leads_ads)::int as ads, sum(leads_organic)::int as org
    into v_kpi
    from l2v.kpi_daily(v_clinic, (v_cairo_now::date - 1), v_cairo_now::date);
  assert v_kpi.leads = 4 and v_kpi.ads = 2 and v_kpi.org = 2,
    'T11: expected 4 total leads (2 ads + 2 organic), got ' || row_to_json(v_kpi)::text;

  raise notice 'T11 working hours (open/closed/boundary/Africa-Cairo/null), release_overnight idempotent, and kpi split: OK';
end $$;

-- ============================================================================
-- 10b. T11 SLA across closing time:
--      - Assigned at 17:55 with SLA 15 and closing at 18:00 (sla_due_at = 18:10,
--        which passes while closed):
--          * At 09:00 opening tick: NOT escalated; sla_due_at moved to 09:15
--            (opening_time + sla_minutes) once, idempotently
--          * Escalated after 09:15 (09:16 tick) if not acked
--      - Acked assignment unaffected (status and sla_due_at unchanged, never escalated)
--      - Null hours = old behaviour (sla_due_at not moved; escalates when due)
-- ============================================================================
do $$
declare
  v_clinic       uuid;
  v_mgr          uuid;
  v_rep1_c       uuid;
  v_rep2_c       uuid;
  v_rep1_id      uuid;
  v_rep2_id      uuid;
  v_p_pend       uuid;
  v_p_acked      uuid;
  v_p_null       uuid;
  v_lead_pend    uuid;
  v_lead_acked   uuid;
  v_lead_null    uuid;
  v_new          boolean;
  v_q_pend       record;
  v_q_acked      record;
  v_q_null       record;
  v_due_after    timestamptz;
  v_acked_due    timestamptz;
  v_null_due     timestamptz;
  v_esc          integer;
begin
  --Ack any leftover pending assignments in other test clinics so global release_overnight/escalate_overdue only act on v_clinic
  update l2v.assignments set status = 'acked', acked_at = now() where status = 'pending';

  insert into public.clinics (name, timezone, settings)
  values (
    'T11 SLA Across Closing Clinic',
    'Africa/Cairo',
    '{"whatsapp_templates":{
        "lead_handoff":{"name":"lead_handoff","language_codes":{"ar":"ar"}},
        "sla_breach":{"name":"sla_breach","language_codes":{"ar":"ar"}},
        "sla_breach_no_rep":{"name":"sla_breach_no_rep","language_codes":{"ar":"ar"}}}}'::jsonb
  ) returning id into v_clinic;

  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201066600001', 'MgrClose')  returning id into v_mgr;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201066600002', 'RepClose1') returning id into v_rep1_c;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201066600003', 'RepClose2') returning id into v_rep2_c;

  insert into l2v.settings (clinic_id, sla_minutes, manager_contact_id, open_time, close_time, open_days)
  values (v_clinic, 15, v_mgr, time '09:00:00', time '18:00:00', array[0,1,2,3,4,5,6]::smallint[]);

  insert into l2v.reps (clinic_id, contact_id, name) values (v_clinic, v_rep1_c, 'RepClose1') returning id into v_rep1_id;
  insert into l2v.reps (clinic_id, contact_id, name) values (v_clinic, v_rep2_c, 'RepClose2') returning id into v_rep2_id;

  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201166600010', 'PatPending1755') returning id into v_p_pend;
  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201166600011', 'PatAcked1755')   returning id into v_p_acked;

  -- Security check: no l2v function may read l2v.test_now or current_setting,
  -- and public runtime functions (assign_lead, set_qualification, release_overnight, escalate_overdue)
  -- must NOT accept a p_at clock-override parameter.
  assert not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'l2v'
       and (p.prosrc ilike '%test_now%' or p.prosrc ilike '%current_setting%')
  ), 'T11 security: l2v functions must not read l2v.test_now or current_setting';

  assert not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'l2v'
       and p.proname in ('assign_lead', 'set_qualification', 'release_overnight', 'escalate_overdue')
       and 'p_at' = any(coalesce(p.proargnames, '{}'::text[]))
  ), 'H3 security: public l2v runtime functions (assign_lead, set_qualification, release_overnight, escalate_overdue) must not accept p_at';

  -- (1) Assign both leads at 17:55 Cairo time (5 minutes before 18:00 close, SLA = 15 -> sla_due_at = 18:10)
  select * into v_lead_pend, v_new from l2v.capture_lead(v_clinic, v_p_pend, 'click_to_whatsapp', 'camp_close', null, null, '2026-11-17 17:55:00+02'::timestamptz);
  select * into v_q_pend from l2v._set_qualification_at(v_lead_pend, 'high', 'now', 'زراعة', '2026-11-17 17:55:00+02'::timestamptz);
  assert v_q_pend.status = 'hot' and v_q_pend.assignment_id is not null,
    'T11 closing-SLA: lead at 17:55 (before 18:00 close) must be assigned immediately';

  select * into v_lead_acked, v_new from l2v.capture_lead(v_clinic, v_p_acked, 'organic', null, null, null, '2026-11-17 17:55:00+02'::timestamptz);
  select * into v_q_acked from l2v._set_qualification_at(v_lead_acked, 'high', 'now', 'تقويم', '2026-11-17 17:55:00+02'::timestamptz);
  assert v_q_acked.status = 'hot' and v_q_acked.assignment_id is not null,
    'T11 closing-SLA: second lead at 17:55 must be assigned immediately';

  -- Verify _set_qualification_at with p_at = 17:55 set sla_due_at = 18:10 directly
  assert (select sla_due_at from l2v.assignments where id = v_q_pend.assignment_id) = '2026-11-17 18:10:00+02'::timestamptz,
    'T11 closing-SLA: expected initial sla_due_at = 2026-11-17 18:10:00+02';

  -- Second assignment is acked before closing (17:58)
  update l2v.assignments
     set status   = 'acked',
         acked_at = '2026-11-17 17:58:00+02'::timestamptz
   where id = v_q_acked.assignment_id;

  -- (2) Next morning at 09:00 opening tick:
  --     Pending assignment's sla_due_at (18:10 yesterday, which passed while closed)
  --     must be moved to 09:15 today (opening_time + 15m) once, idempotently,
  --     and must NOT be escalated at the 09:00 tick!
  perform l2v._release_overnight_at('2026-11-18 09:00:00+02'::timestamptz);
  v_esc := l2v._escalate_overdue_at('2026-11-18 09:00:00+02'::timestamptz);
  assert v_esc = 0,
    'T11 closing-SLA: pending assignment from 17:55 (SLA 15, close 18:00) must NOT be escalated at 09:00 tick, got ' || v_esc;

  select sla_due_at into v_due_after from l2v.assignments where id = v_q_pend.assignment_id;
  assert v_due_after = '2026-11-18 09:15:00+02'::timestamptz,
    'T11 closing-SLA: expected pending sla_due_at moved to 2026-11-18 09:15:00+02 (opening_time + 15m), got ' || v_due_after;
  assert (select status from l2v.assignments where id = v_q_pend.assignment_id) = 'pending',
    'T11 closing-SLA: assignment must remain pending at 09:00 tick';

  -- Idempotency check at 09:05 tick: _release_overnight_at() must not change sla_due_at again, and _escalate_overdue_at() still 0
  perform l2v._release_overnight_at('2026-11-18 09:05:00+02'::timestamptz);
  assert (select sla_due_at from l2v.assignments where id = v_q_pend.assignment_id) = '2026-11-18 09:15:00+02'::timestamptz,
    'T11 closing-SLA: moving sla_due_at to opening_time + sla_minutes must be idempotent';
  assert l2v._escalate_overdue_at('2026-11-18 09:05:00+02'::timestamptz) = 0,
    'T11 closing-SLA: pending assignment must not be escalated before 09:15 (at 09:05 tick)';

  -- Acked assignment check: completely unaffected (status = acked, sla_due_at unchanged at yesterday 18:10)
  select sla_due_at into v_acked_due from l2v.assignments where id = v_q_acked.assignment_id;
  assert (select status from l2v.assignments where id = v_q_acked.assignment_id) = 'acked',
    'T11 closing-SLA: acked assignment status must remain acked';
  assert v_acked_due = '2026-11-17 18:10:00+02'::timestamptz,
    'T11 closing-SLA: acked assignment sla_due_at must be unaffected, got ' || v_acked_due;

  -- (3) After 09:15 (09:16 tick): if still not acked, it MUST be escalated now!
  perform l2v._release_overnight_at('2026-11-18 09:16:00+02'::timestamptz);
  v_esc := l2v._escalate_overdue_at('2026-11-18 09:16:00+02'::timestamptz);
  assert v_esc = 1,
    'T11 closing-SLA: unacked assignment must be escalated after 09:15 (at 09:16 tick), got ' || v_esc;
  assert (select status from l2v.assignments where id = v_q_pend.assignment_id) = 'escalated',
    'T11 closing-SLA: first assignment must be marked escalated after 09:15';
  assert (select count(*) from l2v.assignments where lead_id = v_lead_pend and status = 'pending' and rep_id = v_rep2_id) = 1,
    'T11 closing-SLA: lead must be reassigned to second rep after 09:15 escalation';
  assert (select status from l2v.assignments where id = v_q_acked.assignment_id) = 'acked',
    'T11 closing-SLA: acked assignment must still remain acked after 09:15 tick';

  -- Clean up the reassigned pending row before testing null hours
  update l2v.assignments set status = 'acked', acked_at = '2026-11-18 09:17:00+02'::timestamptz where lead_id = v_lead_pend and status = 'pending';

  -- (4) Null hours = old behaviour (sla_due_at is NOT moved; escalates immediately when due)
  update l2v.settings
     set open_time  = null,
         close_time = null,
         open_days  = null
   where clinic_id = v_clinic;

  insert into public.contacts (clinic_id, phone_e164, name) values (v_clinic, '+201166600012', 'PatNullHours') returning id into v_p_null;
  select * into v_lead_null, v_new from l2v.capture_lead(v_clinic, v_p_null, 'organic', null, null, null, '2026-11-18 17:55:00+02'::timestamptz);
  select * into v_q_null from l2v._set_qualification_at(v_lead_null, 'high', 'now', 'حشو', '2026-11-18 17:55:00+02'::timestamptz);

  perform l2v._release_overnight_at('2026-11-19 09:00:00+02'::timestamptz);
  select sla_due_at into v_null_due from l2v.assignments where id = v_q_null.assignment_id;
  assert v_null_due = '2026-11-18 18:10:00+02'::timestamptz,
    'T11 closing-SLA: null hours must preserve old behaviour (sla_due_at not moved)';
  v_esc := l2v._escalate_overdue_at('2026-11-19 09:00:00+02'::timestamptz);
  assert v_esc = 1,
    'T11 closing-SLA: null hours overdue assignment must escalate immediately (old behaviour), got ' || v_esc;

  raise notice 'T11 SLA across closing time (17:55 -> 09:00 not escalated -> 09:15+ escalated, acked unaffected, null hours old behaviour): OK';
end $$;

set role anon;
do $$ begin
  begin perform l2v.release_overnight(); raise exception 'anon called release_overnight';
  exception when insufficient_privilege then raise notice 'anon release_overnight denied'; end;
  begin perform l2v.escalate_overdue(); raise exception 'anon called escalate_overdue';
  exception when insufficient_privilege then null; end;
  begin perform l2v.is_clinic_open(gen_random_uuid()); raise exception 'anon called is_clinic_open';
  exception when insufficient_privilege then null; end;
  begin perform l2v._assign_lead_at(gen_random_uuid()); raise exception 'anon called _assign_lead_at';
  exception when insufficient_privilege then null; end;
  begin perform l2v._set_qualification_at(gen_random_uuid(), 'high', 'now'); raise exception 'anon called _set_qualification_at';
  exception when insufficient_privilege then null; end;
  begin perform l2v._release_overnight_at(); raise exception 'anon called _release_overnight_at';
  exception when insufficient_privilege then null; end;
  begin perform l2v._escalate_overdue_at(); raise exception 'anon called _escalate_overdue_at';
  exception when insufficient_privilege then raise notice 'anon all internal _*_at functions denied'; end;
end $$;
reset role;

set role clinicos_api_owner;
do $$ begin
  perform l2v.release_overnight();
  perform l2v.escalate_overdue();
  perform l2v.is_clinic_open(gen_random_uuid());
  begin perform l2v._assign_lead_at(gen_random_uuid()); raise exception 'runtime role called _assign_lead_at';
  exception when insufficient_privilege then null; end;
  begin perform l2v._set_qualification_at(gen_random_uuid(), 'high', 'now'); raise exception 'runtime role called _set_qualification_at';
  exception when insufficient_privilege then null; end;
  begin perform l2v._release_overnight_at(); raise exception 'runtime role called _release_overnight_at';
  exception when insufficient_privilege then null; end;
  begin perform l2v._escalate_overdue_at(); raise exception 'runtime role called _escalate_overdue_at';
  exception when insufficient_privilege then raise notice 'runtime role denied on internal _*_at functions'; end;
  raise notice 'runtime role release_overnight & is_clinic_open allowed, internal _*_at helpers denied: OK';
end $$;
reset role;


