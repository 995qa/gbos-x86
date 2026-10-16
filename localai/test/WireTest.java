package gbos.localai;

import android.os.Parcel;
import java.util.Arrays;

/**
 * Round-trips the parcel code against a reference reader/writer written from the SafeParcel code in gPointer (decompiled
 * SafeParcelReader/Writer), including the int that follows an object in a real transaction (the callback binder), which is
 * what a wrong object-end position corrupts.
 */
public class WireTest {
    static int fails;
    static void check(String name, boolean ok, String detail) {
        if (!ok) { fails++; System.out.println("FAIL " + name + (detail.isEmpty() ? "" : ": " + detail)); } else System.out.println("ok   " + name);
    }

    // ---- reference reader (mirrors SafeParcelReader.readSize / validateObjectHeader / getFieldId) ----
    static int refSize(Parcel p, int header) { return (header & 0xFFFF0000) != 0xFFFF0000 ? (header >> 16) & 0xFFFF : p.readInt(); }
    static int refObjectEnd(Parcel p) {
        int header = p.readInt(); int size = refSize(p, header); int pos = p.dataPosition();
        if ((header & 0xFFFF) != 20293) throw new IllegalStateException("Expected object header");
        return pos + size;
    }

    // ---- build a request the way LLMRequestParcelableCreator writes it (fields in the real order, null ones omitted) ----
    static void writeMsg(Parcel p, int role, String text, int type, boolean withBitmapField) {
        int el = Wire.beginElement(p);
        int o = Wire.beginObject(p);
        Wire.putInt(p, 1, role);
        Wire.putString(p, 2, text);
        if (withBitmapField) { int b = Wire.begin(p, 3); p.writeInt(1); p.writeInt(0xB17); p.writeInt(0xB17); Wire.end(p, b); } // a Bitmap-like blob
        Wire.putInt(p, 4, type);
        Wire.end(p, o);
        Wire.endElement(p, el);
    }

    static Parcel buildRequest(int sentinel) {
        Parcel p = new Parcel();
        p.writeInt(1);                                   // Codecs.writeParcelable: non-null flag
        int o = Wire.beginObject(p);
        int l = Wire.beginList(p, 1, 3);
        writeMsg(p, 2, "SYSTEM PROMPT " + "x".repeat(300), 0, false);
        writeMsg(p, 0, "with OCR text: 'hello world'", 0, false);
        writeMsg(p, 0, "", 5, true);                     // an image part: type 5, ignored by the text-only service
        Wire.end(p, l);
        Wire.putFloat(p, 2, 0.5f);
        Wire.putInt(p, 3, 40);
        int s = Wire.begin(p, 4); p.writeStringList(Arrays.asList("STOP1")); Wire.end(p, s);
        Wire.putInt(p, 5, 1);
        Wire.putInt(p, 6, 200);                          // maxTokens
        int bnd = Wire.begin(p, 7); p.writeInt(0x77); p.writeInt(0x88); p.writeInt(0x99); Wire.end(p, bnd);   // an IBinder field (skipped)
        Wire.putInt(p, 8, 1);
        Wire.putFloat(p, 20, 0.9f);
        Wire.putInt(p, 22, 0);
        Wire.end(p, o);
        p.writeInt(sentinel);                            // what follows the request in the transaction: the callback binder
        return p;
    }

