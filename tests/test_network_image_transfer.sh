#!/usr/bin/env bash

set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_UNDER_TEST="${PROJECT_DIR}/network_image_transfer.sh"
FIXTURE_DIR="${TEST_DIR}/fixtures"

if (( BASH_VERSINFO[0] < 4 || \
    (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "SKIP: network_image_transfer tests require Bash 4.3+ (found ${BASH_VERSION})."
    exit 0
fi

source "$SCRIPT_UNDER_TEST"

TEST_FAILURES=0

fail()
{
    echo "FAIL: $*" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
}

assert_equal()
{
    local expected="$1"
    local actual="$2"
    local label="$3"
    [ "$expected" = "$actual" ] || fail "$label (expected '$expected', got '$actual')"
}

assert_success()
{
    "$@" || fail "Command failed: $*"
}

test_parsers()
{
    assert_equal "iosxe" "$(detect_os "$(<"${FIXTURE_DIR}/iosxe_show_version.txt")")" "IOS-XE detection"
    assert_equal "nxos" "$(detect_os "$(<"${FIXTURE_DIR}/nxos_show_version.txt")")" "NX-OS detection"
    assert_equal "eos" "$(detect_os "$(<"${FIXTURE_DIR}/eos_show_version.txt")")" "EOS detection"
    assert_equal "C9300-48P" "$(extract_model "$(<"${FIXTURE_DIR}/iosxe_inventory.txt")" "")" "IOS-XE model"
    assert_equal "N9K-C93180YC-FX" "$(extract_model "$(<"${FIXTURE_DIR}/nxos_inventory.txt")" "")" "NX-OS model"
    assert_equal "DCS-7280SR-48C6" "$(extract_model "$(<"${FIXTURE_DIR}/eos_inventory.txt")" "")" "EOS model"
    assert_equal "8765432100" "$(parse_free_bytes "$(<"${FIXTURE_DIR}/dir_free.txt")")" "Free-byte parser"
    assert_equal "1048676" "$(required_space_bytes 100 1)" "Required space calculation"
    if ! has_enough_space 1048676 1048676; then
        fail "Exact free-space boundary must pass"
    fi
    if has_enough_space 1048675 1048676; then
        fail "Insufficient free-space boundary must fail"
    fi

    if remote_file_exists $'  1  -rw-  123 ios.bin\r' "ios.bin"; then
        :
    else
        fail "Exact remote image match"
    fi
    if remote_file_exists '  1  -rw-  123 ios.bin.bak' "ios.bin"; then
        fail "Similar remote filename must not match"
    fi
}

test_image_selection()
{
    IMAGE_PRIORITIES=(20 10)
    IMAGE_OS_TYPES=(iosxe iosxe)
    IMAGE_MODEL_REGEXES=('^C9300-' '^C9300-48P$')
    IMAGE_FILES=(generic.bin exact.bin)
    IMAGE_FILESYSTEMS=(bootflash: bootflash:)
    IMAGE_RESERVE_MBS=(500 500)

    assert_success select_image iosxe C9300-48P
    assert_equal "exact.bin" "$SELECT_IMAGE_FILE" "Lower priority image selection"

    if select_image iosxe C9200-24P; then
        fail "No matching image rule must fail"
    fi
    assert_equal "NO_MATCH" "$SELECT_STATUS" "No-match status"

    IMAGE_PRIORITIES=(10 10)
    IMAGE_OS_TYPES=(iosxe iosxe)
    IMAGE_MODEL_REGEXES=('^C9300-' '^C9300-48P$')
    IMAGE_FILES=(generic.bin exact.bin)
    IMAGE_FILESYSTEMS=(bootflash: bootflash:)
    IMAGE_RESERVE_MBS=(500 500)
    if select_image iosxe C9300-48P; then
        fail "Same-priority image mappings must fail"
    fi
    assert_equal "INVALID_CONFIG" "$SELECT_STATUS" "Same-priority conflict status"
}

write_mock_commands()
{
    local bin_dir="$1"

    cat > "${bin_dir}/timeout" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

    cat > "${bin_dir}/sshpass" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-e" ] && shift
exec "$@"
EOF

    cat > "${bin_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
remote=""
for argument in "$@"; do
    case "$argument" in
        *@*) remote="$argument" ;;
    esac
done
host="${remote#*@}"
command="${!#}"
case "$command" in
    "show version")
        case "$host" in
            iosxe.example.net|iosxe-02.example.net|192.0.2.20) cat "${FIXTURE_DIR}/iosxe_show_version.txt" ;;
            nxos.example.net) cat "${FIXTURE_DIR}/nxos_show_version.txt" ;;
            eos.example.net) cat "${FIXTURE_DIR}/eos_show_version.txt" ;;
        esac
        ;;
    "show inventory")
        case "$host" in
            iosxe.example.net|iosxe-02.example.net|192.0.2.20) cat "${FIXTURE_DIR}/iosxe_inventory.txt" ;;
            nxos.example.net) cat "${FIXTURE_DIR}/nxos_inventory.txt" ;;
            eos.example.net) cat "${FIXTURE_DIR}/eos_inventory.txt" ;;
        esac
        ;;
    dir*)
        if [ "$host" = "eos.example.net" ]; then
            printf 'Directory of flash:/\n  1 -rw- 42 eos.swi\n  9000000000 bytes total (8000000000 bytes free)\n'
        else
            printf 'Directory of bootflash:/\n  9000000000 bytes total (8000000000 bytes free)\n'
        fi
        ;;
