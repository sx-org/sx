#!/bin/bash
# Honest benchmark of the std/http server (bench/sx-server.sx).
# Measures plaintext GET, keep-alive, and pool-mode throughput/latency with ab,
# and (if they build) compares against zig, Go, and Rust baselines.
# Records the host/OS/flags so numbers are reproducible. NOT part of the corpus.
#
# Usage: bash bench/run.sh [requests] [concurrency]
# Requires: ab (ApacheBench).

set -e
cd "$(dirname "$0")/.."
mkdir -p .sx-tmp

REQUESTS=${1:-50000}
CONCURRENCY=${2:-50}
WARMUP=1000
BENCH_FAILURES=0
SX_PORT=8080
SXP_PORT=8082          # sx, pool mode
ZIG_PORT=8081
GO_PORT=8083
RUST_PORT=8084

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; RESET='\033[0m'

cleanup() {
    [ -n "$RSS_MONITOR_PID" ] && kill "$RSS_MONITOR_PID" 2>/dev/null || true
    for p in "$SX_PID" "$SXP_PID" "$ZIG_PID" "$GO_PID" "$RUST_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT

if ! command -v ab >/dev/null 2>&1; then echo "need ApacheBench (ab) on PATH"; exit 1; fi

echo -e "${BOLD}=== std/http benchmark ===${RESET}"
echo "host:    $(uname -msr)"
echo "cpu:     $( (sysctl -n machdep.cpu.brand_string 2>/dev/null) || (grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2) || echo '?')"
echo "ab:      $(ab -V 2>/dev/null | head -1)"
echo "load:    ${REQUESTS} requests @ concurrency ${CONCURRENCY} (warmup ${WARMUP})"
echo ""

echo -e "${BOLD}Building sx server...${RESET}"
./zig-out/bin/sx build bench/sx-server.sx -o .sx-tmp/sx-server
HAVE_ZIG=0
if zig build-exe bench/http-server.zig -O ReleaseFast -femit-bin=.sx-tmp/zig-server 2>/dev/null; then HAVE_ZIG=1; else echo "(zig baseline did not build — skipping comparison)"; fi
HAVE_GO=0
if command -v go >/dev/null 2>&1 && (cd bench && go build -o ../.sx-tmp/go-server .) 2>/dev/null; then HAVE_GO=1; else echo "(go baseline did not build — skipping comparison)"; fi
HAVE_RUST=0
if command -v cargo >/dev/null 2>&1 && cargo build --release --manifest-path bench/rust-http-server/Cargo.toml >/dev/null 2>&1; then HAVE_RUST=1; else echo "(rust baseline did not build — skipping comparison)"; fi
echo ""

wait_for_port() {
    for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$1" 2>/dev/null && return 0; sleep 0.1; done
    echo "FAIL: server on port $1 did not start" >&2; return 1
}

start_rss_monitor() {
    RSS_FILE=".sx-tmp/rss-$1.txt"
    : > "$RSS_FILE"
    (
        max=0
        while kill -0 "$1" 2>/dev/null; do
            rss=$(ps -o rss= -p "$1" 2>/dev/null | tr -d ' ')
            case "$rss" in
                ''|*[!0-9]*) ;;
                *) [ "$rss" -gt "$max" ] && max=$rss ;;
            esac
            echo "$max" > "$RSS_FILE"
            sleep 0.1
        done
    ) &
    RSS_MONITOR_PID=$!
}

stop_rss_monitor() {
    [ -n "$RSS_MONITOR_PID" ] && kill "$RSS_MONITOR_PID" 2>/dev/null || true
    wait "$RSS_MONITOR_PID" 2>/dev/null || true
    RSS_MONITOR_PID=""
    rss=$(cat "$RSS_FILE" 2>/dev/null || echo 0)
    if [ -n "$rss" ] && [ "$rss" -gt 0 ] 2>/dev/null; then
        awk -v kb="$rss" 'BEGIN { printf "Peak RSS:              %.1f MiB\n", kb / 1024 }'
    else
        echo "Peak RSS:              unavailable"
    fi
}

