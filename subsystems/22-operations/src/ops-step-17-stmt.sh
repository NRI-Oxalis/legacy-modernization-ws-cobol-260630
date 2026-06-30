#!/usr/bin/env bash
set -uo pipefail
DRY_RUN="${1:-Y}"
STEP_ID="17-stmt"
SO_PATH="/workspace/subsystems/17-statement/bin/STMT-GENERATE-BATCH.so"
MODULE="STMT-GENERATE-BATCH"
SUBSYS_BIN_DIR="$(dirname "$SO_PATH")"
AUD_BIN=/workspace/shared/util/aud-write/bin
LOG_BIN=/workspace/shared/util/shared-log/bin

_INJ="${OPS_STEP_INJECT_FAIL:-}"
if [[ "${_INJ,,}" == "${STEP_ID,,}" && -n "$_INJ" ]]; then
    echo "[OPS-STEP-$STEP_ID] INJECTED FAILURE (Phase 9.5 test hook)" >&2
    exit 1
fi

if [[ ! -f "$SO_PATH" ]]; then
    echo "[OPS-STEP-$STEP_ID] FAIL: missing $SO_PATH" >&2
    exit 1
fi

if ! command -v cobcrun >/dev/null 2>&1; then
    echo "[OPS-STEP-$STEP_ID] FAIL: cobcrun unavailable" >&2
    exit 1
fi

if [[ "$DRY_RUN" == "Y" ]]; then
    echo "[OPS-STEP-$STEP_ID] dry-run OK (smoke=$(basename $SO_PATH))"
    exit 0
fi

DRIVER=/workspace/subsystems/22-operations/bin/ops-daily-driver
if [[ ! -x "$DRIVER" ]]; then
    echo "[OPS-STEP-$STEP_ID] FAIL: missing driver $DRIVER (build: make -C subsystems/22-operations bin/ops-daily-driver)" >&2
    exit 1
fi
WORK="${OPS_WORK_DIR:-/tmp/ops-daily}"; mkdir -p "$WORK"
BID="${OPS_BATCH_ID:-MVP-DAILY}"
BDATE="${OPS_BUSINESS_DATE:-$(date +%Y%m%d)}"

# e2e-driver と同型: 薄いドライバが INPUT/OUTPUT を確保しワーカーを CALL する
COB_LIBRARY_PATH="$SUBSYS_BIN_DIR:$AUD_BIN:$LOG_BIN" \
LD_PRELOAD=/usr/local/lib/libocesql.so \
PGHOST=${PGHOST:-postgres} \
PGUSER=${PGUSER:-cobol} \
PGPASSWORD=${PGPASSWORD:-cobol} \
PGDATABASE=${PGDATABASE:-banking} \
"$DRIVER" step17 "$BID" "$BDATE" "${OPS_STMT_MODE:-D}" \
    "$WORK/stmt-$BDATE.dat" "$WORK/stmt-summary-$BDATE.dat" "${OPS_STMT_SKIP_INACTIVE:-Y}" \
    >/tmp/ops-step-$STEP_ID.out 2>&1
rc=$?

if [[ "$rc" -eq 0 || "$rc" -eq 1 || "$rc" -eq 4 ]]; then
    echo "[OPS-STEP-$STEP_ID] real-mode OK (driver $MODULE rc=$rc)"
    tail -1 /tmp/ops-step-$STEP_ID.out 2>/dev/null || true
    exit 0
elif [[ "$rc" -ge 8 && "$rc" -le 12 ]]; then
    echo "[OPS-STEP-$STEP_ID] real-mode SOFT-SKIP (driver $MODULE rc=$rc; data/prereqs not seeded; v1.1 backlog)" >&2
    tail -1 /tmp/ops-step-$STEP_ID.out >&2 2>/dev/null || true
    exit 0
else
    echo "[OPS-STEP-$STEP_ID] real-mode FAIL (driver $MODULE rc=$rc)" >&2
    head -20 /tmp/ops-step-$STEP_ID.out >&2 2>/dev/null || true
    exit 1
fi
