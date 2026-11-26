#!/usr/bin/env bash
# Runs inside the ruby:3.4.10-bookworm container that scripts/ci/tests.sh starts.
#   all                          every lane; a failing lane does not stop the others
#   rerun <file> <class> <name>  one test, picked by its JUnit attributes
set -uo pipefail
ROOT=/src
CACHE=$ROOT/.ci-cache
NODE_VERSION=24.15.0  # jsdom wants ^24.15
export PGHOST=localhost PGUSER=postgres
export BUNDLE_PATH=$CACHE/bundle
export PLAYWRIGHT_BROWSERS_PATH=$CACHE/ms-playwright
export UV_CACHE_DIR=$CACHE/uv UV_PYTHON_INSTALL_DIR=$CACHE/uv-python
export YARN_CACHE_FOLDER=$CACHE/yarn COREPACK_HOME=$CACHE/corepack
export npm_config_cache=$CACHE/npm

setup() {
  set -e
  mkdir -p "$CACHE/bin"
  # ffmpeg and zip make the Disk samples; postgresql-client gives createdb and pg_dump.
  apt-get update -qq && apt-get install -y -qq --no-install-recommends ffmpeg zip postgresql-client xz-utils poppler-utils libvips-tools >/dev/null
  local arch; arch=$(dpkg --print-architecture); [ "$arch" = amd64 ] && arch=x64
  local node=$CACHE/node-v$NODE_VERSION-linux-$arch
  [ -x "$node/bin/node" ] || curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$arch.tar.xz" | tar -xJ -C "$CACHE"
  export PATH=$node/bin:$CACHE/bin:$PATH
  corepack enable --install-directory "$CACHE/bin"
  [ -x "$CACHE/bin/uv" ] || curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$CACHE/bin" INSTALLER_NO_MODIFY_PATH=1 sh >/dev/null
  (cd $ROOT/api && bundle install --quiet --jobs 8)
  (cd $ROOT/ui/web && yarn install --frozen-lockfile --ignore-scripts --silent && npx playwright install --with-deps chromium firefox webkit >/dev/null)
  (cd $ROOT/ui/cli && uv sync --quiet --extra test)
  # The Disk MCP smoke spec drives the MCP SDK from the Android MCP tool's node_modules.
  (cd $ROOT/ui/android/tools/android-mcp && npm install --silent --no-audit --no-fund)
  set +e
}

rspec_lane() {
  cd $ROOT/api
  export RAILS_ENV=test DATABASE_URL=postgres://postgres@localhost:5432
  bin/rails db:drop db:create db:schema:load >/dev/null || return 1
  # The test Disk bucket's CORS; no spec needs it, so a failure only warns.
  bin/rails disk:storage:setup >/dev/null 2>&1 || echo "warning: disk:storage:setup failed" >&2
  bundle exec rspec "$@" --format progress --format RspecJunitFormatter --out $ROOT/reports/junit/rspec.xml
}

vitest_lane() {
  # The native email-body bundles are generated and gitignored; bundleSync.test.js
  # compares them with a fresh build (as the GitHub CI web job does).
  (cd $ROOT && bin/android bundle >/dev/null && cp ui/android/app/src/main/assets/email-body.js ui/ios/Resources/email-body.js) || return 1
  cd $ROOT/ui/web
  npx vitest run --project unit --reporter=default --reporter=junit --outputFile.junit=$ROOT/reports/junit/vitest.xml "$@"
}

pytest_lane() {
  cd $ROOT/ui/cli
  uv run pytest -q -o junit_family=xunit1 --junitxml=$ROOT/reports/junit/pytest.xml "$@"
}

disk_lane() {
  cd $ROOT/ui/web
  E2E_DISK_BUCKET_READY=1 PLAYWRIGHT_JUNIT_OUTPUT_NAME=$ROOT/reports/junit/e2e-disk.xml \
    node e2e/disk/prepare.mjs && \
  E2E_DISK_BUCKET_READY=1 PLAYWRIGHT_JUNIT_OUTPUT_NAME=$ROOT/reports/junit/e2e-disk.xml \
    npx playwright test -c e2e/disk/playwright.config.js --project=chromium --project=firefox --project=webkit --reporter=list,junit "$@"
}

# One failed test again. Pushleft passes the JUnit testcase's file, classname and
# name; which tool wrote it tells which lane it belongs to.
rerun() {
  local file=$1 class=$2 name=$3
  case "$file$class" in
    *_spec.rb*) rspec_lane "${file#./}" -e "$name" ;;
    *.test.js*|*.test.jsx*|*.test.ts*|*.test.tsx*) vitest_lane "${file:-$class}" ;;
    *.spec.js*) disk_lane "$(basename "${file:-$class}")" -g "$(printf '%s' "${name##* › }" | sed 's/[][\\.*+?(){}|^$]/\\&/g')" ;;
    tests.*|*tests/test_*.py*)
      local id=${file:-$(echo "${class%.*}" | tr . /).py}
      local last=${class##*.}; [[ $last =~ ^[A-Z] ]] && id+="::$last"
      pytest_lane "$id::$name" ;;
    *) echo "rerun: no lane for file='$file' classname='$class'" >&2; return 2 ;;
  esac
}

# Not `setup || …`: set -e is off inside a function on the left of ||. Here a
# failed install ends the script (non-zero) and no lane runs on half a setup.
setup
status=0
if [ "$1" = rerun ]; then
  shift; rerun "$@"; status=$?
else
  for lane in rspec_lane vitest_lane pytest_lane disk_lane; do
    echo "==> $lane"
    ( $lane ) || { echo "<== $lane failed"; status=1; }
  done
fi
# Files written here belong to root; hand them back to whoever started the run.
chown -R "${CI_UID:-0}" $ROOT/reports $ROOT/ui/web/e2e/disk/.state 2>/dev/null
exit $status
