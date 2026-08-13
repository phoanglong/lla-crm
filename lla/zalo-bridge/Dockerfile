FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server.mjs ./
RUN mkdir -p /data && chown node:node /data
USER node
ENV PORT=8787 DATA_DIR=/data
EXPOSE 8787
HEALTHCHECK --interval=10s --timeout=3s --retries=6 CMD wget -q -O /dev/null http://127.0.0.1:8787/healthz || exit 1
CMD ["node", "server.mjs"]
