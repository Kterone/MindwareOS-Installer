#!/usr/bin/env bash
#
#  MindwareOS Installer
#  A guided, UEFI-only installer that produces a branded, privacy-hardened
#  Arch Linux system. Run it from the official Arch Linux live ISO:
#
#      bash mindware-install.sh
#
#  WARNING: this ERASES the disk you select. You must confirm by typing the
#  disk path before any change is made.
#
set -Eeuo pipefail

OSNAME="MindwareOS"
VERSION="1.2"
TAGLINE="think. protect. boot."
LOGFILE="/tmp/mindware-install-$(date +%Y%m%d-%H%M%S).log"
MNT="/mnt"
STEP=0
TOTAL_STEPS=12

usage() {
  cat <<EOF
$OSNAME installer v$VERSION

Usage: bash $(basename "$0") [options]

  -h, --help   Show this help

Environment:
  MINDWARE_FORCE=1   Skip the Arch live ISO check
EOF
}

for arg in "$@"; do
  case $arg in
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg"; usage; exit 2 ;;
  esac
done

# ───────────────────────────── colours ─────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\e[1;31m'; GRN=$'\e[1;32m'; YLW=$'\e[1;33m'; BLU=$'\e[1;34m'
  MAG=$'\e[1;35m'; CYN=$'\e[1;36m'; DIM=$'\e[2m';   RST=$'\e[0m'
else
  RED=; GRN=; YLW=; BLU=; MAG=; CYN=; DIM=; RST=
fi

# ───────────────────────────── ASCII art ─────────────────────────────
wordmark() {
cat <<'ART'
#   #  ###  #   #  ####   #   #   ###   ####   #####
## ##   #   ##  #  #   #  #   #  #   #  #   #  #
# # #   #   # # #  #   #  # # #  #####  ####   ####
#   #   #   #  ##  #   #  ## ##  #   #  #  #   #
#   #  ###  #   #  ####   #   #  #   #  #   #  #####
ART
}

banner() {
  clear 2>/dev/null || true
  printf '%s\n' "$CYN"
  wordmark
  printf '%s\n' "$RST"
  printf '%s       %s v%s  --  %s%s\n\n' "$MAG" "$OSNAME" "$VERSION" "$TAGLINE" "$RST"
}

# ───────────────────────────── helpers ─────────────────────────────
log()  { printf '[%s] %s\n' "$(date +%T)" "$*" >>"$LOGFILE" 2>/dev/null || true; }
say()  { printf '%s%s%s\n' "$CYN" "$*" "$RST"; log "$*"; }
ok()   { printf '%s ✔ %s%s\n' "$GRN" "$*" "$RST"; log "OK: $*"; }
warn() { printf '%s ! %s%s\n' "$YLW" "$*" "$RST" >&2; log "WARN: $*"; }
die()  { printf '\n%s ✘ %s%s\n' "$RED" "$*" "$RST" >&2; log "FATAL: $*"; exit 1; }

step() {
  STEP=$((STEP + 1))
  printf '\n%s[%d/%d]%s %s%s%s\n' "$BLU" "$STEP" "$TOTAL_STEPS" "$RST" "$MAG" "$*" "$RST"
  log "STEP $STEP: $*"
}

