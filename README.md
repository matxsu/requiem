# requiem

**Safe storage decommissioning for Linux: preserve what matters, erase the rest
the right way for the media, and prove it.**

```
identify → PLAN → [ recover → archive → sanitize → verify → certificate ]
```

`requiem` treats *decommissioning a drive* as the whole job, not just the wipe.
It identifies the device by a stable ID, refuses the system disk, optionally
recovers deleted files, archives the live files worth keeping, then applies the
**most effective erase primitive the media actually allows**. After that it
verifies the result and writes a **NIST SP 800-88** certificate.

## Safety model: plan first, apply explicitly

By default `requiem` **only plans**: it shows the device, the erase method and
the exact commands it *would* run, plus what it *would* preserve. It changes
nothing. To execute you must pass `--apply`. `requiem` then re-checks the device
by serial number and asks you to type both the device path and `ERASE`.

```bash
git clone git@github.com:matxsu/requiem.git && cd requiem

sudo ./requiem /dev/sdb                    # PLAN only, destroys nothing
sudo ./requiem /dev/sdb --apply            # archive, then erase, verify, certify
sudo ./requiem /dev/sdb --apply --recover  # also recover deleted files first
./requiem --help
```

If the recover or archive stage fails, `requiem` aborts **before** sanitize, so
nothing is destroyed on error.

## Media-correct erasure

Overwriting is **not** the strongest option on an SSD: the FTL, wear-levelling
and over-provisioning keep copies that no LBA overwrite reaches.
`--method auto` (the default) therefore picks per media:

| Media | auto picks (best → fallback) | NIST 800-88 |
|-------|------------------------------|-------------|
| NVMe SSD (direct) | crypto-erase → TRIM → overwrite | Purge → Clear |
| SATA SSD (direct) | ATA secure-erase → TRIM → overwrite | Purge → Clear |
| HDD | single-pass overwrite | Clear |
| USB-bridged SSD | TRIM → random overwrite | Clear |
| SD / eMMC | TRIM → overwrite | Clear |

Firmware erase commands rarely pass through a USB bridge. For a bridged drive,
`requiem` says so instead of overstating the result, and recommends attaching the
drive directly to get `--method crypto` / `secure-erase`. Overwrites stream
through `dd` with a live progress bar showing percentage, throughput and ETA.

You can force a method with
`--method crypto|sanitize|secure-erase|trim|overwrite-random|overwrite-zero`.

## The certificate

Each applied run writes `requiem-cert-<serial>-<stamp>.{json,txt}`. The
certificate records the device identity, the method **actually** applied, its
NIST category, the verification result and where preserved data went. You can
use it as proof of disposal (GDPR) or hand it to an ITAD provider.

## Requirements

- **Required:** bash ≥ 4, util-linux (`lsblk`, `blockdev`, `wipefs`,
  `blkdiscard`), coreutils `dd`, `openssl`, `udevadm`, root privileges.
- **Firmware erase:** `nvme-cli` (NVMe crypto-erase / sanitize) and `hdparm`
  (ATA secure-erase).
- **Archive (read-only mounts):** `ntfs-3g`, `apfs-fuse` for NTFS / APFS.
  ext, btrfs, xfs, exFAT and HFS+ use the kernel.
- **Recover (optional):** `ddrescue`, `photorec` / `foremost` / `scalpel`,
  `extundelete` / `ext4magic`, `ntfsundelete`, `tsk_recover`.
- **Tests:** `jq`, and for the end-to-end test, `losetup` as root.

Missing optional tools are detected, and the affected stage falls back or is
skipped.

## Tests

```bash
bash tests/run.sh        # pure-logic + fixture tests (no root needed)
sudo bash tests/run.sh   # adds a real loop-device erase + verify, end to end
```

The harness only uses virtual disks (`truncate` + `losetup`) and fixture
trees. It never touches a physical drive.

## Layout

```
requiem              orchestrator (plan → apply)
lib/common.sh        logging, dry-run runner, progress bar, banners
lib/identify.sh      device id, media class, system-disk guard
lib/sanitize.sh      per-media method selection + apply
lib/verify.sh        post-wipe sampling (zero / entropy)
lib/certificate.sh   NIST 800-88 certificate (JSON + TXT)
prewipe-archive.sh   archive stage (categorized copy + sha256 manifest)
prewipe-recover.sh   forensic recovery stage
afdw.sh              the original AFDW wiper (still usable on its own)
tests/run.sh         loop-device + fixture test harness
```

## Documentation

- [`docs/REQUIEM.md`](docs/REQUIEM.md): stages, safety model, method selection,
  roadmap
- [`usage-examples.md`](usage-examples.md): AFDW and archive/recover flags
- [`docs/AFDW.md`](docs/AFDW.md): the original AFDW README
- [`changelog.md`](changelog.md)

## Credits & license

`requiem` builds on **AFDW, the Anti-Forensic Drive Wiper**, by
[Amarilu84](https://github.com/Amarilu84/afdw-secure-drive-wiper) and
contributors. The full upstream history is preserved in this repository.
Released under the [MIT License](LICENSE.md).