# $1 label  $2 port  $3 color  $4 extra-ab-args  $5 server-pid
run_bench() {
    echo -e "${BOLD}${3}--- $1 (port $2) ---${RESET}"
    start_rss_monitor "$5"
    ab -n "$WARMUP" -c 10 -q $4 "http://127.0.0.1:$2/" >/dev/null 2>&1 || true
    set +e
    ab_output=$(ab -n "$REQUESTS" -c "$CONCURRENCY" -q $4 "http://127.0.0.1:$2/" 2>&1)
    ab_status=$?
    set -e
    echo "$ab_output" | grep -E 'Requests per second|Time per request|Transfer rate|Failed requests|Complete requests|Total transferred' || true
    if [ "$ab_status" -ne 0 ]; then
        echo "$ab_output" | tail -5
    fi
    stop_rss_monitor
    if [ "$ab_status" -ne 0 ]; then
        echo "ab exit status:         $ab_status"
        BENCH_FAILURES=1
    fi
    echo ""
}

# sx, inline mode, plain (Connection: close per ab default)
PORT=$SX_PORT .sx-tmp/sx-server >/dev/null 2>&1 & SX_PID=$!; wait_for_port $SX_PORT
run_bench "sx inline — plain"      $SX_PORT "$GREEN" ""   "$SX_PID"
run_bench "sx inline — keep-alive" $SX_PORT "$GREEN" "-k" "$SX_PID"
kill "$SX_PID" 2>/dev/null; wait "$SX_PID" 2>/dev/null || true; SX_PID=""; sleep 0.3

# sx, pool mode (4 workers)
PORT=$SXP_PORT SX_HTTP_POOL=4 .sx-tmp/sx-server >/dev/null 2>&1 & SXP_PID=$!; wait_for_port $SXP_PORT
run_bench "sx pool(4) — keep-alive" $SXP_PORT "$GREEN" "-k" "$SXP_PID"
kill "$SXP_PID" 2>/dev/null; wait "$SXP_PID" 2>/dev/null || true; SXP_PID=""; sleep 0.3

if [ "$HAVE_ZIG" = 1 ]; then
    .sx-tmp/zig-server >/dev/null 2>&1 & ZIG_PID=$!; wait_for_port $ZIG_PORT
    run_bench "zig baseline — keep-alive" $ZIG_PORT "$CYAN" "-k" "$ZIG_PID"
    kill "$ZIG_PID" 2>/dev/null; wait "$ZIG_PID" 2>/dev/null || true; ZIG_PID=""
fi

if [ "$HAVE_GO" = 1 ]; then
    PORT=$GO_PORT .sx-tmp/go-server >/dev/null 2>&1 & GO_PID=$!; wait_for_port $GO_PORT
    run_bench "go baseline — keep-alive" $GO_PORT "$CYAN" "-k" "$GO_PID"
    kill "$GO_PID" 2>/dev/null; wait "$GO_PID" 2>/dev/null || true; GO_PID=""
fi

if [ "$HAVE_RUST" = 1 ]; then
    PORT=$RUST_PORT bench/rust-http-server/target/release/rust-http-server >/dev/null 2>&1 & RUST_PID=$!; wait_for_port $RUST_PORT
    run_bench "rust baseline — keep-alive" $RUST_PORT "$CYAN" "-k" "$RUST_PID"
    kill "$RUST_PID" 2>/dev/null; wait "$RUST_PID" 2>/dev/null || true; RUST_PID=""
fi

if [ "$BENCH_FAILURES" -ne 0 ]; then
    echo -e "${BOLD}Done with benchmark failures.${RESET}"
    exit 1
fi

echo -e "${BOLD}Done.${RESET}"
