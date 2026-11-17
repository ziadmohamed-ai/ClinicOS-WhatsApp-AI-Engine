#!/usr/bin/env bash
# Runs a full clean install (database/01, 02, 02a, 03, 04, 05, 05b) on an EMPTY scratch Postgres
# with ON_ERROR_STOP=1 and default check_function_bodies=on, then verifies every public.<fn>(...)
# call in workflow/clinicos-main-engine.json and workflow/clinicos-main-engine.l2v.json exists in pg_proc
# with a matching argument count.
#
# Optional flags / env:
#   --seed <path>          override seed SQL file (default: database/04_seed_data.sql)
#   --clinic-id <uuid>     pass -v clinic_id=<uuid> to psql (used from T9 onwards)
#   CLINICOS_SKIP_02A=1    skip database/02a_live_sync_profile_and_slots.sql (mutation test)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SEED_OVERRIDE=""
CLINIC_ID_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --seed)
      SEED_OVERRIDE="$2"
      shift 2
      ;;
    --clinic-id)
      CLINIC_ID_ARG="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if ls -d /usr/lib/postgresql/*/bin >/dev/null 2>&1; then
  PGBIN="$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)"
elif command -v initdb >/dev/null 2>&1; then
  PGBIN="$(dirname "$(command -v initdb)")"
else
  echo "ERROR: PostgreSQL binaries (initdb/pg_ctl/psql) not found" >&2
  exit 1
fi

PORT="${CLINICOS_CLEAN_PGPORT:-55433}"
IS_WIN=0
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*) IS_WIN=1 ;;
esac

to_mixed_path() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd "$p" && pwd -W)
  else
    local d b
    d="$(cd "$(dirname "$p")" && pwd -W)"
    b="$(basename "$p")"
    printf '%s/%s\n' "$d" "$b"
  fi
}

to_bslash_path() {
  to_mixed_path "$1" | tr '/' '\\'
}

if [ "$IS_WIN" -eq 1 ]; then
  REPO_PG="$(to_mixed_path "$REPO")"
  WORK_POSIX="$(mktemp -d "${TMPDIR:-/tmp}/clinicos_clean.XXXXXX")"
  rm -rf "$WORK_POSIX"
  mkdir -p "$WORK_POSIX"
  WORK_PG="$(to_mixed_path "$WORK_POSIX")"
  WF_SQL_POSIX="$(mktemp "${TMPDIR:-/tmp}/clinicos_wf_checks.XXXXXX.sql")"
  WF_SQL_PG="$(to_mixed_path "$WF_SQL_POSIX")"
  EMPTY_SQL_POSIX="$(mktemp "${TMPDIR:-/tmp}/clinicos_empty.XXXXXX.sql")"
  EMPTY_SQL_PG="$(to_mixed_path "$EMPTY_SQL_POSIX")"
else
  REPO_PG="$REPO"
  if [ "$(id -u)" = 0 ] && [ -d /var/lib/postgresql ]; then
    WORK_POSIX="/var/lib/postgresql/clinicos_clean_$$"
  else
    WORK_POSIX="$(mktemp -d "${TMPDIR:-/tmp}/clinicos_clean.XXXXXX")"
    rm -rf "$WORK_POSIX"
  fi
  WORK_PG="$WORK_POSIX"
  WF_SQL_POSIX="$(mktemp "${TMPDIR:-/tmp}/clinicos_wf_checks.XXXXXX.sql")"
  WF_SQL_PG="$WF_SQL_POSIX"
  EMPTY_SQL_POSIX="$(mktemp "${TMPDIR:-/tmp}/clinicos_empty.XXXXXX.sql")"
  EMPTY_SQL_PG="$EMPTY_SQL_POSIX"
fi

echo "-- skipped 02a (CLINICOS_SKIP_02A=1)" > "$EMPTY_SQL_POSIX"

if [ "${CLINICOS_SKIP_02A:-0}" = "1" ]; then
  STEP_02A_PG="$EMPTY_SQL_PG"
