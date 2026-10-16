package gbos.localai;

import android.os.Parcel;

import java.util.ArrayList;
import java.util.List;

/** The few AICore messages the local service reads or writes (field ids from the wire layout). */
final class Messages {
    private Messages() {}

    static final int ROLE_USER = 0, ROLE_MODEL = 1, ROLE_SYSTEM = 2;
    static final int TYPE_TEXT = 0;

    static final class Msg {
        int role, type;
        String text;
    }

    static final class Request {
        final List<Msg> messages = new ArrayList<>();
        final List<String> stops = new ArrayList<>();
        float temperature = -1f, topP = -1f;
        int topK = -1, maxTokens = -1;
        int skippedNonText;
    }

    /** Reads a request written after the nullable-parcelable flag. */
    static Request readRequest(Parcel p) {
        Request r = new Request();
        int end = Wire.openObject(p);
        while (p.dataPosition() < end) {
            int h = p.readInt();
            int id = h & 0xFFFF;
            int fend = Wire.endOf(p, h);
            switch (id) {
                case 1: { // messages
                    int n = p.readInt();
                    for (int i = 0; i < n; i++) {
                        int len = p.readInt();
                        if (len == 0) continue;
                        int start = p.dataPosition();
                        Msg m = readMsg(p);
                        p.setDataPosition(start + len);
                        if (m.type == TYPE_TEXT && m.text != null) r.messages.add(m);
                        else r.skippedNonText++;
                    }
                    break;
                }
                case 2: r.temperature = p.readFloat(); break;
                case 3: r.topK = p.readInt(); break;
                case 4: { // stop tokens
                    List<String> l = p.createStringArrayList();
                    if (l != null) r.stops.addAll(l);
                    break;
                }
                case 6: r.maxTokens = p.readInt(); break;
                case 20: r.topP = p.readFloat(); break;
                default: break;
            }
            p.setDataPosition(fend);
        }
        p.setDataPosition(end);
        return r;
    }

    private static Msg readMsg(Parcel p) {
        Msg m = new Msg();
        int end = Wire.openObject(p);
        while (p.dataPosition() < end) {
            int h = p.readInt();
            int id = h & 0xFFFF;
            int fend = Wire.endOf(p, h);
            switch (id) {
                case 1: m.role = p.readInt(); break;
                case 2: m.text = p.readString(); break;
                case 4: m.type = p.readInt(); break;
                default: break;
            }
            p.setDataPosition(fend);
        }
        p.setDataPosition(end);
        return m;
    }

    /** An AIFeature (the id gPointer asks for, marked variant 12 = Legion so it takes that path). */
    static void writeFeature(Parcel p, int id, int version) {
        int st = Wire.beginObject(p);
        Wire.putString(p, 1, "gbos_local_" + id);
        Wire.putString(p, 2, "gbos-local-llm");
        Wire.putInt(p, 3, 1);
        Wire.putInt(p, 4, 12);
        Wire.putInt(p, 5, id);
        Wire.putInt(p, 6, version);
        Wire.putInt(p, 7, 35);
        Wire.putString(p, 8, "Local model served by gbOS86");
        Wire.putInt(p, 9, 0);
        Wire.end(p, st);
    }

    /** An LLMResult holding one reply. */
    static void writeResult(Parcel p, String text) {
        int st = Wire.beginObject(p);
        int list = Wire.beginList(p, 1, 1);
        int el = Wire.beginElement(p);
        int rs = Wire.beginObject(p);
        Wire.putString(p, 1, text);
        Wire.putFloat(p, 2, 0f);
        Wire.putInt(p, 3, 0); // stop reason FINISH
        Wire.putFloat(p, 4, 0f);
        Wire.end(p, rs);
        Wire.endElement(p, el);
        Wire.end(p, list);
        Wire.end(p, st);
    }

    /** A FailedResult carrying only the error code. */
    static void writeFailed(Parcel p, int error) {
        int st = Wire.beginObject(p);
        Wire.putInt(p, 1, error);
        Wire.end(p, st);
    }
}
