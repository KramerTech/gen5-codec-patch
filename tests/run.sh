#!/bin/bash
# Runs the package's install hooks against simulated head units and checks
# what they do. No car needed: tests/sim.py stands in for the on-device codec
# probe, and every path the hooks touch is redirected into a sandbox.
#
# The hooks run under mksh (Android's shell) when it's installed, otherwise
# under zsh in sh emulation. Needs: python3, and package/lib + package/probe
# from ./build.sh (the hooks check they exist; their contents aren't used).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
FIX=$HERE/fixtures
STOCK_XML=$FIX/media_codecs.ioniq5-neev23-us.xml
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if command -v mksh >/dev/null; then SH=(mksh); else SH=(zsh --emulate sh); fi
echo "hooks run with: ${SH[*]}"

[ -d "$REPO/package/lib" ] && [ -f "$REPO/package/probe/probe.jar" ] || { echo "run ./build.sh first" >&2; exit 1; }

failures=0
check() {  # check <description> <command...>
    if "${@:2}"; then echo "  ok   $1"; else echo "  FAIL $1"; failures=$((failures + 1)); fi
}

# setup <name> <xml> <plugin component list>: a sandbox unit. Prints its root.
setup() {
    local root=$WORK/$1 l
    mkdir -p "$root"/system/{etc,lib,bin,xbin} "$root"/data/nemesis/apps "$root"/proc "$root"/bin
    cp "$2" "$root/system/etc/media_codecs.xml"
    cp "$3" "$root/system/lib/libstagefright_omx.so"
    for l in libstagefright.so libstagefright_foundation.so libutils.so liblog.so libc.so libstdc++.so libm.so; do
        : > "$root/system/lib/$l"
    done
    # The software codecs the Ioniq 5 firmware does ship.
    for l in aacdec aacenc amrdec amrnbenc amrwbenc flacenc g711dec gsmdec mp3dec opusdec opusenc rawdec vorbisdec; do
        echo "stock $l" > "$root/system/lib/libstagefright_soft_$l.so"
    done
    echo "/dev/block/platform/bdm/by-name/system /system ext4 ro,nodev,relatime 0 0" > "$root/proc/mounts"

    cat > "$root/system/xbin/nemesis" <<EOF
#!/bin/sh
case "\$1 \$2" in
    "remount rw") python3 -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace(" ext4 ro,"," ext4 rw,"))' "$root/proc/mounts" ;;
    "remount ro") python3 -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace(" ext4 rw,"," ext4 ro,"))' "$root/proc/mounts" ;;
esac
exit 0
EOF
    cat > "$root/bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in ro.build.version.sdk) echo 19 ;; ro.product.cpu.abi) echo armeabi-v7a ;; *) echo test ;; esac
EOF
    cat > "$root/bin/am" <<EOF
#!/bin/sh
echo "\$*" >> "$root/am.log"
EOF
    cat > "$root/bin/md5" <<'EOF'
#!/bin/sh
for f; do [ -f "$f" ] && python3 -c 'import hashlib,sys; print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest(), sys.argv[1], sep="  ")' "$f"; done
EOF
    cat > "$root/bin/app_process" <<EOF
