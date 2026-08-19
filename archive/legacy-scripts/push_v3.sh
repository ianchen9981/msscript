#!/bin/bash

# ============================================================
# Cisco IOS-XE Image Transfer Script
#
# Functions:
#   1. Password entered once
#   2. Read devices from devices.txt
#   3. Check SSH TCP/22
#   4. Check whether image already exists in bootflash
#   5. If image already exists -> skip SCP / SUCCESS
#   6. If image does not exist -> SCP image
#   7. Generate SUCCESS / FAILED summary
#   8. Clear password on exit
#
# NOTE:
#   MD5 verification is NOT performed by this script.
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="cat9k_iosxe.17.16.06.SPA.bin"

IMAGE="${SCRIPT_DIR}/${IMAGE_NAME}"

DEVICE_FILE="${SCRIPT_DIR}/devices.txt"

USERNAME="username"

REMOTE_FS="bootflash:"


# ============================================================
# PASSWORD CLEANUP
# ============================================================

cleanup()
{
    unset SSHPASS
}

trap cleanup EXIT INT TERM


# ============================================================
# REQUIREMENTS CHECK
# ============================================================

for CMD in sshpass scp ssh timeout; do
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
    -o UserKnownHostsFile=/dev/null
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

    HOST="${HOST//$'\r'/}"

    HOST="$(echo "$HOST" | xargs)"

    [ -z "$HOST" ] && continue

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

    sshpass -d 3 scp \
        "${SSH_OPTIONS[@]}" \
        "$IMAGE" \
    "${USERNAME}@${HOST}:${IMAGE_NAME}" \
        3<<<"$SSHPASS"

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
