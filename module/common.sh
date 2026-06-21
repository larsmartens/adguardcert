#!/system/bin/sh

MODDIR=${MODDIR:-${0%/*}}

STATE_DIR=${ADGUARDCERT_STATE_DIR:-/data/adb/adguardcert}
CONFIG_FILE=$STATE_DIR/config.sh
STATUS_FILE=$STATE_DIR/status
CACHE_FILE=$STATE_DIR/cache
RUN_CERT_DIR=$STATE_DIR/cacerts

SYSTEM_CERT_DIR=/system/etc/security/cacerts
APEX_CERT_DIR=/apex/com.android.conscrypt/cacerts
MODULE_SYSTEM_CERT_DIR=$MODDIR/system/etc/security/cacerts
MODULE_APEX_CERT_DIR=$MODDIR/apex/com.android.conscrypt/cacerts

PERSONAL_HASHES=${PERSONAL_HASHES:-"0f4ed297 14944648"}
INTERMEDIATE_HASHES=${INTERMEDIATE_HASHES:-"47ec1af8"}
MIN_CERT_COUNT=${MIN_CERT_COUNT:-10}

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

SELECTED_CERT=
SELECTED_HASH=
SELECTED_SIG=
BASE_SIG=

status_write() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    {
        echo "status=$1"
        echo "detail=$2"
        echo "cert=$SELECTED_CERT"
        echo "hash=$SELECTED_HASH"
        echo "sdk=$(getprop ro.build.version.sdk 2>/dev/null)"
        echo "time=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
    } > "$STATUS_FILE"
}

list_has() {
    for item in $1; do
        [ "$item" = "$2" ] && return 0
    done
    return 1
}

cert_hash_from_path() {
    cert_base=${1##*/}
    echo "${cert_base%%.*}"
}

cert_index_from_path() {
    cert_base=${1##*/}
    cert_index=${cert_base##*.}
    case "$cert_index" in
        ""|*[!0-9]*) echo 0 ;;
        *) echo "$cert_index" ;;
    esac
}

cert_is_intermediate() {
    cert_hash=$(cert_hash_from_path "$1")
    list_has "$INTERMEDIATE_HASHES" "$cert_hash" && grep -aq "AdGuard" "$1" 2>/dev/null && return 0
    grep -aq "AdGuard Personal Intermediate" "$1" 2>/dev/null && return 0
    grep -aq "Personal Intermediate" "$1" 2>/dev/null && grep -aq "AdGuard" "$1" 2>/dev/null && return 0
    return 1
}

cert_is_personal() {
    cert_hash=$(cert_hash_from_path "$1")
    cert_is_intermediate "$1" && return 1
    list_has "$PERSONAL_HASHES" "$cert_hash" && grep -aq "AdGuard" "$1" 2>/dev/null && return 0
    grep -aq "AdGuard Personal CA" "$1" 2>/dev/null && return 0
    return 1
}

