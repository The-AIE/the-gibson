FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates python3 make g++  && rm -rf /var/lib/apt/lists/*
RUN npm i -g @xai-official/grok@1.0.3
ENV HOME=/home/agent
RUN mkdir -p /home/agent/.grok && chmod -R 777 /home/agent
WORKDIR /work
