// Upgraded Parse AI Output & Format Slot List JS code for ClinicOS

const PARSE_AI_OUTPUT_JS = `function extractAiJson(raw) {
  if (!raw || typeof raw !== "object") return {};
  if (typeof raw.intent === "string") return raw;
  const candidates = [
    raw.output,
    raw.output_text,
    raw.text,
    raw.output?.[0]?.content?.[0]?.text,
    raw.output?.[0]?.content?.[0]?.json,
    raw.output?.[0]?.text,
    raw.content?.[0]?.text,
    raw.choices?.[0]?.message?.content,
  ];
  for (const c of candidates) {
    if (!c) continue;
    if (typeof c === "string") {
      const cleaned = c.trim().replace(/^\\\`\\\`\\\`(?:json)?\\s*/i, "").replace(/\\s*\\\`\\\`\\\`$/i, "").trim();
      try {
        const obj = JSON.parse(cleaned);
        if (obj && typeof obj === "object" && !Array.isArray(obj)) return obj;
      } catch {
        const m = cleaned.match(/\\{[\\s\\S]*\\}/);
        if (m) {
          try {
            const obj = JSON.parse(m[0]);
            if (obj && typeof obj === "object" && !Array.isArray(obj)) return obj;
          } catch {}
        }
      }
      if (cleaned.length > 0 && !cleaned.startsWith("{")) {
        return {
          intent: "faq",
          language: /[\\u0600-\\u06FF]/.test(cleaned) ? "ar" : "en",
          reply_text: cleaned,
          confidence: 0.9,
          service_code: null,
          requested_from: null,
          requested_to: null,
          selected_slot_index: null,
          needs_human: false,
        };
      }
    } else if (typeof c === "object" && !Array.isArray(c) && typeof c.intent === "string") {
      return c;
    }
  }
  return {};
}

function normalizeAr(str) {
  if (!str || typeof str !== "string") return "";
  return str
    .replace(/[\\u0660-\\u0669]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[\\u06F0-\\u06F9]/g, (d) => String(d.charCodeAt(0) - 0x06F0))
    .replace(/[\\u064B-\\u065F\\u0670\\u0640]/g, "")
    .replace(/[أإآ]/g, "ا")
    .replace(/ة/g, "ه")
    .replace(/ى/g, "ي")
    .replace(/([\\u0621-\\u064A])\\1{2,}/g, "$1")
    .replace(/\\s+/g, " ")
    .trim()
    .toLowerCase();
}

function humanizeWhatsAppText(s) {
  if (!s || typeof s !== "string") return "";
  return s
    .replace(/[*_~\`"#]+/g, "")
    .replace(/\\s*[—–]\\s*/g, " ")
    .replace(/فيزا\\/ماستركارد/g, "فيزا أو ماستركارد")
    .replace(/(?<!(?:^|[\\s(])(?:د|أ|م|Dr|Mr|Ms|Mrs))\\.(?=\\s+[^\\d])/g, "\\n")
    .replace(/(?<!(?:^|[\\s(])(?:د|أ|م|Dr|Mr|Ms|Mrs))\\.(?=$)/g, "")
    .replace(/ *\\n */g, "\\n")
    .replace(/\\n{3,}/g, "\\n\\n")
    .replace(/[^\\S\\r\\n]{2,}/g, " ")
    .trim();
}

function normalizeIso(v, offset) {
  if (!v || typeof v !== "string") return "";
  const s = v.trim();
  if (!s) return "";
  const tz = offset || "+03:00";
  if (/(?:Z|[+-]\\d{2}:\\d{2})$/i.test(s)) return s;
  if (/^\\d{4}-\\d{2}-\\d{2}$/.test(s)) return s + "T00:00:00" + tz;
  if (/^\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}$/.test(s)) return s.replace(" ", "T") + ":00" + tz;
  if (/^\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}/.test(s)) return s.replace(" ", "T") + tz;
  return s;
}

function detectDialect(normMsg, currentLanguage, savedDialect) {
  if (/^[a-z0-9\\s.,?!'"-]+$/i.test(normMsg) && /[a-z]{2,}/i.test(normMsg)) return "en";
  if (/(عايز|عاوز|بكام|(?:^|\\s)كام(?:\\s|$)|ازيك|معلش|دلوقتي|امتي|فين|ليه|(?:^|\\s)كده(?:\\s|$)|علشان|عشان|يا فندم|اوي|(?:^|\\s)طب\\s|طيب خلي|ميعاد|حجزتلي|اكدلي|النهارده|بتاعي|واجعني|بيوجعني|سناني)/.test(normMsg)) return "ar-EG";
  if (/(ابغي|ابي|بغيت|وش|بكم|حياك|ابشر|طال عمرك|لاهنت|لا هنت|تكفي|الحين|دوامكم|متي دوام|تقدرون|يعافيك|يجزاك|تفتحون|وين موقع|حقي|ما قصرتوا|يا هلا|مشكورين|اعتمدوه)/.test(normMsg)) return "ar-SA";
  if (currentLanguage === "en") return "en";
  return savedDialect || "ar-EG";
}

function pickServiceCode(services, candidates) {
  if (Array.isArray(services) && services.length > 0) {
    for (const c of candidates) {
      const found = services.find((s) => String(s.code ?? "").toUpperCase() === c.toUpperCase());
      if (found) return found.code;
    }
    // Never return a code that does not exist in this clinic's catalog
    return null;
  }
  return candidates[0];
}

// Map AI / legacy service codes onto the clinic's real catalog codes (e.g. DERMA_CONSULT -> DERM_CONSULT)
const SERVICE_CODE_ALIAS_GROUPS = [
  ["DERM_CONSULT", "DERMA_CONSULT", "DERMATOLOGY_CONSULT", "DERMATOLOGY"],
  ["TEETH_WHITENING", "LASER_WHITENING", "WHITENING"],
  ["LASER_SESSION", "LASER_HAIR_REMOVAL", "LASER"],
  ["DENTAL_CLEANING", "TEETH_CLEANING", "CLEANING"],
  ["DENTAL_CHECKUP", "DENTAL_CONSULT", "CHECKUP"],
  ["HYDRAFACIAL", "HYDRA_FACIAL", "FACIAL"],
];
function resolveCatalogServiceCode(rawCode, services) {
  const code = String(rawCode ?? "").trim().toUpperCase();
  if (!code || !Array.isArray(services) || services.length === 0) return null;
  const exact = services.find((s) => String(s.code ?? "").toUpperCase() === code);
  if (exact) return exact.code;
  const group = SERVICE_CODE_ALIAS_GROUPS.find((g) => g.includes(code));
  return group ? pickServiceCode(services, group) : null;
}

function detectServiceCodeFromText(normMsg, services) {
  if (!normMsg) return null;
  if (/(تبييض|تبيض|ليزر اسنان|ليزر للاسنان|ليزر سنان|هوليود|whitening|bleaching)/i.test(normMsg)) return pickServiceCode(services, ["TEETH_WHITENING", "LASER_WHITENING"]);
  if (/(هيدرافيشل|هيدرا فيشل|تنظيف بشره|تنضيف بشره|نضاره|hydrafacial|facial)/i.test(normMsg)) return pickServiceCode(services, ["HYDRAFACIAL", "DERM_CONSULT", "DERMA_CONSULT"]);
  if (/(تنظيف اسنان|تنضيف اسنان|انظف اسنان|انضف اسنان|انظف سنان|انضف سنان|جير|تلميع|تنظيف اللثه|تنضيف اللثه|جلسه تنظيف|جلسه تنضيف|dental cleaning|scaling|teeth cleaning)/i.test(normMsg)) return pickServiceCode(services, ["DENTAL_CLEANING", "TEETH_CLEANING"]);
  if (/(تنظيف|تنضيف|انظف|انضف|cleaning)/i.test(normMsg) && !/(بشره|وجه|جلد|skin|face)/i.test(normMsg)) return pickServiceCode(services, ["DENTAL_CLEANING", "TEETH_CLEANING"]);
  if (/(ليزر|laser|hair removal|ازاله شعر|ازاله الشعر)/i.test(normMsg) && !/(اسنان|سنان|سناني|اسناني|teeth|tooth)/i.test(normMsg)) return pickServiceCode(services, ["LASER_SESSION", "DERM_CONSULT", "DERMA_CONSULT"]);
  if (/(جلديه|بشره|حب شباب|حساسيه|اكزيما|تصبغات|بوتوكس|فيلر|تساقط شعر|دكتور سامي|د سامي|سامي القحطاني|سامي العتيبي|derma|skin|acne|botox|filler|dr sami)/i.test(normMsg)) return pickServiceCode(services, ["DERM_CONSULT", "DERMA_CONSULT"]);
  if (/(تقويم|orthodont|braces)/i.test(normMsg)) return pickServiceCode(services, ["ORTHO_CONSULT", "DENTAL_CHECKUP"]);
  if (/(فحص اسنان|كشف اسنان|استشاره اسنان|وجع ضرس|الم ضرس|ضرس العقل|حشو|عصب|خلع|زراعه اسنان|تركيبات|طربوش|اسناني بتوجعني|ضرسي بيوجعني|dental checkup|toothache|tooth pain|cavity|root canal)/i.test(normMsg)) return pickServiceCode(services, ["DENTAL_CHECKUP"]);
  return null;
}

function extractPatientBookingPhone(rawText, normMsg, whatsappPhone) {
  if (!rawText || typeof rawText !== "string") return null;
  const asciiText = rawText
    .replace(/[\\u0660-\\u0669]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[\\u06F0-\\u06F9]/g, (d) => String(d.charCodeAt(0) - 0x06F0));

  // Explicit phone number in message (Egyptian, Saudi, Gulf, or international 8..15 digits)
  const phoneMatch =
    asciiText.match(/(?:^|[^\\d])(\\+?(?:20|966|971|965|974|973|968)?0?[15]\\d[\\d\\s-]{7,11}\\d)(?:$|[^\\d])/) ||
    asciiText.match(/(?:رقمي|الرقم|رقم التليفون|رقم الموبايل|رقم الجوال|تليفوني|جوالي|phone|number|mobile)\\s*[:：-]?\\s*(\\+?\\d[\\d\\s-]{7,14}\\d)/i);
  if (phoneMatch && phoneMatch[1]) {
    return phoneMatch[1].replace(/[\\s-]+/g, "").trim();
  }

  // "Use this same WhatsApp number" phrase
  if (/(نفس الرقم|نفس رقم|علي نفس الرقم|نفس رقم الواتس|نفس رقمي|هو الرقم ده|هو نفس الرقم|الرقم ده|نفس الجوال|علي نفس جوالي|رقمي هذا|هذا رقمي|بنفس الرقم|نفس النمره|same number|this number|my whatsapp number|use this number)/i.test(normMsg || "")) {
    return whatsappPhone || "same_whatsapp_number";
  }

  return null;
}

function extractPatientIntroducedName(rawText, normMsg, awaitingContactInfo, hasPhoneInMsg) {
  if (!rawText || typeof rawText !== "string") return null;
  const stopWords = /^(عايز|عاوز|محتاج|أبغى|ابغى|أبي|ابي|بحجز|أحجز|احجز|احجزلي|أحجزلي|اكد|أكد|اكدلي|أكدلي|تأكيد|تاكيد|اختار|هاخد|عندي|في|من|على|علي|بسأل|بسال|تنظيف|تنضيف|تبييض|فحص|كشف|استشارة|استشاره|جلدية|جلديه|هيدرافيشل|ليزر|تقويم|الخميس|الجمعة|السبت|الأحد|الاثنين|الثلاثاء|الأربعاء|بكرة|بكره|النهارده|اليوم|يوم|الساعة|الساعه|ساعة|ساعه|الصبح|صباحا|مساء|بالليل|العصر|الظهر|اول|أول|تاني|ثاني|تالت|ثالث|ميعاد|موعد|نفس|الرقم|رقمي|تمام|خلاص|موافق|اه|ايوا|أيوة|ايوه|نعم|لا|طيب|طب|هل|بكام|فين|امتى|امتي)$/i;

  const mAr = rawText.match(/(?:أنا اسمي|انا اسمي|اسمي|الاسم|باسم|الحجز باسم|سجل باسم|معاك|معاكم)\\s*[:：-]?\\s*(?:الأستاذ|الاستاذ|أستاذ|استاذ|الأستاذة|الاستاذه|مدام|دكتور|دكتورة|البشمهندس|المهندس)?\\s*([\\u0600-\\u06FF]{2,15}(?:\\s+[\\u0600-\\u06FF]{2,15}){0,3})/i);
  if (mAr && mAr[1]) {
    const rawWords = mAr[1].trim().split(/\\s+/);
    const words = [];
    for (const w of rawWords) {
      if (stopWords.test(w) || /^(?:و?عايز|و?عاوز|و?محتاج|و?أبغى|و?ابغى|و?بحجز|و?أحجز|و?احجز|و?عندي|و?بسأل|و?بسال|و|ورقمي|والرقم|تليفوني|تليفون|رقم|جوال|موبايل|على|علي|وعلى|وعلي|نفس|الرقم|ده|هذا|لو|سمحت)$/i.test(w)) {
        break;
      }
      words.push(w);
    }
    if (words.length > 0) {
      return words.slice(0, 3).join(" ");
    }
  }
  const mEn = rawText.match(/(?:my name is|name is|name|under the name|book for|i am|this is)\\s*[:：-]?\\s*([A-Za-z]{2,20}(?:\\s+[A-Za-z]{2,20}){0,2})/i);
  if (mEn && mEn[1]) {
    const words = mEn[1]
      .trim()
      .split(/\\s+/)
      .filter((w) => !/^(?:and|phone|number|same|my|is|on|this|please)$/i.test(w));
    if (words.length > 0 && !/^(looking|booking|calling|asking|having|in|at|from|wondering|confirming)$/i.test(words[0])) {
      return words.slice(0, 3).join(" ");
    }
  }

  // Direct reply when bot asked for Name & Phone (e.g. "زياد محمد 01000000000" or "زياد محمد وعلى نفس الرقم ده")
  if (
    (awaitingContactInfo || hasPhoneInMsg) &&
    !/(?:بكام|سعر|فين|عنوان|امتى|امتي|هل|ليه|ازاي|كيف|what|where|when|how|price|cost)/i.test(normMsg || "") &&
    (awaitingContactInfo || !/(?:احجز|احجزلي|عايز|عاوز|محتاج|ميعاد|موعد|الساعه|الساعة|ساعه|ساعة|يوم|بكره|بكرة)/i.test(normMsg || ""))
  ) {
    const cleaned = rawText
      .replace(/[\\u0660-\\u0669\\u06F0-\\u06F90-9+\\-().,،:：/\\\\]+/g, " ")
      .replace(/(?:و?على نفس الرقم ده|و?علي نفس الرقم ده|و?على نفس الرقم|و?علي نفس الرقم|و?نفس رقم الواتساب|و?نفس رقم الواتس|و?نفس الرقم ده|و?نفس الرقم|و?بنفس الرقم|و?نفس رقمي|و?نفس الجوال|هذا رقمي|رقمي هذا|والرقم|ورقمي|رقم التليفون|رقم الموبايل|رقم الجوال|تليفوني|تليفون|موبايل|جوالي|جوال|الاسم|اسمي|باسم|الحجز|الميعاد|الموعد|خلاص|تمام|اكد|أكد|اكدلي|أكدلي|تكد|موافق|ايوا|أيوة|ايوه|اه|آه|نعم|ماشي|طيب|طب|يا فندم|يا غالي|لو سمحت|بعد اذنك|الأستاذ|الاستاذ|أستاذ|استاذ|مدام|same number|this number|my whatsapp number|use this number|phone|number|name|confirm|yes|ok|okay|please)/gi, " ")
      .replace(/\\s+/g, " ")
      .trim();
    const arWords = cleaned.match(/^[\\u0600-\\u06FF]{2,15}(?:\\s+[\\u0600-\\u06FF]{2,15}){0,3}$/);
    if (arWords) {
      const tokens = arWords[0].split(/\\s+/).filter((w) => w.length >= 2 && !stopWords.test(w) && !/^و(?:على|علي|نفس|رقمي|الرقم)$/i.test(w));
      if (tokens.length >= 1 && tokens.length <= 4) {
        return tokens.slice(0, 3).join(" ").replace(/^و(?=[\\u0600-\\u06FF]{3,})/, "");
      }
    }
    const enWords = cleaned.match(/^[A-Za-z]{2,20}(?:\\s+[A-Za-z]{2,20}){0,2}$/);
    if (enWords) {
      const tokens = enWords[0].split(/\\s+/).filter((w) => !/^(and|with|for|the|slot|time|book|use|same)$/i.test(w));
      if (tokens.length >= 1 && tokens.length <= 3) {
        return tokens.join(" ");
      }
    }
  }

  return null;
}

function parseMentionedTime(normMsg) {
  if (!normMsg) return null;
  // Ignore pure slot indices like "رقم 2", "خيار 1", "خليها 2", "خليه 1"
  if (/^(?:رقم|خيار|موعد رقم|ميعاد رقم|خليه رقم|خليها رقم|خليه|خليها|نخليه|نخليها|هاخد|اختار|option|number|slot)\\s*[1-5]$/i.test(normMsg)) return null;

  let hour = null;
  let minute = 0;
  let period = null; // 'am' | 'pm' | null

  const wordHours = [
    [/الساعه واحده|ساعه واحده|الساعه وحده|ساعه وحده/i, 1],
    [/الساعه اتنين|الساعه اثنين|ساعه اتنين|الساعه ثنتين|ساعه ثنتين/i, 2],
    [/الساعه تلاته|الساعه ثلاثه|ساعه تلاته|الساعه ثلاث(?:\\s|$)|ساعه ثلاث(?:\\s|$)/i, 3],
    [/الساعه اربعه|ساعه اربعه|الساعه اربع(?:\\s|$)|ساعه اربع(?:\\s|$)/i, 4],
    [/الساعه خمسه|ساعه خمسه|الساعه خمس(?:\\s|$)|ساعه خمس(?:\\s|$)/i, 5],
    [/الساعه سته|ساعه سته|الساعه ست(?:\\s|$)|ساعه ست(?:\\s|$)/i, 6],
    [/الساعه سبعه|ساعه سبعه|الساعه سبع(?:\\s|$)|ساعه سبع(?:\\s|$)/i, 7],
    [/الساعه تمانيه|الساعه ثمانيه|ساعه تمانيه|الساعه ثمان(?:\\s|$)|ساعه ثمان(?:\\s|$)/i, 8],
    [/الساعه تسعه|ساعه تسعه|الساعه تسع(?:\\s|$)|ساعه تسع(?:\\s|$)/i, 9],
    [/الساعه عشره|ساعه عشره|الساعه عشر(?:\\s|$)|ساعه عشر(?:\\s|$)/i, 10],
    [/الساعه حداشر|الساعه احدعشر|ساعه حداشر/i, 11],
    [/الساعه اتناشر|الساعه اثناعشر|ساعه اتناشر|الساعه طنعش|ساعه طنعش/i, 12],
  ];
  for (const [re, h] of wordHours) {
    if (re.test(normMsg)) {
      hour = h;
      break;
    }
  }
  if (hour !== null) {
    if (/ونص|ونصف/.test(normMsg)) minute = 30;
    else if (/وربع/.test(normMsg)) minute = 15;
    else if (/وتلت|وثلث/.test(normMsg)) minute = 20;
    else if (/الا ربع/.test(normMsg)) {
      hour = hour === 1 ? 12 : hour - 1;
      minute = 45;
    } else if (/الا تلت|الا ثلث/.test(normMsg)) {
      hour = hour === 1 ? 12 : hour - 1;
      minute = 40;
    }
  }

  if (hour === null) {
    // Pattern like "الساعه 4 بدل 10" or "خليها 4 بدل 10" -> capture the FIRST (target) hour before "بدل"
    const hasBadal = /\\s+بدل\\s+/.test(normMsg);
    const beforeBadal = normMsg.split(/\\s+بدل\\s+/)[0];
    const explicitClockRegex = /(?:الساعه|ساعه|عالساعه|علي الساعه|في الساعه|من الساعه|وقتها|at|around)\\s*(\\d{1,2})(?:[:.](\\d{2}))?(?:\\s*(ونص|ونصف|وربع|وتلت|وثلث|الا ربع|الا تلت|الا ثلث))?\\s*(الصبح|صباحا|ص|العصر|المساء|مساء|م|بالليل|الظهر|بعد الظهر|am|pm)?/i;
    const verbWithQualifierRegex = hasBadal
      ? /(?:خليه|خليها|نخليه|نخليها|for)\\s*(\\d{1,2})(?:[:.](\\d{2}))?(?:\\s*(ونص|ونصف|وربع|وتلت|وثلث|الا ربع))?\\s*(الصبح|صباحا|ص|العصر|المساء|مساء|م|بالليل|الظهر|بعد الظهر|am|pm)?/i
      : /(?:خليه|خليها|نخليه|نخليها|for)\\s*(\\d{1,2})(?:[:.](\\d{2})|\\s+(ونص|ونصف|وربع|وتلت|وثلث|الا ربع)|\\s+()(الصبح|صباحا|ص|العصر|المساء|مساء|م|بالليل|الظهر|بعد الظهر|am|pm))/i;
    const m =
      beforeBadal.match(explicitClockRegex) ||
      beforeBadal.match(verbWithQualifierRegex) ||
      beforeBadal.match(/\\b(\\d{1,2})[:.](\\d{2})\\s*(الصبح|صباحا|ص|العصر|المساء|مساء|م|am|pm)?/i) ||
      beforeBadal.match(/\\b(\\d{1,2})\\s+(ونص|ونصف|وربع|وتلت|وثلث|الا ربع)\\s*(الصبح|صباحا|ص|العصر|المساء|مساء|م|am|pm)?/i);
    if (m) {
      hour = parseInt(m[1], 10);
      const frac = m[3] || m[2] || "";
      if (m[2] && /^\\d{2}$/.test(m[2])) {
        minute = parseInt(m[2], 10);
      } else if (/^(ونص|ونصف)$/.test(frac)) {
        minute = 30;
      } else if (frac === "وربع") {
        minute = 15;
      } else if (/^(وتلت|وثلث)$/.test(frac)) {
        minute = 20;
      } else if (frac === "الا ربع") {
        hour = hour === 1 ? 12 : hour - 1;
        minute = 45;
      } else if (/^(الا تلت|الا ثلث)$/.test(frac)) {
        hour = hour === 1 ? 12 : hour - 1;
        minute = 40;
      }
      const pRaw = m[5] || m[4] || m[3] || "";
      if (/^(الصبح|صباحا|ص|am)$/i.test(pRaw)) period = "am";
      else if (/^(العصر|المساء|مساء|م|بالليل|بعد الظهر|pm)$/i.test(pRaw)) period = "pm";
    }
  }

  if (hour === null || hour < 0 || hour > 23) return null;
  if (!period) {
    if (/(الصبح|صباحا|\\bص\\b|\\bam\\b)/i.test(normMsg)) period = "am";
    else if (/(العصر|المساء|مساء|\\bم\\b|بعد الظهر|\\bpm\\b)/i.test(normMsg)) period = "pm";
  }

  // Clinic hours are 10:00 AM to 6:00 PM: hours 1..6 are always PM (13..18), hours 9..11 are AM
  let hour24 = hour;
  if (hour >= 1 && hour <= 6) hour24 = hour + 12;
  else if (hour === 12) hour24 = 12;
  else if (hour >= 7 && hour <= 11 && period === "pm") hour24 = hour + 12;

  return { hour12: hour > 12 ? hour - 12 : hour, hour24, minute, period };
}

function getSlotLocalHourMin(isoStr, zone) {
  const d = new Date(isoStr);
  if (Number.isNaN(d.getTime())) return null;
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone: zone || "Asia/Riyadh",
      hour12: false,
      hour: "2-digit",
      minute: "2-digit",
    })
      .formatToParts(d)
      .map((p) => [p.type, p.value])
  );
  const h24 = parseInt(parts.hour, 10) % 24;
  const min = parseInt(parts.minute, 10);
  const h12 = h24 % 12 === 0 ? 12 : h24 % 12;
  return { h24, h12, min };
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const parsed = extractAiJson($json);
const ctx = $("Load Clinic Context").item.json;
const event = ctx.event ?? {};
const snapshot = ctx.clinic_snapshot ?? {};
const fresh = ctx.fresh_conversation ?? {};
const patientProfile = ctx.patient_profile && typeof ctx.patient_profile === "object" ? ctx.patient_profile : {};

if (fresh.is_superseded === true || fresh.status === "human") {
  return [];
}

const services = Array.isArray(snapshot.services) ? snapshot.services : [];
const providers = Array.isArray(snapshot.providers) ? snapshot.providers : [];
const zone = String(snapshot.timezone ?? "Asia/Riyadh");
const offset = String(snapshot.utc_offset ?? "+03:00");

const userMessage = String(event.body ?? "").trim();
const normMsg = normalizeAr(userMessage);

// 1. Deterministic Safety & Boundary Patterns
const emergencyPattern = /(نزيف|ورم شديد|تورم شديد|مش قادر اتنفس|مش قادره اتنفس|لا استطيع التنفس|صعوبه في البلع|صعوبه في التنفس|اختناق|حادث|كسر فك|كسر في الفك|تسمم|ضيق تنفس|الم لا يحتمل مع ورم|فقدان وعي|اغماء|severe swelling|heavy bleeding|can't breathe|cannot breathe|difficulty swallowing|choking|jaw fracture|unconscious)/i;
const handoffPattern = /(حولني لموظف|حولني للاستقبال|عايز اكلم موظف|عايز اكلم حد|ابغي موظف|ابي موظف|اكلم موظف|موظف بشري|خدمه العملاء|تقديم شكوي|عندي شكوي|مدير العياده|talk to a human|speak to receptionist|human agent|speak to someone|real person)/i;
const medicalPattern = /(اخد مضاد حيوي|اخذ مضاد حيوي|اكتبلي دواء|اكتبلي مسكن|جرعه دواء|جرعه المضاد|بديل دواء|ينفع اخد دواء|علاج التهاب اللثه في البيت|what antibiotic should i take|prescribe medication|dosage of)/i;
const promptInjectionPattern = /(ignore previous instructions|ignore all instructions|system prompt|developer message|انت الان مبرمج|انسي التعليمات السابقه|تجاهل التعليمات|اعطني البرومبت|شروطك البرمجيه)/i;

const isHardEmergency = emergencyPattern.test(normMsg) || emergencyPattern.test(userMessage);
const isHardHandoff = !isHardEmergency && (handoffPattern.test(normMsg) || handoffPattern.test(userMessage));
const isHardMedical = !isHardEmergency && !isHardHandoff && (medicalPattern.test(normMsg) || medicalPattern.test(userMessage));
const isPromptInjection = promptInjectionPattern.test(normMsg) || promptInjectionPattern.test(userMessage);

const allowed = new Set([
  "emergency",
  "human_handoff",
  "cancel_request",
  "confirm_booking",
  "reschedule_request",
  "slot_selection",
  "booking_request",
  "faq",
  "clarify",
  "medical_question",
]);

let intent = isHardEmergency
  ? "emergency"
  : isHardHandoff
    ? "human_handoff"
    : isHardMedical
      ? "medical_question"
      : isPromptInjection
        ? "clarify"
        : (allowed.has(parsed.intent) ? parsed.intent : "faq");

const c = Number(parsed.confidence);
let confidence = Number.isFinite(c) ? Math.max(0, Math.min(1, c)) : 0.9;
if (isHardEmergency || isHardHandoff || isHardMedical) confidence = 1.0;

if (confidence < 0.45 && intent !== "emergency" && intent !== "human_handoff" && intent !== "medical_question") {
  intent = "clarify";
}

const language = parsed.language === "en" || (/^[a-z0-9\\s.,?!'"-]+$/i.test(normMsg) && /[a-z]{3,}/i.test(normMsg)) ? "en" : "ar";
const dialect = detectDialect(normMsg, language, parsed.dialect || patientProfile.preferred_dialect);

let rawReply = typeof parsed.reply_text === "string" ? parsed.reply_text.trim().slice(0, 3500) : "";
if (isPromptInjection) {
  rawReply = language === "en"
    ? "I am the ClinicOS receptionist and can only help with clinic services, appointments, and general inquiries. How can I help you today?"
    : "أنا موظف الاستقبال في عيادة ClinicOS التخصصية، وأقدر أساعدك في حجز المواعيد أو الاستفسار عن خدمات وأطباء العيادة. أقدر أساعدك بإيه النهارده؟";
}
// Remove any invented pet nicknames like "يا زيزو" unless the patient calls themselves that
rawReply = rawReply.replace(/يا زيزو/g, "يا أستاذ زياد").replace(/يا حمودي/g, "يا أستاذ محمد");

const aiReply = humanizeWhatsAppText(rawReply);
const rawClosing = typeof parsed.slot_closing_text === "string" ? parsed.slot_closing_text.trim().slice(0, 500) : "";
const slotClosingText = humanizeWhatsAppText(rawClosing);

const state = (fresh.state && typeof fresh.state === "object") ? fresh.state : (event.conversation_state ?? {});
const pending = state.pending_booking && typeof state.pending_booking === "object" ? state.pending_booking : null;
const pendingSlots = Array.isArray(pending?.available_slots) ? pending.available_slots : [];

// ---- Existing-appointment targeting (cancel / reschedule) ----
const upcomingRaw = Array.isArray(ctx.upcoming_appointments) ? ctx.upcoming_appointments : [];
const upcomingById = new Map();
for (const a of upcomingRaw) {
  const id = typeof a?.appointment_id === "string" ? a.appointment_id.trim().toLowerCase() : "";
  if (UUID_RE.test(id)) upcomingById.set(id, a);
}
function validApptId(v) {
  const s = typeof v === "string" ? v.trim().toLowerCase() : "";
  return upcomingById.has(s) ? s : null;
}

// Deterministic intent upgrade for cancel / reschedule / confirm / slot_selection
const cancelPhrasesRe = /(عايز الغي|عاوز الغي|الغي الحجز|الغي الميعاد|الغي الموعد|الغيلي الميعاد|الغيلي الحجز|الغي حجزي|امسح الحجز|الغاء الحجز|الغاء الموعد|الغاء الميعاد|كنسل الحجز|كنسل الموعد|كنسل موعدي|اكنسل الحجز|ابغي الغي|ابي الغي|بغيت الغيه|لاغي الحجز|cancel my appointment|cancel my upcoming appointment|cancel the appointment|cancel booking|cancel my booking)/i;
const reschedulePhrasesRe = /(عايز اغير ميعادي|عايز اعدل ميعادي|غيرلي الميعاد|غيروا موعدي|ابي اغير موعدي|ابغي اغير موعدي|تعديل الموعد|تعديل الحجز|تاجيل الموعد|تأجيل الموعد|ناجل الحجز|ناجل الموعد|اقدم الميعاد|اجل ميعادي|اجل موعدي|اغير ميعادي|اغير موعدي|انقل الميعاد|انقل الحجز|reschedule my appointment|reschedule my booking|change my appointment|move my appointment)/i;
const changeTimePhraseRe = /(بدل\\s*\\d|خلي الحجز الساعه|خلي الميعاد الساعه|خلي الموعد الساعه|خليه الساعه|خليها الساعه)/i;

if (!isHardEmergency && !isHardHandoff && !isHardMedical && !isPromptInjection) {
  if (cancelPhrasesRe.test(normMsg) && !changeTimePhraseRe.test(normMsg)) {
    intent = "cancel_request";
  } else if (reschedulePhrasesRe.test(normMsg)) {
    intent = "reschedule_request";
  } else if (changeTimePhraseRe.test(normMsg)) {
    intent = upcomingById.size > 0 ? "reschedule_request" : "booking_request";
  }
  if (intent === "reschedule_request" && upcomingById.size === 0 && (pending || patientProfile.last_cancelled_appointment)) {
    // Patient just cancelled or has a pending booking and said "طب خليه الساعة 4 بدل 10" -> treat as booking_request using their remembered service!
    intent = "booking_request";
  }
}

const isCancelRequest = intent === "cancel_request";
const isRescheduleFlow =
  intent === "reschedule_request" ||
  (Boolean(pending?.is_reschedule) && (intent === "confirm_booking" || intent === "slot_selection"));
const touchesExisting = isCancelRequest || isRescheduleFlow;

let targetApptId = touchesExisting
  ? (validApptId(parsed.target_appointment_id) || validApptId(pending?.target_appointment_id))
  : null;
if (touchesExisting && !targetApptId && upcomingById.size === 1) {
  targetApptId = [...upcomingById.keys()][0];
}
// If patient has multiple upcoming appointments and named a doctor or service in the message, match that appointment!
if (touchesExisting && !targetApptId && upcomingById.size > 1) {
  const detCode = detectServiceCodeFromText(normMsg, services) || resolveCatalogServiceCode(parsed.service_code, services) || "";
  for (const [id, a] of upcomingById.entries()) {
    if (detCode && String(a.service_code || "").toUpperCase() === detCode.toUpperCase()) {
      targetApptId = id;
      break;
    }
    if (a.doctor_name && normMsg.includes(normalizeAr(String(a.doctor_name).replace(/^د\\.\\s*/, "")))) {
      targetApptId = id;
      break;
    }
  }
}
const targetAppt = targetApptId ? upcomingById.get(targetApptId) : null;

// Build patient_profile_patch to persist memory + registration contact details
const awaitingContactInfo = Boolean(pending?.awaiting_contact_info);
const rawDetectedPhone =
  extractPatientBookingPhone(userMessage, normMsg, event.phone_e164) ||
  (typeof parsed.patient_phone_detected === "string" && /\\d{8,15}/.test(parsed.patient_phone_detected)
    ? parsed.patient_phone_detected.trim()
    : null);
const detectedName =
  extractPatientIntroducedName(userMessage, normMsg, awaitingContactInfo, Boolean(rawDetectedPhone)) ||
  (typeof parsed.patient_name_detected === "string" ? parsed.patient_name_detected.trim() : null);
const detectedNote = typeof parsed.patient_note === "string" ? parsed.patient_note.trim().slice(0, 200) : null;

// A name counts as the official booking registration name if provided when awaiting contact info, alongside a phone number, with an explicit booking prefix ("باسم ..."), or as a multi-word full name
const isExplicitRegistrationName = Boolean(
  detectedName &&
  (awaitingContactInfo ||
    Boolean(rawDetectedPhone) ||
    /(?:باسم|الاسم|الحجز باسم|سجل باسم|under the name|book for)/i.test(userMessage) ||
    detectedName.trim().split(/\\s+/).length >= 2)
);

const baseProfilePatch = {
  preferred_dialect: dialect,
  ...(detectedName ? { preferred_name: detectedName } : {}),
  ...(isExplicitRegistrationName ? { registered_name: detectedName } : {}),
  ...(rawDetectedPhone ? { booking_phone: rawDetectedPhone } : {}),
  ...(detectedNote ? { notes: detectedNote } : {}),
};

function plainReply(text) {
  return {
    json: {
      ...event,
      clinic_timezone: zone,
      intent,
      confidence,
      language,
      dialect,
      needs_human: false,
      should_query_slots: false,
      should_cancel_appointment: false,
      should_confirm_booking: false,
      is_reschedule: false,
      target_appointment_id: null,
      service_id: null,
      service_code: null,
      provider_id: null,
      requested_from: null,
      requested_to: null,
      slot_closing_text: null,
      should_update: false,
      target_status: null,
      state_patch: null,
      patient_profile_patch: baseProfilePatch,
      reply_text: text,
    },
  };
}

// More than one upcoming appointment and we do not know which one: ask, never guess.
if (touchesExisting && !targetApptId && upcomingById.size > 1) {
  const list = [...upcomingById.values()]
    .map((a, i) => {
      const svc = language === "en" ? (a.service_name_en || a.service_name_ar) : (a.service_name_ar || a.service_name_en);
      const doc = a.doctor_name ? (language === "en" ? " with " + a.doctor_name : " مع " + a.doctor_name) : "";
      const when = language === "en" ? a.local_date + " at " + a.local_time : "يوم " + a.local_date + " الساعة " + a.local_time;
      return (i + 1) + "- " + (svc || "") + " " + when + doc;
    })
    .join("\\n");
  return plainReply(
    language === "en"
      ? "You have more than one upcoming appointment:\\n" + list + "\\nWhich one would you like to modify?"
      : "عندك أكتر من ميعاد قادم مسجل معانا:\\n" + list + "\\nتقصد أنهي واحد فيهم يا فندم؟"
  );
}

// Reschedule with nothing to reschedule and no remembered service
if (intent === "reschedule_request" && upcomingById.size === 0) {
  return plainReply(
    language === "en"
      ? "I couldn't find an upcoming confirmed appointment under your number to reschedule. Would you like to book a new one?"
      : dialect === "ar-SA"
        ? "ما لقيت موعد قادم مؤكد مسجل برقمك عشان أعدله، تحب أحجز لك موعد جديد؟"
        : "ملقتش ميعاد قادم مؤكد مسجل برقمك عشان أعدله، تحب نحجزلك ميعاد جديد؟"
  );
}

// Cancel with nothing to cancel
if (intent === "cancel_request" && upcomingById.size === 0) {
  // Wait: what if they have an active pending_booking and say "لا خلاص الغي الحجز"? Clear pending_booking!
  if (pending) {
    return {
      json: {
        ...event,
        clinic_timezone: zone,
        intent: "clarify",
        confidence,
        language,
        dialect,
        needs_human: false,
        should_query_slots: false,
        should_cancel_appointment: false,
        should_confirm_booking: false,
        is_reschedule: false,
        target_appointment_id: null,
        service_id: null,
        service_code: null,
        provider_id: null,
        requested_from: null,
        requested_to: null,
        slot_closing_text: null,
        should_update: true,
        target_status: null,
        state_patch: { pending_booking: null },
        patient_profile_patch: baseProfilePatch,
        reply_text: language === "en"
          ? "No problem at all, I've cancelled the pending booking request. Let me know whenever you'd like to book in the future!"
          : dialect === "ar-SA"
            ? "ولا يهمك، ألغيت لك طلب الحجز المؤقت. متى ما حبيت تحجز في أي وقت راسلني وأبشر!"
            : "ولا يهمك يا فندم، لغيتلك طلب الحجز المؤقت. وقت ما تحب تحجز في أي وقت ابعتلي بس!",
      },
    };
  }
  return plainReply(
    language === "en"
      ? "I couldn't find an upcoming confirmed appointment under your number to cancel. Would you like to book a new one?"
      : dialect === "ar-SA"
        ? "ما لقيت موعد قادم مؤكد مسجل برقمك عشان ألغيه، تحب أساعدك في حجز موعد جديد؟"
        : "ملقتش ميعاد قادم مؤكد مسجل برقمك عشان ألغيه، تحب أساعدك في حجز ميعاد جديد؟"
  );
}

// ---- Resolve Doctor / Provider ----
const rawDoctor = typeof parsed.doctor_id === "string" ? parsed.doctor_id.trim() : "";
let matchedProvider = null;
if (rawDoctor) {
  matchedProvider = providers.find(
    (p) =>
      String(p.id ?? "").toLowerCase() === rawDoctor.toLowerCase() ||
      normalizeAr(String(p.name ?? "")).includes(normalizeAr(rawDoctor)) ||
      normalizeAr(rawDoctor).includes(normalizeAr(String(p.name ?? "").replace(/^د\\.\\s*/, "")))
  ) ?? null;
}
if (!matchedProvider) {
  for (const p of providers) {
    const cleanDocName = normalizeAr(String(p.name ?? "").replace(/^د\\.\\s*/, ""));
    const firstDocName = cleanDocName.split(" ")[0];
    if (firstDocName && firstDocName.length >= 3 && normMsg.includes(firstDocName)) {
      matchedProvider = p;
      break;
    }
  }
}
const explicitProviderInTurn = matchedProvider;

// ---- Resolve Service (with Patient Memory & History Fallback) ----
const textServiceCode = detectServiceCodeFromText(normMsg, services);
const aiServiceCode = resolveCatalogServiceCode(parsed.service_code, services) || "";

// Look for any explicitly mentioned service in the current message first
let explicitService = null;
if (textServiceCode) {
  explicitService = services.find((s) => String(s.code ?? "").toUpperCase() === textServiceCode.toUpperCase()) ?? null;
}
if (!explicitService && aiServiceCode) {
  // Only trust aiServiceCode as explicit if it wasn't just a blind fallback to DENTAL_CHECKUP when patient has another remembered service
  const rememberedCode = pending?.service_code || patientProfile?.last_cancelled_appointment?.service_code || patientProfile?.last_service_code;
  if (!(aiServiceCode === "DENTAL_CHECKUP" && rememberedCode && rememberedCode !== "DENTAL_CHECKUP" && !/(فحص|كشف|الم|وجع|checkup)/i.test(normMsg))) {
    explicitService = services.find((s) => String(s.code ?? "").toLowerCase() === aiServiceCode.toLowerCase()) ?? null;
  }
}

let service = explicitService;

if (intent === "reschedule_request" && targetAppt) {
  const own = services.find((s) => String(s.code ?? "").toLowerCase() === String(targetAppt.service_code ?? "").toLowerCase());
  if (own) service = own;
}

if (!service) {
  // Fallback chain: 1. pending_booking -> 2. last_cancelled_appointment -> 3. patient_profile.last_service_code -> 4. recent conversation history -> 5. provider's default service -> 6. DENTAL_CHECKUP
  const memoryCode =
    pending?.service_code ||
    patientProfile?.last_cancelled_appointment?.service_code ||
    patientProfile?.last_service_code ||
    null;

  if (memoryCode) {
    const memSvc = services.find((s) => String(s.code ?? "").toLowerCase() === String(memoryCode).toLowerCase());
    if (memSvc && (!matchedProvider || !Array.isArray(matchedProvider.service_codes) || matchedProvider.service_codes.includes(memSvc.code))) {
      service = memSvc;
    }
  }
}

if (!service && Array.isArray(ctx.conversation_context)) {
  for (let i = ctx.conversation_context.length - 1; i >= 0; i--) {
    const histText = normalizeAr(String(ctx.conversation_context[i]?.text ?? ""));
    const histCode = detectServiceCodeFromText(histText, services);
    if (histCode) {
      const histSvc = services.find((s) => s.code === histCode);
      if (histSvc && (!matchedProvider || !Array.isArray(matchedProvider.service_codes) || matchedProvider.service_codes.includes(histSvc.code))) {
        service = histSvc;
        break;
      }
    }
  }
}

if (!service) {
  if (matchedProvider && Array.isArray(matchedProvider.service_codes) && matchedProvider.service_codes.length > 0) {
    service = services.find((s) => matchedProvider.service_codes.includes(s.code));
  }
  if (!service) {
    service = services.find((s) => s.code === "DENTAL_CHECKUP") || services[0];
  }
}

// If both an explicit service and an explicit provider were named, but that provider does not offer that service, clear matchedProvider so get_available_slots finds the right specialist
if (explicitService && matchedProvider && Array.isArray(matchedProvider.service_codes) && !matchedProvider.service_codes.includes(explicitService.code)) {
  matchedProvider = null;
}

// If provider wasn't explicitly mentioned in this turn, inherit from targetAppt, pending, or remembered provider (if compatible with service)
if (!matchedProvider) {
  const memProviderId =
    (intent === "reschedule_request" && targetAppt?.provider_id) ||
    pending?.available_slots?.[0]?.provider_id ||
    patientProfile?.last_cancelled_appointment?.provider_id ||
    patientProfile?.last_provider_id ||
    null;
  if (memProviderId) {
    const cand = providers.find((p) => String(p.id ?? "").toLowerCase() === String(memProviderId).toLowerCase());
    if (cand && (!service || !Array.isArray(cand.service_codes) || cand.service_codes.includes(service.code))) {
      matchedProvider = cand;
    }
  }
}

// Update profile patch with current service/provider interest when relevant
const profilePatch = {
  ...baseProfilePatch,
  ...(service && (intent === "booking_request" || intent === "slot_selection" || intent === "confirm_booking" || explicitService)
    ? { last_service_id: service.id, last_service_code: service.code, last_service_name: service.name_ar }
    : {}),
  ...(matchedProvider && (intent === "booking_request" || intent === "slot_selection" || intent === "confirm_booking")
    ? { last_provider_id: matchedProvider.id, last_provider_name: matchedProvider.name }
    : {}),
};

const nowMs = Date.now();
const rawFrom = normalizeIso(parsed.requested_from, offset);
const rawTo = normalizeIso(parsed.requested_to, offset);
const fromMs = Date.parse(rawFrom);
const toMs = Date.parse(rawTo);

let effectiveFrom = "";
let effectiveTo = "";
let rangeValid = false;

if (Number.isFinite(fromMs) && Number.isFinite(toMs)) {
  const effectiveFromMs = Math.max(fromMs, nowMs + 60 * 1000);
  if (toMs > effectiveFromMs && toMs - effectiveFromMs <= 31 * 24 * 60 * 60 * 1000) {
    effectiveFrom = new Date(effectiveFromMs).toISOString();
    effectiveTo = new Date(toMs).toISOString();
    rangeValid = true;
  }
}

if (!rangeValid && (intent === "booking_request" || intent === "reschedule_request") && Boolean(service?.id)) {
  effectiveFrom = new Date(nowMs + 60 * 1000).toISOString();
  effectiveTo = new Date(nowMs + 7 * 24 * 60 * 60 * 1000).toISOString();
  rangeValid = true;
}

// ---- Multi-Layer Slot Resolver & One-Step Confirmation Engine ----
const overrideAffirmativeRe = /^(?:لا خلاص اكد|لا تمام اكد|لا خلاص احجزه|لا تمام احجزه|لا خلاص موافق|لا عادي اكد)/i;
const negationOrQuestionGuardRe = /(?:^|\\s)(?:لا|لأ|مش|ما|مأ|بلاش|غير|متاكد|متأكد|متاكدش|متأكدش|ماتاكدش|ماتأكدش|ما تاكد|لا تاكد|لا تحجز|مش عايز|مش محتاج|هل|امتي|امتى|فين|بكام|بكم|ليه|ازاي|كيف|استني|استنى|لحظه|ثانيه|اصبر|don't|do not|dont|not|never|wait|hold on|are you sure|cancel)(?:\\s|$)/i;
const hasNegationOrQuestion = !overrideAffirmativeRe.test(normMsg) && negationOrQuestionGuardRe.test(normMsg);

const pureConfirmRe = /^(?:اكد|تكد|اتكد|تاكيد|تأكيد|اكدلي|تكدلي|اكده|اكد الحجز|تكد الحجز|ايوا|ايوه|ايوة|اه|آه|اه تمام|اه ياريت|نعم|اي نعم|ايه نعم|تم|تمم|تمام|تمام اكد|خلاص تمام|خلاص اكد|موافق|موافقه|ماشي|ماشي اكدلي|صح كده|يس|اعتمد|اعتمدوه|تم اعتمدوه|توكلنا علي الله|توكل علي الله|ان شاء الله|اوك|اوكي|طيب تمام|حلو تمام|ok|okay|yes|yes please|yep|sure|confirm|confirmed|book it|go ahead|sounds good|perfect)$/i;
const hasConfirmVerbRe = /(?:^|\\s)(?:اكد|تكد|اتكد|تاكيد|تأكيد|اكدلي|تكدلي|اكده|اكد الحجز|تكد الحجز|اعتمد|اعتمدوه|ثبت|ثبتلي|خلاص احجز|احجزه|احجزها|احجزلي رقم|احجزلي الاول|احجزلي التاني|احجزلي التالت|احجزلي الرابع|احجزلي الخامس|احجزلي الاخير|احجزلي الميعاد|احجزلي الموعد|احجزلي الساعه|توكل علي الله|توكلنا علي الله|ايوا|ايوه|اه ياريت|صح كده|يس|نعم|موافق|موافقه|confirm|confirmed|lock it in|book that|book it|book the first|book the second|book the third|book the fourth|book the fifth|book the last|book slot|book option|yes please)(?:\\s|$)/i;

const isPureConfirmMsg = !hasNegationOrQuestion && (pureConfirmRe.test(normMsg) || /^(?:ايوا+|اه+|تمام+|اكد+|تكد+)$/i.test(normMsg));
if (hasNegationOrQuestion && intent === "confirm_booking") {
  intent = "clarify";
}

// If bot previously asked "Would you like to register under this same WhatsApp number?" and patient replied "ايوه / تمام / اه", treat as same WhatsApp phone
const detectedPhone =
  rawDetectedPhone ||
  (Boolean(pending?.asked_same_phone_confirm) && isPureConfirmMsg ? (event.phone_e164 || "same_whatsapp_number") : null);

const effectiveBookingPhone =
  detectedPhone ||
  pending?.booking_phone ||
  patientProfile?.booking_phone ||
  null;

const effectiveRegisteredName =
  (isExplicitRegistrationName ? detectedName : null) ||
  pending?.registered_name ||
  patientProfile?.registered_name ||
  (awaitingContactInfo && effectiveBookingPhone ? (detectedName || patientProfile?.preferred_name || null) : null);

if (detectedName || (awaitingContactInfo && effectiveBookingPhone && effectiveRegisteredName)) {
  if (effectiveRegisteredName) profilePatch.registered_name = effectiveRegisteredName;
}
if (detectedPhone) {
  profilePatch.booking_phone = detectedPhone;
}

const providedContactInfoForSelectedSlot = Boolean(
  pending?.selected_slot &&
  !hasNegationOrQuestion &&
  (detectedPhone || (awaitingContactInfo && detectedName))
);

const hasExplicitConfirmIntent =
  !hasNegationOrQuestion &&
  (isPureConfirmMsg || hasConfirmVerbRe.test(normMsg) || intent === "confirm_booking" || providedContactInfoForSelectedSlot);

const needsContactInfoForBooking =
  !Boolean(pending?.is_reschedule) &&
  !Boolean(patientProfile?.is_returning_patient) &&
  (!effectiveRegisteredName || !effectiveBookingPhone);

// Check if the patient changed service or doctor compared to pending_booking
const changedServiceFromPending = Boolean(
  pending &&
  explicitService &&
  pending.service_code &&
  String(explicitService.code).toUpperCase() !== String(pending.service_code).toUpperCase()
);
const changedProviderFromPending = Boolean(
  pending &&
  explicitProviderInTurn &&
  pendingSlots.length > 0 &&
  !pendingSlots.some((s) => String(s.provider_id ?? "").toLowerCase() === String(explicitProviderInTurn.id ?? "").toLowerCase())
);

const mentionedTime = parseMentionedTime(normMsg);
let matchedSlotByTime = null;
let mentionedTimeOutsidePending = false;

if (pendingSlots.length > 0 && mentionedTime) {
  for (const s of pendingSlots) {
    if (explicitProviderInTurn && String(s.provider_id ?? "").toLowerCase() !== String(explicitProviderInTurn.id ?? "").toLowerCase()) {
      continue;
    }
    const hm = getSlotLocalHourMin(s.starts_at, zone);
    if (!hm) continue;
    const hourMatches = hm.h24 === mentionedTime.hour24 || hm.h12 === mentionedTime.hour12;
    const minMatches = hm.min === mentionedTime.minute;
    if (hourMatches && minMatches) {
      matchedSlotByTime = s;
      break;
    }
  }
  if (!matchedSlotByTime) {
    mentionedTimeOutsidePending = true;
  }
}

// Layer 2: Ordinal / numeric index detection in message
let ordinalIdx = null;
if (pendingSlots.length > 0 && !mentionedTime && !changedProviderFromPending) {
  const numOnly = normMsg.match(/^(?:رقم|خيار|الميعاد رقم|الموعد رقم|اختار رقم|هاخد رقم|احجز رقم|خليه رقم|خليها رقم|خليه|خليها|نخليه|نخليها|option|slot|number)?\\s*([1-5])$/i);
  if (numOnly) {
    ordinalIdx = parseInt(numOnly[1], 10);
  } else if (/(الاول|اول واحد|اول ميعاد|اول موعد|رقم واحد|رقم 1|\\bfirst\\b|\\boption 1\\b)/i.test(normMsg)) {
    ordinalIdx = 1;
  } else if (/(الثاني|التاني|تاني واحد|تاني ميعاد|تاني موعد|رقم اتنين|رقم اثنين|رقم 2|\\bsecond\\b|\\boption 2\\b)/i.test(normMsg)) {
    ordinalIdx = 2;
  } else if (/(الثالث|التالت|تالت واحد|تالت ميعاد|تالت موعد|رقم تلاته|رقم ثلاثه|رقم 3|\\bthird\\b|\\boption 3\\b)/i.test(normMsg)) {
    ordinalIdx = 3;
  } else if (/(الرابع|رابع واحد|رابع ميعاد|رابع موعد|رقم اربعه|رقم 4|\\bfourth\\b|\\boption 4\\b)/i.test(normMsg)) {
    ordinalIdx = 4;
  } else if (/(الخامس|خامس واحد|خامس ميعاد|خامس موعد|رقم خمسه|رقم 5|\\bfifth\\b|\\boption 5\\b)/i.test(normMsg)) {
    ordinalIdx = 5;
  } else if (/(الاخير|اخر واحد|اخر ميعاد|اخر موعد|\\blast\\b)/i.test(normMsg)) {
    ordinalIdx = pendingSlots.length;
  }
}

const aiSlotIdx = Number.isInteger(parsed.selected_slot_index) ? parsed.selected_slot_index : null;
const effectiveSlotIdx =
  ordinalIdx && ordinalIdx >= 1 && ordinalIdx <= pendingSlots.length
    ? ordinalIdx
    : (aiSlotIdx && aiSlotIdx >= 1 && aiSlotIdx <= pendingSlots.length && !mentionedTimeOutsidePending && !changedProviderFromPending && !hasNegationOrQuestion ? aiSlotIdx : null);

// Layer 4: Match parsed.requested_from against pendingSlots
let matchedSlotByFromIso = null;
if (pendingSlots.length > 0 && Number.isFinite(fromMs) && !mentionedTimeOutsidePending && !changedProviderFromPending) {
  matchedSlotByFromIso = pendingSlots.find(
    (s) =>
      Math.abs(Date.parse(s.starts_at) - fromMs) < 60000 &&
      (!explicitProviderInTurn || String(s.provider_id ?? "").toLowerCase() === String(explicitProviderInTurn.id ?? "").toLowerCase())
  ) ?? null;
}

// Resolve chosen slot from pending_booking
let resolvedPendingSlot = null;
if (pendingSlots.length > 0 && !changedServiceFromPending && !changedProviderFromPending && !mentionedTimeOutsidePending) {
  if (matchedSlotByTime) {
    resolvedPendingSlot = matchedSlotByTime;
  } else if (effectiveSlotIdx) {
    resolvedPendingSlot = pendingSlots[effectiveSlotIdx - 1];
  } else if (matchedSlotByFromIso && (intent === "confirm_booking" || intent === "slot_selection" || hasExplicitConfirmIntent)) {
    resolvedPendingSlot = matchedSlotByFromIso;
  } else if (hasExplicitConfirmIntent) {
    if (pending?.selected_slot) {
      resolvedPendingSlot = pending.selected_slot;
    } else if (pendingSlots.length === 1) {
      resolvedPendingSlot = pendingSlots[0];
    }
  }
}

// If patient requested a time outside pendingSlots (e.g., "طيب خلي الحجز الساعه 4 بدل 10") or changed service/doctor, query fresh slots!
if ((mentionedTimeOutsidePending || changedServiceFromPending || changedProviderFromPending) && (intent === "slot_selection" || intent === "confirm_booking" || intent === "clarify")) {
  intent = upcomingById.size > 0 && changeTimePhraseRe.test(normMsg) ? "reschedule_request" : "booking_request";
  if (!rangeValid && Boolean(service?.id)) {
    effectiveFrom = new Date(nowMs + 60 * 1000).toISOString();
    effectiveTo = new Date(nowMs + 7 * 24 * 60 * 60 * 1000).toISOString();
    rangeValid = true;
  }
}

// If pending.selected_slot is set and the patient explicitly rejected it (e.g. "لا مش موافق" / "Don't confirm"), unselect it and ask which slot they want
if (
  !isHardEmergency &&
  !isHardHandoff &&
  !isHardMedical &&
  !isCancelRequest &&
  pending?.selected_slot &&
  hasNegationOrQuestion &&
  intent === "clarify"
) {
  const clearedSelectedPending = {
    ...pending,
    selected_slot: null,
    expires_at: new Date(Date.now() + 20 * 60 * 1000).toISOString(),
  };
  return {
    json: {
      ...event,
      clinic_timezone: zone,
      intent: "clarify",
      confidence,
      language,
      dialect,
      needs_human: false,
      should_query_slots: false,
      should_cancel_appointment: false,
      should_confirm_booking: false,
      is_reschedule: Boolean(pending?.is_reschedule),
      target_appointment_id: targetApptId || pending?.target_appointment_id || null,
      service_id: null,
      service_code: null,
      provider_id: null,
      requested_from: null,
      requested_to: null,
      slot_closing_text: null,
      should_update: true,
      target_status: null,
      state_patch: { pending_booking: clearedSelectedPending },
      patient_profile_patch: profilePatch,
      reply_text:
        language === "en"
          ? "No problem at all! Which other time or slot from the list would you prefer?"
          : dialect === "ar-SA"
            ? "ولا يهمك طال عمرك، ما أكدت الموعد. أي وقت أو خيار ثاني من القائمة يناسبك أكثر؟"
            : "ولا يهمك يا فندم، مأكدتش الميعاد. قولي أنهي ميعاد تاني يناسبك أكتر؟",
    },
  };
}

// Execute 1-step or 2-step confirmation when a slot is resolved, patient expressed confirmation intent, and registration contact info is complete
if (
  !isHardEmergency &&
  !isHardHandoff &&
  !isHardMedical &&
  !isCancelRequest &&
  resolvedPendingSlot &&
  pending?.service_id &&
  hasExplicitConfirmIntent &&
  !needsContactInfoForBooking &&
  intent !== "reschedule_request" &&
  !(intent === "booking_request" && (mentionedTimeOutsidePending || changedServiceFromPending || changedProviderFromPending))
) {
  return {
    json: {
      ...event,
      clinic_timezone: zone,
      intent: "confirm_booking",
      confidence,
      language,
      dialect,
      needs_human: false,
      should_query_slots: false,
      should_cancel_appointment: false,
      should_confirm_booking: true,
      is_reschedule: Boolean(pending?.is_reschedule),
      target_appointment_id: targetApptId || pending?.target_appointment_id || null,
      confirm_provider_id: resolvedPendingSlot.provider_id,
      confirm_service_id: pending.service_id,
      confirm_starts_at: resolvedPendingSlot.starts_at,
      service_id: null,
      service_code: null,
      provider_id: null,
      requested_from: null,
      requested_to: null,
      slot_closing_text: null,
      should_update: false,
      target_status: null,
      state_patch: null,
      patient_profile_patch: profilePatch,
      reply_text: aiReply,
    },
  };
}

// Execute slot selection (or hold slot while collecting first-time Name & Phone for Option 1)
if (
  !isHardEmergency &&
  !isHardHandoff &&
  !isHardMedical &&
  !isCancelRequest &&
  resolvedPendingSlot &&
  pending?.service_id &&
  (intent === "slot_selection" || effectiveSlotIdx || matchedSlotByTime || hasExplicitConfirmIntent)
) {
  const updatedPending = {
    ...pending,
    selected_slot: resolvedPendingSlot,
    awaiting_contact_info: needsContactInfoForBooking,
    registered_name: effectiveRegisteredName || null,
    booking_phone: effectiveBookingPhone || null,
    asked_same_phone_confirm: Boolean(needsContactInfoForBooking && effectiveRegisteredName && !effectiveBookingPhone),
    target_appointment_id: targetApptId || pending?.target_appointment_id || null,
    expires_at: new Date(Date.now() + 20 * 60 * 1000).toISOString(),
  };
  const timeStr = (language === "en" ? resolvedPendingSlot.display_time_en : resolvedPendingSlot.display_time_ar) || "";
  const docName = resolvedPendingSlot.provider_name || (language === "en" ? "the doctor" : "الدكتور");
  const svcObj = services.find((s) => s.id === pending.service_id || s.code === pending.service_code);
  const svcName = svcObj ? (language === "en" ? svcObj.name_en : svcObj.name_ar) : "";
  const knownSalutationName = effectiveRegisteredName || detectedName || patientProfile?.preferred_name || null;

  let replyText = "";
  if (needsContactInfoForBooking) {
    if (effectiveRegisteredName && !effectiveBookingPhone) {
      replyText =
        language === "en"
          ? "Pleasure to meet you, " + effectiveRegisteredName + "! Would you like me to register the booking under this same WhatsApp number, or a different phone number?"
          : dialect === "ar-SA"
            ? "تشرفنا فيك يا أستاذ " + effectiveRegisteredName + "! تحب نسجل الحجز على نفس رقم الواتساب هذا ولا رقم جوال ثاني؟"
            : "تشرفنا بحضرتك يا أستاذ " + effectiveRegisteredName + "! تحب نسجل الحجز على نفس رقم الواتساب ده ولا رقم تليفون تاني؟";
    } else if (!effectiveRegisteredName && effectiveBookingPhone) {
      replyText =
        language === "en"
          ? "Got your phone number! Please share your full name so I can confirm your appointment right away."
          : dialect === "ar-SA"
            ? "تمام طال عمرك سجلت رقم الجوال! ياليت بس ترسل لي الاسم الكريم بالكامل عشان أأكد لك الموعد فوراً"
            : "تمام يا فندم سجلت رقم التليفون! ياريت بس تبعتلي الاسم بالكامل اللي هنسجل بيه الحجز عشان أأكدلك الميعاد فوراً";
    } else {
      replyText =
        language === "en"
          ? "Got it" + (knownSalutationName ? ", " + knownSalutationName : "") + "! I have selected " + timeStr + (svcName ? " for " + svcName : "") + " with " + docName + ".\\nTo finalize and confirm your booking, please share your full name and the phone number you'd like to register with (or say 'use this same number')."
          : dialect === "ar-SA"
            ? "أبشر طال عمرك" + (knownSalutationName ? " يا أستاذ " + knownSalutationName : "") + "! اخترت لك موعد " + timeStr + (svcName ? " لـ " + svcName : "") + " مع " + docName + "\\nعشان أعتمد وأأكد لك الحجز النهائي، ياليت ترسل لي الاسم الكريم بالكامل ورقم الجوال للتسجيل (أو قل لي على نفس الرقم)"
            : "من عيوني" + (knownSalutationName ? " يا أستاذ " + knownSalutationName : " يا فندم") + "! اخترت لحضرتك ميعاد " + timeStr + (svcName ? " لـ " + svcName : "") + " مع " + docName + "\\nعشان أسجل وأأكد الحجز النهائي، ياريت تبعتلي الاسم بالكامل ورقم التليفون اللي تحب نسجل بيه الحجز (أو قولي على نفس الرقم ده)";
    }
  } else {
    replyText =
      language === "en"
        ? "Got it! I have selected " + timeStr + (svcName ? " for " + svcName : "") + " with " + docName + ".\\nWould you like me to confirm it now?"
        : dialect === "ar-SA"
          ? "أبشر طال عمرك، اخترت لك موعد " + timeStr + (svcName ? " لـ " + svcName : "") + " مع " + docName + "\\nتبيني أأكد لك الحجز على هذا الموعد؟"
          : "خلاص تمام، اخترتلك ميعاد " + timeStr + (svcName ? " لـ " + svcName : "") + " مع " + docName + "\\nأأكدلك الحجز على الميعاد ده؟";
  }

  return {
    json: {
      ...event,
      clinic_timezone: zone,
      intent: "slot_selection",
      confidence,
      language,
      dialect,
      needs_human: false,
      should_query_slots: false,
      should_cancel_appointment: false,
      should_confirm_booking: false,
      target_appointment_id: targetApptId || pending?.target_appointment_id || null,
      service_id: null,
      service_code: null,
      provider_id: null,
      requested_from: null,
      requested_to: null,
      slot_closing_text: null,
      should_update: true,
      target_status: null,
      state_patch: { pending_booking: updatedPending },
      patient_profile_patch: profilePatch,
      reply_text: replyText,
    },
  };
}

// Guard against hallucinated confirm_booking or unresolved slot_selection!
if (intent === "confirm_booking" || intent === "slot_selection") {
  if (pendingSlots.length > 0 && !mentionedTimeOutsidePending && !changedServiceFromPending && !/(عايز احجز|ابغي احجز|محتاج احجز|مواعيد)/i.test(normMsg)) {
    // Re-display the active pending slots clearly so the patient can pick 1..N
    const list = pendingSlots
      .map((s, i) => {
        const t = language === "en" ? s.display_time_en : s.display_time_ar;
        const doc = s.provider_name ? (language === "en" ? " with " + s.provider_name : " مع " + s.provider_name) : "";
        return (i + 1) + "- " + t + doc;
      })
      .join("\\n");
    const clarifySlotsReply =
      language === "en"
        ? "Just to make sure I book the exact time you want, please tell me the number or time from these available slots:\\n\\n" + list
        : dialect === "ar-SA"
          ? "عشان أأكد لك الموعد بالضبط، ياليت تختار رقم الموعد أو الساعة اللي تناسبك من هذي المواعيد المتاحة:\\n\\n" + list
          : "عشان أأكدلك الميعاد بالظبط يا فندم، قولي رقم الميعاد أو الساعة اللي تناسبك من المواعيد المتاحة دي:\\n\\n" + list;
    return plainReply(clarifySlotsReply);
  }
  // Otherwise convert to booking_request so we query and display fresh slots from the database!
  intent = Boolean(pending?.is_reschedule) && targetApptId ? "reschedule_request" : "booking_request";
  if (!rangeValid && Boolean(service?.id)) {
    effectiveFrom = new Date(nowMs + 60 * 1000).toISOString();
    effectiveTo = new Date(nowMs + 7 * 24 * 60 * 60 * 1000).toISOString();
    rangeValid = true;
  }
}

// Compound turn detection: if LLM returned faq, but patient explicitly asked to book or see slots in the same message
if (intent === "faq" && /(عايز احجز|عاوز احجز|محتاج احجز|ابغي احجز|ابي احجز|احجزلي|ممكن احجز|عايز ميعاد|ابغي موعد|ايه المواعيد المتاحه|وش المواعيد المتاحه|book an appointment|available slots)/i.test(normMsg) && Boolean(service?.id)) {
  intent = "booking_request";
  if (!rangeValid) {
    effectiveFrom = new Date(nowMs + 60 * 1000).toISOString();
    effectiveTo = new Date(nowMs + 7 * 24 * 60 * 60 * 1000).toISOString();
    rangeValid = true;
  }
}

const needsHuman =
  !isCancelRequest &&
  intent !== "booking_request" &&
  intent !== "reschedule_request" &&
  intent !== "slot_selection" &&
  intent !== "confirm_booking" &&
  (parsed.needs_human === true ||
    intent === "emergency" ||
    intent === "human_handoff" ||
    intent === "medical_question" ||
    isHardEmergency ||
    isHardHandoff ||
    isHardMedical);

const shouldQuerySlots =
  (intent === "booking_request" || intent === "reschedule_request") &&
  !needsHuman &&
  Boolean(service?.id) &&
  rangeValid;

let finalReply = shouldQuerySlots ? aiReply : (aiReply || (language === "en" ? "How can I help you today?" : "أهلاً بيك يا فندم، أقدر أساعدك بإيه النهارده؟"));

// Never allow a reply_text in non-confirm mode to falsely claim the booking was already confirmed in DB!
if (!shouldQuerySlots && !isCancelRequest && /(تم تأكيد حجزك|اتأكد حجزك|أكدت لك الحجز خلاص|your appointment is confirmed)/i.test(finalReply)) {
  finalReply =
    language === "en"
      ? "I'd love to confirm your appointment! Could you let me know which service and time works best for you?"
      : "عنيا ليك يا فندم، تحب نحجز أنهي خدمة وإيه اليوم والوقت المناسب ليك عشان أأكدلك الميعاد؟";
}

// If patient asked a side question (faq) while a pending_booking is active, gently remind them if the AI didn't
if (intent === "faq" && pending && pendingSlots.length > 0 && !/(حجز|ميعاد|موعد|نكمل|تأكد|أأكد|الاسم|رقم|appointment|booking|slot)/i.test(finalReply)) {
  if (pending.selected_slot) {
    const t = language === "en" ? pending.selected_slot.display_time_en : pending.selected_slot.display_time_ar;
    if (pending.awaiting_contact_info && needsContactInfoForBooking) {
      finalReply += language === "en"
        ? "\\n\\nWhenever you're ready to confirm your " + t + " slot, please share your full name and booking phone number!"
        : "\\n\\nوعشان أأكد لحضرتك ميعاد " + t + " اللي اخترناه، ابعتلي بس الاسم بالكامل ورقم التليفون (أو قولي على نفس الرقم ده)";
    } else {
      finalReply += language === "en"
        ? "\\n\\nWould you like me to go ahead and confirm your " + t + " slot?"
        : "\\n\\nتحب أأكدلك الحجز على ميعاد " + t + " اللي اخترناه؟";
    }
  } else {
    finalReply += language === "en"
      ? "\\n\\nWhenever you're ready, just let me know which available time works best for you!"
      : "\\n\\nولو حابب نكمل الحجز، قولي بس رقم الميعاد أو الساعة اللي تناسبك من المواعيد اللي بعتهالك";
  }
}

return {
  json: {
    ...event,
    clinic_timezone: zone,
    intent,
    confidence,
    language,
    dialect,
    needs_human: needsHuman,
    should_query_slots: shouldQuerySlots,
    should_cancel_appointment: isCancelRequest,
    should_confirm_booking: false,
    is_reschedule: intent === "reschedule_request",
    target_appointment_id: targetApptId,
    service_id: shouldQuerySlots ? service.id : null,
    service_code: shouldQuerySlots ? service.code : null,
    service_name_ar: shouldQuerySlots ? service.name_ar : null,
    service_name_en: shouldQuerySlots ? service.name_en : null,
    provider_id: shouldQuerySlots ? (matchedProvider?.id ?? null) : null,
    requested_from: shouldQuerySlots ? effectiveFrom : null,
    requested_to: shouldQuerySlots ? effectiveTo : null,
    slot_closing_text: shouldQuerySlots ? slotClosingText : null,
    should_update: needsHuman || isCancelRequest,
    target_status: needsHuman ? "human" : null,
    state_patch: (needsHuman || isCancelRequest) ? { pending_booking: null } : null,
    patient_profile_patch: profilePatch,
    reply_text: finalReply,
  },
};`;