count_files() {
    count=0
    for file in "$1"/*; do
        [ -f "$file" ] || continue
        count=$((count + 1))
    done
    echo "$count"
}

dir_signature() {
    if [ -d "$1" ]; then
        ls -ln "$1" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
    fi
}

find_adguard_cert() {
    SELECTED_CERT=
    SELECTED_HASH=
    best_mtime=-1
    best_index=-1

    for cert in /data/misc/user/*/cacerts-added/*; do
        [ -f "$cert" ] || continue
        cert_is_personal "$cert" || continue

        cert_mtime=$(stat -c '%Y' "$cert" 2>/dev/null)
        case "$cert_mtime" in
            ""|*[!0-9]*) cert_mtime=0 ;;
        esac
        cert_index=$(cert_index_from_path "$cert")

        if [ "$cert_mtime" -gt "$best_mtime" ] || {
            [ "$cert_mtime" -eq "$best_mtime" ] && [ "$cert_index" -gt "$best_index" ]
        }; then
            SELECTED_CERT=$cert
            SELECTED_HASH=$(cert_hash_from_path "$cert")
            best_mtime=$cert_mtime
            best_index=$cert_index
        fi
    done

    [ -n "$SELECTED_CERT" ]
}

copy_cert_files() {
    src_dir=$1
    dst_dir=$2

    for cert in "$src_dir"/*; do
        [ -f "$cert" ] || continue
        cp -f "$cert" "$dst_dir/" || return 1
    done
    return 0
}

reset_dir() {
    rm -rf "$1" 2>/dev/null
    mkdir -p "$1"
}

apply_cert_permissions() {
    ref_dir=$1
    dst_dir=$2

    dir_owner=$(ls -ldn "$ref_dir" 2>/dev/null | awk 'NR==1 {print $3 ":" $4}')
    file_owner=$(ls -ln "$ref_dir"/* 2>/dev/null | awk 'NR==1 {print $3 ":" $4}')
    selinux_context=$(ls -Zd "$ref_dir" 2>/dev/null | awk 'NR==1 {print $1}')

    [ -n "$dir_owner" ] || dir_owner=0:0
    [ -n "$file_owner" ] || file_owner=$dir_owner
    [ -n "$selinux_context" ] && [ "$selinux_context" != "?" ] || selinux_context=u:object_r:system_security_cacerts_file:s0

    chown "$dir_owner" "$dst_dir" 2>/dev/null
    chmod 0755 "$dst_dir" 2>/dev/null

    for cert in "$dst_dir"/*; do
        [ -f "$cert" ] || continue
        chown "$file_owner" "$cert" 2>/dev/null
        chmod 0644 "$cert" 2>/dev/null
    done

    if [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        chcon -R "$selinux_context" "$dst_dir" 2>/dev/null || true
    fi
}

prune_adguard_certs() {
    dst_dir=$1

    for cert in "$dst_dir"/*; do
        [ -f "$cert" ] || continue
        if cert_is_personal "$cert" || cert_is_intermediate "$cert"; then
            rm -f "$cert"
        fi
    done

    for hash in $PERSONAL_HASHES $INTERMEDIATE_HASHES "$SELECTED_HASH"; do
        [ -n "$hash" ] || continue
        rm -f "$dst_dir"/"$hash".* 2>/dev/null
    done
}

build_cert_dir() {
    src_dir=$1
    dst_dir=$2

    [ -d "$src_dir" ] || return 1
    [ "$(count_files "$src_dir")" -gt "$MIN_CERT_COUNT" ] || return 1

    reset_dir "$dst_dir" || return 1
    copy_cert_files "$src_dir" "$dst_dir" || return 1
    prune_adguard_certs "$dst_dir"
    cp -f "$SELECTED_CERT" "$dst_dir/$SELECTED_HASH.0" || return 1
    apply_cert_permissions "$src_dir" "$dst_dir"
    return 0
}

mirrors_ready() {
    [ -f "$MODULE_SYSTEM_CERT_DIR/$SELECTED_HASH.0" ] || return 1
    [ -f "$RUN_CERT_DIR/$SELECTED_HASH.0" ] || return 1
    if [ -d "$APEX_CERT_DIR" ]; then
        [ -f "$MODULE_APEX_CERT_DIR/$SELECTED_HASH.0" ] || return 1
    fi
    return 0
}

prepare_trust_store() {
    mkdir -p "$STATE_DIR" 2>/dev/null

    if ! find_adguard_cert; then
        status_write "missing" "adguard-personal-ca-not-found"
        return 1
    fi

    SELECTED_SIG=$(sha256sum "$SELECTED_CERT" 2>/dev/null | awk '{print $1}')
    [ -n "$SELECTED_SIG" ] || SELECTED_SIG=unknown

    if [ -d "$APEX_CERT_DIR" ] && [ "$(count_files "$APEX_CERT_DIR")" -gt "$MIN_CERT_COUNT" ]; then
        primary_source=$APEX_CERT_DIR
    else
        primary_source=$SYSTEM_CERT_DIR
    fi

    BASE_SIG=$(dir_signature "$primary_source")
    cache_sig="$SELECTED_HASH:$SELECTED_SIG:$primary_source:$BASE_SIG"

    if [ -f "$CACHE_FILE" ] && [ "$(cat "$CACHE_FILE" 2>/dev/null)" = "$cache_sig" ] && mirrors_ready; then
        status_write "ready" "cached"
        return 0
    fi

    system_source=$SYSTEM_CERT_DIR
    [ -d "$system_source" ] && [ "$(count_files "$system_source")" -gt "$MIN_CERT_COUNT" ] || system_source=$primary_source

    build_cert_dir "$system_source" "$MODULE_SYSTEM_CERT_DIR" || {
        status_write "failed" "system-store-stage-failed"
        return 1
    }

    if [ -d "$APEX_CERT_DIR" ]; then
        build_cert_dir "$APEX_CERT_DIR" "$MODULE_APEX_CERT_DIR" || {
            status_write "failed" "apex-store-stage-failed"
            return 1
        }
        build_cert_dir "$APEX_CERT_DIR" "$RUN_CERT_DIR" || {
            status_write "failed" "runtime-store-stage-failed"
            return 1
        }
    else
        build_cert_dir "$system_source" "$RUN_CERT_DIR" || {
            status_write "failed" "runtime-store-stage-failed"
            return 1
        }
    fi

    rm -f /data/misc/user/*/cacerts-removed/"$SELECTED_HASH".* 2>/dev/null
    echo "$cache_sig" > "$CACHE_FILE"
    status_write "ready" "staged"
    return 0
}

