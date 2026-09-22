#!/usr/bin/env bash
# Compila o kmod proprietário da NVIDIA (fora da árvore) contra o
# kernel extraído do estágio kernel-headers do Containerfile, e
# empacota os componentes userspace do instalador oficial via diff de
# filesystem — em vez de listar manualmente os arquivos que o
# nvidia-installer instala. O manifesto de arquivos do instalador muda
# entre versões do driver e não é documentado de forma estável o
# suficiente pra hardcodar aqui; capturar o diff real é mais confiável.
#
# Uso: build-nvidia.sh <versao> <kernel-src-root> <saida>
#   <versao>          ex.: 580.65.06 (branch legada — confirme em
#                      https://www.nvidia.com/en-us/drivers/unix/
#                      que é a versão certa pra sua GPU antes de fixar)
#   <kernel-src-root>  raiz contendo lib/modules/<kver>/build
#   <saida>            diretório a popular com a árvore final
#                      (usr/lib/modules/..., usr/lib64/..., etc.)
set -euo pipefail

version="$1"
kernel_src_root="$2"
out_dir="$3"

kver="$(cat /kernel-version)"
build_dir="${kernel_src_root}/lib/modules/${kver}/build"

if [ ! -f "${build_dir}/Makefile" ]; then
    echo "ERRO: ${build_dir}/Makefile não encontrado." >&2
    echo "O estágio kernel-headers do Containerfile deveria ter pego isso antes." >&2
    exit 1
fi

workdir="$(mktemp -d)"
cd "$workdir"

url="https://us.download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run"
echo "==> Baixando driver NVIDIA ${version}..."
curl -fsSLO "$url"
chmod +x "NVIDIA-Linux-x86_64-${version}.run"

echo "==> Extraindo instalador..."
"./NVIDIA-Linux-x86_64-${version}.run" -x
cd "NVIDIA-Linux-x86_64-${version}"

echo "==> Compilando o kmod contra ${build_dir}..."
# IGNORE_CC_MISMATCH: o compilador do Fedora deste estágio quase certo
# não é bit-a-bit o mesmo usado pra buildar o kernel do Dakota
# (freedesktop-sdk). Isso é tolerável para um módulo fora da árvore;
# incompatibilidades reais de ABI apareceriam como falha de link/carga,
# não de compilação — teste `modprobe nvidia` na imagem final antes de
# considerar isto validado.
make -C kernel SYSSRC="${build_dir}" IGNORE_CC_MISMATCH=1 modules

mkdir -p "${out_dir}/usr/lib/modules/${kver}/extra"
find kernel -maxdepth 1 -name '*.ko' -exec cp {} "${out_dir}/usr/lib/modules/${kver}/extra/" \;

echo "==> Instalando componentes userspace (--no-kernel-module, o kmod já foi tratado acima)..."
# ATENÇÃO: os nomes de flag abaixo foram conferidos contra o
# --advanced-options do instalador em versões recentes, mas o
# nvidia-installer muda flags entre branches — rode
# `./nvidia-installer --help` e `--advanced-options` na primeira vez
# que trocar de versão e ajuste esta lista antes de confiar no build.
find / -xdev -type f 2>/dev/null | sort > /tmp/before.list

./nvidia-installer \
    --silent \
    --accept-license \
    --no-questions \
    --ui=none \
    --no-kernel-module \
    --no-nouveau-check \
    --no-nvidia-modprobe \
    --no-rpms \
    --no-backup \
    --no-check-for-alternate-installs \
    --skip-depmod \
    --skip-module-load \
    --install-libglvnd

find / -xdev -type f 2>/dev/null | sort > /tmp/after.list
comm -13 /tmp/before.list /tmp/after.list > /tmp/new-files.list

n="$(wc -l < /tmp/new-files.list)"
echo "==> ${n} arquivos novos detectados; empacotando em ${out_dir}"
if [ "$n" -eq 0 ]; then
    echo "ERRO: nenhum arquivo novo — o nvidia-installer provavelmente falhou" >&2
    echo "silenciosamente ou saiu antes de instalar nada. Rode sem --silent" >&2
    echo "pra ver a saída completa." >&2
    exit 1
fi

while IFS= read -r f; do
    mkdir -p "${out_dir}$(dirname "$f")"
    cp -a "$f" "${out_dir}${f}"
done < /tmp/new-files.list

echo "==> build-nvidia.sh concluído."
