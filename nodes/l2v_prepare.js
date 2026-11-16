// Prepares Lead-to-Visit gate parameters from a "Parse Turn & State" item.
// Never throws on missing or malformed fields; returns safe nulls and a valid l2v.leads.source value.
const rawInput =
  typeof $json !== "undefined" && $json && typeof $json === "object"
    ? $json
    : typeof $input !== "undefined" && $input && typeof $input === "object"
      ? ($input.item?.json ?? (typeof $input.first === "function" ? $input.first()?.json : null) ?? {})
      : {};
const ev = rawInput && typeof rawInput === "object" && !Array.isArray(rawInput) ? rawInput : {};

function trimOrNull(val) {
  if (val === null || val === undefined) return null;
  const s = String(val).trim();
  return s.length > 0 ? s : null;
}

function parseIsoOrNull(val) {
  if (val === null || val === undefined || val === "") return null;
  if (typeof val === "number") {
    if (!Number.isFinite(val)) return null;
    // Meta webhooks emit Unix timestamps in seconds (< 1e12); larger numbers are ms.
    const d = new Date(val < 1e12 ? val * 1000 : val);
    return Number.isFinite(d.getTime()) ? d.toISOString() : null;
  }
  const s = String(val).trim();
  if (!s) return null;
  if (/^\d{9,15}$/.test(s)) {
    const n = Number(s);
    const d = new Date(s.length <= 10 ? n * 1000 : n);
    return Number.isFinite(d.getTime()) ? d.toISOString() : null;
  }
  const ms = Date.parse(s);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

const clinic_id = trimOrNull(ev.clinic_id);
const contact_id = trimOrNull(ev.contact_id);

const rawPhone = trimOrNull(ev.phone) ?? trimOrNull(ev.phone_e164) ?? "";
const digits = rawPhone.replace(/\D+/g, "");
const phone_e164 = digits.length > 0 ? "+" + digits : null;

let rawPayload = null;
if (ev.payload && typeof ev.payload === "object" && !Array.isArray(ev.payload)) {
  rawPayload = ev.payload;
} else if (typeof ev.payload === "string" && ev.payload.trim().startsWith("{")) {
  try {
    const parsed = JSON.parse(ev.payload);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) rawPayload = parsed;
  } catch {}
}

const candidateReferral =
  rawPayload?.referral && typeof rawPayload.referral === "object" && !Array.isArray(rawPayload.referral)
    ? rawPayload.referral
    : ev.referral && typeof ev.referral === "object" && !Array.isArray(ev.referral)
      ? ev.referral
      : null;

const hasReferral = candidateReferral !== null && Object.keys(candidateReferral).length > 0;
const referral = hasReferral ? candidateReferral : null;
const source = hasReferral ? "click_to_whatsapp" : "organic";
const campaign = hasReferral
  ? (trimOrNull(candidateReferral.headline) ?? trimOrNull(candidateReferral.source_id) ?? null)
  : null;

const message_timestamp =
  parseIsoOrNull(ev.message_timestamp) ??
  parseIsoOrNull(ev.received_at) ??
  parseIsoOrNull(ev.timestamp) ??
  parseIsoOrNull(rawPayload?.timestamp) ??
  null;

return {
  json: {
    clinic_id,
    phone_e164,
    phone: phone_e164,
    contact_id,
    source,
    campaign,
    referral,
    message_timestamp,
    received_at: message_timestamp,
  },
};
