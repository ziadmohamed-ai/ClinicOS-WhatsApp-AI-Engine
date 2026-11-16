const request = $("Parse AI Output").item.json;
const result = $json.result ?? [];
const slots = Array.isArray(result) ? result : Array.isArray(result.result) ? result.result : [];
const lang = request.language === "en" ? "en" : "ar";
const dialect = request.dialect || (lang === "en" ? "en" : "ar-EG");
const zone = request.clinic_timezone || "Asia/Riyadh";
const chosen = slots.slice(0, 5);

if (!chosen.length) {
  return {
    json: {
      ...request,
      should_update: false,
      target_status: null,
      state_patch: null,
      reply_text:
        lang === "en"
          ? "I couldn't find an open slot in that time range. Would you like to check another day or time?"
          : dialect === "ar-SA"
            ? "المعذرة منك، ما في مواعيد فاضية في هذا الوقت. تحب نشوف يوم أو وقت ثاني؟"
            : "معلش مفيش مواعيد فاضية في الوقت ده، تحب نشوف يوم أو وقت تاني؟",
    },
  };
}

const fmtArParts = new Intl.DateTimeFormat("ar-EG-u-nu-latn", {
  timeZone: zone,
  weekday: "long",
  day: "numeric",
  month: "long",
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
});
const fmtEnParts = new Intl.DateTimeFormat("en-GB", {
  timeZone: zone,
  weekday: "short",
  day: "numeric",
  month: "short",
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
});

function formatCleanAr(iso) {
  const parts = Object.fromEntries(fmtArParts.formatToParts(new Date(iso)).map((p) => [p.type, p.value]));
  const timeStr = parts.minute === "00" ? parts.hour : parts.hour + ":" + parts.minute;
  const rawPeriod = String(parts.dayPeriod || "").trim();
  const periodLabel = /^(ص|صباح|am)/i.test(rawPeriod) ? "صباحاً" : /^(م|مساء|pm)/i.test(rawPeriod) ? "مساءً" : rawPeriod;
  return "يوم " + (parts.weekday || "") + " " + (parts.day || "") + " " + (parts.month || "") + " الساعة " + timeStr + " " + periodLabel;
}

function formatCleanEn(iso) {
  return fmtEnParts.format(new Date(iso)).replace(/,/g, "");
}

const enrichedSlots = chosen.map((s, i) => ({
  ...s,
  slot_index: i + 1,
  display_time_ar: formatCleanAr(s.starts_at),
  display_time_en: formatCleanEn(s.starts_at),
}));

const list = enrichedSlots
  .map((s, i) => {
    const t = lang === "en" ? s.display_time_en : s.display_time_ar;
    const doc = s.provider_name ? (lang === "en" ? " with " + s.provider_name : " مع " + s.provider_name) : "";
    return (i + 1) + "- " + t + doc;
  })
  .join("\n");

// Check if the patient asked for a specific narrow time (<= 2 hours window) and slot 1 matches requested_from!
const reqFromMs = Date.parse(String(request.requested_from || ""));
const reqToMs = Date.parse(String(request.requested_to || ""));
const firstSlotMs = Date.parse(String(enrichedSlots[0]?.starts_at || ""));
const isExactRequestedTimeMatch =
  enrichedSlots[0]?.exact_match === true &&
  Number.isFinite(reqFromMs) &&
  Number.isFinite(reqToMs) &&
  reqToMs - reqFromMs <= 2 * 60 * 60 * 1000 &&
  Math.abs(firstSlotMs - reqFromMs) < 60 * 1000;

const preSelectedSlot =
  enrichedSlots.length === 1 || isExactRequestedTimeMatch
    ? enrichedSlots[0]
    : null;

const isReschedule = request.intent === "reschedule_request";
const pending_booking = {
  service_id: request.service_id,
  service_code: request.service_code,
  is_reschedule: isReschedule,
  target_appointment_id: isReschedule ? (request.target_appointment_id ?? null) : null,
  available_slots: enrichedSlots,
  selected_slot: preSelectedSlot,
  timezone: zone,
  expires_at: new Date(Date.now() + 20 * 60 * 1000).toISOString(),
};

const svcLabel = lang === "en"
  ? (request.service_name_en || request.service_code || "your visit")
  : (request.service_name_ar || "الكشف");

