# Azure デプロイ Runbook（MVP / rehost）

> MVP は Azure 構築先行（az/MCP）、安定後に Bicep+azd へ写経（ADR-0029）。本書は**実デプロイ済みリソースの停止/削除手順**と**既知リスク**を記録する（deployer 原則: 課金リソースは runbook に停止/削除を残す）。

## 1. デプロイ済みリソース（rg-practicebank / japaneast）

| 種別 | 名前 | 備考 |
|---|---|---|
| Resource Group | `rg-practicebank` | 既存を再利用（新規作成せず） |
| ACA env | `cae-practicebank` | Consumption（VNet なし）。staticIp `48.218.101.216` |
| ACR | `acrpracticebank45261` | Basic, adminEnabled。image `practice-bank:app-latest` ほか |
| PostgreSQL Flexible | `pg-practicebank-5901` | v15, admin `cobol`, publicNetworkAccess Enabled, DB `banking` |
| ACA Jobs (Manual) | `pb-init-{calendar,branch,customer,product,interestrate,feeschedule,account}` | 7 master ロード |
| ACA Jobs (Manual) | `pb-batch-daily-rt` | 日次パイプライン real-mode 検証 job |
| ACA Jobs (Schedule) | `pb-batch-daily` | 日次パイプライン本番 job。cron `0 17 * * *`(UTC)=JST 02:00, real-mode |
| ACA Jobs (Schedule) | `pb-dormancy-scan` | 週次 dormancy/reactivation scan（9-ALC）。cron `0 18 * * 0`(UTC)=JST Mon 03:00, real-mode |
| ACA Jobs (Schedule) | `pb-batch-monthly` | 月次バッチ（ops-driver M）。cron `0 17 1 * *`(UTC)≈JST 2日 02:00, real-mode |
| ACA Jobs (Schedule) | `pb-partition-rollover` | 監査 partition rollover（ops-driver R / 21-audit）。cron `0 17 24 * *`(UTC)=JST 25日 02:00, real-mode |
| ACA Jobs (Manual) | `pb-txn-smoke` | 取引パイプライン非破壊スモーク（10-txnvalidate→11-txnsortmerge, PG 不使用 / C-1）。proc=100/valid=90/rej=10 |
| ACA Jobs (Manual) | `pb-txn-post` | 本番 txn-post パイプライン（10→11→12→Azure PG, 非破壊・冪等 / C-3, ADR-0030）。orchestrator=`subsystems/22-operations/src/ops-txn-post-run.sh` |
| ACA Apps (internal) | `pb-rabbitmq` | RabbitMQ broker（`rabbitmq:3-management-alpine`、内部 TCP ingress 5672、user/pass=cobol/cobol）。step20 drain の実 publish 先。**job からは短縮名 `pb-rabbitmq` で接続**（FQDN 不可・後述）|
| ACA Jobs (Manual) | `pb-batch`, `pb-dbcheck` | 既存 |

全 job は単一リポイメージを共有し、job 実行時に `make` でビルドする（Dockerfile が /workspace に全コピー）。

## 2. 既知リスク（A-1 採択：MVP 妥協）

**現状の構成**: PG firewall = `AllowAzureServices`(0.0.0.0) + `devbox-schema-apply`、PG admin パスワード = `cobol`（弱）。

- **根本原因**: COBOL orchestrator `ops-batch-daily.sqb` の `DB-CONNECT` が資格情報（user/pass=`cobol`/`cobol`, db=`banking`）を**ハードコード**。`PGPASSWORD` env を無視するため、Azure PG 側パスワードをアプリ期待値 `cobol` に合わせる必要がある。
- **ネットワーク閉域化の制約**: ACA Consumption（VNet なし）は**安定した outbound IP を持たない（SNAT プール）**。firewall を env staticIp に絞ると job から PG へ到達不可（A/B テストで確認済み）。そのため `AllowAzureServices` を許可せざるを得ない。
- **リスク**: 他テナント含む Azure 内部から、弱パスワード `cobol` で `banking` DB に到達試行が可能（インターネット公開ではない）。dev サブスク・MVP 限定として許容。

**ハードニング（本番移行フェーズ / フォローアップ）**:
- (B) アプリ `DB-CONNECT` を `PGUSER`/`PGPASSWORD` env 参照化し強パスワード維持（executor スコープ・要 ADR）。**本筋**。
- (A-2) ACA env を VNet 統合（env 再作成要）+ PG private endpoint で firewall を閉じる。

## 3. real-mode 実行（手動）

```bash
az containerapp job start -g rg-practicebank -n pb-batch-daily-rt
# 結果確認
az containerapp job execution list -g rg-practicebank -n pb-batch-daily-rt \
  --query "sort_by([],&properties.startTime)[-1].{name:name,status:properties.status}" -o json
```

