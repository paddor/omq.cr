#!/usr/bin/env bash
# Runs each counterpart in this directory against the same PUSH/PULL and
# REQ/REP workload, printing to stdout. Missing toolchains are skipped
# with a clear one-line note so the suite still runs everywhere else.
#
# Results are paste-ready for README.md. Pin the same hardware between
# runs — CPU frequency scaling and noisy-neighbor cores will skew deltas
# more than the gap between implementations.

set -u
cd "$(dirname "$0")"

JEROMQ_VERSION="0.6.0"
JEROMQ_JAR="jeromq-${JEROMQ_VERSION}.jar"
JEROMQ_URL="https://repo1.maven.org/maven2/org/zeromq/jeromq/${JEROMQ_VERSION}/${JEROMQ_JAR}"
JRUBY_BIN="${JRUBY_BIN:-/home/roadster/.rubies/jruby-10.1.0.0/bin/ruby}"

section() {
  echo
  echo "================================================================"
  echo "$1"
  echo "================================================================"
}

skip() {
  section "$1 — SKIPPED"
  echo "$2"
}

section "omq.cr (this repo)"
if command -v crystal >/dev/null 2>&1; then
  crystal run --release --no-debug omq.cr
else
  skip "omq.cr" "crystal not in PATH"
fi

section "pyzmq (CPython + libzmq)"
if command -v python3 >/dev/null 2>&1 && python3 -c "import zmq" 2>/dev/null; then
  python3 pyzmq.py
else
  skip "pyzmq" "install: pip install pyzmq (and python3 on PATH)"
fi

section "JeroMQ (JRuby + Java interop)"
if [ ! -x "$JRUBY_BIN" ]; then
  skip "JeroMQ" "JRuby not found at $JRUBY_BIN (set \$JRUBY_BIN or install JRuby 10.x)"
else
  if [ ! -f "$JEROMQ_JAR" ]; then
    echo "Downloading $JEROMQ_JAR from Maven Central…"
    curl -fsSL -o "$JEROMQ_JAR" "$JEROMQ_URL" || { echo "download failed"; exit 1; }
  fi
  # JRuby doesn't understand MRI's --jit / --yjit, so clear any inherited
  # RUBYOPT the user may have set for MRI.
  RUBYOPT="" "$JRUBY_BIN" -J-cp "$JEROMQ_JAR" jeromq.rb
fi

section "Ruby OMQ (pure Ruby)"
if command -v ruby >/dev/null 2>&1 && ruby -ropq -e 'exit' 2>/dev/null; then
  ruby --yjit omq.rb
else
  skip "Ruby OMQ" "install: gem install omq (and ruby >= 3.3 on PATH)"
fi
