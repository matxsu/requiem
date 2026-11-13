#!/usr/bin/env bash
# prewipe-archive.sh — Pre-wipe inventory & archive phase for AFDW
# SPDX-License-Identifier: MIT
#
# Purpose
# -------
# A data-loss safety gate that runs BEFORE any destructive wipe: it scans a
# target device, reports what kind of user data is on it, and offers to copy
# the worth-keeping files somewhere safe *before* the drive is destroyed.
#
# It is designed to be:
#   • General      — one default profile that is useful on almost any drive.
#   • Precise       — matches real user-data categories, not the whole OS tree.
#   • Reusable      — works standalone (`./prewipe-archive.sh /dev/sdX`) OR
#                     sourced by afdw.sh (functions are prefixed `pwa_`).
#   • Configurable  — everything is driven by AFDW_ARCHIVE_* environment vars.
#
# It NEVER writes to the source device (read-only scan / read-only mount).
#
# Environment variables
# ---------------------
#   AFDW_ARCHIVE            1|0   Master switch for the phase (default 1).
#   AFDW_ARCHIVE_DEST       DIR   Where archives are written
#                                 (default: ${HOME}/old-archive, else /root/old-archive).
#   AFDW_ARCHIVE_PROFILE    NAME  personal|documents|media|dev|all|none
#                                 (default: personal).
#   AFDW_ARCHIVE_INCLUDE    LIST  Extra extensions/globs to add (space or ':' sep).
#                                 e.g. "psd:ai:sketch" or "*.backup".
#   AFDW_ARCHIVE_EXCLUDE    LIST  Globs to skip (space or ':' sep). e.g. "*/Cache/*".
#   AFDW_ARCHIVE_MAX_FILE_MB   N  Skip files larger than N MiB (0 = no limit, default 0).
#   AFDW_ARCHIVE_MAX_TOTAL_GB  N  Stop after archiving N GiB total (0 = no limit, default 0).
#   AFDW_ARCHIVE_MIN_FREE_GB   N  Require at least N GiB free at destination (default 1).
#   AFDW_ARCHIVE_AUTO       1|0   Archive matches without asking (default 0).
#   AFDW_ARCHIVE_DRYRUN     1|0   Report only, copy nothing (default 0).
#   AFDW_ARCHIVE_MANIFEST   1|0   Write a manifest + sha256 sums (default 1).
#   AFDW_ARCHIVE_MOUNT_RO   1|0   Read-only mount of unmounted partitions (default 1).
#   AFDW_ARCHIVE_SCAN_SYSTEM 1|0  Also scan OS trees (/usr,/var,/etc,...) (default 0:
#                                 skip them so only real user data is captured).
#   AFDW_ARCHIVE_ASSUME_YES 1|0   Standalone: answer prompts with yes (default 0).
#
# Exit / return codes (pwa_run)
#   0  phase complete (archived, skipped by user, or nothing to archive) → safe to wipe
#   10 archive was requested/attempted but FAILED → caller should ABORT the wipe
#   20 user explicitly aborted the whole operation at the archive gate
#
# WARNING: the wipe that follows is irreversible. This phase is your last chance
# to keep anything. Review the report before confirming.

# ---- guard: only set shell opts when run standalone (don't fight the caller) --
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
fi

############################################
#            Config resolution             #
############################################
pwa_cfg() {
  PWA_ENABLE="${AFDW_ARCHIVE:-1}"
  PWA_DEST="${AFDW_ARCHIVE_DEST:-${HOME:-/root}/old-archive}"
  PWA_PROFILE="${AFDW_ARCHIVE_PROFILE:-personal}"
  PWA_INCLUDE="${AFDW_ARCHIVE_INCLUDE:-}"
  PWA_EXCLUDE="${AFDW_ARCHIVE_EXCLUDE:-}"
  PWA_MAX_FILE_MB="${AFDW_ARCHIVE_MAX_FILE_MB:-0}"
  PWA_MAX_TOTAL_GB="${AFDW_ARCHIVE_MAX_TOTAL_GB:-0}"
  PWA_MIN_FREE_GB="${AFDW_ARCHIVE_MIN_FREE_GB:-1}"
  PWA_AUTO="${AFDW_ARCHIVE_AUTO:-0}"
  PWA_DRYRUN="${AFDW_ARCHIVE_DRYRUN:-0}"
  PWA_MANIFEST="${AFDW_ARCHIVE_MANIFEST:-1}"
  PWA_MOUNT_RO="${AFDW_ARCHIVE_MOUNT_RO:-1}"
  PWA_SCAN_SYSTEM="${AFDW_ARCHIVE_SCAN_SYSTEM:-0}"
  PWA_ASSUME_YES="${AFDW_ARCHIVE_ASSUME_YES:-0}"

  # Colors: reuse caller's if present, else define locally.
  : "${RED:=}" "${GRN:=}" "${YLW:=}" "${BLU:=}" "${CYN:=}" "${BLD:=}" "${RST:=}"
  if [[ -t 1 && -z "${RST}" ]]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
  fi
}

