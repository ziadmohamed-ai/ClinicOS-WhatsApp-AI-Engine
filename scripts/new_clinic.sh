#!/usr/bin/env bash
# ClinicOS T9 (Option 1: one Supabase project per clinic) — new clinic bootstrap generator.
#
# Inputs:
#   --name <clinic_name>                  Clinic display name (required; or positional $1)
#   --phone-number-id <meta_phone_id>     WhatsApp Cloud API phone_number_id (default: YOUR_META_PHONE_NUMBER_ID; or positional $2)
#   --timezone <iana_tz>                  IANA timezone (default: Africa/Cairo; or positional $3)
#   --utc-offset <+HH:MM|-HH:MM>          UTC offset string (default: +02:00; or positional $4)
#   --out <seed_sql_path>                 Output seed SQL path (default: ./clinic_<slug>_seed.sql; or positional $5)
#   --clinic-id <uuid>                    Optional explicit clinic UUID (default: generated UUIDv4)
#
# Generates a clinic-specific idempotent seed SQL file, prints the ordered install steps
# (including psql -v clinic_id=<uuid> for database/03_rls_policies.sql), and prints the three
# Meta WhatsApp template texts directly from docs/l2v/TEMPLATES.md for copy/paste.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

CLINIC_NAME=""
PHONE_NUMBER_ID=""
TIMEZONE="Africa/Cairo"
UTC_OFFSET="+02:00"
OUT_SQL=""
CLINIC_ID=""

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      CLINIC_NAME="${2:-}"
      shift 2
      ;;
    --phone-number-id)
      PHONE_NUMBER_ID="${2:-}"
      shift 2
      ;;
    --timezone)
      TIMEZONE="${2:-}"
      shift 2
      ;;
    --utc-offset)
      UTC_OFFSET="${2:-}"
      shift 2
      ;;
    --out)
      OUT_SQL="${2:-}"
      shift 2
      ;;
    --clinic-id)
      CLINIC_ID="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    --*)
      echo "ERROR: Unknown option: $1" >&2
      exit 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ -z "$CLINIC_NAME" ] && [ "${#POSITIONAL[@]}" -ge 1 ]; then
  CLINIC_NAME="${POSITIONAL[0]}"
fi
if [ -z "$PHONE_NUMBER_ID" ] && [ "${#POSITIONAL[@]}" -ge 2 ]; then
  PHONE_NUMBER_ID="${POSITIONAL[1]}"
fi
if [ "${#POSITIONAL[@]}" -ge 3 ]; then
  TIMEZONE="${POSITIONAL[2]}"
fi
if [ "${#POSITIONAL[@]}" -ge 4 ]; then
  UTC_OFFSET="${POSITIONAL[3]}"
fi
if [ -z "$OUT_SQL" ] && [ "${#POSITIONAL[@]}" -ge 5 ]; then
  OUT_SQL="${POSITIONAL[4]}"
fi

if [ -z "$PHONE_NUMBER_ID" ]; then
  PHONE_NUMBER_ID="YOUR_META_PHONE_NUMBER_ID"
fi

if [ -z "$CLINIC_NAME" ]; then
  echo "ERROR: clinic name is required (pass --name \"<Clinic Name>\" or as first argument)" >&2
  exit 2
fi

IS_WIN=0
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*) IS_WIN=1 ;;
esac

to_mixed_path() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd "$p" && pwd -W)
  else
    local d b
    mkdir -p "$(dirname "$p")"
    d="$(cd "$(dirname "$p")" && pwd -W)"
    b="$(basename "$p")"
    printf '%s/%s\n' "$d" "$b"
  fi
}

if [ "$IS_WIN" -eq 1 ]; then
  REPO_NODE="$(to_mixed_path "$REPO")"
else
  REPO_NODE="$REPO"
fi

if [ -n "$OUT_SQL" ] && [ "$IS_WIN" -eq 1 ]; then
  OUT_NODE="$(to_mixed_path "$OUT_SQL")"
else
  OUT_NODE="$OUT_SQL"
fi

node - "$REPO_NODE" "$CLINIC_NAME" "$TIMEZONE" "$UTC_OFFSET" "$PHONE_NUMBER_ID" "$OUT_NODE" "$CLINIC_ID" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const [
  repoDir,
  rawName,
  rawTimezone,
  rawUtcOffset,
  rawPhoneNumberId,
  rawOutPath,
  rawClinicId,
] = process.argv.slice(2);

const clinicName = rawName.trim();
const timezone = rawTimezone.trim() || 'Africa/Cairo';
const utcOffset = rawUtcOffset.trim() || '+02:00';
const phoneNumberId = rawPhoneNumberId.trim() || 'YOUR_META_PHONE_NUMBER_ID';

