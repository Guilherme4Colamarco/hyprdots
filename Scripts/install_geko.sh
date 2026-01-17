#!/usr/bin/env bash
set -euo pipefail

scrDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cloneDir="$(dirname "$scrDir")"

usage() {
  cat <<'EOF'
Instala (ou restaura) o setup do "geko" em um Arch mínimo, reutilizando o instalador do HyDE.

O que faz:
1) instala os pacotes do HyDE (modo -i, sem mexer em grub/pacman/sddm), + extras do seu setup
2) restaura configs a partir de um backup `hyde-backup-*.tar.zst` (sem sobrescrever ~/HyDE)
3) (opcional) extrai assets de temas (GTK/Icon/Cursor) via hyde-gallery
4) (opcional) tenta regerar cache do HyDE

Uso:
  ./install_geko.sh --yes --services

Opções:
  --backup <arquivo.tar.zst>   Backup para restaurar (default: pega o mais recente em ~/Backups)
  --no-restore                Não restaurar configs (só instalar pacotes)
  --no-install                Não instalar pacotes (só restaurar configs)
  --assets <none|current|all> Extrai GTK/Icon/Cursor via hyde-gallery (default: none)
  --gallery-dir <path>        Onde clonar/usar hyde-gallery (default: ~/hyde-gallery)
  --gallery-repo <url>        Repo do hyde-gallery (default: HyDE-Project/hyde-gallery)
  --services                  Habilita services do HyDE (NetworkManager, bluetooth, sddm)
  --yes                       Tenta rodar sem prompts (pacman/yay --noconfirm)
  -h, --help                  Ajuda
EOF
}

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

backup_path=""
do_restore=1
do_install=1
do_services=1
noconfirm=0
assets_mode="none"
gallery_dir="$HOME/hyde-gallery"
gallery_repo="https://github.com/HyDE-Project/hyde-gallery.git"
tmp_paths=()

cleanup() {
  for p in "${tmp_paths[@]:-}"; do
    [ -e "$p" ] && rm -rf "$p"
  done
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) backup_path="${2:-}"; shift 2 ;;
    --no-restore) do_restore=0; shift ;;
    --no-install) do_install=0; shift ;;
    --assets) assets_mode="${2:-}"; shift 2 ;;
    --gallery-dir) gallery_dir="${2:-}"; shift 2 ;;
    --gallery-repo) gallery_repo="${2:-}"; shift 2 ;;
    --services) do_services=1; shift ;;
    --yes) noconfirm=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

need pacman
need tar
need zstd
need git
need sudo

[[ "$(id -u)" -eq 0 ]] && die "rode como usuário normal (não root)"
sudo true

pacman_flags=(--needed)
[[ $noconfirm -eq 1 ]] && pacman_flags+=(--noconfirm)

export use_default=""
[[ $noconfirm -eq 1 ]] && export use_default="--noconfirm"

systemd_running() {
  [[ "$(ps -p 1 -o comm= 2>/dev/null || true)" == "systemd" ]]
}

if [[ $do_install -eq 1 || "$assets_mode" != "none" ]]; then
  echo "[bootstrap] deps básicas..."
  sudo pacman -Syu "${pacman_flags[@]}" base-devel curl jq parallel
fi

if [[ $do_install -eq 1 ]]; then
  echo "[hyde] garantindo paru e zsh (evita prompts do install.sh)..."
  if ! command -v paru >/dev/null 2>&1; then
    (cd "$scrDir" && ./install_aur.sh paru-bin) || (cd "$scrDir" && ./install_aur.sh paru)
  fi
  export getAur="paru"
  if ! command -v zsh >/dev/null 2>&1; then
    sudo pacman -S "${pacman_flags[@]}" zsh
  fi

  extra_pkgs="$(mktemp)"
  tmp_paths+=("$extra_pkgs")
  cat >"$extra_pkgs" <<'EOF'
# Extras do setup do geko (além do custom_hypr.lst do HyDE)
thunar
brave-bin
EOF

  echo "[hyde] instalando pacotes (HyDE install.sh -i)..."
  (cd "$scrDir" && ./install.sh -i "$extra_pkgs")

  if [[ $do_services -eq 1 ]]; then
    if systemd_running; then
      echo "[hyde] habilitando services..."
      (cd "$scrDir" && ./install.sh -s)
    else
      echo "[hyde] aviso: systemd não é o PID 1; pulando enable/start de services (provável container)." >&2
    fi
  fi
fi

if [[ $do_restore -eq 1 ]]; then
  if [[ -z "$backup_path" ]]; then
    backup_path="$(ls -1t "$HOME"/Backups/hyde-backup-*.tar.zst 2>/dev/null | head -n 1 || true)"
  fi
  [[ -n "$backup_path" ]] || die "nenhum backup encontrado (use --backup <arquivo.tar.zst>)"
  [[ -f "$backup_path" ]] || die "backup não existe: $backup_path"

  sha_file="${backup_path}.sha256"
  if [[ -f "$sha_file" ]]; then
    echo "[restore] verificando checksum..."
    (cd "$(dirname -- "$backup_path")" && sha256sum -c "$(basename -- "$sha_file")")
  fi

  tmp="$(mktemp -d)"
  tmp_paths+=("$tmp")
  echo "[restore] extraindo backup para área temporária..."
  tar --zstd -xpf "$backup_path" -C "$tmp"

  restore_lst="$(mktemp)"
  tmp_paths+=("$restore_lst")

  cat >"$restore_lst" <<'EOF'
