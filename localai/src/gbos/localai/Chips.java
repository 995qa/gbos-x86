package gbos.localai;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Repairs the "suggestion chip" reply format. gPointer splits the reply on newlines and then each line on a tab:
 * {@code chip text<TAB>TOOL}, one chip per line, where TOOL is one of the tokens below. A small model usually gets
 * that right but sometimes separates chips with a space, adds bullets or code fences. Only applied when the request
 * itself asked for tool-tagged chips (its instructions mention the NO_TOOL token); anything else passes through.
 */
final class Chips {
    private Chips() {}

    private static final String SAFETY = "INVALID_DUE_TO_SAFETY_REASONS";
    private static final Pattern TAGGED = Pattern.compile(
            "(.+?)\\s*\\b(NO_TOOL|IMAGE_GENERATION|VIDEO_GENERATION|MUSIC_GENERATION|DEEP_RESEARCH)\\b", Pattern.DOTALL);
    private static final int MAX_CHIPS = 3;

    /** True if the request is one that wants tool-tagged chips. */
    static boolean wanted(List<Messages.Msg> messages) {
        for (Messages.Msg m : messages) if (m.text != null && m.text.contains("NO_TOOL")) return true;
        return false;
    }

    static String normalize(String reply) {
        if (reply == null) return "";
        if (reply.contains(SAFETY)) return SAFETY;
        String s = reply.replace("```", " ").replace("\\t", "\t");
        List<String> out = new ArrayList<>();
        Matcher m = TAGGED.matcher(s);
        int end = 0;
        while (out.size() < MAX_CHIPS && m.find()) {
            String chip = clean(m.group(1));
            if (!chip.isEmpty()) out.add(chip + "\t" + m.group(2));
            end = m.end();
        }
        if (!out.isEmpty() && out.size() < MAX_CHIPS) { // a last chip the model left untagged
            String rest = clean(s.substring(end));
            if (!rest.isEmpty()) out.add(rest + "\tNO_TOOL");
        }
        if (out.isEmpty()) { // no tool tokens at all: treat each line as a chip
            for (String line : s.split("\n")) {
                String chip = clean(line);
                if (!chip.isEmpty() && out.size() < MAX_CHIPS) out.add(chip + "\tNO_TOOL");
            }
        }
        if (out.isEmpty()) return reply.trim();
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < out.size(); i++) b.append(i == 0 ? "" : "\n").append(out.get(i));
        return b.toString();
    }

    /** One chip's text: no bullets/numbering/quotes, tabs and newlines collapsed to single spaces. */
    private static String clean(String t) {
        String c = t.replaceAll("[\\t\\r\\n ]+", " ").trim();
        c = c.replaceFirst("^(?:[-*•]+|\\d+[.)])\\s+", "");
        c = c.replaceAll("^[\"'“‘]+|[\"'”’]+$", "").trim();
        return c;
    }
}