const FORMAT_SLOT_LIST_JS = `const request = $("Parse AI Output").item.json;
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
  .join("\\n");

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
    .replace(/\\s*(?:سأعرض لك|يمكنك اختيار رقم الموعد|ابعت رقم الموعد)[\\s\\S]*$/i, "")
    .trim();
  const isSpeculativeOrLoading = /(سأبحث عن المواعيد|سأتحقق من المواعيد|أشيك لك|اشيك لك|هشوفلك لو متاح|أبلغك لو متاح|ابلغك لو متاح|لو كان متاح|i will check|checking available|let me check if)/i.test(clean);
  if (!isSpeculativeOrLoading && clean.length > 8) {
    intro = clean + "\\n\\n";
  }
}

const usedFallback = chosen[0]?.exact_match === false;
if (usedFallback && !/مفيش|غير متاح|إجازة|مغلق|أقرب|مش فاضي/i.test(intro)) {
  intro = lang === "en"
    ? "That specific time isn't open right now, so here are the nearest available times for " + svcLabel + ":\\n\\n"
    : dialect === "ar-SA"
      ? "الوقت هذا تحديداً مو فاضي حالياً، وهذي أقرب المواعيد المتاحة لـ " + svcLabel + ":\\n\\n"
      : "الوقت ده تحديداً مش فاضي حالياً، فدي أقرب مواعيد متاحة لـ " + svcLabel + " بعده علطول:\\n\\n";
} else if (!intro) {
  if (isExactRequestedTimeMatch) {
    const t0 = lang === "en" ? enrichedSlots[0].display_time_en : enrichedSlots[0].display_time_ar;
    const d0 = enrichedSlots[0].provider_name || "";
    intro = lang === "en"
      ? "Great news! " + t0 + " with " + d0 + " for " + svcLabel + " is available:\\n\\n"
      : dialect === "ar-SA"
        ? "أبشر طال عمرك، موعد " + t0 + " مع " + d0 + " لـ " + svcLabel + " متاح:\\n\\n"
        : "تمام يا فندم، ميعاد " + t0 + " مع " + d0 + " لـ " + svcLabel + " متاح، ودي المواعيد المتاحة:\\n\\n";
  } else {
    intro = lang === "en"
      ? "Here are the nearest available times for " + svcLabel + ":\\n\\n"
      : dialect === "ar-SA"
        ? "هذي أقرب المواعيد المتاحة حالياً لـ " + svcLabel + ":\\n\\n"
        : "دي أقرب المواعيد المتاحة حالياً لـ " + svcLabel + ":\\n\\n";
  }
}

let closingLine = "";
if (preSelectedSlot) {
  const tSel = lang === "en" ? preSelectedSlot.display_time_en : preSelectedSlot.display_time_ar;
  closingLine = lang === "en"
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
    reply_text: intro + list + "\\n\\n" + closingLine,
  },
};`;

module.exports = {
  PARSE_AI_OUTPUT_JS,
  FORMAT_SLOT_LIST_JS,
};
