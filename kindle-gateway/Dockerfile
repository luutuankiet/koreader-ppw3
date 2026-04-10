FROM node:22-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --production=false

COPY tsconfig.json ./
COPY src/ ./src/

# Build TypeScript
RUN npx tsc

EXPOSE 9999

CMD ["node", "dist/index.js"]
