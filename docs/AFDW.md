> **Note:** this is the original README of
> [AFDW](https://github.com/Amarilu84/afdw-secure-drive-wiper), the wiper
> `requiem` is built on. It is kept here for reference; `afdw.sh` still ships in
> this repository. For `requiem` itself, see the [main README](../README.md).

<p align="center">
  <img src="https://github.com/user-attachments/assets/d14505a3-da8f-4af3-a09c-16d775c2bdb1" alt="AFDW Screenshot">
</p>

<p align="center">

  <!-- Latest release badge -->
  <a href="https://github.com/Amarilu84/afdw-secure-drive-wiper/releases">
    <img src="https://img.shields.io/github/v/release/Amarilu84/afdw-secure-drive-wiper?style=for-the-badge&color=blue&logo=github" alt="Latest Release">
  </a>
  &nbsp; <!-- spacer -->

  <!-- License badge -->
  <a href="https://github.com/Amarilu84/afdw-secure-drive-wiper/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/Amarilu84/afdw-secure-drive-wiper?style=for-the-badge&color=green" alt="License">
  </a>
  &nbsp;

  <!-- Shell language badge -->
  <img src="https://img.shields.io/badge/Shell-Bash-blue?style=for-the-badge&logo=gnu-bash" alt="Shell: Bash">

</p>

AFDW — The "Anti-Forensic Drive Wiper"
Securely wipes drives with the intent of shredding data beyond recovery and leaving no trace of wipe signatures
even by extreme methods up to and including national security/government forensic LABs.

AES 256 CTR mode (stream cipher) 32Bit random key 16Bit random IV/Nonce. No "Salted" or PBKDF2 metadata headers are written
because Key / IV are supplied directly. Result is high-entropy bytes from absolute beginning to end of drive for plausible
deniability (pure random-looking fill from uninitialized drive).

If formatting with file system, it mimics factory settings (random Serial / UUID / Label). Leaves no trace of wipe. It also writes the appropriate
"cylinders" (clusters) based on size of disk (< 8 GiB → 16 KiB / 8–32 GiB → 32 KiB / 32–128 GiB → 64 KiB / ≥ 128 GiB → 128 KiB)
as would a legitimate "factory setting".

Attempts to utilize Discard/TRIM if supported by device controller, otherwise does a 1-pass zero fill, then optional file system.

AFDW by default runs in a "guided" mode which has lots of safety's in place with confirmations so you don't accidentally destroy your data.
You can use different flags to modify or change it's behavior.

AFDW also supports an emergency mode which instantly and immediately begins wiping with the fastest, most secure method possible, bypassing
all safety's and confirmations, even melting system drives. IYKYK.

Attempts to utilize Discard/TRIM if supported by device controller, otherwise does a 1-pass zero fill, then optional file system.

If formatting with file system, it mimics factory settings (random Serial / UUID / Label). Leaves no trace of wipe.
It also properly handles zero-wiping pre-partition area, noting whether it is MBR or GPT and safely handling each
without nuking MBR or partition meta-data.

There are `--flags` you can use to customize the wipe based on your needs. You can skip methods, use only certain methods, etc. (read on or use with -h).


# TL;DR (What it does):

1.) Lists disks with `lsblk`, shows size/model. Pick the right drive & double-confirm.

2.) Makes you type the full path again, then type ERASE (case-sensitive) before anything destructive.

3.) Unmounts everything from that device.

4.) Flushes writes (`sync`), unmounts recursively (or lazy) so nothing is mounted.

5.) Fills the *exact* device size with encrypted noise. (This prevents 'no space left' notice at end).

6.) Grab the byte size (`blockdev --getsize64`), stream zeros for exactly that many bytes, pipe through AES-256-CTR with a random key/IV, and write to the device.\
(The older method generated a passphrase and piped it through AES-256-CTR, but left a "Salted__" header in first 8 bits).\
(I felt this defeated the purpose of true 'Ghost Mode' and it could be seen that it was wiped on purpose).\
(The fix was to use exact device size, pipe zero's through encryption, and write directly to disk with dd using random key/IV).\
(Result: surface looks like high-entropy “random” data end-to-end).

7.) Try the controller’s internal wipe (discard/trim).