else
  STEP_02A_PG="$REPO_PG/database/02a_live_sync_profile_and_slots.sql"
fi

if [ -n "$SEED_OVERRIDE" ]; then
  if [ "$IS_WIN" -eq 1 ]; then
    SEED_PG="$(to_mixed_path "$SEED_OVERRIDE")"
  else
    SEED_PG="$SEED_OVERRIDE"
  fi
else
  SEED_PG="$REPO_PG/database/04_seed_data.sql"
fi

run_pg() {
  if [ "$IS_WIN" -eq 0 ] && [ "$(id -u)" = 0 ]; then
    su postgres -s /bin/bash -c "$1"
  else
    bash -c "$1"
  fi
}

# Extract every public.<function>(...) call from every Postgres node query in both main workflows
node - "$REPO_PG" "$WF_SQL_PG" <<'NODE'
const fs = require('fs');
const path = require('path');

const [repoDir, outSqlPath] = process.argv.slice(2);
const workflowFiles = [
  'workflow/clinicos-main-engine.json',
  'workflow/clinicos-main-engine.l2v.json',
];

function stripSqlComments(sql) {
  let out = '';
  let i = 0;
  while (i < sql.length) {
    if (sql[i] === "'") {
      out += sql[i++];
      while (i < sql.length) {
        out += sql[i];
        if (sql[i] === "'" && sql[i + 1] === "'") {
          out += sql[++i];
          i++;
          continue;
        }
        if (sql[i] === "'") { i++; break; }
        i++;
      }
    } else if (sql[i] === '-' && sql[i + 1] === '-') {
      while (i < sql.length && sql[i] !== '\n') i++;
    } else if (sql[i] === '/' && sql[i + 1] === '*') {
      i += 2;
      while (i < sql.length && !(sql[i] === '*' && sql[i + 1] === '/')) i++;
      i += 2;
    } else {
      out += sql[i++];
    }
  }
  return out;
}

