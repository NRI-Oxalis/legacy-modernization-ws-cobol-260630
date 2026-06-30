# Multi-stage build for Next.js
FROM node:20-alpine AS builder

WORKDIR /app

# 依存パッケージのインストール
COPY package*.json ./
RUN npm install

# アプリケーションのコピーとビルド
COPY . .
RUN mkdir -p public
RUN npm run build

# 本番ステージ
FROM node:20-alpine

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000

# 本番依存のみをインストール
COPY package*.json ./
RUN npm install --omit=dev

# builder ステージからビルド結果をコピー
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/public ./public

EXPOSE 3000

CMD ["npm", "start"]
