#!/usr/bin/env bash
# Signs the NVIDIA kernel modules build-nvidia.sh packaged, with this
# repo's own module signing key, and ships its certificate (DER) for MOK
# enrollment. See README.md, "Secure Boot and module signing".
#
# The Dakota base boots with lockdown=integrity whether or not Secure
# Boot is on (projectbluefin/dakota's lockdown-kargs.bst), so the kernel
# refuses every module not signed by a key it trusts. Dakota's own key
# is compiled into the kernel, but its private half only exists in
# upstream's CI, so ours has to become trusted the other way: enrolled
# as a MOK, which shim hands to the kernel's .machine keyring.
#
# Usage: sign-modules.sh <out-root> <kernel-src-root> <cert.pem> <key|"">
#   <out-root>         build-nvidia.sh's output tree, signed in place
#   <kernel-src-root>  kernel-src-builder's tree, for scripts/sign-file
#   <cert.pem>         files/secure-boot/module-signing.crt
#   <key>              the private key (a build secret), or an empty
#                      string to ship unsigned modules — only when
#                      ALLOW_UNSIGNED_MODULES=1, for local builds without
#                      the key; those modules do not load on Dakota.
set -euo pipefail

out_dir="$1"
kernel_src_root="$2"
cert="$3"
key="$4"

kver="$(cat /kernel-version)"
sign_file="${kernel_src_root}/lib/modules/${kver}/build/scripts/sign-file"
moddir="${out_dir}/usr/lib/modules/${kver}/extra"
certdir="${out_dir}/usr/lib/dakota-nvidia-580/secure-boot"

mkdir -p "${certdir}"
openssl x509 -in "${cert}" -outform DER -out "${certdir}/module-signing.der"

mapfile -t kos < <(find "${moddir}" -name '*.ko' | sort)
if [ "${#kos[@]}" -eq 0 ]; then
    echo "ERROR: no kernel modules found under ${moddir}" >&2
    exit 1
fi

if [ -z "${key}" ] || [ ! -s "${key}" ]; then
    if [ "${ALLOW_UNSIGNED_MODULES:-0}" = 1 ]; then
        echo "WARNING: no module signing key; shipping ${#kos[@]} UNSIGNED module(s)." >&2
        echo "WARNING: Dakota's lockdown=integrity refuses to load them." >&2
        exit 0
    fi
    echo "ERROR: no module signing key (build secret 'module_signing_key')." >&2
    echo "Pass --secret id=module_signing_key,src=<key>, or" >&2
    echo "--build-arg ALLOW_UNSIGNED_MODULES=1 for a local test build." >&2
    exit 1
fi

# Present only when the kernel's .config has CONFIG_MODULE_SIG (every
# Dakota base since projectbluefin/dakota#1781); kernel-src-builder
# builds it during modules_prepare.
if [ ! -x "${sign_file}" ]; then
    echo "ERROR: ${sign_file} is missing — is CONFIG_MODULE_SIG off in this base?" >&2
    exit 1
fi

# A key that doesn't match the enrolled certificate yields modules the
# kernel rejects; fail here instead, as upstream's sign.sh does.
if [ "$(openssl pkey -in "${key}" -pubout)" != "$(openssl x509 -in "${cert}" -pubkey -noout)" ]; then
    echo "ERROR: the module signing key does not match ${cert}" >&2
    exit 1
fi

# sha512, the only hash Dakota's kernel accepts (fdsdk-config.sh enables
# MODULE_SIG_SHA512 alone).
signer="$(openssl x509 -in "${cert}" -noout -subject -nameopt multiline \
    | sed -n 's/^ *commonName *= *//p')"
for ko in "${kos[@]}"; do
    "${sign_file}" sha512 "${key}" "${certdir}/module-signing.der" "${ko}"
    got="$(modinfo -F signer "${ko}")"
    if [ "${got}" != "${signer}" ]; then
        echo "ERROR: ${ko} signer is '${got}', expected '${signer}'" >&2
        exit 1
    fi
done
echo "==> Signed ${#kos[@]} module(s) with '${signer}'"
