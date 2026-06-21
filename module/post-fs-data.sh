#!/system/bin/sh

MODDIR=${0%/*}
export MODDIR

. "$MODDIR/common.sh"

prepare_trust_store || exit 0

if ! hybrid_mount_available; then
    mount_targets_current_ns
fi

exit 0
