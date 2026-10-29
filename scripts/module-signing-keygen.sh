#!/usr/bin/env bash
# Creates the key pair the NVIDIA kernel modules are signed with (see
# README.md, "Secure Boot and module signing"). Mirrors the shape of
# projectbluefin/dakota's `just secure-boot-keygen` certificate: RSA 4096,
# not a CA, digitalSignature + codeSigning, 100 years — long enough that
# no machine ever has to re-enroll because the MOK expired.
#
# Usage: module-signing-keygen.sh <private-key-out>
#
# The certificate goes to files/secure-boot/module-signing.crt (committed;
# it is what users enroll as a MOK). The private key goes wherever you
# point it, outside the repository: store it as the MODULE_SIGNING_KEY
# repository secret and keep an offline backup. Losing it means every
# machine has to enroll a new key; leaking it means anyone can build
# modules those machines will load.
set -euo pipefail

key_out="${1:?usage: module-signing-keygen.sh <private-key-out>}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
cert_out="${repo}/files/secure-boot/module-signing.crt"

if [ -e "$key_out" ] || [ -e "$cert_out" ]; then
    echo "Refusing to overwrite $key_out or $cert_out" >&2
    exit 1
fi

conf="$(mktemp)"
trap 'rm -f "$conf"' EXIT
cat >"$conf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext

[dn]
O = lbssousa
OU = dakota-nvidia-580
CN = dakota-nvidia-580 module signing key

[ext]
basicConstraints = critical,CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF

mkdir -p "$(dirname "$cert_out")"
(
    umask 077
    openssl req -new -x509 -newkey rsa:4096 -sha256 -nodes -days 36500 \
        -config "$conf" -keyout "$key_out" -out "$cert_out"
)
chmod 644 "$cert_out"
openssl x509 -in "$cert_out" -noout -subject -enddate -fingerprint -sha256
