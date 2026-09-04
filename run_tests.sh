#!/usr/bin/env bash
set -e

echo ""
printf "\033[1;33m=======> %s\033[0m\n" "$(lua -v 2>&1)"
MOONBUG_TEST=1 MOONBUG_LOG=off lua ./tests/run.lua

echo ""
printf "\033[1;33m=======> %s\033[0m\n" "$(luajit -v 2>&1)"
MOONBUG_TEST=1 MOONBUG_LOG=off luajit ./tests/run.lua
