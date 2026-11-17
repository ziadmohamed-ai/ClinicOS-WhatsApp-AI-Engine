#!/usr/bin/env bash
# Runs the Lead-to-Visit SQL tests on a throw-away Postgres cluster.
# Needs Postgres 16+ binaries and node. Never point this at a real database.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

if ls -d /usr/lib/postgresql/*/bin >/dev/null 2>&1; then
  PGBIN="$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)"
elif command -v initdb >/dev/null 2>&1; then
  PGBIN="$(dirname "$(command -v initdb)")"
else
  echo "ERROR: PostgreSQL binaries (initdb/pg_ctl/psql) not found" >&2
  exit 1
fi

PORT="${CLINICOS_TEST_PGPORT:-55432}"
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

if [ "$IS_WIN" -eq 1 ]; then
  REPO_PG="$(to_mixed_path "$REPO")"
  WORK_POSIX="$(mktemp -d "${TMPDIR:-/tmp}/l2v_scratch.XXXXXX")"
  rm -rf "$WORK_POSIX"
  mkdir -p "$WORK_POSIX"
  WORK_PG="$(to_mixed_path "$WORK_POSIX")"
  FNS_POSIX="$(mktemp "${TMPDIR:-/tmp}/clinicos_real_fns.XXXXXX.sql")"
  FNS_PG="$(to_mixed_path "$FNS_POSIX")"
else
  REPO_PG="$REPO"
  if [ "$(id -u)" = 0 ] && [ -d /var/lib/postgresql ]; then
    WORK_POSIX="/var/lib/postgresql/l2v_scratch_$$"
  else
    WORK_POSIX="$(mktemp -d "${TMPDIR:-/tmp}/l2v_scratch.XXXXXX")"
    rm -rf "$WORK_POSIX"
  fi
  WORK_PG="$WORK_POSIX"
  FNS_POSIX="$(mktemp "${TMPDIR:-/tmp}/clinicos_real_fns.XXXXXX.sql")"
  FNS_PG="$FNS_POSIX"
fi

run_pg() {
  if [ "$IS_WIN" -eq 0 ] && [ "$(id -u)" = 0 ]; then
    su postgres -s /bin/bash -c "$1"
  else
    bash -c "$1"
  fi
}

node - "$REPO_PG/database/02_booking_and_outbox_rpcs.sql" "$REPO_PG/database/02a_live_sync_profile_and_slots.sql" "$FNS_PG" <<'NODE'
const fs = require('fs');
const [src02, src02a, dst] = process.argv.slice(2);
const lines = fs.readFileSync(src02, 'utf8').split(/\r?\n/);
const want = [
  'public.enqueue_message(',
  'private.build_whatsapp_message(',
  'public.get_available_slots(',
  'public.apply_voice_transcription(',
];
let out = [];
for (const w of want) {
  const i = lines.findIndex(l => l.startsWith('CREATE OR REPLACE FUNCTION ' + w));
  if (i < 0) throw new Error('Missing function in 02: ' + w);
  const j = lines.findIndex((l, idx) => idx > i && l.trim() === '$function$;');
  out = out.concat(lines.slice(i, j + 1), ['']);
}
out.push(fs.readFileSync(src02a, 'utf8'));
fs.writeFileSync(dst, out.join('\n'), 'utf8');
console.log('extracted', want.length, 'functions + 02a');
NODE
chmod 644 "$FNS_POSIX" 2>/dev/null || true

cleanup() {
  if [ "$IS_WIN" -eq 1 ]; then
    "$PGBIN/pg_ctl" -D "$WORK_PG" -m immediate stop </dev/null >/dev/null 2>&1 || true
    rm -rf "$WORK_POSIX" "$FNS_POSIX"
  else
    run_pg "'$PGBIN/pg_ctl' -D '$WORK_PG' stop -m fast >/dev/null 2>&1 || true; rm -rf '$WORK_PG'"
    rm -f "$FNS_POSIX"
  fi
}
trap cleanup EXIT

if [ "$IS_WIN" -eq 1 ]; then
  "$PGBIN/initdb" -D "$WORK_PG" -U postgres -A trust --encoding=UTF8 --locale=C >/dev/null
  "$PGBIN/pg_ctl" -D "$WORK_PG" -l "$WORK_PG/log" -o "-p $PORT -h 127.0.0.1" -w start </dev/null >/dev/null 2>&1
  "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -v "repo=$REPO_PG" -v "fns=$FNS_PG" -f "$REPO_PG/tests/l2v/l2v_addon_test.sql"
else
  run_pg "'$PGBIN/initdb' -D '$WORK_PG' -A trust --encoding=UTF8 --locale=C >/dev/null && '$PGBIN/pg_ctl' -D '$WORK_PG' -o '-p $PORT -k /tmp' -l '$WORK_PG/log' -w start >/dev/null"
  run_pg "'$PGBIN/psql' -h /tmp -p '$PORT' -d postgres -v ON_ERROR_STOP=1 -v 'repo=$REPO_PG' -v 'fns=$FNS_PG' -f '$REPO_PG/tests/l2v/l2v_addon_test.sql'"
fi
echo "L2V SQL tests: OK"