#!/bin/sh
shift; shift
ROOT="$root" exec python3 -I "$HERE/sim.py" "\$@"
EOF
    chmod +x "$root"/system/xbin/nemesis "$root"/bin/*

    # The package, with every absolute path pointed into the sandbox.
    local pkg=$root/data/nemesis/apps/media.codecs
    cp -R "$REPO/package" "$pkg"
    python3 -I - "$root" "$pkg" <<'EOF'
import sys
from pathlib import Path
root, pkg = sys.argv[1], Path(sys.argv[2])
for f in list(pkg.glob("scripts/*.sh")) + list(pkg.glob("bin/*.sh")):
    lines = []
    for line in f.read_text().splitlines(keepends=True):
        if line.startswith("export PATH="):
            line = f"export PATH={root}/bin:/usr/bin:/bin\n"
        line = line.replace("/system/", f"{root}/system/").replace("/data/nemesis", f"{root}/data/nemesis").replace("/proc/mounts", f"{root}/proc/mounts")
        lines.append(line)
    f.write_text("".join(lines))
EOF
    echo "$root"
}

hook() { (cd "$1/data/nemesis/apps/media.codecs" && "${SH[@]}" "scripts/$2.sh") >> "$1/hooks.log" 2>&1; }
libs_of() { cat "$1/data/nemesis/backup/media.codecs/installed_libs" 2>/dev/null | tr '\n' ' '; }
has_line() { grep -q -F -- "$2" "$1"; }
lacks_line() { ! grep -q -F -- "$2" "$1"; }
xml_parses() { python3 -I -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$1"; }
# result_is <root> <text>: the last install's result line contains the text.
result_is() { grep "result: " "$1/hooks.log" | tail -1 | grep -q -F -- "$2"; }
hook_fails() { ! hook "$@"; }

KNOWN=$FIX/softomxplugin-components.txt
UNKNOWN=$WORK/unknown-plugin.txt
echo "no components here" > "$UNKNOWN"

echo "== s1: Ioniq 5 as shipped"
R=$(setup s1 "$STOCK_XML" "$KNOWN")
hook "$R" pre && hook "$R" post; rc=$?
X=$R/system/etc/media_codecs.xml
check "install succeeds" [ $rc = 0 ]
check "result" result_is "$R" "H.264: hardware. VP9: software. VP8: hardware. HEVC: none. MPEG-4: hardware. H.263: hardware."
check "all three decoders installed" [ "$(libs_of "$R")" = "libstagefright_soft_h264dec.so libstagefright_soft_mpeg4dec.so libstagefright_soft_vpxdec.so " ]
check "dead TCC VP9/HEVC/WMV1-2 entries removed" lacks_line "$X" 'name="OMX.TCC.google.vp9dec"'
check "dead multi-type audio entry removed" lacks_line "$X" 'name="OMX.TCC.ac3dec"'
check "working TCC entries kept" has_line "$X" 'name="OMX.TCC.avcdec"'
check "dead Google encoders left alone" has_line "$X" 'name="OMX.google.h264.encoder"'
check "comment header untouched" has_line "$X" '<MediaCodec name="OMX.foo.bar" type="something/interesting" />'
check "XML still parses" xml_parses "$X"
check "/system remounted ro" grep -q " ext4 ro," "$R/proc/mounts"
hook "$R" preun; rc=$?
check "uninstall succeeds" [ $rc = 0 ]
check "uninstall restores stock XML byte for byte" cmp -s "$STOCK_XML" "$X"
check "uninstall removes the decoders" [ -z "$(ls "$R/system/lib" | grep -E 'h264dec|mpeg4dec|vpxdec')" ]
hook "$R" pre && hook "$R" post
check "reinstall after uninstall" result_is "$R" "VP9: software"

echo "== s2: different codec list (no Google H.264/VP8/VP9 entries, a commented-out VP9 line)"
python3 -I - "$STOCK_XML" "$WORK/variant2.xml" <<'EOF'
import sys
drop = ('name="OMX.google.h264.decoder"', 'name="OMX.google.vp8.decoder"', 'name="OMX.google.vp9.decoder"', 'name="OMX.TCC.google.vp9dec"')
out = []
for l in open(sys.argv[1]).read().split("\n"):
    if any(d in l for d in drop):
        continue
    if "</Decoders>" in l:
        out.append('        <!-- <MediaCodec name="OMX.google.vp9.decoder" type="video/x-vnd.on2.vp9" /> -->')
    out.append(l)
open(sys.argv[2], "w").write("\n".join(out))
EOF
R=$(setup s2 "$WORK/variant2.xml" "$KNOWN")
hook "$R" pre && hook "$R" post
X=$R/system/etc/media_codecs.xml
check "H.264 decoder not installed (hardware already works)" [ "$(libs_of "$R")" = "libstagefright_soft_mpeg4dec.so libstagefright_soft_vpxdec.so " ]
check "VP9 entry added" has_line "$X" '        <MediaCodec name="OMX.google.vp9.decoder" type="video/x-vnd.on2.vp9" />'
check "commented-out line untouched" has_line "$X" '<!-- <MediaCodec name="OMX.google.vp9.decoder"'
check "no VP8 entry added" lacks_line "$X" 'name="OMX.google.vp8.decoder" type'
check "result" result_is "$R" "VP9: software"
check "XML still parses" xml_parses "$X"
hook "$R" preun
check "uninstall restores the variant XML" cmp -s "$WORK/variant2.xml" "$X"

echo "== s3: bundled VP8/VP9 library won't load"
R=$(setup s3 "$STOCK_XML" "$KNOWN")
(export BROKEN_LIBS=vpxdec; hook "$R" pre && hook "$R" post)
check "vpxdec backed out" [ ! -e "$R/system/lib/libstagefright_soft_vpxdec.so" ]
check "dead Google VP9 entry removed" lacks_line "$R/system/etc/media_codecs.xml" 'name="OMX.google.vp9.decoder"'
check "VP9 reported as none (not broken)" result_is "$R" "VP9: none."

echo "== s4: VP9 loads but fails the decode test"
R=$(setup s4 "$STOCK_XML" "$KNOWN")
(export DECODE_FAIL=OMX.google.vp9.decoder; hook "$R" pre && hook "$R" post)
check "vpxdec kept for VP8" [ -e "$R/system/lib/libstagefright_soft_vpxdec.so" ]
check "VP9 entry removed" lacks_line "$R/system/etc/media_codecs.xml" 'name="OMX.google.vp9.decoder"'
check "VP8 entry kept" has_line "$R/system/etc/media_codecs.xml" 'name="OMX.google.vp8.decoder"'

echo "== s4b: extractor can't read a test clip (Gen5W: VP8 WebM reads as video/notsupported)"
R=$(setup s4b "$STOCK_XML" "$KNOWN")
(export DECODE_SKIP=OMX.google.vp8.decoder; hook "$R" pre && hook "$R" post)
check "VP8 entry kept (load check trusted)" has_line "$R/system/etc/media_codecs.xml" 'name="OMX.google.vp8.decoder"'
check "skip logged" grep -q "trusting the load check" "$R/hooks.log"

echo "== s5: plugin doesn't know the Google decoders"
R=$(setup s5 "$STOCK_XML" "$UNKNOWN")
hook "$R" pre && hook "$R" post
check "nothing installed" [ -z "$(libs_of "$R")" ]
check "dead Google entries removed" lacks_line "$R/system/etc/media_codecs.xml" 'name="OMX.google.h264.decoder"'
check "result" result_is "$R" "H.264: hardware. VP9: none."

echo "== s6: a decoder library already ships on the unit"
R=$(setup s6 "$STOCK_XML" "$KNOWN")
echo "vendor h264dec" > "$R/system/lib/libstagefright_soft_h264dec.so"
hook "$R" pre && hook "$R" post
check "existing library not replaced" grep -q "vendor h264dec" "$R/system/lib/libstagefright_soft_h264dec.so"
check "not recorded as ours" [ "$(libs_of "$R")" = "libstagefright_soft_mpeg4dec.so libstagefright_soft_vpxdec.so " ]
hook "$R" preun
check "uninstall leaves it in place" grep -q "vendor h264dec" "$R/system/lib/libstagefright_soft_h264dec.so"

echo "== s7: every Telechips component failing (hardware busy)"
R=$(setup s7 "$STOCK_XML" "$KNOWN")
(export TCC_ALL_FAIL=1; hook "$R" pre && hook "$R" post)
check "no Telechips entries removed" [ "$(grep -c 'name="OMX.TCC.' "$R/system/etc/media_codecs.xml")" = "$(grep -c 'name="OMX.TCC.' "$STOCK_XML")" ]

echo "== s8: XML changed by something else after install"
R=$(setup s8 "$STOCK_XML" "$KNOWN")
hook "$R" pre && hook "$R" post
echo "<!-- someone else -->" >> "$R/system/etc/media_codecs.xml"
hook "$R" preun
check "uninstall leaves the foreign change alone" has_line "$R/system/etc/media_codecs.xml" "someone else"
check "stock copy kept" [ -f "$R/data/nemesis/backup/media.codecs/media_codecs.xml.orig" ]
check "reinstall refused until resolved" hook_fails "$R" pre

echo
if [ $failures = 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed (logs: keep \$WORK by commenting out the trap)"; exit 1; fi
