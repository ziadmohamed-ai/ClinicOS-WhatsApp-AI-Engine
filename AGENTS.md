# AGENTS.md — rules for any coding agent working on ClinicOS

ClinicOS is a WhatsApp receptionist for clinics (n8n + Supabase Postgres + OpenAI). Clinics pay for it,
so a wrong booking or a wrong message to a patient is a real cost. Work small, test everything, report honestly.

## Hard rules
1. **Never commit to `main`.** One branch per task: `l2v/T<n>-<short-name>`, one pull request per task.
2. **Never weaken or delete an existing test to make it pass.** The test count may only grow. Report counts before and after.
3. **No secrets, no real phone numbers, no real clinic data** in the repo. Use placeholders (`YOUR_POSTGRES_CREDENTIAL_ID`, `+20 100 000 0000`).
4. **Do not touch any production Supabase project or n8n instance, and do not call Meta or OpenAI.** Everything is verified locally.
5. **Reply wording policy (do not regress):** facts (times, doctors, lists, phones) come from code; phrasing comes from the AI.
   Do not add new fixed Arabic/English sentences to the reply path. A fixed sentence is allowed only as a *fallback* behind `aiWording(...)`.
6. If a task needs a decision that is not in `docs/l2v/TASKS.md`, **stop and write the question in the PR description** instead of guessing.

## How to verify (run all of these before opening a PR)
```bash
node tests/test_270_messages.js        # baseline today: 281/283. Failures #10 and #11 are known and pre-existing (see T1)
./tests/l2v/run_local.sh               # SQL tests for the Lead-to-Visit add-on on a scratch Postgres (prints "L2V SQL tests: OK")
```
Any new JS logic goes in `nodes/*.js` (plain JavaScript, no template-literal escaping) with tests; any new SQL goes in
`database/` with tests in `tests/l2v/l2v_addon_test.sql`.

## Code conventions
- **SQL:** `SECURITY DEFINER` functions use `set search_path = ''` and fully qualified names; `execute` is granted only to
  `clinicos_api_owner` and `service_role`; RLS stays enabled; every WhatsApp message goes through `public.enqueue_message`.
- **n8n JSON:** change only the nodes a task names. A Postgres node's output *replaces* the item, so anything that must keep the
  original data goes in a side branch, or is re-merged with `$('Node Name').item.json`. A workflow's name must start with
  `ClinicOS` (the error logger rejects other names). Keep credential ids as placeholders.
- **Phone format:** ClinicOS stores `+` + digits in `contacts.phone_e164`. Staff numbers must use the same format.
- **Defaults are for Egypt:** timezone `Africa/Cairo`, UTC offset `+02:00`, language `ar`. Never hard-code a city, address, clinic name or ambulance number.

## Pull request format
```
What changed (files, one line each)
Test output (paste the summary lines of both commands above)
Risks / what I did NOT verify
Questions for the reviewer
```
Claude reviews each PR: it fetches the branch, re-runs both commands, reads the diff against these rules, and replies with findings.
