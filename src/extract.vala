namespace Singularity.Apps.News.Extract {

    private const string[] REMOVED = {
        "script", "style", "noscript", "template", "form", "button", "input", "select", "textarea", "label",
        "nav", "aside", "footer", "svg", "canvas", "dialog", "link", "meta", "object", "embed", "head", "title", "menu"
    };

    private const string[] NOISE = {
        "comment", "share", "sharing", "social", "related", "sidebar", "footer", "masthead", "navbar", "navigation",
        "menu", "promo", "advert", "ad-slot", "ads-", "sponsor", "newsletter", "subscribe", "signup", "sign-up",
        "cookie", "consent", "banner", "popup", "modal", "breadcrumb", "tag-list", "tags", "widget", "recommend",
        "paywall", "toolbar", "pagination", "pager", "skip-link", "author-box", "more-stories", "trending", "outbrain", "taboola"
    };

    private const string[] SIGNAL = {
        "article", "content", "entry", "post-body", "post-content", "story", "body", "text", "main", "prose", "column"
    };

    private const string[] BLOCK_TAGS = {
        "p", "div", "section", "article", "main", "blockquote", "pre", "ul", "ol", "li", "table", "figure",
        "h1", "h2", "h3", "h4", "h5", "h6", "dl", "header", "hr", "tbody", "tr", "td"
    };

    private const string[] ELLIPSES = { "…", "...", "[…]", "[...]", "(…)", "(...)" };

    public const int SHORT_TEXT = 400;
    public const int MIN_EXTRACT = 140;

    private bool listed (string[] list, string name) {
        foreach (string s in list) if (s == name) return true;
        return false;
    }

    private string label_of (Xml.Node* n) {
        string cls = n->get_prop ("class") ?? "";
        string id = n->get_prop ("id") ?? "";
        string role = n->get_prop ("role") ?? "";
        return (cls + " " + id + " " + role).down ();
    }

    private bool has_any (string text, string[] words) {
        foreach (string w in words) if (text.contains (w)) return true;
        return false;
    }

    private bool is_noise (Xml.Node* n) {
        string name = n->name.down ();
        if (name == "body" || name == "html" || name == "article" || name == "main") return false;
        string label = label_of (n);
        if (label.strip () == "") return false;
        if (label.contains ("navigation") || label.contains ("complementary") || label.contains ("contentinfo")) return true;
        return has_any (label, NOISE) && !has_any (label, SIGNAL);
    }

    private bool hidden (Xml.Node* n) {
        if (n->get_prop ("hidden") != null) return true;
        if ((n->get_prop ("aria-hidden") ?? "") == "true") return true;
        string style = (n->get_prop ("style") ?? "").down ().replace (" ", "");
        return style.contains ("display:none") || style.contains ("visibility:hidden");
    }

    private void prune (Xml.Node* n) {
        Xml.Node* c = n->children;
        while (c != null) {
            Xml.Node* next = c->next;
            if (c->type == Xml.ElementType.COMMENT_NODE) {
                c->unlink ();
                delete c;
            } else if (c->type == Xml.ElementType.ELEMENT_NODE) {
                string name = c->name.down ();
                if (listed (REMOVED, name) || hidden (c) || is_noise (c)) {
                    c->unlink ();
                    delete c;
                } else {
                    prune (c);
                }
            }
            c = next;
        }
    }

    private string squeeze (string raw) {
        var sb = new StringBuilder ();
        bool space = false;
        unichar ch;
        int i = 0;
        while (raw.get_next_char (ref i, out ch)) {
            if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == 0xA0) {
                space = true;
                continue;
            }
            if (space && sb.len > 0) sb.append_c (' ');
            space = false;
            sb.append_unichar (ch);
        }
        return sb.str;
    }

    private int text_length (Xml.Node* n) {
        return squeeze (n->get_content () ?? "").char_count ();
    }

    private int link_length (Xml.Node* n) {
        int total = 0;
        for (Xml.Node* c = n->children; c != null; c = c->next) {
            if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
            if (c->name.down () == "a") total += text_length (c);
            else total += link_length (c);
        }
        return total;
    }

    public double link_density (Xml.Node* n) {
        int len = text_length (n);
        if (len == 0) return 0;
        return double.min (1.0, (double) link_length (n) / len);
    }

    private bool has_block_child (Xml.Node* n) {
        for (Xml.Node* c = n->children; c != null; c = c->next) {
            if (c->type == Xml.ElementType.ELEMENT_NODE && listed (BLOCK_TAGS, c->name.down ())) return true;
        }
        return false;
    }

    private int count_tags (Xml.Node* n) {
        int total = 0;
        for (Xml.Node* c = n->children; c != null; c = c->next) {
            if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
            total += 1 + count_tags (c);
        }
        return total;
    }

    private class Candidate {
        public Xml.Node* node;
        public double score;
    }

    private class Scorer {
        public HashTable<void*, Candidate> table = new HashTable<void*, Candidate> (direct_hash, direct_equal);
        public Gee.ArrayList<Candidate> order = new Gee.ArrayList<Candidate> ();

        public Candidate get_or_add (Xml.Node* n) {
            var c = table.lookup (n);
            if (c != null) return c;
            c = new Candidate ();
            c.node = n;
            c.score = base_score (n);
            table.insert (n, c);
            order.add (c);
            return c;
        }

        private double base_score (Xml.Node* n) {
            double s = 0;
            switch (n->name.down ()) {
                case "article": s = 12; break;
                case "main": s = 8; break;
                case "div": case "section": s = 4; break;
                case "pre": case "td": case "blockquote": s = 3; break;
                case "ul": case "ol": case "dl": case "li": case "form": s = -3; break;
                case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": case "th": case "header": s = -5; break;
            }
            string label = label_of (n);
            if (has_any (label, SIGNAL)) s += 20;
            if (has_any (label, NOISE)) s -= 20;
            if ((n->get_prop ("itemprop") ?? "").contains ("articleBody")) s += 30;
            return s;
        }
    }

    private bool is_paragraph (Xml.Node* n) {
        string name = n->name.down ();
        if (name == "p" || name == "pre" || name == "td" || name == "blockquote") return true;
        if (name == "div" || name == "section") return !has_block_child (n);
        return false;
    }

    private void score_paragraphs (Xml.Node* n, Scorer scorer) {
        for (Xml.Node* c = n->children; c != null; c = c->next) {
            if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
            if (is_paragraph (c)) {
                string text = squeeze (c->get_content () ?? "");
                int len = text.char_count ();
                if (len >= 25) {
                    double points = 1;
                    unichar ch;
                    int i = 0;
                    while (text.get_next_char (ref i, out ch)) if (ch == ',' || ch == 0xFF0C || ch == 0x060C) points += 1;
                    points += double.min (len / 100, 3);
                    double density = link_density (c);
                    points *= 1.0 - density;
                    Xml.Node* up = c->parent;
                    double share = 1.0;
                    for (int level = 0; level < 3 && up != null && up->type == Xml.ElementType.ELEMENT_NODE; level++) {
                        scorer.get_or_add (up).score += points * share;
                        share = level == 0 ? 0.5 : share / 1.5;
                        up = up->parent;
                    }
                }
                continue;
            }
            score_paragraphs (c, scorer);
        }
    }

    private Candidate? best (Scorer scorer) {
        Candidate? top = null;
        foreach (var c in scorer.order) {
            double tags = count_tags (c.node) + 1;
            double text = text_length (c.node);
            double density_bonus = double.min (text / tags / 60.0, 1.0);
            c.score = c.score * (1.0 - link_density (c.node)) * (0.75 + 0.25 * density_bonus);
            if (top == null || c.score > top.score) top = c;
        }
        return top;
    }

    private Xml.Node* promote (Candidate top, Scorer scorer) {
        Xml.Node* node = top.node;
        Xml.Node* parent = node->parent;
        int rivals = 0;
        if (parent != null && parent->type == Xml.ElementType.ELEMENT_NODE) {
            for (Xml.Node* s = parent->children; s != null; s = s->next) {
                if (s == node || s->type != Xml.ElementType.ELEMENT_NODE) continue;
                var cand = scorer.table.lookup (s);
                if (cand != null && cand.score >= top.score * 0.6) rivals++;
            }
            string pname = parent->name.down ();
            if (rivals >= 1 && pname != "body" && pname != "html") return parent;
        }
        return node;
    }

    private bool keep_sibling (Xml.Node* s, Candidate top, Scorer scorer) {
        string name = s->name.down ();
        if (name == "figure" || name == "img" || name == "picture") return true;
        var cand = scorer.table.lookup (s);
        double threshold = double.max (10, top.score * 0.25);
        if (cand != null && cand.score >= threshold) return true;
        if (name == "p") {
            int len = text_length (s);
            double density = link_density (s);
            if (len > 80 && density < 0.25) return true;
            string text = squeeze (s->get_content () ?? "");
            if (len > 0 && len <= 80 && density == 0 && (text.has_suffix (".") || text.has_suffix ("!") || text.has_suffix ("?"))) return true;
        }
        return false;
    }

    private bool has_media (Xml.Node* n) {
        for (Xml.Node* c = n->children; c != null; c = c->next) {
            if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
            string name = c->name.down ();
            if (name == "img" || name == "picture" || name == "video" || name == "iframe" || name == "pre") return true;
            if (has_media (c)) return true;
        }
        return false;
    }

    private void drop_title (Xml.Node* n, string title) {
        Xml.Node* c = n->children;
        while (c != null) {
            Xml.Node* next = c->next;
            if (c->type == Xml.ElementType.ELEMENT_NODE) {
                string name = c->name.down ();
                if (name.length == 2 && name[0] == 'h' && name[1] >= '1' && name[1] <= '3') {
                    if (squeeze (c->get_content () ?? "").casefold () == title) {
                        c->unlink ();
                        delete c;
                        return;
                    }
                } else {
                    drop_title (c, title);
                }
            }
            c = next;
        }
    }

    private void tidy (Xml.Node* n) {
        Xml.Node* c = n->children;
        while (c != null) {
            Xml.Node* next = c->next;
            if (c->type == Xml.ElementType.ELEMENT_NODE) {
                string name = c->name.down ();
                bool drop = false;
                if (is_noise (c)) {
                    drop = true;
                } else if (name == "ul" || name == "ol" || name == "div" || name == "section" || name == "table" || name == "dl") {
                    int len = text_length (c);
                    double density = link_density (c);
                    bool media = has_media (c);
                    if (!media && density > 0.5 && len < 600) drop = true;
                    else if (!media && len < 25 && (name == "div" || name == "section")) drop = true;
                }
                if (drop) {
                    c->unlink ();
                    delete c;
                } else {
                    tidy (c);
                }
            }
            c = next;
        }
    }

    private string dump (Xml.Doc* doc, Xml.Node* n) {
        var buf = new Xml.Buffer ();
        buf.node_dump (doc, n, 0, 0);
        return buf.content ();
    }

    private Xml.Node* find_body (Xml.Node* n) {
        for (Xml.Node* c = n; c != null; c = c->next) {
            if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
            if (c->name.down () == "body") return c;
            Xml.Node* inner = find_body (c->children);
            if (inner != null) return inner;
        }
        return null;
    }

    public string article (string html, string title = "") {
        if (html.strip () == "") return "";
        char[] buf = html.to_utf8 ();
        Xml.Doc* doc = global::Html.Doc.read_memory (buf, buf.length, "about:blank", "UTF-8",
            global::Html.ParserOption.RECOVER | global::Html.ParserOption.NOERROR | global::Html.ParserOption.NOWARNING | global::Html.ParserOption.NONET);
        if (doc == null) return "";
        string result = "";
        Xml.Node* root = doc->get_root_element ();
        Xml.Node* body = root != null ? find_body (root) : null;
        if (body == null) body = root;
        if (body != null) {
            prune (body);
            var scorer = new Scorer ();
            score_paragraphs (body, scorer);
            var top = best (scorer);
            if (top != null && top.score > 0) {
                Xml.Node* chosen = promote (top, scorer);
                string wanted = squeeze (title).casefold ();
                if (wanted != "" && chosen->parent != null) drop_title (chosen->parent, wanted);
                var parts = new StringBuilder ("<div>");
                Xml.Node* parent = chosen->parent;
                if (parent != null && parent->type == Xml.ElementType.ELEMENT_NODE && parent != body->parent) {
                    for (Xml.Node* s = parent->children; s != null; s = s->next) {
                        if (s->type != Xml.ElementType.ELEMENT_NODE) continue;
                        if (s == chosen || keep_sibling (s, top, scorer)) {
                            tidy (s);
                            parts.append (dump (doc, s));
                        }
                    }
                } else {
                    tidy (chosen);
                    parts.append (dump (doc, chosen));
                }
                parts.append ("</div>");
                if (HtmlText.plain_text (parts.str).char_count () >= MIN_EXTRACT) result = parts.str;
            }
        }
        delete doc;
        return result;
    }

    public bool is_truncated (string content) {
        string text = HtmlText.plain_text (content).strip ();
        if (text.char_count () < SHORT_TEXT) return true;
        int tail_start = text.index_of_nth_char (int.max (0, text.char_count () - 48));
        string tail = text.substring (tail_start);
        foreach (string e in ELLIPSES) {
            if (text.has_suffix (e)) return true;
            int at = tail.last_index_of (e);
            if (at >= 0) {
                string after = tail.substring (at + e.length).strip ();
                if (after.split (" ").length <= 4) return true;
            }
        }
        return false;
    }

    public bool improves (string extracted, string feed_content) {
        int ext = HtmlText.plain_text (extracted).char_count ();
        int orig = HtmlText.plain_text (feed_content).char_count ();
        return ext >= MIN_EXTRACT && ext > orig + orig / 5 + 40;
    }

    public string charset_of (string content_type, string head) {
        string ct = content_type.down ();
        int at = ct.index_of ("charset=");
        if (at >= 0) return ct.substring (at + 8).split (";")[0].strip ().replace ("\"", "").replace ("'", "");
        string h = head.down ();
        at = h.index_of ("charset=");
        if (at < 0) return "";
        string rest = h.substring (at + 8).strip ();
        if (rest.has_prefix ("\"") || rest.has_prefix ("'")) rest = rest.substring (1);
        var sb = new StringBuilder ();
        for (int i = 0; i < rest.length; i++) {
            char ch = rest[i];
            if (ch.isalnum () || ch == '-' || ch == '_' || ch == ':') sb.append_c (ch);
            else break;
        }
        return sb.str;
    }

    public string decode (Bytes bytes, string content_type) {
        unowned uint8[] data = bytes.get_data ();
        var raw = new StringBuilder.sized (data.length + 1);
        if (data.length > 0) raw.append_len ((string) data, data.length);
        string text = raw.str;
        string head = text.length > 4096 ? text.substring (0, 4096) : text;
        if (!head.validate ()) head = head.make_valid ();
        string charset = charset_of (content_type, head);
        if (charset == "" || charset == "utf-8" || charset == "utf8") {
            if (text.validate ()) return text;
            charset = "windows-1252";
        }
        try {
            return convert (text, text.length, "UTF-8", charset);
        } catch (Error e) {
            return text.make_valid ();
        }
    }
}

