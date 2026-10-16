package gbos.localai;

/**
 * The API settings the installer writes on the laptop: BASE_URL (an OpenAI-compatible chat API, e.g.
 * https://generativelanguage.googleapis.com/v1beta/openai), MODEL, API_KEY and MAX_PER_HOUR, as KEY=VALUE lines.
 * The key is never logged or included in an error message.
 */
final class Config {
    String baseUrl = "", model = "", apiKey = "";
    int maxPerHour = 120;

    static Config parse(String text) {
        Config c = new Config();
        for (String line : text.split("\n")) {
            line = line.trim();
            if (line.isEmpty() || line.startsWith("#")) continue;
            int eq = line.indexOf('=');
            if (eq <= 0) continue;
            String k = line.substring(0, eq).trim(), v = line.substring(eq + 1).trim();
            switch (k) {
                case "BASE_URL": c.baseUrl = v; break;
                case "MODEL": c.model = v; break;
                case "API_KEY": c.apiKey = v; break;
                case "MAX_PER_HOUR":
                    try { c.maxPerHour = Math.max(1, Integer.parseInt(v)); } catch (NumberFormatException e) { /* keep default */ }
                    break;
                default: break;
            }
        }
        return c;
    }

    /** Null when usable, else what is wrong (safe to log: never contains the key). */
    String problem() {
        if (baseUrl.isEmpty()) return "BASE_URL is not set";
        if (model.isEmpty()) return "MODEL is not set";
        if (apiKey.isEmpty()) return "API_KEY is not set";
        String host = host();
        if (!baseUrl.startsWith("https://") && !(baseUrl.startsWith("http://") && isPrivateHost(host)))
            return "BASE_URL must use https:// (http:// only for localhost or a private network address)";
        return null;
    }

    String chatUrl() {
        String u = baseUrl;
        while (u.endsWith("/")) u = u.substring(0, u.length() - 1);
        return u + "/chat/completions";
    }

    /** Host part of BASE_URL, for logging which provider is used. */
    String host() {
        String u = baseUrl;
        int s = u.indexOf("://");
        if (s >= 0) u = u.substring(s + 3);
        int e = u.length();
        for (char ch : new char[] {'/', ':', '?'}) { int k = u.indexOf(ch); if (k >= 0 && k < e) e = k; }
        return u.substring(0, e);
    }

    static boolean isPrivateHost(String h) {
        return h.equals("localhost") || h.startsWith("127.") || h.startsWith("10.") || h.startsWith("192.168.")
                || h.matches("172\\.(1[6-9]|2[0-9]|3[01])\\..*") || h.endsWith(".local")
                || (!h.isEmpty() && h.indexOf('.') < 0 && h.indexOf(':') < 0);   // a one-word name, as used on a home network
    }
}
