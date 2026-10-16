package gbos.localai;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.util.Log;

import java.net.HttpURLConnection;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/** The language-model service (interface ILLMService): runs each request on the local llama-server. */
final class LlmBinder extends Binder {
    static final String DESC = "com.google.android.apps.aicore.aidl.ILLMService";
    private static final String CANCEL_DESC = "com.google.android.apps.aicore.aidl.ICancellationCallback";
    private static final String RESULT_CB = "com.google.android.apps.aicore.aidl.ILLMResultCallback";
    private static final String RESULT_INFO_CB = "com.google.android.apps.aicore.aidl.ILLMResultWithInfoCallback";
    private static final String PREPARE_CB = "com.google.android.apps.aicore.aidl.IPrepareInferenceEngineCallback";
    private static final String TAG = Llama.TAG;

    static final int API_VERSION = 8;
    private static final int ERR_NOT_AVAILABLE = 8, ERR_INTERNAL = 14;

    static final LlmBinder INSTANCE = new LlmBinder();

    // The model runs one request at a time; a second one queues behind the first.
    private final ExecutorService pool = Executors.newFixedThreadPool(2);

    private LlmBinder() {}

    @Override
    protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
        if (code < FIRST_CALL_TRANSACTION || code > LAST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags);
        data.enforceInterface(DESC);
        try {
            switch (code) {
                case 2: // runInference(request, ILLMResultCallback)
                case 3: // runCancellableInference(request, ILLMResultCallback)
                case 6: { // runCancellableInferenceWithInfo(request, ILLMResultWithInfoCallback)
                    Messages.Request req = data.readInt() == 0 ? null : Messages.readRequest(data);
                    IBinder cb = data.readStrongBinder();
                    if (req == null || cb == null) throw new IllegalArgumentException("null request or callback");
                    IBinder cancel = run(req, cb, code == 6);
                    reply.writeNoException();
                    if (code != 2) reply.writeStrongBinder(cancel);
                    return true;
                }
                case 4: // getApiVersion()
                    reply.writeNoException();
                    reply.writeInt(API_VERSION);
                    return true;
                case 5: { // prepareInferenceEngine(IPrepareInferenceEngineCallback)
                    IBinder cb = data.readStrongBinder();
                    reply.writeNoException();
                    reply.writeStrongBinder(prepare(cb));
                    return true;
                }
                case 8: // getMetadata(callback): capabilities are not advertised
                    Log.i(TAG, "ILLMService.getMetadata ignored");
                    reply.writeNoException();
                    return true;
                default: // getTokenInfo and anything newer
                    Log.w(TAG, "ILLMService: unsupported transaction " + code);
                    reply.writeException(new UnsupportedOperationException("transaction " + code));
                    return true;
            }
        } catch (RuntimeException e) {
            Log.e(TAG, "ILLMService transaction " + code + " failed", e);
            reply.writeException(e instanceof IllegalArgumentException || e instanceof IllegalStateException ? e
                    : new IllegalStateException(e.toString()));
            return true;
        }
    }

    private IBinder run(Messages.Request req, IBinder cb, boolean withInfo) {
        final AtomicBoolean cancelled = new AtomicBoolean();
        final HttpURLConnection[] conn = new HttpURLConnection[1];
        // gPointer sends OCR text as user turns but a pure image region as a bitmap only, which this text-only
        // model cannot see. With nothing but the instructions to go on, say so rather than send an empty chat.
        boolean hasContent = false;
        for (Messages.Msg m : req.messages) if (m.role != Messages.ROLE_SYSTEM) hasContent = true;
        if (!hasContent) {
            Messages.Msg u = new Messages.Msg();
            u.role = Messages.ROLE_USER;
            u.text = req.skippedNonText > 0
                    ? "The selected content is a picture that you cannot see. Suggest the most broadly useful chips for a picture."
                    : "Suggest the most broadly useful chips.";
            req.messages.add(u);
        }
        final boolean chips = Chips.wanted(req.messages);
        int chars = 0;
        for (Messages.Msg m : req.messages) chars += m.text.length();
        final int inChars = chars;
        Log.i(TAG, "inference: " + req.messages.size() + " messages, " + inChars + " chars, " + req.skippedNonText
                + " non-text parts ignored, maxTokens=" + req.maxTokens);
        pool.execute(() -> {
            long t0 = System.currentTimeMillis();
            try {
                if (!Llama.waitReady(cancelled, 240000)) {
                    if (!cancelled.get()) fail(cb, withInfo, ERR_NOT_AVAILABLE, "llama-server not ready");
                    return;
                }
                String out = Llama.chat(req, cancelled, conn);
                if (cancelled.get()) return;
                if (chips) out = Chips.normalize(out);
                Log.i(TAG, "inference done in " + (System.currentTimeMillis() - t0) + " ms, " + out.length() + " chars: "
                        + (out.length() > 120 ? out.substring(0, 120) + "..." : out).replace('\n', '|'));
                succeed(cb, withInfo, out);
            } catch (Throwable t) {
                if (cancelled.get()) return;
                Log.e(TAG, "inference failed after " + (System.currentTimeMillis() - t0) + " ms", t);
                fail(cb, withInfo, ERR_INTERNAL, String.valueOf(t));
            }
        });
        return cancelBinder(cancelled, conn);
    }

    private IBinder prepare(IBinder cb) {
        final AtomicBoolean cancelled = new AtomicBoolean();
        pool.execute(() -> {
            // Ready as soon as the server is up (it loads the model itself); a late server just delays the first request.
            Llama.waitReady(cancelled, 240000);
            if (cancelled.get() || cb == null) return;
            oneway(cb, PREPARE_CB, 2 /* onPreparationSuccess */, null);
        });
        return cancelBinder(cancelled, null);
    }

    private static void succeed(IBinder cb, boolean withInfo, String text) {
        oneway(cb, withInfo ? RESULT_INFO_CB : RESULT_CB, 2, p -> {
            p.writeInt(1);
            Messages.writeResult(p, text);
        });
    }

    private static void fail(IBinder cb, boolean withInfo, int error, String why) {
        Log.w(TAG, "reporting failure " + error + ": " + why);
        oneway(cb, withInfo ? RESULT_INFO_CB : RESULT_CB, 3, p -> {
            if (withInfo) {
                p.writeInt(1);
                Messages.writeFailed(p, error);
            } else {
                p.writeInt(error);
            }
        });
    }

    interface Writer {
        void write(Parcel p);
    }

    private static void oneway(IBinder cb, String desc, int code, Writer w) {
        Parcel d = Parcel.obtain();
        try {
            d.writeInterfaceToken(desc);
            if (w != null) w.write(d);
            cb.transact(code, d, null, IBinder.FLAG_ONEWAY);
        } catch (RemoteException e) {
            Log.w(TAG, "callback " + desc + "#" + code + " failed: " + e);
        } finally {
            d.recycle();
        }
    }

    private static IBinder cancelBinder(AtomicBoolean cancelled, HttpURLConnection[] conn) {
        return new Binder() {
            @Override
            protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
                if (code < FIRST_CALL_TRANSACTION || code > LAST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags);
                data.enforceInterface(CANCEL_DESC);
                if (code == 2) { // cancel()
                    cancelled.set(true);
                    if (conn != null && conn[0] != null) conn[0].disconnect();
                    Log.i(TAG, "inference cancelled by client");
                }
                if (reply != null) reply.writeNoException();
                return true;
            }
        };
    }
}
