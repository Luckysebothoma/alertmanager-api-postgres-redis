FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY src ./src
RUN addgroup -S app && adduser -S app -G app
USER app
ENV NODE_ENV=production
EXPOSE 4400
CMD ["node", "src/server.js"]
