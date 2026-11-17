---
name: open-task-pr
description: Open the pull request for a ClinicOS Lead-to-Visit task (T1..T10) in the required format, then stop and wait for review. Use when a task's code and tests are done and verify passed.
---

# open-task-pr

1. Branch name: `l2v/T<n>-<short-name>`, created from the latest `l2v-addon` (`git fetch` and merge first). Never commit to `main` or `l2v-addon` directly.
2. Push the branch and open the PR **targeting `l2v-addon`** (not `main`).
3. PR title: `T<n>: <what>`. PR body:

```
## What changed
<files, one line each>
## Test output
<paste from the verify skill>
## Self-review
<one line per item of the self-review skill>
## Risks / not verified
<n8n runtime, Meta, real LLM, anything else>
## Questions for the reviewer
<decisions you did not take on your own>
```
4. If a reviewer asks for changes, push to the **same branch**, update the PR body, and stop again.
5. After opening or updating the PR: **stop**. Do not start the next task until the reviewer says so.
