#!/usr/bin/env bash
# lib/common.sh — shared helpers for requiem (decommission) toolkit
# SPDX-License-Identifier: MIT
# Sourced by requiem and the other lib/*.sh modules. Defines no side effects
# beyond function/variable definitions, so it is safe to source under set -e.

# ---- version -------------------------------------------------------------
REQUIEM_VERSION="1.0.0"

# ---- colors (respect NO_COLOR and non-tty) -------------------------------
dc_init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${DC_NO_COLOR:-0}" != "1" ]]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'
    MAG=$'\e[35m'; CYN=$'\e[36m'; BLD=$'\e[1m'; DIM=$'\e[2m'; RST=$'\e[0m'
  else
    RED=; GRN=; YLW=; BLU=; MAG=; CYN=; BLD=; DIM=; RST=
  fi
}
dc_init_colors

# ---- logging -------------------------------------------------------------
# A run-wide log file can be set by the orchestrator via DC_LOG.
dc_logline() { [[ -n "${DC_LOG:-}" ]] && printf '%s %s\n' "$(date -Is)" "$*" >>"$DC_LOG" 2>/dev/null || true; }
dc_info() { echo -e "${GRN}==>${RST} $*"; dc_logline "INFO  $*"; }
dc_step() { echo -e "\n${BLD}${CYN}### $* ###${RST}"; dc_logline "STEP  $*"; }
dc_warn() { echo -e "${YLW}WARN:${RST} $*" >&2; dc_logline "WARN  $*"; }
dc_err()  { echo -e "${RED}ERROR:${RST} $*" >&2; dc_logline "ERROR $*"; }
dc_die()  { dc_err "$*"; exit 1; }
dc_have() { command -v "$1" >/dev/null 2>&1; }

# ---- dry-run aware command runner ----------------------------------------
# DC_DRYRUN=1 → print the command instead of running it. Returns the command's
# status when run, or 0 when printed.
dc_run() {
  if [[ "${DC_DRYRUN:-0}" == "1" ]]; then
    echo -e "   ${DIM}[plan] $*${RST}"
    return 0
  fi
  dc_logline "RUN   $*"
  eval "$@"
}

# ---- helpers -------------------------------------------------------------
dc_human() {
  awk -v b="${1:-0}" 'function h(x,  u,i){u="BKMGTPE";i=0;while(x>=1024&&i<6){x/=1024;i++}return sprintf("%.2f %s",x,substr(u,i+1,1))}BEGIN{print h(b)}'
}

dc_require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || dc_die "This action needs root (sudo)."; }

