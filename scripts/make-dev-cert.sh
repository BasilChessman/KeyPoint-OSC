#!/bin/zsh
# Creates a self-signed "KeyPoint OSC Development" code-signing identity in the login
# keychain. Signing with a stable identity keeps macOS permissions (Accessibility,
# Automation) across rebuilds; ad-hoc signatures change with every build.
# Remove it with: security delete-identity -c "KeyPoint OSC Development"
set -euo pipefail
name="KeyPoint OSC Development"
if security find-identity -p codesigning | grep -q "\"$name\""; then
  echo "$name already exists"; exit 0
fi
tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
cat > $tmp/cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout $tmp/key.pem -out $tmp/cert.pem -days 3650 -config $tmp/cert.cnf 2>/dev/null
pw=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey $tmp/key.pem -in $tmp/cert.pem -out $tmp/id.p12 -passout pass:$pw -name "$name"
security import $tmp/id.p12 -k ~/Library/Keychains/login.keychain-db -P $pw -T /usr/bin/codesign
echo "Created $name"
