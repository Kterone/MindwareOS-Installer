#!/usr/bin/env bash
#
#  ███  MindwareOS Installer  ███
#  An "archinstall"-style, UEFI-only installer with branding, privacy hardening
#  and a sense of humour. Run it from the official Arch Linux live ISO:
#
#      curl -O <wherever-you-host-it>/mindware-install.sh   (or copy it over)
#      bash mindware-install.sh            # full experience
#      bash mindware-install.sh --no-jokes # serious mode (we'll miss you)
#
#  WARNING: this ERASES the disk you choose. It asks you to confirm by typing
#  the disk name, but still... read what's on screen.
#
set -Eeuo pipefail

OSNAME="MindwareOS"
VERSION="1.0"
TAGLINE="think. protect. boot."
LOGFILE="/tmp/mindware-install.log"
MNT="/mnt"
JOKES=1
STEP=0
TOTAL_STEPS=12

usage() {
  cat <<EOF
$OSNAME installer v$VERSION

Usage: bash $(basename "$0") [options]

  --no-jokes   Disable the humour (boring, but valid)
  -h, --help   Show this help

Environment:
  MINDWARE_FORCE=1   Skip the "are we on the Arch live ISO?" check
EOF
}

for arg in "$@"; do
  case $arg in
    --no-jokes) JOKES=0 ;;
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

art_warning() {
cat <<'ART'
         /\
        /  \
       / !! \
      /  ||  \
     /   ..   \
    /__________\
ART
}

