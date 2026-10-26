"""Pull the license notices for the bundled libraries out of the system
image's NOTICE.txt, verbatim, into one file that ships in the release zip.

usage: extract_notices.py <NOTICE.txt> <out file> <file name>...

NOTICE.txt is a series of blocks separated by lines of '=':
    Notices for file(s):
    /system/lib/a.so
    ...
    ------------------------------------------------------------
    <notice text>
Every block whose file list mentions one of the given names is kept (with
its file list cut down to the matching entries). Fails if a name has no block.
"""
import re
import sys


def main() -> None:
    notice_path, out_path, names = sys.argv[1], sys.argv[2], sys.argv[3:]
    # Mixed encodings (some Latin-1); surrogateescape keeps the bytes verbatim.
    text = open(notice_path, encoding="utf-8", errors="surrogateescape").read()
    blocks = re.split(r"\n={20,}\n", text)
    found = {n: False for n in names}
    out = []
    for block in blocks:
        head, sep, body = block.partition("\n" + "-" * 60 + "\n")
        if not sep:
            continue
        files = [l.strip() for l in head.splitlines() if l.strip().startswith("/")]
        hits = [f for f in files if any(f.rsplit("/", 1)[-1].startswith(n) for n in names)]
        if not hits:
            continue
        for n in names:
            if any(f.rsplit("/", 1)[-1].startswith(n) for f in hits):
                found[n] = True
        out.append("Notices for file(s):\n" + "\n".join(hits) + "\n" + "-" * 60 + "\n" + body.strip("\n") + "\n")
    missing = [n for n, ok in found.items() if not ok]
    if missing:
        raise SystemExit(f"no notice found for: {', '.join(missing)}")
    header = (
        "Third-party notices for the decoder libraries in lib/.\n\n"
        "The libraries are unmodified binaries from Google's Android SDK system image\n"
        "\"system-images;android-19;default;armeabi-v7a\" r05 (armeabi-v7a-19_r05.zip).\n"
        "They are open source components of the SDK, distributed under the licenses\n"
        "below (Android SDK License Agreement, section 3.5). libvpx is statically\n"
        "linked into libstagefright_soft_vpxdec.so. The text below is copied verbatim\n"
        "from the image's NOTICE.txt.\n\n"
    )
    with open(out_path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(header + ("\n" + "=" * 60 + "\n").join(out))
    print(f"wrote {out_path}: {len(out)} notice block(s) for {', '.join(names)}")


if __name__ == "__main__":
    main()
