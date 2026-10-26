#!/system/bin/sh
# Manager -> Packages -> Video Codec Fix -> Launch: show which decoder handles
# each video format. Also logged to /data/nemesis/media.codecs.log.
cd /data/nemesis/apps/media.codecs || exit 1
. ./scripts/common.sh

mkdir -p "$STATE"
OUT=$STATE/probe-status.txt
probe_list "$OUT" || { toast "Video codec fix: the codec probe did not run"; exit 1; }
msg=$(summary "$OUT")
log "status: $msg"
toast "$msg"
exit 0
