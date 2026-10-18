#!/bin/bash
cd "$(dirname "$0")"
. ./BUILD; U=$URL
for i in $(seq 1 500); do
  curl -fsS -L -C - --retry 3 -o recovery.zip "$U" 2>/dev/null && { echo DONE; exit 0; }
  sleep 2
done
echo GAVEUP