8.) If `blkdiscard` is supported, issue it. Then spot-check a few random 4 MiB blocks:
(The blocks are randomly chosen from the beginning, middle, and end of drive).\
(If they read as all `0x00` or all `0xFF`, great — considered erased).\
(If not, assume discard didn’t really clear everything → do a single zero pass).\

NOTE: It is true you can just use internal discard/trim to write zero's at firmware level and be OK.
Many people will say that you are wasting time writing high entropy random first, then zero's second. There is truth to this.
However, where a noise-first pass can be useful is when zeros might be treated specially by the device/stack:
Compressing SSDs / data-reduction controllers (mostly internal SATA/NVMe SSDs, not cheap USB/SD) - writing zeros can be elided/compressed;
a random pass forces real writes across the address space. Thin-provisioned LUNs / dedup filesystems / sparse images (VMs, SANs) - zeros may
de-allocate or dedup; random data proves allocation and overwrites.

If the final look you want is “high-entropy/uninitialized” (not factory): stopping after the noise pass yields a surface that looks like
encrypted or never-used data. That’s the only time the noise pass meaningfully changes the forensic “appearance.”

For USB sticks / SD cards with no discard/TRIM support, controllers typically don’t compress zeros. So for your factory-look target, just do:
Preferred: blkdiscard → format → verify (fastest, if supported).
Fallback: zero-only → format → verify (half the time of noise+zero, same final look).

The philosophy here is, why are you using this script? Does the consequence of your data being recovered outweigh your trust in other/faster
erasure methods, or concerns over the lifespan of the drive with the amount of writes? If losing a cheap USB flash drive spares you a visit
from the FBI, then just do the extra methods, no?. At the end of the day, it's you that gets affected, not the others with opinions.\
-END NOTE-


9.) Zero-pass fallback (if needed - in case discard/trim wasn't available).

10.) One clean sweep of zeros across the *exact* byte size (prevents 'no space left' hiccup), syncing at the end.

11.) Partitions + formats for a “factory-fresh” look.\
(Creates one aligned partition table (MBR by default, or GPT if you asked).\
(Makes a single primary partition starting at *1 MiB* (good alignment/“cylinders” realism).\
(Formats exFAT with a capacity-aware cluster size:\
(<8 GiB → 16K, 8–32 GiB → 32K, 32–128 GiB → 64K, ≥128 GiB → 128K).

12.) Randomizes identifiers: generates an 8-char A–Z/0–9 label, and a fresh volume GUID/serial.

13.) Verifies it really looks clean & normal.\
(Checks: MBR signature '0x55AA', erased pre-partition gap, middle & last random MiBs erased, table type (MBR/GPT) matches, label pattern OK),
(exFAT UUID pattern '####-####', partition starts exactly at *1 MiB*, and that a small read inside the filesystem works).

14.) Logs everything.\
(Write a human log and a JSON log (includes per-stage timings) to ./afdw_logs/ )

15.) Optionally powers off/ejects the device.\
(If supported, 'udisksctl power-off' so you can safely yank it.


Net effect: you end with a drive that either (a) looks blank and freshly formatted like it came from the factory,
or (b) (if you choose) ends on high-entropy “random” data — your call via flags.


# Pre-wipe data preservation (recover → archive → wipe)

Destroying data is only safe once you're sure nothing important is still on the
drive. AFDW adds two optional, **read-only** stages that run *before* the wipe:

```
 [1] FORENSIC RECOVERY (opt-in)   [2] ARCHIVE GATE (default on)   [3] WIPE
 undelete deleted files,          inventory live files, show      the same
 image a failing drive,           a categorized report, copy      irreversible
 carve by file signature          the worth-keeping ones out      erase as before
```

* **Archive gate** (`prewipe-archive.sh`, on by default): scans the target,
  prints what's on it (documents / images / video / audio / keys, sizes, biggest
  files), and asks whether to copy the worth-keeping files to a safe place before
  wiping. Writes a `MANIFEST.tsv` (sha256) + summary. Skips OS trees and caches by
  default so it captures *your* data, not the whole filesystem.
* **Forensic recovery** (`prewipe-recover.sh`, opt-in with `--recover`): recovers
  what is important but no longer a live file — deleted files (per-filesystem
  undelete), a full `ddrescue` clone of a failing drive, and signature carving.
  Uses standard FOSS tools when present and tells you what to install otherwise.

