#!/usr/bin/env node
// ClinicOS receptionist evaluation harness.
//
// Sends every case in evals/cases.jsonl to the REAL model with the REAL system prompt
// (prompts/receptionist-system-prompt.xml) and a user payload shaped exactly like the one the
// "AI Receptionist" node builds, then scores the answers with deterministic checks.
//
//   node evals/run_eval.js --dry           # offline: validates cases + prompt assembly, no network, no key
//   OPENAI_API_KEY=sk-... node evals/run_eval.js
//   OPENAI_API_KEY=... OPENAI_MODEL=gpt-4.1 EVAL_RUNS=3 node evals/run_eval.js --only emg,bk
//
// Run it BEFORE and AFTER any prompt change and compare the two summaries. The key is read from the
// environment only; results are written to evals/results/ (git-ignored). Never commit a key.
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const args = process.argv.slice(2);
const DRY = args.includes('--dry');
const onlyIdx = args.indexOf('--only');
const ONLY = onlyIdx >= 0 ? String(args[onlyIdx + 1] || '').split(',').filter(Boolean) : [];
const MODEL = process.env.OPENAI_MODEL || 'gpt-4.1';
const TEMPERATURE = Number(process.env.OPENAI_TEMPERATURE ?? 0.3);
const RUNS = Math.max(1, Number(process.env.EVAL_RUNS || 1));
const CONCURRENCY = Math.max(1, Number(process.env.EVAL_CONCURRENCY || 4));

const INTENTS = ['emergency', 'human_handoff', 'medical_question', 'cancel_request', 'confirm_booking',
  'reschedule_request', 'slot_selection', 'booking_request', 'faq', 'clarify'];

const prompt = fs.readFileSync(path.join(ROOT, 'prompts', 'receptionist-system-prompt.xml'), 'utf8').replace(/\r\n/g, '\n');
const snapshot = JSON.parse(fs.readFileSync(path.join(__dirname, 'clinic_snapshot.fixture.json'), 'utf8'));
const cases = fs.readFileSync(path.join(__dirname, 'cases.jsonl'), 'utf8')
  .split('\n').map((l) => l.trim()).filter(Boolean)
  .map((l, i) => {
    try { return JSON.parse(l); } catch (e) { throw new Error(`cases.jsonl line ${i + 1}: invalid JSON (${e.message})`); }
  });

// ---------- case validation (runs in --dry and before every real run) ----------
function validateCases() {
  const seen = new Set();
  const codes = new Set(snapshot.services.map((s) => s.code));
  for (const c of cases) {
    if (!c.id || seen.has(c.id)) throw new Error(`duplicate or missing case id: ${c.id}`);
    seen.add(c.id);
    if (typeof c.message !== 'string' || !c.message) throw new Error(`${c.id}: message required`);
    if (!c.expect || typeof c.expect !== 'object') throw new Error(`${c.id}: expect required`);
    for (const i of c.expect.intent_in || []) if (!INTENTS.includes(i)) throw new Error(`${c.id}: unknown intent ${i}`);
    for (const k of ['service_code', 'service_code_not']) {
      if (c.expect[k] && !codes.has(c.expect[k])) throw new Error(`${c.id}: ${k} ${c.expect[k]} not in fixture`);
    }
    for (const k of ['reply_must_match', 'reply_must_not_match']) {
      for (const r of c.expect[k] || []) new RegExp(r, 'u');
    }
  }
}

// ---------- the user payload, mirroring the "AI Receptionist" node ----------
function buildUserPayload(c) {
  const mem = c.memory || {};
  return JSON.stringify({
    current_datetime: snapshot.now_local,
    patient_memory: {
      name: mem.name || '',
      registered_name: mem.registered_name || null,
      booking_phone: mem.booking_phone || null,
      gender: mem.gender || 'unknown',
      preferred_dialect: mem.preferred_dialect || 'ar-EG',
      is_returning_patient: Boolean(mem.is_returning_patient),
      total_visits_count: Number(mem.total_visits_count || 0),
      last_service_code: mem.last_service_code || null,
      last_service_name: mem.last_service_name || null,
      last_provider_id: mem.last_provider_id || null,
      last_provider_name: mem.last_provider_name || null,
      last_cancelled_appointment: mem.last_cancelled_appointment || null,
      recent_appointments: mem.recent_appointments || [],
      notes: mem.notes || '',
    },
    conversation_status: 'bot',
    message_type: c.message_type || 'text',
    untrusted_patient_message: '<patient_message>' + c.message + '</patient_message>',
    clinic_snapshot: snapshot,
    upcoming_appointments: c.upcoming || [],
    pending_booking: c.pending_booking || null,
    untrusted_conversation_history: c.history || [],
  });
}

