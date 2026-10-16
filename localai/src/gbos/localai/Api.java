package gbos.localai;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/** Calls an OpenAI-compatible chat-completions API with the user's own key (see {@link Config}). Plain Java, so it is testable off-device. */
final class Api {
    static final String TAG = "gbos-localai";
    static final int DEFAULT_MAX_TOKENS = 1024, MAX_TOKENS_CEILING = 4096;

    private Api() {}

    /** status = HTTP status, 0 when there was no HTTP answer (settings problem, network down, empty reply). */
    static final class ApiException extends IOException {
        final int status;

        ApiException(int status, String message, Throwable cause) {
            super(message, cause);
            this.status = status;
        }
    }

    // ---- request cap: Magic Pointer fires a request per selection, so protect the user's quota ----

    private static final List<Long> stamps = new ArrayList<>();

    /** True and records the request if fewer than {@code maxPerHour} were made in the last hour. */
    static synchronized boolean allow(int maxPerHour, long nowMs) {
        while (!stamps.isEmpty() && nowMs - stamps.get(0) > 3600_000L) stamps.remove(0);
        if (stamps.size() >= maxPerHour) return false;
        stamps.add(nowMs);
        return true;
    }

    static synchronized void resetCapForTest() { stamps.clear(); }

    // ---- request body ----

    private static String roleName(int role) {
        return role == Messages.ROLE_MODEL ? "assistant" : role == Messages.ROLE_SYSTEM ? "system" : "user";
    }

    /** Chat templates and APIs want roles to alternate, so consecutive messages of one role (gPointer sends one per selected area) are merged. */
    static String buildBody(Messages.Request r, Config c) {
        List<String> roles = new ArrayList<>();
        List<List<Messages.Msg>> groups = new ArrayList<>();
        for (Messages.Msg m : r.messages) {
            String role = roleName(m.role);
            int last = roles.size() - 1;
            if (last >= 0 && roles.get(last).equals(role)) {
                groups.get(last).add(m);
            } else {
                roles.add(role);
                List<Messages.Msg> g = new ArrayList<>();
                g.add(m);
                groups.add(g);
            }
        }
        StringBuilder b = new StringBuilder("{\"model\":").append(Json.quote(c.model)).append(",\"messages\":[");
        for (int gi = 0; gi < groups.size(); gi++) {
            if (gi > 0) b.append(',');
            List<Messages.Msg> g = groups.get(gi);
            boolean hasImage = false;
            for (Messages.Msg m : g) if (m.image != null) hasImage = true;
            b.append("{\"role\":").append(Json.quote(roles.get(gi))).append(",\"content\":");
            if (!hasImage) {
                StringBuilder t = new StringBuilder();
                for (Messages.Msg m : g) {
                    if (m.text == null || m.text.isEmpty()) continue;
                    if (t.length() > 0) t.append('\n');
                    t.append(m.text);
                }
                b.append(Json.quote(t.toString()));
            } else {
                b.append('[');
                boolean first = true;
                for (Messages.Msg m : g) {
                    if (m.text != null && !m.text.isEmpty()) {
                        if (!first) b.append(',');
                        b.append("{\"type\":\"text\",\"text\":").append(Json.quote(m.text)).append('}');
                        first = false;
                    }
                    if (m.image != null) {
                        if (!first) b.append(',');
                        b.append("{\"type\":\"image_url\",\"image_url\":{\"url\":").append(Json.quote(m.image)).append("}}");
                        first = false;
                    }
                }
                b.append(']');
            }
            b.append('}');
        }
        int max = r.maxTokens > 0 ? Math.min(r.maxTokens, MAX_TOKENS_CEILING) : DEFAULT_MAX_TOKENS;
        b.append("],\"stream\":false,\"max_tokens\":").append(max);
        if (r.temperature >= 0) b.append(",\"temperature\":").append(r.temperature);
        if (r.topP > 0 && r.topP <= 1) b.append(",\"top_p\":").append(r.topP);
        if (!r.stops.isEmpty()) {
            b.append(",\"stop\":[");
            for (int i = 0; i < Math.min(4, r.stops.size()); i++) {
                if (i > 0) b.append(',');
                b.append(Json.quote(r.stops.get(i)));
            }
            b.append(']');
        }
        return b.append('}').toString();
    }

