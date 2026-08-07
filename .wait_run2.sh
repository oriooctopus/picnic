#!/bin/bash
RUN_ID="$1"
while true; do
  s=$(gh run view "$RUN_ID" --repo oriooctopus/picnic --json status,conclusion)
  status=$(echo "$s" | jq -r '.status')
  concl=$(echo "$s" | jq -r '.conclusion')
  echo "status=$status conclusion=$concl"
  if [ "$status" = "completed" ]; then break; fi
  sleep 30
done
