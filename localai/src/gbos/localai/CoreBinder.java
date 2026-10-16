package gbos.localai;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.util.Log;

/**
 * The core service (interface IAICoreService). Every feature id is reported as available and served by the one
 * local model; the calls a client makes while setting up (version, feature lookup, status, LLM service) are
 * answered, anything else is refused with an exception so the client sees "not supported".
 */
final class CoreBinder extends Binder {
    static final String DESC = "com.google.android.apps.aicore.aidl.IAICoreService";
    private static final String TAG = Api.TAG;

    /** gPointer needs >= 7 for the Legion (server model) path. */
    static final int API_VERSION = 8;
    private static final int STATUS_AVAILABLE = 3;
    private static final int DEFAULT_FEATURE = 713;

    static final CoreBinder INSTANCE = new CoreBinder();

    private CoreBinder() {}

    @Override
    protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
        if (code < FIRST_CALL_TRANSACTION || code > LAST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags);
        data.enforceInterface(DESC);
        try {
            switch (code) {
                case 11: // getApiVersion()
                    reply.writeNoException();
                    reply.writeInt(API_VERSION);
                    return true;
                case 2: // listFeatures()
                    reply.writeNoException();
                    reply.writeInt(1);
                    reply.writeInt(1);
                    Messages.writeFeature(reply, DEFAULT_FEATURE, 1);
                    return true;
                case 14: { // getFeature(id)
                    int id = data.readInt();
                    Log.i(TAG, "getFeature(" + id + ")");
                    reply.writeNoException();
                    reply.writeInt(1);
                    Messages.writeFeature(reply, id, 1);
                    return true;
                }
                case 32: { // getFeatureOrControl(id, version)
                    int id = data.readInt();
                    int version = data.readInt();
                    Log.i(TAG, "getFeatureOrControl(" + id + ", " + version + ")");
                    reply.writeNoException();
                    reply.writeInt(1);
                    Messages.writeFeature(reply, id, version);
                    return true;
                }
                case 3: // getFeatureStatus(feature)
                    Log.i(TAG, "getFeatureStatus -> AVAILABLE");
                    reply.writeNoException();
                    reply.writeInt(STATUS_AVAILABLE);
                    return true;
                case 13: // isPersistentModeEnabled()
                    reply.writeNoException();
                    reply.writeInt(0);
                    return true;
                case 39: // getClientSideImportanceCutoff(feature)
                    reply.writeNoException();
                    reply.writeInt(0);
                    return true;
                case 33: // initializeSafety(feature, listener): nothing to download
                    reply.writeNoException();
                    return true;
                case 5: // getLLMService(feature)
                case 34: // getLLMLegionService(feature, options)
                    Log.i(TAG, "getLLM" + (code == 34 ? "Legion" : "") + "Service");
                    reply.writeNoException();
                    reply.writeStrongBinder(LlmBinder.INSTANCE);
                    return true;
                default:
                    Log.w(TAG, "IAICoreService: unsupported transaction " + code);
                    reply.writeException(new UnsupportedOperationException("transaction " + code));
                    return true;
            }
        } catch (RuntimeException e) {
            Log.e(TAG, "IAICoreService transaction " + code + " failed", e);
            reply.writeException(new IllegalStateException(e.toString()));
            return true;
        }
    }

    /** What the multi-user service hands back through the provider callback. */
    static IBinder binder() {
        return INSTANCE;
    }
}
