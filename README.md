# Video Codec Fix for Gen5W head units

A [NEMESIS](https://github.com/xwtk/hmg_nemesis) package for Hyundai/Kia/Genesis Gen5W head units (Android 4.4.2, Telechips TCC803x). It makes video work in third-party players such as SmartTube, Kodi, or anything built on ExoPlayer, instead of having them fail with:

```
MediaCodecUtil$DecoderQueryException: Failed to query underlying media codecs
Caused by: java.lang.IllegalArgumentException at android.media.MediaCodecList.getCodecCapabilities
```

It's general-purpose: no app-specific patches, and it doesn't touch the hardware decoders.

## The problem

The firmware's `/system/etc/media_codecs.xml` lists codecs that can't be instantiated on the unit. On a 2023 Ioniq 5:

| Entry | Why it's dead |
|---|---|
| `OMX.google.{h264,mpeg4,h263,vp8,vp9}.decoder` | listed, but `libstagefright_soft_{h264dec,mpeg4dec,vpxdec}.so` were left out of `/system/lib` |
| `OMX.TCC.google.vp9dec` | its library, `libOMX.TCC.google.vpxdec.so`, is missing |
| `OMX.TCC.hevcdec` | never registered in `libTCC_OMXCore`, even though the HEVC hardware exists |
| `OMX.TCC.{wmv12dec,ac3dec,dtsdec,radec}` | the component can't be allocated |

When a player asks Android about one of these, the call throws. On Android ≤ 6, ExoPlayer skips a broken codec only if it has already found a working one for that format. So:
- **H.264:** the working hardware decoder (`OMX.TCC.avcdec`) gets skipped by ExoPlayer's *tunneled-playback* query, which KitKat can't satisfy. The query then hits the dead Google entry with an empty list, and playback fails.
- **VP9, HEVC, E-AC3, DTS:** the first entry for each is dead, so every query for them throws.

## What the package does

Everything is decided on the unit, at install time:

1. **Probe.** A small dex run with `app_process` lists every codec and whether Android can instantiate it.
2. **Add missing Google decoders.** For each decoder in [`package/codecs.conf`](package/codecs.conf), the library is installed only if:
   - the unit's `SoftOMXPlugin` can load that component (its name is in `libstagefright_omx.so`),
   - no file with that name already exists in `/system/lib` (existing files are never replaced),
   - and the codec is declared but dead, or undeclared while the format has no working decoder at all. An undeclared one also gets a new XML entry, placed last so it has the lowest priority.
3. **Prove they work.** Each decoder has to load *and* decode a test clip from [`package/clips/`](package/clips/) into real frames. If the firmware can't read a clip's container (Gen5W reports VP8-in-WebM as `video/notsupported`), the test is skipped and the load check is trusted instead. Libraries with no working decoder are removed again, and so are entries we added that fail.
4. **Remove dead entries.** A decoder entry is removed only if every type it declares failed in two probes a moment apart *and* another decoder from the same vendor worked in those same probes, which rules out "the hardware was just busy". Dead encoders are left alone. Comments in the XML are never touched.
5. **Check for regressions.** Every codec that worked before must still work, or the whole install is undone.

Result on a 2023 Ioniq 5 (`NEEV23.USA`, firmware 260507):

| Format | Before | After |
|---|---|---|
| H.264 | player error | hardware (`OMX.TCC.avcdec`), with software fallback |
| VP9 | player error | software (`OMX.google.vp9.decoder`) |
| VP8, MPEG-4, H.263 | hardware | hardware (unchanged) |
| HEVC, E-AC3/AC3, DTS | player error | reported as unsupported (players choose another track) |

VP9 decodes on the CPU. If 1080p stutters, set the player to prefer H.264/AVC so it uses the hardware decoder.

Launching the package from NEMESIS Manager (Packages → Video Codec Fix → Launch) shows a toast listing which decoder handles each format. Install details go to `/data/nemesis/media.codecs.log`, and the probe results are kept in `/data/nemesis/backup/media.codecs/`.

## Install

Download `media.codecs-<version>.zip` from Releases. Then either:
- **USB:** install it with NEMESIS's USB installer (`type=install`, see the NEMESIS docs).
- **ADB:**
  ```sh
  adb push media.codecs-2.0.1.zip /data/local/tmp/
  adb shell '/system/xbin/nemesis install --update /data/local/tmp/media.codecs-2.0.1.zip'
  ```

No reboot is needed. Restart any video app that was open, since apps read the codec list when they start.

Pre-install checks refuse anything other than Android 4.4 (API 19) on 32-bit ARM. They also refuse if `media_codecs.xml` was modified by something else since a previous install.

## Uninstall

Manager → Packages → Video Codec Fix → Uninstall, or `nemesis uninstall media.codecs`. This restores the stock `media_codecs.xml` and removes the libraries the package added, but only if they're still byte-identical to what it wrote. If something else has changed them since, they're left alone and the stock XML backup is kept in `/data/nemesis/backup/media.codecs/`.

## Build

```sh
./build.sh       # → dist/media.codecs-<version>.zip and .sha256
tests/run.sh     # install/uninstall scenarios against simulated units
```

Needs `curl`, `python3`, `javac`, `zip`, and the Android SDK's build-tools (`d8`) plus a platform `android.jar`. Set `ANDROID_HOME` if it isn't `~/Library/Android/sdk`. `build.sh`:
1. downloads Google's SDK system image `armeabi-v7a-19_r05.zip` (~160 MB, cached in `.cache/`, SHA-1 checked against Google's repository manifest),
2. extracts the decoders with a pure-Python ext4 reader and checks them against pinned SHA-256 hashes,
3. copies their license notices from the image's `NOTICE.txt`,
4. compiles the probe, and zips `package/`.