日次 6 step（19→13→15→16→17→20）は **`ops-daily-driver`（e2e-driver 同型の薄い CALL シム）経由で実ワーカーを駆動**する（2026-06-30 配線）。以前は `cobcrun <MODULE>` を引数なし起動して全 step が SIGSEGV(rc=11)→soft-skip だったが、ドライバが INPUT/OUTPUT レコードを確保して `CALL ... USING` するため実行されるようになった。検証（`pb-batch-daily-rt` 実行）で `OPS_BATCH_OK` + `OPS_STEP_OK×6`、ワーカー固有監査（`AD_DAILY_SUMM`/`FEE_DAILY_SUMM`/`STMT_GEN_START|END`）を確認。

- rc 方針: `0/1/4`=OK、`8-12`=SOFT-SKIP（適格データ未 seed・受信ファイル無し等）、`16`/その他=FAIL（致命・モジュール不在をもう隠さない）。
- step19 は受信ファイル未供給だと rc=12（SOFT-SKIP）。本番は `OPS_INBOUND_FILE` で供給。
- step20（drain）は既定 `OPS_MQ_MODE=M`（mock）。RabbitMQ 実投入は `OPS_MQ_MODE=R` + ブローカー配備時のみ必要。現時点では**不要**。
- 反映には image 再ビルド（`az acr build`）が必要（ドライバ/step スクリプトを焼き込む）。`pb-batch-daily-rt`(手動) と `pb-batch-daily`(夜間) は同一 image を共有。

## 4. 停止 / 削除（teardown）

### 個別 job 削除
```bash
for j in pb-init-calendar pb-init-branch pb-init-customer pb-init-product \
         pb-init-interestrate pb-init-feeschedule pb-init-account pb-batch-daily-rt \
         pb-batch-daily pb-dormancy-scan pb-batch-monthly pb-partition-rollover \
         pb-txn-smoke pb-txn-post; do
  az containerapp job delete -g rg-practicebank -n "$j" --yes
done
```

### RabbitMQ broker 削除
```bash
az containerapp delete -g rg-practicebank -n pb-rabbitmq --yes
```

### firewall ルール削除
```bash
az postgres flexible-server firewall-rule delete -g rg-practicebank \
  -s pg-practicebank-5901 -n devbox-schema-apply --yes
az postgres flexible-server firewall-rule delete -g rg-practicebank \
  -s pg-practicebank-5901 -n AllowAzureServices --yes
```

### PG 停止（課金停止・データ保持）
```bash
az postgres flexible-server stop -g rg-practicebank -n pg-practicebank-5901
```

### 全削除（既存スタックも消える・要注意）
```bash
az group delete -n rg-practicebank --yes --no-wait
```

> 注意: `rg-practicebank` には本セッション以前から存在するリソース（ACA env / ACR / PG / pb-batch / pb-dbcheck）も含まれる。RG 全削除はそれらも消す。

## 5. 課金注意

- ACA Jobs（Manual）は**実行時のみ課金**（アイドル時ゼロ）。
- PG Flexible は**常時課金**。未使用時は `stop`（上記）。
- ACR Basic は少額の常時課金。
- RabbitMQ は未デプロイ（必要になれば常時課金 → 要 runbook 追記）。

## 6. 運用知見（デバッグ・落とし穴）

### ACA job ログがこの devbox から取得不能
`az monitor log-analytics query` も `az containerapp job logs` もこの環境では**ハング/タイムアウト**する。
job 失敗の原因特定は次の順で行う:
1. **ローカル再現**（`git clone --depth 1 file:///workspace /tmp/pbclean` でクリーン状態を作り job script を実行）。
2. **PG ブレッドクラム**: job 内で各ステップの rc と出力末尾を PG の一時テーブル（`deploy_diag`）に書き、devbox の psql から読む。雛形 `infra/job-txn-smoke-diag.yaml`（観測専用・使用後は job 削除 + `DROP TABLE deploy_diag`）。

### ISAM マスタ（*.idx）は image に入っていない
`*.idx` は `.gitignore` 対象でリポに無く、image にも同梱されない。ISAM を読む COBOL（例 `e2e-seed-isam` は `OPEN I-O account.idx` で**既存前提**、無いと fs=35 → `STOP RUN RETURNING 1`）を含む job は、**実行時に各サブシステムの `make -C subsystems/NN-xxx load-idx` で ISAM を再生成**してから本処理に入る必要がある（`pb-txn-smoke` は 01/02/05/08 を load-idx する）。

### job のリソースは実績値に揃える
`make build-all`（全 COBOL を cobc→C→gcc）を含む job は **cpu 1.0 / memory 2Gi**（実績）にする。0.5/1Gi は不足し失敗しうる。

