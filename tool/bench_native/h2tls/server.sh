#!/usr/bin/env bash
#
# Run the TLS HTTP/2 + HTTP/1.1 benchmark server (see server.mjs) on this Mac.
# The certificate is self-signed; benchmark clients skip verification.
#
#   tool/bench_native/h2tls/server.sh start [port]   # prints the port
#   tool/bench_native/h2tls/server.sh stop
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ACTION="${1:-}"; PORT="${2:-18443}"
OUT="../../../build/bench/h2tls"; mkdir -p "$OUT"

case "$ACTION" in
  start)
    { [ -f "$OUT/key.pem" ] && [ -f "$OUT/cert.pem" ]; } ||
      openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -subj "/CN=nitro_http bench" \
        >/dev/null 2>&1
    [ -f "$OUT/pid" ] && kill "$(cat "$OUT/pid")" 2>/dev/null || true
    node server.mjs "$PORT" "$OUT/key.pem" "$OUT/cert.pem" >"$OUT/server.log" 2>&1 &
    pid=$!
    echo "$pid" > "$OUT/pid"
    # Ready means OUR child is alive and the port answers: a listener someone
    # else holds makes the child exit, which the second check catches.
    ready=0
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then ready=1; break; fi
      perl -e 'select(undef, undef, undef, 0.1)'
    done
    perl -e 'select(undef, undef, undef, 0.3)'
    if [ "$ready" != 1 ] || ! kill -0 "$pid" 2>/dev/null; then
      echo "server did not start on port $PORT:" >&2
      cat "$OUT/server.log" >&2
      kill "$pid" 2>/dev/null || true
      rm -f "$OUT/pid"
      exit 1
    fi
    echo "$PORT"
    ;;
  stop)
    [ -f "$OUT/pid" ] && kill "$(cat "$OUT/pid")" 2>/dev/null || true
    rm -f "$OUT/pid"
    ;;
  *) echo "usage: $0 start [port] | stop" >&2; exit 2 ;;
esac
