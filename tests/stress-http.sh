#!/bin/bash
# Stress test for std/http: memory stability under sustained load.
# Sends requests in rounds against a live server and reports RSS per round —
# a flat RSS across rounds means no per-request leak (cf. the in-corpus leak
# gate examples/http/1670). NOT part of `zig build test` (it needs a live
# server + a load tool and runs longer than the corpus timeout).
#
# Usage: bash tests/stress-http.sh
# Requires: ab (ApacheBench) or curl. Honors SX_HTTP_POOL to test pool mode.

set -e
cd "$(dirname "$0")/.."
mkdir -p .sx-tmp

PORT=9876
BIN=.sx-tmp/sx-stress-server

echo "building std/http server (bench/sx-server.sx)..."
zig build >/dev/null 2>&1
./zig-out/bin/sx build bench/sx-server.sx -o "$BIN"

PORT=$PORT "$BIN" >/dev/null 2>&1 &
SERVER_PID=$!
sleep 0.4
if ! kill -0 $SERVER_PID 2>/dev/null; then echo "FAIL: server did not start"; exit 1; fi

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    rm -f "$BIN"
}
trap cleanup EXIT

rss_kb() { ps -o rss= -p $SERVER_PID | tr -d ' '; }
initial_rss=$(rss_kb)

# One round = $1 requests at concurrency 50; prefers ab, falls back to curl.
run_round() {
    local count=$1 failures=0
    if command -v ab >/dev/null 2>&1; then
        local out; out=$(ab -n "$count" -c 50 -q "http://127.0.0.1:$PORT/" 2>/dev/null || true)
        failures=$(echo "$out" | awk '/Failed requests:/ {print $3}')
        [ -z "$failures" ] && failures="?"
    else
        for i in $(seq 1 "$count"); do
            local r; r=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/" 2>/dev/null) || true
            [ "$r" != "200" ] && failures=$((failures + 1))
        done
    fi
    local rss; rss=$(rss_kb)
    printf "  %-7s requests  ->  RSS %6s KB  (delta %+d KB, %s failed)\n" \
        "$count" "$rss" "$((rss - initial_rss))" "$failures"
}

echo ""
echo "std/http stress — initial RSS: ${initial_rss} KB  (pool=${SX_HTTP_POOL:-0})"
echo ""
run_round 2000
run_round 5000
run_round 20000
run_round 20000

final_rss=$(rss_kb)
echo ""
echo "--- summary ---"
echo "initial RSS: ${initial_rss} KB   final RSS: ${final_rss} KB   delta: $((final_rss - initial_rss)) KB"
echo "(a small initial growth then a FLAT delta across rounds = no per-request leak)"
