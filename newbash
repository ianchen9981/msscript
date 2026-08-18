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
#   7. Check bootflash free space
#   8. SCP image
#   9. Verify MD5
#  10. Generate SUCCESS / FAILED summary
#  11. Clear password on exit
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

# Keep this much free space AFTER copying
RESERVE_MB=500
RESERVE_BYTES=$((RESERVE_MB * 1024 * 1024))


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

for CMD in sshpass scp ssh md5sum timeout stat; do
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
# LOCAL IMAGE INFORMATION
# ============================================================

echo
echo "Calculating local image information..."

LOCAL_MD5=$(md5sum "$IMAGE" | awk '{print $1}')
IMAGE_SIZE=$(stat -c%s "$IMAGE")

if [ -z "$LOCAL_MD5" ]; then
    echo "ERROR: Unable to calculate local MD5."
    exit 1
fi

if [[ ! "$IMAGE_SIZE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Unable to determine image size."
    exit 1
fi

IMAGE_SIZE_MB=$(( (IMAGE_SIZE + 1024*1024 - 1) / (1024*1024) ))
REQUIRED_BYTES=$((IMAGE_SIZE + RESERVE_BYTES))
REQUIRED_MB=$(( (REQUIRED_BYTES + 1024*1024 - 1) / (1024*1024) ))


echo
echo "============================================================"
echo "Image information"
echo "============================================================"
echo "Image path    : $IMAGE"
echo "Image name    : $IMAGE_NAME"
echo "Image size    : ${IMAGE_SIZE_MB} MB"
echo "Local MD5     : $LOCAL_MD5"
echo "Reserve space : ${RESERVE_MB} MB"
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

    echo "[1/5] Checking SSH connectivity..."

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
    echo "[2/5] Checking whether image already exists..."

    FILE_CHECK=$(sshpass -e ssh \
        "${SSH_OPTIONS[@]}" \
        "${USERNAME}@${HOST}" \
        "dir ${REMOTE_FS}${IMAGE_NAME}" 2>&1)

    FILE_CHECK_RESULT=$?


    # Look for exact image filename in Cisco output
    if [ $FILE_CHECK_RESULT -eq 0 ] && echo "$FILE_CHECK" | grep -Fq "$IMAGE_NAME"; then

        echo "Image already exists:"
        echo "${REMOTE_FS}${IMAGE_NAME}"
        echo
        echo "Checking existing image MD5..."


        EXISTING_VERIFY=$(sshpass -e ssh \
            "${SSH_OPTIONS[@]}" \
            "${USERNAME}@${HOST}" \
            "verify /md5 ${REMOTE_FS}${IMAGE_NAME}" 2>&1)

        EXISTING_VERIFY_RESULT=$?

        echo "$EXISTING_VERIFY"


        if [ $EXISTING_VERIFY_RESULT -ne 0 ]; then
            echo
            echo "FAILED: Existing image found but MD5 verification failed."
            FAILED_DEVICES+=("$HOST : Existing image, MD5 command failed")
            continue
        fi


        EXISTING_MD5=$(echo "$EXISTING_VERIFY" \
            | grep -Eio '[a-fA-F0-9]{32}' \
            | tail -1 \
            | tr 'A-F' 'a-f')


        if [ -z "$EXISTING_MD5" ]; then
            echo
            echo "FAILED: Existing image found but MD5 could not be read."
            FAILED_DEVICES+=("$HOST : Existing image, cannot read MD5")
            continue
        fi


        echo
        echo "Local MD5  : $LOCAL_MD5"
        echo "Remote MD5 : $EXISTING_MD5"


        if [ "$LOCAL_MD5" = "$EXISTING_MD5" ]; then

            echo
            echo "SUCCESS: Image already exists and MD5 matches."
            echo "SCP skipped."

            SUCCESS_DEVICES+=("$HOST : Already exists / MD5 match")
            continue

        else

            echo
            echo "FAILED: Existing image MD5 does NOT match."
            echo "For safety, the script will NOT delete or overwrite it."

            FAILED_DEVICES+=("$HOST : Existing image MD5 mismatch")
            continue

        fi
    fi


    echo "Image does not already exist."


    # ========================================================
    # STEP 3 - BOOTFLASH SPACE CHECK
    # ========================================================

    echo
    echo "[3/5] Checking bootflash free space..."

    DIR_OUTPUT=$(sshpass -e ssh \
        "${SSH_OPTIONS[@]}" \
        "${USERNAME}@${HOST}" \
        "dir ${REMOTE_FS}" 2>&1)

    DIR_RESULT=$?


    if [ $DIR_RESULT -ne 0 ]; then
        echo "FAILED: Unable to execute 'dir ${REMOTE_FS}'."
        FAILED_DEVICES+=("$HOST : Cannot check bootflash")
        continue
    fi


    # Typical Cisco output:
    #
    # 11353194496 bytes total (7089844224 bytes free)
    #
    FREE_BYTES=$(echo "$DIR_OUTPUT" \
        | grep -Eio '[0-9]+ bytes free' \
        | tail -1 \
        | awk '{print $1}')


    if [[ ! "$FREE_BYTES" =~ ^[0-9]+$ ]]; then
        echo "FAILED: Unable to determine bootflash free space."
        echo
        echo "Cisco output:"
        echo "$DIR_OUTPUT"

        FAILED_DEVICES+=("$HOST : Cannot determine free space")
        continue
    fi


    FREE_MB=$((FREE_BYTES / 1024 / 1024))


    echo "Image size     : ${IMAGE_SIZE_MB} MB"
    echo "Free space     : ${FREE_MB} MB"
    echo "Safety reserve : ${RESERVE_MB} MB"
    echo "Required       : ${REQUIRED_MB} MB"


    if [ "$FREE_BYTES" -lt "$REQUIRED_BYTES" ]; then

        echo
        echo "FAILED: Not enough bootflash space."

        FAILED_DEVICES+=(
            "$HOST : Insufficient bootflash (${FREE_MB} MB free)"
        )

        continue
    fi


    echo "OK: Bootflash space is sufficient."


    # ========================================================
    # STEP 4 - SCP IMAGE
    # ========================================================

    echo
    echo "[4/5] Copying image..."

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
    # STEP 5 - VERIFY MD5 AFTER SCP
    # ========================================================

    echo
    echo "[5/5] Verifying transferred image MD5..."

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
