#!/bin/sh
# Ubuntu packages for a CI job, tried again when a mirror does not answer
# (a GitHub runner's name lookups fail now and then, and the whole run
# went red for it):
#
#   sh tools/apt.sh clang lld
#
# Up to six tries, 30 to 150 seconds apart (some 7 minutes in all).
for try in 1 2 3 4 5 6; do
  # (apt's own tries off: with a mirror's name not found they spun, "Tried
  # to start delayed item", twelve million lines for two hours on a runner
  # -- these tries are ours, and one that hangs anyway is stopped)
  if sudo timeout 600 apt-get update -o Acquire::Retries=0 &&
     sudo timeout 1800 apt-get install -y -o Acquire::Retries=0 "$@"; then
    exit 0
  fi
  [ "$try" = 6 ] && break
  echo "apt: try $try did not get them; again in $((try * 30)) s"
  sleep $((try * 30))
  sudo dpkg --configure -a || true      # (a try stopped halfway)
done
exit 1
