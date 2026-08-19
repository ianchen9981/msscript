#!/bin/bash

# ============================================================
# Cisco IOS-XE Image Transfer Script
#
# Functions:
#   1. Password entered once
#   2. Read devices from devices.txt
#   3. Check SSH TCP/22
#   4. SCP image directly
#   5. Generate SUCCESS / FAILED summary
#   6. Clear password and temporary known_hosts on exit
#
# NOTE:
#   No bootflash free-space check
#   No existing-image check
#   No MD5 verification
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="cat9k_iosxe.17.15.06.SPA.bin"

IMAGE="${SCRIPT_DIR}/${IMAGE_NAME}"

DEVICE_FILE="${SCRIPT_DIR}/devices.txt"

USERNAME="username"

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

for CMD in sshpass scp timeout; do
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
# READ PASSWORD ONCE
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

    echo "[1/2] Checking SSH connectivity..."

    if ! timeout 5 bash -c "echo >/dev/tcp/$HOST/22" 2>/dev/null; then

        echo "FAILED: TCP/22 unreachable."

        FAILED_DEVICES+=("$HOST : SSH unreachable")

        continue
    fi

    echo "OK: TCP/22 reachable."


    # ========================================================
    # STEP 2 - SCP IMAGE
    # ========================================================

    echo
    echo "[2/2] Starting SCP transfer..."
    echo "Please wait. Large IOS-XE images may take several minutes."
    echo "Do NOT enter the password again."
    echo

    START_TIME=$(date +%s)

    sshpass -e -P "Password:" scp \
        "${SSH_OPTIONS[@]}" \
        "$IMAGE" \
        "${USERNAME}@${HOST}:${IMAGE_NAME}"

    SCP_RESULT=$?

    END_TIME=$(date +%s)

    ELAPSED=$((END_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED / 60))
    ELAPSED_SEC=$((ELAPSED % 60))


    if [ $SCP_RESULT -ne 0 ]; then

        echo
        echo "FAILED: SCP failed."
        echo "Elapsed time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"

        FAILED_DEVICES+=("$HOST : SCP failed")

        continue
    fi


    echo
    echo "SUCCESS: SCP completed."
    echo "Elapsed time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"

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