    // ---- reply ----

    static String parseReply(String body) throws ApiException {
        try {
            Map<String, Object> top = Json.obj(Json.parse(body));
            List<Object> choices = top == null ? null : Json.arr(top.get("choices"));
            Map<String, Object> choice = choices == null || choices.isEmpty() ? null : Json.obj(choices.get(0));
            Map<String, Object> message = choice == null ? null : Json.obj(choice.get("message"));
            if (message == null) throw new ApiException(0, "reply has no choices[0].message", null);
            Object content = message.get("content");
            StringBuilder out = new StringBuilder();
            if (content instanceof String) {
                out.append((String) content);
            } else if (Json.arr(content) != null) {
                for (Object part : Json.arr(content)) {
                    Map<String, Object> pm = Json.obj(part);
                    if (pm != null && pm.get("text") instanceof String) out.append((String) pm.get("text"));
                }
            }
            String text = out.toString().trim();
            if (text.isEmpty()) throw new ApiException(0, "empty reply (finish_reason=" + choice.get("finish_reason") + ")", null);
            return text;
        } catch (IllegalArgumentException e) {
            throw new ApiException(0, "reply is not valid JSON: " + e.getMessage(), e);
        }
    }

    /** The provider's own error text from a failed call, trimmed. */
    static String errorMessage(String body) {
        try {
            Map<String, Object> top = Json.obj(Json.parse(body));
            Map<String, Object> err = top == null ? null : Json.obj(top.get("error"));
            if (err != null && err.get("message") instanceof String) return trim((String) err.get("message"));
        } catch (IllegalArgumentException e) {
            // not JSON: fall through
        }
        return trim(body);
    }

    private static String trim(String s) {
        s = s.replace('\n', ' ').trim();
        return s.length() > 240 ? s.substring(0, 240) + "..." : s;
    }

    // ---- the call ----

    /** One chat completion. {@code conn[0]} is set so a cancel can abort the request. The key is only ever sent in the Authorization header. */
    static String chat(Messages.Request r, Config c, AtomicBoolean cancelled, HttpURLConnection[] conn) throws IOException {
        String problem = c.problem();
        if (problem != null) throw new ApiException(0, "API settings: " + problem, null);
        if (!allow(c.maxPerHour, System.currentTimeMillis()))
            throw new ApiException(429, "request cap reached (" + c.maxPerHour + " per hour, MAX_PER_HOUR in api.conf)", null);
        byte[] out = buildBody(r, c).getBytes(StandardCharsets.UTF_8);
        HttpURLConnection h = (HttpURLConnection) new URL(c.chatUrl()).openConnection();
        conn[0] = h;
        try {
            h.setRequestMethod("POST");
            h.setDoOutput(true);
            h.setConnectTimeout(15000);
            h.setReadTimeout(120000);
            h.setRequestProperty("Content-Type", "application/json");
            h.setRequestProperty("Authorization", "Bearer " + c.apiKey);
            h.setFixedLengthStreamingMode(out.length);
            try (OutputStream os = h.getOutputStream()) {
                os.write(out);
            }
            int code = h.getResponseCode();
            if (cancelled.get()) throw new IOException("cancelled");
            InputStream in = code < 400 ? h.getInputStream() : h.getErrorStream();
            String resp = in == null ? "" : slurp(in);
            if (code >= 400) throw new ApiException(code, "HTTP " + code + ": " + errorMessage(resp), null);
            return parseReply(resp);
        } catch (ApiException e) {
            throw e;
        } catch (IOException e) {
            if (cancelled.get()) throw e;
            throw new ApiException(0, "network: " + e.getClass().getSimpleName() + ": " + e.getMessage(), e);
        } finally {
            h.disconnect();
        }
    }

    private static String slurp(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
        return b.toString("UTF-8");
    }
}
