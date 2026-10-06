namespace Singularity.Apps.News {

    public class OpmlEntry : Object {
        public string title;
        public string xml_url;
        public string html_url;
        public string folder;

        public OpmlEntry (string title, string xml_url, string html_url, string folder) {
            this.title = title;
            this.xml_url = xml_url;
            this.html_url = html_url;
            this.folder = folder;
        }
    }

    namespace Opml {
        private string prop (Xml.Node* n, string name) {
            string? v = n->get_prop (name);
            return v != null ? v.strip () : "";
        }

        private void walk (Xml.Node* n, string folder, Gee.List<OpmlEntry> out_list) {
            for (Xml.Node* c = n->children; c != null; c = c->next) {
                if (c->type != Xml.ElementType.ELEMENT_NODE || c->name != "outline") continue;
                string url = prop (c, "xmlUrl");
                if (url == "") url = prop (c, "xmlurl");
                string title = prop (c, "title");
                if (title == "") title = prop (c, "text");
                if (url != "") {
                    out_list.add (new OpmlEntry (title != "" ? title : url, url, prop (c, "htmlUrl"), folder));
                    continue;
                }
                walk (c, title != "" ? title : folder, out_list);
            }
        }

        public Gee.List<OpmlEntry> parse (string data) throws FeedError {
            var list = new Gee.ArrayList<OpmlEntry> ();
            string text = data.strip ();
            Xml.Doc* doc = Xml.Parser.read_memory (text, text.length, null, null,
                Xml.ParserOption.RECOVER | Xml.ParserOption.NONET | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING);
            if (doc == null) throw new FeedError.NOT_A_FEED (_("The file is not an OPML subscription list."));
            try {
                Xml.Node* root = doc->get_root_element ();
                if (root == null || root->name.down () != "opml") throw new FeedError.NOT_A_FEED (_("The file is not an OPML subscription list."));
                for (Xml.Node* c = root->children; c != null; c = c->next) {
                    if (c->type == Xml.ElementType.ELEMENT_NODE && c->name == "body") walk (c, "", list);
                }
            } finally {
                delete doc;
            }
            return list;
        }

        private string esc (string s) {
            return GLib.Markup.escape_text (s).replace ("\"", "&quot;");
        }

        private void outline (StringBuilder sb, OpmlEntry e, string indent) {
            sb.append ("%s<outline type=\"rss\" text=\"%s\" title=\"%s\" xmlUrl=\"%s\"".printf (indent, esc (e.title), esc (e.title), esc (e.xml_url)));
            if (e.html_url != "") sb.append (" htmlUrl=\"%s\"".printf (esc (e.html_url)));
            sb.append ("/>\n");
        }

        public string serialize (Gee.List<OpmlEntry> entries, string title) {
            var sb = new StringBuilder ();
            sb.append ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head>\n");
            sb.append ("    <title>%s</title>\n".printf (esc (title)));
            sb.append ("    <dateCreated>%s</dateCreated>\n".printf (new DateTime.now_utc ().format ("%a, %d %b %Y %H:%M:%S GMT")));
            sb.append ("  </head>\n  <body>\n");
            var folders = new Gee.ArrayList<string> ();
            foreach (var e in entries) {
                if (e.folder == "") outline (sb, e, "    ");
                else if (!folders.contains (e.folder)) folders.add (e.folder);
            }
            foreach (string f in folders) {
                sb.append ("    <outline text=\"%s\" title=\"%s\">\n".printf (esc (f), esc (f)));
                foreach (var e in entries) if (e.folder == f) outline (sb, e, "      ");
                sb.append ("    </outline>\n");
            }
            sb.append ("  </body>\n</opml>\n");
            return sb.str;
        }
    }
}
