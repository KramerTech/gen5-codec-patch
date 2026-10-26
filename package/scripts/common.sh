#!/system/bin/sh
# Shared helpers for media.codecs. Hooks run as NEMESIS root (uid 0 with only
# CAP_SETUID|CAP_SETGID) with cwd = the package dir. The toolbox shell has no
# sed/awk/cut/head/tail/wc/printf, so this sticks to grep, cat, md5 and mksh
# builtins (print -r, ${var%%pattern}, read).
export PATH=/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
# NEMESIS runs hooks with umask 0; keep the backups from being world-writable.
umask 022

ID=media.codecs
PKGDIR=${PKGDIR:-$PWD}
LOG=/data/nemesis/$ID.log
STATE=/data/nemesis/backup/$ID
XML=/system/etc/media_codecs.xml
ORIG=$STATE/media_codecs.xml.orig
LIBDIR=/system/lib
OMXLIB=$LIBDIR/libstagefright_omx.so
CONF=$PKGDIR/codecs.conf

# Formats shown in the status summary.
SUMMARY_TYPES="video/avc:H.264 video/x-vnd.on2.vp9:VP9 video/x-vnd.on2.vp8:VP8 video/hevc:HEVC video/mp4v-es:MPEG-4 video/3gpp:H.263"

log() { print -r -- "$1"; mkdir -p /data/nemesis 2>/dev/null; print -r -- "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG" 2>/dev/null; true; }

toast() {
    am broadcast -a com.hkmc.intent.action.TOAST \
        -e com.hkmc.intent.extra.TOAST_MESSAGE "$1" \
        --ez com.hkmc.intent.extra.TOAST_POPUPSHOWING true >/dev/null 2>&1 || true
}

# Prints the file's md5, or a marker so two absent files never compare equal.
md5_of() {
    [ -f "$1" ] || { print -r -- "missing:$1"; return; }
    set -- $(md5 "$1" 2>/dev/null)
    print -r -- "${1:-unreadable}"
}

line_count() { _n=$(grep -c '' "$1" 2>/dev/null); print -r -- "${_n:-0}"; }

# Remount /system rw, remembering whether it was ro so system_restore_mount
# can put it back the way it was.
SYSTEM_WAS_RO=
system_rw() {
    grep -q ' /system ext4 ro[ ,]' /proc/mounts && SYSTEM_WAS_RO=1
    /system/xbin/nemesis remount rw >/dev/null 2>&1 || { log "FAIL: cannot remount /system rw"; return 1; }
    ( : > "$LIBDIR/.media_codecs_wtest" ) 2>/dev/null || { log "FAIL: /system/lib is not writable after remount"; return 1; }
    rm -f "$LIBDIR/.media_codecs_wtest"
}

system_restore_mount() {
    sync
    [ -n "$SYSTEM_WAS_RO" ] && /system/xbin/nemesis remount ro >/dev/null 2>&1
    true
}

# Probe (tools/probe/CodecProbe.java)

run_probe() {
    mkdir -p "$STATE/dalvik/dalvik-cache" || return 1
    # app_process needs init's BOOTCLASSPATH. An ADB shell has it, but processes
    # started by svcmgr (the USB handler, which runs USB installs) may not.
    if [ -z "$BOOTCLASSPATH" ] && [ -r /init.environ.rc ]; then
        while read _cmd _name _value; do
            [ "$_cmd" = export ] && export "$_name=$_value"
        done < /init.environ.rc
    fi
    ANDROID_DATA=$STATE/dalvik CLASSPATH=$PKGDIR/probe/probe.jar \
        app_process /system/bin CodecProbe "$@" 2>/dev/null
}

# Writes "OK|FAIL DEC|ENC <name> <type>" lines for every codec to $1.
probe_list() {
    run_probe list | grep -E '^(OK|FAIL) (DEC|ENC) ' > "$1"
    grep -q '^OK ' "$1"
}

