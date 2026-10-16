package gbos.localai;

import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/** Off-device tests for the API client: JSON, settings, request building, reply parsing, the request cap, and a real HTTP round trip. */
public class ApiTest {
    static int fails;
    static void check(String name, boolean ok, String detail) {
        if (!ok) { fails++; System.out.println("FAIL " + name + (detail.isEmpty() ? "" : ": " + detail)); } else System.out.println("ok   " + name);
    }

    static Messages.Msg msg(int role, String text, String image) {
        Messages.Msg m = new Messages.Msg(); m.role = role; m.text = text; m.image = image; return m;
    }

    static Config cfg(String url, String key) {
        return Config.parse("BASE_URL=" + url + "\nMODEL=test-model\nAPI_KEY=" + key + "\nMAX_PER_HOUR=5\n");
    }

    public static void main(String[] a) throws Exception {
        // ---- Json ----
        String tricky = "line1\nline2\t\"q\" \\ é 中 \u0001";
        check("json: quote/parse round trip", tricky.equals(Json.parse(Json.quote(tricky))), "");
        Map<String, Object> o = Json.obj(Json.parse("{\"a\":[1,2.5,true,null,\"x\\u0041\"],\"b\":{\"c\":\"d\"}}"));
        check("json: nested parse", o != null && Json.arr(o.get("a")).size() == 5 && "xA".equals(Json.arr(o.get("a")).get(4)) && "d".equals(Json.obj(o.get("b")).get("c")), String.valueOf(o));
        boolean bad = false; try { Json.parse("{\"a\":"); } catch (IllegalArgumentException e) { bad = true; }
        check("json: truncated input rejected", bad, "");

        // ---- Config ----
        Config c = cfg("https://generativelanguage.googleapis.com/v1beta/openai/", "K");
        check("config: https url ok, trailing slash handled", c.problem() == null && c.chatUrl().equals("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions") && c.host().equals("generativelanguage.googleapis.com"), c.chatUrl() + " " + c.problem());
        check("config: public http rejected", cfg("http://example.com/v1", "K").problem() != null, "");
        check("config: private http accepted (LAN server)", cfg("http://192.168.1.20:8080/v1", "K").problem() == null && cfg("http://localhost:11434/v1", "K").problem() == null, "");
        check("config: one-word LAN hostname accepted over http, public name still refused", cfg("http://ollama-box:11434/v1", "K").problem() == null && cfg("http://api.example.com/v1", "K").problem() != null, "");
        check("config: missing key / model / url reported", Config.parse("BASE_URL=https://x\nMODEL=m\n").problem().contains("API_KEY") && Config.parse("BASE_URL=https://x\nAPI_KEY=k\n").problem().contains("MODEL") && Config.parse("").problem().contains("BASE_URL"), "");
        check("config: comments, spaces, bad cap value", Config.parse("# c\n  BASE_URL = https://x \nMODEL=m\nAPI_KEY=k\nMAX_PER_HOUR=abc\n").problem() == null, "");

        // ---- request body ----
        Messages.Request r = new Messages.Request();
        r.messages.add(msg(Messages.ROLE_SYSTEM, "SYS", null));
        r.messages.add(msg(Messages.ROLE_USER, "with OCR text: 'a'", null));
        r.messages.add(msg(Messages.ROLE_USER, "with OCR text: 'b'", null));
        r.maxTokens = 200; r.temperature = 0.5f; r.topP = 0.9f; r.stops.add("S1");
        Map<String, Object> body = Json.obj(Json.parse(Api.buildBody(r, c)));
        List<Object> ms = Json.arr(body.get("messages"));
        check("body: model, max_tokens, temperature, top_p, stop", "test-model".equals(body.get("model")) && ((Double) body.get("max_tokens")) == 200 && body.get("temperature") != null && body.get("top_p") != null && Json.arr(body.get("stop")).size() == 1, String.valueOf(body.keySet()));
        check("body: consecutive user messages merged (roles alternate)", ms.size() == 2 && "system".equals(Json.obj(ms.get(0)).get("role")) && "with OCR text: 'a'\nwith OCR text: 'b'".equals(Json.obj(ms.get(1)).get("content")), String.valueOf(ms));
        check("body: key is never in the body", !Api.buildBody(r, cfg("https://x", "SECRETKEY123")).contains("SECRETKEY123"), "");

        Messages.Request ri = new Messages.Request();
        ri.messages.add(msg(Messages.ROLE_SYSTEM, "SYS", null));
        ri.messages.add(msg(Messages.ROLE_USER, "look at this", null));
        ri.messages.add(msg(Messages.ROLE_USER, null, "data:image/jpeg;base64,AAAA"));
        List<Object> parts = Json.arr(Json.obj(Json.arr(Json.obj(Json.parse(Api.buildBody(ri, c))).get("messages")).get(1)).get("content"));
        check("body: image becomes an image_url part after the text", parts != null && parts.size() == 2 && "text".equals(Json.obj(parts.get(0)).get("type")) && "image_url".equals(Json.obj(parts.get(1)).get("type")) && "data:image/jpeg;base64,AAAA".equals(Json.obj(Json.obj(parts.get(1)).get("image_url")).get("url")), String.valueOf(parts));
        check("body: default max_tokens when the caller gave none", ((Double) Json.obj(Json.parse(Api.buildBody(ri, c))).get("max_tokens")) == Api.DEFAULT_MAX_TOKENS, "");

        // ---- reply parsing ----
        check("reply: string content", "hi\tNO_TOOL".equals(Api.parseReply("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\" hi\\tNO_TOOL \"}}]}")), "");
        check("reply: array content", "ab".equals(Api.parseReply("{\"choices\":[{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"text\",\"text\":\"b\"}]}}]}")), "");
        boolean empty = false; try { Api.parseReply("{\"choices\":[{\"message\":{\"content\":\"\"},\"finish_reason\":\"length\"}]}"); } catch (Api.ApiException e) { empty = e.getMessage().contains("empty reply") && e.status == 0; }
        check("reply: empty content is an error that names the finish reason", empty, "");
        check("error text: provider message extracted", "API key not valid".equals(Api.errorMessage("{\"error\":{\"code\":400,\"message\":\"API key not valid\"}}")), "");

        // ---- request cap ----
        Api.resetCapForTest();
        boolean a1 = Api.allow(2, 1000), a2 = Api.allow(2, 2000), a3 = Api.allow(2, 3000), a4 = Api.allow(2, 1000 + 3600_001L);
        check("cap: third request in an hour refused, allowed again after an hour", a1 && a2 && !a3 && a4, a1 + " " + a2 + " " + a3 + " " + a4);

        // ---- real HTTP round trip against a fake provider ----
        final AtomicReference<String> seenAuth = new AtomicReference<>(), seenBody = new AtomicReference<>();
        final int[] mode = {200};
        HttpServer srv = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        srv.createContext("/v1/chat/completions", ex -> {
            seenAuth.set(ex.getRequestHeaders().getFirst("Authorization"));
            seenBody.set(new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            String resp = mode[0] == 200 ? "{\"choices\":[{\"message\":{\"content\":\"Summarize\\tNO_TOOL\"}}]}"
                    : "{\"error\":{\"message\":\"bad key SECRETKEY123 echoed\"}}";
            byte[] bytes = resp.getBytes(StandardCharsets.UTF_8);
            ex.sendResponseHeaders(mode[0], bytes.length);
            ex.getResponseBody().write(bytes);
            ex.close();
        });
        srv.start();
        Config live = cfg("http://127.0.0.1:" + srv.getAddress().getPort() + "/v1", "SECRETKEY123");
        Api.resetCapForTest();
        String got = Api.chat(r, live, new AtomicBoolean(), new HttpURLConnection[1]);
        check("http: reply returned", "Summarize\tNO_TOOL".equals(got), got);
        check("http: key sent as a Bearer header, request body is valid JSON with the model", "Bearer SECRETKEY123".equals(seenAuth.get()) && "test-model".equals(Json.obj(Json.parse(seenBody.get())).get("model")), seenAuth.get());
        mode[0] = 401;
        try { Api.chat(r, live, new AtomicBoolean(), new HttpURLConnection[1]); check("http: 401 raises", false, "no exception"); }
        catch (Api.ApiException e) { check("http: 401 -> status 401 (maps to PERMISSION_DENIED)", e.status == 401, String.valueOf(e.status)); }
        srv.stop(0);
        try { Api.chat(r, live, new AtomicBoolean(), new HttpURLConnection[1]); check("http: network down raises", false, "no exception"); }
        catch (Api.ApiException e) { check("http: server down -> status 0 (maps to NOT_AVAILABLE), key not in message", e.status == 0 && !e.getMessage().contains("SECRETKEY123"), e.getMessage()); }
        try { Api.chat(r, cfg("http://example.com/v1", "SECRETKEY123"), new AtomicBoolean(), new HttpURLConnection[1]); check("settings: bad url raises", false, "no exception"); }
        catch (Api.ApiException e) { check("settings: unusable settings never leak the key", e.status == 0 && !e.getMessage().contains("SECRETKEY123"), e.getMessage()); }

        System.out.println(fails == 0 ? "ALL PASS" : fails + " FAILED");
        System.exit(fails);
    }
}
