package gbos.localai;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.util.Log;

/** Interface IAiCoreServiceProvider: the multi-user service's entry point; hands the core service to a callback. */
final class ProviderBinder extends Binder {
    static final String DESC = "com.google.android.apps.aicore.aidl.IAiCoreServiceProvider";
    private static final String CALLBACK_DESC = "com.google.android.apps.aicore.aidl.IAiCoreServiceProviderCallback";
    private static final String TAG = Llama.TAG;

    static final ProviderBinder INSTANCE = new ProviderBinder();

    private ProviderBinder() {}

    @Override
    protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
        if (code < FIRST_CALL_TRANSACTION || code > LAST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags);
        data.enforceInterface(DESC);
        switch (code) {
            case 2: // get(callback)
            case 3: // getWithCallerInfo(callerInfo, callback)
                if (code == 3) Wire.skipParcelable(data);
                IBinder cb = data.readStrongBinder();
                Log.i(TAG, "provider: client " + Binder.getCallingUid() + " asks for the core service");
                deliver(cb);
                return true; // oneway: no reply
            default:
                Log.w(TAG, "IAiCoreServiceProvider: unsupported transaction " + code);
                return true;
        }
    }

    private static void deliver(IBinder cb) {
        if (cb == null) return;
        Parcel d = Parcel.obtain();
        try {
            d.writeInterfaceToken(CALLBACK_DESC);
            d.writeStrongBinder(CoreBinder.binder());
            cb.transact(2 /* onServiceProviderSuccess */, d, null, IBinder.FLAG_ONEWAY);
        } catch (RemoteException e) {
            Log.w(TAG, "provider callback failed: " + e);
        } finally {
            d.recycle();
        }
    }
}
