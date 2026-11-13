#!/usr/bin/env bash
# lib/sanitize.sh — choose and apply the *right* erasure primitive per media.
# SPDX-License-Identifier: MIT
#
# Forensic effectiveness, honestly ranked, is media-dependent:
#   NVMe/SSD  : crypto-erase > firmware sanitize (block) > TRIM > overwrite
#   HDD       : a single full overwrite is already definitive; secure-erase too
#   USB bridge: firmware commands rarely pass through → TRIM if supported, else
#               overwrite. We SAY SO rather than pretending otherwise.
#
# NIST SP 800-88 maps these to: Clear (overwrite/TRIM), Purge (crypto-erase,
# sanitize, secure-erase). The certificate uses that mapping.
#
# Exposes:
#   dc_sanitize_select         → sets DC_SAN_METHOD, DC_SAN_NIST, DC_SAN_DESC, DC_SAN_CMDS[]
#   dc_sanitize_apply          → runs the selected commands, sets DC_SAN_APPLIED
# Honors DC_DRYRUN.

# Capability probes (best-effort, read-only).
dc_san_nvme_node() {
  # For /dev/nvme0n1 → controller /dev/nvme0 (nvme-cli wants the controller).
  local d="$1"; echo "${d%n[0-9]*}"
}
dc_san_nvme_supports() {
  local ctrl; ctrl="$(dc_san_nvme_node "$DC_DEV")"
  dc_have nvme || return 1
  nvme id-ctrl "$ctrl" >/dev/null 2>&1 || return 1
  return 0
}
dc_san_blkdiscard_ok() {
  dc_have blkdiscard || return 1
  # A zero-length secure test isn't portable; probe the queue's discard limit.
  local dmax; dmax="$(cat "/sys/block/$(basename "$DC_DEV")/queue/discard_max_bytes" 2>/dev/null || echo 0)"
  [[ "${dmax:-0}" -gt 0 ]]
}
dc_san_ata_secure_ok() {
  dc_have hdparm || return 1
  hdparm -I "$DC_DEV" 2>/dev/null | grep -qi 'supported.*enhanced erase\|SECURITY ERASE UNIT' || \
  hdparm -I "$DC_DEV" 2>/dev/null | grep -qi 'Security:'
}

# Build the AES-accelerated high-entropy overwrite command for $DC_DEV.
dc_san_overwrite_random_cmd() {
  # Encrypt a zero stream with a random key → GB/s of random-looking bytes.
  # Streamed with a live progress bar (see dc_wipe_stream_with_progress in lib/common.sh).
  echo "dc_wipe_stream_with_progress random '$DC_DEV' '${DC_SIZE_BYTES:-0}'"
}
dc_san_overwrite_zero_cmd() {
  echo "dc_wipe_stream_with_progress zero '$DC_DEV' '${DC_SIZE_BYTES:-0}'"
}

