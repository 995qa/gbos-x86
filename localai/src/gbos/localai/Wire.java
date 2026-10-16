package gbos.localai;

import android.os.Parcel;

/**
 * The parcel framing AICore's messages use: a header int per field (field id in the low 16 bits, payload size
 * in the high 16, or 0xFFFF followed by a size int for big payloads) inside an object header (id 20293).
 * Written from the wire layout only; readers skip any field they don't know by its size.
 */
final class Wire {
    static final int MAGIC = 20293;
    private static final int BIG = 0xFFFF;

    private Wire() {}

    // ---- writing ----

    static int begin(Parcel p, int id) {
        p.writeInt(0xFFFF0000 | id);
        p.writeInt(0);
        return p.dataPosition();
    }

    static void end(Parcel p, int start) {
        int e = p.dataPosition();
        p.setDataPosition(start - 4);
        p.writeInt(e - start);
        p.setDataPosition(e);
    }

    static int beginObject(Parcel p) {
        return begin(p, MAGIC);
    }

    static void putInt(Parcel p, int id, int v) {
        p.writeInt((4 << 16) | id);
        p.writeInt(v);
    }

    static void putFloat(Parcel p, int id, float v) {
        p.writeInt((4 << 16) | id);
        p.writeFloat(v);
    }

    static void putString(Parcel p, int id, String s) {
        if (s == null) return;
        int st = begin(p, id);
        p.writeString(s);
        end(p, st);
    }

    /** Starts a typed-list field: count, then each element is preceded by its byte length. */
    static int beginList(Parcel p, int id, int count) {
        int st = begin(p, id);
        p.writeInt(count);
        return st;
    }

    static int beginElement(Parcel p) {
        int pos = p.dataPosition();
        p.writeInt(1);
        return pos;
    }

    static void endElement(Parcel p, int pos) {
        int e = p.dataPosition();
        p.setDataPosition(pos);
        p.writeInt(e - (pos + 4));
        p.setDataPosition(e);
    }

    // ---- reading ----

    static int sizeOf(Parcel p, int header) {
        int s = header >>> 16;
        return s == BIG ? p.readInt() : s;
    }

    /**
     * Position where the field or object whose header int {@code h} was just read ends. The size must be read BEFORE the
     * position is taken: a big header is followed by a size int, so {@code p.dataPosition() + sizeOf(p, h)} (position first)
     * lands 4 bytes short, which broke the first version of this parser (callback read as null, boot 29).
     */
    static int endOf(Parcel p, int h) {
        int size = sizeOf(p, h);
        int end = p.dataPosition() + size;
        if (size < 0 || end > p.dataSize()) throw new IllegalArgumentException("field size " + size + " runs past the parcel");
        return end;
    }

    /** Reads an object header; returns the parcel position where the object ends. */
    static int openObject(Parcel p) {
        int h = p.readInt();
        if ((h & 0xFFFF) != MAGIC) throw new IllegalArgumentException("not an object header: 0x" + Integer.toHexString(h));
        return endOf(p, h);
    }

    /** Skips a nullable parcelable argument (flag int, then the object). */
    static void skipParcelable(Parcel p) {
        if (p.readInt() == 0) return;
        p.setDataPosition(openObject(p));
    }
}
