namespace Singularity.Apps.News {

    public errordomain FeedError {
        NOT_A_FEED,
        EMPTY,
        NETWORK,
        HTTP
    }

    public class Article : Object {
        public string feed_id = "";
        public string guid = "";
        public string title = "";
        public string link = "";
        public string author = "";
        public string content = "";
        public string thumbnail = "";
        public int64 published;
        public int64 fetched;
        public bool unread { get; set; default = true; }
        public bool starred { get; set; default = false; }
        public string muted { get; set; default = ""; }
        public string source_name = "";

        private string? _excerpt;
        private string? _haystack;
        private string? _muting;

        public string key {
            owned get { return feed_id + "\n" + guid; }
        }

        public string excerpt {
            get {
                if (_excerpt == null) _excerpt = HtmlText.excerpt (content, 220);
                return _excerpt;
            }
        }

        public string muting_text {
            get {
                if (_muting == null) _muting = title + "\n" + author + "\n" + HtmlText.plain_text (content);
                return _muting;
            }
        }

        public bool matches (string query) {
            if (query == "") return true;
            if (_haystack == null) _haystack = (title + "\n" + author + "\n" + HtmlText.plain_text (content)).casefold ();
            foreach (string word in query.casefold ().split (" ")) {
                if (word != "" && !_haystack.contains (word)) return false;
            }
            return true;
        }

        public void set_content (string html) {
            content = html;
            _excerpt = null;
            _haystack = null;
            _muting = null;
        }
    }

    public class ParsedFeed : Object {
        public string kind = "";
        public string title = "";
        public string site_url = "";
        public string description = "";
        public Gee.List<Article> items = new Gee.ArrayList<Article> ();
    }

    namespace FeedParser {
        public const string NS_ATOM = "http://www.w3.org/2005/Atom";
        public const string NS_RSS1 = "http://purl.org/rss/1.0/";
        public const string NS_RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
        public const string NS_DC = "http://purl.org/dc/elements/1.1/";
        public const string NS_CONTENT = "http://purl.org/rss/1.0/modules/content/";
        public const string NS_MEDIA = "http://search.yahoo.com/mrss/";

        public bool looks_like_feed (string data) {
            string head = data.length > 2048 ? data.substring (0, 2048) : data;
            head = head.strip ();
            if (head.has_prefix ("{")) return head.contains ("jsonfeed.org");
            string low = head.down ();
            return low.contains ("<rss") || low.contains ("<rdf:rdf") || low.contains ("<rdf ") || (low.contains ("<feed") && low.contains ("atom"));
        }

        public ParsedFeed parse (string data, string base_url) throws FeedError {
            string text = data.strip ();
            if (text.has_prefix ("\xef\xbb\xbf")) text = text.substring (3);
            if (text.has_prefix ("{")) return parse_json (text, base_url);
            Xml.Doc* doc = Xml.Parser.read_memory (text, text.length, base_url, null,
                Xml.ParserOption.RECOVER | Xml.ParserOption.NONET | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING | Xml.ParserOption.NOCDATA);
            if (doc == null) throw new FeedError.NOT_A_FEED (_("The address does not point to a feed."));
            try {
                Xml.Node* root = doc->get_root_element ();
                if (root == null) throw new FeedError.NOT_A_FEED (_("The address does not point to a feed."));
                string name = root->name.down ();
                ParsedFeed feed;
                if (name == "rss") feed = parse_rss2 (root, base_url);
                else if (name == "rdf") feed = parse_rss1 (root, base_url);
                else if (name == "feed") feed = parse_atom (root, base_url);
                else throw new FeedError.NOT_A_FEED (_("The address does not point to a feed."));
                return feed;
            } finally {
                delete doc;
            }
        }

        private string ns_of (Xml.Node* n) {
            return n->ns != null && n->ns->href != null ? n->ns->href : "";
        }

        private bool is (Xml.Node* n, string local, string? ns) {
            if (n->type != Xml.ElementType.ELEMENT_NODE) return false;
            if (n->name != local) return false;
            return ns == null || ns_of (n) == ns;
        }

        private Xml.Node* child (Xml.Node* parent, string local, string? ns) {
            for (Xml.Node* c = parent->children; c != null; c = c->next) {
                if (is (c, local, ns)) return c;
            }
            return null;
        }