on_error() {
  local code=$? line=$1 cmd=$2
  trap - ERR
  printf '\n%s ✘ Installation failed.%s\n' "$RED" "$RST"
  printf '   Line %s: %s (exit code %s)\n' "$line" "$cmd" "$code"
  printf '   Log file: %s\n' "$LOGFILE"
  printf '   Filesystems mounted under %s have been left in place for inspection.\n' "$MNT"
  exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

ask() { # ask VAR "prompt" ["default"]
  local __var=$1 prompt=$2 def=${3-} reply
  if [[ -n $def ]]; then
    read -r -p "${CYN}?${RST} ${prompt} ${DIM}[${def}]${RST}: " reply
    reply=${reply:-$def}
  else
    read -r -p "${CYN}?${RST} ${prompt}: " reply
  fi
  printf -v "$__var" '%s' "$reply"
}

ask_yn() { # ask_yn "prompt" y|n  -> exit 0 on yes
  local prompt=$1 def=${2:-y} reply hint
  if [[ $def == y ]]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "${CYN}?${RST} ${prompt} ${DIM}[${hint}]${RST}: " reply
  reply=${reply:-$def}
  [[ ${reply,,} == y* ]]
}

ask_pass() { # ask_pass VAR "prompt" [minlen]
  local __var=$1 prompt=$2 minlen=${3:-8} p1 p2
  while true; do
    read -r -s -p "${CYN}?${RST} ${prompt} (min ${minlen} characters): " p1; echo
    if (( ${#p1} < minlen )); then
      warn "Password must be at least ${minlen} characters."
      continue
    fi
    read -r -s -p "${CYN}?${RST} Confirm password: " p2; echo
    if [[ $p1 == "$p2" ]]; then break; fi
    warn "Passwords do not match. Try again."
  done
  printf -v "$__var" '%s' "$p1"
}

choose() { # choose VAR "title" "value|description" ...   (first = default)
  local __var=$1 title=$2; shift 2
  local opts=("$@") i sel val
  printf '%s%s%s\n' "$MAG" "$title" "$RST"
  for i in "${!opts[@]}"; do
    printf '   %s%d)%s %s\n' "$YLW" $((i + 1)) "$RST" "${opts[$i]#*|}"
  done
  while true; do
    read -r -p "   Selection ${DIM}[1]${RST}: " sel
    sel=${sel:-1}
    if [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#opts[@]} )); then
      val=${opts[$((sel - 1))]%%|*}
      printf -v "$__var" '%s' "$val"
      return 0
    fi
    warn "Enter a number from 1 to ${#opts[@]}."
  done
}

part() { # part N -> /dev/sdX1 or /dev/nvme0n1p1
  if [[ $DISK =~ [0-9]$ ]]; then printf '%sp%s' "$DISK" "$1"; else printf '%s%s' "$DISK" "$1"; fi
}

chroot_run() { arch-chroot "$MNT" "$@"; }

pac_install() { # install packages in the target; fall back to one-by-one
  local p
  if ! arch-chroot "$MNT" pacman -S --noconfirm --needed "$@"; then
    warn "Batch installation failed; retrying packages individually."
    for p in "$@"; do
      arch-chroot "$MNT" pacman -S --noconfirm --needed "$p" || warn "Package '$p' could not be installed; skipped."
    done
  fi
}

# ───────────────────────────── hardware detection ─────────────────────────────
detect_hardware() {
  CPU_VENDOR=$(awk -F: '/vendor_id/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo || true)
  UCODE_PKG=""
  case $CPU_VENDOR in
    GenuineIntel) UCODE_PKG="intel-ucode" ;;
    AuthenticAMD) UCODE_PKG="amd-ucode" ;;
  esac
  RAM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  VIRT=$(systemd-detect-virt 2>/dev/null || true)
  GPU_INFO=$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)

  GPU_PKGS=(mesa)
  GUEST_PKGS=()
  GUEST_SERVICES=()
  local g=${GPU_INFO,,}
  if [[ $g == *amd* || $g == *radeon* ]]; then GPU_PKGS+=(vulkan-radeon); fi
  if [[ $g == *intel* ]];                  then GPU_PKGS+=(vulkan-intel); fi
  HAS_NVIDIA=0
  if [[ $g == *nvidia* ]]; then HAS_NVIDIA=1; GPU_PKGS+=(vulkan-nouveau); fi

  case $VIRT in
    kvm|qemu)  GUEST_PKGS=(qemu-guest-agent spice-vdagent); GUEST_SERVICES=(qemu-guest-agent) ;;
    vmware)    GUEST_PKGS=(open-vm-tools);                  GUEST_SERVICES=(vmtoolsd) ;;
    oracle)    GUEST_PKGS=(virtualbox-guest-utils);         GUEST_SERVICES=(vboxservice) ;;
  esac

  say "Detected hardware: CPU=${CPU_VENDOR:-unknown}, RAM≈${RAM_GB} GB, virtualization=${VIRT:-none}"
  if (( HAS_NVIDIA )); then
    say "NVIDIA GPU detected: the open-source nouveau driver will be installed (proprietary drivers can be added later)."
  fi
}

# ───────────────────────────── phase 1: preflight ─────────────────────────────
preflight() {
  step "Preflight checks"
  [[ $EUID -eq 0 ]] || die "This installer must be run as root."

  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    die "UEFI firmware not detected. This installer supports UEFI systems only."
  fi

  local c
  for c in pacstrap genfstab arch-chroot sgdisk lsblk mkfs.fat blkid partprobe curl; do
    command -v "$c" >/dev/null 2>&1 || die "Required tool '$c' not found. Run this installer from the official Arch Linux live ISO."
  done

  if [[ ! -d /run/archiso && -z ${MINDWARE_FORCE:-} ]]; then
    die "The Arch Linux live ISO was not detected. Boot from it, or set MINDWARE_FORCE=1 to override."
  fi

  say "Checking internet connectivity..."
  if ! curl -fsS --max-time 8 -o /dev/null https://archlinux.org; then
    die "No internet connection. For Wi-Fi use: iwctl station <device> connect <SSID>"
  fi
  ok "Internet connection available."

  timedatectl set-ntp true || true
  detect_hardware
}