if (!clinicName) {
  throw new Error('Clinic name must not be empty');
}
if (!/^[+-]\d{2}:\d{2}$/.test(utcOffset)) {
  throw new Error(`Invalid utc_offset "${utcOffset}": expected +HH:MM or -HH:MM (e.g. +02:00)`);
}
if (!/^[A-Za-z0-9_\/+-]+$/.test(timezone)) {
  throw new Error(`Invalid timezone "${timezone}"`);
}

const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const clinicId = rawClinicId.trim() ? rawClinicId.trim().toLowerCase() : crypto.randomUUID();
if (!uuidRe.test(clinicId)) {
  throw new Error(`Invalid clinic_id UUID "${clinicId}"`);
}
if (clinicId.startsWith('5b20' + '1616')) {
  throw new Error('Refusing legacy hard-coded demo clinic UUID');
}

// Deterministic child UUIDs derived from clinicId so re-generating with the same --clinic-id is idempotent
function derivedUuid(label) {
  const h = crypto.createHash('sha256').update(clinicId + ':' + label).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

const prov1Id = derivedUuid('provider:1');
const prov2Id = derivedUuid('provider:2');
const svc1Id = derivedUuid('service:CONSULTATION');
const svc2Id = derivedUuid('service:FOLLOWUP');

const slug = clinicName
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, '_')
  .replace(/^_+|_+$/g, '') || 'clinic';

const outPath = rawOutPath.trim()
  ? rawOutPath.trim()
  : path.join(process.cwd(), `clinic_${slug}_seed.sql`);

const sqlStr = (s) => "'" + String(s).replace(/'/g, "''") + "'";

const seedSql = `-- =====================================================================
-- ClinicOS Clinic Seed File (Generated by scripts/new_clinic.sh)
-- One Supabase Project per Clinic (Option 1)
--
-- Clinic Name:              ${clinicName.replace(/\r?\n/g, ' ')}
-- Clinic ID:                ${clinicId}
-- Timezone:                 ${timezone}
-- UTC Offset:               ${utcOffset}
-- WhatsApp Phone Number ID: ${phoneNumberId.replace(/\r?\n/g, ' ')}
--
-- Edit placeholder providers, services, working hours, location, and emergency
-- number below before production go-live. Idempotent: safe to run more than once.
-- =====================================================================

INSERT INTO public.clinics (id, name, timezone, settings)
VALUES (
  ${sqlStr(clinicId)}::uuid,
  ${sqlStr(clinicName)},
  ${sqlStr(timezone)},
  jsonb_build_object(
    'whatsapp_phone_number_id', ${sqlStr(phoneNumberId)},
    'utc_offset', ${sqlStr(utcOffset)},
    'snapshot', jsonb_build_object(
      'timezone', ${sqlStr(timezone)},
      'utc_offset', ${sqlStr(utcOffset)}
    ),
    'slot_step_minutes', 30,
    'min_notice_minutes', 60,
    'max_days_ahead', 30,
    'reminder_hours_before', 24,
    'human_handoff_timeout_hours', 12,
    'emergency_number', '123',
    'installments_available', false,
    'location', 'PLACEHOLDER_CLINIC_ADDRESS — edit before go-live',
    'parking', 'PLACEHOLDER_PARKING_INFO — edit before go-live',
    'payment_methods', jsonb_build_array('كاش (نقداً)', 'بطاقة بنكية', 'InstaPay'),
    'whatsapp_templates', jsonb_build_object(
      'lead_handoff', jsonb_build_object(
        'name', 'lead_handoff',
        'language_codes', jsonb_build_object('ar', 'ar')
      ),
      'sla_breach', jsonb_build_object(
        'name', 'sla_breach',
        'language_codes', jsonb_build_object('ar', 'ar')
      ),
      'sla_breach_no_rep', jsonb_build_object(
        'name', 'sla_breach_no_rep',
        'language_codes', jsonb_build_object('ar', 'ar')
      )
    )
  )
)
ON CONFLICT (id) DO NOTHING;

-- Placeholder Providers (edit names & specialties before go-live)
INSERT INTO public.providers (id, clinic_id, name, specialty, active)
VALUES
  (${sqlStr(prov1Id)}::uuid, ${sqlStr(clinicId)}::uuid, 'د. طبيب ١ (مثال — عدّل قبل التشغيل)', 'تخصص ١ (General / Dental)', true),
  (${sqlStr(prov2Id)}::uuid, ${sqlStr(clinicId)}::uuid, 'د. طبيب ٢ (مثال — عدّل قبل التشغيل)', 'تخصص ٢ (Specialist)', true)
ON CONFLICT (id) DO NOTHING;

-- Placeholder Services (edit codes, Arabic/English names, durations, and prices before go-live)
INSERT INTO public.services (id, clinic_id, code, name_ar, name_en, duration_minutes, price, active)
VALUES
  (${sqlStr(svc1Id)}::uuid, ${sqlStr(clinicId)}::uuid, 'INITIAL_CONSULT', 'كشف واستشارة أولية', 'Initial Consultation', 30, 300, true),
  (${sqlStr(svc2Id)}::uuid, ${sqlStr(clinicId)}::uuid, 'FOLLOWUP_VISIT', 'زيارة متابعة', 'Follow-up Visit', 30, 150, true)
ON CONFLICT (clinic_id, code) DO NOTHING;

-- Placeholder Provider-Service Mapping
INSERT INTO public.provider_services (clinic_id, provider_id, service_id)
SELECT
  ${sqlStr(clinicId)}::uuid,
  p.id,
  s.id
FROM public.providers AS p
JOIN public.services AS s
  ON s.clinic_id = p.clinic_id
WHERE p.clinic_id = ${sqlStr(clinicId)}::uuid
  AND p.id IN (${sqlStr(prov1Id)}::uuid, ${sqlStr(prov2Id)}::uuid)
  AND s.code IN ('INITIAL_CONSULT', 'FOLLOWUP_VISIT')
ON CONFLICT (clinic_id, provider_id, service_id) DO NOTHING;

-- Placeholder Working Hours (Sunday-Thursday & Saturday 10:00-18:00, idempotent)
INSERT INTO public.working_hours (clinic_id, provider_id, weekday, start_time, end_time)
SELECT
  ${sqlStr(clinicId)}::uuid,
  p.id,
  w.weekday,
  TIME '10:00:00',
  TIME '18:00:00'
FROM public.providers AS p
CROSS JOIN (VALUES (0::smallint), (1::smallint), (2::smallint), (3::smallint), (4::smallint), (6::smallint)) AS w(weekday)
WHERE p.clinic_id = ${sqlStr(clinicId)}::uuid
  AND p.id IN (${sqlStr(prov1Id)}::uuid, ${sqlStr(prov2Id)}::uuid)
  AND NOT EXISTS (
    SELECT 1
    FROM public.working_hours AS wh
    WHERE wh.clinic_id = ${sqlStr(clinicId)}::uuid
      AND wh.provider_id = p.id
      AND wh.weekday = w.weekday
  );
`;

fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, seedSql, 'utf8');

