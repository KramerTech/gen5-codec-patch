#!/system/bin/sh
# Make every video format either work or report "unsupported" cleanly:
#   1. add the Google software decoders this unit is missing (codecs.conf)
#   2. prove each one loads and decodes a test clip, backing out any that don't
#   3. drop media_codecs.xml entries that can never be instantiated here
#   4. make sure nothing that worked before stopped working
# Any failure undoes everything.
. ./scripts/common.sh
while IFS= read -r _l; do case "$_l" in version=*) log "postinstall $ID ${_l#version=}"; break ;; esac; done < NEMESIS.data

fail() {
    log "FAIL: $1 - undoing"
    undo
    system_restore_mount
    toast "Video codec fix failed and was undone: $1"
    exit 1
}

system_rw || { toast "Video codec fix failed: could not unlock the system partition. Reboot the head unit and try again."; exit 1; }
mkdir -p "$STATE" || fail "cannot create $STATE"

[ -f "$ORIG" ] || cat "$XML" > "$ORIG" || fail "cannot back up $XML"
[ "$(md5_of "$ORIG")" = "$(md5_of "$XML")" ] || fail "backup of $XML doesn't match"
log "stock media_codecs.xml md5 $(md5_of "$ORIG")"
: > "$STATE/installed_libs"

P0=$STATE/probe-0-stock.txt
probe_list "$P0" || fail "codec probe did not run"
log "stock: $(summary "$P0")"

WORK=$STATE/media_codecs.xml.work
cat "$XML" > "$WORK" || fail "cannot copy XML"
# Every write records the checksum, so undo knows the file is ours to restore.
commit_xml() {
    write_xml "$WORK" && md5_of "$XML" > "$STATE/patched.md5" || fail "cannot write $XML"
}

# 1. Decide what to add.
need_libs=
add_entries=
responsible=
while read lib name mime clip; do
    case "$lib" in ""|\#*) continue ;; esac
    st=$(status "$P0" "$name" "$mime")
    if [ "$st" = OK ]; then
        log "$name: already works"
        continue
    fi
    if [ "$st" = absent ] && has_working "$P0" "$mime"; then
        log "$name: not declared, and $mime already has a working decoder - leaving it out"
        continue
    fi
    if ! plugin_knows "$name"; then
        log "$name: this unit's SoftOMXPlugin doesn't know it - can't add"
        continue
    fi
    if [ -e "$LIBDIR/$lib" ]; then
        log "$name: $LIBDIR/$lib is already on the system - not replacing it"
    else
        case " $need_libs " in *" $lib "*) ;; *) need_libs="$need_libs $lib" ;; esac
    fi
    [ "$st" = absent ] && add_entries="$add_entries $name:$mime"
    responsible="$responsible $name:$mime:$clip:$lib"
done < "$CONF"

for lib in $need_libs; do
    [ -f "lib/$lib" ] || fail "package is missing lib/$lib"
    cat "lib/$lib" > "$LIBDIR/$lib.tmp" && chmod 644 "$LIBDIR/$lib.tmp" && mv "$LIBDIR/$lib.tmp" "$LIBDIR/$lib" \
        || { rm -f "$LIBDIR/$lib.tmp"; fail "cannot write $LIBDIR/$lib"; }
    print -r -- "$lib" >> "$STATE/installed_libs"
    log "installed $LIBDIR/$lib"
done
for e in $add_entries; do
    xml_add "$WORK" "${e%%:*}" "${e#*:}" && log "added entry ${e%%:*} (${e#*:})" || fail "cannot add ${e%%:*} to XML"
done
commit_xml
sync

# 2. Prove the codecs we're responsible for work.
P1=$STATE/probe-1-added.txt
probe_list "$P1" || fail "codec probe did not run after adding decoders"
good=
bad=
for r in $responsible; do
    name=${r%%:*}; r=${r#*:}
    mime=${r%%:*}; r=${r#*:}
    clip=${r%%:*}; lib=${r#*:}
    if [ "$(status "$P1" "$name" "$mime")" != OK ]; then
        log "$name: still can't be loaded"
        bad="$bad $name"
        continue
    fi
    decode_test "$name" "$clip"
    case $? in
        0) good="$good $name:$lib" ;;
        2) log "$name: test clip unreadable on this unit - trusting the load check"; good="$good $name:$lib" ;;
        *) bad="$bad $name" ;;
    esac
done

# Back out libraries none of whose codecs work, and entries we added that don't.
kept_libs=
for lib in $(cat "$STATE/installed_libs"); do
    case "$good " in *":$lib "*) kept_libs="$kept_libs $lib"; continue ;; esac
    rm -f "$LIBDIR/$lib" && log "removed $LIBDIR/$lib: none of its decoders work on this unit"
done
: > "$STATE/installed_libs"
for lib in $kept_libs; do print -r -- "$lib" >> "$STATE/installed_libs"; done
for e in $add_entries; do
    case " $bad " in *" ${e%%:*} "*) xml_remove "$WORK" "${e%%:*}" && log "dropped added entry ${e%%:*}" ;; esac
done
commit_xml
sync

# 3. Remove entries that can never be instantiated. A codec qualifies if every
# type of it fails in two probes a moment apart, and another codec from the
# same vendor works (so the failure isn't just busy hardware). Codecs we tried
# to fix and that failed their decode test qualify too.
P2=$STATE/probe-2a.txt
P3=$STATE/probe-2b.txt
probe_list "$P2" || fail "codec probe did not run"
sleep 2
probe_list "$P3" || fail "codec probe did not run"
dead=
checked=
while read st kind name type; do
    [ "$st $kind" = "FAIL DEC" ] || continue
    case " $checked " in *" $name "*) continue ;; esac
    checked="$checked $name"
    case "$name" in *.secure) continue ;; esac
    all_fail "$P2" "$name" && all_fail "$P3" "$name" || continue
    if ! vendor_alive "$P2" "$name" || ! vendor_alive "$P3" "$name"; then
        log "$name: fails, but so does everything else from its vendor - keeping it"
        continue
    fi
    dead="$dead $name"
done < "$P2"
for name in $bad; do
    case " $dead " in *" $name "*) ;; *) declared "$WORK" "$name" && dead="$dead $name" ;; esac
done
for name in $dead; do
    xml_remove "$WORK" "$name" && log "removed dead entry $name"
done
commit_xml
rm -f "$WORK"
sync

# 4. Nothing that worked may have stopped working.
PF=$STATE/probe-3-final.txt
probe_list "$PF" || fail "codec probe did not run with the final XML"
while read st kind name type; do
    [ "$st" = OK ] || continue
    grep -q -x -F "OK $kind $name $type" "$PF" || fail "$name ($type) worked before and doesn't now"
done < "$P0"
for g in $good; do
    grep -q "^OK DEC ${g%%:*} " "$PF" || fail "${g%%:*} stopped loading"
done
while read st kind name type; do
    [ "$st $kind" = "FAIL DEC" ] && log "still failing: $name $type"
done < "$PF"

system_restore_mount
result=$(summary "$PF")
log "result: $result"
log "postinstall ok"
toast "Video codec fix installed. $result Restart any video app that was open."
exit 0
