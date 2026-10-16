package gbos.localai;
public class ChipsTest {
  static int fails = 0;
  static void eq(String name, String in, String want) {
    String got = Chips.normalize(in);
    if (!got.equals(want)) { fails++; System.out.println("FAIL " + name + "\n  got:  " + got.replace("\t","<TAB>").replace("\n","<NL>") + "\n  want: " + want.replace("\t","<TAB>").replace("\n","<NL>")); }
    else System.out.println("ok   " + name);
  }
  public static void main(String[] a) {
    eq("real email (already right)", "Summarize the blockers\tNO_TOOL\nDraft a reply with availability\tNO_TOOL\nSuggest next steps for launch\tNO_TOOL",
       "Summarize the blockers\tNO_TOOL\nDraft a reply with availability\tNO_TOOL\nSuggest next steps for launch\tNO_TOOL");
    eq("real recipe (space joined)", "Order groceries for recipe\tNO_TOOL Draft a simple banana bread recipe\tNO_TOOL Brainstorm similar recipes",
       "Order groceries for recipe\tNO_TOOL\nDraft a simple banana bread recipe\tNO_TOOL\nBrainstorm similar recipes\tNO_TOOL");
    eq("real code (space joined, missing last token)", "Summarize this code function\tNO_TOOL Draft a Python script for Fibonacci\tNO_TOOL Explain how this recursion works",
       "Summarize this code function\tNO_TOOL\nDraft a Python script for Fibonacci\tNO_TOOL\nExplain how this recursion works\tNO_TOOL");
    eq("fenced + bullets", "```\n- Summarize this article\tNO_TOOL\n- Visualize a scene\tIMAGE_GENERATION\n```",
       "Summarize this article\tNO_TOOL\nVisualize a scene\tIMAGE_GENERATION");
    eq("literal backslash-t", "Check flight status\\tNO_TOOL\nCheck terminal\\tNO_TOOL", "Check flight status\tNO_TOOL\nCheck terminal\tNO_TOOL");
    eq("numbered, no tokens", "1. Explain this chart\n2. Summarize the data\n3. Suggest improvements\n4. Extra", 
       "Explain this chart\tNO_TOOL\nSummarize the data\tNO_TOOL\nSuggest improvements\tNO_TOOL");
    eq("max 3", "A\tNO_TOOL\nB\tNO_TOOL\nC\tNO_TOOL\nD\tNO_TOOL", "A\tNO_TOOL\nB\tNO_TOOL\nC\tNO_TOOL");
    eq("safety", "INVALID_DUE_TO_SAFETY_REASONS", "INVALID_DUE_TO_SAFETY_REASONS");
    eq("quoted", "\"Explain this\"\tNO_TOOL", "Explain this\tNO_TOOL");
    eq("empty", "", "");
    System.out.println(fails == 0 ? "ALL PASS" : fails + " FAILED");
    System.exit(fails);
  }
}
