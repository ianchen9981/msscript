#!/usr/bin/env bash

# Multi-vendor network image transfer helper.
# Supports Cisco IOS-XE, Cisco NX-OS, and Arista EOS.
# This script copies images only. It does not verify MD5, change boot variables,
# install software, reload devices, or delete remote files.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_FILE="${SCRIPT_DIR}/devices.csv"
IMAGE_FILE="${SCRIPT_DIR}/images.csv"
IMAGE_DIR="${SCRIPT_DIR}/images"
RESULTS_DIR="${SCRIPT_DIR}/results"
MAX_JOBS=3

declare -a DEVICE_NAMES=()
declare -a DEVICE_HOSTS=()
declare -a IMAGE_PRIORITIES=()
declare -a IMAGE_OS_TYPES=()
declare -a IMAGE_MODEL_REGEXES=()
declare -a IMAGE_FILES=()
declare -a IMAGE_FILESYSTEMS=()
declare -a IMAGE_RESERVE_MBS=()
declare -A SEEN_DEVICE_NAMES=()

usage()
{
    cat <<'EOF'
Usage: network_image_transfer.sh [options]

Options:
  --devices PATH       Device CSV; default: ./devices.csv
  --images PATH        Image-map CSV; default: ./images.csv
  --image-dir PATH     Directory containing image files; default: ./images
  --jobs NUMBER        Concurrent device jobs; default: 3
  --results-dir PATH   Directory for timestamped results; default: ./results
  --help               Show this help text
EOF
}

trim()
{
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

now_utc()
{
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

expected_filesystem()
{
    case "$1" in
        iosxe|nxos)
            printf 'bootflash:'
            ;;
        eos)
            printf 'flash:'
            ;;
        *)
            return 1
            ;;
    esac
}

detect_os()
{
    local version_output="$1"

    if printf '%s\n' "$version_output" | grep -qiE 'Arista|EOS[[:space:]]+version'; then
        printf 'eos'
    elif printf '%s\n' "$version_output" | grep -qiE 'NX-OS|NXOS'; then
        printf 'nxos'
    elif printf '%s\n' "$version_output" | grep -qiE 'Cisco IOS XE|IOS-XE|IOS XE'; then
        printf 'iosxe'
    else
        return 1
    fi
}

extract_model()
{
    local inventory_output="$1"
    local version_output="$2"
    local model

    model=$(printf '%s\n%s\n' "$inventory_output" "$version_output" | awk '
        /^[[:space:]]*PID:[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]*PID:[[:space:]]*/, "", line)
            sub(/[[:space:],].*$/, "", line)
            if (line != "") { print line; exit }
        }
        /^[[:space:]]*Model[[:space:]]+([Nn]ame|[Nn]umber)[[:space:]]*:/ {
            line=$0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/[[:space:]].*$/, "", line)
            if (line != "") { print line; exit }
        }
        /^[[:space:]]*Model[[:space:]]*:/ {
            line=$0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/[[:space:]].*$/, "", line)
            if (line != "") { print line; exit }
        }
    ')

    [ -n "$model" ] || return 1
    printf '%s' "$model"
}

