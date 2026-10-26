#!/system/bin/sh
# Put media_codecs.xml and /system/lib back the way they were before install.
. ./scripts/common.sh
log "preuninstall $ID"
system_rw || { toast "Video codec fix: could not unlock the system partition to uninstall. Reboot and try again."; exit 1; }
undo || { system_restore_mount; exit 1; }
system_restore_mount
log "preuninstall ok - back to stock"
exit 0
