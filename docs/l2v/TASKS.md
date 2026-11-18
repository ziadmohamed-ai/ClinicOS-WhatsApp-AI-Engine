# Lead-to-Visit add-on — task list

Goal: turn ClinicOS into "no paid lead gets lost": capture the lead from the ad, score it, hand hot leads to a
receptionist with a WhatsApp button, escalate if nobody acts in 15 minutes, and report the numbers.
Already built and tested: `database/05_lead_engine.sql` (schema `l2v`, 8 functions) and `tests/l2v/l2v_addon_test.sql`.
Do the tasks **in order**. Open one PR per task and wait for review before starting the next one.

## Design in one page
```
WhatsApp webhook -> Verify & Save Event -> Is Voice Note? -> Parse Turn & State
   -> [NEW] L2V Prepare (Code) -> L2V Gate (Postgres) -> L2V Merge (Code) -> Is Staff? (IF)
        staff    -> end (l2v.rep_ack already ran inside the gate)
        not staff-> Route Turn (unchanged) -> ... -> AI Receptionist -> Parse AI Output -> Emergency Reply Guard
                                                                                      |-> Search Slots? (unchanged)
                                                                                      '-> [NEW side branch] L2V Qualify? (IF) -> L2V Qualify (Postgres, dead end)
Schedule (1 min) -> Claim Outbox            (existing timer: 15 min -> 1 min)
NEW workflow "ClinicOS L2V SLA Tick": Schedule (1 min) -> SELECT l2v.escalate_overdue()
```
Facts found in the existing code that the tasks rely on:
- `ingest_meta_webhook_batch` returns each message's raw Meta payload in `payload`; the ad referral is `payload.referral` (`source_id`, `headline`, `ctwa_clid`, ...).
- `Claim Outbox` already runs after every patient reply and also enqueues reminders/follow-ups; it is idempotent, so a 1-minute timer is safe.
- `Parse AI Output` returns only the fields it lists, so new AI fields are dropped unless added explicitly.
- The runtime role cannot `SELECT` from `l2v.*` tables; everything goes through the `l2v` functions.
- A rep's button tap arrives as plain text (the button title), so reps are recognised by phone with `l2v.is_staff`, and `l2v.rep_ack` acks the oldest pending assignment.

## T1 — Fix or explain the two failing tests
`node tests/test_270_messages.js` fails #10 and #11 (Live Replay turns 10 and 11). Find the root cause (suspected: fixed dates in the
test fixtures vs. "today"). Fix the test fixture or the code, whichever is actually wrong. Do not loosen the assertions.
Acceptance: 283/283 (or the new total), root cause written in the PR description.

## T2 — SQL: qualify by contact, guarded capture
In `database/05_lead_engine.sql` (+ tests in `tests/l2v/l2v_addon_test.sql`):
- `l2v.qualify_contact(p_clinic_id uuid, p_contact_id uuid, p_budget_band text, p_timing text, p_treatment text default null)`:
  finds the contact's open lead and calls `l2v.set_qualification`; returns no row (does not raise) if there is no open lead.
- `l2v.capture_lead_guarded(p_clinic_id, p_contact_id, p_source, p_campaign, p_referral jsonb, p_received_at)`:
  creates/returns the open lead **only if** the message has a referral **or** the contact has no confirmed/completed appointment;
  returns no row for staff contacts (instead of raising).
- Grants identical to the other functions. Tests: happy path, no open lead, staff, existing patient without referral, existing patient with referral.
Acceptance: `./tests/l2v/run_local.sh` prints OK and the new tests are in the output.

## T3 — JS: gate parameters (pure function + tests)
Create `nodes/l2v_prepare.js` (an n8n Code node, "run once for each item") that reads the Parse Turn item and outputs the parameters for the gate query:
clinic id, `'+' + digits(phone)`, contact id, `source` (`click_to_whatsapp` if `payload.referral` else `organic`), `campaign`
(`referral.headline ?? referral.source_id ?? null`), `referral` JSON or null, message timestamp.
Add tests (in `tests/test_270_messages.js`, category "Lead-to-Visit"): with/without referral, phone with and without `+`, missing fields.