pwa_info()  { echo -e "${GRN}[archive]${RST} $*"; }
pwa_warn()  { echo -e "${YLW}[archive]${RST} $*" >&2; }
pwa_err()   { echo -e "${RED}[archive]${RST} $*" >&2; }

pwa_human() {
  awk -v b="${1:-0}" 'function h(x){s="BKMGTPE";i=0;while(x>=1024&&i<6){x/=1024;i++}return sprintf("%.2f %s",x,substr(s,i+1,1))}BEGIN{print h(b)}'
}

############################################
#        Category / pattern profiles       #
############################################
# Each profile expands to a set of case-insensitive extensions. The "personal"
# default = documents + media + keychains.
pwa_profile_exts() {
  local docs="pdf doc docx odt rtf tex txt md csv xls xlsx ods ppt pptx odp epub pages numbers key"
  local media="jpg jpeg png gif bmp tiff tif heic webp svg psd ai raw cr2 nef arw dng mp4 mov avi mkv webm m4v mp3 flac wav aac ogg m4a"
  local keys="gpg kdbx kdb key pem ppk p12 pfx ovpn asc wallet seed"
  local dev="sql json yaml yml toml ini conf cfg env sh py js ts go rs c h cpp java rb php"
  case "${1:-personal}" in
    documents) echo "$docs" ;;
    media)     echo "$media" ;;
    dev)       echo "$dev" ;;
    personal)  echo "$docs $media $keys" ;;
    all)       echo "" ;;        # empty = match every regular file
    none)      echo "__none__" ;;
    *)         echo "$docs $media $keys" ;;
  esac
}

############################################
#        Mount handling (read-only)        #
############################################
PWA_TMP_MOUNTS=()   # temp mountpoints we created and must unmount

pwa_cleanup_mounts() {
  local mp
  for mp in "${PWA_TMP_MOUNTS[@]:-}"; do
    [[ -z "$mp" ]] && continue
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
  done
  PWA_TMP_MOUNTS=()
}

# Echo a mountpoint for a given partition node. Reuses an existing mount if any,
# otherwise mounts READ-ONLY (when allowed and root), trying filesystem-specific
# drivers so drives from Windows (NTFS/exFAT), macOS (HFS+/APFS) and Linux
# (ext/btrfs/xfs/f2fs) can all be read. Echoes nothing on failure.
pwa_mountpoint_for() {
  local part="$1" mp fstype
  mp="$(findmnt -nro TARGET "$part" 2>/dev/null | head -n1 || true)"
  if [[ -n "$mp" ]]; then echo "$mp"; return 0; fi
  [[ "$PWA_MOUNT_RO" == "1" && $EUID -eq 0 ]] || return 1

  fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
  mp="$(mktemp -d /tmp/pwa_mnt.XXXXXX)" || return 1

  # 1) Generic auto-detected read-only mount (covers ext*/xfs/btrfs/vfat/exfat/...).
  if mount -o ro "$part" "$mp" 2>/dev/null; then
    PWA_TMP_MOUNTS+=("$mp"); echo "$mp"; return 0
  fi
  # 2) Filesystem-specific fallbacks for cross-platform media.
  case "$fstype" in
    ntfs|ntfs3)  mount -t ntfs3 -o ro "$part" "$mp" 2>/dev/null \
                 || mount -t ntfs-3g -o ro "$part" "$mp" 2>/dev/null \
                 || { command -v ntfs-3g >/dev/null 2>&1 && ntfs-3g -o ro "$part" "$mp" 2>/dev/null; } ;;
    exfat)       mount -t exfat -o ro "$part" "$mp" 2>/dev/null \
                 || { command -v mount.exfat-fuse >/dev/null 2>&1 && mount.exfat-fuse -o ro "$part" "$mp" 2>/dev/null; } ;;
    hfsplus|hfs) mount -t hfsplus -o ro,force "$part" "$mp" 2>/dev/null ;;
    apfs)        command -v apfs-fuse >/dev/null 2>&1 && apfs-fuse -o ro,allow_other "$part" "$mp" 2>/dev/null ;;
    *)           : ;;
  esac
  if findmnt -nro TARGET "$mp" >/dev/null 2>&1 || mountpoint -q "$mp" 2>/dev/null; then
    PWA_TMP_MOUNTS+=("$mp"); echo "$mp"; return 0
  fi
  rmdir "$mp" 2>/dev/null || true
  [[ -n "$fstype" ]] && pwa_warn "No read-only driver succeeded for $part (fstype=$fstype)."
  return 1
}

