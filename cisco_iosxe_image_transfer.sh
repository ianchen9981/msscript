#!/bin/bash

# ============================================================
# Cisco IOS-XE Image Transfer Script
#
# Functions:
#   1. Prompt for image filename, username, and password
#   2. Read devices from devices.txt
#   3. Check SSH TCP/22
#   4. Use temporary known_hosts files under /tmp
#   5. Check whether the same image already exists in bootflash
#   6. SCP image when it does not already exist
#   7. Run up to three device jobs concurrently
#   8. Generate SUCCESS / SKIPPED / FAILED summary
#   9. Clear password and temporary known_hosts on exit
#
# NOTE:
#   MD5 verification is NOT performed by this script.
#   Bootflash free-space verification is NOT performed.
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Device list
DEVICE_FILE="${SCRIPT_DIR}/devices.txt"

# Cisco filesystem
REMOTE_FS="bootflash:"

# Maximum number of device jobs to run concurrently
MAX_PARALLEL=3


# ============================================================
# CLEANUP
# ============================================================

cleanup()
{
    unset SSHPASS

    if [ -n "${RESULT_DIR:-}" ] && [ -d "$RESULT_DIR" ]; then
        rm -f "$RESULT_DIR"/* 2>/dev/null
        rmdir "$RESULT_DIR" 2>/dev/null
    fi
}

trap cleanup EXIT INT TERM


# ============================================================
# REQUIREMENTS CHECK
# ============================================================

for CMD in sshpass scp ssh timeout awk mktemp; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: Required command '$CMD' is not installed."
        exit 1
    fi
done

if (( BASH_VERSINFO[0] < 4 || \
    (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "ERROR: Bash 4.3 or later is required for concurrent transfers."
    exit 1
fi

if ! [[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MAX_PARALLEL must be a positive integer."
    exit 1
fi


# ============================================================
# READ RUN INPUTS
# ============================================================

if ! read -r -p "IOS-XE image filename (in ${SCRIPT_DIR}): " IMAGE_NAME; then
    echo "ERROR: Unable to read image filename."
    exit 1
fi

if [ -z "$IMAGE_NAME" ] || [[ "$IMAGE_NAME" == */* ]]; then
    echo "ERROR: Enter a non-empty image filename without a path."
    exit 1
fi

IMAGE="${SCRIPT_DIR}/${IMAGE_NAME}"

if ! read -r -p "Cisco username: " USERNAME; then
    echo "ERROR: Unable to read Cisco username."
    exit 1
fi

if [ -z "$USERNAME" ] || [[ "$USERNAME" =~ [[:space:]] ]]; then
    echo "ERROR: Enter a non-empty Cisco username without spaces."
    exit 1
fi


# ============================================================
# CHECK LOCAL FILES
# ============================================================

if [ ! -f "$IMAGE" ]; then
    echo "ERROR: Image file not found:"
    echo "$IMAGE"
    exit 1
fi

if [ ! -f "$DEVICE_FILE" ]; then
    echo "ERROR: Device file not found:"
    echo "$DEVICE_FILE"
    exit 1
fi


# ============================================================
# CREATE TEMPORARY RESULT DIRECTORY
# ============================================================

RESULT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cisco_scp_results_${USER}_XXXXXX")

if [ -z "$RESULT_DIR" ] || [ ! -d "$RESULT_DIR" ]; then
    echo "ERROR: Cannot create temporary result directory."
    exit 1
fi

chmod 700 "$RESULT_DIR"


# ============================================================
# READ PASSWORD
# ============================================================

read -s -p "Password for $USERNAME: " SSHPASS
echo

export SSHPASS


# ============================================================
# DEVICE JOB
# ============================================================

process_device()
{
    local HOST="$1"
    local RESULT_FILE="$2"
    local TEMP_KNOWN_HOSTS
    local FILE_CHECK
    local FILE_CHECK_RESULT
    local SCP_RESULT

    worker_cleanup()
    {
        if [ -n "$TEMP_KNOWN_HOSTS" ] && [ -f "$TEMP_KNOWN_HOSTS" ]; then
            rm -f "$TEMP_KNOWN_HOSTS"
        fi
    }

    # This background job must not inherit the parent cleanup trap, which
    # owns the shared result directory.
    trap worker_cleanup EXIT
    trap 'worker_cleanup; exit 130' INT TERM

    TEMP_KNOWN_HOSTS=$(mktemp "${TMPDIR:-/tmp}/cisco_known_hosts_${USER}_XXXXXX")

    if [ -z "$TEMP_KNOWN_HOSTS" ] || [ ! -f "$TEMP_KNOWN_HOSTS" ]; then
        printf 'FAILED\t%s : Cannot create temporary known_hosts file\n' "$HOST" > "$RESULT_FILE"
        return
    fi

    chmod 600 "$TEMP_KNOWN_HOSTS"

    local SSH_OPTIONS=(
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile="$TEMP_KNOWN_HOSTS"
        -o GlobalKnownHostsFile=/dev/null
        -o PreferredAuthentications=password
        -o PubkeyAuthentication=no
    )

    echo
    echo "============================================================"
    echo "Device: $HOST"
    echo "============================================================"

    echo "[1/3] Checking SSH connectivity..."

    if ! timeout 5 bash -c "echo >/dev/tcp/$HOST/22" 2>/dev/null; then
        echo "FAILED: TCP/22 unreachable."
        printf 'FAILED\t%s : SSH unreachable\n' "$HOST" > "$RESULT_FILE"
        return
    fi

    echo "OK: TCP/22 reachable."

    echo
    echo "[2/3] Checking whether image already exists..."

    FILE_CHECK=$(sshpass -e ssh \
        "${SSH_OPTIONS[@]}" \
        "${USERNAME}@${HOST}" \
        "dir ${REMOTE_FS}" 2>&1)

    FILE_CHECK_RESULT=$?

    if [ $FILE_CHECK_RESULT -ne 0 ]; then
        echo "FAILED: Unable to check ${REMOTE_FS}."
        printf 'FAILED\t%s : Cannot check %s\n' "$HOST" "$REMOTE_FS" > "$RESULT_FILE"
        return
    fi

    # Cisco directory entries end with the filename. Match that field exactly
    # so an error message or similarly named image is not treated as a match.
    if printf '%s\n' "$FILE_CHECK" | \
        awk -v image="$IMAGE_NAME" '{ name=$NF; sub(/\r$/, "", name); if (name == image) found=1 } END { exit !found }'
    then
        echo "SKIPPED: Image already exists: ${REMOTE_FS}${IMAGE_NAME}"
        printf 'SKIPPED\t%s : Image already exists\n' "$HOST" > "$RESULT_FILE"
        return
    fi

    echo "OK: No matching image found."

    echo
    echo "[3/3] Copying image..."

    sshpass -e scp \
        "${SSH_OPTIONS[@]}" \
        "$IMAGE" \
        "${USERNAME}@${HOST}:${IMAGE_NAME}"

    SCP_RESULT=$?

    if [ $SCP_RESULT -ne 0 ]; then
        echo
        echo "FAILED: SCP failed."
        printf 'FAILED\t%s : SCP failed\n' "$HOST" > "$RESULT_FILE"
        return
    fi

    echo
    echo "SUCCESS: SCP completed."
    printf 'SUCCESS\t%s : Transferred\n' "$HOST" > "$RESULT_FILE"
}


