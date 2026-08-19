# Cisco IOS-XE image SCP helper

This repository is a Linux jump-host helper for copying a Cisco IOS-XE image
to a list of devices over SCP.

## Official script

`push_v6.sh` is the current, approved script. It is intentionally kept in the
repository root because it resolves its image and device-list paths relative to
itself. This cleanup does **not** change that file.

Before a maintenance window, review its configuration values for the image
name and Cisco username. The image file must be beside `push_v6.sh`.

## Prepare a run

1. Use a Linux jump host with `bash`, `sshpass`, OpenSSH (`ssh` and `scp`),
   GNU `timeout`, and `awk` installed.
2. Copy `devices.example.txt` to `devices.txt` and replace the examples with
   the approved target hostnames or IP addresses. Use one host per line;
   blank lines and lines starting with `#` are ignored.
3. Place the approved IOS-XE image beside `push_v6.sh`, using exactly the
   filename configured in the script.
4. Run `./push_v6.sh`. It prompts once for the device password and writes a
   timestamped `scp_summary_*.txt` in this directory.

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

- `push_v6.sh` — current production script; do not edit during normal use.
- `devices.example.txt` — safe device-list template.
- `archive/legacy-scripts/` — prior script revisions retained for reference.
- `archive/notes/` — original scratch material, retained unchanged.
- `docs/legacy-scripts.md` — short index of archived files.
