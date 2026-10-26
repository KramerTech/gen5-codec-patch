"""Stands in for CodecProbe (app_process) in tests: reports what a Gen5W unit
would, for the media_codecs.xml and libraries in the sandbox root $ROOT.

Statuses come from the real unit (probe run 2026-10-25): Telechips entries
listed in TCC_DEAD fail, other Telechips entries work, and an OMX.google
component works only if its libstagefright_soft_*.so exists in the sandbox.
Env knobs: BROKEN_LIBS (libs that exist but fail to load),
TCC_ALL_FAIL (every Telechips component fails, e.g. hardware busy),
DECODE_FAIL (components that load but fail the decode test),
DECODE_SKIP (components whose test clip the extractor can't read).
"""
import os
import sys
import xml.etree.ElementTree as ET

ROOT = os.environ["ROOT"]
TCC_DEAD = {"OMX.TCC.wmv12dec", "OMX.TCC.google.vp9dec", "OMX.TCC.hevcdec",
            "OMX.TCC.ac3dec", "OMX.TCC.radec", "OMX.TCC.dtsdec"}
GOOGLE_LIB = {
    "h264.decoder": "h264dec", "mpeg4.decoder": "mpeg4dec", "h263.decoder": "mpeg4dec",
    "vp8.decoder": "vpxdec", "vp9.decoder": "vpxdec",
    "h264.encoder": "h264enc", "mpeg4.encoder": "mpeg4enc", "h263.encoder": "mpeg4enc",
    "vp8.encoder": "vpxenc", "aac.decoder": "aacdec", "mp3.decoder": "mp3dec",
    "amrnb.decoder": "amrdec", "amrwb.decoder": "amrdec", "g711.alaw.decoder": "g711dec",
    "g711.mlaw.decoder": "g711dec", "vorbis.decoder": "vorbisdec", "opus.decoder": "opusdec",
    "amrnb.encoder": "amrnbenc", "amrwb.encoder": "amrwbenc", "aac.encoder": "aacenc",
    "flac.encoder": "flacenc", "opus.encoder": "opusenc", "gsm.decoder": "gsmdec",
    "raw.decoder": "rawdec",
}
BROKEN = set(filter(None, os.environ.get("BROKEN_LIBS", "").split(",")))
DECODE_FAIL = set(filter(None, os.environ.get("DECODE_FAIL", "").split(",")))
DECODE_SKIP = set(filter(None, os.environ.get("DECODE_SKIP", "").split(",")))


def works(name):
    if os.environ.get("TCC_ALL_FAIL") and name.startswith("OMX.TCC."):
        return False
    if name in TCC_DEAD:
        return False
    if name.startswith("OMX.TCC."):
        return True
    if name.startswith("OMX.google."):
        lib = GOOGLE_LIB.get(name[len("OMX.google."):])
        return bool(lib) and lib not in BROKEN and os.path.exists(
            f"{ROOT}/system/lib/libstagefright_soft_{lib}.so")
    return False


def entries():
    tree = ET.parse(f"{ROOT}/system/etc/media_codecs.xml")
    for section, kind in (("Decoders", "DEC"), ("Encoders", "ENC")):
        sec = tree.getroot().find(section)
        for mc in sec.findall("MediaCodec") if sec is not None else []:
            name = mc.get("name")
            if name.endswith(".secure"):
                continue  # the real MediaCodecList didn't list these either
            types = [mc.get("type")] if mc.get("type") else []
            types += [t.get("name") for t in mc.findall("Type")]
            for t in types:
                yield kind, name, t


args = sys.argv[1:]
if args[0] == "list":
    for kind, name, t in entries():
        print(("OK" if works(name) else "FAIL"), kind, name, t)
elif args[0] == "decode":
    name = args[1]
    if not os.path.exists(args[2]) or name in DECODE_SKIP:
        print(f"DECODE SKIP {name} cannot read clip")
    elif works(name) and name not in DECODE_FAIL:
        print(f"DECODE OK {name} frames=10/10 176x144")
    else:
        print(f"DECODE FAIL {name} simulated")
