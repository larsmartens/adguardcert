#!/system/bin/sh

MODDIR=${0%/*}
export MODDIR

. "$MODDIR/common.sh"

prepare_trust_store >/dev/null 2>&1

echo "AdGuard Certificate"
echo
[ -f "$STATUS_FILE" ] && cat "$STATUS_FILE" || echo "status=unknown"
echo
echo "system=$SYSTEM_CERT_DIR"
[ -d "$APEX_CERT_DIR" ] && echo "apex=$APEX_CERT_DIR"
for apex_dir in $(versioned_apex_dirs); do
    echo "apex_versioned=$apex_dir"
done