function extractPublicFunctionCalls(sql) {
  const cleaned = stripSqlComments(sql);
  const calls = [];
  const re = /\bpublic\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\(/gi;
  let m;
  while ((m = re.exec(cleaned)) !== null) {
    const fnName = m[1].toLowerCase();
    let idx = m.index + m[0].length;
    let depth = 1;
    let commas = 0;
    let inner = '';
    while (idx < cleaned.length && depth > 0) {
      const ch = cleaned[idx];
      if (ch === "'") {
        inner += ch;
        idx++;
        while (idx < cleaned.length) {
          inner += cleaned[idx];
          if (cleaned[idx] === "'" && cleaned[idx + 1] === "'") {
            inner += cleaned[++idx];
            idx++;
            continue;
          }
          if (cleaned[idx] === "'") { idx++; break; }
          idx++;
        }
        continue;
      }
      if (ch === '(') {
        depth++;
        inner += ch;
      } else if (ch === ')') {
        depth--;
        if (depth > 0) inner += ch;
      } else if (ch === ',' && depth === 1) {
        commas++;
        inner += ch;
      } else {
        inner += ch;
      }
      idx++;
    }
    if (depth !== 0) {
      throw new Error('Unbalanced parentheses in SQL call to public.' + fnName);
    }
    const argCount = inner.trim() === '' ? 0 : commas + 1;
    calls.push({ fnName, argCount });
  }
  return calls;
}

const allCalls = [];
for (const rel of workflowFiles) {
  const wf = JSON.parse(fs.readFileSync(path.join(repoDir, rel), 'utf8'));
  for (const node of wf.nodes || []) {
    if (node.type !== 'n8n-nodes-base.postgres') continue;
    const query = (node.parameters && node.parameters.query) || '';
    for (const c of extractPublicFunctionCalls(query)) {
      allCalls.push({ wf: rel, node: node.name, fnName: c.fnName, argCount: c.argCount });
    }
  }
}

if (allCalls.length === 0) {
  throw new Error('Extractor found 0 public.<function>() calls in workflows');
}

const sqlLines = [
  'DO $$',
  'DECLARE',
  '  v_match integer;',
  '  v_missing text[] := ARRAY[]::text[];',
  'BEGIN',
];

for (const c of allCalls) {
  const safeWf = c.wf.replace(/'/g, "''");
  const safeNode = c.node.replace(/'/g, "''");
  const safeFn = c.fnName.replace(/'/g, "''");
  sqlLines.push(
    `  SELECT count(*)::int INTO v_match FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = '${safeFn}' AND ${c.argCount} BETWEEN (p.pronargs - p.pronargdefaults) AND p.pronargs;`,
    `  IF v_match = 0 THEN v_missing := array_append(v_missing, '${safeWf} [' || '${safeNode}' || ']: public.${safeFn}(' || ${c.argCount} || ' args)'); END IF;`
  );
}

sqlLines.push(
  "  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN",
  "    RAISE EXCEPTION 'Workflow -> pg_proc signature drift detected: %', array_to_string(v_missing, '; ');",
  "  END IF;",
  `  RAISE NOTICE 'Verified ${allCalls.length} workflow public.<function>() calls against pg_proc: OK';`,
  'END $$;',
  ''
);

fs.writeFileSync(outSqlPath, sqlLines.join('\n'), 'utf8');
NODE
chmod 644 "$WF_SQL_POSIX" "$EMPTY_SQL_POSIX" 2>/dev/null || true

cleanup() {
  if [ "$IS_WIN" -eq 1 ]; then
    "$PGBIN/pg_ctl" -D "$WORK_PG" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$WORK_POSIX" "$WF_SQL_POSIX" "$EMPTY_SQL_POSIX"
  else
    run_pg "'$PGBIN/pg_ctl' -D '$WORK_PG' stop -m fast >/dev/null 2>&1 || true; rm -rf '$WORK_PG'"
    rm -f "$WF_SQL_POSIX" "$EMPTY_SQL_POSIX"
  fi
}
trap cleanup EXIT

PSQL_CLINIC_OPT=()
if [ -n "$CLINIC_ID_ARG" ]; then
  PSQL_CLINIC_OPT=(-v "clinic_id=$CLINIC_ID_ARG")
fi

if [ "$IS_WIN" -eq 1 ]; then
  "$PGBIN/initdb" -D "$WORK_PG" -U postgres -A trust --encoding=UTF8 --locale=C >/dev/null
  "$PGBIN/pg_ctl" -D "$WORK_PG" -l "$WORK_PG/log" -o "-p $PORT -h 127.0.0.1" -w start </dev/null >/dev/null 2>&1
  "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 \
    "${PSQL_CLINIC_OPT[@]}" \
    -v "repo=$REPO_PG" \
    -v "step_02a=$STEP_02A_PG" \
    -v "seed_sql=$SEED_PG" \
    -v "wf_checks_sql=$WF_SQL_PG" \
    -f "$REPO_PG/tests/clean_install_test.sql"
else
  CLINIC_FLAG=""
  if [ -n "$CLINIC_ID_ARG" ]; then
    CLINIC_FLAG="-v 'clinic_id=$CLINIC_ID_ARG'"
  fi
  run_pg "'$PGBIN/initdb' -D '$WORK_PG' -A trust --encoding=UTF8 --locale=C >/dev/null && '$PGBIN/pg_ctl' -D '$WORK_PG' -o '-p $PORT -k /tmp' -l '$WORK_PG/log' -w start >/dev/null"
  run_pg "'$PGBIN/psql' -h /tmp -p '$PORT' -d postgres -v ON_ERROR_STOP=1 $CLINIC_FLAG -v 'repo=$REPO_PG' -v 'step_02a=$STEP_02A_PG' -v 'seed_sql=$SEED_PG' -v 'wf_checks_sql=$WF_SQL_PG' -f '$REPO_PG/tests/clean_install_test.sql'"
fi

echo "Clean install test: OK"
