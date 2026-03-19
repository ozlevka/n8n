ARG NODE_VERSION=24
ARG GIT_COMMIT_HASH="773452bb"

# 1. Create an image to build n8n
FROM ghcr.io/ozlevka/n8n-base:${NODE_VERSION}-${GIT_COMMIT_HASH} AS builder

# Build the application from source
WORKDIR /src
COPY . /src
RUN DOCKER_BUILD=true pnpm install --frozen-lockfile
RUN pnpm turbo run build --filter=n8n...

# Delete all dev dependencies
RUN jq 'del(.pnpm.patchedDependencies)' package.json > package.json.tmp; mv package.json.tmp package.json
RUN node .github/scripts/trim-fe-packageJson.js

# Delete any source code, source-mapping, or typings
RUN find . -type f -name "*.ts" -o -name "*.js.map" -o -name "*.vue" -o -name "tsconfig.json" -o -name "*.tsbuildinfo" | xargs rm -rf

# Deploy the `n8n` package into /compiled
RUN mkdir /compiled
RUN NODE_ENV=production DOCKER_BUILD=true pnpm --filter=n8n --prod --no-optional --legacy deploy /compiled

# 2. Start with a new clean image with just the code that is needed to run n8n
FROM ghcr.io/ozlevka/n8n-base:${NODE_VERSION}-${GIT_COMMIT_HASH}
ENV NODE_ENV=production

ARG N8N_RELEASE_TYPE=dev
ENV N8N_RELEASE_TYPE=${N8N_RELEASE_TYPE}

WORKDIR /home/node
COPY --from=builder /compiled /usr/local/lib/node_modules/n8n
COPY docker/images/n8n/docker-entrypoint.sh /

# Setup the Task Runner Launcher
ARG LAUNCHER_VERSION=1.1.2
COPY docker/images/runners/n8n-task-runners.json /etc/n8n-task-runners.json
# Download, verify, then extract the launcher binary for amd64
RUN \
	mkdir /launcher-temp && \
	cd /launcher-temp && \
	wget https://github.com/n8n-io/task-runner-launcher/releases/download/${LAUNCHER_VERSION}/task-runner-launcher-${LAUNCHER_VERSION}-linux-amd64.tar.gz && \
	wget https://github.com/n8n-io/task-runner-launcher/releases/download/${LAUNCHER_VERSION}/task-runner-launcher-${LAUNCHER_VERSION}-linux-amd64.tar.gz.sha256 && \
	echo "$(cat task-runner-launcher-${LAUNCHER_VERSION}-linux-amd64.tar.gz.sha256) task-runner-launcher-${LAUNCHER_VERSION}-linux-amd64.tar.gz" > checksum.sha256 && \
	sha256sum -c checksum.sha256 && \
	tar xvf task-runner-launcher-${LAUNCHER_VERSION}-linux-amd64.tar.gz --directory=/usr/local/bin && \
	cd - && \
	rm -r /launcher-temp

RUN \
	cd /usr/local/lib/node_modules/n8n && \
	npm rebuild sqlite3 && \
	cd - && \
	ln -s /usr/local/lib/node_modules/n8n/bin/n8n /usr/local/bin/n8n && \
	mkdir .n8n && \
	chown node:node .n8n

ENV SHELL=/bin/sh
USER node
ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
