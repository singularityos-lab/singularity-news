namespace Singularity.Apps.News {

    public enum MuteKind {
        CONTAINS,
        WORD,
        REGEX;

        public string prefix () {
            switch (this) {
                case WORD: return "word:";
                case REGEX: return "regex:";
                default: return "text:";
            }
        }
    }

    public class MuteRule : Object {
        public string pattern = "";
        public MuteKind kind = MuteKind.CONTAINS;
        private string folded = "";
        private Regex? regex;

        public MuteRule (string pattern, MuteKind kind) {
            this.pattern = pattern.strip ();
            this.kind = kind;
            folded = this.pattern.casefold ();
            if (kind == MuteKind.REGEX) {
                try {
                    regex = new Regex (this.pattern, RegexCompileFlags.CASELESS | RegexCompileFlags.OPTIMIZE);
                } catch (RegexError e) {
                    regex = null;
                }
            }
        }

        public static MuteRule? parse (string entry) {
            MuteKind kind = MuteKind.CONTAINS;
            string body = entry;
            if (entry.has_prefix ("word:")) {
                kind = MuteKind.WORD;
                body = entry.substring (5);
            } else if (entry.has_prefix ("regex:")) {
                kind = MuteKind.REGEX;
                body = entry.substring (6);
            } else if (entry.has_prefix ("text:")) {
                body = entry.substring (5);
            }
            if (body.strip () == "") return null;
            return new MuteRule (body, kind);
        }

        public string serialize () {
            return kind.prefix () + pattern;
        }

        public bool valid {
            get { return pattern != "" && (kind != MuteKind.REGEX || regex != null); }
        }

        public static string? regex_problem (string pattern) {
            try {
                new Regex (pattern, RegexCompileFlags.CASELESS);
                return null;
            } catch (RegexError e) {
                return e.message;
            }
        }

        private static bool word_char (unichar c) {
            return c.isalnum () || c == '_';
        }

        public bool matches (string text, string folded_text) {
            if (!valid) return false;
            switch (kind) {
                case MuteKind.REGEX:
                    return regex.match (text);
                case MuteKind.WORD:
                    int from = 0;
                    while (true) {
                        int at = folded_text.index_of (folded, from);
                        if (at < 0) return false;
                        int end = at + folded.length;
                        bool left = true;
                        if (at > 0) {
                            int p = at;
                            unichar before;
                            folded_text.get_prev_char (ref p, out before);
                            left = !word_char (before);
                        }
                        bool right = end >= folded_text.length || !word_char (folded_text.get_char (end));
                        if (left && right) return true;
                        from = at + folded_text.get_char (at).to_string ().length;
                    }
                default:
                    return folded_text.contains (folded);
            }
        }

        public string describe () {
            switch (kind) {
                case MuteKind.WORD: return _("Whole word");
                case MuteKind.REGEX: return _("Regular expression");
                default: return _("Contains");
            }
        }
    }

    public class MuteList : Object {
        public Gee.List<MuteRule> rules = new Gee.ArrayList<MuteRule> ();

        public MuteList () {
        }

        public MuteList.from_strv (string[] entries) {
            foreach (string e in entries) {
                var r = MuteRule.parse (e);
                if (r != null && !contains (r)) rules.add (r);
            }
        }

        public bool contains (MuteRule rule) {
            foreach (var r in rules) if (r.kind == rule.kind && r.pattern.casefold () == rule.pattern.casefold ()) return true;
            return false;
        }

        public bool is_empty {
            get { return rules.size == 0; }
        }

        public string[] to_strv () {
            string[] out_v = {};
            foreach (var r in rules) out_v += r.serialize ();
            return out_v;
        }

        public MuteRule? match_text (string text) {
            if (rules.size == 0) return null;
            string folded = text.casefold ();
            foreach (var r in rules) if (r.matches (text, folded)) return r;
            return null;
        }

        public MuteRule? match (Article a) {
            if (rules.size == 0) return null;
            return match_text (a.muting_text);
        }
    }
}
