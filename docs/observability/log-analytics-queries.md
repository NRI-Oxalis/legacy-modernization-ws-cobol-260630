# Observability — Container Apps ログを Log Analytics で見る

> Practice Bank の ACA 環境 `cae-practicebank` は Log Analytics ワークスペース `workspace-rgpracticebank7sWT` に
> コンソールログを自動連携。ジョブ/サービスの stdout/stderr は `ContainerAppConsoleLogs_CL` に蓄積される。

## 主要テーブル / 列
- テーブル: `ContainerAppConsoleLogs_CL`
- ジョブ名: `ContainerJobName_s`（例: `pb-batch`, `pb-dbcheck`）
- アプリ名(常駐): `ContainerAppName_s`
- 本文: `Log_s` ／ 時刻: `TimeGenerated` ／ ストリーム: `Stream_s`（stdout/stderr）
- コンテナ: `ContainerName_s` ／ イメージ: `ContainerImage_s`

## ポータル（Log Analytics → ログ）
```kusto
ContainerAppConsoleLogs_CL
| where ContainerJobName_s in ('pb-batch','pb-dbcheck')
| project TimeGenerated, ContainerJobName_s, Stream_s, Log_s
| order by TimeGenerated desc
| take 100
```

直近のエラーだけ:
```kusto
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where Stream_s == 'stderr' or Log_s has_any ('ERROR','SQLCODE','FATAL')
| project TimeGenerated, ContainerJobName_s, Log_s
| order by TimeGenerated desc
```

## CLI（az monitor log-analytics）
```powershell
# customerId(GUID) を取得
$ws = az containerapp env show -g rg-practicebank -n cae-practicebank `
  --query "properties.appLogsConfiguration.logAnalyticsConfiguration.customerId" -o tsv

# 直近ログ
az monitor log-analytics query -w $ws --analytics-query `
  "ContainerAppConsoleLogs_CL | where ContainerJobName_s=='pb-batch' | project TimeGenerated, Log_s | order by TimeGenerated desc | take 50" -o table
```

## ジョブ単位の実行ログ（プレビュー・即席）
```powershell
az containerapp job logs show -g rg-practicebank -n pb-dbcheck --container dbcheck --tail 50
```

## メモ
- Log Analytics への取り込みは数十秒〜数分のラグあり（即時は `job logs show`）。
- ACA 環境作成時に Log Analytics が自動生成される（手動指定も可）。
