#!/usr/bin/env bash
#
# CachyOS fresh-install script (DE/WM-less -> personalized desktop)
# Usage: ./install.sh [--dry-run] [--yes] [--de N] [--apps a,b,c] [--list]
#
# App profiles (--apps comma list, "all", or "none"; interactive toggle menu
# by default): core (always on), desktop, dev, audio, gaming (incl. AUR
# launchers), creative, proton, remote, privacy (incl. throne-bin proxy),
# flatpak.
#
# Curated from a 2026-09-23 CachyOS + Hyprland + Noctalia host
# (RX 5700 XT + Raphael iGPU, fish + starship, shelly, zen-browser):
#   shelly backup --export  ->  standard / aur / flatpak TOML
# Transitive build deps from that export are intentionally omitted here;
# the package manager resolves them. Personal -bin launchers are opt-in.
#
# Flow: guards -> shelly -> mirrors/upgrade -> base -> toggles -> DE menu -> services.
#
# Dotfiles are deployed with cp + timestamped backups, NOT stow, because
# neither repo is stow-clean (hypr-dotfiles/uwsm.env -> ~/.config/uwsm/env,
# niri-dotfiles/conf/* -> ~/.config/*).

set -euo pipefail

LOG="$HOME/cachy-install.log"
BACKUP_ROOT="$HOME/dotfiles-backups/pre-install-$(date +%Y%m%d-%H%M%S)"
HYPR_REPO="https://github.com/seikodayo/hypr-dotfiles.git"
NIRI_REPO="https://github.com/SeikoDayo/niri-dotfiles"
END4_REPO="https://github.com/end-4/dots-hyprland.git"
DRY_RUN=0
ASSUME_YES=0
DE_CHOICE=""
APPS_CHOICE=""
LIST_ONLY=0
SELECTED_APPS=()

# --- helpers ---------------------------------------------------------------

log()  { echo "[install] $*" | tee -a "$LOG"; }
die()  { echo "[install] ERROR: $*" | tee -a "$LOG" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

run() { # run <cmd...>: echo in dry-run, execute otherwise
  if (( DRY_RUN )); then echo "[dry-run] $*"; else log "run: $*"; "$@"; fi
}

ask_yn() { # ask_yn <default Y|N> <prompt>; echoes y/n
  local def="$1" prompt="$2" ans
  (( ASSUME_YES )) && { [[ "$def" == Y ]] && echo y || echo n; return; }
  read -rp "[install] $prompt [$def] " ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]] && echo y || echo n
}

# shelly wrappers: packages BEFORE flags (shelly install standard <pkgs> [options])
sinstall() { run shelly install standard "$@" --needed -n; }
ainstall() { run shelly install aur "$@" -n; }
finstall() { run shelly install flatpak "$@" -n; }

backup_path() { # backup_path <dest>: move existing dest under $BACKUP_ROOT
  local dest="$1" rel
  [[ -e "$dest" || -L "$dest" ]] || return 0
  (( DRY_RUN )) && { echo "[dry-run] backup: $dest -> \$BACKUP_ROOT/"; return 0; }
  rel="${dest/#$HOME\//}"
  mkdir -p "$BACKUP_ROOT/$(dirname "$rel")"
  log "backup: $dest -> $BACKUP_ROOT/$rel"
  mv "$dest" "$BACKUP_ROOT/$rel"
}

deploy_dir() { # deploy_dir <src> <dest>: rsync dir over dest after backup
  local src="$1" dest="$2"
  if (( DRY_RUN )); then echo "[dry-run] deploy dir: $src -> $dest"; return 0; fi
  [[ -d "$src" ]] || die "dotfile source missing: $src"
  backup_path "$dest"
  log "deploy dir: $src -> $dest"
  mkdir -p "$(dirname "$dest")"; cp -a "$src/." "$dest/"
}

deploy_file() { # deploy_file <src> <dest>
  local src="$1" dest="$2"
  if (( DRY_RUN )); then echo "[dry-run] deploy file: $src -> $dest"; return 0; fi
  [[ -f "$src" ]] || die "dotfile source missing: $src"
  backup_path "$dest"
  log "deploy file: $src -> $dest"
  mkdir -p "$(dirname "$dest")"; cp -a "$src" "$dest"
}