## T4 — Parse AI Output passes the lead signals
`lead_timing` must be one of `now|this_month|later`, `lead_budget_band` one of `high|mid|low`; anything else becomes `null`.
Return them from `Parse AI Output` (`nodes/parse_ai_output.js`) as `lead_timing` and `lead_budget_band`. The prompt already asks for them.
Tests: valid values pass through, invalid become null, absent become null. The wording-policy tests must still pass.

## T5 — Workflow JSON with the add-on nodes
Produce `workflow/clinicos-main-engine.l2v.json` from `workflow/clinicos-main-engine.json` by adding **only**:
`L2V Prepare`, `L2V Gate`, `L2V Merge`, `Is Staff?`, `L2V Qualify?`, `L2V Qualify`, and changing `Reminder & Outbox Timer` to 1 minute.
- `L2V Gate` query (Postgres, `executeQuery`):
```sql
WITH s AS (SELECT l2v.is_staff($1::uuid, $2::text) AS is_staff)
SELECT s.is_staff,
  CASE WHEN s.is_staff
    THEN (SELECT to_jsonb(a) FROM l2v.rep_ack($1::uuid, $2::text) a)
    ELSE (SELECT to_jsonb(c) FROM l2v.capture_lead_guarded($1::uuid, $3::uuid, $4::text, $5::text, $6::jsonb, $7::timestamptz) c)
  END AS l2v
FROM s;
```
- `L2V Merge` returns `{ ...$('Parse Turn & State').item.json, l2v_is_staff: $json.is_staff === true }`.
- `Is Staff?`: true -> nothing connected; false -> `Route Turn`. `Parse Turn & State` now connects to `L2V Prepare`, not directly to `Route Turn`.
- `L2V Qualify?` is a **side branch from `Emergency Reply Guard`** (it must not change what `Search Slots?` receives). Condition: `lead_timing` or `lead_budget_band` is set.
  `L2V Qualify` runs `SELECT * FROM l2v.qualify_contact($1::uuid, $2::uuid, $3, $4, $5);` and has no outgoing connection.
- **Fail-open (important):** the add-on must never stop a patient's message from being answered. Set `onError: "continueRegularOutput"` on `L2V Gate` and
  `L2V Qualify`, and make `L2V Merge` treat a missing or failed gate result as `l2v_is_staff = false`. A broken add-on must degrade to plain ClinicOS behaviour.
- Write `tests/validate_workflow.js` and run it on both workflow files: every connection target exists, no orphan nodes, node names unique,
  all pre-existing connections preserved except `Parse Turn & State -> Route Turn`, credentials are placeholders. Wire it into the README's test instructions.

## T6 — SLA tick workflow
`workflow/clinicos-l2v-sla-tick.json`, name **`ClinicOS L2V SLA Tick`**: `Schedule Trigger (1 min)` -> Postgres `SELECT l2v.escalate_overdue() AS escalated;`.
Copy `Error Trigger` -> `Log Workflow Error` from the main workflow (same query, same placeholder credential). Run `tests/validate_workflow.js` on it too.

## T7 — Seed example and Meta templates
- `database/05b_l2v_seed_example.sql`: example manager + two reps (fake numbers `+20100000000x`), `l2v.settings` (15-minute SLA) and the `whatsapp_templates` keys
  `lead_handoff`, `sla_breach`, `sla_breach_no_rep` for `clinics.settings`. Idempotent; clearly marked "example, edit before use".
- `docs/l2v/TEMPLATES.md`: the three template texts in Arabic for submission to Meta (category UTILITY, `lead_handoff` with a quick-reply button), with
  the variable order **exactly as `l2v._notify` / `private.build_whatsapp_message` send them** (read the SQL; do not invent a different order).