        private string text_of (Xml.Node* parent, string local, string? ns) {
            Xml.Node* c = child (parent, local, ns);
            return c != null ? c->get_content ().strip () : "";
        }

        private string inner_xml (Xml.Node* n) {
            var sb = new StringBuilder ();
            for (Xml.Node* c = n->children; c != null; c = c->next) {
                var buf = new Xml.Buffer ();
                buf.node_dump (n->doc, c, 0, 0);
                sb.append (buf.content ());
            }
            return sb.str;
        }

        public string resolve (string base_url, string href) {
            string h = href.strip ();
            if (h == "") return "";
            if (base_url == "") return h;
            try {
                return Uri.resolve_relative (base_url, h, UriFlags.NONE);
            } catch (Error e) {
                return h;
            }
        }

        public string text_to_html (string text) {
            var sb = new StringBuilder ();
            foreach (string para in text.strip ().split ("\n\n")) {
                if (para.strip () == "") continue;
                sb.append ("<p>");
                sb.append (Markup.escape_text (para.strip ()).replace ("\n", "<br>"));
                sb.append ("</p>");
            }
            return sb.str;
        }

        private string clean_title (string raw) {
            string t = raw.strip ();
            if (t.contains ("<") || t.contains ("&")) t = HtmlText.plain_text (t);
            return t.replace ("\n", " ").strip ();
        }

        private string media_image (Xml.Node* item, string base_url) {
            for (Xml.Node* c = item->children; c != null; c = c->next) {
                if (is (c, "thumbnail", NS_MEDIA)) {
                    string? u = c->get_prop ("url");
                    if (u != null && u != "") return resolve (base_url, u);
                }
            }
            for (Xml.Node* c = item->children; c != null; c = c->next) {
                if (is (c, "group", NS_MEDIA)) {
                    string g = media_image (c, base_url);
                    if (g != "") return g;
                }
                if (is (c, "content", NS_MEDIA)) {
                    string? medium = c->get_prop ("medium");
                    string? type = c->get_prop ("type");
                    string? u = c->get_prop ("url");
                    if (u != null && ((medium != null && medium == "image") || (type != null && type.has_prefix ("image/")))) return resolve (base_url, u);
                    Xml.Node* th = child (c, "thumbnail", NS_MEDIA);
                    if (th != null && th->get_prop ("url") != null) return resolve (base_url, th->get_prop ("url"));
                }
                if (is (c, "enclosure", null)) {
                    string? type = c->get_prop ("type");
                    string? u = c->get_prop ("url");
                    if (u != null && type != null && type.has_prefix ("image/")) return resolve (base_url, u);
                }
            }
            return "";
        }

        private void finish (Article a, string base_url) {
            if (a.guid == "") a.guid = a.link != "" ? a.link : Checksum.compute_for_string (ChecksumType.SHA1, a.title + "\n" + a.published.to_string () + "\n" + a.content);
            if (a.title == "") {
                string ex = HtmlText.excerpt (a.content, 80);
                a.title = ex != "" ? ex : _("Untitled");
            }
            if (a.thumbnail == "") a.thumbnail = HtmlText.first_image (a.content, a.link != "" ? a.link : base_url);
        }

        private ParsedFeed parse_rss2 (Xml.Node* root, string base_url) throws FeedError {
            Xml.Node* channel = child (root, "channel", null);
            if (channel == null) throw new FeedError.NOT_A_FEED (_("The feed has no channel."));
            var feed = new ParsedFeed ();
            feed.kind = "rss";
            feed.title = clean_title (text_of (channel, "title", ""));
            feed.site_url = resolve (base_url, text_of (channel, "link", ""));
            feed.description = clean_title (text_of (channel, "description", ""));
            string item_base = feed.site_url != "" ? feed.site_url : base_url;
            for (Xml.Node* it = channel->children; it != null; it = it->next) {
                if (!is (it, "item", "")) continue;
                feed.items.add (rss_item (it, item_base, ""));
            }
            for (Xml.Node* it = root->children; it != null; it = it->next) {
                if (is (it, "item", "")) feed.items.add (rss_item (it, item_base, ""));
            }
            return feed;
        }

