#!/system/bin/sh
# Delete pre-compiled oat files for telephony-common.jar
# so Android uses our patched jar instead
MODDIR=${0%/*}
OAT_DIR=/system/framework/oat
for arch in arm arm64 x86 x86_64; do
    if [ -d "$OAT_DIR/$arch" ]; then
        # Create .replace marker to delete oat files
        mkdir -p "$MODDIR/system/framework/oat/$arch"
        # Create empty placeholder files to override originals
        for ext in odex vdex; do
            if [ -f "$OAT_DIR/$arch/telephony-common.$ext" ]; then
                echo "Overriding $OAT_DIR/$arch/telephony-common.$ext"
                touch "$MODDIR/system/framework/oat/$arch/telephony-common.$ext"
            fi
        done
    fi
done
