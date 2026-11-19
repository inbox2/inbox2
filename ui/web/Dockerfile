FROM node:22-slim

WORKDIR /app

COPY --chown=node:node package.json yarn.lock ./
USER node
RUN yarn install --frozen-lockfile

COPY --chown=node:node . .

EXPOSE 5173
CMD ["yarn", "dev", "--host", "0.0.0.0"]