# decode_test <component> <clip>: 0 = decodes, 1 = fails, 2 = clip unreadable.
decode_test() {
    _r=$(run_probe decode "$1" "$PKGDIR/clips/$2" | grep '^DECODE ')
    log "  ${_r:-DECODE FAIL $1 (probe crashed)}"
    case "$_r" in
        "DECODE OK "*) return 0 ;;
        "DECODE SKIP "*) return 2 ;;
        *) return 1 ;;
    esac
}

# status <probe file> <name> <type>: prints OK, FAIL or absent.
status() {
    if grep -q -x -F "OK DEC $2 $3" "$1"; then print OK
    elif grep -q -x -F "FAIL DEC $2 $3" "$1"; then print FAIL
    else print absent
    fi
}

# has_working <probe file> <type>: some non-secure decoder for the type works.
has_working() {
    while read _st _kind _name _type; do
        [ "$_st $_kind $_type" = "OK DEC $2" ] || continue
        case "$_name" in *.secure) continue ;; esac
        return 0
    done < "$1"
    return 1
}

# all_fail <probe file> <name>: the codec is listed and every type of it fails.
all_fail() {
    _seen=
    while read _st _kind _name _type; do
        [ "$_kind $_name" = "DEC $2" ] || continue
        [ "$_st" = OK ] && return 1
        _seen=1
    done < "$1"
    [ -n "$_seen" ]
}

# vendor_alive <probe file> <name>: another decoder with the same "OMX.Vendor"
# prefix works, so a failure isn't just the hardware being busy.
vendor_alive() {
    _rest=${2#*.}
    _prefix=${2%%.*}.${_rest%%.*}.
    while read _st _kind _name _type; do
        [ "$_st $_kind" = "OK DEC" ] || continue
        case "$_name" in "$_prefix"*) [ "$_name" != "$2" ] && return 0 ;; esac
    done < "$1"
    return 1
}

# The unit's SoftOMXPlugin can only load components in its built-in table.
plugin_knows() { grep -q -a -F "$1" "$OMXLIB"; }

# XML editing on a working copy. Lines inside <!-- --> comments are never
# matched or changed (the AOSP header has example entries). Each edit checks
# the resulting line count.

# Comment tracking for the loops below: is_comment tells whether the current
# line is (part of) a comment, then next_comment_state updates $_c ("1" while
# inside an unclosed <!--) for the following line. No subshells, so it stays
# quick on the head unit.
is_comment() {
    [ -n "$_c" ] && return 0
    case "$1" in *"<!--"*) return 0 ;; esac
    return 1
}
next_comment_state() {
    case "$1" in
        *"-->"*) case "${1##*-->}" in *"<!--"*) _c=1 ;; *) _c= ;; esac ;;
        *"<!--"*) _c=1 ;;
    esac
}

# live_lines <file>: the lines that aren't comments.
live_lines() {
    _c=
    while IFS= read -r _line || [ -n "$_line" ]; do
        is_comment "$_line" || print -r -- "$_line"
        next_comment_state "$_line"
    done < "$1"
}

declared() { live_lines "$1" | grep -q -F "name=\"$2\""; }

# xml_add <file> <name> <type>: insert a decoder entry just before </Decoders>,
# so it has the lowest priority for its type.
xml_add() {
    [ "$(live_lines "$1" | grep -c '</Decoders>')" = 1 ] || { log "  cannot add $2: no single </Decoders> in XML"; return 1; }
    _before=$(line_count "$1")
    _c=
    while IFS= read -r _line || [ -n "$_line" ]; do
        if ! is_comment "$_line"; then
            case "$_line" in
                *"</Decoders>"*) print -r -- "        <MediaCodec name=\"$2\" type=\"$3\" />" ;;
            esac
        fi
        print -r -- "$_line"
        next_comment_state "$_line"
    done < "$1" > "$1.new"
    [ "$(line_count "$1.new")" = $((_before + 1)) ] || { rm -f "$1.new"; log "  cannot add $2: edit check failed"; return 1; }
    cat "$1.new" > "$1" && rm -f "$1.new"
}