        private Article rss_item (Xml.Node* it, string base_url, string ns) {
            var a = new Article ();
            a.title = clean_title (text_of (it, "title", ns));
            a.link = resolve (base_url, text_of (it, "link", ns));
            Xml.Node* guid = child (it, "guid", ns);
            if (guid != null) {
                a.guid = guid->get_content ().strip ();
                string? perma = guid->get_prop ("isPermaLink");
                if (a.link == "" && (perma == null || perma == "true") && (a.guid.has_prefix ("http://") || a.guid.has_prefix ("https://"))) a.link = a.guid;
            }
            if (a.guid == "") {
                string? about = it->get_ns_prop ("about", NS_RDF);
                if (about != null) a.guid = about;
            }
            string date = text_of (it, "pubDate", ns);
            if (date == "") date = text_of (it, "date", NS_DC);
            a.published = Dates.parse (date);
            a.author = text_of (it, "creator", NS_DC);
            if (a.author == "") a.author = text_of (it, "author", ns);
            string encoded = text_of (it, "encoded", NS_CONTENT);
            string desc = text_of (it, "description", ns);
            a.set_content (encoded != "" ? encoded : desc);
            a.thumbnail = media_image (it, base_url);
            finish (a, base_url);
            return a;
        }

        private ParsedFeed parse_rss1 (Xml.Node* root, string base_url) throws FeedError {
            var feed = new ParsedFeed ();
            feed.kind = "rdf";
            Xml.Node* channel = child (root, "channel", NS_RSS1);
            if (channel == null) channel = child (root, "channel", null);
            if (channel == null) throw new FeedError.NOT_A_FEED (_("The feed has no channel."));
            string ns = ns_of (channel);
            feed.title = clean_title (text_of (channel, "title", ns));
            feed.site_url = resolve (base_url, text_of (channel, "link", ns));
            feed.description = clean_title (text_of (channel, "description", ns));
            string item_base = feed.site_url != "" ? feed.site_url : base_url;
            for (Xml.Node* it = root->children; it != null; it = it->next) {
                if (is (it, "item", ns)) feed.items.add (rss_item (it, item_base, ns));
            }
            return feed;
        }

        private string atom_link (Xml.Node* n, string ns, string base_url) {
            string fallback = "";
            for (Xml.Node* c = n->children; c != null; c = c->next) {
                if (!is (c, "link", ns)) continue;
                string? href = c->get_prop ("href");
                if (href == null) continue;
                string? rel = c->get_prop ("rel");
                if (rel == null || rel == "alternate") {
                    string? type = c->get_prop ("type");
                    if (type == null || type.contains ("html")) return resolve (base_url, href);
                    if (fallback == "") fallback = resolve (base_url, href);
                }
            }
            return fallback;
        }

        private string atom_text (Xml.Node* n, bool as_html) {
            if (n == null) return "";
            string type = n->get_prop ("type") ?? "text";
            if (type == "xhtml") {
                Xml.Node* div = null;
                for (Xml.Node* c = n->children; c != null; c = c->next) {
                    if (c->type == Xml.ElementType.ELEMENT_NODE) {
                        div = c;
                        break;
                    }
                }
                return div != null ? inner_xml (div) : inner_xml (n);
            }
            string raw = n->get_content ();
            if (type == "html" || type == "text/html") return raw.strip ();
            return as_html ? text_to_html (raw) : Markup.escape_text (raw.strip ());
        }

        private string node_base (Xml.Node* n, string base_url) {
            string b = base_url;
            var chain = new Gee.ArrayList<string> ();
            for (Xml.Node* p = n; p != null && p->type == Xml.ElementType.ELEMENT_NODE; p = p->parent) {
                string? xb = p->get_ns_prop ("base", "http://www.w3.org/XML/1998/namespace");
                if (xb != null) chain.insert (0, xb);
            }
            foreach (string x in chain) b = resolve (b, x);
            return b;
        }

