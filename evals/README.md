# Receptionist evals

Measures the REAL prompt (`prompts/receptionist-system-prompt.xml`) against the REAL model on ~50 Egyptian/Gulf/English patient messages, with deterministic checks (valid JSON, intent, no markdown, no invented numbers, service/doctor ids exist in the snapshot, date offset, emergency/handoff flags, no "booking confirmed" claims, reply length, opening-word repetition).

```bash
node evals/run_eval.js --dry                              # offline sanity check, no key, no network
OPENAI_API_KEY=sk-... node evals/run_eval.js              # full run (key from the environment only)
OPENAI_API_KEY=... EVAL_RUNS=3 node evals/run_eval.js --only emg,bk
```

Env: `OPENAI_MODEL` (default gpt-4.1), `OPENAI_TEMPERATURE` (0.3), `EVAL_RUNS`, `EVAL_CONCURRENCY`.

Rule: run it before and after every prompt change and compare the SUMMARY block. A prompt change that lowers the pass rate or raises the repeated-opening-word share is rejected. Results go to `evals/results/` (git-ignored). The fixture clinic is fake; "today" is Wednesday 2026-11-18.
