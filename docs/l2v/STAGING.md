# ClinicOS Lead-to-Visit (`l2v`) — Human Staging Runbook

This runbook walks a human operator step by step through provisioning an isolated **Staging** environment (one dedicated staging Supabase project, staging n8n workflows, and a Meta WhatsApp test number) and running end-to-end verification before touching any real clinic.

> **Hard safety rule:** Never point staging workflows at a production database or production WhatsApp phone number. Create separate staging credentials in n8n for every credential slot.

---

## 1. Provision the Supabase Staging Project via `scripts/new_clinic.sh`

1. Create a fresh **Supabase** project dedicated to staging and copy its direct PostgreSQL connection string (`DATABASE_URL` as superuser/`postgres` for schema migration, plus create a dedicated login role `clinicos_n8n_runtime` granted `clinicos_api_owner` for n8n runtime access):
   ```sql
   DO $$ BEGIN
     IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'clinicos_api_owner') THEN
       CREATE ROLE clinicos_api_owner NOLOGIN;
     END IF;
     IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'clinicos_n8n_runtime') THEN
       CREATE ROLE clinicos_n8n_runtime LOGIN PASSWORD 'REPLACE_WITH_STRONG_STAGING_PASSWORD';
     END IF;
   END $$;
   GRANT clinicos_api_owner TO clinicos_n8n_runtime;
   ```
2. Store the Meta staging app secret and webhook verify token in **Supabase Vault** (`vault.decrypted_secrets`, read by `private.get_clinicos_meta_secret` in `database/02_booking_and_outbox_rpcs.sql`):
   ```sql
   SELECT vault.create_secret('REPLACE_WITH_META_TEST_APP_SECRET', 'clinicos_meta_app_secret');
   SELECT vault.create_secret('REPLACE_WITH_META_VERIFY_TOKEN', 'clinicos_meta_verify_token');
   ```
3. From the repository root, generate the staging clinic seed SQL and `CLINIC_ID` using `scripts/new_clinic.sh` (defaults: `Africa/Cairo`, `+02:00`):
   ```bash
   ./scripts/new_clinic.sh \
     --name "ClinicOS L2V Staging" \
     --phone-number-id "<META_TEST_PHONE_NUMBER_ID>" \
     --timezone "Africa/Cairo" \
     --utc-offset "+02:00" \
     --out ./staging_clinic_seed.sql
   ```
   Record the printed `CLINIC_ID=<uuid>` and keep the printed Meta template texts handy for Section 3.
4. Run the SQL files in **strict install order** against the **STAGING** `DATABASE_URL` (`ON_ERROR_STOP=1`):
   ```bash
   psql "$STAGING_ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -f database/01_schema.sql
   psql "$STAGING_ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -f database/02_booking_and_outbox_rpcs.sql
   psql "$STAGING_ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -f database/02a_live_sync_profile_and_slots.sql
   psql "$STAGING_ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -v clinic_id="$CLINIC_ID" -f database/03_rls_policies.sql
   psql "$STAGING_ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -f ./staging_clinic_seed.sql
   psql "$STAGING_ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -f database/05_lead_engine.sql
   ```
5. Seed staging reception staff and `l2v.settings` (either run `database/05b_l2v_seed_example.sql` and update the phone numbers to your allowed staging phones from Section 3, or insert your staging manager and rep contacts directly into `public.contacts`, `l2v.settings`, and `l2v.reps`).
   - Optional working-hours test setup in `l2v.settings`: leave `open_time`, `close_time`, and `open_days` as `NULL` for 24/7 immediate handoff, or set e.g. `open_time = '09:00'`, `close_time = '17:00'`, `open_days = '{0,1,2,3,4,6}'` to test overnight hold and `l2v.release_overnight()`.

---

## 2. Configure Meta WhatsApp Test Number & Two Allowed Phones

1. In **Meta for Developers -> Your App -> WhatsApp -> API Setup**, select the **Test number** (never a real clinic number) and copy its **Phone number ID** (`whatsapp_phone_number_id` in `public.clinics.settings`).
2. Under **To -> Manage phone number list**, register and verify **two allowed test phone numbers** (Meta test numbers can message up to 5 allowlisted recipients):
   - **Phone A (Test Patient):** used to send patient inquiries, voice notes, and booking confirmations.
   - **Phone B (Test Reception Rep / Manager):** added in `public.contacts` (`phone_e164` in `+<digits>` format) and linked in `l2v.reps` (`is_active = true`) so it receives `lead_handoff` quick-reply buttons and taps `استلمت العميل` (you may also set a third phone as `l2v.settings.manager_contact_id`, or temporarily point `manager_contact_id` to Phone B when testing `sla_breach` after deactivating or adding a second rep).
