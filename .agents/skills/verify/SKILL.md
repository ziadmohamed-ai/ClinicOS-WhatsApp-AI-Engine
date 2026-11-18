---
name: verify
description: Run the full ClinicOS verification (JS test suite, workflow validator, SQL tests, generated-file sync) and print the results in pull-request format. Use before opening or updating any pull request, and whenever you changed nodes/, prompts/, scripts/, workflow/ or database/.
---

# verify

Run these from the repository root. Run every step that exists in this checkout; skip a step only if its file does not exist yet.

1. `node tests/test_270_messages.js` — expect `N/N PASSED (0 FAILED)`. The total only ever grows.
2. If `tests/validate_workflow.js` exists: `node tests/validate_workflow.js workflow/clinicos-main-engine.json workflow/clinicos-main-engine.l2v.json` — both lines must say `Workflow valid`.
3. `./tests/l2v/run_local.sh` — must end with `L2V SQL tests: OK`. (Scratch Postgres cluster; never a real database.)
3b. `./tests/clean_install_test.sh` — must end with `Clean install test: OK`. (Empty scratch Postgres cluster running `database/01..05b` in order with `ON_ERROR_STOP` and default `check_function_bodies`, plus `pg_proc` drift check against workflow Postgres queries.)
4. If `scripts/build_l2v_workflow.js` exists: run it, then `git status --short workflow/`. **No uncommitted change may appear.** If one does, the generated workflow files were stale: commit them.
5. `git diff --stat <base-branch>...HEAD` — every changed file must belong to the current task. List anything unexpected and justify it or revert it.

Report in this shape (paste real output, never a summary from memory):

```
Test output
  JS suite:   <summary line>
  Validator:  <lines>
  SQL:        <last NOTICE lines + final line>
  Clean install: <final lines>
  Generated files in sync: yes/no
Files changed: <list>
```

If any step fails, fix it before opening the PR. Do not skip, weaken or delete a test to get green.

## Prompt changes (`prompts/receptionist-system-prompt.xml`)

After `node scripts/build_l2v_workflow.js`, also run `node evals/run_eval.js --dry` (offline, must print DRY RUN OK). Antigravity has no OpenAI key: state in the PR that the live eval was NOT run and must be run by the owner before and after (`OPENAI_API_KEY=... node evals/run_eval.js`). Never claim a prompt change "improves" replies without that comparison.
