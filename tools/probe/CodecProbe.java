import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaExtractor;
import android.media.MediaFormat;

import java.nio.ByteBuffer;

/**
 * Codec checks run on the head unit with app_process (no APK needed).
 *
 *   CodecProbe list
 *     One line per codec and type, in media_codecs.xml order:
 *       OK|FAIL DEC|ENC <codec name> <mime type>
 *     FAIL means MediaCodecInfo.getCapabilitiesForType threw, i.e. the OMX
 *     component could not be allocated. On KitKat, ExoPlayer and other
 *     players give up on the whole format when they hit one of these.
 *
 *   CodecProbe decode <codec name> <clip>
 *     Decodes the clip's video track with that codec into ByteBuffers and
 *     prints one line:
 *       DECODE OK <name> frames=<n>/<samples> <w>x<h>
 *       DECODE FAIL <name> <reason>
 *       DECODE SKIP <name> <reason>     (the clip itself couldn't be read)
 *     OK needs most frames out, the clip's size, and non-flat picture data.
 *
 * MediaCodecList reads /system/etc/media_codecs.xml when the process starts,
 * so every run sees the current file.
 */
public class CodecProbe {
    private static final long TIMEOUT_US = 10000;
    private static final long DEADLINE_MS = 15000;

    public static void main(String[] args) {
        if (args.length >= 1 && args[0].equals("list")) {
            list();
        } else if (args.length >= 3 && args[0].equals("decode")) {
            System.out.println(decode(args[1], args[2]));
        } else {
            System.out.println("usage: CodecProbe list | decode <codec> <clip>");
            System.exit(2);
        }
    }

    private static void list() {
        int n = MediaCodecList.getCodecCount();
        for (int i = 0; i < n; i++) {
            MediaCodecInfo info = MediaCodecList.getCodecInfoAt(i);
            String kind = info.isEncoder() ? "ENC" : "DEC";
            for (String type : info.getSupportedTypes()) {
                String status;
                try {
                    info.getCapabilitiesForType(type);
                    status = "OK";
                } catch (Throwable t) {
                    status = "FAIL";
                }
                System.out.println(status + " " + kind + " " + info.getName() + " " + type);
            }
        }
    }

    private static String decode(String name, String clip) {
        MediaExtractor ex = new MediaExtractor();
        MediaFormat format = null;
        try {
            ex.setDataSource(clip);
            for (int i = 0; i < ex.getTrackCount(); i++) {
                MediaFormat f = ex.getTrackFormat(i);
                if (f.getString(MediaFormat.KEY_MIME).startsWith("video/")) {
                    ex.selectTrack(i);
                    format = f;
                    break;
                }
            }
        } catch (Throwable t) {
            ex.release();
            return "DECODE SKIP " + name + " cannot read clip: " + t;
        }
        if (format == null) {
            ex.release();
            return "DECODE SKIP " + name + " no video track in clip";
        }
        // Some firmware extractors can't read some containers: Gen5W reports a
        // VP8 WebM track as "video/notsupported". That says nothing about the
        // decoder, so don't count it as a decode failure.
        String trackMime = format.getString(MediaFormat.KEY_MIME);
        if (!codecHandles(name, trackMime)) {
            ex.release();
            return "DECODE SKIP " + name + " extractor reads the clip as " + trackMime;
        }
        int width = format.getInteger(MediaFormat.KEY_WIDTH);
        int height = format.getInteger(MediaFormat.KEY_HEIGHT);

        MediaCodec codec = null;
        try {
            codec = MediaCodec.createByCodecName(name);
            codec.configure(format, null, null, 0);
            codec.start();
            ByteBuffer[] inputs = codec.getInputBuffers();
            ByteBuffer[] outputs = codec.getOutputBuffers();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            int samples = 0, frames = 0;
            boolean inputDone = false, sawDetail = false;
            long deadline = System.currentTimeMillis() + DEADLINE_MS;

            while (System.currentTimeMillis() < deadline) {
                if (!inputDone) {
                    int in = codec.dequeueInputBuffer(TIMEOUT_US);
                    if (in >= 0) {
                        inputs[in].clear();
                        int size = ex.readSampleData(inputs[in], 0);
                        if (size < 0) {
                            codec.queueInputBuffer(in, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputDone = true;
                        } else {
                            codec.queueInputBuffer(in, 0, size, ex.getSampleTime(), 0);
                            samples++;
                            ex.advance();
                        }
                    }
                }
                int out = codec.dequeueOutputBuffer(info, TIMEOUT_US);
                if (out >= 0) {
                    if (info.size > 0) {
                        frames++;
                        if (!sawDetail) {
                            sawDetail = hasDetail(outputs[out], info);
                        }
                    }
                    codec.releaseOutputBuffer(out, false);
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        break;
                    }
                } else if (out == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                    outputs = codec.getOutputBuffers();
                } else if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat f = codec.getOutputFormat();
                    width = f.getInteger(MediaFormat.KEY_WIDTH);
                    height = f.getInteger(MediaFormat.KEY_HEIGHT);
                }
            }

            String result = "frames=" + frames + "/" + samples + " " + width + "x" + height;
            if (samples == 0) {
                return "DECODE SKIP " + name + " clip has no samples";
            }
            if (frames * 10 < samples * 8) {
                return "DECODE FAIL " + name + " too few frames: " + result;
            }
            if (!sawDetail) {
                return "DECODE FAIL " + name + " output is flat: " + result;
            }
            return "DECODE OK " + name + " " + result;
        } catch (Throwable t) {
            return "DECODE FAIL " + name + " " + t;
        } finally {
            if (codec != null) {
                try {
                    codec.stop();
                } catch (Throwable ignored) {
                }
                codec.release();
            }
            ex.release();
        }
    }

    private static boolean codecHandles(String name, String mime) {
        for (int i = 0; i < MediaCodecList.getCodecCount(); i++) {
            MediaCodecInfo info = MediaCodecList.getCodecInfoAt(i);
            if (!info.getName().equals(name)) continue;
            for (String type : info.getSupportedTypes()) {
                if (type.equalsIgnoreCase(mime)) return true;
            }
        }
        return false;
    }

    /** True if the first part of the frame isn't a single repeated byte. */
    private static boolean hasDetail(ByteBuffer buf, MediaCodec.BufferInfo info) {
        int end = info.offset + Math.min(info.size, 16384);
        int first = buf.get(info.offset) & 0xff;
        for (int i = info.offset + 1; i < end; i++) {
            if ((buf.get(i) & 0xff) != first) {
                return true;
            }
        }
        return false;
    }
}