# ───────────────────────────── phase 2: configuration ─────────────────────────────
gather_config() {
  step "System configuration"

  # --- user ---
  while true; do
    ask USERNAME "Username"
    if [[ $USERNAME == root ]]; then
      warn "'root' is reserved. Choose a different username."
      continue
    fi
    if [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then break; fi
    warn "Use lowercase letters, digits, '-' and '_' only; the name must start with a letter or '_'."
  done

  ask FULLNAME "Display name" "${USERNAME^}"
  FULLNAME=${FULLNAME//[:,]/}

  ask_pass USER_PASS "Password for ${USERNAME} (also used for sudo)"

  if ask_yn "Lock the root account and use sudo only? (recommended)" y; then
    LOCK_ROOT=1
  else
    LOCK_ROOT=0
    ask_pass ROOT_PASS "Root password"
  fi

  # --- machine ---
  while true; do
    ask HOST_NAME "Hostname" "mindware"
    if [[ $HOST_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then break; fi
    warn "Hostnames may contain letters, digits and hyphens, and cannot begin or end with a hyphen."
  done

  while true; do
    ask TZONE "Timezone (e.g. Europe/Berlin, America/New_York, Asia/Kolkata)" "UTC"
    if [[ -f /usr/share/zoneinfo/$TZONE ]]; then break; fi
    warn "Unknown timezone '$TZONE'. See /usr/share/zoneinfo."
  done

  while true; do
    ask LOCALE "Locale" "en_US.UTF-8"
    if [[ ! -r /usr/share/i18n/SUPPORTED ]] || grep -q "^${LOCALE} " /usr/share/i18n/SUPPORTED; then break; fi
    warn "Unsupported locale '$LOCALE'. See /usr/share/i18n/SUPPORTED."
  done

  while true; do
    ask KEYMAP "Console keymap" "us"
    if ! command -v localectl >/dev/null 2>&1 || [[ -z $(localectl list-keymaps 2>/dev/null) ]] \
       || localectl list-keymaps 2>/dev/null | grep -qx "$KEYMAP"; then break; fi
    warn "Unknown keymap '$KEYMAP'. List available keymaps with: localectl list-keymaps"
  done
  loadkeys "$KEYMAP" 2>/dev/null || true

  # --- disk ---
  local ISO_SRC ISO_DISK="" name size model
  ISO_SRC=$(findmnt -rno SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  if [[ -n $ISO_SRC ]]; then ISO_DISK=$(lsblk -no PKNAME "$ISO_SRC" 2>/dev/null | head -1 || true); fi
  DISK_OPTS=()
  while read -r name size model; do
    if [[ -n $ISO_DISK && $name == "/dev/$ISO_DISK" ]]; then continue; fi
    DISK_OPTS+=("${name}|${name}  ${size}  ${model:-unknown model}")
  done < <(lsblk -dpno NAME,SIZE,MODEL -e 7,11)
  (( ${#DISK_OPTS[@]} > 0 )) || die "No installable disks found."
  echo
  choose DISK "Target disk (ALL DATA ON IT WILL BE ERASED)" "${DISK_OPTS[@]}"

  # --- storage layout ---
  echo
  choose FS_TYPE "Root filesystem" \
    "btrfs|btrfs - snapshots, compression, subvolumes (recommended)" \
    "ext4|ext4  - traditional and stable"

  echo
  if ask_yn "Encrypt the disk with LUKS2? (recommended)" y; then
    ENCRYPT=1
    ask_pass LUKS_PASS "Disk encryption passphrase" 10
  else
    ENCRYPT=0
    warn "Disk encryption disabled. Data on the disk will be readable by anyone with physical access."
  fi

  # --- kernel & desktop ---
  echo
  choose KERNEL "Kernel" \
    "linux|linux          - mainline Arch kernel" \
    "linux-hardened|linux-hardened - additional security hardening (some software may be restricted)" \
    "linux-lts|linux-lts      - long-term support" \
    "linux-zen|linux-zen      - tuned for desktop responsiveness"

  echo
  choose DESKTOP "Desktop environment" \
    "xfce|XFCE        - lightweight" \
    "kde|KDE Plasma  - feature-rich" \
    "gnome|GNOME       - minimal and modern" \
    "none|None         - command line only"
}

confirm_plan() {
  step "Installation summary"
  cat <<EOF

   ${MAG}User${RST}        : ${USERNAME} (${FULLNAME})  $( ((LOCK_ROOT)) && echo '[root account locked]' || echo '[root account enabled]')
   ${MAG}Hostname${RST}    : ${HOST_NAME}
   ${MAG}Timezone${RST}    : ${TZONE}   ${MAG}Locale${RST}: ${LOCALE}   ${MAG}Keymap${RST}: ${KEYMAP}
   ${MAG}Disk${RST}        : ${RED}${DISK}${RST}  (all existing data will be destroyed)
   ${MAG}Filesystem${RST}  : ${FS_TYPE}   ${MAG}Encryption${RST}: $( ((ENCRYPT)) && echo 'LUKS2' || echo 'none')
   ${MAG}Kernel${RST}      : ${KERNEL}    ${MAG}Desktop${RST}: ${DESKTOP}
   ${MAG}Bootloader${RST}  : GRUB (UEFI), branded as ${OSNAME}

EOF
  lsblk "$DISK" || true
  echo
  local typed
  read -r -p "${RED}Type ${DISK} to confirm and begin installation${RST}: " typed
  [[ $typed == "$DISK" ]] || die "Confirmation did not match '${DISK}'. No changes were made."
}

# ───────────────────────────── phase 3: partitioning ─────────────────────────────
partition_disk() {
  step "Partitioning ${DISK}"
  umount -R "$MNT" 2>/dev/null || true
  cryptsetup close cryptroot 2>/dev/null || true
  swapoff -a 2>/dev/null || true

  wipefs -af "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"MINDWARE-ESP"  "$DISK"
  if (( ENCRYPT )); then
    sgdisk -n 2:0:0 -t 2:8309 -c 2:"MINDWARE-LUKS" "$DISK"
  else
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"MINDWARE-ROOT" "$DISK"
  fi
  partprobe "$DISK"
  udevadm settle
  sleep 1

  ESP_PART=$(part 1)
  ROOT_PART=$(part 2)
  ok "Created ${ESP_PART} (1 GiB EFI system partition) and ${ROOT_PART} (root)."
}

# ───────────────────────────── phase 4: format & mount ─────────────────────────────
format_and_mount() {
  step "Formatting and mounting"
  local ROOT_DEV=$ROOT_PART

  if (( ENCRYPT )); then
    say "Creating LUKS2 container..."
    printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$ROOT_PART"
    printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" cryptroot
    ROOT_DEV=/dev/mapper/cryptroot
    ok "Encrypted container unlocked."
  fi

  mkfs.fat -F32 -n MWESP "$ESP_PART"

  if [[ $FS_TYPE == btrfs ]]; then
    mkfs.btrfs -f -L mindware "$ROOT_DEV"
    mount "$ROOT_DEV" "$MNT"
    local sv
    for sv in @ @home @log @pkg @snapshots; do btrfs subvolume create "$MNT/$sv"; done
    umount "$MNT"
    local o="noatime,compress=zstd:3,space_cache=v2"
    mount -o "${o},subvol=@" "$ROOT_DEV" "$MNT"
    mkdir -p "$MNT"/{home,var/log,var/cache/pacman/pkg,.snapshots,boot}
    mount -o "${o},subvol=@home"      "$ROOT_DEV" "$MNT/home"
    mount -o "${o},subvol=@log"       "$ROOT_DEV" "$MNT/var/log"
    mount -o "${o},subvol=@pkg"       "$ROOT_DEV" "$MNT/var/cache/pacman/pkg"
    mount -o "${o},subvol=@snapshots" "$ROOT_DEV" "$MNT/.snapshots"
  else
    mkfs.ext4 -F -L mindware "$ROOT_DEV"
    mount "$ROOT_DEV" "$MNT"
    mkdir -p "$MNT/boot"
  fi

  mount -o umask=0077 "$ESP_PART" "$MNT/boot"
  ok "Filesystems mounted under ${MNT}."
}

# ───────────────────────────── phase 5: base install ─────────────────────────────
install_base() {
  step "Installing the base system (this may take several minutes)"

  say "Refreshing keyring and ranking mirrors..."
  pacman -Sy --noconfirm --needed archlinux-keyring || warn "Keyring refresh failed; continuing with the ISO keyring."
  if command -v reflector >/dev/null 2>&1; then
    timeout 120 reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist \
      || warn "Mirror ranking failed; using existing mirrors."
  fi

  local pkgs=(base "$KERNEL" "${KERNEL}-headers" linux-firmware base-devel sudo
    grub efibootmgr networkmanager nano vim git curl wget man-db man-pages
    bash-completion htop btop fastfetch reflector zram-generator
    less which rsync unzip zip tree lsof usbutils pciutils inetutils ncdu pacman-contrib
    e2fsprogs dosfstools)
  if [[ -n $UCODE_PKG ]];        then pkgs+=("$UCODE_PKG"); fi
  if [[ $FS_TYPE == btrfs ]];    then pkgs+=(btrfs-progs); fi
  if (( ENCRYPT ));              then pkgs+=(cryptsetup); fi

  pacstrap -K "$MNT" "${pkgs[@]}"
  ok "Base system installed."

  genfstab -U "$MNT" >> "$MNT/etc/fstab"
  ok "fstab generated."

  local pc="$MNT/etc/pacman.conf"
  sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 10/' "$pc"
}

# ───────────────────────────── phase 6: system config ─────────────────────────────
configure_system() {
  step "Configuring time, locale and hostname"
  ln -sf "/usr/share/zoneinfo/${TZONE}" "$MNT/etc/localtime"
  chroot_run hwclock --systohc || warn "Could not set the hardware clock (common in virtual machines)."

  sed -i "s/^#\(en_US.UTF-8 UTF-8\)/\1/" "$MNT/etc/locale.gen"
  sed -i "s/^#\(${LOCALE//./\\.} UTF-8\)/\1/" "$MNT/etc/locale.gen"
  chroot_run locale-gen
  echo "LANG=${LOCALE}"   > "$MNT/etc/locale.conf"
  echo "KEYMAP=${KEYMAP}" > "$MNT/etc/vconsole.conf"

  echo "$HOST_NAME" > "$MNT/etc/hostname"
  cat > "$MNT/etc/hosts" <<EOF
127.0.0.1  localhost
::1        localhost
127.0.1.1  ${HOST_NAME}.localdomain ${HOST_NAME}
EOF
  cat > "$MNT/etc/machine-info" <<EOF
PRETTY_HOSTNAME="${HOST_NAME} (${OSNAME})"
ICON_NAME=computer
EOF

  # zram swap: compressed RAM, no swap partition on disk
  cat > "$MNT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
  ok "System identity and locale configured."
}

# ───────────────────────────── phase 7: packages ─────────────────────────────
install_extras() {
  step "Installing privacy tools and desktop components"

  local priv_cli=(ufw tor torsocks proxychains-ng wireguard-tools openvpn networkmanager-openvpn
                  macchanger mat2 perl-image-exiftool gnupg apparmor firejail)
  local priv_gui=(firefox keepassxc veracrypt bleachbit torbrowser-launcher)
  local gui_common=(pipewire pipewire-alsa pipewire-pulse wireplumber librsvg
                    noto-fonts noto-fonts-emoji ttf-dejavu xdg-user-dirs)
  local de_pkgs=()

  case $DESKTOP in
    xfce)  de_pkgs=(xorg-server xfce4 xfce4-goodies lightdm lightdm-gtk-greeter network-manager-applet pavucontrol file-roller) ; DM=lightdm ;;
    kde)   de_pkgs=(plasma-meta konsole dolphin kate ark sddm) ; DM=sddm ;;
    gnome) de_pkgs=(gnome gnome-tweaks) ; DM=gdm ;;
    none)  DM="" ;;
  esac

  say "Privacy toolkit..."
  pac_install "${priv_cli[@]}"

  if [[ $DESKTOP != none ]]; then
    say "Desktop environment (${DESKTOP})..."
    pac_install "${gui_common[@]}" "${GPU_PKGS[@]}" "${de_pkgs[@]}" "${priv_gui[@]}"
  fi

  if (( ${#GUEST_PKGS[@]} > 0 )); then
    say "Virtual machine guest tools (${VIRT})..."
    pac_install "${GUEST_PKGS[@]}"
  fi

  ok "Package installation complete."
}

# ───────────────────────────── phase 8: privacy config ─────────────────────────────
configure_privacy() {
  step "Applying security and privacy configuration"

  # kernel/network hardening
  cat > "$MNT/etc/sysctl.d/99-mindware-hardening.conf" <<'EOF'
# MindwareOS hardening
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
net.core.bpf_jit_harden = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF

  # disable core dumps
  mkdir -p "$MNT/etc/systemd/coredump.conf.d"
  cat > "$MNT/etc/systemd/coredump.conf.d/00-mindware.conf" <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

  # block rarely used protocols and FireWire (DMA attack surface)
  cat > "$MNT/etc/modprobe.d/mindware-blacklist.conf" <<'EOF'
# Rarely needed and historically exploitable. Remove a line if the module is required.
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
install firewire-core /bin/false
EOF

  # DNS: systemd-resolved with Quad9 and DNS-over-TLS, no fallback servers
  mkdir -p "$MNT/etc/systemd/resolved.conf.d"
  cat > "$MNT/etc/systemd/resolved.conf.d/mindware-privacy.conf" <<'EOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net
FallbackDNS=
# 'opportunistic' is compatible with captive portals; set to 'yes' for strict DNS-over-TLS.
DNSOverTLS=opportunistic
DNSSEC=allow-downgrade
LLMNR=no
MulticastDNS=no
EOF

  # NetworkManager: randomized MAC addresses, systemd-resolved
  cat > "$MNT/etc/NetworkManager/conf.d/00-mindware-privacy.conf" <<'EOF'
[main]
dns=systemd-resolved

[device]
wifi.scan-rand-mac-address=yes

[connection]
# Random MAC per connection. If a network requires a fixed MAC, change 'random' to 'preserve'.
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
EOF

  # firewall: deny incoming, allow outgoing (ufw defaults), enabled at boot
  if [[ -f $MNT/etc/ufw/ufw.conf ]]; then
    sed -i 's/^ENABLED=.*/ENABLED=yes/' "$MNT/etc/ufw/ufw.conf"
  fi

  # Firefox: telemetry off, tracking protection on, uBlock Origin pre-installed
  if [[ $DESKTOP != none ]]; then
    mkdir -p "$MNT/etc/firefox/policies"
    cat > "$MNT/etc/firefox/policies/policies.json" <<'EOF'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DontCheckDefaultBrowser": true,
    "EnableTrackingProtection": { "Value": true, "Cryptomining": true, "Fingerprinting": true },
    "FirefoxHome": { "Pocket": false, "SponsoredPocket": false, "SponsoredTopSites": false },
    "UserMessaging": { "ExtensionRecommendations": false, "FeatureRecommendations": false, "SkipOnboarding": true },
    "ExtensionSettings": {
      "uBlock0@raymondhill.net": {
        "installation_mode": "normal_installed",
        "install_url": "https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
      }
    }
  }
}
EOF
  fi

  # services
  local svcs=(NetworkManager systemd-resolved systemd-timesyncd ufw apparmor fstrim.timer paccache.timer)
  if [[ -n ${DM:-} ]]; then svcs+=("$DM"); fi
  chroot_run systemctl enable "${svcs[@]}"
  local s
  for s in "${GUEST_SERVICES[@]}"; do chroot_run systemctl enable "$s" || warn "Could not enable $s."; done

  ok "Security and privacy configuration applied."
}

# ───────────────────────────── branding: logo assets ─────────────────────────────
write_logo_svg() { # write_logo_svg PATH  -> square 256x256 logo mark
  cat > "$1" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
  <title>MindwareOS</title>
  <defs>
    <linearGradient id="mw" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#22d3ee"/>
      <stop offset="1" stop-color="#a855f7"/>
    </linearGradient>
  </defs>
  <rect x="48" y="48" width="160" height="160" rx="24" fill="#0b0f1a" stroke="url(#mw)" stroke-width="8"/>
  <g stroke="url(#mw)" stroke-width="8" stroke-linecap="round" fill="none">
    <path d="M88 48V20M128 48V20M168 48V20M88 208v28M128 208v28M168 208v28M48 88H20M48 128H20M48 168H20M208 88h28M208 128h28M208 168h28"/>
  </g>
  <path d="M84 172V84l44 52 44-52v88" fill="none" stroke="url(#mw)" stroke-width="14" stroke-linejoin="round" stroke-linecap="round"/>
</svg>
EOF
}

write_wallpaper_svg() { # write_wallpaper_svg PATH -> 1920x1080
  cat > "$1" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <title>MindwareOS</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0b0f1a"/>
      <stop offset="1" stop-color="#1b1033"/>
    </linearGradient>
    <linearGradient id="mw" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#22d3ee"/>
      <stop offset="1" stop-color="#a855f7"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <g transform="translate(832 300)">
    <rect x="48" y="48" width="160" height="160" rx="24" fill="#0b0f1a" stroke="url(#mw)" stroke-width="8"/>
    <g stroke="url(#mw)" stroke-width="8" stroke-linecap="round" fill="none">
      <path d="M88 48V20M128 48V20M168 48V20M88 208v28M128 208v28M168 208v28M48 88H20M48 128H20M48 168H20M208 88h28M208 128h28M208 168h28"/>
    </g>
    <path d="M84 172V84l44 52 44-52v88" fill="none" stroke="url(#mw)" stroke-width="14" stroke-linejoin="round" stroke-linecap="round"/>
  </g>
  <g font-family="sans-serif" text-anchor="middle">
    <text x="960" y="680" font-size="84" font-weight="700" fill="#e2e8f0" letter-spacing="6">MindwareOS</text>
    <text x="960" y="745" font-size="30" fill="#94a3b8" letter-spacing="8">THINK. PROTECT. BOOT.</text>
  </g>
</svg>
EOF
}

# ───────────────────────────── phase 9: branding ─────────────────────────────
brand_system() {
  step "Applying ${OSNAME} branding (logos, wallpaper, fastfetch)"
  local share="$MNT/usr/share/mindwareos"
  mkdir -p "$share" "$MNT/etc/pacman.d/hooks" "$MNT/usr/local/bin" \
           "$MNT/etc/skel/.config/fastfetch" "$MNT/root/.config/fastfetch" \
           "$MNT/etc/xdg/fastfetch" "$MNT/usr/share/backgrounds/mindwareos" \
           "$MNT/usr/share/pixmaps" "$MNT/usr/share/icons/hicolor/scalable/apps"

  # --- system identity ---
  cat > "$share/os-release" <<'EOF'
NAME="MindwareOS"
PRETTY_NAME="MindwareOS"
ID=mindwareos
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="0;36"
LOGO=mindwareos
DEFAULT_HOSTNAME=mindware
EOF
  cat > "$share/lsb-release" <<'EOF'
DISTRIB_ID="MindwareOS"
DISTRIB_RELEASE="rolling"
DISTRIB_DESCRIPTION="MindwareOS"
EOF
  cat > "$MNT/usr/local/bin/mindware-rebrand" <<'EOF'
#!/bin/sh
# Re-apply MindwareOS identity after 'filesystem' package updates.
rm -f /etc/os-release
install -m 0644 /usr/share/mindwareos/os-release /etc/os-release
install -m 0644 /usr/share/mindwareos/lsb-release /etc/lsb-release
EOF
  chmod 755 "$MNT/usr/local/bin/mindware-rebrand"
  cat > "$MNT/etc/pacman.d/hooks/99-mindware-branding.hook" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = filesystem

[Action]
Description = Re-applying MindwareOS branding...
When = PostTransaction
Exec = /usr/local/bin/mindware-rebrand
EOF
  chroot_run /usr/local/bin/mindware-rebrand
  echo "${OSNAME} (installer v${VERSION}) installed on $(date -u +%F)" > "$MNT/etc/mindware-release"

  # --- logos (SVG source + system icon locations) ---
  write_logo_svg "$share/logo.svg"
  install -m 644 "$share/logo.svg" "$MNT/usr/share/pixmaps/mindwareos.svg"
  install -m 644 "$share/logo.svg" "$MNT/usr/share/icons/hicolor/scalable/apps/mindwareos.svg"
  write_wallpaper_svg "$MNT/usr/share/backgrounds/mindwareos/wallpaper.svg"

  # PNG renditions (needed by login screens and some toolkits); requires librsvg (desktop installs)
  if [[ -x $MNT/usr/bin/rsvg-convert ]]; then
    local sz
    for sz in 32 48 64 128 256; do
      mkdir -p "$MNT/usr/share/icons/hicolor/${sz}x${sz}/apps"
      chroot_run rsvg-convert -w "$sz" -h "$sz" /usr/share/mindwareos/logo.svg \
        -o "/usr/share/icons/hicolor/${sz}x${sz}/apps/mindwareos.png" || warn "Could not render ${sz}px logo."
    done
    chroot_run rsvg-convert -w 256 -h 256 /usr/share/mindwareos/logo.svg -o /usr/share/pixmaps/mindwareos.png \
      || warn "Could not render pixmap logo."
    chroot_run rsvg-convert -w 1920 -h 1080 /usr/share/backgrounds/mindwareos/wallpaper.svg \
      -o /usr/share/backgrounds/mindwareos/wallpaper.png || warn "Could not render wallpaper PNG."
    chroot_run gtk-update-icon-cache -q -f /usr/share/icons/hicolor 2>/dev/null || true
  fi

  # --- desktop defaults ---
  local wp=/usr/share/backgrounds/mindwareos/wallpaper.png
  case $DESKTOP in
    xfce)
      if [[ -f $MNT$wp ]]; then
        mkdir -p "$MNT/etc/lightdm"
        cat > "$MNT/etc/lightdm/lightdm-gtk-greeter.conf" <<EOF
[greeter]
background=${wp}
default-user-image=/usr/share/pixmaps/mindwareos.png
EOF
      fi ;;
    gnome)
      if [[ -f $MNT$wp && -x $MNT/usr/bin/dconf ]]; then
        mkdir -p "$MNT/etc/dconf/profile" "$MNT/etc/dconf/db/local.d"
        printf 'user-db:user\nsystem-db:local\n' > "$MNT/etc/dconf/profile/user"
        cat > "$MNT/etc/dconf/db/local.d/00-mindware" <<EOF
[org/gnome/desktop/background]
picture-uri='file://${wp}'
picture-uri-dark='file://${wp}'

[org/gnome/desktop/screensaver]
picture-uri='file://${wp}'
EOF
        chroot_run dconf update || warn "dconf update failed; wallpaper default not applied."
      fi ;;
  esac

  # --- ASCII assets ---
  wordmark > "$share/wordmark.txt"

  # fastfetch logo ($1 = cyan, $2 = magenta)
  cat > "$share/fastfetch-logo.txt" <<'EOF'
$1     ╷   ╷   ╷   ╷
$1  ╭──┴───┴───┴───┴──╮
$1  │                 │
$1  │    $2█▄     ▄█$1    │
$1  │    $2█ █▄ ▄█ █$1    │
$1  │    $2█  ▀█▀  █$1    │
$1  │    $2█       █$1    │
$1  │                 │
$1  ╰──┬───┬───┬───┬──╯
$1     ╵   ╵   ╵   ╵
EOF

  cat > "$share/fastfetch.jsonc" <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file",
    "source": "/usr/share/mindwareos/fastfetch-logo.txt",
    "color": { "1": "cyan", "2": "magenta" },
    "padding": { "top": 1, "right": 3 }
  },
  "display": {
    "separator": "  ➜  ",
    "color": { "keys": "cyan", "title": "magenta" }
  },
  "modules": [
    "title",
    "separator",
    "os",
    "host",
    "kernel",
    "uptime",
    "packages",
    "shell",
    "de",
    "wm",
    "terminal",
    "cpu",
    "gpu",
    "memory",
    "disk",
    "break",
    { "type": "custom",  "key": "Tagline",  "format": "think. protect. boot." },
    { "type": "command", "key": "Security", "text": "mind security" },
    "break",
    "colors"
  ]
}
EOF
  install -m 644 "$share/fastfetch.jsonc" "$MNT/etc/skel/.config/fastfetch/config.jsonc"
  install -m 644 "$share/fastfetch.jsonc" "$MNT/root/.config/fastfetch/config.jsonc"
  install -m 644 "$share/fastfetch.jsonc" "$MNT/etc/xdg/fastfetch/config.jsonc"

  # --- login banner (/etc/issue) and motd ---
  {
    printf '\e[1;36m'; wordmark; printf '\e[0m'
    printf '\e[1;35m   %s -- %s\e[0m\n' "$OSNAME" "$TAGLINE"
    printf '\n   Kernel \\r on an \\m (\\l)\n\n'
  } > "$MNT/etc/issue"
  printf '%s\n' "$OSNAME" > "$MNT/etc/issue.net"
  {
    printf '\e[1;36m'; wordmark; printf '\e[0m'
    printf '\e[1;35m   %s -- %s\e[0m\n\n' "$OSNAME" "$TAGLINE"
    printf '   Run "mind help" for system commands.\n\n'
  } > "$MNT/etc/motd"

  # --- mind CLI ---
  cat > "$MNT/usr/local/bin/mind" <<'EOF'
#!/bin/sh
# mind -- MindwareOS helper: package shortcuts and system status
cmd=${1:-info}
[ $# -gt 0 ] && shift
case "$cmd" in
  install|i)   exec sudo pacman -S --needed "$@" ;;
  remove|rm|r) exec sudo pacman -Rns "$@" ;;
  update|up|u) exec sudo pacman -Syu "$@" ;;
  search|s)    exec pacman -Ss "$@" ;;
  show)        exec pacman -Si "$@" ;;
  clean)       exec sudo paccache -r ;;
  orphans)     pacman -Qdtq || echo "No orphaned packages." ;;
  banner)      cat /usr/share/mindwareos/wordmark.txt ;;
  security)
    fw=$(systemctl is-active ufw 2>/dev/null)
    aa=$(systemctl is-active apparmor 2>/dev/null)
    if lsblk -rno TYPE 2>/dev/null | grep -qx crypt; then enc="encrypted"; else enc="not encrypted"; fi
    echo "firewall ${fw}, apparmor ${aa}, disk ${enc}"
    ;;
  privacy)
    echo "== MindwareOS privacy status =="
    printf 'Firewall (ufw)  : '; systemctl is-active ufw
    printf 'AppArmor        : '; systemctl is-active apparmor
    printf 'Tor service     : '; systemctl is-active tor
    echo   'DNS:'; resolvectl status 2>/dev/null | grep -E 'Current DNS|DNS Servers|Protocols' | head -6
    ;;
  version)     cat /etc/mindware-release ;;
  info)
    cat /usr/share/mindwareos/wordmark.txt
    echo
    exec fastfetch ;;
  help|-h|--help|*)
    cat <<HELP