############################################
#            Scan (read-only)              #
############################################
# Build a `find` expression for the active extension set into PWA_FIND_EXPR[].
pwa_build_find_expr() {
  local exts="$1" e first=1
  PWA_FIND_EXPR=()
  if [[ "$exts" == "__none__" ]]; then PWA_FIND_EXPR=( -false ); return; fi
  if [[ -z "$exts" ]]; then PWA_FIND_EXPR=( -type f ); return; fi   # "all"
  PWA_FIND_EXPR=( -type f '(' )
  for e in $exts; do
    if [[ $first -eq 1 ]]; then first=0; else PWA_FIND_EXPR+=( -o ); fi
    PWA_FIND_EXPR+=( -iname "*.${e}" )
  done
  # Extra user includes (raw -iname globs, or bare extensions → *.ext).
  local inc
  for inc in ${PWA_INCLUDE//:/ }; do
    [[ -z "$inc" ]] && continue
    PWA_FIND_EXPR+=( -o -iname )
    if [[ "$inc" == *'*'* || "$inc" == *'.'* ]]; then PWA_FIND_EXPR+=( "$inc" ); else PWA_FIND_EXPR+=( "*.${inc}" ); fi
  done
  PWA_FIND_EXPR+=( ')' )
}

# Walk one mountpoint; append "size<TAB>path" lines to $2 (a temp file).
# By default, OS trees are pruned (anchored at the mount root) so only genuine
# user data is captured; set AFDW_ARCHIVE_SCAN_SYSTEM=1 to scan everything.
pwa_scan_mount() {
  local root="$1" out="$2" d
  local -a prune=()
  # Always prune pseudo filesystems and lost+found (anchored at mount root).
  for d in proc sys dev run lost+found; do prune+=( -ipath "$root/$d" -o ); done
  # Always prune universal junk/cache dirs at any depth (never worth archiving).
  local g
  for g in '*/.cache' '*/.thumbnails' '*/.local/share/Trash' '*/.Trash-*' \
           '*/node_modules' '*/.git' '*/__pycache__'; do
    prune+=( -path "$g" -o )
  done
  if [[ "$PWA_SCAN_SYSTEM" != "1" ]]; then
    # Typical distro system directories (kept: home root media mnt srv data ...).
    for g in '*/AppData/Local/*' '*/AppData/LocalLow/*' '*/Application Data/*'; do
      prune+=( -iname "$g" -o )
    done
    for d in usr bin sbin lib lib32 lib64 libx32 boot opt etc var snap cdrom \
             Windows 'Program Files' 'Program Files (x86)' ProgramData Office Recovery PerfLogs \
             'System Volume Information' '$RECYCLE.BIN' '$WinREAgent' Config.Msi; do
      prune+=( -ipath "$root/$d" -o )
    done
  fi
  find "$root" -xdev \( "${prune[@]}" -false \) -prune -o \
      "${PWA_FIND_EXPR[@]}" -printf '%s\t%p\n' 2>/dev/null >>"$out" || true
}

############################################
#              Archive (copy)              #
############################################
pwa_copy_file() {
  # $1 src-root  $2 src-file  $3 dest-base
  local root="$1" src="$2" dest="$3" rel target
  rel="${src#$root/}"
  target="$dest/$rel"
  mkdir -p "$(dirname "$target")" 2>/dev/null || return 1
  cp -a --no-preserve=ownership "$src" "$target" 2>/dev/null || cp -p "$src" "$target" 2>/dev/null || return 1
  return 0
}

# Resolve an absolute path to "root<TAB>mountpoint" from the scanned_roots list
# (set by pwa_run; visible here via bash dynamic scope). Longest prefix wins so
# nested mounts (e.g. / and /home) are attributed correctly.
pwa_resolve_mount() {
  local p="$1" entry r m best_m="" best_r=""
  for entry in "${scanned_roots[@]:-}"; do
    [[ -z "$entry" ]] && continue
    r="${entry%%=*}"; m="${entry#*=}"
    if [[ "$p" == "$m"/* || "$p" == "$m" ]]; then
      if [[ ${#m} -gt ${#best_m} ]]; then best_m="$m"; best_r="$r"; fi
    fi
  done
  printf '%s\t%s' "$best_r" "$best_m"
}

############################################
#                Main phase                #
############################################
# pwa_run <device>   e.g. pwa_run /dev/sdb
pwa_run() {
  pwa_cfg
  local device="${1:-}"
  [[ -n "$device" ]] || { pwa_err "pwa_run: no device given"; return 10; }

  if [[ "$PWA_ENABLE" != "1" ]]; then
    pwa_info "Archive phase disabled (AFDW_ARCHIVE=0). Skipping."
    return 0
  fi
  if [[ "$PWA_PROFILE" == "none" ]]; then
    pwa_info "Archive profile is 'none' — inventory only, no copying."
  fi

  pwa_info "Pre-wipe archive phase on ${BLD}${device}${RST} (profile=${PWA_PROFILE}, dest=${PWA_DEST})."

  # Enumerate partitions (fall back to the whole device if it has none).
  local -a parts=()
  local n t
  while read -r n t; do
    [[ "$t" == "part" ]] && parts+=("/dev/$n")
  done < <(lsblk -rno NAME,TYPE "$device" 2>/dev/null | tail -n +2)
  [[ ${#parts[@]} -eq 0 ]] && parts=("$device")

  local exts; exts="$(pwa_profile_exts "$PWA_PROFILE")"
  pwa_build_find_expr "$exts"

  local scanfile; scanfile="$(mktemp /tmp/pwa_scan.XXXXXX)"
  local -a scanned_roots=()
  local part mp
  for part in "${parts[@]}"; do
    mp="$(pwa_mountpoint_for "$part" || true)"
    if [[ -z "$mp" ]]; then
      pwa_warn "Could not access $part (not mounted / mount failed) — skipped."
      continue
    fi
    pwa_info "Scanning $part at $mp ..."
    pwa_scan_mount "$mp" "$scanfile"
    scanned_roots+=("$part=$mp")
  done

  # Summarize.
  local total_files total_bytes
  total_files="$(wc -l <"$scanfile" 2>/dev/null | tr -d ' ')"
  total_bytes="$(awk -F'\t' '{s+=$1} END{print s+0}' "$scanfile")"

  echo
  echo -e "${BLD}${CYN}================ PRE-WIPE INVENTORY ================${RST}"
  if [[ "${total_files:-0}" -eq 0 ]]; then
    pwa_info "No worth-keeping files matched profile '${PWA_PROFILE}'. Nothing to archive."
    echo -e "${BLD}${CYN}===================================================${RST}"
    pwa_cleanup_mounts; rm -f "$scanfile"
    return 0
  fi

  echo -e "Matched ${BLD}${total_files}${RST} files, ${BLD}$(pwa_human "$total_bytes")${RST} total:"
  # Per-bucket breakdown in a single awk pass.
  awk -F'\t' '
    { p=tolower($2);
      if(p ~ /\.(pdf|docx?|odt|rtf|tex|txt|md|csv|xlsx?|ods|pptx?|odp|epub)$/)      b="documents";
      else if(p ~ /\.(jpe?g|png|gif|bmp|tiff?|heic|webp|svg|psd|raw|cr2|nef|arw|dng)$/) b="images";
      else if(p ~ /\.(mp4|mov|avi|mkv|webm|m4v)$/)                                   b="video";
      else if(p ~ /\.(mp3|flac|wav|aac|ogg|m4a)$/)                                   b="audio";
      else if(p ~ /(\.(gpg|kdbx?|key|pem|ppk|p12|pfx|ovpn|asc|seed)$|wallet)/)        b="keys";
      else b="other";
      c[b]++; s[b]+=$1 }
    function h(x,   u,i){u="BKMGTPE";i=0;while(x>=1024&&i<6){x/=1024;i++}return sprintf("%.2f %s",x,substr(u,i+1,1))}
    END{ split("documents images video audio keys other",o," ");
         for(j=1;j<=6;j++){k=o[j]; if(c[k]>0) printf "   %-10s %6d files   %s\n",k,c[k],h(s[k])} }
  ' "$scanfile"
  echo -e "${BLD}${CYN}===================================================${RST}"

  echo -e "${CYN}Largest matched files:${RST}"
  sort -t$'\t' -k1,1 -nr "$scanfile" | head -10 | \
    while IFS=$'\t' read -r sz pth; do printf "   %10s  %s\n" "$(pwa_human "$sz")" "$pth"; done
  echo

  # Inventory-only mode.
  if [[ "$PWA_PROFILE" == "none" || "$PWA_DRYRUN" == "1" ]]; then
    pwa_info "Dry-run / inventory only — not copying anything."
    pwa_cleanup_mounts; rm -f "$scanfile"
    return 0
  fi

  # Decide whether to archive.
  local do_copy=0
  if [[ "$PWA_AUTO" == "1" ]]; then
    do_copy=1
    pwa_info "AUTO mode — archiving matched files without prompting."
  elif [[ "$PWA_ASSUME_YES" == "1" ]]; then
    do_copy=1
  elif [[ -t 0 ]]; then
    echo -e "${YLW}${BLD}This is your LAST chance to keep this data before the wipe destroys it.${RST}"
    echo -ne "Archive these files to ${BLD}${PWA_DEST}${RST} now? [y]es / [n]o-continue-to-wipe / [a]bort-everything: "
    local ans; read -r ans
    case "${ans,,}" in
      y|yes)   do_copy=1 ;;
      a|abort) pwa_warn "Aborted at archive gate by user."; pwa_cleanup_mounts; rm -f "$scanfile"; return 20 ;;
      *)       pwa_info "Skipping archive by user choice — proceeding to wipe."; do_copy=0 ;;
    esac
  else
    pwa_warn "Non-interactive and AFDW_ARCHIVE_AUTO!=1 — not archiving (set AFDW_ARCHIVE_AUTO=1 to force)."
    do_copy=0
  fi

  if [[ $do_copy -eq 0 ]]; then
    pwa_cleanup_mounts; rm -f "$scanfile"; return 0
  fi

  # Destination + free-space check.
  if ! mkdir -p "$PWA_DEST" 2>/dev/null; then
    pwa_err "Cannot create destination '$PWA_DEST'."; pwa_cleanup_mounts; rm -f "$scanfile"; return 10
  fi
  local free_kb free_gb
  free_kb="$(df -Pk "$PWA_DEST" | awk 'NR==2{print $4}')"
  free_gb=$(( free_kb / 1024 / 1024 ))
  if [[ "$PWA_MIN_FREE_GB" -gt 0 && $free_gb -lt "$PWA_MIN_FREE_GB" ]]; then
    pwa_err "Destination has ${free_gb} GiB free, need >= ${PWA_MIN_FREE_GB} GiB."
    pwa_cleanup_mounts; rm -f "$scanfile"; return 10
  fi

  local stamp devbase setdir
  stamp="$(date +%Y%m%d_%H%M%S)"
  devbase="$(basename "$device")"
  setdir="$PWA_DEST/${stamp}_${devbase}"
  mkdir -p "$setdir"
  local manifest="$setdir/MANIFEST.tsv"
  [[ "$PWA_MANIFEST" == "1" ]] && printf 'sha256\tsize\tmtime\tarchived_path\n' >"$manifest"

  local max_file_bytes=$(( PWA_MAX_FILE_MB * 1024 * 1024 ))
  local max_total_bytes=$(( PWA_MAX_TOTAL_GB * 1024 * 1024 * 1024 ))
  local copied=0 skipped=0 failed=0 running_bytes=0

  # Copy straight from the already-built (pruned) inventory in $scanfile — we do
  # NOT re-scan the filesystem. This is faster and, crucially, keeps the copy set
  # identical to what the inventory reported (same prune/junk rules).
  local sz pth root mpoint rm destpart
  while IFS=$'\t' read -r sz pth; do
    [[ -z "$pth" ]] && continue
    if [[ $max_file_bytes -gt 0 && $sz -gt $max_file_bytes ]]; then skipped=$((skipped+1)); continue; fi
    if [[ $max_total_bytes -gt 0 && $(( running_bytes + sz )) -gt $max_total_bytes ]]; then
      pwa_warn "Reached total cap (${PWA_MAX_TOTAL_GB} GiB) — stopping archive."; break
    fi
    local ex skip=0
    for ex in ${PWA_EXCLUDE//:/ }; do [[ -n "$ex" && "$pth" == $ex ]] && { skip=1; break; }; done
    [[ $skip -eq 1 ]] && { skipped=$((skipped+1)); continue; }

    # Map the absolute path back to its source mount (longest prefix wins).
    rm="$(pwa_resolve_mount "$pth")"; root="${rm%%$'\t'*}"; mpoint="${rm#*$'\t'}"
    [[ -z "$mpoint" ]] && { failed=$((failed+1)); pwa_warn "no mount for: $pth"; continue; }
    destpart="$setdir/${root//\//_}"

    if pwa_copy_file "$mpoint" "$pth" "$destpart"; then
      copied=$((copied+1)); running_bytes=$(( running_bytes + sz ))
      if [[ $(( copied % 25 )) -eq 0 || $copied -eq $total_files ]]; then
        local pct=$(( (copied * 100) / (total_files > 0 ? total_files : 1) ))
        local filled=$(( (copied * 28) / (total_files > 0 ? total_files : 1) ))
        local empty=$(( 28 - filled ))
        local bar="$(printf '%0.s█' $(seq 1 $filled 2>/dev/null))$(printf '%0.s░' $(seq 1 $empty 2>/dev/null))"
        printf "\r   ${CYN}[%-28s]${RST} ${BLD}%3d%%${RST} | %d/%d fichiers | %s / %s   " \
          "$bar" "$pct" "$copied" "$total_files" "$(pwa_human "$running_bytes")" "$(pwa_human "$total_bytes")"
      fi
      if [[ "$PWA_MANIFEST" == "1" ]]; then
        local sum mt rel
        sum="$(sha256sum "$pth" 2>/dev/null | awk '{print $1}')"; sum="${sum:-NA}"
        mt="$(date -r "$pth" +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo NA)"
        rel="${pth#$mpoint/}"
        printf '%s\t%s\t%s\t%s\n' "$sum" "$sz" "$mt" "${root//\//_}/$rel" >>"$manifest"
      fi
    else
      failed=$((failed+1)); pwa_warn "copy failed: $pth"
    fi
  done < "$scanfile"

  {
    echo "AFDW pre-wipe archive"
    echo "date      : $(date -Is)"
    echo "source    : $device"
    echo "profile   : $PWA_PROFILE"
    echo "copied    : $copied files, $(pwa_human "$running_bytes")"
    echo "skipped   : $skipped (size/exclude), failed: $failed"
    echo "manifest  : $( [[ "$PWA_MANIFEST" == "1" ]] && echo MANIFEST.tsv || echo none )"
  } >"$setdir/ARCHIVE-SUMMARY.txt"

  echo
  sync
  pwa_cleanup_mounts; rm -f "$scanfile"

  echo
  pwa_info "Archived ${BLD}${copied}${RST} files ($(pwa_human "$running_bytes")) to ${BLU}${setdir}${RST}"
  [[ $skipped -gt 0 ]] && pwa_info "Skipped $skipped (size cap / exclude rules)."
  if [[ $failed -gt 0 ]]; then
    pwa_err "$failed file(s) failed to copy. Review before wiping."
    return 10
  fi
  pwa_info "Archive complete. It is now safe to proceed with the wipe."
  return 0
}

############################################
#            Standalone runner             #
############################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  pwa_cfg
  DEV=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest)      AFDW_ARCHIVE_DEST="$2"; shift 2;;
      --profile)   AFDW_ARCHIVE_PROFILE="$2"; shift 2;;
      --auto)      AFDW_ARCHIVE_AUTO=1; shift;;
      --dry-run)   AFDW_ARCHIVE_DRYRUN=1; shift;;
      -y|--yes)    AFDW_ARCHIVE_ASSUME_YES=1; shift;;
      -h|--help)   sed -n '2,60p' "$0"; exit 0;;
      /dev/*)      DEV="$1"; shift;;
      *)           echo "Unknown arg: $1" >&2; exit 1;;
    esac
  done
  [[ -n "$DEV" ]] || { echo "Usage: sudo $0 [--dest DIR] [--profile NAME] [--auto|--dry-run|-y] /dev/sdX" >&2; exit 1; }
  [[ $EUID -eq 0 ]] || { echo "Run as root (needed to read raw devices / mount read-only)." >&2; exit 1; }
  trap 'pwa_cleanup_mounts' EXIT
  pwa_run "$DEV"
  exit $?
fi
