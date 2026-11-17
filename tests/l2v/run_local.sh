#!/usr/bin/env bash
# Runs the Lead-to-Visit SQL tests on a throw-away Postgres cluster.
# Needs Postgres 16+ binaries and python3. Run as root (it uses the postgres OS user) or as postgres.
# Never point this at a real database: it creates roles/schemas and a scratch cluster in /var/lib/postgresql.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PGBIN="$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)"
WORK="/var/lib/postgresql/l2v_scratch_$$"
PORT=55432
run_pg() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "$1"; else bash -c "$1"; fi; }

FNS="$(mktemp /tmp/clinicos_real_fns.XXXXXX.sql)"
python3 -I - "$REPO/database/02_booking_and_outbox_rpcs.sql" "$FNS" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8').read().split('\n')
want = [
    'public.enqueue_message(',
    'private.build_whatsapp_message(',
    'public.get_patient_profile(',
    'public.update_patient_profile(',
    'public.get_available_slots(',
    'public.apply_voice_transcription(',
]
out = []
for w in want:
    i = next(k for k, l in enumerate(lines) if l.startswith('CREATE OR REPLACE FUNCTION ' + w))
    j = next(k for k in range(i + 1, len(lines)) if lines[k].strip() == '$function$;')
    out += lines[i:j + 1] + ['']
open(dst, 'w', encoding='utf-8').write('\n'.join(out))
print('extracted', len(want), 'functions')
PY
chmod 644 "$FNS"

cleanup() { run_pg "$PGBIN/pg_ctl -D $WORK stop -m fast >/dev/null 2>&1 || true; rm -rf $WORK"; rm -f "$FNS"; }
trap cleanup EXIT

run_pg "$PGBIN/initdb -D $WORK -A trust >/dev/null && $PGBIN/pg_ctl -D $WORK -o '-p $PORT -k /tmp' -l $WORK/log -w start >/dev/null"
run_pg "$PGBIN/psql -h /tmp -p $PORT -d postgres -v ON_ERROR_STOP=1 -v repo=$REPO -v fns=$FNS -f $REPO/tests/l2v/l2v_addon_test.sql"
echo "L2V SQL tests: OK"
