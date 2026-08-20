# Network image transfer helpers

This repository contains Linux jump-host helpers for copying network operating
system images over SCP. The multi-vendor helper supports Cisco IOS-XE, Cisco
NX-OS, and Arista EOS.

## Multi-vendor helper

`network_image_transfer.sh` is the complete multi-vendor workflow. It detects
the operating system and model over SSH, chooses an image from `images.csv`,
checks free space, and then pushes the image from the jump host over SCP.

## Prepare a run

1. Use a Linux jump host with Bash 4.3 or later, `sshpass`, OpenSSH (`ssh` and
   `scp`), GNU `timeout`, `awk`, `grep`, `stat`, and `mktemp` installed.
2. Copy `devices.example.csv` to `devices.csv`. `device_name` is a unique
   label; `host` is an IPv4 address or full hostname. SSH uses port 22.
3. Create `images/`, put the approved images there, and copy
   `images.example.csv` to `images.csv`. Each row is:
   `priority,os_type,model_regex,image_file,remote_filesystem,reserve_mb`.
   The lowest matching priority wins; two matches at the same priority fail.
   CSV fields cannot contain commas or embedded line breaks.
4. Run `./network_image_transfer.sh`. It prompts once for a shared device
   username and password. Use `--help` to view path and concurrency overrides.

The default is three concurrent jobs. Every run creates a timestamped directory
under `results/` with `transfers.csv`, `summary.txt`, and a per-device worker
log. Operational device lists, images, and results are ignored by Git.

## Operational boundary

The helper uses `show version` and `show inventory` to classify devices, then
uses `dir bootflash:` for IOS-XE/NX-OS or `dir flash:` for EOS. It requires the
device-side SCP/SFTP service to be enabled because the jump host pushes the
image directly. It records an existing same-name image as `EXISTS` and skips
SCP. It does not perform MD5 validation, delete files, modify boot variables,
install software, or reload devices. Treat `TRANSFERRED` as transfer evidence
only; perform the approved device-side verification and upgrade process
separately.

## Layout

- `network_image_transfer.sh` — multi-vendor image transfer workflow.
- `devices.example.csv` and `images.example.csv` — safe CSV templates.
- `cisco_iosxe_image_transfer.sh` — existing IOS-XE-only helper.
- `archive/legacy-scripts/` — prior script revisions retained for reference.
- `archive/notes/` — original scratch material, retained unchanged.
- `docs/legacy-scripts.md` — short index of archived files.
