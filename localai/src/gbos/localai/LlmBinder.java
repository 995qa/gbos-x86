package gbos.localai;

import android.graphics.Bitmap;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.util.Base64;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.net.HttpURLConnection;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/** The language-model service (interface ILLMService): answers each request with the user's configured chat API. */
final class LlmBinder extends Binder {
    static final String DESC = "com.google.android.apps.aicore.aidl.ILLMService";
    private static final String CANCEL_DESC = "com.google.android.apps.aicore.aidl.ICancellationCallback";
    private static final String RESULT_CB = "com.google.android.apps.aicore.aidl.ILLMResultCallback";
    private static final String RESULT_INFO_CB = "com.google.android.apps.aicore.aidl.ILLMResultWithInfoCallback";
    private static final String PREPARE_CB = "com.google.android.apps.aicore.aidl.IPrepareInferenceEngineCallback";
    private static final String TAG = Api.TAG;

    static final int API_VERSION = 8;
    // AICore error codes (aidl ErrorCode)
    private static final int ERR_BAD_REQUEST = 3, ERR_NOT_AVAILABLE = 8, ERR_INTERNAL = 14, ERR_SERVICE_PROCESSING = 10,
            ERR_PERMISSION_DENIED = 22, ERR_RESOURCE_EXHAUSTED = 25;
    private static final int IMAGE_MAX_SIDE = 1024;

    static final LlmBinder INSTANCE = new LlmBinder();

    static {
        Messages.imageDecoder = LlmBinder::bitmapToDataUri;
    }

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
        // With nothing but the instructions (e.g. a picture that could not be decoded), still send a sensible question.
        boolean hasContent = false;
        for (Messages.Msg m : req.messages) if (m.role != Messages.ROLE_SYSTEM) hasContent = true;
        if (!hasContent) {
            Messages.Msg u = new Messages.Msg();
            u.role = Messages.ROLE_USER;
            u.text = req.skippedNonText > 0
                    ? "The selected content is a picture that could not be shown. Suggest the most broadly useful chips for a picture."
                    : "Suggest the most broadly useful chips.";
            req.messages.add(u);
        }
        final boolean chips = Chips.wanted(req.messages);
        int chars = 0, images = 0;
        for (Messages.Msg m : req.messages) {
            if (m.text != null) chars += m.text.length();
            if (m.image != null) images++;
        }
        final Config cfg = Settings.load();
        Log.i(TAG, "inference: " + req.messages.size() + " messages, " + chars + " chars, " + images + " image(s), "
                + req.skippedNonText + " part(s) ignored, maxTokens=" + req.maxTokens + ", provider "
                + (cfg.problem() == null ? cfg.host() + " model " + cfg.model : "NOT CONFIGURED (" + cfg.problem() + ")"));
        pool.execute(() -> {
            long t0 = System.currentTimeMillis();
            try {
                String out = Api.chat(req, cfg, cancelled, conn);
                if (cancelled.get()) return;
                if (chips) out = Chips.normalize(out);
                Log.i(TAG, "inference done in " + (System.currentTimeMillis() - t0) + " ms, " + out.length() + " chars: "
                        + (out.length() > 120 ? out.substring(0, 120) + "..." : out).replace('\n', '|'));
                succeed(cb, withInfo, out);
            } catch (Throwable t) {
                if (cancelled.get()) return;
                Log.e(TAG, "inference failed after " + (System.currentTimeMillis() - t0) + " ms: " + t);
                fail(cb, withInfo, errorCode(t), String.valueOf(t));
            }
        });
        return cancelBinder(cancelled, conn);
    }

    /** What AICore's clients are told: wrong key, quota/cap, bad request, provider trouble, or "not available" (no network / not set up). */
    static int errorCode(Throwable t) {
        if (!(t instanceof Api.ApiException)) return ERR_INTERNAL;
        int s = ((Api.ApiException) t).status;
        if (s == 401 || s == 403) return ERR_PERMISSION_DENIED;
        if (s == 429) return ERR_RESOURCE_EXHAUSTED;
        if (s == 400 || s == 404 || s == 413 || s == 422) return ERR_BAD_REQUEST;
        if (s >= 500) return ERR_SERVICE_PROCESSING;
        return ERR_NOT_AVAILABLE;
    }

    private IBinder prepare(IBinder cb) {
        final AtomicBoolean cancelled = new AtomicBoolean();
        pool.execute(() -> {
            String problem = Settings.load().problem();
            if (cancelled.get() || cb == null) return;
            if (problem == null) {
                oneway(cb, PREPARE_CB, 2 /* onPreparationSuccess */, null);
            } else {
                Log.w(TAG, "prepareInferenceEngine: API not usable: " + problem);
                oneway(cb, PREPARE_CB, 3 /* onPreparationFailure(int) */, p -> p.writeInt(ERR_NOT_AVAILABLE));
            }
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

    /** gPointer's picture (a Bitmap parcelable) as a JPEG data: URI, shrunk so the upload stays small and quick. Null if it can't be read. */
    static String bitmapToDataUri(Parcel p) {
        try {
            Bitmap bm = Bitmap.CREATOR.createFromParcel(p);
            if (bm == null) return null;
            if (bm.getConfig() == Bitmap.Config.HARDWARE) bm = bm.copy(Bitmap.Config.ARGB_8888, false);
            int w = bm.getWidth(), h = bm.getHeight(), max = Math.max(w, h);
            if (max > IMAGE_MAX_SIDE) {
                float s = (float) IMAGE_MAX_SIDE / max;
                bm = Bitmap.createScaledBitmap(bm, Math.max(1, Math.round(w * s)), Math.max(1, Math.round(h * s)), true);
            }
            ByteArrayOutputStream o = new ByteArrayOutputStream();
            if (!bm.compress(Bitmap.CompressFormat.JPEG, 85, o)) return null;
            return "data:image/jpeg;base64," + Base64.encodeToString(o.toByteArray(), Base64.NO_WRAP);
        } catch (RuntimeException e) {
            Log.w(TAG, "could not read a picture from the request: " + e);
            return null;
        }
    }
}
