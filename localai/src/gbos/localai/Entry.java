package gbos.localai;

import android.os.IBinder;

/** Public doorway from the two service classes (which must live in the AICore package) into this package. */
public final class Entry {
    private Entry() {}

    public static IBinder provider() {
        return ProviderBinder.INSTANCE;
    }

    public static IBinder core() {
        return CoreBinder.INSTANCE;
    }
}
