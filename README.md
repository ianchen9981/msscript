# Cisco IOS-XE image SCP helper

This repository is a Linux jump-host helper for copying a Cisco IOS-XE image
to a list of devices over SCP.

## Official script

`cisco_iosxe_image_transfer.sh` is the current, approved script. It is intentionally kept in the
repository root because it resolves its image and device-list paths relative to
itself. At startup it prompts for the image filename, Cisco username, and
password; the image file must be beside `cisco_iosxe_image_transfer.sh`.

## Prepare a run

1. Use a Linux jump host with Bash 4.3 or later, `sshpass`, OpenSSH (`ssh` and
   `scp`), GNU `timeout`, `awk`, and `mktemp` installed.
2. Copy `devices.example.txt` to `devices.txt` and replace the examples with
   the approved target hostnames or IP addresses. Use one host per line;
   blank lines and lines starting with `#` are ignored.
3. Place the approved IOS-XE image beside `cisco_iosxe_image_transfer.sh`.
4. Run `./cisco_iosxe_image_transfer.sh`, then enter the image filename, Cisco username, and
   password when prompted. The script writes a timestamped
   `scp_summary_*.txt` in this directory.

The script starts at most three device jobs at a time (`MAX_PARALLEL=3` in
`cisco_iosxe_image_transfer.sh`). Each job completes its reachability and duplicate-image checks
before it starts SCP. Parallel status lines can interleave; use the final
timestamped summary as the authoritative per-device result.

`devices.txt`, image files, and run summaries are deliberately ignored by Git:
they are environment-specific operational data.

## Operational boundary

The current script tests TCP/22 reachability, skips an exact filename match in
`bootflash:`, and reports the SCP command's result. It does not verify free
space, image checksum, or boot/install state. Treat an SCP success as transfer
evidence only; perform
the approved device-side size/checksum and boot-variable/install checks before
any reload.

## Layout

- `cisco_iosxe_image_transfer.sh` — current production script; do not edit during normal use.
- `devices.example.txt` — safe device-list template.
- `archive/legacy-scripts/` — prior script revisions retained for reference.
- `archive/notes/` — original scratch material, retained unchanged.
- `docs/legacy-scripts.md` — short index of archived files.