mind -- MindwareOS helper

  mind install <pkg>   install packages      mind update    full system upgrade
  mind remove  <pkg>   remove with deps      mind search    search repositories
  mind show    <pkg>   package details       mind clean     trim package cache
  mind orphans         list orphaned pkgs    mind privacy   privacy status
  mind security        one-line security     mind version   installer version
  mind info            banner + fastfetch
HELP
    ;;
esac
EOF
  chmod 755 "$MNT/usr/local/bin/mind"
  ln -sf mind "$MNT/usr/local/bin/mindware"

  # --- shell branding (applies to new users and root) ---
  bashrc_block() {
cat <<'EOF'

# ───── MindwareOS ─────
PS1='\[\e[1;35m\]\u\[\e[0m\]@\[\e[1;36m\]\h\[\e[0m\] \[\e[1;34m\]\w\[\e[0m\] \[\e[2m\]λ\[\e[0m\] '
alias ll='ls -lAh --color=auto'
alias update='mind update'
alias mw='mind'
if [[ $- == *i* ]] && command -v fastfetch >/dev/null 2>&1; then
  fastfetch
fi
EOF
  }
  bashrc_block >> "$MNT/etc/skel/.bashrc"
  bashrc_block >> "$MNT/root/.bashrc"

  ok "Branding applied: os-release, logos, wallpaper, fastfetch, login banner, shell prompt, 'mind' CLI."
}