namespace Singularity.Apps.News {

    public class FullText : Object {
        private Fetcher fetcher;
        private string dir;
        private Gee.HashMap<string, string> memory = new Gee.HashMap<string, string> ();
        private Gee.HashSet<string> failed = new Gee.HashSet<string> ();
        private Gee.HashMap<string, Gee.List<SourceFuncWrapper>> waiting = new Gee.HashMap<string, Gee.List<SourceFuncWrapper>> ();

        private class SourceFuncWrapper {
            public SourceFunc func;

            public SourceFuncWrapper (owned SourceFunc f) {
                func = (owned) f;
            }
        }

        public FullText (Fetcher fetcher, string? dir = null) {
            this.fetcher = fetcher;
            this.dir = dir ?? Path.build_filename (Environment.get_user_cache_dir (), "singularity-news", "fulltext");
        }

        private string path_for (string link) {
            return Path.build_filename (dir, Checksum.compute_for_string (ChecksumType.SHA1, link) + ".html");
        }

        public string? cached (string link) {
            if (link == "") return null;
            if (memory.has_key (link)) return memory[link];
            string text;
            try {
                if (!FileUtils.get_contents (path_for (link), out text)) return null;
            } catch (Error e) {
                return null;
            }
            memory[link] = text;
            return text;
        }

