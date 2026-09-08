#!/usr/bin/env bash
set -e

LUA="lua"
FLAG_COVERAGE=0
FLAG_WATCH=0
MOONBUG_TEST_COVERAGE_PORT="${MOONBUG_TEST_COVERAGE_PORT:-8000}"

usage() {
    cat "
    usage: ./run_tests.sh [--jit] [--cov] [--watch]

    --jit   run tests with luajit instead of lua
    --cov   collect coverage, generate \`moonbug.report.html\` report
    --watch re-run on changes, with --cov also host report at http://localhost:${MOONBUG_TEST_COVERAGE_PORT}/moonbug.report.html

            Use MOONBUG_TEST_COVERAGE_PORT=... to customize the port

    "
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --jit)
        LUA="luajit"
        ;;
    --cov)
        FLAG_COVERAGE=1
        ;;
    --watch)
        FLAG_WATCH=1
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "unknown option: $1"
        usage
        exit 2
        ;;
    esac
    shift
done

report_coverage() {
    [[ -f moonbug.report.html ]] || {
        echo "n/a"
        return
    }
    awk '
    /<strong>[0-9.]+%<\/strong> Coverage/ {
      match($0, /<strong>[0-9.]+%<\/strong> Coverage/);
      s = substr($0, RSTART, RLENGTH);
      gsub(/<[^>]+>/, "", s); gsub(/% Coverage/, "", s);
      val = s
    }
    END { print (val == "" ? "n/a" : val) }
  ' moonbug.report.html

}

run_once() {
    if [[ $FLAG_COVERAGE -eq 1 ]]; then
        rm -f ./moonbug.stats.out
        echo ""
        printf "\033[1;33m=======> %s\033[0m\n" "$($LUA -v 2>&1)"
        MOONBUG_LUA="$LUA" MOONBUG_TEST=1 MOONBUG_LOG=off "$LUA" -lluacov ./tests/run.lua

        luacov
        echo ""
        printf "\033[1;33m=======> coverage: %s%%\033[0m\n" "$(report_coverage)"
    else
        echo ""
        printf "\033[1;33m=======> %s\033[0m\n" "$($LUA -v 2>&1)"
        MOONBUG_LUA="$LUA" MOONBUG_TEST=1 MOONBUG_LOG=off "$LUA" ./tests/run.lua
    fi
}

if [[ $FLAG_WATCH -eq 1 ]]; then
    args=()

    [[ $LUA == "luajit" ]] && args+=(--jit)
    [[ $FLAG_COVERAGE -eq 1 ]] && args+=(--cov)

    if [[ $FLAG_COVERAGE -eq 1 ]]; then
        python3 -m http.server "$MOONBUG_TEST_COVERAGE_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
        server_pid=$!
        trap 'kill "$server_pid" 2>/dev/null || true' EXIT INT TERM
        printf "\033[1;36m==> report: http://127.0.0.1:%s/moonbug.report.html\033[0m\n" "$MOONBUG_TEST_COVERAGE_PORT"
    fi

    printf "\033[1;36m==> watching for changes...\033[0m\n"
    watchexec -w src -w tests -- ./run_tests.sh "${args[@]}"
else
    run_once
fi
