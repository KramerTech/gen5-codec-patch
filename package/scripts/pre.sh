#!/system/bin/sh
# Refuse to install anywhere the bundled KitKat ARM decoders can't belong.
. ./scripts/common.sh
log "preinstall $ID"

fail() { log "FAIL: $1"; toast "Video codec fix not installed: $1"; exit 1; }

[ "$(getprop ro.build.version.sdk)" = 19 ] || fail "needs Android 4.4 (API 19), found API $(getprop ro.build.version.sdk)"
case "$(getprop ro.product.cpu.abi)" in armeabi-v7a*) ;; *) fail "needs a 32-bit ARM unit" ;; esac
[ -f "$XML" ] || fail "$XML is missing"
grep -q '<Decoders>' "$XML" || fail "$XML has no <Decoders> section"
# What the bundled decoders link against.
for _d in libstagefright.so libstagefright_omx.so libstagefright_foundation.so libutils.so liblog.so libc.so libstdc++.so libm.so; do
    [ -f "$LIBDIR/$_d" ] || fail "$LIBDIR/$_d is missing"
done
[ -f probe/probe.jar ] || fail "package is missing probe/probe.jar"
[ -f codecs.conf ] || fail "package is missing codecs.conf"
while read _lib _name _mime _clip; do
    case "$_lib" in ""|\#*) continue ;; esac
    [ -f "lib/$_lib" ] || fail "package is missing lib/$_lib"
    [ -f "clips/$_clip" ] || fail "package is missing clips/$_clip"
done < codecs.conf
# When updating, the old version's preuninstall has already put the stock XML back.
if [ -f "$ORIG" ] && [ "$(md5_of "$XML")" != "$(md5_of "$ORIG")" ]; then
    fail "media_codecs.xml was changed outside this package; undo that change first"
fi
log "preinstall ok: $(getprop ro.build.product) $(getprop ro.build.display.id)"
exit 0
