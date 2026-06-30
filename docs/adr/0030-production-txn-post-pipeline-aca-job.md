# ADR-0030: 本番 txn-post パイプライン（10→11→12→Azure PG）を専用 ACA Job 化し、非破壊・隔離・冪等を必須とする

- **Status**: Proposed
- **Date**: 2026-06-30
- **Deciders**: @shinyay（deployer 起票 / executor・checker レビュー想定）

## Context

取引投入パイプラインのうち、**ファイルベースで非破壊な 10-txnvalidate → 11-txnsortmerge** 区間は
ACA Manual Job `pb-txn-smoke` で完走実証済み（C-1）。残るのは **12-txnpost（stage5）= Azure PG への
実書込み**（`transactions` / `postings` / `balances` / `batch_run` / `audit_*`）。

現状、10→11→12 を端から端まで結線するのは **テストハーネス `tests/e2e/scripts/e2e-run.sh` のみ**で、これは本番投入には使えない:

- `e2e-prep-pg.sh` が共有 `banking` DB の `transactions, postings` を **`TRUNCATE ... RESTART IDENTITY CASCADE`** し、
  `batch_run` / `audit_log` / `audit_outbox` を DELETE、テスト用 customer/accounts/balances を INSERT する（**破壊的**）。
- 入力は `e2e-fixture-gen` による**合成 fixture**であり、実ファイル入力ではない。
- 資格情報・接続先（`PGHOST=postgres` / `cobol` / `banking`）がハーネス前提でハードコードされている。

一方 12-txnpost（`TXPOST-RUN-BATCH`）自体は、**冪等（already-skipped）**・直列リトライ・in-doubt 解決・reversal を
備えており、`txn-ready` ファイルを読んで PG へ post する設計になっている。つまり「破壊的なのはハーネスの reset であって
12-txnpost 本体ではない」。

制約（既存 ADR/runbook 由来）:
- ACA Consumption は安定 outbound IP を持たず、PG firewall は `AllowAzureServices` 前提（A-1, `docs/azure-deploy-runbook.md`）。
- COBOL orchestrator は資格情報をハードコード（`cobol`/`cobol`/`banking`）。PG admin パスワードは MVP 妥協で弱い `cobol`。
- ISAM マスタ（`*.idx`）は image に同梱されず、Job 実行時に `load-idx` で再生成が必要（C-1 知見）。
- deployer は `legacy/`・golden 不可侵、アプリ/業務ロジックは書かない（executor スコープ）。

本番の post 段を ACA に載せるには、「ハーネスをそのまま使う」以外の**安全な結線方法と隔離方針**を決める必要がある。

## Decision

本番 txn-post を、`pb-txn-smoke` とは別の**専用 ACA Job `pb-txn-post`** として段階導入する。導入にあたり以下を必須とする。

1. **専用の本番 orchestrator を新設する（executor スコープ）。** `e2e-run.sh` を本番転用しない。
   本番 orchestrator は:
   - **TRUNCATE / 全件 DELETE を行わない**（reset 禁止）。投入は 12-txnpost の**冪等性**に委ねる（再実行で already-skipped）。
   - **実ファイル入力**（固定長 txn 入力）を受け取り、10→11→12 を結線する（合成 fixture は使わない）。
   - `batch_run` の start/complete を記録し、`business_date` / `batch_id` で投入単位を識別する。
   - マスタ ISAM は実行時に `load-idx`（01/02/05/08 ほか必要分）で用意する（C-1 と同様）。
2. **隔離を先行する。** 初回〜検証段階は共有 `banking` を汚さないよう、**隔離した論理 DB（例 `banking_stg`）または隔離 `business_date`**
   に対して post し、golden 等価とリプレイ冪等を確認してから共有 `banking` へ昇格する。隔離 DB の払い出しは deployer が行う。
3. **A-1 の資格/ネットワーク姿勢を継承するが、本番カットオーバー前に (B) ハードニングを前提条件とする。** 本 Job は**業務データを書く**ため、
   弱パスワード `cobol` + `AllowAzureServices` のリスクは smoke より重大。共有 `banking` への昇格は **(B) `DB-CONNECT` の env 化＋強パスワード**
   完了を**前提**とする（ADR 化済みの A-1 リスクを参照）。
4. **役割分担を明示する（ADR-0023 トポロジ）。**
   - **executor**: 本番 orchestrator 実装＋ confirmation テスト（冪等リプレイ・recon・verify）。
   - **deployer**: `pb-txn-post` Job 定義（`infra/job-txn-post.yaml`）・隔離 DB 払い出し・runbook teardown 追記。
   - **checker**: golden-master 等価ゲート（`tests/<prog>/golden` 一致）で post 結果を検証。

本 ADR は**結線方針と安全設計の決定**であり、orchestrator コード自体は executor が後続で実装する。

## Consequences

- **良い点**:
  - 破壊的なのはハーネスの reset であり、12-txnpost の冪等性を使えば本番投入は非破壊にできる、という設計上の分離が明確になる。
  - 隔離 DB 先行により、共有 `banking` を汚さずに ACA 上の post を実証できる。
  - smoke（10/11）と post（12）の Job を分離することで、破壊リスクの面が小さく保てる。
- **悪い点 / トレードオフ**:
  - 本番 orchestrator の新規実装が必要（executor 作業）。`e2e-run.sh` の流用より手間。
  - 隔離 DB（または隔離 schema）の払い出しで追加の課金・運用が発生。
  - 共有 `banking` 昇格は (B) ハードニング待ちとなり、エンドツーエンドの本番化が直列化する。
- **中立**:
  - 12-txnpost の reversal/直列リトライ等の振る舞いは既存仕様のまま（本 ADR では変更しない）。

## Confirmation（任意）

- **golden 等価**: post 結果（transactions/postings/balances/batch_run）が `tests/<prog>/golden` と一致（checker / 等価ゲート）。
- **冪等リプレイ**: 同一入力を 2 回投入して 2 回目が all already-skipped（新規 post 0）になること。
- **非破壊性**: 本番 orchestrator 経路に `TRUNCATE` / 全件 `DELETE` が無いことをレビューで担保。
- **隔離**: 初回は `banking_stg`（または隔離 `business_date`）に対してのみ post されること。

## Alternatives considered（任意）

- **`e2e-run.sh` をそのまま本番 Job 化**: 却下。共有 `banking` を `TRUNCATE` し合成 fixture を seed する破壊的ハーネスで、本番投入に使うと既存データを失う。
- **初回から共有 `banking` に直接 post**: 却下。隔離なしで弱パスワード姿勢のまま業務データを書くのはリスク過大。(B) 完了前は不可。
- **post 段を当面オンプレ/systemd に留める**: 却下に近い保留。ACA への一本化方針（ADR-0026/0027）と矛盾するため、隔離付きで ACA 化を進める。

## References

- ADR-0026（コンテナ粒度＝サブシステム/ジョブ単位） / ADR-0027（rehost・Java 化しない）
- ADR-0029（MVP は MCP 構築先行・IaC 後追い）
- `docs/azure-deploy-runbook.md`（A-1 リスク・運用知見・teardown）
- `tests/e2e/scripts/e2e-run.sh` / `e2e-prep-pg.sh`（破壊的ハーネスの所在）
- `subsystems/12-txnpost/src/txpost-run-batch.sqb`（冪等 post の本体）
