# syntax=docker/dockerfile:1
# Pushleft image for inbox2: every production role runs from this one image
# (Pushleft builds one image per project, and roles reach each other by private
# name only inside one project). Context is the repository root (.pl.yaml).
#
#   api, worker, nats-subscriber, release  the Rails app (as api/Dockerfile)
#   mx, smtp                               the Go mail binaries (as mta/Dockerfile)
#   nats                                   nats-server, JetStream on a volume
#   rspamd                                 rspamd from rspamd.com's apt repo; its
#                                          bayes store is the managed Valkey, its
#                                          DNS an unbound inside the same container
#
# api/Dockerfile and mta/Dockerfile stay for local builds only.

ARG RUBY_VERSION=3.4.10

FROM golang:1.26-alpine AS mta
WORKDIR /src
COPY mta/go.mod mta/go.sum ./
RUN go mod download
COPY mta/ .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/ ./cmd/mx ./cmd/smtp ./cmd/imap

FROM nats:2.14.9-alpine AS nats

FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base
WORKDIR /rails
# libvips-tools' vips, vipsthumbnail and vipsheader are taken out of its .deb:
# the package depends on python3 for vipsprofile alone, which nothing here runs.
# Disk::Thumbnailer runs vips with its untrusted loaders blocked (.trivyignore).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libsodium23 postgresql-client libvips42t64 ffmpeg poppler-utils && \
    cd /tmp && apt-get download libvips-tools && dpkg-deb -x libvips-tools_*.deb /tmp/vips-tools && \
    cp /tmp/vips-tools/usr/bin/vips /tmp/vips-tools/usr/bin/vipsthumbnail /tmp/vips-tools/usr/bin/vipsheader /usr/local/bin/ && \
    rm -rf /tmp/vips-tools /tmp/libvips-tools_*.deb && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

FROM base AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
COPY api/vendor/* ./vendor/
COPY api/Gemfile api/Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile
COPY api/ .
RUN bundle exec bootsnap precompile -j 1 app/ lib/
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

FROM base
# rspamd stable from its own repository (Debian's 3.12 is older than the 4.x
# whose bayes data comes along), its bayes store is the managed Valkey.
# unbound is rspamd's own resolver (rspamd/unbound.conf).
RUN apt-get update -qq && apt-get install --no-install-recommends -y gnupg && \
    curl -fsSL https://rspamd.com/apt-stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/rspamd.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/rspamd.gpg] https://rspamd.com/apt-stable/ trixie main" > /etc/apt/sources.list.d/rspamd.list && \
    apt-get update -qq && apt-get install --no-install-recommends -y rspamd unbound && \
    apt-get purge -y gnupg && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
# The base image lags Debian security updates (see api/Dockerfile).
# Pushleft passes PUSHLEFT_OS_REFRESH=<UTC date> on every build, so this layer
# reruns daily; APT_UPGRADE_AT forces it by hand.
ARG APT_UPGRADE_AT=2026-11-07
ARG PUSHLEFT_OS_REFRESH
RUN echo "apt upgrade at $APT_UPGRADE_AT, refresh $PUSHLEFT_OS_REFRESH" && \
    apt-get update -qq && apt-get upgrade -y && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
RUN rm -f /usr/local/lib/ruby/gems/*/specifications/default/resolv-*.gemspec

COPY --from=mta /out/mx /out/smtp /out/imap /usr/local/bin/
COPY --from=nats /usr/local/bin/nats-server /usr/local/bin/nats-server
COPY deploy/pushleft/nats.conf /etc/nats/nats.conf
COPY deploy/pushleft/rspamd/local.d/ /etc/rspamd/local.d/
COPY deploy/pushleft/rspamd/unbound.conf /etc/rspamd/unbound.conf
COPY deploy/pushleft/rspamd/start /usr/local/bin/inbox2-rspamd

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
COPY deploy/pushleft/run /usr/local/bin/inbox2-run

EXPOSE 4000
CMD ["inbox2-run", "bundle", "exec", "puma", "-C", "config/puma.rb"]
