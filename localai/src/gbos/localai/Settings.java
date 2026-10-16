package gbos.localai;

import android.content.Context;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;

/**
 * Reads the API settings the installer wrote (api.conf). prep.sh copies the file into this app's own private folder at boot,
 * readable only by this app; the master copy in /data/gbos-localai is root-only. Read on every request so edits take effect.
 */
final class Settings {
    private static volatile Context context;

    private Settings() {}

    static void attach(Context c) { context = c; }

    static Config load() {
        Context c = context;
        if (c != null) {
            File f = new File(c.createDeviceProtectedStorageContext().getFilesDir(), "api.conf");
            String t = read(f);
            if (t != null) return Config.parse(t);
        }
        String t = read(new File("/data/gbos-localai/api.conf"));
        return Config.parse(t == null ? "" : t);
    }

    private static String read(File f) {
        if (!f.isFile()) return null;
        try (InputStream in = new FileInputStream(f)) {
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[1024];
            int n;
            while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
            return b.toString("UTF-8");
        } catch (IOException | SecurityException e) {
            Log.w(Api.TAG, "cannot read " + f.getPath() + ": " + e.getClass().getSimpleName()); // never the contents
            return null;
        }
    }
}