Everything is configured with `AFDW_ARCHIVE_*` / `AFDW_RECOVER_*` environment
variables or the `--archive-*` / `--recover*` flags. Drives from Windows
(NTFS/exFAT), macOS (HFS+/APFS) and Linux (ext/btrfs/xfs) are all read when
attached to the Linux host. See `usage-examples.md` for copy-paste recipes and the
script headers for the full list of knobs. If a recovery/archive step fails, AFDW
aborts **before** wiping — nothing is destroyed.

> The wiper itself runs on Linux; to wipe a Mac/Windows internal disk, run AFDW
> from a Linux USB or attach the disk to a Linux box. Native macOS/Windows
> wipers are on the roadmap.

**Going further — `requiem`.** A plan→apply pipeline built on top of these stages
that ties the whole job together: `identify → plan → recover → archive → sanitize
→ verify → certificate`. It identifies the drive by stable ID, refuses the system
disk, picks the **media-correct** erase primitive (NVMe crypto-erase / ATA
secure-erase → TRIM → overwrite), verifies the result and emits a **NIST SP
800-88** certificate. Runs **plan-only by default** (destroys nothing until
`--apply`). See [`REQUIEM.md`](REQUIEM.md).


# How To Run (First Time Setup):

First run (no dependencies yet)

Debian / Ubuntu / Kali:

chmod +x afdw.sh\
sudo bash ./afdw.sh --install-deps --doctor\
sudo bash ./afdw.sh\

This gives permissions, installs dependencies, checks that all functions will work.

Just testing the flow without formatting?\
sudo bash ./afdw.sh --no-format


Other distros (quick hints)

1. Show what’s missing (no disk prompts, no writes):

sudo bash ./afdw.sh --doctor

2. Install the basics with your package manager:

Fedora/RHEL/CentOS:

sudo dnf install -y coreutils util-linux openssl parted exfatprogs

Arch/Manjaro:

sudo pacman -S --needed coreutils util-linux openssl parted exfatprogs

openSUSE:

sudo zypper install -y coreutils util-linux openssl parted exfatprogs

(Optional but nice): blkdiscard udisksctl partx kpartx



# Gotchas

Run as **root** (the script enforces it).\
**WSL/containers** are blocked on purpose (unsafe for raw disks).\
Make sure you run with **bash** i.e. sudo bash ./afdw.sh and **NOT** with /bin/sh i.e. sudo ./afdw.sh\
Use **doctor mode** anytime to check the environment:

sudo bash ./afdw.sh --doctor



# How To Run (After Initial Setup):

Run it in guided mode (most common) and follow the prompts:\
sudo bash ./afdw.sh

Run it in batch mode with explicit confirmation:\
sudo bash ./afdw.sh --device /dev/sdX --non-interactive --erase-confirm ERASE

Fast method for drives without TRIM/DISCARD:\
sudo bash ./afdw.sh --device /dev/sdX --fast

Why you might want each mode:

Factory-fresh look (common)\
Use --fast on media without DISCARD to skip the noise pass (cuts time ~in half), then format + verify.\
sudo bash ./afdw.sh --device /dev/sdX --fast

Randomized final surface (entropy on disk)\
Use --noise-only --no-format to end on high-entropy data and stop there.\
sudo bash ./afdw.sh --device /dev/sdX --noise-only --no-format

One quick zero pass, nothing else\
sudo ./afdw.sh --device /dev/sdX --zero-only --no-format

Skip wipes; just partition + format + verify\
sudo bash ./afdw.sh --device /dev/sdX --skip-wipe



# All Flags:

Targeting & Safety

--device /dev/sdX — pick a device explicitly (required for non-interactive).
--non-interactive --erase-confirm ERASE — batch mode (token is *CASE SENSITIVE*).
--genius — allow operating on the system/root disk (dangerous; default is refuse).

Wipe/Format Behavior

--noise-only — run only the high-entropy fill; skip zero and format.
--zero-only — run only a single zero pass; skip noise and format.
--skip-wipe — skip wipe passes; do partition + exFAT + verify.
--fast — if DISCARD is unsupported, automatically skip the noise pass.
--no-format — don’t create a partition or filesystem.
--gpt — use a GPT table instead of MBR (msdos).
--label RANDOM|CUSTOM — label mode (default RANDOM).
--label-text "NAME1234" — with CUSTOM, sets the exact label (A–Z/0–9, up to 11 chars; upcased).
--strict — if verification fails, exit 2 (otherwise it reports and continues).
--no-poweroff — skip `udisksctl power-off` at the end.
--dry-run — print what would run; don’t touch the device.
--no-color — disable ANSI colors.
-h, --help — show usage.



