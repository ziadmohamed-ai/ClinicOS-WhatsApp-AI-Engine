-- Tests for database/05_lead_engine.sql against the REAL ClinicOS schema.
-- Run with tests/l2v/run_local.sh (scratch Postgres cluster, never production).
-- Manual run: psql -v ON_ERROR_STOP=1 -v repo=/path/to/checkout -v fns=/path/to/real_fns.sql -f tests/l2v/l2v_addon_test.sql
\set ON_ERROR_STOP on

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon')               then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated')      then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'clinicos_api_owner') then create role clinicos_api_owner nologin; end if;
end $$;

create schema private;
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

