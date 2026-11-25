#!/bin/sh
# Ubuntu packages for a CI job, tried again when a mirror does not answer
# (a GitHub runner's name lookups fail now and then, and the whole run
# went red for it):
#
#   sh tools/apt.sh clang lld
#
# Up to six tries, 30 to 150 seconds apart (some 7 minutes in all).
#
# A runner whose sources have no Ubuntu archive -- GitHub's ubuntu-26.04
# image of November 2026 had Microsoft's alone, and every try said "Unable
# to locate package clang" -- gets Ubuntu's own for its release first.
if ! grep -rqsE 'ubuntu\.com|ubuntu-ports' /etc/apt/sources.list /etc/apt/sources.list.d/; then
  . /etc/os-release
  case $(dpkg --print-architecture) in
    amd64|i386)
      url=http://archive.ubuntu.com/ubuntu
      sec=http://security.ubuntu.com/ubuntu ;;
    *)
      url=http://ports.ubuntu.com/ubuntu-ports
      sec=$url ;;
  esac
  key=/usr/share/keyrings/ubuntu-archive-keyring.gpg
  signed=""
  [ -f "$key" ] && signed="Signed-By: $key"
  printf 'Types: deb\nURIs: %s\nSuites: %s %s-updates %s-backports\nComponents: main universe restricted multiverse\n%s\n\nTypes: deb\nURIs: %s\nSuites: %s-security\nComponents: main universe restricted multiverse\n%s\n' \
    "$url" "$VERSION_CODENAME" "$VERSION_CODENAME" "$VERSION_CODENAME" "$signed" \
    "$sec" "$VERSION_CODENAME" "$signed" | sudo tee /etc/apt/sources.list.d/ubuntu-archive.sources > /dev/null
  echo "apt: no Ubuntu archive among the sources: $url ($VERSION_CODENAME) added"
fi
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
