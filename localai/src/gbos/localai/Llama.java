package gbos.localai;

import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;

/** Talks to the llama-server that init starts (gbos_llama in hook.sh) on 127.0.0.1. */
final class Llama {
    static final String TAG = "gbos-localai";
    private static final String BASE = "http://127.0.0.1:8089";
    /** Chips are a few short lines; keep a generous cap but stay well inside gPointer's 240 s budget on a slow CPU. */
    private static final int DEFAULT_MAX_TOKENS = 256;
    private static final int MAX_TOKENS_CEILING = 768;

    private Llama() {}

    /** Blocks until the server answers /health with 200 (it returns 503 while the model loads). */
    static boolean waitReady(AtomicBoolean cancelled, long timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline && !cancelled.get()) {
            HttpURLConnection c = null;
            try {
                c = (HttpURLConnection) new URL(BASE + "/health").openConnection();
                c.setConnectTimeout(2000);
                c.setReadTimeout(5000);
                if (c.getResponseCode() == 200) return true;
            } catch (IOException e) {
                // not up yet
            } finally {
                if (c != null) c.disconnect();
            }
            try {
                Thread.sleep(1500);
            } catch (InterruptedException e) {
                return false;
            }
        }
        return false;
    }

    /** One chat completion. {@code conn[0]} is set so a cancel can abort the request. */
    static String chat(Messages.Request r, AtomicBoolean cancelled, HttpURLConnection[] conn) throws IOException {
        try {
            return post(r, false, cancelled, conn);
        } catch (HttpError e) {
            // Some chat templates reject a system turn: retry with it folded into the first user turn.
            if (e.code >= 400 && e.code < 500 && hasSystem(r)) {
                Log.w(TAG, "chat template rejected the system role (" + e.code + "), retrying folded");
                return post(r, true, cancelled, conn);
            }
            throw e;
        }
    }

    private static boolean hasSystem(Messages.Request r) {
        for (Messages.Msg m : r.messages) if (m.role == Messages.ROLE_SYSTEM) return true;
        return false;
    }

    private static String post(Messages.Request r, boolean foldSystem, AtomicBoolean cancelled, HttpURLConnection[] conn)
            throws IOException {
        try {
            JSONObject body = new JSONObject();
            JSONArray msgs = new JSONArray();
            StringBuilder sys = new StringBuilder();
            for (Messages.Msg m : r.messages) {
                String role = m.role == Messages.ROLE_MODEL ? "assistant" : m.role == Messages.ROLE_SYSTEM ? "system" : "user";
                if (foldSystem && m.role == Messages.ROLE_SYSTEM) {
                    sys.append(m.text).append("\n\n");
                    continue;
                }
                String text = m.text;
                if (foldSystem && sys.length() > 0 && "user".equals(role)) {
                    text = sys + text;
                    sys.setLength(0);
                }
                msgs.put(new JSONObject().put("role", role).put("content", text));
            }
            body.put("messages", msgs);
            body.put("stream", false);
            body.put("cache_prompt", true);
            int max = r.maxTokens > 0 ? Math.min(r.maxTokens, MAX_TOKENS_CEILING) : DEFAULT_MAX_TOKENS;
            body.put("max_tokens", max);
            if (r.temperature >= 0) body.put("temperature", r.temperature);
            if (r.topK > 0) body.put("top_k", r.topK);
            if (r.topP > 0 && r.topP <= 1) body.put("top_p", r.topP);
            if (!r.stops.isEmpty()) body.put("stop", new JSONArray(r.stops));
            byte[] out = body.toString().getBytes(StandardCharsets.UTF_8);

            HttpURLConnection c = (HttpURLConnection) new URL(BASE + "/v1/chat/completions").openConnection();
            conn[0] = c;
            c.setRequestMethod("POST");
            c.setDoOutput(true);
            c.setConnectTimeout(5000);
            c.setReadTimeout(235000);
            c.setRequestProperty("Content-Type", "application/json");
            try (OutputStream os = c.getOutputStream()) {
                os.write(out);
            }
            int code = c.getResponseCode();
            if (cancelled.get()) throw new IOException("cancelled");
            InputStream in = code < 400 ? c.getInputStream() : c.getErrorStream();
            String resp = in == null ? "" : slurp(in);
            if (code >= 400) throw new HttpError(code, resp);
            JSONObject msg = new JSONObject(resp).getJSONArray("choices").getJSONObject(0).getJSONObject("message");
            String content = msg.optString("content", "");
            return content == null ? "" : content.trim();
        } catch (org.json.JSONException e) {
            throw new IOException("bad response: " + e.getMessage(), e);
        }
    }

    private static String slurp(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
        return b.toString("UTF-8");
    }

    static final class HttpError extends IOException {
        final int code;

        HttpError(int code, String body) {
            super("llama-server HTTP " + code + ": " + (body.length() > 300 ? body.substring(0, 300) : body));
            this.code = code;
        }
    }
}
