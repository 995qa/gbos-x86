package gbos.localai;

import android.os.IBinder;

/** Public doorway from the two service classes (which must live in the AICore package) into this package. */
public final class Entry {
    private Entry() {}

    /** Called by the service classes so the settings file can be found in this app's private storage. */
    public static void attach(android.content.Context c) {
        Settings.attach(c);
    }

    public static IBinder provider() {
        return ProviderBinder.INSTANCE;
    }

    public static IBinder core() {
        return CoreBinder.INSTANCE;
    }
}
