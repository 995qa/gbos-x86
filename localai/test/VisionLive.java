package gbos.localai;

import java.net.HttpURLConnection;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Base64;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * MANUAL live check of the picture path (not part of test.sh: needs a server). Sends gPointer's real instruction prompt plus a
 * JPEG as an image_url data URI, exactly as LlmBinder builds it, through the real Api client to any OpenAI-compatible server that
 * has vision, then runs the reply through Chips like the service does.
 * Usage: VisionLive BASE_URL MODEL KEY IMAGE.jpg PROMPT.txt
 */
public class VisionLive {
    public static void main(String[] a) throws Exception {
        Config c = Config.parse("BASE_URL=" + a[0] + "\nMODEL=" + a[1] + "\nAPI_KEY=" + a[2] + "\nMAX_PER_HOUR=100\n");
        if (c.problem() != null) { System.out.println("settings problem: " + c.problem()); System.exit(2); }
        String prompt = new String(Files.readAllBytes(Paths.get(a[4])), "UTF-8");
        String uri = "data:image/jpeg;base64," + Base64.getEncoder().encodeToString(Files.readAllBytes(Paths.get(a[3])));
        Messages.Request r = new Messages.Request();
        Messages.Msg sys = new Messages.Msg(); sys.role = Messages.ROLE_SYSTEM; sys.text = prompt; r.messages.add(sys);
        Messages.Msg img = new Messages.Msg(); img.role = Messages.ROLE_USER; img.image = uri; r.messages.add(img);
        long t0 = System.currentTimeMillis();
        String raw = Api.chat(r, c, new AtomicBoolean(), new HttpURLConnection[1]);
        String chips = Chips.wanted(r.messages) ? Chips.normalize(raw) : raw;
        System.out.println("image " + a[3].replaceAll(".*/", "") + " (" + uri.length() / 1024 + " KB as data URI) -> " + (System.currentTimeMillis() - t0) / 1000 + " s");
        System.out.println(chips.replace("\t", "  <TAB>  "));
        boolean ok = chips.split("\n").length >= 1 && chips.contains("\t");
        System.out.println(ok ? "FORMAT OK (chip<TAB>tool lines)" : "FORMAT BAD");
        System.exit(ok ? 0 : 1);
    }
}