        public void store (string link, string html) {
            memory[link] = html;
            DirUtils.create_with_parents (dir, 0700);
            try {
                FileUtils.set_contents_full (path_for (link), html, -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning ("Could not cache the full article: %s", e.message);
            }
        }

        public bool has_failed (string link) {
            return failed.contains (link);
        }

        public void forget_failure (string link) {
            failed.remove (link);
        }

        public void prune (int max_age_days) {
            int64 limit = get_real_time () / 1000000 - (int64) max_age_days * 86400;
            try {
                var en = File.new_for_path (dir).enumerate_children (FileAttribute.STANDARD_NAME + "," + FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = en.next_file ()) != null) {
                    var mt = info.get_modification_date_time ();
                    if (mt != null && mt.to_unix () < limit) FileUtils.remove (Path.build_filename (dir, info.get_name ()));
                }
            } catch (Error e) {
            }
        }

        public async string load (string link, string title, Cancellable? cancel) throws Error {
            string? hit = cached (link);
            if (hit != null) return hit;
            if (waiting.has_key (link)) {
                waiting[link].add (new SourceFuncWrapper (load.callback));
                yield;
                hit = cached (link);
                if (hit != null) return hit;
                throw new FeedError.EMPTY (_("The full article could not be found on the page."));
            }
            waiting[link] = new Gee.ArrayList<SourceFuncWrapper> ();
            try {
                var page = yield fetcher.fetch_page (link, cancel);
                string html = Extract.article (page, title);
                if (html == "") {
                    failed.add (link);
                    throw new FeedError.EMPTY (_("The full article could not be found on the page."));
                }
                store (link, html);
                return html;
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                failed.add (link);
                throw e;
            } finally {
                var list = waiting[link];
                waiting.unset (link);
                foreach (var w in list) Idle.add ((owned) w.func);
            }
        }
    }
}