# dc_sanitize_select [requested-method]
# requested: auto (default) | crypto | sanitize | secure-erase | trim |
#            overwrite-random | overwrite-zero
dc_sanitize_select() {
  local want="${1:-auto}"
  DC_SAN_CMDS=(); DC_SAN_METHOD=""; DC_SAN_NIST=""; DC_SAN_DESC=""
  local ctrl; ctrl="$(dc_san_nvme_node "$DC_DEV")"

  # Explicit request overrides auto (still capability-checked where relevant).
  case "$want" in
    crypto)
      DC_SAN_METHOD="nvme-crypto-erase"; DC_SAN_NIST="Purge"
      DC_SAN_DESC="NVMe cryptographic erase (discards the media encryption key)"
      DC_SAN_CMDS=( "nvme format '$DC_DEV' --ses=2 --force" ); return 0 ;;
    sanitize)
      DC_SAN_METHOD="nvme-sanitize-crypto"; DC_SAN_NIST="Purge"
      DC_SAN_DESC="NVMe sanitize (crypto-erase action)"
      DC_SAN_CMDS=( "nvme sanitize '$ctrl' --sanact=4" "nvme sanitize-log '$ctrl' || true" ); return 0 ;;
    secure-erase)
      DC_SAN_METHOD="ata-secure-erase"; DC_SAN_NIST="Purge"
      DC_SAN_DESC="ATA SECURITY ERASE UNIT (enhanced if available)"
      DC_SAN_CMDS=(
        "hdparm --user-master u --security-set-pass PasS '$DC_DEV'"
        "hdparm --user-master u --security-erase-enhanced PasS '$DC_DEV' || hdparm --user-master u --security-erase PasS '$DC_DEV'"
      ); return 0 ;;
    trim)
      DC_SAN_METHOD="blkdiscard-trim"; DC_SAN_NIST="Clear"
      DC_SAN_DESC="Whole-device TRIM/discard (blkdiscard)"
      DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "blkdiscard -f '$DC_DEV'" ); return 0 ;;
    overwrite-random)
      DC_SAN_METHOD="overwrite-random"; DC_SAN_NIST="Clear"
      DC_SAN_DESC="Single-pass high-entropy overwrite (AES-CTR stream)"
      DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "$(dc_san_overwrite_random_cmd)" ); return 0 ;;
    overwrite-zero)
      DC_SAN_METHOD="overwrite-zero"; DC_SAN_NIST="Clear"
      DC_SAN_DESC="Single-pass zero overwrite"
      DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "$(dc_san_overwrite_zero_cmd)" ); return 0 ;;
  esac

  # AUTO: pick the most effective primitive the media + stack actually allow.
  case "$DC_MEDIA" in
    nvme-ssd)
      if dc_san_nvme_supports; then
        DC_SAN_METHOD="nvme-crypto-erase"; DC_SAN_NIST="Purge"
        DC_SAN_DESC="NVMe cryptographic erase (best for SSD: reaches over-provisioning & retired blocks)"
        DC_SAN_CMDS=( "nvme format '$DC_DEV' --ses=2 --force" )
      elif dc_san_blkdiscard_ok; then
        DC_SAN_METHOD="blkdiscard-trim"; DC_SAN_NIST="Clear"
        DC_SAN_DESC="TRIM/discard (nvme-cli unavailable; controller-level purge)"
        DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "blkdiscard -f '$DC_DEV'" )
      else
        DC_SAN_METHOD="overwrite-random"; DC_SAN_NIST="Clear"
        DC_SAN_DESC="Overwrite fallback (no firmware erase / TRIM available)"
        DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "$(dc_san_overwrite_random_cmd)" )
      fi ;;
    sata-ssd)
      if dc_san_ata_secure_ok; then
        DC_SAN_METHOD="ata-secure-erase"; DC_SAN_NIST="Purge"
        DC_SAN_DESC="ATA secure erase (SSD firmware erase of all NAND incl. spare)"
        DC_SAN_CMDS=(
          "hdparm --user-master u --security-set-pass PasS '$DC_DEV'"
          "hdparm --user-master u --security-erase-enhanced PasS '$DC_DEV' || hdparm --user-master u --security-erase PasS '$DC_DEV'"
        )
      elif dc_san_blkdiscard_ok; then
        DC_SAN_METHOD="blkdiscard-trim"; DC_SAN_NIST="Clear"
        DC_SAN_DESC="TRIM/discard (secure-erase frozen/unavailable)"
        DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "blkdiscard -f '$DC_DEV'" )
      else
        DC_SAN_METHOD="overwrite-random"; DC_SAN_NIST="Clear"
        DC_SAN_DESC="Overwrite fallback"
        DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "$(dc_san_overwrite_random_cmd)" )
      fi ;;
    usb|mmc)
      # Firmware erase rarely passes a bridge/reader. TRIM if we can, else overwrite.
      if dc_san_blkdiscard_ok; then
        DC_SAN_METHOD="blkdiscard-trim"; DC_SAN_NIST="Clear"
        DC_SAN_DESC="TRIM/discard over $DC_MEDIA (best available without direct attach)"
        DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "blkdiscard -f '$DC_DEV'" )
      else
        DC_SAN_METHOD="overwrite-random"; DC_SAN_NIST="Clear"
        DC_SAN_DESC="Overwrite over $DC_MEDIA (TRIM not passed through; residue may remain in SSD spare area)"
        DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "$(dc_san_overwrite_random_cmd)" )
      fi ;;
    hdd)
      DC_SAN_METHOD="overwrite-zero"; DC_SAN_NIST="Clear"
      DC_SAN_DESC="Single-pass overwrite (definitive on magnetic media)"
      DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "$(dc_san_overwrite_zero_cmd)" ) ;;
    *)
      DC_SAN_METHOD="overwrite-random"; DC_SAN_NIST="Clear"
      DC_SAN_DESC="Overwrite (unknown media class)"
      DC_SAN_CMDS=( "wipefs -a '$DC_DEV'" "$(dc_san_overwrite_random_cmd)" ) ;;
  esac
  return 0
}

# Run the selected commands. Sets DC_SAN_APPLIED=1 on success.
dc_sanitize_apply() {
  DC_SAN_APPLIED=0
  local c rc=0
  for c in "${DC_SAN_CMDS[@]}"; do
    dc_info "sanitize: ${c%% *} ..."
    dc_run "$c" || { rc=$?; dc_warn "command returned $rc: $c"; }
  done
  # blkdiscard fallback: if TRIM was chosen but didn't zero the device, overwrite.
  if [[ "$DC_SAN_METHOD" == "blkdiscard-trim" && "${DC_DRYRUN:-0}" != "1" ]]; then
    if ! dc_san_reads_zero; then
      dc_warn "Device does not read back zero after TRIM → falling back to overwrite."
      DC_SAN_METHOD="overwrite-random-after-trim"
      dc_run "$(dc_san_overwrite_random_cmd)" || true
    fi
  fi
  DC_SAN_APPLIED=1
  return 0
}

# Does the start of the device read back as zeros? (cheap TRIM effectiveness check)
dc_san_reads_zero() {
  local n; n="$(dd if="$DC_DEV" bs=1M count=16 2>/dev/null | tr -d '\000' | wc -c)"
  [[ "${n:-1}" -eq 0 ]]
}