### 新規 orchestrator/script を job に入れたら image を再ビルドする
全 job は `acrpracticebank45261.azurecr.io/practice-bank:app-latest` を共有し、`COPY . /workspace` で**ビルド時点**の作業ツリーを焼き込む。リポに新ファイル（例 `ops-txn-post-run.sh`）を足しただけでは image に入らず、job 内で `No such file` 失敗する（build-all は通るので **~40s で失敗**＝紛らわしい）。`az acr build -r acrpracticebank45261 -t practice-bank:app-latest -f infra/Dockerfile .`（クラウドビルド ~1.5min）で再ビルドしてから job を再実行する。追加ファイルは加算的なので既存 job に影響しない。

### step20（drain）の RabbitMQ 実 publish（OPS_MQ_MODE=R）

step20 は失敗ファイル（15-autodebit が出力する自動引落失敗）を `INTO-PUBLISH-EVENT`→`rmq_pub`(librabbitmq) で RabbitMQ `pb.events` へ publish する。

- **broker host は短縮名 `pb-rabbitmq` を使う（重要）**: ACA 内部 ingress の **FQDN（`*.internal.<env>...`）は job から TCP 5672 に到達できない（接続タイムアウト rc=124）**。一方、**ACA service discovery の短縮名 `pb-rabbitmq`（→ `pb-rabbitmq.k8se-apps.svc.cluster.local`）は job から到達可能（rc=0）**。診断は境界付き TCP プローブ（`timeout 8 bash -c 'exec 3<>/dev/tcp/<host>/5672'`）で確認。
- 接続情報は env で注入（`into-publish-event.cob` を env 化済み）: `RABBITMQ_HOST`/`RABBITMQ_USER`/`RABBITMQ_PASS`/`RABBITMQ_PORT`/`RABBITMQ_QUEUE`。未設定なら devcontainer 既定（`rabbitmq`:cobol/cobol）。
- `rmq_pub` は publish 前に **durable queue を冪等宣言**するため、consumer 不在でもメッセージが保持される。
- 検証実績: ローカル（devcontainer rabbitmq）= pb.events に 2 メッセージ着弾・JSON エンベロープ確認。ACA = 一回限り job（短縮名）で drain status=00 / drained=2（PG breadcrumb 経由）。`pb-batch-daily`/`-rt` に `OPS_MQ_MODE=R` + `RABBITMQ_HOST=pb-rabbitmq` を配線済み。実 publish は 15 が失敗を出した時のみ発生。
- 既知バグ（別件）: `MQ_PUBLISH_COMPLETE`/`MQ_DRAIN_COMPLETE` の AUD-WRITE 監査ペイロードが invalid JSON で INSERT 失敗（publish 自体は status=00 で成功）。

### pb-txn-post の冪等性と business_date 制約（ADR-0030）
- **12-txnpost は取引自然キー（source_system+source_seq+business_date 等）で重複排除**する。batch_id ではない。よって**同一 business_date の同一決定的 fixture を別 batch_id で再投入しても `records_posted=0 / already_skipped=N`**（二重計上なし）。これは正しい冪等動作で、ledger 不変条件（I2: DR=CR）を保つ。
- **I4 単調性ガード（E020）**: 投入 business_date が `max-closed`（`MAX(business_date) FROM batch_run WHERE status='OK' AND completed_ts IS NOT NULL`）**未満だと back-dated 拒否**。`pb-txn-post` は実行時に `max-closed` を導出して business_date に使う（`<` ガードなので等号は許容）。
- **PG `calendar` テーブルは現状 2026-06-30 までしか無い**（ISAM calendar は 1826 日）。未来日 post は calendar 不在で validate 不可なため、検証は `business_date = max-closed (2026-06-30)` で行う。
- **新規 post をクラウド job で観測したい場合**: 対象 business_date に既存の同一 fixture データがあると `already_skipped` になる。クリーンな新規 post を見るには、先行の検証データ（例 `source_batch_id='TXNPOST-PRD-02'`）を**自分のテスト行に限って**削除してから再実行する（共有 banking への破壊操作のため要人間確認）:
  ```bash
  # 自分の合成テスト行のみ（postings→transactions→batch_run の順）
  PGSSLMODE=require psql "host=pg-practicebank-5901.postgres.database.azure.com user=cobol dbname=banking" -c \
    "DELETE FROM postings p USING transactions t WHERE p.txn_id=t.txn_id AND t.source_batch_id IN ('TXNPOST-PRD-02');" -c \
    "DELETE FROM transactions WHERE source_batch_id IN ('TXNPOST-PRD-02');" -c \
    "DELETE FROM batch_run WHERE batch_id IN ('TXNPOST-PRD-02');"
  ```
- **検証実績**: local orchestrator 実行（`TXNPOST-PRD-02` @2026-06-30）= records_posted=90 / transactions=90 / postings=180 / DR=CR=90000 / verify PASS=14。冪等再実行 = posted=0 / already_skipped=90 / 件数不変 / PASS=14。ACA job `pb-txn-post`（`TXNPOST-ACA001`）= 全パイプライン Azure 上で Succeeded・batch_run OK・verify PASS=14（既存データに対し冪等 skip）。