# --- app profiles (curated from shelly backup export) ------------------------
# Standard = CachyOS/Arch repos. Groups (plasma, kde-applications, gnome)
# are passed through to ALPM, which resolves them.
# core = always installed. The rest are multi-selectable (see APP_ORDER).

CORE_STANDARD=(
  base-devel git stow curl wget reflector cachyos-rate-mirrors
  pacman-contrib pkgfile plocate rebuild-detector
  fish cachyos-fish-config starship eza bat fzf zoxide
  fastfetch btop duf glances ripgrep less man-db man-pages bash-completion
  nano nano-syntax-highlighting micro 7zip unzip unrar
  vulkan-radeon lib32-vulkan-radeon lib32-mesa opencl-mesa lib32-opencl-mesa
  xf86-video-amdgpu mesa-utils vulkan-tools nvtop amdgpu_top lact
  pipewire-alsa pipewire-pulse wireplumber
  alsa-utils alsa-firmware sof-firmware
  networkmanager nm-connection-editor bluez bluez-utils openssh ufw ufw-extras
  xdg-user-dirs accountsservice upower polkit-qt6 power-profiles-daemon realtime-privileges
  btrfs-progs btrfs-assistant snapper
  flatpak shelly shelly-flatpak-backend
  noto-fonts noto-fonts-cjk noto-fonts-emoji
  ttf-meslo-nerd ttf-liberation ttf-dejavu ttf-bitstream-vera ttf-opensans
  cantarell-fonts awesome-terminal-fonts
)
DESKTOP_STANDARD=(
  dolphin ark ffmpegthumbnailer qview
  gnome-disk-utility gnome-text-editor gnome-calculator gnome-system-monitor
  chromium zen-browser-bin qbittorrent localsend discord spotify-launcher
  vlc vlc-plugins-all android-tools scrcpy openrgb
)
DEV_STANDARD=( vscodium opencode python )
AUDIO_STANDARD=( easyeffects pavucontrol cava )
AUDIO_AUR=( deepfilternet-plus-bin ) # noise suppression for easyeffects/pipewire
PROTON_STANDARD=( proton-pass )
PROTON_AUR=( proton-authenticator-bin )
GAMING_STANDARD=( cachyos-gaming-meta cachyos-gaming-applications prismlauncher protonplus )
GAMING_AUR=( lunar-client-bin an-anime-game-launcher-bin sleepy-launcher-bin
  the-honkers-railway-launcher-bin )
CREATIVE_STANDARD=( blender gimp kdenlive obs-studio )
REMOTE_STANDARD=( sunshine tailscale )
PRIVACY_AUR=( mullvad-vpn-bin mullvad-vpn-daemon-bin throne-bin ) # throne-bin = sing-box GUI proxy
FLATPAKS=( com.usebottles.bottles org.vinegarhq.Sober )

APP_ORDER=( desktop dev audio gaming creative proton remote privacy flatpak )
DEFAULT_APPS=( desktop dev audio gaming creative proton flatpak )

app_label() { # app_label <profile>: short description
  case "$1" in
    desktop)   echo "everyday GUI apps (repo)" ;;
    dev)       echo "dev tools (repo)" ;;
    audio)     echo "audio apps + noise suppression (repo + AUR)" ;;
    gaming)    echo "gaming stack + personal launchers (repo + AUR)" ;;
    creative)  echo "creative + streaming (repo)" ;;
    proton)    echo "proton apps (repo + AUR)" ;;
    remote)    echo "remote access (repo)" ;;
    privacy)   echo "privacy (AUR)" ;;
    flatpak)   echo "flatpaks" ;;
  esac
}