// Extract the 3 Meta template texts directly from docs/l2v/TEMPLATES.md
const templatesMd = fs.readFileSync(path.join(repoDir, 'docs', 'l2v', 'TEMPLATES.md'), 'utf8').replace(/\r\n/g, '\n');
function extractTemplateBody(name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp('## \\d+\\. `' + escaped + '`[\\s\\S]*?### Exact Arabic Body Text\\s*```text\\n([\\s\\S]*?)\\n```');
  const m = templatesMd.match(re);
  if (!m || !m[1]) {
    throw new Error(`Could not extract template "${name}" from docs/l2v/TEMPLATES.md`);
  }
  return m[1].trim();
}

const tplHandoff = extractTemplateBody('lead_handoff');
const tplBreach = extractTemplateBody('sla_breach');
const tplNoRep = extractTemplateBody('sla_breach_no_rep');

console.log('=====================================================================');
console.log('ClinicOS — New Clinic Bootstrap (Option 1: One Supabase per Clinic)');
console.log('=====================================================================');
console.log(`CLINIC_ID=${clinicId}`);
console.log(`CLINIC_NAME=${clinicName}`);
console.log(`TIMEZONE=${timezone}`);
console.log(`UTC_OFFSET=${utcOffset}`);
console.log(`WHATSAPP_PHONE_NUMBER_ID=${phoneNumberId}`);
console.log(`SEED_SQL=${outPath}`);
console.log('');
console.log('Ordered PostgreSQL / Supabase Install Steps:');
console.log('  1. psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database/01_schema.sql');
console.log('  2. psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database/02_booking_and_outbox_rpcs.sql');
console.log('  3. psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database/02a_live_sync_profile_and_slots.sql');
console.log(`  4a (psql CLI). psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v clinic_id=${clinicId} -f database/03_rls_policies.sql`);
console.log(`  4b (Supabase SQL Editor — no psql). Replace <CLINIC_UUID> with ${clinicId} in database/03a_rls_policies_template.sql and run it`);
console.log(`  5. psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "${outPath}"`);
console.log('  6. psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database/05_lead_engine.sql');
console.log('  7. (Optional demo/staging staff) psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database/05b_l2v_seed_example.sql');
console.log('');
console.log('Meta WhatsApp Templates (submit in Meta Business Suite, category UTILITY, language ar):');
console.log('');
console.log('[1] lead_handoff (UTILITY, ar, Quick-Reply button 0: "استلمت العميل"):');
console.log(`    ${tplHandoff}`);
console.log('');
console.log('[2] sla_breach (UTILITY, ar, no buttons):');
console.log(`    ${tplBreach}`);
console.log('');
console.log('[3] sla_breach_no_rep (UTILITY, ar, no buttons):');
console.log(`    ${tplNoRep}`);
console.log('=====================================================================');
NODE
