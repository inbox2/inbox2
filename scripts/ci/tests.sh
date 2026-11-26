#!/usr/bin/env bash
# The full test suite, as the Pushleft `tests` schedule runs it (.pl.yaml).
#
#   scripts/ci/tests.sh                               every lane, JUnit XML in reports/junit/
#   scripts/ci/tests.sh rerun <file> <classname> <name>   one failed test again (Pushleft's rerun)
#
# The runner VM has Docker, Node and Rust, but no Ruby or Python. So this script
# starts Postgres and Garage as containers, then runs each lane inside one Ruby
# container (scripts/ci/in-container.sh) that adds Node, uv and Playwright. Tools and
# gems are kept in .ci-cache, the schedule's cache path.
#
# Not on a dev machine as is: it binds 5432, reuses the dev Garage container (same
# compose project) and writes Linux node_modules into the checkout. To try it
# locally, run a copy of the repository inside a `docker:dind` container.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
mkdir -p reports/junit .ci-cache

services() {
  if ! docker inspect -f '{{.State.Running}}' ci-postgres 2>/dev/null | grep -q true; then
    docker rm -f ci-postgres >/dev/null 2>&1
    # 15: the Ruby image's pg_dump is 15, and the Disk suite runs pg_dump.
    docker run -d --name ci-postgres -p 127.0.0.1:5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:15 >/dev/null \
      || { echo "postgres did not start" >&2; exit 1; }
  fi
  docker compose -f docker/docker-compose.yml --profile storage up -d garage
  GARAGE_INIT_NO_FOLLOW=1 bin/garage-init >/dev/null 2>&1 || { echo "garage-init failed" >&2; exit 1; }
  local g=(docker compose -f docker/docker-compose.yml exec -T garage /garage)
  # The test env's attachment bucket (storage.yml) and the Disk e2e bucket; garage-init
  # makes only the dev ones. The e2e bucket's CORS is not set here: prepare.mjs runs
  # `e2e:disk:seed`, whose storage.setup! sets it for the e2e web origin (env.js).
  for b in inbox2-test-attachments inbox2-e2e-disk; do
    "${g[@]}" bucket info "$b" >/dev/null 2>&1 || "${g[@]}" bucket create "$b" >/dev/null || exit 1
    "${g[@]}" bucket allow --read --write --owner "$b" --key GK1b0a5c9d3e7f2a8b4c6d0e12 >/dev/null || exit 1
  done
  for _ in $(seq 60); do docker exec ci-postgres pg_isready -q && return 0; sleep 1; done
  echo "postgres not ready after 60 s" >&2; exit 1
}

in_container() {
  docker run --rm --network host --shm-size 2g \
    -v "$ROOT:/src" -w /src \
    -e CI_UID="$(id -u)" \
    ruby:3.4.10-bookworm bash scripts/ci/in-container.sh "$@"
}

services
if [ "${1:-}" = rerun ]; then
  shift
  in_container rerun "$@"
else
  rm -f reports/junit/*.xml
  in_container all
fi
