// Validates GET query parameters (?from=YYYY-MM-DD&to=YYYY-MM-DD) for ClinicOS Dashboard API.
// Fails closed (valid: false, status_code: 400) on missing, malformed, reversed, or >90-day ranges.

const item = typeof $json !== "undefined" && $json && typeof $json === "object" ? $json : {};
const query = item.query && typeof item.query === "object" && !Array.isArray(item.query) ? item.query : {};

function parseStrictIsoDate(val) {
  if (typeof val !== "string") return null;
  const trimmed = val.trim();
  if (trimmed.length !== 10 || !/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return null;
  const [yStr, mStr, dStr] = trimmed.split("-");
  const y = Number(yStr);
  const m = Number(mStr);
  const d = Number(dStr);
  if (!Number.isInteger(y) || !Number.isInteger(m) || !Number.isInteger(d)) return null;
  if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (
    Number.isNaN(dt.getTime()) ||
    dt.getUTCFullYear() !== y ||
    dt.getUTCMonth() !== m - 1 ||
    dt.getUTCDate() !== d
  ) {
    return null;
  }
  return { iso: trimmed, ms: dt.getTime() };
}

const parsedFrom = parseStrictIsoDate(query.from);
const parsedTo = parseStrictIsoDate(query.to);

if (!parsedFrom || !parsedTo) {
  return {
    json: {
      valid: false,
      status_code: 400,
      error: "invalid_date_params",
    },
  };
}

if (parsedFrom.ms > parsedTo.ms) {
  return {
    json: {
      valid: false,
      status_code: 400,
      error: "from_after_to",
    },
  };
}

const inclusiveDays = Math.round((parsedTo.ms - parsedFrom.ms) / 86400000) + 1;
if (inclusiveDays < 1 || inclusiveDays > 90) {
  return {
    json: {
      valid: false,
      status_code: 400,
      error: "date_range_exceeds_90_days",
    },
  };
}

return {
  json: {
    valid: true,
    from: parsedFrom.iso,
    to: parsedTo.iso,
    days: inclusiveDays,
  },
};
