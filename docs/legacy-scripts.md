# Archived script index

The files below are older experiments and prior revisions. They are retained
for traceability, not as runbooks. `cisco_iosxe_image_transfer.sh` is the only current script.

| File | Historical focus |
| --- | --- |
| `push_v3.sh` | Basic transfer with pre-existing image detection. |
| `push_v4.sh` | Adds a temporary `known_hosts` file. |
| `push_v5.sh` | Direct SCP variant that became the basis for `cisco_iosxe_image_transfer.sh`. |
| `push.sh` | Small two-argument transfer helper. |
| `push_success.sh` | Transfer plus bootflash-space and MD5 checks. |
| `push_success_withoutbootcheck.sh` | MD5 checks without a bootflash-space check. |
| `newbash.sh` | Earlier MD5-verification experiment. |

`archive/notes/device-and-code-scratchpad.txt` is the original mixed device
example and command-snippet file. It is archived unchanged because it is not
a valid `devices.txt` input.