Y|Y|${HOME}/.config|hyde|
Y|Y|${HOME}/.config|hypr|
Y|Y|${HOME}/.config|waybar|
Y|Y|${HOME}/.config|rofi|
Y|Y|${HOME}/.config|wlogout|
Y|Y|${HOME}/.config|dunst|
Y|Y|${HOME}/.config|kitty|
Y|Y|${HOME}/.config|gtk-3.0|
Y|Y|${HOME}/.config|gtk-4.0|
Y|Y|${HOME}/.config|qt5ct|
Y|Y|${HOME}/.config|qt6ct|
Y|Y|${HOME}/.config|swappy|
Y|Y|${HOME}/.local/share|bin|
Y|Y|${HOME}/.cache/hyde|hyde.meta landing|
EOF

  echo "[restore] aplicando configs via restore_cfg.sh (sem tocar em ~/HyDE)..."
  (cd "$scrDir" && ./restore_cfg.sh "$restore_lst" "$tmp")

  if [[ -x "$HOME/.local/share/bin/swwwallcache.sh" ]]; then
    echo "[restore] regenerando cache do HyDE..."
    "$HOME/.local/share/bin/swwwallcache.sh" -t "" || true
  fi
fi

if [[ "$assets_mode" != "none" ]]; then
  [[ "$assets_mode" == "current" || "$assets_mode" == "all" ]] || die "--assets precisa ser none|current|all"

  echo "[assets] preparando hyde-gallery em $gallery_dir ..."
  ensure_gallery() {
    if [[ -d "$gallery_dir/.git" ]]; then
      (cd "$gallery_dir" && git pull --ff-only) || true
      return 0
    fi

    rm -rf "$gallery_dir" 2>/dev/null || true
    if git clone --depth 1 "$gallery_repo" "$gallery_dir"; then
      return 0
    fi

    echo "[assets] git clone falhou; tentando download do tarball..." >&2
    need curl

    tmp="$(mktemp -d)"
    tmp_paths+=("$tmp")

    base="${gallery_repo%.git}"
    tar_url="${base}/archive/refs/heads/main.tar.gz"
    curl -fL --retry 3 --retry-delay 2 -o "$tmp/gallery.tgz" "$tar_url"

    rm -rf "$gallery_dir" 2>/dev/null || true
    mkdir -p "$gallery_dir"
    tar -xzf "$tmp/gallery.tgz" -C "$gallery_dir" --strip-components=1
  }

  ensure_gallery

  need find
  gallery_json="$gallery_dir/hyde-themes.json"
  [[ -f "$gallery_json" ]] || die "não achei $gallery_json"

  if [[ "$assets_mode" == "current" ]]; then
    [[ -f "$HOME/.config/hyde/hyde.conf" ]] || die "não achei ~/.config/hyde/hyde.conf (restaure configs antes)"
    theme_name="$(. "$HOME/.config/hyde/hyde.conf"; printf '%s' "${hydeTheme:-}")"
    [[ -n "$theme_name" ]] || die "hydeTheme vazio em ~/.config/hyde/hyde.conf"
    echo "[assets] extraindo assets do tema atual: $theme_name"
    theme_link="$(jq -r --arg t "$theme_name" '.[] | select(.THEME==$t) | .LINK' "$gallery_json" | head -n 1 || true)"
    if [[ -z "$theme_link" || "$theme_link" == "null" ]]; then
      echo "[assets] aviso: não achei LINK do tema '$theme_name' em hyde-themes.json; pulando assets." >&2
    else
      if ! (cd "$scrDir" && ./themepatcher.sh "$theme_name" "$theme_link" --skipcaching true); then
        echo "[assets] aviso: themepatcher falhou para '$theme_name'; pulando assets." >&2
      fi
    fi
  else
    echo "[assets] extraindo assets de todos os temas em ~/.config/hyde/themes (pode demorar)..."
    find "$HOME/.config/hyde/themes" -mindepth 1 -maxdepth 1 -type d -printf '%f\0' \
      | while IFS= read -r -d '' t; do
          theme_name="$(basename -- "$t")"
          theme_link="$(jq -r --arg th "$theme_name" '.[] | select(.THEME==$th) | .LINK' "$gallery_json" | head -n 1 || true)"
          if [[ -z "$theme_link" || "$theme_link" == "null" ]]; then
            echo "[assets] skip: sem LINK no gallery para '$theme_name'" >&2
            continue
          fi
          "$scrDir/themepatcher.sh" "$theme_name" "$theme_link" --skipcaching true || {
            echo "[assets] aviso: themepatcher falhou para '$theme_name'." >&2
          }
        done
  fi

  if [[ -x "$HOME/.local/share/bin/swwwallcache.sh" ]]; then
    echo "[assets] regenerando cache do HyDE..."
    "$HOME/.local/share/bin/swwwallcache.sh" -t "" || true
  fi
fi

echo "done."
echo "Sugestão: relogue (ou reboot) antes do primeiro login no Hyprland."
