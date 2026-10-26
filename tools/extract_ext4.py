"""Copy files out of an ext4 image without mounting it.

usage: extract_ext4.py <system.img> <dir in image> <out dir> <name>...
"""
import os
import sys

import ext4


def main() -> None:
    img, src_dir, out_dir, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    os.makedirs(out_dir, exist_ok=True)
    with open(img, "rb") as f:
        vol = ext4.Volume(f)
        for name in names:
            data = vol.inode_at(f"{src_dir}/{name}").open().read()
            with open(os.path.join(out_dir, name), "wb") as o:
                o.write(data)
            print(f"extracted {name} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
