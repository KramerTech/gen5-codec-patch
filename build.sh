#!/bin/bash
# Build dist/media.codecs-<version>.zip, the installable NEMESIS package.
#
# The decoder libraries aren't stored in the repo. They're pulled from Google's
# official Android SDK system image (API 19, armeabi-v7a, r05), checked against
# pinned hashes, and bundled with their license notices.
#
# Needs: curl, python3, javac, zip, and Android build-tools (d8) plus a
# platform android.jar under $ANDROID_HOME (default ~/Library/Android/sdk).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CACHE=$HERE/.cache
PKG=$HERE/package
DIST=$HERE/dist
ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}

IMG_URL=https://dl.google.com/android/repository/sys-img/android/armeabi-v7a-19_r05.zip
IMG_SHA1=d1a5fd4f2e1c013c3d3d9bfe7e9db908c3ed56fa   # from Google's sys-img2-1.xml

lib_sha256() {
    case $1 in
        libstagefright_soft_h264dec.so)  echo f5d58ecd2131793be250729e4b2c92dc1cff7904e2d0b4fa91bd575faf4aab26 ;;
        libstagefright_soft_mpeg4dec.so) echo a430208de7fca50b7b937e9f2492dcd3a5cd00d9c5c2328a24a4531e8e0c2497 ;;
        libstagefright_soft_vpxdec.so)   echo 52cf0bd2b122de7bb8ff02dc805e70e40e43f9734ed1032eec7347893804deff ;;
        *) echo "no pinned hash for $1" >&2; return 1 ;;
    esac
}

sha1() { if command -v sha1sum >/dev/null; then sha1sum "$1"; else shasum -a 1 "$1"; fi | cut -d' ' -f1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

D8=$(ls -d "$ANDROID_HOME"/build-tools/*/d8 2>/dev/null | tail -1)
ANDROID_JAR=$(ls -d "$ANDROID_HOME"/platforms/android-*/android.jar 2>/dev/null | tail -1)
[ -n "$D8" ] && [ -x "$D8" ] || { echo "d8 not found under $ANDROID_HOME/build-tools" >&2; exit 1; }
[ -n "$ANDROID_JAR" ] && [ -f "$ANDROID_JAR" ] || { echo "android.jar not found under $ANDROID_HOME/platforms" >&2; exit 1; }

# Libraries named in codecs.conf
LIBS=($(grep -v -E '^\s*(#|$)' "$PKG/codecs.conf" | awk '{print $1}' | sort -u))
CLIPS=($(grep -v -E '^\s*(#|$)' "$PKG/codecs.conf" | awk '{print $4}' | sort -u))
for c in "${CLIPS[@]}"; do
    [ -f "$PKG/clips/$c" ] || { echo "missing package/clips/$c (run tools/make-clips.sh)" >&2; exit 1; }
done

mkdir -p "$CACHE" "$DIST"

# 1. System image
zip=$CACHE/armeabi-v7a-19_r05.zip
if [ ! -f "$zip" ] || [ "$(sha1 "$zip")" != "$IMG_SHA1" ]; then
    echo "downloading $IMG_URL"
    curl -fL --progress-bar -o "$zip.part" "$IMG_URL"
    mv "$zip.part" "$zip"
fi
[ "$(sha1 "$zip")" = "$IMG_SHA1" ] || { echo "system image SHA-1 mismatch" >&2; exit 1; }
[ -f "$CACHE/system.img" ] || unzip -p "$zip" armeabi-v7a/system.img > "$CACHE/system.img"
[ -f "$CACHE/NOTICE.txt" ] || unzip -p "$zip" armeabi-v7a/NOTICE.txt > "$CACHE/NOTICE.txt"

# 2. Libraries and their notices
if [ ! -x "$CACHE/venv/bin/python" ]; then
    python3 -m venv "$CACHE/venv"
    "$CACHE/venv/bin/pip" -q install 'ext4==1.4.1'
fi
rm -rf "$PKG/lib" "$PKG/notices"
"$CACHE/venv/bin/python" -I "$HERE/tools/extract_ext4.py" "$CACHE/system.img" /lib "$PKG/lib" "${LIBS[@]}"
for l in "${LIBS[@]}"; do
    got=$(sha256 "$PKG/lib/$l")
    [ "$got" = "$(lib_sha256 "$l")" ] || { echo "$l SHA-256 mismatch: $got" >&2; exit 1; }
done
mkdir -p "$PKG/notices"
python3 -I "$HERE/tools/extract_notices.py" "$CACHE/NOTICE.txt" "$PKG/notices/THIRD_PARTY_NOTICES.txt" "${LIBS[@]}" libvpx
cp "$HERE/LICENSE" "$PKG/notices/LICENSE"

# 3. Codec probe
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
javac -nowarn -source 8 -target 8 -bootclasspath "$ANDROID_JAR" -d "$work/classes" "$HERE/tools/probe/CodecProbe.java" 2>&1 \
    | grep -v -E '^(warning|Note):|^[0-9]+ warnings?$' || true
[ -f "$work/classes/CodecProbe.class" ] || { echo "probe failed to compile" >&2; exit 1; }
"$D8" --min-api 19 --release --lib "$ANDROID_JAR" --output "$work" "$work/classes/CodecProbe.class"
rm -rf "$PKG/probe" && mkdir -p "$PKG/probe"
(cd "$work" && zip -q -X "$PKG/probe/probe.jar" classes.dex)

# 4. Package zip (everything under package/, NEMESIS.data at the root), for
#    `nemesis install`, and a USB bundle wrapping it. The USB handler only reads
#    a `type=` descriptor at the drive root, so extracting the package itself
#    onto a drive gives "Invalid package descriptor". The bundle has the same
#    layout as NEMESIS's own release zips: extract it onto the drive root.
version=$(grep -m1 '^version=' "$PKG/NEMESIS.data" | cut -d= -f2)
out=$DIST/media.codecs-$version.zip
usb=$DIST/media.codecs-$version-usb.zip
rm -f "$out" "$usb"
python3 -I - "$PKG" "$out" "$usb" <<'EOF'
import sys, zipfile
from pathlib import Path
src, out, usb = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for p in sorted(src.rglob("*")):
        if p.is_file() and not p.name.startswith((".", "._")):
            z.write(p, p.relative_to(src).as_posix())
with zipfile.ZipFile(usb, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("NEMESIS.data", "[nemesis]\nversion=1.0\ntype=install\npath=packages/media.codecs.zip\n")
    z.write(out, "packages/media.codecs.zip")
EOF
for f in "$out" "$usb"; do
    (cd "$DIST" && sha256 "$(basename "$f")" | sed "s|\$|  $(basename "$f")|" > "$(basename "$f").sha256")
    echo "built $f ($(wc -c < "$f" | tr -d ' ') bytes)"
done