app_packages() { # app_packages <profile>: print that profile's packages
  case "$1" in
    desktop)   printf '%s\n' "${DESKTOP_STANDARD[@]}" ;;
    dev)       printf '%s\n' "${DEV_STANDARD[@]}" ;;
    audio)     printf '%s\n' "${AUDIO_STANDARD[@]}" "${AUDIO_AUR[@]}" ;;
    gaming)    printf '%s\n' "${GAMING_STANDARD[@]}" "${GAMING_AUR[@]}" ;;
    creative)  printf '%s\n' "${CREATIVE_STANDARD[@]}" ;;
    proton)    printf '%s\n' "${PROTON_STANDARD[@]}" "${PROTON_AUR[@]}" ;;
    remote)    printf '%s\n' "${REMOTE_STANDARD[@]}" ;;
    privacy)   printf '%s\n' "${PRIVACY_AUR[@]}" ;;
    flatpak)   printf '%s\n' "${FLATPAKS[@]}" ;;
  esac
}

list_profiles() { # list_profiles: print core + every app profile and exit
  echo "core (always installed):"
  printf '  %s\n' "${CORE_STANDARD[@]}"
  for p in "${APP_ORDER[@]}"; do
    echo "$p -- $(app_label "$p"):"
    app_packages "$p" | sed 's/^/  /'
  done
}

has_app() { # has_app <profile>: true if profile selected
  local needle="$1" s
  for s in "${SELECTED_APPS[@]}"; do [[ "$s" == "$needle" ]] && return 0; done
  return 1
}

valid_app() { # valid_app <name>: true if known profile
  local needle="$1" p
  for p in "${APP_ORDER[@]}"; do [[ "$p" == "$needle" ]] && return 0; done
  return 1
}

toggle_app() { # toggle_app <profile>: flip selection state
  local needle="$1" i
  for i in "${!SELECTED_APPS[@]}"; do
    if [[ "${SELECTED_APPS[$i]}" == "$needle" ]]; then
      unset 'SELECTED_APPS[$i]'
      SELECTED_APPS=( "${SELECTED_APPS[@]}" )
      return 0
    fi
  done
  SELECTED_APPS+=( "$needle" )
}

HYPR_STANDARD=( cachyos-hypr-noctalia hyprland kitty alacritty
  grim slurp swash wl-clipboard uwsm noctalia noctalia-greeter
  greetd-tuigreet brightnessctl hyprpicker xdg-desktop-portal-hyprland )
NIRI_STANDARD=( cachyos-niri-noctalia niri ghostty alacritty nautilus
  wl-clipboard xdg-desktop-portal-gnome xdg-desktop-portal-gtk
  xwayland-satellite noctalia greetd-tuigreet )
END4_STANDARD=( hyprland kitty git quickshell )
CAELESTIA_AUR=( caelestia-cli )
KDE_STANDARD=( plasma kde-applications cachyos-kde-settings sddm )
GNOME_STANDARD=( gnome gnome-extra cachyos-gnome-settings gdm )

# --- DE profiles ------------------------------------------------------------

profile_hypr() {
  sinstall "${HYPR_STANDARD[@]}"
  local src="/tmp/hypr-dotfiles"
  [[ -d "$src" ]] || run git clone "$HYPR_REPO" "$src"
  deploy_dir "$src/hypr" "$HOME/.config/hypr"
  deploy_file "$src/fish/config.fish" "$HOME/.config/fish/config.fish"
  deploy_dir "$src/kitty" "$HOME/.config/kitty"
  deploy_file "$src/noctalia/config.toml" "$HOME/.config/noctalia/config.toml"
  deploy_file "$src/starship.toml" "$HOME/.config/starship.toml"
  deploy_file "$src/uwsm.env" "$HOME/.config/uwsm/env"
  # NOTE: $src/env is legacy (BROWSER=firefox); uwsm.env (zen-browser) is canonical.
  if have noctalia && (( ! DRY_RUN )); then noctalia config validate || true; fi
  run sudo systemctl enable greetd.service
  run sudo systemctl disable sddm.service gdm.service || true
}

