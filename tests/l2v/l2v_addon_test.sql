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

  raise notice 'ALL ADD-ON TESTS PASSED';
end $$;

-- permissions
set role anon;
do $$ begin
  begin perform 1 from l2v.leads limit 1; raise exception 'anon read leads';
  exception when insufficient_privilege then raise notice 'anon table denied'; end;
  begin perform l2v.escalate_overdue(); raise exception 'anon executed function';
  exception when insufficient_privilege then raise notice 'anon function denied'; end;
end $$;
reset role;
set role clinicos_api_owner;
do $$ begin
  perform l2v.is_staff(gen_random_uuid(), '+20');
  begin perform 1 from l2v.leads limit 1; raise exception 'runtime role read table directly';
  exception when insufficient_privilege then raise notice 'runtime role: functions yes, tables no'; end;
end $$;
reset role;
