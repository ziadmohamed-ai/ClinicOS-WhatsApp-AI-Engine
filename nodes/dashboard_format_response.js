// Formats the Postgres response for ClinicOS Dashboard API.
// Fails closed if clinic_count !== 1, caps leads at 50, and enforces phone masking
// (all digits masked except the last 3 digits) as defense-in-depth.

const row = typeof $json !== "undefined" && $json && typeof $json === "object" ? $json : {};
const clinicCount = Number(row.clinic_count ?? 0);

if (!Number.isInteger(clinicCount) || clinicCount !== 1) {
  throw new Error(`Dashboard API requires exactly 1 clinic row in public.clinics (found ${clinicCount})`);
}

let reqMeta = { from: null, to: null };
try {
  const v = $("Validate Query Params").item?.json;
  if (v && typeof v === "object") {
    reqMeta = { from: v.from ?? null, to: v.to ?? null };
  }
} catch {
  try {
    const idx = typeof $itemIndex === "number" ? $itemIndex : 0;
    const v = $("Validate Query Params").all()?.[idx]?.json;
    if (v && typeof v === "object") {
      reqMeta = { from: v.from ?? null, to: v.to ?? null };
    }
  } catch {
    reqMeta = { from: null, to: null };
  }
}

function maskPhoneLast3(value) {
  if (typeof value === "string" && /^\+\*+\d{3}$/.test(value.trim())) {
    return value.trim();
  }
  const digits = String(value ?? "").replace(/\D+/g, "");
  if (digits.length <= 3) {
    return "***";
  }
  return "+" + "*".repeat(digits.length - 3) + digits.slice(-3);
}

const rawKpis = Array.isArray(row.kpi_daily)
  ? row.kpi_daily
  : typeof row.kpi_daily === "string"
    ? JSON.parse(row.kpi_daily)
    : [];

const kpiDaily = rawKpis.map((k) => {
  const out = {
    day: String(k?.day ?? ""),
    leads: Number(k?.leads ?? 0),
    hot_leads: Number(k?.hot_leads ?? 0),
    avg_first_reply_s:
      k?.avg_first_reply_s === null || k?.avg_first_reply_s === undefined
        ? null
        : Number(k.avg_first_reply_s),
    escalations: Number(k?.escalations ?? 0),
    booked_leads: Number(k?.booked_leads ?? 0),
    visits: Number(k?.visits ?? 0),
    no_shows: Number(k?.no_shows ?? 0),
  };
  if (k && Object.prototype.hasOwnProperty.call(k, "leads_ads")) {
    out.leads_ads = Number(k.leads_ads ?? 0);
  }
  if (k && Object.prototype.hasOwnProperty.call(k, "leads_organic")) {
    out.leads_organic = Number(k.leads_organic ?? 0);
  }
  return out;
});

const rawLeads = Array.isArray(row.leads)
  ? row.leads
  : typeof row.leads === "string"
    ? JSON.parse(row.leads)
    : [];

const leads = rawLeads.slice(0, 50).map((l) => ({
  lead_id: l?.lead_id ? String(l.lead_id) : null,
  phone_masked: maskPhoneLast3(l?.phone_masked ?? l?.phone_e164 ?? l?.phone ?? ""),
  status: String(l?.status ?? "new"),
  source: String(l?.source ?? "organic"),
  score: l?.score === null || l?.score === undefined ? null : Number(l.score),
  campaign: l?.campaign ? String(l.campaign) : null,
  treatment_interest: l?.treatment_interest ? String(l.treatment_interest) : null,
  created_at: l?.created_at ? String(l.created_at) : null,
}));

return {
  json: {
    ok: true,
    from: reqMeta.from,
    to: reqMeta.to,
    kpi_daily: kpiDaily,
    leads,
  },
};
