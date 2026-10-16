package android.os;

import java.util.ArrayList;
import java.util.List;

/**
 * Test-only stand-in for android.os.Parcel with the handful of methods the service's parcel code uses, so that code can be
 * exercised off-device. Layout is internally consistent (4-byte ints, strings as length + UTF-16 padded to 4), not Android's
 * exact bytes; what matters here is positions, sizes and ordering.
 */
public final class Parcel {
    private byte[] buf = new byte[1 << 16];
    private int pos, size;

    private void ensure(int n) { if (n > buf.length) buf = java.util.Arrays.copyOf(buf, Math.max(n, buf.length * 2)); }

    public int dataPosition() { return pos; }
    public int dataSize() { return size; }
    public void setDataPosition(int p) { if (p < 0 || p > size) throw new IllegalArgumentException("position " + p + " outside 0.." + size); pos = p; }

    public void writeInt(int v) {
        ensure(pos + 4);
        buf[pos] = (byte) v; buf[pos + 1] = (byte) (v >> 8); buf[pos + 2] = (byte) (v >> 16); buf[pos + 3] = (byte) (v >> 24);
        pos += 4; if (pos > size) size = pos;
    }
    public int readInt() {
        if (pos + 4 > size) throw new IllegalStateException("read past end at " + pos);
        int v = (buf[pos] & 0xFF) | (buf[pos + 1] & 0xFF) << 8 | (buf[pos + 2] & 0xFF) << 16 | (buf[pos + 3] & 0xFF) << 24;
        pos += 4; return v;
    }
    public void writeFloat(float f) { writeInt(Float.floatToIntBits(f)); }
    public float readFloat() { return Float.intBitsToFloat(readInt()); }

    public void writeString(String s) {
        if (s == null) { writeInt(-1); return; }
        writeInt(s.length());
        for (int i = 0; i < s.length(); i++) { ensure(pos + 2); buf[pos] = (byte) s.charAt(i); buf[pos + 1] = (byte) (s.charAt(i) >> 8); pos += 2; if (pos > size) size = pos; }
        while (pos % 4 != 0) { ensure(pos + 1); buf[pos++] = 0; if (pos > size) size = pos; }
    }
    public String readString() {
        int n = readInt();
        if (n < 0) return null;
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < n; i++) { b.append((char) ((buf[pos] & 0xFF) | (buf[pos + 1] & 0xFF) << 8)); pos += 2; }
        while (pos % 4 != 0) pos++;
        return b.toString();
    }
    public void writeStringList(List<String> l) { if (l == null) { writeInt(-1); return; } writeInt(l.size()); for (String s : l) writeString(s); }
    public ArrayList<String> createStringArrayList() {
        int n = readInt();
        if (n < 0) return null;
        ArrayList<String> r = new ArrayList<>(); for (int i = 0; i < n; i++) r.add(readString()); return r;
    }
}
