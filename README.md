# dakota-nvidia-580

Imagem [Bluefin Dakota](https://docs.projectbluefin.io/dakota/)
personalizada, com dois componentes baked-in via layering downstream
de imagem OCI (não via fork do BuildStream upstream — ver ["Por que
downstream e não fork do
BuildStream"](#por-que-downstream-e-não-fork-do-buildstream) abaixo):

- **Driver proprietário NVIDIA na branch legada 580.xxx** — necessário
  porque a GPU alvo é de uma geração fora do suporte nas variantes
  `dakota-nvidia`/`dakota-nvidia-gaming` oficiais, que seguem a branch
  mais nova (~610.x/615.x em 2026).
- **Fork [lbssousa/libfprint](https://github.com/lbssousa/libfprint)**
  (branch `goodix-538d-sigfm-gtls`), com suporte ao leitor de
  impressão digital Goodix 538d — o mesmo fork usado em
  [lbssousa/bluefin-initial-setup](https://github.com/lbssousa/bluefin-initial-setup)
  (`playbooks/dakota/libfprint.yml`), que o instala em **runtime** via
  distrobox para hosts Dakota que não usam esta imagem. Aqui ele é
  compilado no build da imagem e baked em `/usr/local` — sem precisar
  do workaround `/var/usrlocal` que a instalação em runtime exige (ver
  esse repositório para o porquê).

## ⚠️ Antes de tudo: valide os headers do kernel

O maior risco não resolvido deste projeto inteiro é este: **não está
confirmado que a imagem `dakota:stable` publicada expõe uma árvore de
build de kernel completa** em `/usr/lib/modules/<kver>/build`. O
Dakota é montado do zero via Apache BuildStream (não via RPMs de
`kernel-devel`), numa imagem otimizada para espaço com dedup via
Chunkah — não há garantia de que essa árvore sobrevive no runtime
image em vez de ficar só nos artefatos intermediários do build.

Rode isto **antes** de configurar segredos do GHCR, Renovate, etc.:

```bash
./scripts/check-kernel-headers.sh stable
```

Se falhar, este caminho inteiro (Containerfile downstream) não
funciona, e a única alternativa vira forkar o BuildStream do próprio
[`projectbluefin/dakota`](https://github.com/projectbluefin/dakota) e
pinar a versão do driver lá — bem mais pesado (exige o toolchain
completo BuildStream + freedesktop-sdk + gnome-build-meta), mas é o
caminho "nativo" que o próprio projeto usa. Ver `docs/oci-assembly.md`
e `docs/patches.md` no repo do Dakota.

## Arquitetura

```
dakota-base (FROM ghcr.io/projectbluefin/dakota:stable@sha256:...)
  │
  ├─→ kernel-headers          extrai versão + /usr/lib/modules/<kver>/build
  │     │
  │     └─→ nvidia-builder    (Fedora, só ambiente de compilação)
  │           compila o kmod fora da árvore contra os headers acima,
  │           roda o nvidia-installer --no-kernel-module e empacota
  │           via diff de filesystem (scripts/build-nvidia.sh)
  │
  ├─→ libfprint-builder       (Fedora, só ambiente de compilação)
  │     compila o fork contra opencv-devel do dnf, DESTDIR=/out
  │
  └─→ final (FROM dakota-base outra vez)
        COPY dos dois /out, drop-in do fprintd.service, blacklist do
        nouveau, depmod + ldconfig -r, bootc container lint
```

Os estágios `nvidia-builder` e `libfprint-builder` usam Fedora **só
como ambiente de compilação** (tem `dnf`, `gcc`, `meson`...) — nada
deles entra na imagem final além do que os scripts empacotam
explicitamente em `/out`. A imagem final continua sendo Dakota puro
(GNOME OS, sem RPMs) com esses dois payloads por cima.

## Por que downstream e não fork do BuildStream

O Dakota não tem `dnf`/`rpm`/`akmods` — não é possível fazer
`rpm-ostree install akmod-nvidia` como no Bluefin/Aurora clássicos. O
jeito "nativo" de mudar o que vai de fábrica na imagem é editar os
elementos `.bst` do próprio repositório `dakota` e buildar tudo via
BuildStream. Esse caminho é mais correto (o módulo é compilado na
mesma árvore de fontes do kernel), mas exige manter um fork completo
do build da distro, com todo o toolchain BuildStream + freedesktop-sdk,
e fazer rebase contínuo em cima do upstream para não perder
atualizações de segurança/GNOME.

Este repositório escolhe o caminho mais barato de manter para um
usuário único: um `Containerfile` `FROM` a imagem já publicada,
compilando só o que precisa ser compilado (o kmod fora da árvore + o
fork do libfprint) contra os headers extraídos daquela imagem
específica.

## Riscos conhecidos, não totalmente validados

- **Headers do kernel ausentes na imagem publicada** — ver seção
  acima. Bloqueante; verifique primeiro.
- **Deriva de API do kernel vs. branch legada do driver** — o Dakota
  acompanha o kernel upstream de perto; a branch 580.xxx da NVIDIA é
  legada e pode não ter patches de compatibilidade para kernels muito
  recentes (o tipo de patch que a RPM Fusion mantém para drivers
  NVIDIA legados no Fedora). Se o build do kmod falhar por API do
  kernel, procure patches de compatibilidade da comunidade antes de
  tentar "consertar na mão".
- **Secure Boot / assinatura de módulo** — o Dakota usa UKI
  (`systemd-boot` + kernel unificado). Um módulo fora da árvore, não
  assinado, pode ser rejeitado em boot com Secure Boot habilitado
  (lockdown do kernel). Se o `modprobe nvidia` falhar silenciosamente
  no primeiro boot, comece por aí (desabilitar Secure Boot, ou
  configurar MOK enrollment + assinatura do módulo no build).
  Não testado neste repositório ainda.
- **Blacklist do nouveau pode não ser suficiente** — se o Dakota
  embutir o nouveau estaticamente na UKI em vez de como módulo sob
  demanda, `files/nvidia-blacklist-nouveau.conf` sozinho não resolve.
  Ver o comentário nesse arquivo.
- **Flags do `nvidia-installer`** — conferidas contra `--help`/
  `--advanced-options` de versões recentes, mas mudam entre branches.
  Revalide antes de trocar `NVIDIA_VERSION`.
- **Nada aqui foi validado em hardware Dakota real.** Trate como ponto
  de partida a testar, não como garantia — mesma ressalva que
  `bluefin-initial-setup` faz para o Dakota em geral (ainda alpha).

## Build local

```bash
# 1. Confirme o digest atual do dakota:stable e cole no Containerfile
#    (linha `FROM ... @sha256:...`):
skopeo inspect docker://ghcr.io/projectbluefin/dakota:stable | jq -r .Digest

# 2. Valide os headers do kernel ANTES de buildar (ver seção acima):
./scripts/check-kernel-headers.sh stable

# 3. Build:
podman build --file Containerfile --tag localhost/dakota-nvidia-580:dev .

# 4. Smoke test básico antes de instalar em qualquer máquina real:
podman run --rm localhost/dakota-nvidia-580:dev modinfo nvidia
podman run --rm localhost/dakota-nvidia-580:dev bootc container lint
```

Para trocar a versão do driver: `--build-arg NVIDIA_VERSION=580.xx.xx`
(confirme a versão certa para sua GPU em
[nvidia.com/en-us/drivers/unix](https://www.nvidia.com/en-us/drivers/unix/)
antes de fixar).

## Usar num host Dakota real

```bash
sudo bootc switch ghcr.io/lbssousa/dakota-nvidia-580:stable
# ou, se a imagem oficial já tiver o ujust:
ujust rebase-helper
```

Reboot obrigatório depois. Valide `modprobe nvidia`, `nvidia-smi` e o
leitor de digital (`fprintd-list $USER`, `fprintd-verify`) antes de
considerar a migração concluída — e mantenha um jeito de voltar
(`bootc switch` para a imagem `dakota:stable` original) até validar em
hardware real.

## CI e atualização automática

- `.github/workflows/build.yml` builda e publica
  `ghcr.io/lbssousa/dakota-nvidia-580:stable` em push para `main`, em
  schedule diário (cobre o caso de um PR do Renovate já mergeado sem
  rebuild manual) e via `workflow_dispatch`.
- `renovate.json5` acompanha o digest de
  `ghcr.io/projectbluefin/dakota:stable` fixado no `Containerfile` e
  abre PR quando ele muda upstream — **cada bump é um PR revisável**,
  não um rebuild silencioso, porque uma imagem base nova pode ter um
  kernel novo e quebrar o kmod até você confirmar que o build ainda
  passa.
