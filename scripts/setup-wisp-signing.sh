#!/usr/bin/env bash
# Create a self-signed code signing certificate, "Wisp Local Signing", in your
# login keychain. Run it once.
#
# Why: without a certificate, install-wisp.sh signs Wisp ad hoc, and macOS then
# recognizes the app by the hash of that exact build. Every update is a new
# hash, so permissions such as Accessibility (needed by the quick terminal's
# global shortcut) are asked for again even though they look granted. Signed
# with a fixed certificate, macOS recognizes Wisp by its bundle id and
# certificate, and permissions stay granted across updates.
#
# The certificate is only trusted by your Mac and only signs code. Remove it
# from Keychain Access to undo.
set -euo pipefail

name="Wisp Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$keychain" | grep -q "\"$name\""; then
  echo "\"$name\" already exists."
  exit 0
fi

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

echo "==> Creating the certificate"
cat > "$dir/cert.conf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$dir/cert.conf" -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null

# A random password only protects the file while it's imported.
password="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
  -name "$name" -out "$dir/identity.p12" -passout "pass:$password"

echo "==> Importing it into your login keychain"
# -T lets codesign use the key without asking each time.
security import "$dir/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign

echo "==> Done. Run scripts/install-wisp.sh, then turn Wisp off and on again"
echo "    in System Settings > Privacy & Security > Accessibility (once)."
