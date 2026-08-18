#!/bin/bash

# ============================================================
# Cisco IOS-XE Image Transfer + MD5 Verification
#
# Functions:
#   1. Password entered once
#   2. Read devices from devices.txt
#   3. Check SSH TCP/22
#   4. Check whether image already exists
#   5. If existing image MD5 matches -> skip SCP / SUCCESS
#   6. If existing image MD5 mismatches -> FAILED, no overwrite
#   7. SCP image if image does not exist
#   8. Verify MD5 after SCP
#   9. Generate SUCCESS / FAILED summary
#  10. Clear password on exit
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

# Directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# IOS-XE image filename
IMAGE_NAME="cat9k_iosxe.17.16.06.SPA.bin"

# Image must be in the same directory as this script
IMAGE="${SCRIPT_DIR}/${IMAGE_NAME}"

# Device list
DEVICE_FILE="${SCRIPT_DIR}/devices.txt"

# Cisco username
USERNAME="username"

# Cisco filesystem
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

for CMD in sshpass scp ssh md5sum timeout; do
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
    -o StrictHostKeyChecking=accept-new
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
)


# ============================================================
# LOCAL IMAGE MD5
# ============================================================

echo
echo "Calculating local MD5..."

LOCAL_MD5=$(md5sum "$IMAGE" | awk '{print $1}')

if [ -z "$LOCAL_MD5" ]; then
    echo "ERROR: Unable to calculate local MD5."
    exit 1
fi


echo
echo "============================================================"
echo "Image information"
echo "============================================================"
echo "Image path : $IMAGE"
echo "Image name : $IMAGE_NAME"
echo "Local MD5  : $LOCAL_MD5"
echo


# ============================================================
# RESULT ARRAYS
# ============================================================

SUCCESS_DEVICES=()
FAILED_DEVICES=()


# ============================================================
# PROCESS DEVICES
# ============================================================

while IFS= read -r HOST || [ -n "$HOST" ]; do

    # Remove Windows CR
    HOST="${HOST//$'\r'/}"

    # Trim spaces
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

    echo "[1/4] Checking SSH connectivity..."

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
echo "[2/4] Checking whether image already exists..."

FILE_CHECK=$(sshpass -e ssh \
    "${SSH_OPTIONS[@]}" \
    "${USERNAME}@${HOST}" \
    "dir ${REMOTE_FS}${IMAGE_NAME}" 2>&1)


# Cisco may include the filename in an error message when
# the file does not exist, so check for CLI errors first.

if echo "$FILE_CHECK" | grep -qiE '%Error|No such file|not found'; then

    echo "Image does not already exist."

else

    # No Cisco error. Now check whether filename appears
    # in the directory output.

    if echo "$FILE_CHECK" | grep -Fq "$IMAGE_NAME"; then

        echo "Image already exists:"
        echo "${REMOTE_FS}${IMAGE_NAME}"

        echo
        echo "Checking existing image MD5..."

        EXISTING_VERIFY=$(sshpass -e ssh \
            "${SSH_OPTIONS[@]}" \
            "${USERNAME}@${HOST}" \
            "verify /md5 ${REMOTE_FS}${IMAGE_NAME}" 2>&1)

        EXISTING_MD5=$(echo "$EXISTING_VERIFY" \
            | grep -Eio '[a-fA-F0-9]{32}' \
            | tail -1 \
            | tr 'A-F' 'a-f')


        if [ -z "$EXISTING_MD5" ]; then

            echo
            echo "FAILED: Existing image found but MD5 could not be read."

            FAILED_DEVICES+=(
                "$HOST : Existing image, cannot read MD5"
            )

            continue
        fi


        echo
        echo "Local MD5  : $LOCAL_MD5"
        echo "Remote MD5 : $EXISTING_MD5"


        if [ "$LOCAL_MD5" = "$EXISTING_MD5" ]; then

            echo
            echo "SUCCESS: Image already exists and MD5 matches."
            echo "SCP skipped."

            SUCCESS_DEVICES+=(
                "$HOST : Already exists / MD5 match"
            )

            continue

        else

            echo
            echo "FAILED: Existing image MD5 does NOT match."
            echo "For safety, the script will NOT overwrite it."

            FAILED_DEVICES+=(
                "$HOST : Existing image MD5 mismatch"
            )

            continue
        fi

    else

        echo "Image does not already exist."

    fi



    # ========================================================
    # STEP 3 - SCP IMAGE
    # ========================================================

    echo
    echo "[3/4] Copying image..."

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
    echo "OK: SCP completed."


    # ========================================================
    # STEP 4 - VERIFY MD5 AFTER SCP
    # ========================================================

    echo
    echo "[4/4] Verifying transferred image MD5..."

    VERIFY_OUTPUT=$(sshpass -e ssh \
        "${SSH_OPTIONS[@]}" \
        "${USERNAME}@${HOST}" \
        "verify /md5 ${REMOTE_FS}${IMAGE_NAME}" 2>&1)

    VERIFY_RESULT=$?


    echo "$VERIFY_OUTPUT"


    if [ $VERIFY_RESULT -ne 0 ]; then

        echo
        echo "FAILED: MD5 command failed."

        FAILED_DEVICES+=("$HOST : MD5 command failed")
        continue
    fi


    REMOTE_MD5=$(echo "$VERIFY_OUTPUT" \
        | grep -Eio '[a-fA-F0-9]{32}' \
        | tail -1 \
        | tr 'A-F' 'a-f')


    if [ -z "$REMOTE_MD5" ]; then

        echo
        echo "FAILED: Cannot extract remote MD5."

        FAILED_DEVICES+=("$HOST : Cannot read MD5")
        continue
    fi


    echo
    echo "Local MD5  : $LOCAL_MD5"
    echo "Remote MD5 : $REMOTE_MD5"


    if [ "$LOCAL_MD5" = "$REMOTE_MD5" ]; then

        echo
        echo "SUCCESS: Image transferred and MD5 matched."

        SUCCESS_DEVICES+=("$HOST : Transferred / MD5 match")

    else

        echo
        echo "FAILED: MD5 mismatch!"

        FAILED_DEVICES+=("$HOST : MD5 mismatch")

    fi


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
    echo "MD5   : $LOCAL_MD5"
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