profile_niri() {
  sinstall "${NIRI_STANDARD[@]}"
  local src="/tmp/niri-dotfiles"
  [[ -d "$src" ]] || run git clone "$NIRI_REPO" "$src"
  deploy_dir "$src/conf/fish" "$HOME/.config/fish"
  deploy_dir "$src/conf/ghostty" "$HOME/.config/ghostty"
  deploy_dir "$src/conf/niri" "$HOME/.config/niri"
  deploy_dir "$src/conf/noctalia" "$HOME/.config/noctalia"
  deploy_file "$src/conf/starship.toml" "$HOME/.config/starship.toml"
  if have niri && (( ! DRY_RUN )); then niri validate || true; fi
  run sudo systemctl enable greetd.service
  run sudo systemctl disable sddm.service gdm.service || true
}

profile_end4() {
  sinstall "${END4_STANDARD[@]}"
  local src="/tmp/dots-hyprland"
  [[ -d "$src" ]] || run git clone "$END4_REPO" "$src"
  log "running upstream end-4 installer (./setup install)"
  (( DRY_RUN )) || (cd "$src" && ./setup install)
  run sudo systemctl enable greetd.service
}

profile_caelestia() {
  ainstall "${CAELESTIA_AUR[@]}"
  log "running upstream caelestia installer (caelestia install)"
  (( DRY_RUN )) || caelestia install
  run sudo systemctl enable greetd.service
}

profile_dms() {
  log "running upstream DMS installer (https://install.danklinux.com)"
  (( DRY_RUN )) || curl -fsSL https://install.danklinux.com | sh
  run sudo systemctl enable greetd.service
}

profile_kde() {
  sinstall "${KDE_STANDARD[@]}"
  run sudo systemctl enable sddm.service
  run sudo systemctl disable greetd.service gdm.service || true
}

profile_gnome() {
  sinstall "${GNOME_STANDARD[@]}"
  run sudo systemctl enable gdm.service
  run sudo systemctl disable greetd.service sddm.service || true
}

# --- main -------------------------------------------------------------------

ARGS=("$@")
i=0
while (( i < ${#ARGS[@]} )); do
  arg="${ARGS[$i]}"
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --de=*) DE_CHOICE="${arg#--de=}" ;;
    --de) (( ++i )); DE_CHOICE="${ARGS[$i]:-}" ;;
    --apps=*) APPS_CHOICE="${arg#--apps=}" ;;
    --apps) (( ++i )); APPS_CHOICE="${ARGS[$i]:-}" ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown arg: $arg (see --help)" ;;
  esac
  (( ++i ))
done
[[ -n "$DE_CHOICE" ]] || DE_CHOICE=""

if (( LIST_ONLY )); then list_profiles; exit 0; fi

(( EUID != 0 )) || die "run as your user (with sudo), not as root"
have sudo || die "sudo not found"
grep -qi cachyos /etc/os-release 2>/dev/null || log "WARN: not CachyOS per /etc/os-release, continuing anyway"
have ping && ping -c1 -W3 archlinux.org >/dev/null 2>&1 || log "WARN: no network? continuing anyway"
: > "$LOG"

if ! have shelly; then
  log "shelly missing, bootstrapping via pacman"
  run sudo pacman -S --needed --noconfirm shelly shelly-flatpak-backend
fi

log "sync + full upgrade first (shelly covers repo + AUR + flatpak)"
run shelly sync -n || true
run shelly upgrade -n || run sudo pacman -Syu --noconfirm

if [[ "$(ask_yn Y "rate mirrors with cachyos-rate-mirrors")" == y ]]; then
  run sudo cachyos-rate-mirrors || true
fi

sinstall "${CORE_STANDARD[@]}"

# --- app profile selection -------------------------------------------------
if [[ -n "$APPS_CHOICE" ]]; then
  if [[ "$APPS_CHOICE" == all ]]; then
    SELECTED_APPS=( "${APP_ORDER[@]}" )
  elif [[ "$APPS_CHOICE" == none ]]; then
    SELECTED_APPS=()
  else
    IFS=',' read -ra SELECTED_APPS <<< "$APPS_CHOICE"
    for s in "${SELECTED_APPS[@]}"; do
      valid_app "$s" || die "bad --apps value: '$s' (want comma list of: ${APP_ORDER[*]}, or all/none)"
    done
  fi
elif (( ASSUME_YES )); then
  SELECTED_APPS=( "${DEFAULT_APPS[@]}" )
