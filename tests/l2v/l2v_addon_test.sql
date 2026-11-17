-- Tests for database/05_lead_engine.sql against the REAL ClinicOS schema.
-- Run with tests/l2v/run_local.sh (scratch Postgres cluster, never production).
-- Manual run: psql -v ON_ERROR_STOP=1 -v repo=/path/to/checkout -v fns=/path/to/real_fns.sql -f tests/l2v/l2v_addon_test.sql
\set ON_ERROR_STOP on

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon')               then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated')      then create role authenticated nologin; end if;
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
    '5b201616-fdf0-4a37-8863-bd050ea90376',
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

-- First run of 05b_l2v_seed_example.sql
\i :repo/database/05b_l2v_seed_example.sql

create temp table _t7_snapshot as
select
  (select count(*)::int from public.contacts where clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376') as clinic_contacts_cnt,
  (select count(*)::int from public.contacts) as total_contacts_cnt,
  (select count(*)::int from l2v.settings where clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376') as clinic_settings_cnt,
  (select count(*)::int from l2v.settings) as total_settings_cnt,
  (select count(*)::int from l2v.reps where clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376') as clinic_reps_cnt,
  (select count(*)::int from l2v.reps) as total_reps_cnt,
  (select settings from public.clinics where id = '5b201616-fdf0-4a37-8863-bd050ea90376') as clinic_settings_json,
  (select jsonb_agg(to_jsonb(c) order by c.phone_e164)
     from public.contacts c
    where c.clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376') as contacts_rows,
  (select to_jsonb(s)
     from l2v.settings s
    where s.clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376') as l2v_settings_row;

do $$
declare
  v_seed_clinic uuid := '5b201616-fdf0-4a37-8863-bd050ea90376';
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
 where r.clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376';

-- Second run of 05b_l2v_seed_example.sql (must be a complete no-op)
\i :repo/database/05b_l2v_seed_example.sql

do $$
declare
  v_seed_clinic uuid := '5b201616-fdf0-4a37-8863-bd050ea90376';
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
  v_seed_clinic uuid := '5b201616-fdf0-4a37-8863-bd050ea90376';
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
  v_seed_clinic uuid := '5b201616-fdf0-4a37-8863-bd050ea90376';
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

-- 12. Audit fixes verification (inactive staff, outbox KPI, source upgrade, close_lead,
--     new ad click after conversion, working_hours seed, 7-arg get_available_slots,
--     patient_profile CRUD, and batch apply_voice_transcription)
\i :repo/database/04_seed_data.sql

do $$
declare
  v_cnt_wh integer;
begin
  select count(*)::int into v_cnt_wh
    from public.working_hours
   where clinic_id = '5b201616-fdf0-4a37-8863-bd050ea90376';
  assert v_cnt_wh >= 12, '04_seed_data must seed working_hours (>=12), got ' || v_cnt_wh;
end $$;

\i :repo/database/04_seed_data.sql

do $$
declare
  v_seed_clinic uuid := '5b201616-fdf0-4a37-8863-bd050ea90376';
  v_svc_id      uuid := '4305027d-539f-4d21-b2bb-4be7d2c73816';
  v_prov_id     uuid := 'a2634639-04fd-4485-bb52-b00ac206976c';
  v_patient_id  uuid;
  v_other_pat   uuid;
  v_appt_id     uuid;
  v_slot_ts     timestamptz;
  v_slot_end    timestamptz;
  v_slots_cnt   integer;
  v_lead        uuid;
  v_lead2       uuid;
  v_new         boolean;
  v_ack         record;
  v_prof        jsonb;
  v_res         jsonb;
  v_msg1        uuid := gen_random_uuid();
  v_msg2        uuid := gen_random_uuid();
  v_conv_id     uuid;
  v_reply_s     integer;
begin
  -- (a) 04_seed_data idempotent for working_hours (still 12 rows, no duplicates)
  assert (select count(*) from public.working_hours where clinic_id = v_seed_clinic) = 12,
    '04_seed_data second run must not duplicate working_hours';

  -- (b) Deactivated rep (+201000000002 was set is_active = false in T7 above):
  --     is_staff must be false, capture_lead_guarded allows patient capture, rep_ack refuses ack
  assert not l2v.is_staff(v_seed_clinic, '+201000000002'),
    'Deactivated rep must not be treated as staff by l2v.is_staff';
  assert l2v.is_staff(v_seed_clinic, '+201000000003'),
    'Active rep must remain staff';
  select * into v_ack from l2v.rep_ack(v_seed_clinic, '+201000000002');
  assert not v_ack.acked and v_ack.reason = 'none',
    'Deactivated rep cannot ack pending leads';
  select * into v_lead, v_new
    from l2v.capture_lead_guarded(v_seed_clinic, (select id from public.contacts where clinic_id = v_seed_clinic and phone_e164 = '+201000000002'), 'organic');
  assert v_lead is not null and v_new,
    'Deactivated rep messaging as patient can be captured as lead';
  assert l2v.close_lead(v_seed_clinic, v_lead),
    'l2v.close_lead closes an open lead cleanly';
  assert not l2v.close_lead(v_seed_clinic, v_lead),
    'l2v.close_lead is idempotent (false when already closed)';
  assert not l2v.close_lead(gen_random_uuid(), v_lead),
    'l2v.close_lead enforces clinic isolation';

  -- (c) Patient profile CRUD + boundary validation + appointment exclusion in 7-arg get_available_slots
  insert into public.contacts (clinic_id, phone_e164, name)
  values (v_seed_clinic, '+201112223334', 'Hossam')
  returning id into v_patient_id;
  insert into public.contacts (clinic_id, phone_e164, name)
  values (v_seed_clinic, '+201112223335', 'Mona')
  returning id into v_other_pat;

  v_prof := public.get_patient_profile(v_seed_clinic, v_patient_id);
  assert v_prof ->> 'preferred_name' = 'Hossam'
     and (v_prof ->> 'is_returning_patient')::boolean = false
     and (v_prof ->> 'total_visits_count')::int = 0,
    'Initial patient profile shape';
  assert public.get_patient_profile(gen_random_uuid(), v_patient_id) = '{}'::jsonb,
    'Foreign clinic get_patient_profile returns empty object';

  assert (public.update_patient_profile(v_seed_clinic, v_patient_id, null) ->> 'ok')::boolean = false,
    'update_patient_profile rejects null patch';
  assert (public.update_patient_profile(v_seed_clinic, v_patient_id, '[]'::jsonb) ->> 'ok')::boolean = false,
    'update_patient_profile rejects non-object patch';
  assert (public.update_patient_profile(v_seed_clinic, v_patient_id,
    jsonb_build_object('notes', repeat('x', 9000))) ->> 'ok')::boolean = false,
    'update_patient_profile rejects oversized patch (>8KB)';

  v_res := public.update_patient_profile(
    v_seed_clinic,
    v_patient_id,
    jsonb_build_object(
      'preferred_dialect', 'ar-SA',
      'registered_name', 'حسام علي',
      'booking_phone', '+201112223334',
      'is_returning_patient', true,
      'injected_admin_flag', 'hacked',
      'last_service_id', 'not-a-uuid'
    )
  );
  assert (v_res ->> 'ok')::boolean = true, 'update_patient_profile accepts valid fields';
  v_prof := public.get_patient_profile(v_seed_clinic, v_patient_id);
  assert v_prof ->> 'preferred_dialect' = 'ar-SA'
     and v_prof ->> 'registered_name' = 'حسام علي'
     and v_prof ->> 'booking_phone' = '+201112223334'
     and (v_prof ->> 'is_returning_patient')::boolean = false
     and not (v_prof ? 'injected_admin_flag')
     and (v_prof ->> 'last_service_id') is null,
    'update_patient_profile strips disallowed keys and invalid UUIDs';

  -- Pick a real open slot using 7-arg get_available_slots, book it, confirm excluded unless passed as p_exclude_appointment_id
  select starts_at, ends_at into v_slot_ts, v_slot_end
    from public.get_available_slots(v_seed_clinic, v_svc_id, now() + interval '2 hours', now() + interval '8 days', v_prov_id, 1, null)
   limit 1;
  assert v_slot_ts is not null, 'Seeded clinic with working_hours yields open slots';

  insert into public.appointments (clinic_id, contact_id, provider_id, service_id, starts_at, ends_at, status)
  values (v_seed_clinic, v_patient_id, v_prov_id, v_svc_id, v_slot_ts, v_slot_end, 'confirmed')
  returning id into v_appt_id;

  select count(*)::int into v_slots_cnt
    from public.get_available_slots(v_seed_clinic, v_svc_id, v_slot_ts, v_slot_ts, v_prov_id, 5, null);
  assert v_slots_cnt = 0, 'Booked slot excluded when p_exclude_appointment_id is null';

  select count(*)::int into v_slots_cnt
    from public.get_available_slots(v_seed_clinic, v_svc_id, v_slot_ts, v_slot_ts, v_prov_id, 5, v_appt_id);
  assert v_slots_cnt = 1, 'Booked slot included when excluded via p_exclude_appointment_id during reschedule';

  -- Patient now has confirmed appointment -> is_returning_patient becomes true and recent_appointments populated
  v_prof := public.get_patient_profile(v_seed_clinic, v_patient_id);
  assert (v_prof ->> 'is_returning_patient')::boolean = true
     and jsonb_array_length(v_prof -> 'recent_appointments') = 1,
    'Confirmed appointment flips is_returning_patient and populates recent_appointments';

  -- (d) capture_lead source upgrade ('organic' -> 'click_to_whatsapp') & new ad after conversion
  select * into v_lead, v_new
    from l2v.capture_lead_guarded(v_seed_clinic, v_other_pat, 'organic');
  assert v_new and (select source from l2v.leads where id = v_lead) = 'organic',
    'Organic capture creates organic lead';

  insert into public.outbox (clinic_id, contact_id, kind, payload, status, idempotency_key, sent_at, created_at)
  values (
    v_seed_clinic,
    v_other_pat,
    'text',
    '{"text":"أهلاً بحضرتك"}'::jsonb,
    'sent',
    'audit-outbox-' || v_other_pat::text,
    now() + interval '12 seconds',
    now() + interval '12 seconds'
  );
  update l2v.leads set first_inbound_at = now(), created_at = now() where id = v_lead;
  select avg_first_reply_s into v_reply_s
    from l2v.kpi_daily(v_seed_clinic, (now() at time zone 'Asia/Riyadh')::date, (now() at time zone 'Asia/Riyadh')::date);
  assert v_reply_s between 11 and 13,
    'kpi_daily computes avg_first_reply_s from public.outbox sent rows (~12s), got ' || coalesce(v_reply_s::text, 'null');

  select * into v_lead2, v_new
    from l2v.capture_lead_guarded(v_seed_clinic, v_other_pat, 'click_to_whatsapp', 'ad_camp_1', '{"source_id":"ad_100"}'::jsonb);
  assert v_lead2 = v_lead and not v_new
     and (select source from l2v.leads where id = v_lead) = 'click_to_whatsapp'
     and (select campaign from l2v.leads where id = v_lead) = 'ad_camp_1',
    'Ad click upgrades open organic lead source & campaign';

  insert into public.appointments (clinic_id, contact_id, provider_id, service_id, starts_at, ends_at, status, created_at)
  values (v_seed_clinic, v_other_pat, v_prov_id, v_svc_id, v_slot_ts + interval '2 days', v_slot_end + interval '2 days', 'confirmed', now() + interval '1 minute');

  -- Same source_id duplicate delivery stays on same lead
  select * into v_lead2, v_new
    from l2v.capture_lead_guarded(v_seed_clinic, v_other_pat, 'click_to_whatsapp', 'ad_camp_1', '{"source_id":"ad_100"}'::jsonb);
  assert v_lead2 = v_lead and not v_new,
    'Duplicate same-ad delivery stays idempotent on existing lead';

  -- Distinct new ad source_id after prior lead converted closes old lead & creates new lead
  select * into v_lead2, v_new
    from l2v.capture_lead_guarded(v_seed_clinic, v_other_pat, 'click_to_whatsapp', 'ad_camp_2', '{"source_id":"ad_200"}'::jsonb);
  assert v_lead2 <> v_lead and v_new
     and (select status from l2v.leads where id = v_lead) = 'closed',
    'New ad after conversion closes prior lead and opens a fresh lead';

  -- (e) apply_voice_transcription updates non-zero batch index accurately
  insert into public.conversations (clinic_id, contact_id) values (v_seed_clinic, v_other_pat) returning id into v_conv_id;
  insert into public.messages (id, clinic_id, conversation_id, direction, provider_message_id, message_type, body)
  values
    (v_msg1, v_seed_clinic, v_conv_id, 'in', 'wamid.text.1', 'text', 'مرحبا'),
    (v_msg2, v_seed_clinic, v_conv_id, 'in', 'wamid.voice.2', 'audio', null);

  v_res := public.apply_voice_transcription(
    jsonb_build_object(
      'ok', true,
      'messages', jsonb_build_array(
        jsonb_build_object('clinic_id', v_seed_clinic, 'message_id', v_msg1, 'message_type', 'text', 'body', 'مرحبا'),
        jsonb_build_object('clinic_id', v_seed_clinic, 'message_id', v_msg2, 'message_type', 'audio', 'body', null, 'payload', '{"audio":{"id":"media_99"}}'::jsonb)
      )
    ),
    'عايز احجز تنظيف اسنان',
    v_msg2
  );
  assert (v_res #>> '{messages,0,body}') = 'مرحبا'
     and (v_res #>> '{messages,1,body}') = 'عايز احجز تنظيف اسنان'
     and (select body from public.messages where id = v_msg2) = 'عايز احجز تنظيف اسنان',
    'apply_voice_transcription transcribes target batch element [1] without corrupting [0]';

  raise notice 'AUDIT FIXES TESTS (inactive staff, outbox KPI, source upgrade, close_lead, seed hours, slots exclusion, profile RPCs, voice batch): OK';
end $$;

set role anon;
do $$ begin
  begin perform l2v.close_lead(gen_random_uuid(), gen_random_uuid()); raise exception 'anon called close_lead';
  exception when insufficient_privilege then raise notice 'anon close_lead denied'; end;
end $$;
reset role;


