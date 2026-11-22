#!/usr/bin/env sh
# Tests of the VPN's Java on a computer (no phone): its servers and block list, its answers,
# why a lookup failed (VpnLogicTest); and the hello in pieces or with no name sent, against a
# TLS server of its own on this computer (SplitTest, tlsserver.py). Needs a JDK, openssl and
# python3.
#
#   sh examples/retrodns/glue/tests/check.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
glue=$(dirname "$here")
work=$(mktemp -d)
trap 'kill $srv 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p "$work/stubs" "$work/classes"
javac -source 8 -target 8 -nowarn -Xlint:-options -d "$work/stubs" $(find "$glue/stubs" -name '*.java')
javac -source 8 -target 8 -nowarn -Xlint:-options -cp "$work/stubs" -d "$work/classes" \
  $(find "$glue/java" -name '*.java') "$here/VpnLogicTest.java" "$here/SplitTest.java"
java -cp "$work/classes:$work/stubs" net.foxoman.retrodns.VpnLogicTest
cd "$work"
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 2 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
keytool -importcert -noprompt -alias t -file cert.pem -keystore trust.jks -storepass changeit >/dev/null 2>&1
python3 "$here/tlsserver.py" 18853 18854 > server.log 2>&1 &
srv=$!
sleep 1
java -Djavax.net.ssl.trustStore="$work/trust.jks" -Djavax.net.ssl.trustStorePassword=changeit \
  -cp "$work/classes" net.foxoman.retrodns.SplitTest 18853 18854
sleep 0.5
# (the hello arrived in pieces of 40 bytes; whole when not split)
grep -q "hello reads \[40, 40" server.log || { echo "the hello was not in pieces"; cat server.log; exit 1; }
echo "vpn java ok"