// ---------- checks ----------
const AR_DIGITS = '٠١٢٣٤٥٦٧٨٩';
const norm = (s) => String(s ?? '').replace(/[٠-٩]/g, (d) => String(AR_DIGITS.indexOf(d))).replace(/,/g, '');

function check(c, out, raw) {
  const fails = [];
  const e = c.expect;
  if (!out || typeof out !== 'object' || Array.isArray(out)) return ['G1 invalid JSON object'];
  if (!INTENTS.includes(out.intent)) fails.push(`G2 bad intent "${out.intent}"`);
  const reply = typeof out.reply_text === 'string' ? out.reply_text : '';
  if (!reply.trim()) fails.push('G3 empty reply_text');
  if (/\*\*|^\s*#{1,3}\s|^\s*[-•]\s|^\s*\d+[.)]\s/m.test(reply)) fails.push('G4 markdown/list in reply');
  if (/تم\s+(تأكيد|إلغاء|الإلغاء|الحجز)|has been (booked|confirmed|cancel)/i.test(reply)) fails.push('G5 claims a booking result');
  const corpus = norm(JSON.stringify(snapshot) + c.message + JSON.stringify(c.history || []) +
    JSON.stringify(c.pending_booking || {}) + JSON.stringify(c.upcoming || []) + JSON.stringify(c.memory || {}));
  for (const n of norm(reply).match(/\d{2,}/g) || []) {
    if (!corpus.includes(n)) { fails.push(`G6 number "${n}" not in the data`); break; }
  }
  const codes = snapshot.services.map((s) => s.code);
  const docs = snapshot.providers.map((p) => p.id);
  if (out.service_code != null && !codes.includes(out.service_code)) fails.push(`G7 invented service_code ${out.service_code}`);
  if (out.doctor_id != null && !docs.includes(out.doctor_id)) fails.push(`G7 invented doctor_id ${out.doctor_id}`);
  for (const k of ['requested_from', 'requested_to']) {
    if (out[k] != null && !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$/.test(String(out[k]))) fails.push(`G8 ${k} not ISO with offset`);
  }

  if (e.intent_in && !e.intent_in.includes(out.intent)) fails.push(`intent ${out.intent} not in [${e.intent_in}]`);
  if (e.needs_human != null && Boolean(out.needs_human) !== e.needs_human) fails.push(`needs_human ${out.needs_human}`);
  if (e.is_urgent != null && Boolean(out.is_urgent) !== e.is_urgent) fails.push(`is_urgent ${out.is_urgent}`);
  if (e.language && out.language !== e.language) fails.push(`language ${out.language}`);
  if (e.dialect && out.dialect !== e.dialect) fails.push(`dialect ${out.dialect}`);
  if (e.service_code && out.service_code !== e.service_code) fails.push(`service_code ${out.service_code}`);
  if (e.service_code_not && out.service_code === e.service_code_not) fails.push(`service_code must not be ${e.service_code_not}`);
  if (e.service_code_null && out.service_code != null) fails.push(`service_code should be null, got ${out.service_code}`);
  if (e.target_appointment_id && out.target_appointment_id !== e.target_appointment_id) fails.push(`target_appointment_id ${out.target_appointment_id}`);
  if (e.selected_slot_index != null && Number(out.selected_slot_index) !== e.selected_slot_index) fails.push(`selected_slot_index ${out.selected_slot_index}`);
  if (e.requested_from_prefix && !String(out.requested_from || '').startsWith(e.requested_from_prefix)) fails.push(`requested_from ${out.requested_from}`);
  if (e.requested_offset && out.requested_from && !String(out.requested_from).endsWith(e.requested_offset)) fails.push(`offset of ${out.requested_from}`);
  if (e.patient_name_detected_null && out.patient_name_detected != null) fails.push(`patient_name_detected should be null, got ${out.patient_name_detected}`);
  if ('lead_timing' in e && (out.lead_timing ?? null) !== e.lead_timing) fails.push(`lead_timing ${out.lead_timing}`);
  if ('lead_budget_band' in e && (out.lead_budget_band ?? null) !== e.lead_budget_band) fails.push(`lead_budget_band ${out.lead_budget_band}`);
  if (e.max_chars && reply.length > e.max_chars) fails.push(`reply ${reply.length} chars > ${e.max_chars}`);
  for (const r of e.reply_must_match || []) if (!new RegExp(r, 'u').test(reply)) fails.push(`reply missing /${r}/`);
  for (const r of e.reply_must_not_match || []) if (new RegExp(r, 'iu').test(reply)) fails.push(`reply contains /${r}/`);
  return fails;
}

// ---------- model call ----------
async function callModel(c) {
  const body = {
    model: MODEL,
    temperature: TEMPERATURE,
    response_format: { type: 'json_object' },
    messages: [
      { role: 'system', content: prompt },
      { role: 'user', content: buildUserPayload(c) },
    ],
  };
  for (let attempt = 1; attempt <= 4; attempt++) {
    const res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${process.env.OPENAI_API_KEY}` },
      body: JSON.stringify(body),
    });
    if (res.status === 429 || res.status >= 500) { await new Promise((r) => setTimeout(r, 1500 * attempt)); continue; }
    if (!res.ok) throw new Error(`OpenAI HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const j = await res.json();
    return { text: j.choices?.[0]?.message?.content ?? '', usage: j.usage || {} };
  }
  throw new Error('OpenAI: too many retries');
}

async function main() {
  validateCases();
  let list = cases;
  if (ONLY.length) list = cases.filter((c) => ONLY.some((p) => c.id.startsWith(p) || (c.tags || []).includes(p)));
  if (DRY) {
    const sizes = list.map((c) => buildUserPayload(c).length);
    console.log(`DRY RUN OK: ${list.length} cases valid, prompt ${prompt.length} chars, user payload ${Math.min(...sizes)}..${Math.max(...sizes)} chars. No network used.`);
    return;
  }
  if (!process.env.OPENAI_API_KEY) { console.error('Set OPENAI_API_KEY in the environment (never in a file).'); process.exit(2); }

  const jobs = [];
  for (const c of list) for (let r = 1; r <= RUNS; r++) jobs.push({ c, r });
  const results = [];
  let next = 0;
  async function worker() {
    while (next < jobs.length) {
      const { c, r } = jobs[next++];
      let out = null; let raw = ''; let fails; let usage = {};
      try {
        const resp = await callModel(c); raw = resp.text; usage = resp.usage;
        try { out = JSON.parse(raw); } catch { out = null; }
        fails = check(c, out, raw);
      } catch (err) { fails = [`ERROR ${err.message}`]; }
      results.push({ id: c.id, run: r, tags: c.tags, pass: fails.length === 0, fails, reply: out?.reply_text ?? null, out, usage });
      process.stdout.write(fails.length ? 'F' : '.');
    }
  }
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  console.log('\n');

  results.sort((a, b) => a.id.localeCompare(b.id) || a.run - b.run);
  const passed = results.filter((x) => x.pass).length;
  const jsonOk = results.filter((x) => x.out && typeof x.out === 'object').length;
  const firstWords = results.map((x) => String(x.reply || '').trim().split(/\s+/)[0]).filter(Boolean);
  const freq = {}; for (const w of firstWords) freq[w] = (freq[w] || 0) + 1;
  const [topWord, topCount] = Object.entries(freq).sort((a, b) => b[1] - a[1])[0] || ['-', 0];
  const lens = results.map((x) => String(x.reply || '').length).filter(Boolean).sort((a, b) => a - b);
  const byTag = {};
  for (const x of results) for (const t of x.tags || []) { (byTag[t] ||= { p: 0, n: 0 }); byTag[t].n++; if (x.pass) byTag[t].p++; }

  for (const x of results.filter((y) => !y.pass)) console.log(`FAIL ${x.id}#${x.run}: ${x.fails.join(' | ')}\n     reply: ${String(x.reply ?? '').slice(0, 140)}`);
  console.log('\n==== SUMMARY ====');
  console.log(`model=${MODEL} temperature=${TEMPERATURE} runs=${RUNS}`);
  console.log(`passed ${passed}/${results.length} (${((passed / results.length) * 100).toFixed(1)}%)   valid JSON ${jsonOk}/${results.length}`);
  console.log(`most common first word: "${topWord}" in ${topCount}/${firstWords.length} replies (${((topCount / Math.max(1, firstWords.length)) * 100).toFixed(0)}%)`);
  console.log(`reply length chars: median ${lens[Math.floor(lens.length / 2)] ?? 0}, max ${lens[lens.length - 1] ?? 0}`);
  console.log('by tag: ' + Object.entries(byTag).sort().map(([t, v]) => `${t} ${v.p}/${v.n}`).join(', '));

  fs.mkdirSync(path.join(__dirname, 'results'), { recursive: true });
  const file = path.join(__dirname, 'results', `eval-${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
  fs.writeFileSync(file, JSON.stringify({ model: MODEL, temperature: TEMPERATURE, runs: RUNS, passed, total: results.length, results }, null, 2));
  console.log(`results saved: ${path.relative(ROOT, file)}`);
  process.exit(passed === results.length ? 0 : 1);
}

main().catch((e) => { console.error(e.message); process.exit(2); });
