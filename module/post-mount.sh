#!/system/bin/sh

MODDIR=${0%/*}
export MODDIR

. "$MODDIR/common.sh"

prepare_trust_store || exit 0
mount_targets_current_ns
mount_targets_other_namespaces

verify_visibility && status_write "ready" "mounted" || status_write "degraded" "mount-not-visible"

exit 0