# xml_remove <file> <name>: drop the entry, either a self-closing line or a
# block up to its </MediaCodec>. Refuses unless the name appears exactly once.
xml_remove() {
    [ "$(live_lines "$1" | grep -c -F "name=\"$2\"")" = 1 ] || { log "  cannot remove $2: not exactly one entry"; return 1; }
    _before=$(line_count "$1")
    _skip=
    _removed=0
    _c=
    while IFS= read -r _line || [ -n "$_line" ]; do
        if [ -n "$_skip" ]; then
            _removed=$((_removed + 1))
            case "$_line" in *"</MediaCodec>"*) _skip= ;; esac
            continue
        fi
        if ! is_comment "$_line"; then
            case "$_line" in
                *"name=\"$2\""*)
                    _removed=1
                    case "$_line" in *"/>"*) ;; *) _skip=1 ;; esac
                    continue ;;
            esac
        fi
        print -r -- "$_line"
        next_comment_state "$_line"
    done < "$1" > "$1.new"
    if [ -n "$_skip" ] || [ "$(line_count "$1.new")" != $((_before - _removed)) ]; then
        rm -f "$1.new"; log "  cannot remove $2: entry has no end"; return 1
    fi
    cat "$1.new" > "$1" && rm -f "$1.new"
}

# Writes the XML in place (cat >) so owner, mode and inode stay the same.
write_xml() { cat "$1" > "$XML" && sync; }

# summary <probe file>: one line per format, e.g. "H.264: hardware."
summary() {
    _msg=
    for _t in $SUMMARY_TYPES; do
        _mime=${_t%%:*}
        _label=${_t##*:}
        _desc=
        while read _st _kind _name _type; do
            [ "$_kind $_type" = "DEC $_mime" ] || continue
            case "$_name" in *.secure) continue ;; esac
            if [ "$_st" = FAIL ]; then _desc="BROKEN (dead entry first)"; break; fi
            case "$_name" in OMX.google.*) _desc=software ;; *) _desc=hardware ;; esac
            break
        done < "$1"
        _msg="$_msg$_label: ${_desc:-none}. "
    done
    print -r -- "$_msg"
}

# Restore the stock XML if it is still exactly what we wrote, and remove the
# libraries we added (only if they are still ours). Never touches files that
# something else changed since.
undo() {
    _keep_state=
    if [ -f "$ORIG" ]; then
        _cur=$(md5_of "$XML")
        if [ "$_cur" = "$(md5_of "$ORIG")" ]; then
            log "media_codecs.xml is stock"
        elif [ -f "$STATE/patched.md5" ] && [ "$_cur" = "$(cat "$STATE/patched.md5")" ]; then
            write_xml "$ORIG" && log "restored stock media_codecs.xml" || { log "FAIL: could not restore media_codecs.xml"; return 1; }
        else
            log "WARN: media_codecs.xml changed since install - leaving it; stock copy kept at $ORIG"
            _keep_state=1
        fi
    fi
    if [ -f "$STATE/installed_libs" ]; then
        for _l in $(cat "$STATE/installed_libs"); do
            if [ "$(md5_of "$LIBDIR/$_l")" = "$(md5_of "$PKGDIR/lib/$_l")" ]; then
                rm -f "$LIBDIR/$_l" && log "removed $LIBDIR/$_l"
            elif [ -e "$LIBDIR/$_l" ]; then
                log "WARN: $LIBDIR/$_l changed since install - leaving it"
            fi
        done
    fi
    if [ -z "$_keep_state" ]; then
        rm -f "$ORIG" "$STATE/installed_libs" "$STATE/patched.md5" "$STATE"/*.txt
        rm -rf "$STATE/dalvik"
        rmdir "$STATE" 2>/dev/null
    fi
    true
}
