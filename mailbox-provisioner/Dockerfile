FROM node:22-alpine

RUN apk add --no-cache docker-cli

WORKDIR /app
COPY server.js ./

ENV HOST=0.0.0.0 \
    PORT=3010 \
    MAILSERVER_CONTAINER=mailserver

EXPOSE 3010
CMD ["node", "server.js"]
