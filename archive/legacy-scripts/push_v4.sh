#!/bin/bash

# ============================================================
# Cisco IOS-XE Image Transfer Script
#
# Functions:
#   1. Password entered once
#   2. Read devices from devices.txt
#   3. Check SSH TCP/22
#   4. Use temporary known_hosts file under /tmp
#   5. Check whether image already exists in bootflash
#   6. If image already exists -> skip SCP / SUCCESS
#   7. If image does not exist -> SCP image
#   8. Generate SUCCESS / FAILED summary
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

# IOS-XE image filename
IMAGE_NAME="cat9k_iosxe.17.15.06.SPA.bin"

# Image must be in the same directory as this script
IMAGE="${SCRIPT_DIR}/${IMAGE_NAME}"

# Device list
DEVICE_FILE="${SCRIPT_DIR}/devices.txt"

# Cisco username
USERNAME="username"

# Cisco filesystem
REMOTE_FS="bootflash:"

# Temporary SSH known_hosts file
TEMP_KNOWN_HOSTS="/tmp/cisco_known_hosts_${USER}_$$"


# ============================================================
# CLEANUP
# ============================================================

cleanup()
{
    unset SSHPASS

    if [ -n "$TEMP_KNOWN_HOSTS" ] && [ -f "$TEMP_KNOWN_HOSTS" ]; then
        rm -f "$TEMP_KNOWN_HOSTS"
    fi
}

trap cleanup EXIT INT TERM


# ============================================================
# REQUIREMENTS CHECK
# ============================================================

for CMD in sshpass scp ssh timeout awk; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: Required command '$CMD' is not installed."
        exit 1
    fi
done


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
# CREATE TEMPORARY KNOWN_HOSTS
# ============================================================

if ! touch "$TEMP_KNOWN_HOSTS"; then
    echo "ERROR: Cannot create temporary known_hosts file:"
    echo "$TEMP_KNOWN_HOSTS"
    exit 1
fi

chmod 600 "$TEMP_KNOWN_HOSTS"


# ============================================================
# READ PASSWORD
# ============================================================

read -s -p "Password for $USERNAME: " SSHPASS
echo

export SSHPASS


# ============================================================
# SSH OPTIONS
# ============================================================

SSH_OPTIONS=(
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile="$TEMP_KNOWN_HOSTS"
    -o GlobalKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
)


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
FAILED_DEVICES=()


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


    echo
    echo "============================================================"
    echo "Device: $HOST"
    echo "============================================================"


    # ========================================================
    # STEP 1 - TCP/22 CHECK
    # ========================================================

    echo "[1/3] Checking SSH connectivity..."

    if ! timeout 5 bash -c "echo >/dev/tcp/$HOST/22" 2>/dev/null; then

        echo "FAILED: TCP/22 unreachable."

        FAILED_DEVICES+=("$HOST : SSH unreachable")

        continue
    fi

    echo "OK: TCP/22 reachable."


    # ========================================================
    # STEP 2 - CHECK IF IMAGE ALREADY EXISTS
    # ========================================================

    echo
    echo "[2/3] Checking whether image already exists..."

    FILE_CHECK=$(sshpass -e ssh \
        "${SSH_OPTIONS[@]}" \
        "${USERNAME}@${HOST}" \
        "dir ${REMOTE_FS}" 2>&1)

    SSH_RESULT=$?


    if [ $SSH_RESULT -ne 0 ]; then

        echo "FAILED: Unable to check bootflash."

        FAILED_DEVICES+=("$HOST : SSH command failed")

        continue
    fi


    # Check directory listing.
    # Only consider the image present when the last field
    # exactly matches the image filename.
    if printf '%s\n' "$FILE_CHECK" | \
        awk -v image="$IMAGE_NAME" '$NF == image { found=1 } END { exit !found }'
    then

        echo "Image already exists:"
        echo "${REMOTE_FS}${IMAGE_NAME}"

        echo
        echo "SUCCESS: Image already exists."
        echo "SCP skipped."

        SUCCESS_DEVICES+=("$HOST : Already exists")

        continue
    fi


    echo "Image does not already exist."


    # ========================================================
    # STEP 3 - SCP IMAGE
    # ========================================================

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

        FAILED_DEVICES+=("$HOST : SCP failed")

        continue
    fi


    echo
    echo "SUCCESS: SCP completed."

    SUCCESS_DEVICES+=("$HOST : Transferred")


done < "$DEVICE_FILE"


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