hybrid_mount_available() {
    for cli in /data/adb/metamodule/hybrid-mount /data/adb/modules/hybrid_mount/hybrid-mount /data/adb/modules/meta-hybrid_mount/hybrid-mount; do
        [ -x "$cli" ] || [ -f "$cli" ] || continue
        "$cli" api version >/dev/null 2>&1 && return 0
    done
    command -v hybrid-mount >/dev/null 2>&1 && hybrid-mount api version >/dev/null 2>&1
}

apex_mount_source() {
    if hybrid_mount_available && [ -d "$MODULE_APEX_CERT_DIR" ]; then
        echo "$MODULE_APEX_CERT_DIR"
    else
        echo "$RUN_CERT_DIR"
    fi
}

bind_mount_dir() {
    src=$1
    dst=$2

    [ -d "$src" ] || return 1
    [ -d "$dst" ] || return 0
    mount -o bind "$src" "$dst" 2>/dev/null || return 1
    mount -o remount,bind,ro "$dst" 2>/dev/null || true
    return 0
}

bind_mount_dir_in_ns() {
    pid=$1
    src=$2
    dst=$3

    [ -d "$src" ] || return 1
    [ -d "$dst" ] || return 0
    [ -r "/proc/$pid/ns/mnt" ] || return 0
    command -v nsenter >/dev/null 2>&1 || return 0
    nsenter --mount="/proc/$pid/ns/mnt" -- mount -o bind "$src" "$dst" 2>/dev/null || return 1
    nsenter --mount="/proc/$pid/ns/mnt" -- mount -o remount,bind,ro "$dst" 2>/dev/null || true
    return 0
}

versioned_apex_dirs() {
    for dir in /apex/com.android.conscrypt@*/cacerts; do
        [ -d "$dir" ] || continue
        echo "$dir"
    done
}

target_pids() {
    echo 1
    pidof zygote 2>/dev/null
    pidof zygote64 2>/dev/null
    pidof zygote_next 2>/dev/null
    pidof webview_zygote 2>/dev/null
    pidof system_server 2>/dev/null
}

mount_targets_current_ns() {
    apex_src=$(apex_mount_source)

    if [ -d "$SYSTEM_CERT_DIR" ] && [ -d "$MODULE_SYSTEM_CERT_DIR" ]; then
        bind_mount_dir "$MODULE_SYSTEM_CERT_DIR" "$SYSTEM_CERT_DIR" || true
    fi

    if [ -d "$APEX_CERT_DIR" ]; then
        bind_mount_dir "$apex_src" "$APEX_CERT_DIR" || true
        for apex_dir in $(versioned_apex_dirs); do
            bind_mount_dir "$apex_src" "$apex_dir" || true
        done
    fi
}

mount_targets_other_namespaces() {
    apex_src=$(apex_mount_source)

    seen=
    for pid in $(target_pids); do
        case " $seen " in
            *" $pid "*) continue ;;
        esac
        seen="$seen $pid"

        if [ -d "$SYSTEM_CERT_DIR" ] && [ -d "$MODULE_SYSTEM_CERT_DIR" ]; then
            bind_mount_dir_in_ns "$pid" "$MODULE_SYSTEM_CERT_DIR" "$SYSTEM_CERT_DIR" || true
        fi

        if [ -d "$APEX_CERT_DIR" ]; then
            bind_mount_dir_in_ns "$pid" "$apex_src" "$APEX_CERT_DIR" || true
            for apex_dir in $(versioned_apex_dirs); do
                bind_mount_dir_in_ns "$pid" "$apex_src" "$apex_dir" || true
            done
        fi
    done
}

cert_visible_in_dir() {
    [ -n "$SELECTED_HASH" ] || return 1
    [ -f "$1/$SELECTED_HASH.0" ]
}

verify_visibility() {
    if [ -d "$APEX_CERT_DIR" ]; then
        cert_visible_in_dir "$APEX_CERT_DIR" || return 1
        for apex_dir in $(versioned_apex_dirs); do
            cert_visible_in_dir "$apex_dir" || return 1
        done
    else
        cert_visible_in_dir "$SYSTEM_CERT_DIR" || return 1
    fi
    return 0
}