# Ask the user to type an exact token to proceed. $1 = prompt, $2 = required token.
dc_confirm_token() {
  local prompt="$1" token="$2" ans
  if [[ "${DC_ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  [[ -t 0 ]] || { dc_err "Confirmation required but no TTY (use --yes to bypass, carefully)."; return 1; }
  echo -ne "$prompt"
  read -r ans
  [[ "$ans" == "$token" ]]
}

# Robustly unmount every partition of a device before a destructive op.
# Handles udisks-managed mounts (/run/media/*) that a plain `umount -R` misses.
dc_unmount_device() {
  local dev="$1" part mp
  sync
  # Unmount each partition node, trying udisks then umount then lazy umount.
  for part in $(lsblk -rno NAME "$dev" 2>/dev/null | tail -n +2); do
    udisksctl unmount -b "/dev/$part" >/dev/null 2>&1 || true
    umount "/dev/$part" 2>/dev/null || umount -l "/dev/$part" 2>/dev/null || true
  done
  # Unmount by mountpoint too (covers bind/oddly-registered mounts).
  while read -r mp; do
    [[ -n "$mp" ]] && { umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true; }
  done < <(lsblk -rno MOUNTPOINT "$dev" 2>/dev/null | awk 'NF')
  umount -l "${dev}" 2>/dev/null || true
  sync
}

# JSON string escaper (minimal).
dc_json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\n'; }


# ---- visual stream wipe with live progress bar ---------------------------
dc_wipe_stream_with_progress() {
  local mode="${1:-random}" dev="$2" total="${3:-0}"
  [[ "$total" -le 0 ]] && total="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
  local bdev; bdev="$(basename "$dev")"

  local bs="16M" bs_bytes=$((16 * 1024 * 1024)) dd_oflag="oflag=direct"
  if [[ "${DC_MEDIA:-}" == "usb" ]]; then
    { echo 1024 > "/sys/block/$bdev/queue/max_sectors_kb"; } 2>/dev/null || true
    bs="4M"; bs_bytes=$((4 * 1024 * 1024))
    dd_oflag="oflag=dsync"
  fi

  echo -e "   ${DIM}Écriture sur ${dev} (${DC_SIZE_H:-$(dc_human "$total")}) — bloc=${bs}, synchronisation directe...${RST}"

  local dd_pid
  if [[ "$mode" == "random" ]]; then
    openssl enc -aes-256-ctr -nosalt -pass pass:"$(head -c32 /dev/urandom | base64)" </dev/zero 2>/dev/null \
      | dd of="$dev" bs="$bs" iflag=fullblock $dd_oflag conv=fsync status=none 2>/dev/null &
    dd_pid=$!
  else
    dd if=/dev/zero of="$dev" bs="$bs" $dd_oflag conv=fsync status=none 2>/dev/null &
    dd_pid=$!
  fi

  local start_ts now_ts elapsed pos pct filled empty bar rate eta_s eta_str
  start_ts="$(date +%s)"
  while kill -0 "$dd_pid" 2>/dev/null; do
    pos="$(awk '/^pos:/{print $2}' "/proc/$dd_pid/fdinfo/1" 2>/dev/null || echo 0)"
    now_ts="$(date +%s)"
    elapsed=$(( now_ts - start_ts ))
    [[ $elapsed -lt 1 ]] && elapsed=1
    if [[ "$total" -gt 0 && "${pos:-0}" -gt 0 ]]; then
      if [[ "$pos" -ge "$total" ]]; then
        printf "\r   ${CYN}[████████████████████████████████]${RST} ${BLD}100.0%%${RST} | %s / %s | Finalisation (fsync)...            " \
          "$(dc_human "$total")" "$(dc_human "$total")"
      else
        pct="$(awk -v p="$pos" -v t="$total" 'BEGIN{v=(p*100)/t; if(v>100)v=100; printf "%.1f", v}')"
        filled="$(awk -v p="$pos" -v t="$total" 'BEGIN{v=int((p*32)/t); if(v>32)v=32; print v}')"
        empty=$(( 32 - filled ))
        bar="$(printf '%0.s█' $(seq 1 "$filled" 2>/dev/null))$(printf '%0.s░' $(seq 1 "$empty" 2>/dev/null))"
        rate=$(( pos / elapsed ))
        if [[ $rate -gt 0 ]]; then
          eta_s=$(( (total - pos) / rate ))
          eta_str="$(printf '%02d:%02d:%02d' $((eta_s/3600)) $(((eta_s%3600)/60)) $((eta_s%60)))"
        else
          eta_str="00:00:00"
        fi
        printf "\r   ${CYN}[%-32s]${RST} ${BLD}%5s%%${RST} | %s / %s | %s/s | ETA %s   " \
          "$bar" "$pct" "$(dc_human "$pos")" "$(dc_human "$total")" "$(dc_human "$rate")" "$eta_str"
      fi
    fi
    sleep 0.5
  done

  wait "$dd_pid" 2>/dev/null || true
  now_ts="$(date +%s)"
  elapsed=$(( now_ts - start_ts ))
  [[ $elapsed -lt 1 ]] && elapsed=1
  rate=$(( total / elapsed ))
  bar="████████████████████████████████"
  printf "\r   ${GRN}[%s]${RST} ${BLD}100.0%%${RST} | %s / %s | %s/s | Terminé en %02dm%02ds          \n" \
    "$bar" "$(dc_human "$total")" "$(dc_human "$total")" "$(dc_human "$rate")" $((elapsed/60)) $((elapsed%60))

  echo -ne "   ${DIM}Synchronisation des caches matériels (sync + udev)...${RST}"
  sync
  udevadm settle --timeout=10 2>/dev/null || true
  echo -e " ${GRN}OK${RST}"
  return 0
}

dc_banner_start() {
  cat <<EOF
${CYN}.·:'''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''':·.
: :   ██████╗ ███████╗ ██████╗ ██╗   ██╗██╗███████╗███╗   ███╗             : :
: :   ██╔══██╗██╔════╝██╔═══██╗██║   ██║██║██╔════╝████╗ ████║             : :
: :   ██████╔╝█████╗  ██║   ██║██║   ██║██║█████╗  ██╔████╔██║             : :
: :   ██╔══██╗██╔══╝  ██║▄▄ ██║██║   ██║██║██╔══╝  ██║╚██╔╝██║             : :
: :   ██║  ██║███████╗╚██████╔╝╚██████╔╝██║███████╗██║ ╚═╝ ██║             : :
: :   ╚═╝  ╚═╝╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝╚══════╝╚═╝     ╚═╝             : :
'·:..... Storage Decommissioning Pipeline ................... v${REQUIEM_VERSION} .....:·'${RST}
EOF
}

dc_banner_done() {
  local status_color="${GRN}" status_label="OPÉRATION TERMINÉE — DISQUE PURGÉ ET CERTIFIÉ"
  if [[ "${DC_VERIFY_OK:-0}" != "1" ]]; then
    status_color="${YLW}"
    status_label="OPÉRATION TERMINÉE (AVEC AVERTISSEMENTS DE VÉRIFICATION)"
  fi

  cat <<EOF

${status_color}${BLD}╔══════════════════════════════════════════════════════════════════════════╗
║  ✔  ${status_label}               ║
╠══════════════════════════════════════════════════════════════════════════╣${RST}
  ${BLD}Périphérique :${RST} ${DC_DEV} (${DC_SIZE_H:-?}, S/N: ${DC_SERIAL:-?})
  ${BLD}Méthode      :${RST} ${DC_SAN_METHOD:-?} (NIST 800-88 : ${DC_SAN_NIST:-?})
  ${BLD}Vérification :${RST} $([[ "${DC_VERIFY_OK:-0}" == "1" ]] && echo "${GRN}PASS${RST} (${DC_VERIFY_NOTES:-})" || echo "${YLW}WARN${RST} (${DC_VERIFY_NOTES:-})")
  ${BLD}Certificat   :${RST} ${DC_CERT_TXT:-<aucun>}
  ${BLD}Journal      :${RST} ${DC_LOG:-<aucun>}
${status_color}${BLD}╚══════════════════════════════════════════════════════════════════════════╝${RST}
EOF
}