3. In **WhatsApp Manager -> Message Templates**, submit the three Arabic `UTILITY` templates printed by `scripts/new_clinic.sh` (documented in `docs/l2v/TEMPLATES.md`):
   - `lead_handoff` (`UTILITY`, `ar`, Quick-Reply button index `0`: `استلمت العميل`)
   - `sla_breach` (`UTILITY`, `ar`, no buttons)
   - `sla_breach_no_rep` (`UTILITY`, `ar`, no buttons)
   Confirm their approved names match `public.clinics.settings -> 'whatsapp_templates'`.

---

## 3. Import n8n Workflows (Renamed for Staging) & Re-Point Credentials

1. Create **staging-only credentials** in n8n (never edit or reuse a production credential):
   - **Postgres (`ClinicOS Runtime PostgreSQL` — staging):** connect as `clinicos_n8n_runtime` (with `SET ROLE clinicos_api_owner` or default role inheritance where `clinicos_api_owner` privileges apply) to the **STAGING** Supabase host.
   - **WhatsApp Cloud API (`WhatsApp account` — staging):** System User / test token scoped to the Meta test app.
   - **OpenAI (`OpenAI account` — staging):** API key with access to `gpt-4.1` and `gpt-4o-transcribe`.
   - **Header Auth (`ClinicOS Dashboard Header Auth` — staging):** Header Name `x-dashboard-token`, Value `<LONG_RANDOM_STAGING_TOKEN>`.
2. Import all three workflow JSON files into n8n and rename them clearly with a staging suffix (`"(L2V staging)"` in your folder/tag, or hyphenated in the workflow title):
   - `workflow/clinicos-main-engine.l2v.json` (`36` nodes) -> e.g. `ClinicOS - Main Engine - L2V staging`
   - `workflow/clinicos-l2v-sla-tick.json` (`4` nodes) -> e.g. `ClinicOS L2V SLA Tick - L2V staging`
   - `workflow/clinicos-dashboard-api.json` (`9` nodes) -> e.g. `ClinicOS Dashboard API - L2V staging`
   - **Important naming note for `public.log_workflow_error`:** `database/02_booking_and_outbox_rpcs.sql` validates `p_workflow_name` against `^ClinicOS[A-Za-z0-9 _—–-]{0,100}$`. Keep the workflow name starting with `ClinicOS` and use `- L2V staging` (letters, digits, spaces, hyphens — no literal `(` or `)`) if you want `Error Trigger -> Log Workflow Error` to persist rows in `public.system_events` without returning `{"ok": false, "reason": "invalid_request"}`.
3. Inside each of the 3 imported workflows:
   - Re-bind every placeholder credential (`YOUR_POSTGRES_CREDENTIAL_ID`, `YOUR_WHATSAPP_CREDENTIAL_ID`, `YOUR_OPENAI_CREDENTIAL_ID`, `YOUR_DASHBOARD_HEADER_AUTH_CREDENTIAL_ID`) to the **STAGING** credentials created in step 1.
   - Open **Workflow Settings** -> set **Error Workflow** to **the workflow itself** (so its internal `Error Trigger` -> `Log Workflow Error` path handles unhandled runtime errors).
   - Save each workflow.

---

## 4. Activation Order

Activate components in this exact order so no webhook or timer fires against half-configured state:

1. **Activate `ClinicOS Dashboard API - L2V staging`** and verify:
   - Unauthenticated `curl -i "https://<N8N_STAGING_HOST>/webhook/clinicos/dashboard?from=2026-11-01&to=2026-11-17"` returns `401`/`403`.
   - Authenticated request with `-H "x-dashboard-token: <LONG_RANDOM_STAGING_TOKEN>"` and a `>90`-day range (`from=2026-01-01&to=2026-06-01`) returns `400` (`{"ok":false,"error":"date_range_exceeds_90_days"}`).
   - Authenticated request with a valid `<=90`-day range returns `200` with `{"ok":true,"kpi_daily":[...],"leads":[...]}`.
