package com.aiorchestrator;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Reads only Tombstone.abort_message (field 14), never memory dumps/log buffers.
 * Schema: platform/system/core/debuggerd/proto/tombstone.proto in AOSP.
 */
final class TombstoneAbortMessage {
    private static final int MAX_SCAN_BYTES = 2 * 1024 * 1024;
    private static final int MAX_MESSAGE_BYTES = 8 * 1024;
    private final InputStream stream;
    private int remaining = MAX_SCAN_BYTES;

    private TombstoneAbortMessage(InputStream stream) { this.stream = stream; }

    static String read(InputStream stream) throws IOException {
        return new TombstoneAbortMessage(stream).parse();
    }

    private int next() throws IOException {
        if (remaining-- <= 0) throw new IOException("Tombstone scan limit");
        int value = stream.read();
        if (value < 0) throw new EOFException();
        return value;
    }

    private long varint(int first) throws IOException {
        long value = first & 127;
        int current = first;
        for (int shift = 7; (current & 128) != 0; shift += 7) {
            if (shift > 63) throw new IOException("Invalid varint");
            current = next();
            if (shift == 63 && (current & 254) != 0) {
                throw new IOException("Varint overflow");
            }
            value |= (long) (current & 127) << shift;
        }
        return value;
    }

    private void skip(long count) throws IOException {
        if (count < 0 || count > remaining) throw new IOException("Invalid length");
        for (long i = 0; i < count; i++) next();
    }

    private String parse() throws IOException {
        while (remaining > 0) {
            int first;
            try { first = next(); } catch (EOFException end) { return null; }
            long tag = varint(first);
            if (tag <= 0 || tag > 0xffffffffL || (tag >>> 3) == 0) {
                throw new IOException("Invalid tag");
            }
            int wire = (int) (tag & 7);
            if (wire == 0) {
                varint(next());
            } else if (wire == 1) {
                skip(8);
            } else if (wire == 5) {
                skip(4);
            } else if (wire == 2) {
                long length = varint(next());
                if (length < 0 || length > remaining) throw new IOException("Invalid length");
                if ((tag >>> 3) == 14) {
                    if (length > MAX_MESSAGE_BYTES) throw new IOException("Abort message limit");
                    byte[] text = new byte[(int) length];
                    for (int i = 0; i < text.length; i++) text[i] = (byte) next();
                    return new String(text, StandardCharsets.UTF_8);
                }
                skip(length);
            } else {
                throw new IOException("Unsupported wire type");
            }
        }
        throw new IOException("Tombstone scan limit");
    }
}
