#!/usr/bin/env bash
# ops-txn-post-run.sh — 本番 txn-post オーケストレータ（ADR-0030）
#
# 取引投入パイプライン 10-txnvalidate → 11-txnsortmerge → 12-txnpost を
# 実ファイル入力・非破壊・冪等で実行し、Azure PG（banking）へ post する。
#
# tests/e2e/scripts/e2e-run.sh との違い（= 本番化の肝）:
#   - 破壊的 reset（e2e-prep-pg.sh の TRUNCATE transactions,postings）を一切行わない。
#   - 投入の重複防止は 12-txnpost の冪等性（already-skipped）に委ねる。再実行は安全。
#   - 前提データ（system/test アカウント・残高）は ON CONFLICT DO NOTHING の冪等 upsert のみ。
#   - 入力は実ファイル（引数）。検証時のみ合成 fixture（--fixture）にフォールバック。
#   - 隔離は business_date 単位（12-txnpost は dbname=banking がハードコードのため別 DB 不可）。
#
# e2e-driver は TXVAL/TXSM/TXPOST を CALL する純粋なディスパッチャ（DB 破壊なし）として再利用する。
#
# 使い方:
#   PGHOST=<pg> [PGPASSWORD=...] ops-txn-post-run.sh <batch_id(14)> <business_date(YYYYMMDD)> <input|--fixture>
#
# 例（検証 / 隔離 business_date）:
#   PGHOST=pg-... ops-txn-post-run.sh TXNPOST-PRD-01 20260612 --fixture
set -euo pipefail

BATCH_ID="${1:?usage: ops-txn-post-run.sh <batch_id(14)> <business_date(YYYYMMDD)> <input|--fixture>}"
BDATE="${2:?business_date(YYYYMMDD) required}"
INPUT="${3:---fixture}"

if [ "${#BATCH_ID}" -ne 14 ]; then
  echo "[ops-txn-post] ERROR: batch_id must be exactly 14 chars (got '${BATCH_ID}' len=${#BATCH_ID})" >&2
  exit 2
fi

WS="${WS:-/workspace}"
WORKDIR="${TXNPOST_WORKDIR:-/tmp/txn-post}"
RESULTS="$WORKDIR/results"
E2E="$WS/tests/e2e"
mkdir -p "$WORKDIR/tmp" "$RESULTS"

# --- PG 接続（HOST は env、user/pass/db=cobol/cobol/banking は 12-txnpost にハードコード）---
export PGHOST="${PGHOST:?set PGHOST (Azure PG FQDN)}"
export PGUSER="${PGUSER:-cobol}"
export PGDATABASE="${PGDATABASE:-banking}"
export PGPASSWORD="${PGPASSWORD:-cobol}"
export LD_PRELOAD="${LD_PRELOAD:-/usr/local/lib/libocesql.so}"
PSQL="psql -h $PGHOST -U $PGUSER -d $PGDATABASE -q -v ON_ERROR_STOP=1"

export COB_LIBRARY_PATH=\
"$WS/subsystems/10-txnvalidate/bin:"\
"$WS/subsystems/11-txnsortmerge/bin:"\
"$WS/subsystems/12-txnpost/bin:"\
"$WS/subsystems/01-calendar/bin:"\
"$WS/subsystems/02-branch/bin:"\
"$WS/subsystems/05-product/bin:"\
"$WS/subsystems/08-account/bin:"\
"$WS/shared/util/aud-write/bin:"\
"$WS/shared/util/shared-log/bin"

BDATE_PG="${BDATE:0:4}-${BDATE:4:2}-${BDATE:6:2}"
echo "=== ops-txn-post-run: batch=$BATCH_ID bdate=$BDATE_PG input=$INPUT host=$PGHOST ==="

# --- 1. ランタイム ISAM（マスタは image に同梱されないため毎回 load-idx）---
echo "[1] master ISAM load-idx"
for d in 01-calendar 02-branch 05-product 08-account; do
  make -s -C "$WS/subsystems/$d" load-idx >/dev/null
done

# --- 2. 前提データ（非破壊・冪等 upsert。TRUNCATE/reset しない）---
echo "[2] prerequisites (non-destructive upserts)"
bash "$WS/subsystems/22-operations/src/ops-seed-system-accounts.sh" >/dev/null

# テスト用 customer / accounts / balances（fixture が参照。ON CONFLICT DO NOTHING = 残高をリセットしない）
$PSQL <<'SQL' >/dev/null
INSERT INTO customers (cust_id, cust_name, cust_name_kana, cust_status, tier, created_at, updated_at)
VALUES ('9999000099', 'E2E TEST', 'E2EテストJP', 'A', 'B', NOW(), NOW())
ON CONFLICT (cust_id) DO NOTHING;
SQL
for ACCT in 0010010099001 0010010099002 0010010099003; do
  $PSQL -v acct="$ACCT" <<'SQL' >/dev/null