        private ParsedFeed parse_atom (Xml.Node* root, string base_url) throws FeedError {
            var feed = new ParsedFeed ();
            feed.kind = "atom";
            string ns = ns_of (root);
            string fbase = node_base (root, base_url);
            feed.title = clean_title (HtmlText.plain_text (atom_text (child (root, "title", ns), false)));
            feed.site_url = atom_link (root, ns, fbase);
            feed.description = clean_title (HtmlText.plain_text (atom_text (child (root, "subtitle", ns), false)));
            string feed_author = "";
            Xml.Node* fa = child (root, "author", ns);
            if (fa != null) feed_author = text_of (fa, "name", ns);
            for (Xml.Node* e = root->children; e != null; e = e->next) {
                if (!is (e, "entry", ns)) continue;
                string ebase = node_base (e, base_url);
                var a = new Article ();
                a.guid = text_of (e, "id", ns);
                a.title = clean_title (HtmlText.plain_text (atom_text (child (e, "title", ns), false)));
                a.link = atom_link (e, ns, ebase);
                string date = text_of (e, "published", ns);
                if (date == "") date = text_of (e, "updated", ns);
                if (date == "") date = text_of (e, "issued", ns);
                a.published = Dates.parse (date);
                Xml.Node* au = child (e, "author", ns);
                a.author = au != null ? text_of (au, "name", ns) : feed_author;
                string body = atom_text (child (e, "content", ns), true);
                if (body.strip () == "") body = atom_text (child (e, "summary", ns), true);
                a.set_content (body);
                a.thumbnail = media_image (e, ebase);
                finish (a, ebase);
                feed.items.add (a);
            }
            return feed;
        }

        private string jstr (Json.Object o, string name) {
            if (!o.has_member (name)) return "";
            var n = o.get_member (name);
            if (n.get_node_type () != Json.NodeType.VALUE || n.get_value_type () != typeof (string)) return "";
            return n.get_string () ?? "";
        }

        private ParsedFeed parse_json (string text, string base_url) throws FeedError {
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (text, -1);
            } catch (Error e) {
                throw new FeedError.NOT_A_FEED (_("The feed is not valid JSON."));
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) throw new FeedError.NOT_A_FEED (_("The address does not point to a feed."));
            var o = root.get_object ();
            if (!jstr (o, "version").contains ("jsonfeed.org")) throw new FeedError.NOT_A_FEED (_("The address does not point to a feed."));
            var feed = new ParsedFeed ();
            feed.kind = "json";
            feed.title = clean_title (jstr (o, "title"));
            feed.site_url = resolve (base_url, jstr (o, "home_page_url"));
            feed.description = jstr (o, "description");
            string feed_author = json_author (o);
            string ibase = feed.site_url != "" ? feed.site_url : base_url;
            if (o.has_member ("items") && o.get_member ("items").get_node_type () == Json.NodeType.ARRAY) {
                foreach (var node in o.get_array_member ("items").get_elements ()) {
                    if (node.get_node_type () != Json.NodeType.OBJECT) continue;
                    var io = node.get_object ();
                    var a = new Article ();
                    if (io.has_member ("id")) {
                        var idn = io.get_member ("id");
                        if (idn.get_node_type () == Json.NodeType.VALUE) {
                            if (idn.get_value_type () == typeof (string)) a.guid = idn.get_string ();
                            else if (idn.get_value_type () == typeof (int64)) a.guid = idn.get_int ().to_string ();
                        }
                    }
                    a.link = resolve (ibase, jstr (io, "url"));
                    if (a.link == "") a.link = resolve (ibase, jstr (io, "external_url"));
                    a.title = clean_title (jstr (io, "title"));
                    string html = jstr (io, "content_html");
                    if (html == "") {
                        string t = jstr (io, "content_text");
                        html = t != "" ? text_to_html (t) : text_to_html (jstr (io, "summary"));
                    }
                    a.set_content (html);
                    string date = jstr (io, "date_published");
                    if (date == "") date = jstr (io, "date_modified");
                    a.published = Dates.parse (date);
                    a.author = json_author (io);
                    if (a.author == "") a.author = feed_author;
                    a.thumbnail = resolve (ibase, jstr (io, "image"));
                    if (a.thumbnail == "") a.thumbnail = resolve (ibase, jstr (io, "banner_image"));
                    finish (a, ibase);
                    feed.items.add (a);
                }
            }
            return feed;
        }