# ============================================================
# IMAGE INFORMATION
# ============================================================

echo
echo "============================================================"
echo "Image information"
echo "============================================================"
echo "Image path : $IMAGE"
echo "Image name : $IMAGE_NAME"
echo


# ============================================================
# RESULT ARRAYS
# ============================================================

SUCCESS_DEVICES=()
SKIPPED_DEVICES=()
FAILED_DEVICES=()
RESULT_FILES=()
ACTIVE_JOBS=0


# ============================================================
# DEVICE LOOP
# ============================================================

while IFS= read -r HOST || [ -n "$HOST" ]; do

    # Remove Windows CR
    HOST="${HOST//$'\r'/}"

    # Trim leading/trailing whitespace
    HOST="$(echo "$HOST" | xargs)"

    # Skip blank lines
    [ -z "$HOST" ] && continue

    # Skip comments
    [[ "$HOST" =~ ^# ]] && continue


    RESULT_FILE="${RESULT_DIR}/${#RESULT_FILES[@]}"
    RESULT_FILES+=("$RESULT_FILE")

    process_device "$HOST" "$RESULT_FILE" &
    ((ACTIVE_JOBS++))

    if [ $ACTIVE_JOBS -ge "$MAX_PARALLEL" ]; then
        wait -n
        ((ACTIVE_JOBS--))
    fi
done < "$DEVICE_FILE"

while [ $ACTIVE_JOBS -gt 0 ]; do
    wait -n
    ((ACTIVE_JOBS--))
done

for RESULT_FILE in "${RESULT_FILES[@]}"; do
    if ! IFS=$'\t' read -r RESULT_TYPE RESULT_MESSAGE < "$RESULT_FILE"; then
        FAILED_DEVICES+=("Unknown device : No result returned")
        continue
    fi

    case "$RESULT_TYPE" in
        SUCCESS)
            SUCCESS_DEVICES+=("$RESULT_MESSAGE")
            ;;
        SKIPPED)
            SKIPPED_DEVICES+=("$RESULT_MESSAGE")
            ;;
        FAILED)
            FAILED_DEVICES+=("$RESULT_MESSAGE")
            ;;
        *)
            FAILED_DEVICES+=("$RESULT_MESSAGE : Unknown result")
            ;;
    esac
done


# ============================================================
# SUMMARY
# ============================================================

SUMMARY_FILE="${SCRIPT_DIR}/scp_summary_$(date +%Y%m%d_%H%M%S).txt"


{
    echo
    echo "============================================================"
    echo "Cisco Image Transfer Summary"
    echo "============================================================"
    echo
    echo "Image : $IMAGE_NAME"
    echo "Date  : $(date)"
    echo

    echo "============================================================"
    echo "SUCCESS (${#SUCCESS_DEVICES[@]})"
    echo "============================================================"

    if [ ${#SUCCESS_DEVICES[@]} -eq 0 ]; then
        echo "None"
    else
        printf '%s\n' "${SUCCESS_DEVICES[@]}"
    fi


    echo
    echo "============================================================"
    echo "SKIPPED (${#SKIPPED_DEVICES[@]})"
    echo "============================================================"

    if [ ${#SKIPPED_DEVICES[@]} -eq 0 ]; then
        echo "None"
    else
        printf '%s\n' "${SKIPPED_DEVICES[@]}"
    fi


    echo
    echo "============================================================"
    echo "FAILED (${#FAILED_DEVICES[@]})"
    echo "============================================================"

    if [ ${#FAILED_DEVICES[@]} -eq 0 ]; then
        echo "None"
    else
        printf '%s\n' "${FAILED_DEVICES[@]}"
    fi


} | tee "$SUMMARY_FILE"


echo
echo "Summary saved to:"
echo "$SUMMARY_FILE"
echo
echo "Finished."
