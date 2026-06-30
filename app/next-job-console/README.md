# Next.js Job Console

Flask API (ACA Job wrapper) を呼び出す Next.js UI です。画面上でユニットごとに `Run` ボタンを押して Job 実行できます。

## Setup

```bash
cd app/next-job-console
cp .env.example .env.local
npm install
npm run dev
```

Open: <http://localhost:3000>

## Environment variables

- `FLASK_JOB_API_BASE_URL`: Flask wrapper API base URL
  - default: `http://localhost:8080`

## What this app does

- `GET /api/units` -> Flask `GET /units`
- `POST /api/units/:unitName/runs` -> Flask `POST /units/:unitName/runs`
- `GET /api/units/:unitName/runs` -> Flask `GET /units/:unitName/runs`

Next.js 側の API Route で Flask をプロキシするため、ブラウザ側 CORS 設定は不要です。