2. **Activate `ClinicOS - Main Engine - L2V staging`** (so both `GET Webhook` and `WhatsApp Webhook` on `/webhook/clinicos/meta` are live, and the 1-minute `Reminder & Outbox Timer` starts).
3. **Connect Meta Webhook:** in Meta App Dashboard -> WhatsApp -> Configuration, set Callback URL to `https://<N8N_STAGING_HOST>/webhook/clinicos/meta`, enter the `clinicos_meta_verify_token` value, click **Verify and save** (exercises `GET Webhook` -> `Verify Token` -> `Challenge Reply`), and subscribe to `messages`.
4. **Manually activate `ClinicOS L2V SLA Tick - L2V staging`:** imported workflows start **inactive** in n8n; toggle it **Active** so `Schedule Trigger` runs `SELECT l2v.release_overnight() AS released, l2v.escalate_overdue() AS escalated;` every minute.

---

## 5. End-to-End Staging Verification Checklist (6 Core Steps + Voice & Batch Tests)

Run all 8 checks below from **Phone A (Test Patient)** and **Phone B (Test Rep)**:

1. **Ad message capture:** Send an inbound message with a Click-to-WhatsApp `referral` payload (or simulate via Meta's webhook test tool with `referral.source_id` / `referral.headline` signed with `clinicos_meta_app_secret`).
   - **Pass criteria:** A new row appears in `l2v.leads` with `source = 'click_to_whatsapp'` and `campaign` populated (`leads_ads` increments by `1`).
2. **Hot qualification & rep handoff:** From Phone A, say in Arabic/English that you want to start treatment **this week** and the price fits your budget (e.g. `"عايز أعمل جلسة كشف الأسبوع ده والسعر مناسب جداً"`).
   - **Pass criteria:** `L2V Qualify` calls `l2v.qualify_contact` -> `l2v.set_qualification`, updating `l2v.leads.status = 'hot'` (`score >= 70`); `l2v.assignments` gets a `pending` row; `public.outbox` enqueues and delivers the `lead_handoff` template with the `استلمت العميل` quick-reply button to **Phone B**.
3. **Rep button tap isolation:** On **Phone B**, tap `استلمت العميل`.
   - **Pass criteria:** `L2V Gate` (`l2v.is_staff` = `true`) calls `l2v.rep_ack`, updating `l2v.assignments.status = 'acked'` (`acked_at` set); `Is Staff?` exits on the `true` branch so **the AI receptionist does NOT reply to Phone B**.
4. **15-minute SLA escalation:** Create a fresh `hot` lead (or temporarily set `sla_minutes = 1` in `l2v.settings` for staging) and do **not** tap the button on Rep 1's phone.
   - **Pass criteria:** After `sla_due_at <= now()`, `ClinicOS L2V SLA Tick` (`Escalate Overdue Leads` -> `l2v.escalate_overdue`) marks Rep 1's assignment `status = 'escalated'`, assigns the next eligible active rep (or triggers `sla_breach_no_rep` if none remain), and enqueues `sla_breach` to `manager_contact_id`. (If `open_time`/`close_time` are set to closed hours, verify zero escalation fires until `l2v.is_clinic_open` becomes `true`.)
5. **Auto-close assignment on booking before SLA expires:** With an active `pending` assignment on Phone A's lead, complete a slot selection and send `"تأكيد"` from Phone A before `sla_due_at`.
   - **Pass criteria:** `Save State & Enqueue` creates a `confirmed` row in `public.appointments`; on the next 1-minute tick, `l2v.escalate_overdue` transitions `l2v.assignments.status` to `'closed_booked'` with **zero** manager escalation.
6. **Daily KPI & Dashboard API check:** Query `SELECT * FROM l2v.kpi_daily('<CLINIC_ID>', current_date - 7, current_date);` and open `dashboard/index.html` configured with staging `DASHBOARD_CONFIG` (`apiUrl`, `apiToken`).
   - **Pass criteria:** `leads`, `hot_leads`, `avg_first_reply_s`, `escalations`, `booked_leads`, `visits`, `no_shows`, `leads_ads`, and `leads_organic` match staging activity (`leads_ads + leads_organic = leads`), `demoDataBanner` is hidden when connected (and visible with `DEMO DATA` if `apiToken` is cleared), and every `phone_masked` in `leads` masks all digits except the last 3 (`+*********NNN`).
7. **Voice-note test:** From **Phone A**, record and send an Arabic WhatsApp voice note asking for available slots (e.g. *"السلام عليكم، عايز أحجز ميعاد كشف بكرة الصبح"*).
   - **Pass criteria:** `Is Voice Note?` routes `true` -> `Get Audio URL` -> `Download Voice` -> `Transcribe Voice` (`gpt-4o-transcribe`) -> `Save & Inject Transcript` (`public.apply_voice_transcription`), `public.messages.body` stores the Arabic transcript, and Phone A receives real slot options from `Get Slots` -> `Format Slot List`.
8. **Two-message batch / rapid-burst test:** Send two messages back-to-back from **Phone A** within 1–2 seconds (e.g. message 1: `"السلام عليكم"`, message 2: a voice note or `"عايز أحجز كشف يوم الأحد"` — or deliver a 2-item `messages` array where item `0` is text and item `1` is `audio`).
   - **Pass criteria:** In a multi-item webhook batch containing a non-zero voice index, `Is Voice Note?` (`messages.some(...)`), `Get Audio URL`, `Download Voice`, `Transcribe Voice`, and `Save & Inject Transcript` (`msgs.findIndex(...)` reordering for 2-arg `public.apply_voice_transcription`) transcribe the voice item without throwing or overwriting the text item; on rapid overlapping executions, `Save State & Enqueue` checks `public.get_conversation_fresh_state` (`is_superseded`) so stale turns do not overwrite newer state or double-reply.

---

## 6. Where to Look for Failures

| Symptom | Where to Inspect | Exact Columns / Nodes to Check |
| :--- | :--- | :--- |
| **Webhook rejected (`403` / `unauthorized: true`)** | n8n Executions (`Verify Token` or `Verify & Save Event`) + Supabase `vault.decrypted_secrets` | Confirm `clinicos_meta_verify_token` and `clinicos_meta_app_secret` exist in Vault and `Extract Raw Body` receives raw binary payload (`rawBody: true` on `WhatsApp Webhook`). |
| **Unhandled workflow error** | `public.system_events` + n8n **Executions -> Error** tab | `SELECT * FROM public.system_events WHERE level = 'error' ORDER BY created_at DESC LIMIT 20;` (`event_type = 'workflow_execution_failed'`, `details->>'last_node'`, `details->>'error_class'`). Also confirm there is **1** row in `public.clinics` (`public.log_workflow_error` raises if `count <> 1`). |
| **Outbound WhatsApp message not delivered** | `public.outbox` + n8n `Claim Outbox` / `Parse Send Result` / `Record Send Result` | `SELECT id, kind, status, attempts, last_error, delivery_status, delivery_error_code FROM public.outbox ORDER BY created_at DESC LIMIT 20;` — check `whatsapp_phone_number_id` in `public.clinics.settings` (`outbox_message_dead` in `public.system_events` if missing) and template approval status in Meta WhatsApp Manager. |
| **Lead not captured or rep reply answered by AI** | n8n `L2V Prepare` -> `L2V Gate` -> `L2V Merge` -> `Is Staff?` + `l2v.leads` / `l2v.reps` | Remember `L2V Gate` and `L2V Qualify` fail open (`onError: "continueRegularOutput"`): inspect `L2V Gate` output in n8n execution data for SQL permission errors, and verify rep `phone_e164` in `public.contacts` starts with `+` and `l2v.reps.is_active = true`. |
| **Overnight hot lead not assigned or SLA breach not firing** | n8n `ClinicOS L2V SLA Tick` (`Escalate Overdue Leads`) + `l2v.settings` / `l2v.assignments` | Confirm `ClinicOS L2V SLA Tick` is toggled **Active**, check `SELECT l2v.is_clinic_open('<CLINIC_ID>');` (`open_time`, `close_time`, `open_days`, `public.clinics.timezone`), and inspect `SELECT * FROM l2v.assignments ORDER BY assigned_at DESC LIMIT 20;`. |
| **Dashboard shows `DEMO DATA` banner** | Browser DevTools Network tab + n8n `ClinicOS Dashboard API` | Confirm `DASHBOARD_CONFIG.apiUrl` and `DASHBOARD_CONFIG.apiToken` in `dashboard/index.html` are not `YOUR_*` placeholders, header `x-dashboard-token` matches `ClinicOS Dashboard Header Auth`, and `from`..`to` is `<= 90` days. |