else
  # interactive toggle menu (pure bash, no gum/whiptail needed); defaults pre-checked
  SELECTED_APPS=( "${DEFAULT_APPS[@]}" )
  while true; do
    echo "App profiles (core is always installed):"
    n=1
    for p in "${APP_ORDER[@]}"; do
      if has_app "$p"; then mark="x"; else mark=" "; fi
      printf '  %d) [%s] %s -- %s\n' "$n" "$mark" "$p" "$(app_label "$p")"
      (( ++n ))
    done
    read -rp "[install] toggle number/name, 'all', 'none', or Enter to continue: " ans
    [[ -z "$ans" ]] && break
    if [[ "$ans" == all ]]; then SELECTED_APPS=( "${APP_ORDER[@]}" ); continue; fi
    if [[ "$ans" == none ]]; then SELECTED_APPS=(); continue; fi
    for tok in $ans; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#APP_ORDER[@]} )); then
        toggle_app "${APP_ORDER[$((tok-1))]}"
      elif valid_app "$tok"; then
        toggle_app "$tok"
      else
        echo "bad selection: '$tok'"
      fi
    done
  done
fi
log "app profiles: core + ${SELECTED_APPS[*]:-(none)}"

has_app desktop   && sinstall "${DESKTOP_STANDARD[@]}"
has_app dev       && sinstall "${DEV_STANDARD[@]}"
if has_app audio; then sinstall "${AUDIO_STANDARD[@]}"; ainstall "${AUDIO_AUR[@]}"; fi
if has_app gaming; then sinstall "${GAMING_STANDARD[@]}"; ainstall "${GAMING_AUR[@]}"; fi
has_app creative  && sinstall "${CREATIVE_STANDARD[@]}"
if has_app proton; then sinstall "${PROTON_STANDARD[@]}"; ainstall "${PROTON_AUR[@]}"; fi
has_app remote    && sinstall "${REMOTE_STANDARD[@]}"
has_app privacy   && ainstall "${PRIVACY_AUR[@]}"
if has_app flatpak; then for f in "${FLATPAKS[@]}"; do finstall "$f"; done; fi

if [[ -z "$DE_CHOICE" ]]; then
  echo "Choose desktop:"
  select DE_CHOICE in \
    "hypr-dotfiles (personal)" \
    "niri-dotfiles (personal)" \
    "end-4 dotfiles (upstream installer)" \
    "caelestia (caelestia-cli + caelestia install)" \
    "DMS (upstream install.danklinux.com)" \
    "KDE (full CachyOS flavor)" \
    "GNOME (full CachyOS flavor)" \
    "other (no DE/WM)"; do
    [[ -n "$DE_CHOICE" ]] && break
    echo "pick 1-8"
  done
fi

case "$DE_CHOICE" in
  1*|*hypr-dotfiles*)  profile_hypr ;;
  2*|*niri-dotfiles*)  profile_niri ;;
  3*|*end-4*)          profile_end4 ;;
  4*|*caelestia*)      profile_caelestia ;;
  5*|*DMS*|*dms*)      profile_dms ;;
  6*|*KDE*|*kde*)      profile_kde ;;
  7*|*GNOME*|*gnome*)  profile_gnome ;;
  8*|*other*)          log "skipping DE/WM install" ;;
  *) die "bad --de value: $DE_CHOICE (want 1-8)" ;;
esac

log "enabling common services"
run sudo systemctl enable NetworkManager.service bluetooth.service ufw.service || true
has_app remote && run sudo systemctl enable tailscaled.service || true
has_app privacy && run sudo systemctl enable mullvad-daemon.service || true
if printf '%s' "${CORE_STANDARD[*]}" | grep -q lact; then run sudo systemctl enable lactd.service || true; fi
run systemctl --user enable wireplumber.service pipewire.service pipewire-pulse.socket || true

if [[ "$SHELL" != */fish ]] && [[ "$(ask_yn Y "set fish as default shell")" == y ]]; then
  run sudo chsh -s /usr/bin/fish "$USER"
fi

log "done. backups under $BACKUP_ROOT. full log: $LOG"
[[ "$(ask_yn Y "reboot now")" == y ]] && run sudo reboot
