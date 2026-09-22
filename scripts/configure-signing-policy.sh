#!/usr/bin/env bash
# Configures /etc/containers/policy.json + registries.d to require a
# valid cosign signature for images at ghcr.io/lbssousa — mirrors
# lbssousa/bluefin's build_files/00-signing.sh and Dakota's own
# convention for verified registries (its shipped
# /usr/lib/pki/containers/ublue-os*.pub + registries.d/ublue-os.yaml).
#
# Usage: configure-signing-policy.sh <cosign-pub-key-path>
set -euo pipefail

pubkey="$1"

install -Dm0644 "${pubkey}" /usr/lib/pki/containers/lbssousa.pub

jq '.transports.docker["ghcr.io/lbssousa"] = [
  {
    "type": "sigstoreSigned",
    "keyPath": "/usr/lib/pki/containers/lbssousa.pub",
    "signedIdentity": { "type": "matchRepository" }
  }
]' /etc/containers/policy.json > /tmp/policy.json.tmp
mv /tmp/policy.json.tmp /etc/containers/policy.json

install -Dm0644 /dev/stdin /etc/containers/registries.d/ghcr.io-lbssousa.yaml << 'EOF'
docker:
  ghcr.io/lbssousa:
    use-sigstore-attachments: true
EOF