# Under The Hood (short version):

Noise pass: dd if=/dev/zero | openssl enc -aes-256-ctr → dd of=/dev/…\
Gives a high-entropy surface (looks like encrypted data).

Ghost erase: tries blkdiscard -t (tests support) and blkdiscard (actual discard).\
If unsupported, samples a few random 4 MiB blocks at beginning, middle, and end of drive; if they’re not all zeros/0xFF, it does a single zero pass.

Partition: parted -a optimal mklabel <msdos|gpt> mkpart primary 1MiB 100%\
Names the partition correctly for sdb1 vs mmcblk0p1/nvme0n1p1.

Format: mkfs.exfat with cluster size chosen from capacity and a random/custom label.

Verify: MBR 0x55AA, erased pre-partition gap and sample blocks, partition table type, label pattern,
exFAT UUID pattern (####-####), 1 MiB alignment, sample read in the filesystem.



# What logs you get:

Everything lands in `./afdw_logs/` next to the script:

verify_XXXX.txt — the human-readable PASS/FAIL transcript\
afdw_YYYYMMDD_HHMMSS.json — the machine log (includes timings)

Example JSON:\
json\
{\
"timestamp": "2025-09-12T06:38:03-04:00",\
"device": "/dev/sdb",\
"size_bytes": 61524148224,\
"human_size": "57.30 G",\
"model": "SanDisk",\
"bus": "usb",\
"table_type": "msdos",\
"formatted": 1,\
"label": "B47XJ4ZA",\
"uuid": "E9E3-F808",\
"discard_attempted": 0,\
"verify_passed": 1,\
"strict_mode": 0,\
"fast_mode": 1,\
"skip_wipe": 0,\
"times": { "total": 4290, "noise": 0, "erase": 4289, "format": 1, "verify": 0 },\
"dry_run": 0\
}



# Requirements:

Linux + Bash 4+\
Must run as root: `sudo bash ./afdw.sh`\
Tools you’ll need on PATH:

required: lsblk dd openssl parted blkid uuidgen blockdev grep awk sed tr wc hexdump\
recommended: exfatprogs (for mkfs.exfat), blkdiscard, findmnt, udisksctl, partx, kpartx



# Install on Debian/Ubuntu/Kali:

sudo apt update\
sudo apt install -y coreutils util-linux openssl parted exfatprogs blkid uuid-runtime udisks2



# Performance notes

If your stick doesn’t support DISCARD, --fast will skip the noise pass automatically → roughly half the time.\
USB 3+ matters. lsusb -t should show 5000M (not 480M). Bad hubs/cables drop you to USB 2 speeds.\
Big block sizes help for the zero pass (bs=8M is good; bs=32M can help, but diminishing returns).\
Noise+zero writes the device twice. If the final look you want is “factory blank”, you don’t need both on non-discard media.



# Troubleshooting:

“Not a block device” — check your path (/dev/sdb, not /dev/sdb1).\
/dev/nvme0n1 doesn’t exist — partition names ending in digits use 'p1' (the script handles this: /dev/loop0p1, /dev/nvme0n1p1, etc.)\
blkdiscard skipped — totally normal on many USB/SD sticks. The script will sample and do a zero pass if needed.\
“Final confirmation failed” — it’s case-sensitive `ERASE` on purpose. If you lose your data by accident 1 time you'll understand.\
Slow speeds — check cables, hubs, and lsusb -t. Front-panel or cheap hubs often force USB 2.\
Syntax/Lint — quick check with bash -n afdw.sh; deeper hints with shellcheck afdw.sh



# Exit codes (so you can script around it):

0 — success (even if verification found issues *unless* --strict was set)\
1 — usage or unrecoverable runtime error\
2 — verification failed *and* you passed --strict\



# Contributing:

PRs welcome for additional filesystems, more verification checks, smarter device detection, etc.\
Please include a short log snippet and your command line when reporting issues.\
This is my first script, I'm sure you'll find things.



# License:

MIT License

Copyright (c) 2025 oRioN NetheRstaR (aka Amarilu84)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the “Software”), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
