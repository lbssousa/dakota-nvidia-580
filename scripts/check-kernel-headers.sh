#!/usr/bin/env bash
# Verifica, ANTES de investir tempo no resto deste diretório, se a
# imagem Dakota informada expõe uma árvore de build do kernel completa
# o suficiente pra compilar um módulo fora da árvore (kmod NVIDIA).
#
# Isto é o maior risco não resolvido do caminho "Containerfile
# downstream" descrito em image/README.md: o Dakota é buildado do
# zero via BuildStream, não via kernel-devel de RPM, e é uma imagem
# otimizada para espaço (dedup via chunkah) — não há garantia de que a
# árvore completa de build do kernel sobrevive no runtime image em vez
# de só nos artefatos de build do BuildStream. Se este script falhar,
# o Containerfile também vai falhar (o estágio kernel-headers faz a
# mesma checagem) — mas rodar isto primeiro evita configurar o resto
# (segredos do GHCR, Renovate, etc.) só para descobrir isso depois.
#
# Uso: image/scripts/check-kernel-headers.sh [ref]
#   ref: tag ou tag@sha256:... da imagem Dakota (default: stable)
set -euo pipefail

ref="${1:-stable}"
image="ghcr.io/projectbluefin/dakota:${ref}"

echo "==> Inspecionando ${image}..." >&2
podman run --rm "${image}" bash -c '
    set -euo pipefail
    kver="$(basename "$(ls -d /usr/lib/modules/*/ | head -n1)")"
    echo "Kernel: $kver"
    if [ -f "/usr/lib/modules/$kver/build/Makefile" ]; then
        echo "OK: /usr/lib/modules/$kver/build existe e tem Makefile."
        exit 0
    fi
    echo "FALTANDO: /usr/lib/modules/$kver/build (ou Makefile dentro dele)."
    echo "Conteúdo de /usr/lib/modules/$kver:"
    ls -la "/usr/lib/modules/$kver" || true
    exit 1
'