CI ([`.github/workflows/build.yml`](.github/workflows/build.yml)) builds and runs the tests under mksh, Android's shell. Pushing a tag `v<version>` that matches `package/NEMESIS.data` publishes the zip as a release.

`tests/run.sh` runs the real install hooks in a sandbox. `tests/sim.py` stands in for the on-device probe, using codec behavior measured on an Ioniq 5. The scenarios cover:
- the stock unit,
- a unit with a different codec list,
- a bundled library that won't load,
- a decoder that loads but can't decode,
- a plugin that doesn't know the decoders,
- a library already shipped by the vendor,
- busy hardware,
- the XML being changed by someone else.

To regenerate the test clips (needs ffmpeg): `tools/make-clips.sh`.

## Layout

| Path | |
|---|---|
| `package/` | the NEMESIS package. `lib/`, `probe/` and `notices/` are build outputs |
| `package/codecs.conf` | decoders the package can provide: library, component, MIME type, test clip |
| `package/scripts/` | `pre.sh` checks, `post.sh` installs, `preun.sh` restores, `common.sh` holds shared helpers |
| `package/bin/status.sh` | the Launch action |
| `package/clips/` | 176×144, 10-frame synthetic test clips (ffmpeg `testsrc2`) |
| `tools/probe/CodecProbe.java` | on-device probe: `list` and `decode <codec> <clip>` |
| `tools/extract_ext4.py`, `tools/extract_notices.py` | build helpers |
| `tests/` | simulator, scenarios, fixtures |

## Third-party code

The release zip includes three unmodified binaries from Google's Android SDK system image (API 19, armeabi-v7a, r05):
- `libstagefright_soft_h264dec.so`, `libstagefright_soft_mpeg4dec.so` and `libstagefright_soft_vpxdec.so` are AOSP code under the Apache License 2.0.
- `vpxdec` statically includes libvpx, under the BSD 3-clause license (WebM Project).

These are open-source components of the SDK, which the SDK license (section 3.5) leaves governed solely by their own licenses. Their notices ship in the zip as `notices/THIRD_PARTY_NOTICES.txt`, copied verbatim from the image's `NOTICE.txt`. Those copyright licenses don't cover patents on the video formats themselves.

`tests/fixtures/media_codecs.ioniq5-neev23-us.xml` is the stock codec list from a 2023 Ioniq 5, kept as a test fixture.
