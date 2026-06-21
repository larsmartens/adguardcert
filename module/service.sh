#!/system/bin/sh

MODDIR=${0%/*}
export MODDIR

. "$MODDIR/common.sh"

prepare_trust_store || exit 0
hybrid_mount_register >/dev/null 2>&1 || true

if ! verify_visibility; then
    mount_targets_current_ns
    mount_targets_other_namespaces
fi

verify_visibility && status_write "ready" "verified" || status_write "degraded" "late-verify-failed"

exit 0
