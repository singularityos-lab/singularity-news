namespace Singularity.Apps.News {

    public class FeedLink : Object {
        public string url;
        public string title;
        public string type;

        public FeedLink (string url, string title, string type) {
            this.url = url;
            this.title = title;
            this.type = type;
        }
    }

    namespace Discovery {
        private const string[] TYPES = {
            "application/rss+xml", "application/atom+xml", "application/rdf+xml",
            "application/feed+json", "application/json", "text/xml", "application/xml"
        };

        private const string[] GUESSES = { "feed", "rss", "feed.xml", "rss.xml", "atom.xml", "index.xml", "feed.json" };

        private void collect (Xml.Node* n, ref string base_url, Gee.List<FeedLink> out_list, Gee.HashSet<string> seen, string page_url) {
            for (Xml.Node* c = n->children; c != null; c = c->next) {
                if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                string name = c->name.down ();
                if (name == "base") {
                    string? h = c->get_prop ("href");
                    if (h != null && h.strip () != "") base_url = FeedParser.resolve (page_url, h);
                } else if (name == "link") {
                    string rel = (c->get_prop ("rel") ?? "").down ();
                    string type = (c->get_prop ("type") ?? "").down ().strip ();
                    string href = (c->get_prop ("href") ?? "").strip ();
                    bool alternate = false;
                    foreach (string r in rel.split (" ")) if (r == "alternate" || r == "feed") alternate = true;
                    bool typed = false;
                    foreach (string t in TYPES) if (type == t) typed = true;
                    if (alternate && href != "" && (typed || (rel.contains ("feed") && type == ""))) {
                        string url = FeedParser.resolve (base_url, href);
                        if (!seen.contains (url) && (url.has_prefix ("http://") || url.has_prefix ("https://"))) {
                            seen.add (url);
                            out_list.add (new FeedLink (url, (c->get_prop ("title") ?? "").strip (), type));
                        }
                    }
                }
                collect (c, ref base_url, out_list, seen, page_url);
            }
        }

        public Gee.List<FeedLink> find_feeds (string html, string page_url) {
            var list = new Gee.ArrayList<FeedLink> ();
            if (html.strip () == "") return list;
            char[] buf = html.to_utf8 ();
            Xml.Doc* doc = global::Html.Doc.read_memory (buf, buf.length, page_url, null,
                global::Html.ParserOption.RECOVER | global::Html.ParserOption.NOERROR | global::Html.ParserOption.NOWARNING | global::Html.ParserOption.NONET);
            if (doc == null) return list;
            Xml.Node* root = doc->get_root_element ();
            string base_url = page_url;
            if (root != null) collect (root, ref base_url, list, new Gee.HashSet<string> (), page_url);
            delete doc;
            return list;
        }

        public string[] guesses (string page_url) {
            string[] out_v = {};
            foreach (string g in GUESSES) out_v += FeedParser.resolve (page_url, "/" + g);
            return out_v;
        }

        public string normalize_address (string input) {
            string s = input.strip ();
            if (s == "") return "";
            if (s.has_prefix ("feed://")) s = "https://" + s.substring (7);
            else if (s.has_prefix ("feed:")) s = s.substring (5);
            if (!s.contains ("://")) s = "https://" + s;
            string l = s.down ();
            if (!l.has_prefix ("http://") && !l.has_prefix ("https://")) return "";
            try {
                var u = Uri.parse (s, UriFlags.NONE);
                if (u.get_host () == null || u.get_host () == "") return "";
                if (u.get_path () == "") {
                    u = Uri.build (u.get_flags (), u.get_scheme (), u.get_userinfo (), u.get_host (), u.get_port (), "/", u.get_query (), u.get_fragment ());
                }
                return u.to_string ();
            } catch (Error e) {
                return "";
            }
        }
    }
}