esac
EOF

    cat > "${bin_dir}/scp" <<'EOF'
#!/usr/bin/env bash
sleep 1
EOF

    chmod 755 "${bin_dir}/timeout" "${bin_dir}/sshpass" "${bin_dir}/ssh" "${bin_dir}/scp"
}

test_simulated_run()
{
    local temporary_dir bin_dir started elapsed run_csv existing_csv

    temporary_dir=$(mktemp -d)
    bin_dir="${temporary_dir}/bin"
    mkdir -p "$bin_dir" "${temporary_dir}/images"
    export FIXTURE_DIR
    write_mock_commands "$bin_dir"

    cat > "${temporary_dir}/devices.csv" <<'EOF'
device_name,host
iosxe-fqdn,iosxe.example.net
iosxe-ip,192.0.2.20
iosxe-fqdn-02,iosxe-02.example.net
nxos,nxos.example.net
eos,eos.example.net
EOF

    cat > "${temporary_dir}/images.csv" <<'EOF'
priority,os_type,model_regex,image_file,remote_filesystem,reserve_mb
10,iosxe,^C9300-,ios.bin,bootflash:,500
10,nxos,^N9K-C93,nx.bin,bootflash:,500
10,eos,^DCS-7280,eos.swi,flash:,500
EOF
    : > "${temporary_dir}/images/ios.bin"
    : > "${temporary_dir}/images/nx.bin"
    : > "${temporary_dir}/images/eos.swi"

    started=$SECONDS
    if ! printf 'admin\npassword\n' | PATH="${bin_dir}:$PATH" "$SCRIPT_UNDER_TEST" \
        --devices "${temporary_dir}/devices.csv" \
        --images "${temporary_dir}/images.csv" \
        --image-dir "${temporary_dir}/images" \
        --results-dir "${temporary_dir}/results" \
        --jobs 3 >/dev/null; then
        fail "Simulated transfer run"
    fi
    elapsed=$((SECONDS - started))
    if [ "$elapsed" -ge 4 ]; then
        fail "Expected three-job concurrency, simulated run took ${elapsed}s"
    fi

    run_csv=$(find "${temporary_dir}/results" -name transfers.csv -print -quit)
    [ -n "$run_csv" ] || fail "Simulated run did not create transfers.csv"
    assert_equal "4" "$(grep -c 'TRANSFERRED' "$run_csv")" "Transferred result count"
    assert_equal "1" "$(grep -c 'EXISTS' "$run_csv")" "Existing-image result count"

    cat > "${temporary_dir}/existing.csv" <<'EOF'
device_name,host
eos,eos.example.net
EOF
    if ! printf 'admin\npassword\n' | PATH="${bin_dir}:$PATH" "$SCRIPT_UNDER_TEST" \
        --devices "${temporary_dir}/existing.csv" \
        --images "${temporary_dir}/images.csv" \
        --image-dir "${temporary_dir}/images" \
        --results-dir "${temporary_dir}/existing-results" >/dev/null; then
        fail "Existing-image run"
    fi
    existing_csv=$(find "${temporary_dir}/existing-results" -name transfers.csv -print -quit)
    assert_equal "1" "$(grep -c 'EXISTS' "$existing_csv")" "Existing-image skip"

    rm -rf "$temporary_dir"
}

test_parsers
test_image_selection
test_simulated_run

if [ "$TEST_FAILURES" -gt 0 ]; then
    exit 1
fi

echo "PASS: network_image_transfer tests"