art_coffee() {
cat <<'ART'
      ( (
       ) )
    .______.
    |      |]
    \      /
     `----'
ART
}

art_rocket() {
cat <<'ART'
          ^
         /^\
        /___\
       |=   =|
       |  O  |
       |=   =|
      /|##|##|\
     / |##|##| \
    /__|__|__|__\
       /_\ /_\
        !!!!!
ART
}

banner() {
  clear 2>/dev/null || true
  printf '%s\n' "$CYN"
  wordmark
  printf '%s\n' "$RST"
  printf '%s       ::  %s v%s  --  %s  ::%s\n\n' "$MAG" "$OSNAME" "$VERSION" "$TAGLINE" "$RST"
}

# ───────────────────────────── helpers ─────────────────────────────
log()  { printf '[%s] %s\n' "$(date +%T)" "$*" >>"$LOGFILE"; }
say()  { printf '%s%s%s\n' "$CYN" "$*" "$RST"; log "$*"; }
ok()   { printf '%s ✔ %s%s\n' "$GRN" "$*" "$RST"; log "OK: $*"; }
warn() { printf '%s ! %s%s\n' "$YLW" "$*" "$RST" >&2; log "WARN: $*"; }
die()  { printf '\n%s ✘ %s%s\n' "$RED" "$*" "$RST" >&2; log "FATAL: $*"; exit 1; }

joke() {
  if (( JOKES )); then
    printf '   %s» %s%s\n' "$DIM" "$*" "$RST"
  fi
}

pick() { # pick "a" "b" "c" -> random element
  local arr=("$@")
  printf '%s' "${arr[RANDOM % ${#arr[@]}]}"
}

step() {
  STEP=$((STEP + 1))
  printf '\n%s[%d/%d]%s %s%s%s\n' "$BLU" "$STEP" "$TOTAL_STEPS" "$RST" "$MAG" "$*" "$RST"
  log "STEP $STEP: $*"
}

on_error() {
  local code=$? line=$1 cmd=$2
  trap - ERR
  printf '\n%s' "$RED"
  art_warning
  printf '%s\n' "$RST"
  printf '%s ✘ %s%s\n' "$RED" "$(pick \
      "Well, that went sideways." \
      "Houston, we have a problem." \
      "The installer tripped over its own shoelaces." \
      "Something exploded. Quietly, but it exploded.")" "$RST"
  printf '   %sline %s: %s (exit %s)%s\n' "$DIM" "$line" "$cmd" "$code" "$RST"
  printf '   Log: %s\n' "$LOGFILE"
  printf '   Anything already mounted under %s is left as-is so you can poke around.\n' "$MNT"
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

ask_pass() { # ask_pass VAR "prompt"
  local __var=$1 prompt=$2 p1 p2
  while true; do
    read -r -s -p "${CYN}?${RST} ${prompt}: " p1; echo
    if [[ -z $p1 ]]; then
      warn "Empty password? That's not a password, that's a suggestion."
      continue
    fi
    read -r -s -p "${CYN}?${RST} Again, with feeling: " p2; echo
    if [[ $p1 == "$p2" ]]; then break; fi
    warn "Mismatch. Keyboard 1, you 0. Try again."
  done
  printf -v "$__var" '%s' "$p1"
}

choose() { # choose VAR "title" "value|description" ...   (first = default)
  local __var=$1 title=$2; shift 2
  local opts=("$@") i pick_ val
  printf '%s%s%s\n' "$MAG" "$title" "$RST"
  for i in "${!opts[@]}"; do
    printf '   %s%d)%s %s\n' "$YLW" $((i + 1)) "$RST" "${opts[$i]#*|}"
  done
  while true; do
    read -r -p "   choice ${DIM}[1]${RST}: " pick_
    pick_=${pick_:-1}
    if [[ $pick_ =~ ^[0-9]+$ ]] && (( pick_ >= 1 && pick_ <= ${#opts[@]} )); then
      val=${opts[$((pick_ - 1))]%%|*}
      printf -v "$__var" '%s' "$val"
      return 0
    fi
    warn "Pick a number from 1 to ${#opts[@]}. Counting is fun, I promise."
  done
}

part() { # part N -> /dev/sdX1 or /dev/nvme0n1p1
  if [[ $DISK =~ [0-9]$ ]]; then printf '%sp%s' "$DISK" "$1"; else printf '%s%s' "$DISK" "$1"; fi
}

chroot_run() { arch-chroot "$MNT" "$@"; }

pac_install() { # install packages in the target; fall back to one-by-one
  local p
  if ! arch-chroot "$MNT" pacman -S --noconfirm --needed "$@"; then
    warn "Batch install hiccuped; trying one package at a time..."
    for p in "$@"; do
      arch-chroot "$MNT" pacman -S --noconfirm --needed "$p" || warn "  '$p' ghosted us. Skipping."
    done
  fi
}

# ───────────────────────────── humour engine ─────────────────────────────
joke_username() {
  local u=$1
  case "${u,,}" in
    admin|administrator) joke "'$u'? Bold. It's every attacker's second guess, right after 'root'." ;;
    user|test|guest)     joke "'$u'... the creativity is overwhelming." ;;
    hacker|h4x0r|anon|anonymous) joke "A '$u'. Please keep the hoodie on. Thank you." ;;
    arch|archuser)       joke "Named after the distro. We'll allow it. Also: btw you use Arch." ;;
    linus|torvalds)      joke "Linus? If it's really you: hi, and please don't yell at the kernel config." ;;
    *)
      if [[ $u =~ [0-9]{3,} ]]; then
        joke "That many digits? Birthday, or number of times you've reinstalled?"
      elif (( ${#u} <= 2 )); then
        joke "'$u': short and sweet. Like a good boot time."
      elif (( ${#u} >= 16 )); then
        joke "'$u' is a long one. Tab completion will carry you."
      else
        joke "Welcome aboard, ${u^}. Your files, your rules, zero telemetry."
      fi ;;
  esac
}

joke_hostname() {
  local h=${1,,}
  case $h in
    archlinux|arch|localhost) joke "'$h'? Originality level: factory default. Respect the honesty though." ;;
    ubuntu|debian|fedora)     joke "Wrong distro, but I admire the hustle." ;;
    pc|laptop|desktop|computer) joke "'$h'. So specific. Does it also answer to 'thing'?" ;;
    mindware)                 joke "Default hostname. Efficient. Lazy. Same thing." ;;
    *)                        joke "'$1' it is. Your machine now has an identity crisis... solved." ;;
  esac
}

joke_password() {
  local p=$1 len=${#1}
  case ${p,,} in
    password|123456|12345678|qwerty|letmein|admin|iloveyou|"$USERNAME")
      joke "That password has been in more breaches than a rowboat made of sieves. (We'll let you keep it. Please don't.)"
      return 0 ;;
  esac
  if (( len < 8 )); then
    joke "Under 8 characters. A toaster could crack that with a stern look."
  elif (( len < 12 )); then
    joke "Decent. Not stellar, not terrible. The beige of passwords."
  elif (( len < 16 )); then
    joke "Solid. A hacker just sighed and went to find an easier target."
  else
    joke "A proper passphrase. Even I don't want to guess that."
  fi
}

joke_hour() {
  local h; h=$(date +%H); h=$((10#$h))
  if   (( h < 5 ));  then joke "It's $(date +%H:%M) and you're installing an OS. Legend, or deadline?"
  elif (( h < 12 )); then joke "Morning install! Coffee first, kernel second."
  elif (( h < 18 )); then joke "Afternoon install. Productive procrastination, I see."
  else                    joke "Evening install: the sweet spot between 'I have time' and 'I should sleep'."
  fi
}

joke_timezone() {
  case $1 in
    UTC)                          joke "UTC: you either run servers or refuse to pick a side." ;;
    Asia/Kolkata|Asia/Calcutta)   joke "A +05:30 offset. Developers everywhere quietly weep. Lovingly." ;;
    America/*)                    joke "The Americas. Daylight saving remains everyone's nemesis." ;;
    Europe/*)                     joke "Europe. Tell the clocks I said hi... twice a year." ;;
    *)                            joke "Timezone '$1' locked in. Yes, I could GeoIP it, but we're a privacy distro. Typing is the price." ;;
  esac
}

joke_disk() {
  local gb rot
  gb=$(( $(lsblk -bdno SIZE "$DISK") / 1000000000 ))
  if   (( gb < 60 ));   then joke "${gb} GB. Cozy. Choose your apps wisely."
  elif (( gb < 500 ));  then joke "${gb} GB. A perfectly respectable amount of room."
  elif (( gb < 2100 )); then joke "${gb} GB. Plenty of space for memes and 400 tabs' worth of cache."
  else                       joke "${gb} GB. More terabytes than sense. Respect."
  fi
  if [[ $DISK == *nvme* ]]; then
    joke "NVMe: so fast you'll miss the splash screen. (We added one anyway.)"
  else
    rot=$(cat "/sys/block/${DISK##*/}/queue/rotational" 2>/dev/null || echo 0)
    if [[ $rot == 1 ]]; then joke "Spinning rust! Grab a coffee, this is going to be a nostalgic journey."; fi
  fi
}

joke_desktop() {
  case $1 in
    none)  joke "TTY gang. No GUI, no distractions, no mercy." ;;
    xfce)  joke "XFCE: the mouse and your RAM are both grateful." ;;
    kde)   joke "Plasma: customisation gremlins, welcome home." ;;
    gnome) joke "GNOME: bold of you to expect fewer buttons... and more extensions." ;;
  esac
}

joke_kernel() {
  case $1 in
    linux)          joke "Vanilla kernel. Classic. Like a good black t-shirt." ;;
    linux-hardened) joke "Hardened kernel: for when 'secure' isn't paranoid enough." ;;
    linux-lts)      joke "LTS: kernel like coffee. Stable and unsurprising." ;;
    linux-zen)      joke "Zen: because milliseconds matter and so does inner peace." ;;
  esac
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

  say "Hardware: CPU=${CPU_VENDOR:-unknown}, RAM≈${RAM_GB}GB, virt=${VIRT:-none}"
  if (( RAM_GB <= 2 )); then joke "Only ~${RAM_GB} GB of RAM. We'll go light. Firefox will have opinions."; fi
  if (( RAM_GB >= 32 )); then joke "${RAM_GB} GB of RAM. Chrome tabs rejoice. (We don't ship Chrome, sorry.)"; fi
  if (( HAS_NVIDIA )); then joke "NVIDIA detected. We use the open-source nouveau stack; proprietary drivers are your adventure later."; fi
  if [[ -n $VIRT && $VIRT != none ]]; then joke "Running inside a VM ($VIRT)? Inception music intensifies."; fi
}

# ───────────────────────────── phase 1: preflight ─────────────────────────────
preflight() {
  step "Preflight checks (poking the machine with a stick)"
  [[ $EUID -eq 0 ]] || die "Run me as root. I'm not asking nicely because I can't."

  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    die "No UEFI detected. This installer is UEFI-only (it's the current decade, boot in UEFI mode)."
  fi

  local c
  for c in pacstrap genfstab arch-chroot sgdisk lsblk mkfs.fat blkid partprobe curl; do
    command -v "$c" >/dev/null 2>&1 || die "Missing '$c'. Are you on the official Arch live ISO?"
  done

  if [[ ! -d /run/archiso && -z ${MINDWARE_FORCE:-} ]]; then
    die "Doesn't look like the Arch live ISO. Boot from it (or set MINDWARE_FORCE=1 if you really know what you're doing)."
  fi

  say "Checking the internet (pinging the void)..."
  if ! curl -fsS --max-time 8 -o /dev/null https://archlinux.org; then
    joke "No internet. 'iwctl' is your friend for Wi-Fi: station wlan0 connect <SSID>"
    die "No internet connection. Fix that and re-run me."
  fi
  ok "Online."

  timedatectl set-ntp true || true
  joke_hour
  detect_hardware
}

# ───────────────────────────── phase 2: questions ─────────────────────────────
gather_config() {
  step "Questions (no exam, just a mild interrogation)"

  # --- user ---
  while true; do
    ask USERNAME "Username for your shiny new account"
    if [[ $USERNAME == root ]]; then
      warn "'root' already exists. It's the original gangster; pick another."
      continue
    fi
    if [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then break; fi
    warn "Lowercase letters, digits, - and _ only; start with a letter or _. Linux is picky, not personal."
  done
  joke_username "$USERNAME"

  ask FULLNAME "Display name (for login screens)" "${USERNAME^}"
  FULLNAME=${FULLNAME//[:,]/}

  ask_pass USER_PASS "Password for ${USERNAME} (also used for sudo)"
  joke_password "$USER_PASS"

  if ask_yn "Lock the root account and use sudo only? (recommended)" y; then
    LOCK_ROOT=1
    joke "Root locked. Even root can't log in. It's fine, root is used to it."
  else
    LOCK_ROOT=0
    ask_pass ROOT_PASS "Root password"
  fi

  # --- machine ---
  while true; do
    ask HOST_NAME "Hostname" "mindware"
    if [[ $HOST_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then break; fi
    warn "Letters, digits and hyphens only; no leading/trailing hyphen."
  done
  joke_hostname "$HOST_NAME"

  while true; do
    ask TZONE "Timezone (e.g. Europe/Berlin, America/New_York, Asia/Kolkata)" "UTC"
    if [[ -f /usr/share/zoneinfo/$TZONE ]]; then break; fi
    warn "I don't know a timezone called '$TZONE'. Check /usr/share/zoneinfo."
  done
  joke_timezone "$TZONE"

  while true; do
    ask LOCALE "Locale" "en_US.UTF-8"
    if [[ ! -r /usr/share/i18n/SUPPORTED ]] || grep -q "^${LOCALE} " /usr/share/i18n/SUPPORTED; then break; fi
    warn "Unsupported locale '$LOCALE'. See /usr/share/i18n/SUPPORTED."
  done

  while true; do
    ask KEYMAP "Console keymap" "us"
    if ! command -v localectl >/dev/null 2>&1 || [[ -z $(localectl list-keymaps 2>/dev/null) ]] \
       || localectl list-keymaps 2>/dev/null | grep -qx "$KEYMAP"; then break; fi
    warn "Unknown keymap '$KEYMAP'. Try: localectl list-keymaps"
  done
  loadkeys "$KEYMAP" 2>/dev/null || true
  case $KEYMAP in
    dvorak*|colemak*) joke "A $KEYMAP user! I'll pretend I understand where the Q key went." ;;
  esac

  # --- disk ---
  local ISO_SRC ISO_DISK="" name size model
  ISO_SRC=$(findmnt -rno SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  if [[ -n $ISO_SRC ]]; then ISO_DISK=$(lsblk -no PKNAME "$ISO_SRC" 2>/dev/null | head -1 || true); fi
  DISK_OPTS=()
  while read -r name size model; do
    if [[ -n $ISO_DISK && $name == "/dev/$ISO_DISK" ]]; then continue; fi
    DISK_OPTS+=("${name}|${name}  ${size}  ${model:-unknown model}")
  done < <(lsblk -dpno NAME,SIZE,MODEL -e 7,11)
  (( ${#DISK_OPTS[@]} > 0 )) || die "No installable disks found. Did the disk wander off?"
  echo
  choose DISK "Which disk gets ERASED and reborn as ${OSNAME}?" "${DISK_OPTS[@]}"
  joke_disk

  # --- storage layout ---
  echo
  choose FS_TYPE "Root filesystem" \
    "btrfs|btrfs  - snapshots, compression, subvolumes (recommended)" \
    "ext4|ext4   - boring, reliable, will outlive us all"
  if [[ $FS_TYPE == btrfs ]]; then
    joke "Btrfs: because snapshots are cheaper than regrets."
  else
    joke "ext4: if it ain't broke, don't format it."
  fi

  echo
  if ask_yn "Encrypt the whole disk with LUKS2? (privacy distro, so... yes?)" y; then
    ENCRYPT=1
    ask_pass LUKS_PASS "Disk encryption passphrase"
    joke "Forget this passphrase and your data becomes a very expensive paperweight. No pressure."
    joke_password "$LUKS_PASS"
  else
    ENCRYPT=0
    joke "No encryption? Living dangerously. Bold. (It's cheaper than regret, just saying.)"
  fi

  # --- kernel & desktop ---
  echo
  choose KERNEL "Kernel" \
    "linux|linux          - vanilla, the classic" \
    "linux-hardened|linux-hardened - extra security hardening (some apps may grumble)" \
    "linux-lts|linux-lts      - long-term support, calm and stable" \
    "linux-zen|linux-zen      - tuned for desktop responsiveness"
  joke_kernel "$KERNEL"

  echo
  choose DESKTOP "Desktop environment" \
    "xfce|XFCE        - light, friendly, mouse-approved" \
    "kde|KDE Plasma  - all the knobs" \
    "gnome|GNOME       - all the minimalism" \
    "none|None         - pure TTY, for the brave"
  joke_desktop "$DESKTOP"
}

confirm_plan() {
  step "Summary (last chance to back out gracefully)"
  printf '\n%s' "$YLW"; art_warning; printf '%s\n' "$RST"
  cat <<EOF
   ${MAG}User${RST}        : ${USERNAME} (${FULLNAME})  $( ((LOCK_ROOT)) && echo '[root locked]' || echo '[root enabled]')
   ${MAG}Hostname${RST}    : ${HOST_NAME}
   ${MAG}Timezone${RST}    : ${TZONE}   ${MAG}Locale${RST}: ${LOCALE}   ${MAG}Keymap${RST}: ${KEYMAP}
   ${MAG}Disk${RST}        : ${RED}${DISK}${RST}  (EVERYTHING ON IT WILL BE DESTROYED)
   ${MAG}Filesystem${RST}  : ${FS_TYPE}   ${MAG}Encryption${RST}: $( ((ENCRYPT)) && echo 'LUKS2' || echo 'none')
   ${MAG}Kernel${RST}      : ${KERNEL}    ${MAG}Desktop${RST}: ${DESKTOP}
   ${MAG}Bootloader${RST}  : GRUB (UEFI), branded as ${OSNAME}
EOF
  echo
  lsblk "$DISK" || true
  echo
  joke "Say goodbye to $(lsblk -no SIZE "$DISK" | head -1 | tr -d ' ') of memes, tax returns and half-finished projects on ${DISK}."
  local typed
  read -r -p "${RED}Type ${DISK} to confirm and begin${RST}: " typed
  [[ $typed == "$DISK" ]] || die "You typed '${typed}', not '${DISK}'. Nothing was touched. Safe, like a seatbelt."
}

# ───────────────────────────── phase 3: partitioning ─────────────────────────────
partition_disk() {
  step "Partitioning ${DISK} (sharpening the scalpel)"
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
  ok "Created ${ESP_PART} (1 GiB ESP) and ${ROOT_PART} (the rest)."
  joke "Partition table: written. No bits were harmed in the making of this layout (many were erased)."
}

# ───────────────────────────── phase 4: format & mount ─────────────────────────────
format_and_mount() {
  step "Formatting & mounting"
  local ROOT_DEV=$ROOT_PART

  if (( ENCRYPT )); then
    say "Setting up LUKS2 encryption (this is the 'argon2 thinks hard' bit)..."
    printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$ROOT_PART"
    printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" cryptroot
    ROOT_DEV=/dev/mapper/cryptroot
    ok "LUKS container unlocked."
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
  ok "Everything mounted under ${MNT}."
}

# ───────────────────────────── phase 5: base install ─────────────────────────────
install_base() {
  step "Installing the base system (the long part)"
  printf '%s' "$CYN"; art_coffee; printf '%s\n' "$RST"
  joke "$(pick \
    "Downloading the internet's finest packages (the legal ones)." \
    "Time for coffee. Real coffee. This isn't an Electron app, but it still takes a while." \
    "pacman is eating packages. Om nom nom." \
    "Compiling nothing, downloading everything. Such is the Arch way.")"

  say "Refreshing keyring & ranking mirrors..."
  pacman -Sy --noconfirm --needed archlinux-keyring || warn "Keyring refresh failed; continuing with the ISO's keyring."
  if command -v reflector >/dev/null 2>&1; then
    timeout 120 reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist \
      || warn "reflector sulked; using the existing mirrors."
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

  # Make pacman pretty (and a little silly)
  local pc="$MNT/etc/pacman.conf"
  sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 10/' "$pc"
  if ! grep -q '^ILoveCandy' "$pc"; then sed -i '/^Color/a ILoveCandy' "$pc"; fi
  joke "pacman now has Pac-Man progress bars (ILoveCandy). You're welcome."
}

# ───────────────────────────── phase 6: system config ─────────────────────────────
configure_system() {
  step "Configuring the system (time, language, identity)"
  ln -sf "/usr/share/zoneinfo/${TZONE}" "$MNT/etc/localtime"
  chroot_run hwclock --systohc || warn "hwclock complained (normal in some VMs)."

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

  # zram swap: compressed RAM, no swap partition to leak secrets onto disk
  cat > "$MNT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
  ok "Identity and locale configured."
}

# ───────────────────────────── phase 7: packages ─────────────────────────────
install_extras() {
  step "Installing privacy tools & extras (the fun shopping trip)"

  local priv_cli=(ufw tor torsocks proxychains-ng wireguard-tools openvpn networkmanager-openvpn
                  macchanger mat2 perl-image-exiftool gnupg apparmor firejail)
  local priv_gui=(firefox keepassxc veracrypt bleachbit torbrowser-launcher)
  local gui_common=(pipewire pipewire-alsa pipewire-pulse wireplumber
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
    say "Desktop (${DESKTOP}) and friends..."
    pac_install "${gui_common[@]}" "${GPU_PKGS[@]}" "${de_pkgs[@]}" "${priv_gui[@]}"
  fi

  if (( ${#GUEST_PKGS[@]} > 0 )); then
    say "VM guest tools (${VIRT})..."
    pac_install "${GUEST_PKGS[@]}"
  fi

  ok "Packages installed."
  joke "You now own more privacy tools than most people own socks."
}

# ───────────────────────────── phase 8: privacy config ─────────────────────────────
configure_privacy() {
  step "Hardening & privacy configuration"

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

  # no core dumps leaking memory contents
  mkdir -p "$MNT/etc/systemd/coredump.conf.d"
  cat > "$MNT/etc/systemd/coredump.conf.d/00-mindware.conf" <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

  # block obscure protocols & DMA-happy buses
  cat > "$MNT/etc/modprobe.d/mindware-blacklist.conf" <<'EOF'
# Rarely needed, historically exploitable. Remove a line if you need it.
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
install firewire-core /bin/false
EOF

  # DNS: systemd-resolved with Quad9 + DNS-over-TLS, no fallback leakage
  mkdir -p "$MNT/etc/systemd/resolved.conf.d"
  cat > "$MNT/etc/systemd/resolved.conf.d/mindware-privacy.conf" <<'EOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net
FallbackDNS=
# 'opportunistic' plays nice with captive portals; set to 'yes' for strict DoT.
DNSOverTLS=opportunistic
DNSSEC=allow-downgrade
LLMNR=no
MulticastDNS=no
EOF

  # NetworkManager: randomised MACs, use resolved
  cat > "$MNT/etc/NetworkManager/conf.d/00-mindware-privacy.conf" <<'EOF'
[main]
dns=systemd-resolved

[device]
wifi.scan-rand-mac-address=yes

[connection]
# Random MAC per connection. If a network insists on a fixed MAC, change 'random' to 'preserve'.
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random
EOF

  # firewall: deny incoming, allow outgoing (ufw defaults), enabled at boot
  if [[ -f $MNT/etc/ufw/ufw.conf ]]; then
    sed -i 's/^ENABLED=.*/ENABLED=yes/' "$MNT/etc/ufw/ufw.conf"
  fi

  # Firefox: no telemetry/pocket/studies, tracking protection on, uBlock Origin pre-installed
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
  for s in "${GUEST_SERVICES[@]}"; do chroot_run systemctl enable "$s" || warn "Couldn't enable $s."; done

  ok "Hardening applied."
  joke "Telemetry on this system: 0 bytes. Gossip: also 0."
}

# ───────────────────────────── phase 9: branding ─────────────────────────────
brand_system() {
  step "Branding everything with ${OSNAME} (ASCII art included)"
  local share="$MNT/usr/share/mindwareos"
  mkdir -p "$share" "$MNT/etc/pacman.d/hooks" "$MNT/usr/local/bin" \
           "$MNT/etc/skel/.config/fastfetch" "$MNT/root/.config/fastfetch" \
           "$MNT/etc/xdg/fastfetch" "$MNT/usr/share/backgrounds/mindwareos"

  # --- identity files ---
  cat > "$share/os-release" <<'EOF'
NAME="MindwareOS"
PRETTY_NAME="MindwareOS"
ID=mindwareos
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="0;36"
DEFAULT_HOSTNAME=mindware
EOF
  cat > "$share/lsb-release" <<'EOF'
DISTRIB_ID="MindwareOS"
DISTRIB_RELEASE="rolling"
DISTRIB_DESCRIPTION="MindwareOS"
EOF
  cat > "$MNT/usr/local/bin/mindware-rebrand" <<'EOF'
#!/bin/sh
# Re-apply MindwareOS identity (the 'filesystem' package keeps trying to be Arch again).
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

  # --- ASCII assets ---
  wordmark > "$share/wordmark.txt"

  # Fastfetch logo ($1 = cyan, $2 = magenta)
  cat > "$share/logo.txt" <<'EOF'
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

  # Fastfetch config
  cat > "$share/fastfetch.jsonc" <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file",
    "source": "/usr/share/mindwareos/logo.txt",
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
    { "type": "custom", "key": "Motto",   "format": "think. protect. boot." },
    { "type": "custom", "key": "Privacy", "format": "telemetry: 0 bytes" },
    { "type": "command", "key": "Quip",   "text": "mind quip" },
    "break",
    "colors"
  ]
}
EOF
  install -m 644 "$share/fastfetch.jsonc" "$MNT/etc/skel/.config/fastfetch/config.jsonc"
  install -m 644 "$share/fastfetch.jsonc" "$MNT/root/.config/fastfetch/config.jsonc"
  install -m 644 "$share/fastfetch.jsonc" "$MNT/etc/xdg/fastfetch/config.jsonc"

  # --- login banner (/etc/issue), motd ---
  {
    printf '\e[1;36m'; wordmark; printf '\e[0m'
    printf '\e[1;35m   :: %s -- %s ::\e[0m\n' "$OSNAME" "$TAGLINE"
    printf '\n   Kernel \\r on an \\m (\\l)\n\n'
  } > "$MNT/etc/issue"
  printf '%s\n' "$OSNAME" > "$MNT/etc/issue.net"
  {
    printf '\e[1;36m'; wordmark; printf '\e[0m'
    printf '\e[1;35m   :: %s -- %s ::\e[0m\n\n' "$OSNAME" "$TAGLINE"
    printf '   Try:  mind help   |   mind privacy   |   mind quip\n'
    printf '   Your data lives here. Only here. It likes it that way.\n\n'
  } > "$MNT/etc/motd"

  # --- wallpaper ---
  cat > "$MNT/usr/share/backgrounds/mindwareos/wallpaper.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0b0f1a"/>
      <stop offset="1" stop-color="#1b1033"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <g font-family="monospace" fill="#22d3ee" font-size="40" text-anchor="middle">
    <text x="960" y="470" font-size="120" font-weight="bold" fill="#c084fc">MINDWARE</text>
    <text x="960" y="560" font-size="64" fill="#22d3ee">OS</text>
    <text x="960" y="650" font-size="32" fill="#94a3b8">think. protect. boot.</text>
  </g>
</svg>
EOF

  # --- mind CLI (friendly pacman wrapper + branding commands) ---
  cat > "$MNT/usr/local/bin/mind" <<'EOF'
#!/bin/sh
# mind -- MindwareOS helper: friendly pacman wrapper + branding commands
cmd=${1:-info}
[ $# -gt 0 ] && shift
case "$cmd" in
  install|i)   exec sudo pacman -S --needed "$@" ;;
  remove|rm|r) exec sudo pacman -Rns "$@" ;;
  update|up|u) exec sudo pacman -Syu "$@" ;;
  search|s)    exec pacman -Ss "$@" ;;
  show)        exec pacman -Si "$@" ;;
  clean)       exec sudo paccache -r ;;
  orphans)     pacman -Qdtq || echo "No orphans. Tidy system, tidy mind." ;;
  banner)      cat /usr/share/mindwareos/wordmark.txt ;;
  quip)        exec mindware-quip ;;
  privacy)
    echo "== MindwareOS privacy check =="
    printf 'Firewall (ufw)  : '; systemctl is-active ufw
    printf 'AppArmor        : '; systemctl is-active apparmor
    printf 'Tor service     : '; systemctl is-active tor
    echo   'DNS:'; resolvectl status 2>/dev/null | grep -E 'Current DNS|DNS Servers|Protocols' | head -6
    echo   'Telemetry       : 0 bytes (we checked twice)'
    ;;
  info)
    cat /usr/share/mindwareos/wordmark.txt
    echo
    exec fastfetch ;;
  help|-h|--help|*)
    cat <<HELP
mind -- MindwareOS helper

  mind install <pkg>   install packages      mind update    full system upgrade
  mind remove  <pkg>   remove + deps         mind search    search repos
  mind show    <pkg>   package info          mind clean     trim package cache
  mind orphans         list orphaned pkgs    mind privacy   quick privacy check
  mind info            banner + fastfetch    mind quip      a random quip
HELP
    ;;
esac
EOF
  chmod 755 "$MNT/usr/local/bin/mind"
  ln -sf mind "$MNT/usr/local/bin/mindware"

  cat > "$MNT/usr/local/bin/mindware-quip" <<'EOF'
#!/bin/bash
quips=(
  "I use MindwareOS, btw."
  "There is no cloud. It's just someone else's computer. Here, it's yours."
  "sudo make me a sandwich."
  "Telemetry on this system: 0 bytes. Gossip: also 0."
  "Keep calm and pacman -Syu."
  "Your data called. It said thanks for staying home."
  "rm -rf is not a personality."
  "It works on my machine. Now it's your machine."
  "Have you tried turning your privacy up to eleven?"
  "Think first. Boot second."
)
printf '%s\n' "${quips[RANDOM % ${#quips[@]}]}"
EOF
  chmod 755 "$MNT/usr/local/bin/mindware-quip"

  # --- shell branding (skel for future users + root) ---
  bashrc_block() {
cat <<'EOF'

# ───── MindwareOS ─────
PS1='\[\e[1;35m\]\u\[\e[0m\]@\[\e[1;36m\]\h\[\e[0m\] \[\e[1;34m\]\w\[\e[0m\] \[\e[2m\]λ\[\e[0m\] '
alias ll='ls -lAh --color=auto'
alias please='sudo'
alias update='mind update'
alias mw='mind'
if [[ $- == *i* ]] && command -v fastfetch >/dev/null 2>&1; then
  fastfetch
fi
EOF
  }
  bashrc_block >> "$MNT/etc/skel/.bashrc"
  bashrc_block >> "$MNT/root/.bashrc"

  ok "Branding applied: os-release, issue, motd, fastfetch, prompt, wallpaper, 'mind' CLI."
  joke "Your OS now has a name, a logo, and a personality disorder. Perfect."
}

# ───────────────────────────── phase 10: user accounts ─────────────────────────────
create_users() {
  step "Creating accounts for ${USERNAME}"
  chroot_run useradd -m -G wheel -s /bin/bash -c "$FULLNAME" "$USERNAME"
  printf '%s:%s\n' "$USERNAME" "$USER_PASS" | chroot_run chpasswd

  if (( LOCK_ROOT )); then
    chroot_run passwd -l root
  else
    printf 'root:%s\n' "$ROOT_PASS" | chroot_run chpasswd
  fi

  echo '%wheel ALL=(ALL:ALL) ALL' > "$MNT/etc/sudoers.d/10-wheel"
  printf 'Defaults insults\nDefaults pwfeedback\n' > "$MNT/etc/sudoers.d/20-mindware-fun"
  chmod 440 "$MNT/etc/sudoers.d/10-wheel" "$MNT/etc/sudoers.d/20-mindware-fun"
  chroot_run visudo -c >/dev/null

  ok "User ${USERNAME} created with sudo powers."
  joke "sudo is set to insult you on wrong passwords. Consider it tough love, ${USERNAME^}."
}

# ───────────────────────────── phase 11: bootloader ─────────────────────────────
install_bootloader() {
  step "Bootloader (GRUB, wearing a ${OSNAME} name tag)"

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

  # ASCII splash before the GRUB menu (ESC skips the 1s pause).
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
menuentry "MindwareOS :: Reboot (turn it off and on again)" { reboot }
menuentry "MindwareOS :: Firmware Settings (here be dragons)" { fwsetup }
menuentry "MindwareOS :: Power Off (go touch grass)" { halt }
EOF
  chmod 755 "$MNT/etc/grub.d/41_mindware_extras"

  chroot_run grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=MindwareOS --recheck
  chroot_run grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=MindwareOS --removable --recheck
  chroot_run grub-mkconfig -o /boot/grub/grub.cfg

  ok "Bootloader installed."
  joke "GRUB will greet you with ASCII art. Press ESC if you're in a hurry. We won't take it personally."
}

# ───────────────────────────── phase 12: finish ─────────────────────────────
finish() {
  step "Wrapping up"
  # DNS stub symlink must be created outside arch-chroot (it bind-mounts resolv.conf)
  rm -f "$MNT/etc/resolv.conf"
  ln -s ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"

  cp "$LOGFILE" "$MNT/var/log/mindware-install.log" 2>/dev/null || true
  sync
  umount -R "$MNT"
  if (( ENCRYPT )); then cryptsetup close cryptroot || true; fi

  printf '\n%s' "$GRN"; art_rocket; printf '%s\n' "$RST"
  printf '%s%s is installed, %s! 🚀%s\n' "$GRN" "$OSNAME" "${USERNAME^}" "$RST"
  cat <<EOF

   Next steps:
     1. Remove the install USB.
     2. Reboot and log in as ${USERNAME}.
     3. Run ${CYN}mind help${RST} to see what's new.

   Install log saved to /var/log/mindware-install.log on the new system.
EOF
  joke "$(pick \
    "Houston, we have liftoff. Please keep your telemetry inside the vehicle at all times." \
    "Installation complete. Time to customise things for the next six hours." \
    "Done! You now run an OS that thinks before it boots.")"
  echo
  if ask_yn "Reboot now?" y; then reboot; fi
}

# ───────────────────────────── main ─────────────────────────────
main() {
  : > "$LOGFILE"
  banner
  joke "Welcome to the ${OSNAME} installer. Fasten your seatbelts; the packages are heavy."
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