let intro = "";
if (request.reply_text && typeof request.reply_text === "string") {
  const clean = request.reply_text
    .trim()
    .replace(/\s*(?:سأعرض لك|يمكنك اختيار رقم الموعد|ابعت رقم الموعد)[\s\S]*$/i, "")
    .trim();
  const isSpeculativeOrLoading = /(سأبحث عن المواعيد|سأتحقق من المواعيد|أشيك لك|اشيك لك|هشوفلك لو متاح|أبلغك لو متاح|ابلغك لو متاح|لو كان متاح|i will check|checking available|let me check if)/i.test(clean);
  if (!isSpeculativeOrLoading && clean.length > 8) {
    intro = clean + "\n\n";
  }
}

const usedFallback = chosen[0]?.exact_match === false;
if (usedFallback && !/مفيش|غير متاح|إجازة|مغلق|أقرب|مش فاضي/i.test(intro)) {
  intro = lang === "en"
    ? "That specific time isn't open right now, so here are the nearest available times for " + svcLabel + ":\n\n"
    : dialect === "ar-SA"
      ? "الوقت هذا تحديداً مو فاضي حالياً، وهذي أقرب المواعيد المتاحة لـ " + svcLabel + ":\n\n"
      : "الوقت ده تحديداً مش فاضي حالياً، فدي أقرب مواعيد متاحة لـ " + svcLabel + " بعده علطول:\n\n";
} else if (!intro) {
  if (isExactRequestedTimeMatch) {
    const t0 = lang === "en" ? enrichedSlots[0].display_time_en : enrichedSlots[0].display_time_ar;
    const d0 = enrichedSlots[0].provider_name || "";
    intro = lang === "en"
      ? "Great news! " + t0 + " with " + d0 + " for " + svcLabel + " is available:\n\n"
      : dialect === "ar-SA"
        ? "أبشر طال عمرك، موعد " + t0 + " مع " + d0 + " لـ " + svcLabel + " متاح:\n\n"
        : "تمام يا فندم، ميعاد " + t0 + " مع " + d0 + " لـ " + svcLabel + " متاح، ودي المواعيد المتاحة:\n\n";
  } else {
    intro = lang === "en"
      ? "Here are the nearest available times for " + svcLabel + ":\n\n"
      : dialect === "ar-SA"
        ? "هذي أقرب المواعيد المتاحة حالياً لـ " + svcLabel + ":\n\n"
        : "دي أقرب المواعيد المتاحة حالياً لـ " + svcLabel + ":\n\n";
  }
}

function toAsciiDigits(v) {
  return String(v ?? "")
    .replace(/[\u0660-\u0669]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[\u06F0-\u06F9]/g, (d) => String(d.charCodeAt(0) - 0x06F0));
}
function closingFromAiOk(t, factsText) {
  if (typeof t !== "string") return false;
  const c = t.trim();
  if (c.length < 5 || c.length > 300 || !/[?؟]/.test(c) || /(لو كان متاح|لو متاح)/i.test(c)) return false;
  if (/(^|\n)\s*(?:\d+\s*[-.)]|[-*•])\s/.test(c)) return false;
  const allowed = new Set(toAsciiDigits(factsText + " " + String(request.body ?? "")).match(/\d+/g) || []);
  return (toAsciiDigits(c).match(/\d+/g) || []).every((n) => allowed.has(n));
}

let closingLine = "";
if (preSelectedSlot) {
  const tSel = lang === "en" ? preSelectedSlot.display_time_en : preSelectedSlot.display_time_ar;
  closingLine = closingFromAiOk(request.slot_closing_text, tSel) ? request.slot_closing_text.trim() : lang === "en"
    ? "Would you like me to confirm " + tSel + " for you right away, or do you prefer another time?"
    : dialect === "ar-SA"
      ? "تحب أأكد لك الحجز على " + tSel + " على طول، ولا تفضل وقت ثاني؟"
      : "تحب أأكدلك الحجز على ميعاد " + tSel + " علطول، ولا تفضل وقت تاني؟";
} else if (
  request.slot_closing_text &&
  request.slot_closing_text.length > 4 &&
  !/(لو كان متاح|لو متاح)/i.test(request.slot_closing_text)
) {
  closingLine = request.slot_closing_text;
} else {
  closingLine = lang === "en"
    ? "Just let me know which slot number or time works best for you!"
    : dialect === "ar-SA"
      ? "شوف أي موعد يناسبك وقولي رقمه أو وقته وأحجزه لك على طول"
      : "شوف كده أنهي ميعاد فيهم يناسبك وقولي رقمه أو وقته أحجزهولك علطول";
}

return {
  json: {
    ...request,
    should_update: true,
    target_status: null,
    state_patch: { pending_booking },
    reply_text: intro + list + "\n\n" + closingLine,
  },
};