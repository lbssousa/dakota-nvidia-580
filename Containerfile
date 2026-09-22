# syntax=docker/dockerfile:1.7
#
# Imagem Dakota personalizada: NVIDIA proprietário v580.xxx (GPU legada,
# fora do suporte nas variantes dakota-nvidia/dakota-nvidia-gaming
# oficiais, que seguem a branch mais nova, ~610.x/615.x) + fork
# libfprint (Goodix 538d) baked-in via layering downstream de imagem
# OCI. Ver README.md para o raciocínio completo (por que downstream e
# não fork do BuildStream upstream, e os riscos que ainda não foram
# validados em hardware real).
#
# PRÉ-REQUISITO NÃO VERIFICADO POR ESTE ARQUIVO SOZINHO: a imagem
# Dakota pinada abaixo precisa expor uma árvore de build do kernel
# completa em /usr/lib/modules/<kver>/build. O estágio kernel-headers
# checa isso e falha alto se faltar — mas rode
# `scripts/check-kernel-headers.sh` ANTES de mexer no resto
# (segredos do GHCR, Renovate etc.), porque se isso faltar este
# caminho inteiro não funciona e a única alternativa vira o fork do
# BuildStream (ver README.md).

ARG NVIDIA_VERSION=580.65.06
ARG LIBFPRINT_REPO=https://github.com/lbssousa/libfprint.git
ARG LIBFPRINT_REF=goodix-538d-sigfm-gtls

# ---------------------------------------------------------------------
# dakota-base — SEMPRE pinada por digest, nunca por tag flutuante
# ("stable" muda de conteúdo). O módulo NVIDIA abaixo é compilado
# contra o kernel exato desta imagem; se o digest mudar sem recompilar,
# o resultado é um kernel novo com um .ko velho (não carrega, ou pior,
# carrega e é instável). O Renovate (.github/renovate.json5) abre PR
# quando o digest upstream muda; o CI builda a partir do PR.
#
# Troque para ghcr.io/projectbluefin/dakota-gaming se quiser a variante
# gaming como base (mesma estratégia, só troca esta linha).
# ---------------------------------------------------------------------
FROM ghcr.io/projectbluefin/dakota:stable@sha256:0000000000000000000000000000000000000000000000000000000000000 AS dakota-base
# ^ substitua pelo digest real antes do primeiro build:
#   skopeo inspect docker://ghcr.io/projectbluefin/dakota:stable | jq -r .Digest

# ---------------------------------------------------------------------
# kernel-headers — extrai a versão e a árvore de build do kernel desta
# imagem específica, para o estágio nvidia-builder consumir. Falha alto
# e cedo se a imagem não tiver os headers.
# ---------------------------------------------------------------------
FROM dakota-base AS kernel-headers
RUN set -eux; \
    kver="$(basename "$(ls -d /usr/lib/modules/*/ | head -n1)")"; \
    echo "$kver" > /kernel-version; \
    if [ ! -f "/usr/lib/modules/$kver/build/Makefile" ]; then \
        echo "ERRO: /usr/lib/modules/$kver/build ausente ou incompleto" >&2; \
        echo "nesta imagem Dakota — não dá pra compilar o kmod NVIDIA" >&2; \
        echo "fora da árvore sem ela. Ver README.md, seção" >&2; \
        echo "'Se os headers não existirem'." >&2; \
        exit 1; \
    fi

# ---------------------------------------------------------------------
# nvidia-builder — Fedora só como ambiente de compilação (dnf/gcc/make);
# nada daqui entra na imagem final além do que build-nvidia.sh empacota
# explicitamente em /out.
# ---------------------------------------------------------------------
FROM fedora:42 AS nvidia-builder
ARG NVIDIA_VERSION
RUN dnf install -y gcc make kmod elfutils-libelf-devel perl-interpreter \
        tar xz curl which && \
    dnf clean all
COPY --from=kernel-headers /usr/lib/modules /kernel-src/lib/modules
COPY --from=kernel-headers /kernel-version /kernel-version
COPY scripts/build-nvidia.sh /build-nvidia.sh
RUN chmod +x /build-nvidia.sh && /build-nvidia.sh "${NVIDIA_VERSION}" /kernel-src /out

# ---------------------------------------------------------------------
# libfprint-builder — mesmo fork/ref usado em
# lbssousa/bluefin-initial-setup (playbooks/dakota/libfprint.yml,
# vars dakota_libfprint_repo/_ref em group_vars/all/dakota.yml), que
# instala o mesmo fork em runtime via distrobox para hosts Dakota que
# não usam esta imagem personalizada. Aqui builda contra o
# opencv-devel do dnf em vez do Homebrew do host — não existe host,
# é build de imagem.
# ---------------------------------------------------------------------
FROM fedora:44 AS libfprint-builder
ARG LIBFPRINT_REPO
ARG LIBFPRINT_REF
RUN dnf install -y meson gcc gcc-c++ ninja-build pkgconf-pkg-config \
        openssl-devel glib2-devel gobject-introspection-devel \
        libgudev-devel libgusb-devel systemd-devel nss-devel \
        pixman-devel gtk-doc python3-cairo python3-gobject cairo-devel \
        umockdev git cmake opencv-devel && \
    dnf clean all
RUN git clone --branch "${LIBFPRINT_REF}" --depth 1 "${LIBFPRINT_REPO}" /src
RUN meson setup /src/builddir /src --prefix=/usr/local -Ddrivers=all && \
    ninja -C /src/builddir && \
    DESTDIR=/out ninja -C /src/builddir install

# ---------------------------------------------------------------------
# final — Dakota + os dois payloads, baked na imagem. /usr é gravável
# durante o build (só vira somente-leitura em runtime via composefs),
# então dá pra escrever direto em /usr/local — sem o workaround
# /var/usrlocal que a instalação em runtime (bluefin-initial-setup)
# precisa.
# ---------------------------------------------------------------------
FROM dakota-base

COPY --from=kernel-headers /kernel-version /kernel-version
COPY --from=nvidia-builder /out/ /
COPY --from=libfprint-builder /out/usr/local/ /usr/local/
COPY files/fprintd-override.conf /usr/lib/systemd/system/fprintd.service.d/override.conf
COPY files/nvidia-blacklist-nouveau.conf /usr/lib/modprobe.d/nvidia-blacklist-nouveau.conf

# Passos de pós-instalação. depmod é acréscimo nosso (específico de
# termos adicionado um módulo de kernel fora da árvore); ldconfig -r é
# o mesmo passo que docs/oci-assembly.md do próprio Dakota descreve
# como "load-bearing — removê-lo quebra a imagem de formas que só
# aparecem depois de um bootc switch", necessário aqui porque
# adicionamos .so novas em /usr/local/lib64 e /usr/lib64.
RUN kver="$(cat /kernel-version)" && \
    depmod -a "$kver" && \
    ldconfig -r / && \
    rm -f /kernel-version

RUN bootc container lint