# ───────────────────────────── phase 10: user accounts ─────────────────────────────
create_users() {
  step "Creating user account"
  chroot_run useradd -m -G wheel -s /bin/bash -c "$FULLNAME" "$USERNAME"
  printf '%s:%s\n' "$USERNAME" "$USER_PASS" | chroot_run chpasswd

  if (( LOCK_ROOT )); then
    chroot_run passwd -l root
  else
    printf 'root:%s\n' "$ROOT_PASS" | chroot_run chpasswd
  fi

  echo '%wheel ALL=(ALL:ALL) ALL' > "$MNT/etc/sudoers.d/10-wheel"
  printf 'Defaults pwfeedback\n' > "$MNT/etc/sudoers.d/20-mindware"
  chmod 440 "$MNT/etc/sudoers.d/10-wheel" "$MNT/etc/sudoers.d/20-mindware"
  chroot_run visudo -c >/dev/null

  ok "User ${USERNAME} created with sudo access."
}

# ───────────────────────────── phase 11: bootloader ─────────────────────────────
install_bootloader() {
  step "Installing the bootloader (GRUB, UEFI)"

  if (( ENCRYPT )); then
    sed -i '/^HOOKS=/ s/\bfilesystems\b/encrypt filesystems/' "$MNT/etc/mkinitcpio.conf"
  fi
  chroot_run mkinitcpio -P

  local cmd_default="loglevel=3 quiet lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
  local cmd_linux=""
  if (( ENCRYPT )); then
    cmd_linux="cryptdevice=UUID=$(blkid -s UUID -o value "$ROOT_PART"):cryptroot root=/dev/mapper/cryptroot"
  fi
  sed -i \
    -e "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${cmd_default}\"|" \
    -e "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${cmd_linux}\"|" \
    -e "s|^GRUB_DISTRIBUTOR=.*|GRUB_DISTRIBUTOR=\"${OSNAME}\"|" \
    "$MNT/etc/default/grub"

  # ASCII splash before the GRUB menu (ESC skips the 1 second pause).
  # To remove: delete /etc/grub.d/05_mindware_banner and re-run grub-mkconfig.
  {
    echo '#!/bin/sh'
    echo "cat <<'GRUB_EOF'"
    echo "echo ''"
    local l
    while IFS= read -r l; do printf "echo '%s'\n" "$l"; done < <(wordmark)
    echo "echo ''"
    echo "echo '   ${OSNAME} :: ${TAGLINE}'"
    echo "sleep --interruptible 1"
    echo "GRUB_EOF"
  } > "$MNT/etc/grub.d/05_mindware_banner"
  chmod 755 "$MNT/etc/grub.d/05_mindware_banner"

  cat > "$MNT/etc/grub.d/41_mindware_extras" <<'EOF'
#!/bin/sh
exec tail -n +3 $0
menuentry "MindwareOS :: UEFI Firmware Settings" { fwsetup }
menuentry "MindwareOS :: Reboot" { reboot }
menuentry "MindwareOS :: Power Off" { halt }
EOF
  chmod 755 "$MNT/etc/grub.d/41_mindware_extras"

  chroot_run grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=MindwareOS --recheck
  chroot_run grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=MindwareOS --removable --recheck
  chroot_run grub-mkconfig -o /boot/grub/grub.cfg

  ok "Bootloader installed."
}

