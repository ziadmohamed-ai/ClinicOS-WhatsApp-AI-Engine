const first = $input.first()?.json ?? {};
let fallbackResult = null;
if (!first.result || typeof first.result !== "object") {
  try {
    if (typeof $ === "function") {
      fallbackResult = $("Verify & Save Event").first()?.json?.result ?? null;
    }
  } catch {
    fallbackResult = null;
  }
}
const result =
  first.result && typeof first.result === "object"
    ? first.result
    : fallbackResult && typeof fallbackResult === "object"
      ? fallbackResult
      : {};
if (result.ok !== true || !Array.isArray(result.messages)) {
  return [];
}

const actionable = result.messages.filter(
  (m) =>
    m &&
    typeof m === "object" &&
    m.opted_out !== true &&
    !m.opt_out_scope &&
    m.conversation_status !== "human"
);

return actionable.map((event) => {
  const lang = event.language === "en" ? "en" : "ar";
  const state = event.conversation_state && typeof event.conversation_state === "object" ? event.conversation_state : {};
  const pending = state.pending_booking && typeof state.pending_booking === "object" ? state.pending_booking : null;
  const rawText = String(event.body ?? "").trim();
  const msgKey = String(event.provider_message_id ?? event.message_id ?? "");
  const mType = String(event.message_type ?? "text").toLowerCase();
  const isVoice = mType === "audio" || mType === "voice";

  // Non-text messages (location, files, a voice note we could not transcribe) are no longer answered
  // with a canned sentence. They go to the AI as a neutral tag so it answers from clinic_snapshot,
  // in the patient's own dialect.
  const nonTextTag = rawText
    ? null
    : isVoice
      ? "[voice_unclear]"
      : mType === "location"
        ? "[location]"
        : ["image", "document", "video", "sticker"].includes(mType)
          ? "[" + mType + "]"
          : "[empty]";

  const expiry = pending ? Date.parse(String(pending.expires_at ?? "")) : NaN;
  const cleanState = (pending && (!Number.isFinite(expiry) || expiry < Date.now()))
    ? { ...state, pending_booking: null }
    : state;

  return {
    json: {
      ...event,
      conversation_state: cleanState,
      provider_message_id: msgKey,
      ...(nonTextTag ? { body: nonTextTag } : {}),
      route: "ai",
    },
  };
});