    public static void main(String[] a) {
        final int SENT = 0x5E17E1;
        Parcel p = buildRequest(SENT);
        p.setDataPosition(0);
        check("flag is 1", p.readInt() == 1, "");
        Messages.Request r = Messages.readRequest(p);
        check("position after the request is exactly the sentinel", p.readInt() == SENT, "wrong end position (the boot-29 bug)");
        check("3 messages read, image part skipped", r.messages.size() == 2 && r.skippedNonText == 1, r.messages.size() + " msgs, skipped " + r.skippedNonText);
        check("system role + text", r.messages.size() > 0 && r.messages.get(0).role == Messages.ROLE_SYSTEM && r.messages.get(0).text.startsWith("SYSTEM PROMPT"), "");
        check("user OCR text", r.messages.size() > 1 && "with OCR text: 'hello world'".equals(r.messages.get(1).text), "");
        check("temperature/topK/topP/maxTokens", r.temperature == 0.5f && r.topK == 40 && r.topP == 0.9f && r.maxTokens == 200, r.temperature + " " + r.topK + " " + r.topP + " " + r.maxTokens);
        check("stop tokens", r.stops.equals(Arrays.asList("STOP1")), String.valueOf(r.stops));

        // a picture part: with a decoder the bitmap field becomes an image on a user message
        Messages.imageDecoder = pp -> "data:image/jpeg;base64,TESTIMG";
        Parcel pi = buildRequest(SENT);
        pi.setDataPosition(0); pi.readInt();
        Messages.Request ri = Messages.readRequest(pi);
        check("image: decoder result attached, position still exact", ri.messages.size() == 3 && "data:image/jpeg;base64,TESTIMG".equals(ri.messages.get(2).image) && ri.messages.get(2).role == Messages.ROLE_USER && pi.readInt() == SENT, ri.messages.size() + " msgs");
        Messages.imageDecoder = null;

        // result written by the service, read back with the reference reader
        Parcel q = new Parcel();
        q.writeInt(1);
        Messages.writeResult(q, "Summarize this\tNO_TOOL");
        q.writeInt(SENT);
        q.setDataPosition(0);
        q.readInt();
        int end = refObjectEnd(q); String text = null; int nres = -1; int stop = -1;
        while (q.dataPosition() < end) {
            int h = q.readInt(); int id = h & 0xFFFF; int sz = refSize(q, h); int fend = q.dataPosition() + sz;
            if (id == 1) {
                nres = q.readInt();
                for (int i = 0; i < nres; i++) {
                    q.readInt();                        // element size
                    int re = refObjectEnd(q);
                    while (q.dataPosition() < re) {
                        int h2 = q.readInt(); int id2 = h2 & 0xFFFF; int sz2 = refSize(q, h2); int fe2 = q.dataPosition() + sz2;
                        if (id2 == 1) text = q.readString(); else if (id2 == 3) stop = q.readInt();
                        q.setDataPosition(fe2);
                    }
                    q.setDataPosition(re);
                }
            }
            q.setDataPosition(fend);
        }
        check("result: 1 reply with text and stop reason FINISH", nres == 1 && "Summarize this\tNO_TOOL".equals(text) && stop == 0, nres + " " + text + " " + stop);
        check("result: parcel ends exactly at the sentinel", q.dataPosition() == end && q.readInt() == SENT, "end " + end + " pos " + q.dataPosition());

        // feature written by the service, read back with the reference reader
        Parcel f = new Parcel();
        f.writeInt(1);
        Messages.writeFeature(f, 713, 1);
        f.writeInt(SENT);
        f.setDataPosition(0); f.readInt();
        int fe = refObjectEnd(f); int id5 = -1, variant = -1, version = -1; String name = null;
        while (f.dataPosition() < fe) {
            int h = f.readInt(); int id = h & 0xFFFF; int sz = refSize(f, h); int fend = f.dataPosition() + sz;
            if (id == 1) name = f.readString(); else if (id == 4) variant = f.readInt(); else if (id == 5) id5 = f.readInt(); else if (id == 6) version = f.readInt();
            f.setDataPosition(fend);
        }
        check("feature: id 713, variant 12 (Legion), version 1", id5 == 713 && variant == 12 && version == 1 && name != null, id5 + " " + variant + " " + version + " " + name);
        check("feature: parcel ends exactly at the sentinel", f.dataPosition() == fe && f.readInt() == SENT, "");

        System.out.println(fails == 0 ? "ALL PASS" : fails + " FAILED");
        System.exit(fails);
    }
}