## T8 — README
Correct the test claim (use the real number from T1), add a "Lead-to-Visit add-on" section: what it does, install order (01–05, workflow import, templates),
and the acceptance checklist below. No marketing claims without a measurement.

## T9 — Remove the hard-coded clinic from the database layer (needed before a second clinic)
Today the runtime is tied to one clinic id (`<legacy-hardcoded-clinic-uuid>`):
- `database/03_rls_policies.sql`: all 12 policies for role `clinicos_api_owner` filter on that literal UUID.
- `database/02_booking_and_outbox_rpcs.sql` (~line 2397): `log_workflow_error` falls back to that UUID.
- `database/04_seed_data.sql`: the demo clinic uses it (fine for a demo, but must be clearly marked as demo data).
**Decision needed before coding. Write both options with trade-offs in the PR description and stop; if the reviewer says nothing, implement Option 1.**
- *Option 1 (default): one Supabase project + one n8n credential per clinic.* The clinic id is generated at install time: turn the policies into a
  template (`database/03_rls_policies.sql.tpl`) and add `scripts/new_clinic.sh <clinic-name>` that creates the clinic row, renders the policies with its id and prints next steps.
  Strongest isolation, simplest to reason about, matches how the code already assumes a single clinic.
- *Option 2: one shared instance for many clinics.* Policies filter on a transaction-scoped setting (`current_setting('clinicos.clinic_id', true)`) that the workflow must set in the
  same transaction as every query. n8n's Postgres node makes that easy to get wrong, so this option needs a design for how it is enforced and tested.
Acceptance (either option): no clinic UUID literal remains outside seed/demo files (`grep -rn <legacy-uuid> database workflow nodes` shows only seed data),
`log_workflow_error` no longer guesses a clinic, and a SQL test proves that a second clinic's rows are invisible to the first clinic's runtime role.

## T10 — Make the dashboard show real numbers (or say clearly that it is a demo)
`dashboard/index.html` is a static mock: the numbers and the "live pipeline" log are hard-coded. Clients are shown it as if it were live, which is a trust risk.
- New n8n workflow `workflow/clinicos-dashboard-api.json`, name **`ClinicOS Dashboard API`**: Webhook `GET /dashboard-kpis?from=YYYY-MM-DD&to=YYYY-MM-DD`,
  header `x-dashboard-token` checked against a value stored in n8n credentials (reject with 401 otherwise), then Postgres `SELECT * FROM l2v.kpi_daily($1::uuid, $2::date, $3::date)`.
  Return counts only, **no names or phone numbers**.
- The dashboard fetches that endpoint. The URL and token are configuration (a small `dashboard/config.example.js`), never committed with real values.
- If the endpoint is not configured or unreachable, the page must show a visible **"DEMO DATA"** banner and keep the sample numbers; with a working endpoint it shows real numbers and no banner.
- Remove or relabel the fake "live pipeline" log lines that claim a connection to a workflow id.
Acceptance: opened without config -> "DEMO DATA" banner; with a local stub server returning JSON -> real numbers and no banner; no secrets in the repo.
Needs T5-T7 done first (the KPI function must be reachable and seeded).

## Acceptance checklist for the whole add-on (manual, in staging, by a human)
1. Ad message -> a row in `l2v.leads` with source and campaign.
2. Patient says "I want to start this week" and the price is fine -> lead becomes `hot` and the rep gets the handoff template with the button.
3. Rep taps the button -> assignment `acked`, the AI does **not** answer the rep.
4. Nobody taps for 15 minutes -> the next rep gets it and the manager gets `sla_breach`.
5. Patient books before the SLA ends -> the assignment becomes `closed_booked`, no escalation.
6. `l2v.kpi_daily` returns plausible numbers.

## Phase 2 (do not start without approval)
Weekly KPI message to the clinic owner on WhatsApp (`l2v.kpi_daily` -> `public.enqueue_message`, scheduled workflow, template needs Meta approval).
Win-back messages to cold leads (these are marketing-category WhatsApp messages, so price them first).
