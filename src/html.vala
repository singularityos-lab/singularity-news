namespace Singularity.Apps.News.HtmlText {

    [Flags]
    public enum Style {
        NONE = 0,
        BOLD = 1,
        ITALIC = 2,
        UNDERLINE = 4,
        STRIKE = 8,
        CODE = 16,
        SUP = 32,
        SUB = 64,
        SMALL = 128
    }

    public enum BlockKind {
        PARAGRAPH,
        HEADING,
        PREFORMATTED,
        IMAGE,
        RULE,
        CAPTION
    }

    public class Run : Object {
        public string text;
        public Style style;
        public string href;

        public Run (string text, Style style, string href) {
            this.text = text;
            this.style = style;
            this.href = href;
        }
    }

    public class Block : Object {
        public BlockKind kind = BlockKind.PARAGRAPH;
        public int level;
        public int quote;
        public int indent;
        public string marker = "";
        public string src = "";
        public string alt = "";
        public Gee.List<Run> runs = new Gee.ArrayList<Run> ();

        public string text () {
            var sb = new StringBuilder ();
            foreach (var r in runs) sb.append (r.text);
            return sb.str;
        }

        public string to_markup () {
            var sb = new StringBuilder ();
            foreach (var r in runs) {
                string t = GLib.Markup.escape_text (r.text);
                if ((r.style & Style.CODE) != 0) t = "<tt>" + t + "</tt>";
                if ((r.style & Style.BOLD) != 0) t = "<b>" + t + "</b>";
                if ((r.style & Style.ITALIC) != 0) t = "<i>" + t + "</i>";
                if ((r.style & Style.UNDERLINE) != 0) t = "<u>" + t + "</u>";
                if ((r.style & Style.STRIKE) != 0) t = "<s>" + t + "</s>";
                if ((r.style & Style.SUP) != 0) t = "<sup>" + t + "</sup>";
                if ((r.style & Style.SUB) != 0) t = "<sub>" + t + "</sub>";
                if ((r.style & Style.SMALL) != 0) t = "<small>" + t + "</small>";
                if (r.href != "") t = "<a href=\"" + GLib.Markup.escape_text (r.href) + "\">" + t + "</a>";
                sb.append (t);
            }
            return sb.str;
        }
    }

    private const string[] DROPPED = {
        "script", "style", "noscript", "template", "head", "title", "form", "input", "button", "select",
        "textarea", "object", "embed", "svg", "math", "canvas", "link", "meta", "map", "dialog", "nav"
    };

    private const string[] BLOCKS = {
        "p", "div", "section", "article", "header", "footer", "main", "aside", "figure", "address",
        "center", "details", "summary", "dl", "dt", "dd", "ul", "ol", "li", "table", "tbody", "thead",
        "tfoot", "tr", "caption", "body", "html"
    };

    private bool contains (string[] list, string name) {
        foreach (string s in list) if (s == name) return true;
        return false;
    }

    public bool safe_url (string url) {
        string l = url.down ();
        return l.has_prefix ("http://") || l.has_prefix ("https://") || l.has_prefix ("mailto:");
    }

    private bool is_space (unichar c) {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\x0c';
    }

    private class Builder {
        public Gee.List<Block> blocks = new Gee.ArrayList<Block> ();
        public string base_url;
        public int quote;
        public int list_depth;
        public string pending_marker = "";
        public Gee.ArrayList<int> counters = new Gee.ArrayList<int> ();
        public Gee.ArrayList<bool> ordered = new Gee.ArrayList<bool> ();
        public Block? current;
        public bool space_pending;
        public bool caption;

        public Builder (string base_url) {
            this.base_url = base_url;
        }

        public Block open () {
            if (current == null) {
                current = new Block ();
                current.quote = quote;
                current.indent = list_depth;
                current.marker = pending_marker;
                pending_marker = "";
                if (caption) current.kind = BlockKind.CAPTION;
            }
            return current;
        }

        public void flush () {
            if (current == null) return;
            var b = current;
            current = null;
            space_pending = false;
            while (b.runs.size > 0) {
                var last = b.runs[b.runs.size - 1];
                last.text = last.text.chomp ();                if (last.text != "") break;
                b.runs.remove_at (b.runs.size - 1);
            }
            if (b.runs.size == 0 && b.kind != BlockKind.RULE && b.kind != BlockKind.IMAGE) {
                if (b.marker != "") pending_marker = b.marker;
                return;
            }
            blocks.add (b);
        }

        public void add_block (Block b) {
            flush ();
            b.quote = quote;
            b.indent = list_depth;
            if (b.kind != BlockKind.IMAGE && b.kind != BlockKind.RULE) {
                b.marker = pending_marker;
                pending_marker = "";
            }
            blocks.add (b);
        }

        public void text (string raw, Style style, string href) {
            var sb = new StringBuilder ();
            bool had_content = current != null && current.runs.size > 0 && !current.runs[current.runs.size - 1].text.has_suffix ("\n");
            unichar c;
            int i = 0;
            while (raw.get_next_char (ref i, out c)) {
                if (is_space (c)) {
                    space_pending = true;
                    continue;
                }
                if (space_pending && sb.len > 0) sb.append_c (' ');
                else if (space_pending && had_content) current.runs[current.runs.size - 1].text += " ";
                space_pending = false;
                sb.append_unichar (c);
            }
            if (sb.len == 0) return;
            append (sb.str, style, href);
        }

        public void append (string t, Style style, string href) {
            var b = open ();
            if (b.runs.size > 0) {
                var last = b.runs[b.runs.size - 1];
                if (last.style == style && last.href == href) {
                    last.text += t;
                    return;
                }
            }
            b.runs.add (new Run (t, style, href));
        }

        public void line_break () {
            var b = open ();
            if (b.runs.size == 0) return;
            append ("\n", b.runs[b.runs.size - 1].style, "");
            space_pending = false;
        }
    }

    private Xml.Doc* parse_doc (string html) {
        if (html.strip () == "") return null;
        char[] buf = html.to_utf8 ();
        return global::Html.Doc.read_memory (buf, buf.length, "about:blank", "UTF-8",
            global::Html.ParserOption.RECOVER | global::Html.ParserOption.NOERROR | global::Html.ParserOption.NOWARNING | global::Html.ParserOption.NONET);
    }

    private string attr (Xml.Node* n, string name) {
        string? v = n->get_prop (name);
        return v != null ? v.strip () : "";
    }

    private string image_src (Xml.Node* n, string base_url) {
        string src = attr (n, "src");
        if (src == "" || src.has_prefix ("data:")) {
            string lazy = attr (n, "data-src");
            if (lazy == "") lazy = attr (n, "data-original");
            if (lazy != "") src = lazy;
        }
        if (src == "") return "";
        string abs = FeedParser.resolve (base_url, src);
        string l = abs.down ();
        if (!l.has_prefix ("http://") && !l.has_prefix ("https://")) return "";
        string w = attr (n, "width"), h = attr (n, "height");
        if ((w != "" && int.parse (w) <= 2 && w[0].isdigit ()) || (h != "" && int.parse (h) <= 2 && h[0].isdigit ())) return "";
        return abs;
    }

    private void walk (Builder b, Xml.Node* n, Style style, string href) {
        for (Xml.Node* c = n->children; c != null; c = c->next) {
            if (c->type == Xml.ElementType.TEXT_NODE || c->type == Xml.ElementType.CDATA_SECTION_NODE) {
                b.text (c->content ?? "", style, href);
                continue;
            }
            if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
            string name = c->name.down ();
            if (contains (DROPPED, name)) continue;
            switch (name) {
                case "br":
                    b.line_break ();
                    continue;
                case "hr":
                    var rule = new Block ();
                    rule.kind = BlockKind.RULE;
                    b.add_block (rule);
                    continue;
                case "img":
                    string src = image_src (c, b.base_url);
                    if (src == "") continue;
                    var img = new Block ();
                    img.kind = BlockKind.IMAGE;
                    img.src = src;
                    img.alt = attr (c, "alt");
                    img.runs.add (new Run (img.alt, Style.NONE, href));
                    b.add_block (img);
                    continue;
                case "iframe":
                case "video":
                case "audio":
                    string media = FeedParser.resolve (b.base_url, attr (c, "src"));
                    if (media == "") {
                        for (Xml.Node* s = c->children; s != null && media == ""; s = s->next) {
                            if (s->type == Xml.ElementType.ELEMENT_NODE && s->name.down () == "source") media = FeedParser.resolve (b.base_url, attr (s, "src"));
                        }
                    }
                    if (media != "" && safe_url (media) && !media.down ().has_prefix ("mailto:")) {
                        b.flush ();
                        b.append (name == "audio" ? _("Play audio") : (name == "video" ? _("Play video") : _("Open embedded content")), Style.NONE, media);
                        b.flush ();
                    }
                    continue;
                case "pre":
                    var pre = new Block ();
                    pre.kind = BlockKind.PREFORMATTED;
                    string code = c->get_content ();
                    if (code.has_prefix ("\n")) code = code.substring (1);
                    code = code.chomp ();
                    if (code == "") continue;
                    pre.runs.add (new Run (code, Style.CODE, ""));
                    b.add_block (pre);
                    continue;
                case "h1": case "h2": case "h3": case "h4": case "h5": case "h6":
                    b.flush ();
                    var h = b.open ();
                    h.kind = BlockKind.HEADING;
                    h.level = int.parse (name.substring (1));
                    walk (b, c, style | Style.BOLD, href);
                    b.flush ();
                    continue;
                case "blockquote":
                    b.flush ();
                    b.quote++;
                    walk (b, c, style, href);
                    b.flush ();
                    b.quote--;
                    continue;
                case "ul":
                case "ol":
                    b.flush ();
                    b.list_depth++;
                    b.ordered.add (name == "ol");
                    int start = name == "ol" && attr (c, "start") != "" ? int.parse (attr (c, "start")) : 1;
                    b.counters.add (start);
                    walk (b, c, style, href);
                    b.flush ();
                    b.ordered.remove_at (b.ordered.size - 1);
                    b.counters.remove_at (b.counters.size - 1);
                    b.list_depth--;
                    b.pending_marker = "";
                    continue;
                case "li":
                    b.flush ();
                    if (b.list_depth == 0) {
                        b.pending_marker = "•";
                    } else if (b.ordered[b.ordered.size - 1]) {
                        int k = b.counters[b.counters.size - 1];
                        b.pending_marker = "%d.".printf (k);
                        b.counters[b.counters.size - 1] = k + 1;
                    } else {
                        b.pending_marker = b.list_depth % 2 == 1 ? "•" : "◦";
                    }
                    walk (b, c, style, href);
                    b.flush ();
                    continue;
                case "figcaption":
                    b.flush ();
                    b.caption = true;
                    walk (b, c, style, href);
                    b.flush ();
                    b.caption = false;
                    continue;
                case "td":
                case "th":
                    if (b.current != null && b.current.runs.size > 0) b.append (" | ", Style.NONE, "");
                    b.space_pending = false;
                    walk (b, c, name == "th" ? style | Style.BOLD : style, href);
                    continue;
                case "a":
                    string target = attr (c, "href");
                    string link = target != "" && !target.has_prefix ("#") ? FeedParser.resolve (b.base_url, target) : "";
                    walk (b, c, style, safe_url (link) ? link : href);
                    continue;
                case "b": case "strong":
                    walk (b, c, style | Style.BOLD, href);
                    continue;
                case "i": case "em": case "cite": case "var": case "dfn":
                    walk (b, c, style | Style.ITALIC, href);
                    continue;
                case "u": case "ins":
                    walk (b, c, style | Style.UNDERLINE, href);
                    continue;
                case "s": case "strike": case "del":
                    walk (b, c, style | Style.STRIKE, href);
                    continue;
                case "code": case "kbd": case "samp": case "tt":
                    walk (b, c, style | Style.CODE, href);
                    continue;
                case "sup":
                    walk (b, c, style | Style.SUP, href);
                    continue;
                case "sub":
                    walk (b, c, style | Style.SUB, href);
                    continue;
                case "small":
                    walk (b, c, style | Style.SMALL, href);
                    continue;
            }
            if (contains (BLOCKS, name)) {
                b.flush ();
                walk (b, c, style, href);
                b.flush ();
            } else {
                walk (b, c, style, href);
            }
        }
    }

    public Gee.List<Block> render (string html, string base_url = "") {
        var b = new Builder (base_url);
        Xml.Doc* doc = parse_doc (html);
        if (doc == null) return b.blocks;
        Xml.Node* root = doc->get_root_element ();
        if (root != null) {
            var wrapper = root;
            walk (b, wrapper->parent, Style.NONE, "");
        }
        b.flush ();
        delete doc;
        return b.blocks;
    }

    public string plain_text (string html) {
        if (!html.contains ("<") && !html.contains ("&")) return html.strip ();
        var sb = new StringBuilder ();
        foreach (var block in render (html)) {
            if (block.kind == BlockKind.IMAGE || block.kind == BlockKind.RULE) continue;
            if (sb.len > 0) sb.append_c (' ');
            sb.append (block.text ().replace ("\n", " "));
        }
        return sb.str.strip ();
    }

    public string excerpt (string html, int max_chars) {
        string t = plain_text (html);
        if (t.char_count () <= max_chars) return t;
        string cut = t.substring (0, t.index_of_nth_char (max_chars));
        int sp = cut.last_index_of (" ");
        if (sp > max_chars / 2) cut = cut.substring (0, sp);
        return cut.strip () + "…";
    }

    private string find_image (Xml.Node* n, string base_url) {
        for (Xml.Node* c = n->children; c != null; c = c->next) {
            if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
            string name = c->name.down ();
            if (contains (DROPPED, name)) continue;
            if (name == "img") {
                string src = image_src (c, base_url);
                if (src != "") return src;
                continue;
            }
            string inner = find_image (c, base_url);
            if (inner != "") return inner;
        }
        return "";
    }

    public string first_image (string html, string base_url) {
        if (!html.contains ("<img") && !html.contains ("<IMG")) return "";
        Xml.Doc* doc = parse_doc (html);
        if (doc == null) return "";
        string found = "";
        Xml.Node* root = doc->get_root_element ();
        if (root != null) found = find_image (root, base_url);
        delete doc;
        return found;
    }
}