parse_free_bytes()
{
    local directory_output="$1"
    local free_bytes

    free_bytes=$(printf '%s\n' "$directory_output" | \
        grep -Eio '[0-9][0-9,]*[[:space:]]+bytes[[:space:]]+free' | \
        tail -1 | tr -d ',' | awk '{print $1}')

    [[ "$free_bytes" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$free_bytes"
}

required_space_bytes()
{
    local image_size="$1"
    local reserve_mb="$2"
    printf '%s' "$((image_size + reserve_mb * 1024 * 1024))"
}

has_enough_space()
{
    local free_bytes="$1"
    local required_bytes="$2"
    [ "$free_bytes" -ge "$required_bytes" ]
}

remote_file_exists()
{
    local directory_output="$1"
    local image_file="$2"

    printf '%s\n' "$directory_output" | \
        awk -v image="$image_file" '{ name=$NF; sub(/\r$/, "", name); if (name == image) found=1 } END { exit !found }'
}

select_image()
{
    local os_type="$1"
    local model="$2"
    local index
    local selected_index=""
    local selected_priority=""
    local regex_status

    SELECT_STATUS="NO_MATCH"
    SELECT_IMAGE_FILE=""
    SELECT_REMOTE_FILESYSTEM=""
    SELECT_RESERVE_MB=""

    for index in "${!IMAGE_PRIORITIES[@]}"; do
        [ "${IMAGE_OS_TYPES[$index]}" = "$os_type" ] || continue

        [[ "$model" =~ ${IMAGE_MODEL_REGEXES[$index]} ]]
        regex_status=$?
        if [ "$regex_status" -eq 2 ]; then
            SELECT_STATUS="INVALID_CONFIG"
            return 1
        fi
        [ "$regex_status" -eq 0 ] || continue

        if [ -z "$selected_index" ] || [ "${IMAGE_PRIORITIES[$index]}" -lt "$selected_priority" ]; then
            selected_index="$index"
            selected_priority="${IMAGE_PRIORITIES[$index]}"
        elif [ "${IMAGE_PRIORITIES[$index]}" -eq "$selected_priority" ]; then
            SELECT_STATUS="INVALID_CONFIG"
            return 1
        fi
    done

    [ -n "$selected_index" ] || return 1

    SELECT_STATUS="SELECTED"
    SELECT_IMAGE_FILE="${IMAGE_FILES[$selected_index]}"
    SELECT_REMOTE_FILESYSTEM="${IMAGE_FILESYSTEMS[$selected_index]}"
    SELECT_RESERVE_MB="${IMAGE_RESERVE_MBS[$selected_index]}"
}

csv_escape()
{
    local value="$1"
    value=${value//\"/\"\"}
    printf '"%s"' "$value"
}

write_csv_row()
{
    local output_file="$1"
    shift
    local first=1
    local field

    {
        for field in "$@"; do
            if [ "$first" -eq 0 ]; then
                printf ','
            fi
            csv_escape "$field"
            first=0
        done
        printf '\n'
    } >> "$output_file"
}

write_worker_result()
{
    local result_file="$1"
    shift
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" > "$result_file"
}

validate_options()
{
    if ! [[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: --jobs must be a positive integer." >&2
        return 1
    fi
}

check_requirements()
{
    local command

    for command in sshpass scp ssh timeout awk grep mktemp stat; do
        if ! command -v "$command" >/dev/null 2>&1; then
            echo "ERROR: Required command '$command' is not installed." >&2
            return 1
        fi
    done

    if (( BASH_VERSINFO[0] < 4 || \
        (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        echo "ERROR: Bash 4.3 or later is required for --jobs concurrency." >&2
        return 1
    fi
}

load_devices()
{
    local raw_line device_name host extra
    local line_number=0

    [ -f "$DEVICE_FILE" ] || {
        echo "ERROR: Device CSV not found: $DEVICE_FILE" >&2
        return 1
    }

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line_number=$((line_number + 1))
        raw_line="${raw_line//$'\r'/}"
        raw_line=$(trim "$raw_line")
        [ -z "$raw_line" ] && continue
        [[ "$raw_line" == \#* ]] && continue

        IFS=, read -r device_name host extra <<< "$raw_line"
        device_name=$(trim "$device_name")
        host=$(trim "$host")
        extra=$(trim "$extra")

        if [ "$device_name" = "device_name" ] && [ "$host" = "host" ]; then
            continue
        fi

        if [ -z "$device_name" ] || [ -z "$host" ] || [ -n "$extra" ] || \
            [[ "$device_name" =~ [[:space:]] ]] || \
            ! [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
            echo "ERROR: Invalid device CSV row $line_number." >&2
            return 1
        fi

        if [[ -n "${SEEN_DEVICE_NAMES[$device_name]+x}" ]]; then
            echo "ERROR: Duplicate device_name '$device_name'." >&2
            return 1
        fi

        SEEN_DEVICE_NAMES["$device_name"]=1
        DEVICE_NAMES+=("$device_name")
        DEVICE_HOSTS+=("$host")
    done < "$DEVICE_FILE"

    if [ "${#DEVICE_NAMES[@]}" -eq 0 ]; then
        echo "ERROR: Device CSV has no usable devices." >&2
        return 1
    fi
}

load_images()
{
    local raw_line priority os_type model_regex image_file remote_filesystem reserve_mb extra
    local expected_fs regex_status
    local line_number=0

    [ -f "$IMAGE_FILE" ] || {
        echo "ERROR: Image CSV not found: $IMAGE_FILE" >&2
        return 1
    }
    [ -d "$IMAGE_DIR" ] || {
        echo "ERROR: Image directory not found: $IMAGE_DIR" >&2
        return 1
    }

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line_number=$((line_number + 1))
        raw_line="${raw_line//$'\r'/}"
        raw_line=$(trim "$raw_line")
        [ -z "$raw_line" ] && continue
        [[ "$raw_line" == \#* ]] && continue

        IFS=, read -r priority os_type model_regex image_file remote_filesystem reserve_mb extra <<< "$raw_line"
        priority=$(trim "$priority")
        os_type=$(trim "$os_type")
        model_regex=$(trim "$model_regex")
        image_file=$(trim "$image_file")
        remote_filesystem=$(trim "$remote_filesystem")
        reserve_mb=$(trim "$reserve_mb")
        extra=$(trim "$extra")

        if [ "$priority" = "priority" ] && [ "$os_type" = "os_type" ]; then
            continue
        fi

        if ! [[ "$priority" =~ ^[0-9]+$ ]] || [ -z "$model_regex" ] || \
            [ -z "$image_file" ] || ! [[ "$reserve_mb" =~ ^[0-9]+$ ]] || [ -n "$extra" ]; then
            echo "ERROR: Invalid image CSV row $line_number." >&2
            return 1
        fi

        expected_fs=$(expected_filesystem "$os_type") || {
            echo "ERROR: Unsupported os_type '$os_type' on image CSV row $line_number." >&2
            return 1
        }

        if [ "$remote_filesystem" != "$expected_fs" ]; then
            echo "ERROR: Image CSV row $line_number must use ${expected_fs} for ${os_type}." >&2
            return 1
        fi

        if [[ "$image_file" == */* ]] || [[ "$image_file" =~ [[:space:]] ]]; then
            echo "ERROR: image_file on row $line_number must be a filename without spaces or a path." >&2
            return 1
        fi

        [[ "" =~ $model_regex ]]
        regex_status=$?
        if [ "$regex_status" -eq 2 ]; then
            echo "ERROR: Invalid model_regex on image CSV row $line_number." >&2
            return 1
        fi

        if [ ! -f "${IMAGE_DIR}/${image_file}" ]; then
            echo "ERROR: Image file for row $line_number not found: ${IMAGE_DIR}/${image_file}" >&2
            return 1
        fi

        IMAGE_PRIORITIES+=("$priority")
        IMAGE_OS_TYPES+=("$os_type")
        IMAGE_MODEL_REGEXES+=("$model_regex")
        IMAGE_FILES+=("$image_file")
        IMAGE_FILESYSTEMS+=("$remote_filesystem")
        IMAGE_RESERVE_MBS+=("$reserve_mb")
    done < "$IMAGE_FILE"

    if [ "${#IMAGE_FILES[@]}" -eq 0 ]; then
        echo "ERROR: Image CSV has no usable mappings." >&2
        return 1
    fi
}

run_device()
{
    local device_name="$1"
    local host="$2"
    local result_file="$3"
    local log_file="$4"
    local started_at started_epoch ended_at duration_seconds
    local temporary_known_hosts version_output inventory_output directory_output
    local os_type="" model="" image_file="" remote_filesystem=""
    local local_size="" free_bytes="" required_bytes=""
    local reserve_mb="" scp_result

    started_at=$(now_utc)
    started_epoch=$(date +%s)

    worker_cleanup()
    {
        if [ -n "${temporary_known_hosts:-}" ] && [ -f "$temporary_known_hosts" ]; then
            rm -f "$temporary_known_hosts"
        fi
    }

    emit_result()
    {
        local status="$1"
        local reason="$2"
        ended_at=$(now_utc)
        duration_seconds=$(( $(date +%s) - started_epoch ))
        write_worker_result "$result_file" \
            "$device_name" "$host" "$os_type" "$model" "$image_file" \
            "$remote_filesystem" "$local_size" "$free_bytes" "$required_bytes" \
            "$status" "$reason" "$started_at" "$ended_at" "$duration_seconds"
    }

    # The parent owns the run directory. This worker cleans only its own file.
    trap worker_cleanup EXIT
    trap 'worker_cleanup; exit 130' INT TERM

    exec > "$log_file" 2>&1

    temporary_known_hosts=$(mktemp "${TMPDIR:-/tmp}/network_image_known_hosts_${USER}_XXXXXX")
    if [ -z "$temporary_known_hosts" ] || [ ! -f "$temporary_known_hosts" ]; then
        emit_result "PROBE_FAILED" "Cannot create temporary known_hosts file"
        return
    fi
    chmod 600 "$temporary_known_hosts"

    local ssh_options=(
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile="$temporary_known_hosts"
        -o GlobalKnownHostsFile=/dev/null
        -o PreferredAuthentications=password
        -o PubkeyAuthentication=no
    )

    echo "[$device_name] Checking TCP/22 for $host"
    if ! timeout 5 bash -c "echo >/dev/tcp/$host/22" 2>/dev/null; then
        emit_result "PROBE_FAILED" "TCP/22 unreachable"
        return
    fi

    echo "[$device_name] Detecting operating system"
    version_output=$(sshpass -e ssh "${ssh_options[@]}" "${DEVICE_USERNAME}@${host}" "show version" 2>&1)
    if [ $? -ne 0 ]; then
        emit_result "PROBE_FAILED" "show version failed"
        return
    fi

    os_type=$(detect_os "$version_output") || {
        emit_result "UNSUPPORTED_OS" "Unable to classify show version output"
        return
    }

    inventory_output=$(sshpass -e ssh "${ssh_options[@]}" "${DEVICE_USERNAME}@${host}" "show inventory" 2>&1)
    if [ $? -ne 0 ]; then
        inventory_output=""
    fi

    model=$(extract_model "$inventory_output" "$version_output") || {
        emit_result "PROBE_FAILED" "Unable to determine device model"
        return
    }

    if ! select_image "$os_type" "$model"; then
        if [ "$SELECT_STATUS" = "INVALID_CONFIG" ]; then
            emit_result "INVALID_CONFIG" "Image mappings are ambiguous or invalid"
        else
            emit_result "NO_MATCH" "No image mapping matches ${os_type}/${model}"
        fi
        return
    fi

    image_file="$SELECT_IMAGE_FILE"
    remote_filesystem="$SELECT_REMOTE_FILESYSTEM"
    reserve_mb="$SELECT_RESERVE_MB"
    local_size=$(stat -c%s "${IMAGE_DIR}/${image_file}")
    if ! [[ "$local_size" =~ ^[0-9]+$ ]]; then
        emit_result "INVALID_CONFIG" "Cannot determine local image size"
        return
    fi
    required_bytes=$(required_space_bytes "$local_size" "$reserve_mb")

    echo "[$device_name] Checking ${remote_filesystem} free space"
    directory_output=$(sshpass -e ssh "${ssh_options[@]}" \
        "${DEVICE_USERNAME}@${host}" "dir ${remote_filesystem}" 2>&1)
    if [ $? -ne 0 ]; then
        emit_result "SPACE_CHECK_FAILED" "dir ${remote_filesystem} failed"
        return
    fi

    free_bytes=$(parse_free_bytes "$directory_output") || {
        emit_result "SPACE_CHECK_FAILED" "Cannot parse bytes free from dir output"
        return
    }

    if ! has_enough_space "$free_bytes" "$required_bytes"; then
        emit_result "INSUFFICIENT_SPACE" "Free space is below image size plus reserve"
        return
    fi

    if remote_file_exists "$directory_output" "$image_file"; then
        emit_result "EXISTS" "Same filename already exists; SCP skipped"
        return
    fi

    echo "[$device_name] Copying ${image_file} to ${remote_filesystem}"
    sshpass -e scp "${ssh_options[@]}" "${IMAGE_DIR}/${image_file}" \
        "${DEVICE_USERNAME}@${host}:${remote_filesystem}${image_file}"
    scp_result=$?

    if [ "$scp_result" -ne 0 ]; then
        emit_result "SCP_FAILED" "scp returned ${scp_result}"
        return
    fi

    emit_result "TRANSFERRED" "SCP completed"
}

main()
{
    local argument
    local run_id run_dir result_dir log_dir csv_file summary_file
    local index active_jobs=0 result_file log_file
    local device_name host os_type model image_file remote_filesystem local_size free_bytes required_bytes
    local status reason started_at ended_at duration_seconds
    local failure_count=0
    declare -a RESULT_FILES=()
    declare -A STATUS_COUNTS=()

    while [ "$#" -gt 0 ]; do
        argument="$1"
        case "$argument" in
            --devices|--images|--image-dir|--jobs|--results-dir)
                if [ "$#" -lt 2 ]; then
                    echo "ERROR: $argument requires a value." >&2
                    return 2
                fi
                case "$argument" in
                    --devices) DEVICE_FILE="$2" ;;
                    --images) IMAGE_FILE="$2" ;;
                    --image-dir) IMAGE_DIR="$2" ;;
                    --jobs) MAX_JOBS="$2" ;;
                    --results-dir) RESULTS_DIR="$2" ;;
                esac
                shift 2
                ;;
            --help)
                usage
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $argument" >&2
                usage >&2
                return 2
                ;;
        esac
    done

    validate_options && check_requirements && load_devices && load_images || return 2

    if ! mkdir -p "$RESULTS_DIR"; then
        echo "ERROR: Cannot create results directory: $RESULTS_DIR" >&2
        return 2
    fi

    run_id="run_$(date -u '+%Y%m%dT%H%M%SZ')_$$"
    run_dir="${RESULTS_DIR}/${run_id}"
    result_dir="${run_dir}/worker-results"
    log_dir="${run_dir}/worker-logs"
    if ! mkdir -p "$result_dir" "$log_dir"; then
        echo "ERROR: Cannot create run directory: $run_dir" >&2
        return 2
    fi
    chmod 700 "$run_dir" "$result_dir" "$log_dir"

    if ! read -r -p "Device username: " DEVICE_USERNAME; then
        echo "ERROR: Unable to read device username." >&2
        return 2
    fi
    if [ -z "$DEVICE_USERNAME" ] || [[ "$DEVICE_USERNAME" =~ [[:space:]] ]]; then
        echo "ERROR: Enter a non-empty device username without spaces." >&2
        return 2
    fi

    read -r -s -p "Password for ${DEVICE_USERNAME}: " SSHPASS
    echo
    if [ -z "$SSHPASS" ]; then
        echo "ERROR: Password cannot be empty." >&2
        return 2
    fi
    export SSHPASS
    trap 'unset SSHPASS' EXIT INT TERM

    printf 'device_name,host,os_type,model,image_file,remote_filesystem,local_size_bytes,free_bytes,required_bytes,status,reason,started_at,ended_at,duration_seconds\n' > "${run_dir}/transfers.csv"
    csv_file="${run_dir}/transfers.csv"
    summary_file="${run_dir}/summary.txt"

    echo "Run directory: $run_dir"
    echo "Queued devices: ${#DEVICE_NAMES[@]}; concurrent jobs: $MAX_JOBS"

    for index in "${!DEVICE_NAMES[@]}"; do
        result_file="${result_dir}/${index}.tsv"
        log_file="${log_dir}/${index}.log"
        RESULT_FILES+=("$result_file")

        run_device "${DEVICE_NAMES[$index]}" "${DEVICE_HOSTS[$index]}" "$result_file" "$log_file" &
        active_jobs=$((active_jobs + 1))

        if [ "$active_jobs" -ge "$MAX_JOBS" ]; then
            wait -n
            active_jobs=$((active_jobs - 1))
        fi
    done

    while [ "$active_jobs" -gt 0 ]; do
        wait -n
        active_jobs=$((active_jobs - 1))
    done

    {
        echo "Multi-vendor network image transfer summary"
        echo "Run directory: $run_dir"
        echo
        printf '%-24s %-36s %-18s %-18s %s\n' "DEVICE" "HOST" "STATUS" "MODEL" "REASON"
    } > "$summary_file"

    for index in "${!RESULT_FILES[@]}"; do
        result_file="${RESULT_FILES[$index]}"
        if ! IFS=$'\t' read -r device_name host os_type model image_file remote_filesystem local_size free_bytes required_bytes status reason started_at ended_at duration_seconds < "$result_file"; then
            device_name="${DEVICE_NAMES[$index]}"
            host="${DEVICE_HOSTS[$index]}"
            os_type=""
            model=""
            image_file=""
            remote_filesystem=""
            local_size=""
            free_bytes=""
            required_bytes=""
            status="PROBE_FAILED"
            reason="Worker returned no result"
            started_at=""
            ended_at=""
            duration_seconds=""
        fi

        write_csv_row "$csv_file" "$device_name" "$host" "$os_type" "$model" "$image_file" \
            "$remote_filesystem" "$local_size" "$free_bytes" "$required_bytes" "$status" \
            "$reason" "$started_at" "$ended_at" "$duration_seconds"
        printf '%-24s %-36s %-18s %-18s %s\n' \
            "$device_name" "$host" "$status" "$model" "$reason" >> "$summary_file"
        STATUS_COUNTS["$status"]=$(( ${STATUS_COUNTS["$status"]:-0} + 1 ))

        case "$status" in
            TRANSFERRED|EXISTS)
                ;;
            *)
                failure_count=$((failure_count + 1))
                ;;
        esac
    done

    cat "$summary_file"
    echo
    echo "CSV record: $csv_file"
    echo "Worker logs: $log_dir"

    if [ "$failure_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