        private string json_author (Json.Object o) {
            if (o.has_member ("authors") && o.get_member ("authors").get_node_type () == Json.NodeType.ARRAY) {
                string[] names = {};
                foreach (var n in o.get_array_member ("authors").get_elements ()) {
                    if (n.get_node_type () == Json.NodeType.OBJECT) {
                        string nm = jstr (n.get_object (), "name");
                        if (nm != "") names += nm;
                    }
                }
                if (names.length > 0) return string.joinv (", ", names);
            }
            if (o.has_member ("author") && o.get_member ("author").get_node_type () == Json.NodeType.OBJECT) {
                return jstr (o.get_object_member ("author"), "name");
            }
            return "";
        }
    }

    namespace Dates {
        private const string[] MONTHS = { "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };

        public int64 parse (string raw) {
            string s = raw.strip ();
            if (s == "") return 0;
            if (s.length >= 4 && s[0].isdigit () && s[1].isdigit () && s[2].isdigit () && s[3].isdigit () && (s.length == 4 || s[4] == '-')) return parse_iso (s);
            return parse_rfc822 (s);
        }

        private int64 parse_iso (string s) {
            string t = s.replace (" ", "T");
            if (t.length == 10) t += "T00:00:00Z";
            else if (t.length == 7) t += "-01T00:00:00Z";
            else if (t.length == 4) t += "-01-01T00:00:00Z";
            var dt = new DateTime.from_iso8601 (t, new TimeZone.utc ());
            return dt != null ? dt.to_unix () : 0;
        }

        private int zone_offset (string z) {
            switch (z.up ()) {
                case "GMT": case "UT": case "UTC": case "Z": return 0;
                case "EST": return -5 * 60;
                case "EDT": return -4 * 60;
                case "CST": return -6 * 60;
                case "CDT": return -5 * 60;
                case "MST": return -7 * 60;
                case "MDT": return -6 * 60;
                case "PST": return -8 * 60;
                case "PDT": return -7 * 60;
                case "CET": return 60;
                case "CEST": return 120;
                case "BST": return 60;
                case "IST": return 330;
                case "JST": return 540;
                case "AEST": return 600;
            }
            if ((z.has_prefix ("+") || z.has_prefix ("-")) && z.length >= 5) {
                string d = z.substring (1).replace (":", "");
                if (d.length < 4) return 0;
                int h = int.parse (d.substring (0, 2));
                int m = int.parse (d.substring (2, 2));
                int total = h * 60 + m;
                return z.has_prefix ("-") ? -total : total;
            }
            return 0;
        }

        private int64 parse_rfc822 (string s) {
            string t = s;
            int comma = t.index_of (",");
            if (comma >= 0 && comma < 12) t = t.substring (comma + 1);
            string[] parts = {};
            foreach (string p in t.strip ().split (" ")) if (p != "") parts += p;
            if (parts.length < 3) return 0;
            int day = -1, month = -1, year = -1;
            int idx = 0;
            if (parts[0][0].isdigit ()) {
                day = int.parse (parts[0]);
                month = month_index (parts[1]);
                idx = 2;
            } else {
                month = month_index (parts[0]);
                day = int.parse (parts[1]);
                idx = 2;
            }
            if (month < 0 || day < 1 || day > 31 || idx >= parts.length) return 0;
            year = int.parse (parts[idx]);
            if (parts[idx].length <= 2) year += year < 50 ? 2000 : 1900;
            idx++;
            int h = 0, mi = 0;
            double sec = 0;
            string zone = "GMT";
            if (idx < parts.length && parts[idx].contains (":")) {
                string[] hms = parts[idx].split (":");
                h = int.parse (hms[0]);
                if (hms.length > 1) mi = int.parse (hms[1]);
                if (hms.length > 2) sec = double.parse (hms[2]);
                idx++;
            }
            if (idx < parts.length) zone = parts[idx];
            int off = zone_offset (zone);
            var dt = new DateTime.utc (year, month + 1, day, h, mi, sec);
            if (dt == null) return 0;
            return dt.to_unix () - off * 60;
        }

        private int month_index (string m) {
            if (m.length < 3) return -1;
            string k = m.substring (0, 3).down ();
            for (int i = 0; i < MONTHS.length; i++) if (MONTHS[i] == k) return i;
            return -1;
        }
    }
}