# ───────────────────────────── phase 12: finish ─────────────────────────────
finish() {
  step "Finalizing"
  # The resolv.conf symlink must be created outside arch-chroot (it bind-mounts resolv.conf)
  rm -f "$MNT/etc/resolv.conf"
  ln -s ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"

  cp "$LOGFILE" "$MNT/var/log/mindware-install.log" 2>/dev/null || true
  sync
  umount -R "$MNT"
  if (( ENCRYPT )); then cryptsetup close cryptroot || true; fi

  printf '\n%s' "$GRN"
  wordmark
  printf '%s\n' "$RST"
  printf '%s%s has been installed successfully.%s\n' "$GRN" "$OSNAME" "$RST"
  cat <<EOF

   Next steps:
     1. Remove the installation media.
     2. Reboot and log in as ${USERNAME}.
     3. Run 'mind help' to see available system commands.

   The installation log is saved at /var/log/mindware-install.log on the new system.
EOF
  echo
  if ask_yn "Reboot now?" y; then reboot; fi
}

# ───────────────────────────── main ─────────────────────────────
main() {
  # Root is required for everything below (and for the log file).
  if [[ $EUID -ne 0 ]]; then
    printf '%s ✘ This installer must be run as root.%s\n' "$RED" "$RST" >&2
    printf '   On the Arch live ISO you are already root. Elsewhere use: sudo bash %s\n' "$(basename "$0")" >&2
    exit 1
  fi

  # Support "curl ... | bash": when stdin is a pipe, read prompts from the terminal instead.
  # (The whole script has already been read by this point, so this is safe.)
  if [[ ! -t 0 ]]; then
    if ( : </dev/tty ) 2>/dev/null; then
      exec </dev/tty
    else
      printf '%s ✘ An interactive terminal is required. Save the script to a file and run: bash mindware-install.sh%s\n' "$RED" "$RST" >&2
      exit 1
    fi
  fi

  : > "$LOGFILE"
  banner
  preflight
  gather_config
  confirm_plan
  partition_disk
  format_and_mount
  install_base
  configure_system
  install_extras
  configure_privacy
  brand_system
  create_users
  install_bootloader
  finish
}

main "$@"