INSERT INTO accounts (acct_number, acct_name, branch_code, product_code, acct_status, cust_id, opened_date, created_at, updated_at)
VALUES (:'acct', 'E2E TEST', '001', '001', 'A', '9999000099', '2026-06-01', NOW(), NOW())
ON CONFLICT (acct_number) DO NOTHING;
INSERT INTO balances (account_number, balance_jpy, available_jpy, last_business_date, updated_ts)
VALUES (:'acct', 100000, 100000, '2026-06-01', NOW())
ON CONFLICT (account_number) DO NOTHING;
SQL
done
"$E2E/bin/e2e-seed-isam"

# --- 3. 入力: 実ファイル or 検証 fixture ---
export E2E_BATCH_ID="$BATCH_ID" E2E_BDATE="$BDATE" E2E_OUTPUT="$WORKDIR/txn-decoded.dat"
if [ "$INPUT" = "--fixture" ]; then
  echo "[3] input = synthetic fixture (validation mode)"
  export E2E_TOTAL="${E2E_TOTAL:-100}" E2E_VALID_RATIO="${E2E_VALID_RATIO:-90}"
  "$E2E/bin/e2e-fixture-gen"
else
  echo "[3] input = real file $INPUT"
  [ -s "$INPUT" ] || { echo "[ops-txn-post] ERROR: input file empty/missing: $INPUT" >&2; exit 3; }
  cp "$INPUT" "$WORKDIR/txn-decoded.dat"
fi

# --- 4. パイプライン 10 → 11 → 12（非破壊）---
echo "[4a] stage2 validate (10-txnvalidate)"
"$E2E/bin/e2e-driver" stage2 "$BATCH_ID" "$BDATE" \
  "$WORKDIR/txn-decoded.dat" "$WORKDIR/txn-valid.dat" "$WORKDIR/txn-error.dat" "$WORKDIR/txval.ckpt" \
  | tee "$RESULTS/stage2.out"

echo "[4b] stage3 sort (11-txnsortmerge)"
"$E2E/bin/e2e-driver" stage3 "$BATCH_ID" "$BDATE" \
  "$WORKDIR/txn-valid.dat" "$WORKDIR/txn-sorted.dat" "$WORKDIR/txsm-sort.ckpt" \
  | tee "$RESULTS/stage3.out"

: > "$WORKDIR/txn-recon-prev.dat"
echo "[4c] stage4 merge (11-txnsortmerge)"
"$E2E/bin/e2e-driver" stage4 "$BATCH_ID" "$BDATE" \
  "$WORKDIR/txn-sorted.dat" "$WORKDIR/txn-recon-prev.dat" "$WORKDIR/txn-ready.dat" \
  "$WORKDIR/txn-error.dat" "$WORKDIR/txsm-merge.ckpt" "$WORKDIR/tmp/txn-ready-d-only.tmp" \
  | tee "$RESULTS/stage4.out"

echo "[4d] stage5 post (12-txnpost) — writes to PG (idempotent)"
bash "$WS/subsystems/22-operations/src/ops-batch-run-start.sh" "$BATCH_ID" "$BDATE" "TXPOST"
"$E2E/bin/e2e-driver" stage5 "$BATCH_ID" "$BDATE" \
  "$WORKDIR/txn-ready.dat" "$WORKDIR/txn-error.dat" "$WORKDIR/txn-recon-defer.dat" \
  "$WORKDIR/txpost.ckpt" "$WORKDIR/dormancy-repair.dat" \
  | tee "$RESULTS/stage5.out"

POSTED=$(grep -oE '"records_posted":[0-9]+' "$RESULTS/stage5.out" | head -1 | grep -oE '[0-9]+$' || echo 0)
TX_STATUS=$(grep -oE '"status":"[0-9]+"' "$RESULTS/stage5.out" | head -1 | grep -oE '[0-9]+' || echo 16)
case "$TX_STATUS" in 00|04) BR_STATUS="OK" ;; *) BR_STATUS="FL" ;; esac
bash "$WS/subsystems/22-operations/src/ops-batch-run-complete.sh" "$BATCH_ID" "$BDATE" "$BR_STATUS" "$POSTED" 0

# --- 5. 検証（golden 等価相当の不変条件: DR=CR, 件数, batch_run）---
echo "[5] verify"
bash "$E2E/scripts/e2e-verify.sh" smoke "$BATCH_ID" "$BDATE" "$WORKDIR" "$RESULTS"

echo "=== ops-txn-post-run COMPLETE batch=$BATCH_ID status=$BR_STATUS posted=$POSTED ==="
