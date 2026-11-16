// Upgraded ClinicOS Node Logic Module (for both n8n workflow injection and 200-message evaluation)

const fs = require('fs');
const path = require('path');
const readNode = (name) => fs.readFileSync(path.join(__dirname, '..', 'nodes', name), 'utf8');

// Node code lives in nodes/*.js (plain JavaScript, no template-literal escaping).
const PARSE_TURN_AND_STATE_JS = readNode('parse_turn_and_state.js');

const AI_RECEPTIONIST_INPUT_TEXT = `={{ (() => {
  const ev = $json.event ?? {};
  const snap = $json.clinic_snapshot ?? {};
  const fresh = $json.fresh_conversation ?? {};
  const prof = $json.patient_profile && typeof $json.patient_profile === "object" ? $json.patient_profile : {};
  const state = (fresh.state && typeof fresh.state === "object") ? fresh.state : (ev.conversation_state ?? {});
  const status = fresh.status || ev.conversation_status || "bot";

  const rawName = String(prof.preferred_name || ev.contact_name || "").trim();
  const firstToken = rawName.split(/\\s+/)[0] || "";
  const enToArMap = {
    ziad: "زياد", zyad: "زياد", zeyad: "زياد", ahmed: "أحمد", ahmad: "أحمد",
    mohamed: "محمد", mohammad: "محمد", muhammad: "محمد", ali: "علي", omar: "عمر",
    khaled: "خالد", khalid: "خالد", saad: "سعد", fahd: "فهد", fahad: "فهد",
    faisal: "فيصل", salman: "سلمان", sultan: "سلطان", waleed: "وليد", walid: "وليد",
    yasser: "ياسر", karim: "كريم", kareem: "كريم", mostafa: "مصطفى", mustafa: "مصطفى",
    mahmoud: "محمود", ibrahim: "إبراهيم", youssef: "يوسف", yusef: "يوسف",
    hassan: "حسن", hussein: "حسين", abdullah: "عبدالله", tarek: "طارق", tariq: "طارق",
    sara: "سارة", sarah: "سارة", fatima: "فاطمة", fatma: "فاطمة", maryam: "مريم", mariam: "مريم",
    nour: "نور", noor: "نور", reem: "ريم", layan: "ليان", dina: "دينا", rana: "رنا",
    huda: "هدى", yasmin: "ياسمين", yasmine: "ياسمين", nada: "ندى", salma: "سلمى",
    heba: "هبة", aisha: "عائشة", zainab: "زينب", eman: "إيمان", marwa: "مروة",
    shahd: "شهد", farah: "فرح", dana: "دانة", jana: "جنى", malak: "ملك", rawan: "روان",
    mona: "منى", hend: "هند", mai: "مي", aya: "آية", amira: "أميرة"
  };
  const cleanFirstName = enToArMap[firstToken.toLowerCase()] || firstToken;

  const femaleNames = /^(سارة|ساره|فاطمة|فاطمه|مريم|نور|نورا|ريم|ليان|هند|منى|مني|دينا|رنا|هدى|هدي|ياسمين|ندى|ندي|مي|مى|آية|ايه|سلمى|سلمي|هبة|هبه|عائشة|عائشه|خديجة|خديجه|زينب|حنان|إيمان|ايمان|شيماء|أسماء|اسماء|دعاء|مروة|مروه|رحمة|رحمه|سحر|رغد|لجين|جود|نوف|دانة|دانه|شهد|فرح|حلا|جنى|جني|ملك|حبيبة|حبيبه|روان|نورهان|سندس|هاجر|اميرة|أميرة|فريدة|فريده|sara|sarah|fatima|maryam|nour|reem|layan|dina|rana|huda|yasmin|nada|salma|heba|aisha|khadija|zainab|eman|marwa|shahd|farah|dana|jana|malak|rawan)$/i;
  const maleNames = /^(زياد|أحمد|احمد|محمد|علي|على|عمر|عمرو|خالد|سعد|سعيد|فهد|فيصل|سلمان|سلطان|تركي|نايف|وليد|ياسر|ماجد|طارق|كريم|مصطفى|مصطفي|محمود|إبراهيم|ابراهيم|يوسف|يحيى|يحيي|آدم|ادم|حسن|حسين|عبدالله|عبد الله|عبدالرحمن|عبد الرحمن|عبدالعزيز|عبد العزيز|عثمان|أنس|انس|بلال|حمزة|حمزه|سامي|سامى|رامي|رامى|هادي|هادى|إياد|اياد|أمير|امير|أدهم|ادهم|أيمن|ايمن|حسام|هشام|إسلام|اسلام|ziad|ahmed|mohamed|ali|omar|khaled|saad|fahd|faisal|salman|waleed|yasser|karim|mostafa|mahmoud|ibrahim|youssef|adam|hassan|hussein|abdullah)$/i;
  const gender = maleNames.test(cleanFirstName) || maleNames.test(firstToken) ? "male" : (femaleNames.test(cleanFirstName) || femaleNames.test(firstToken) ? "female" : null);

  const zone = snap.timezone || "Asia/Riyadh";
  const fmtAr = new Intl.DateTimeFormat("ar-EG-u-nu-latn", { timeZone: zone, weekday: "long", day: "numeric", month: "long", hour: "numeric", minute: "2-digit", hour12: true });
  const fmtEn = new Intl.DateTimeFormat("en-GB", { timeZone: zone, weekday: "short", day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit", hour12: true });
  const upcoming = Array.isArray($json.upcoming_appointments)
    ? $json.upcoming_appointments.map((a) => {
        const t = a.starts_at_utc || a.starts_at;
        return {
          appointment_id: a.appointment_id || a.id,
          service_code: a.service_code,
          service: a.service_name_ar || a.service_name_en || a.service_name || a.service,
          doctor: a.doctor_name || a.provider_name || a.doctor,
          starts_at: t,
          display_time_ar: t ? fmtAr.format(new Date(t)) : "",
          display_time_en: t ? fmtEn.format(new Date(t)) : "",
        };
      })
    : [];

  return JSON.stringify({
    current_datetime: snap.now_local,
    patient_memory: {
      name: cleanFirstName || rawName,
      registered_name: prof.registered_name || null,
      booking_phone: prof.booking_phone || null,
      gender,
      preferred_dialect: prof.preferred_dialect || "ar-EG",
      is_returning_patient: Boolean(prof.is_returning_patient),
      total_visits_count: Number(prof.total_visits_count || 0),
      last_service_code: prof.last_service_code || null,
      last_service_name: prof.last_service_name || null,
      last_provider_id: prof.last_provider_id || null,
      last_provider_name: prof.last_provider_name || null,
      last_cancelled_appointment: prof.last_cancelled_appointment || null,
      recent_appointments: prof.recent_appointments || [],
      notes: prof.notes || "",
    },
    conversation_status: status,
    message_type: ev.message_type === "voice" ? "audio" : ev.message_type,
    untrusted_patient_message: "<patient_message>" + String(ev.body ?? "") + "</patient_message>",
    clinic_snapshot: snap,
    upcoming_appointments: upcoming,
    pending_booking: state.pending_booking ?? null,
    untrusted_conversation_history: $json.conversation_context ?? [],
  });
})() }}`;

// The system prompt lives in prompts/receptionist-system-prompt.xml; n8n expression mode needs the leading '='.
const AI_RECEPTIONIST_SYSTEM_PROMPT = '=' + fs.readFileSync(path.join(__dirname, '..', 'prompts', 'receptionist-system-prompt.xml'), 'utf8');

module.exports = {
  PARSE_TURN_AND_STATE_JS,
  AI_RECEPTIONIST_INPUT_TEXT,
  AI_RECEPTIONIST_SYSTEM_PROMPT,
};
