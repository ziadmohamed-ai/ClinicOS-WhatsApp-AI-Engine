---
name: self-review
description: Red-team your own change before opening a pull request. A checklist of the defects found in earlier ClinicOS reviews (stale generated code, NULL at the SQL boundary, repeat calls, fail-open, n8n pairing, tests that cannot fail). Use after the code works and before the verify skill.
---

# self-review

Every item below was a real defect caught in review. Check each one against your diff and write one line per item in the PR ("checked: <how>").

1. **Generated files are stale.** If you changed `nodes/*.js` or `prompts/*`, the workflow JSON must be regenerated and committed. A green unit test does not prove the workflow contains your change: grep the JSON for the new field.
2. **NULL / empty / junk at every boundary.** For each new SQL function parameter and each value the n8n expression can pass, test `NULL`, empty string, the string `"null"`, a 5000-character string, and wrong type. Check `NOT NULL` columns: passing an explicit `NULL` overrides a column default.
3. **Repeat calls.** Assume every function runs again on every message of the same patient. Test calling it twice, and calling it again after a terminal state (booked, escalated chain exhausted, lead closed). It must not create a second assignment or a second WhatsApp message.
4. **Fail-open.** The add-on must never stop a patient from getting a reply. A failing add-on node must continue (`onError: continueRegularOutput`) and downstream code must treat missing add-on data as "not staff, no lead".
5. **n8n pairing.** `$('Node').item` throws when pairing is lost. Use separate try/catch blocks and `.all()[$itemIndex]`; never `.first()` for per-item data. A Postgres node's output replaces the item, so keep original data via a named reference or a side branch.
6. **Safety suppression.** Anything that turns a conversation into a sales lead must be `null` for emergency, complaint/human-handoff, medical and prompt-injection turns. Any AI-provided value that reaches the database is validated against a fixed list.
7. **No new fixed sentences in the reply path.** Patient-facing wording comes from the AI behind `aiWording`; a fixed sentence is only a fallback.
8. **A test must be able to fail.** For every new test or validator, break the thing it protects (revert the fix, edit the query, remove a connection) and confirm the test goes red. Validators need at least five such mutations. A validator that only checks structure of a file passed on the command line is not testing the real file.
9. **Scope.** Run `git diff --stat`; every file must belong to your task. Do not "improve" neighbouring code.
10. **Say what you did not verify.** n8n runtime, Meta delivery and a real LLM are never exercised here. Write that in the PR.
