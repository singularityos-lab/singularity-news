namespace Singularity.Apps.News {

    public class Feed : Object {
        public string id = "";
        public string url = "";
        public string site_url = "";
        public string etag = "";
        public string last_modified = "";
        public int64 last_checked;
        public int64 last_parsed;
        public string title { get; set; default = ""; }
        public string folder { get; set; default = ""; }
        public string error { get; set; default = ""; }
        public string full_text { get; set; default = "auto"; }
        public int unread { get; set; }
        public bool busy { get; set; }

        public string display_title {
            owned get {
                if (title != "") return title;
                try {
                    return Uri.parse (url, UriFlags.NONE).get_host () ?? url;
                } catch (Error e) {
                    return url;
                }
            }
        }
    }

    public class Store : Object {
        public Gee.List<Feed> feeds = new Gee.ArrayList<Feed> ();
        public Gee.List<string> folders = new Gee.ArrayList<string> ();
        public Gee.HashMap<string, Article> articles = new Gee.HashMap<string, Article> ();
        public int refresh_minutes = 30;
        public int keep_days = 30;
        public bool mark_read_on_open = true;
        public bool unread_only = false;
        public bool legacy_settings;
        public int64 last_refresh;
        public string dir;

        public signal void feeds_changed ();
        public signal void articles_changed ();
        public signal void counts_changed ();

        private Gee.HashSet<string> dirty = new Gee.HashSet<string> ();
        private bool meta_dirty;
        private uint save_id;

        public Store (string dir) {
            this.dir = dir;
        }

        public static string default_dir () {
            return Path.build_filename (Environment.get_user_data_dir (), "singularity-news");
        }

        public Feed? feed (string id) {
            foreach (var f in feeds) if (f.id == id) return f;
            return null;
        }

        public Feed? feed_by_url (string url) {
            foreach (var f in feeds) if (f.url == url) return f;
            return null;
        }

        public Feed add_feed (string url, string title, string site_url, string folder) {
            var existing = feed_by_url (url);
            if (existing != null) return existing;
            var f = new Feed ();
            f.id = Uuid.string_random ();
            f.url = url;
            f.title = title;
            f.site_url = site_url;
            f.folder = folder;
            if (folder != "" && !folders.contains (folder)) folders.add (folder);
            feeds.add (f);
            meta_dirty = true;
            save_soon ();
            feeds_changed ();
            return f;
        }

        public void remove_feed (Feed f) {
            feeds.remove (f);
            var drop = new Gee.ArrayList<string> ();
            foreach (var e in articles.entries) if (e.value.feed_id == f.id) drop.add (e.key);
            foreach (string k in drop) articles.unset (k);
            FileUtils.remove (article_path (f.id));
            meta_dirty = true;
            save_soon ();
            feeds_changed ();
            articles_changed ();
            counts_changed ();
        }

        public void add_folder (string name) {
            string n = name.strip ();
            if (n == "" || folders.contains (n)) return;
            folders.add (n);
            meta_dirty = true;
            save_soon ();
            feeds_changed ();
        }

        public void rename_folder (string old_name, string new_name) {
            string n = new_name.strip ();
            if (n == "" || n == old_name) return;
            int i = folders.index_of (old_name);
            if (i < 0) return;
            if (folders.contains (n)) folders.remove_at (i);
            else folders[i] = n;
            foreach (var f in feeds) if (f.folder == old_name) f.folder = n;
            meta_dirty = true;
            save_soon ();
            feeds_changed ();
        }

        public void remove_folder (string name) {
            folders.remove (name);
            foreach (var f in feeds) if (f.folder == name) f.folder = "";
            meta_dirty = true;
            save_soon ();
            feeds_changed ();
        }

        public void move_feed (Feed f, string folder) {
            f.folder = folder;
            if (folder != "" && !folders.contains (folder)) folders.add (folder);
            meta_dirty = true;
            save_soon ();
            feeds_changed ();
        }

        public void rename_feed (Feed f, string title) {
            f.title = title.strip ();
            meta_dirty = true;
            save_soon ();
            feeds_changed ();
        }

        public void set_full_text (Feed f, string mode) {
            string m = mode == "always" || mode == "never" ? mode : "auto";
            if (f.full_text == m) return;
            f.full_text = m;
            meta_dirty = true;
            save_soon ();
        }

        public void touch_meta () {
            meta_dirty = true;
            save_soon ();
        }

        public int merge (Feed f, ParsedFeed parsed, int64 now) {
            int added = 0;
            if (f.title == "" && parsed.title != "") f.title = parsed.title;
            if (parsed.site_url != "") f.site_url = parsed.site_url;
            f.last_parsed = now;
            var seen_keys = new Gee.HashSet<string> ();
            foreach (var item in parsed.items) {
                item.feed_id = f.id;
                string k = item.key;
                if (seen_keys.contains (k)) continue;
                seen_keys.add (k);
                var old = articles[k];
                if (old != null) {
                    old.fetched = now;
                    if (old.title != item.title || old.content != item.content) {
                        old.title = item.title;
                        old.set_content (item.content);
                        old.link = item.link;
                        if (item.thumbnail != "") old.thumbnail = item.thumbnail;
                    }
                    continue;
                }
                item.fetched = now;
                if (item.published == 0 || item.published > now + 86400) item.published = now;
                if (keep_days > 0 && item.published < now - (int64) keep_days * 86400) item.unread = false;
                articles[k] = item;
                added++;
            }
            prune (f, now);
            update_counts ();
            dirty.add (f.id);
            meta_dirty = true;
            save_soon ();
            if (added > 0) articles_changed ();
            return added;
        }

        public void prune (Feed f, int64 now) {
            var mine = new Gee.ArrayList<Article> ();
            foreach (var a in articles.values) if (a.feed_id == f.id) mine.add (a);
            mine.sort ((a, b) => a.published > b.published ? -1 : (a.published < b.published ? 1 : 0));
            int kept = 0;
            foreach (var a in mine) {
                bool in_feed = a.fetched == f.last_parsed;
                bool old = keep_days > 0 && a.published < now - (int64) keep_days * 86400;
                if (!a.starred && !a.unread && !in_feed && (old || kept >= 1000)) {
                    articles.unset (a.key);
                    continue;
                }
                kept++;
            }
        }

        public void update_counts () {
            var counts = new Gee.HashMap<string, int> ();
            foreach (var a in articles.values) if (a.unread) counts[a.feed_id] = counts[a.feed_id] + 1;
            foreach (var f in feeds) {
                int n = counts.has_key (f.id) ? counts[f.id] : 0;
                if (f.unread != n) f.unread = n;
            }
            counts_changed ();
        }

        public int total_unread () {
            int n = 0;
            foreach (var f in feeds) n += f.unread;
            return n;
        }

        public int total_starred () {
            int n = 0;
            foreach (var a in articles.values) if (a.starred) n++;
            return n;
        }

        public void set_unread (Article a, bool unread) {
            if (a.unread == unread) return;
            a.unread = unread;
            dirty.add (a.feed_id);
            update_counts ();
            save_soon ();
        }

        public void set_starred (Article a, bool starred) {
            if (a.starred == starred) return;
            a.starred = starred;
            dirty.add (a.feed_id);
            counts_changed ();
            save_soon ();
        }

        public int mark_read (Gee.Collection<Article> list) {
            int n = 0;
            foreach (var a in list) {
                if (!a.unread) continue;
                a.unread = false;
                dirty.add (a.feed_id);
                n++;
            }
            if (n > 0) {
                update_counts ();
                save_soon ();
            }
            return n;
        }

        public Gee.List<Feed> import_entries (Gee.List<OpmlEntry> entries) {
            var added = new Gee.ArrayList<Feed> ();
            foreach (var e in entries) {
                string url = Discovery.normalize_address (e.xml_url);
                if (url == "" || feed_by_url (url) != null) continue;
                var f = new Feed ();
                f.id = Uuid.string_random ();
                f.url = url;
                f.title = e.title != e.xml_url ? e.title : "";
                f.site_url = e.html_url;
                f.folder = e.folder;
                if (e.folder != "" && !folders.contains (e.folder)) folders.add (e.folder);
                feeds.add (f);
                added.add (f);
            }
            if (added.size > 0) {
                meta_dirty = true;
                save_soon ();
                feeds_changed ();
            }
            return added;
        }

        public Gee.List<OpmlEntry> export_entries () {
            var list = new Gee.ArrayList<OpmlEntry> ();
            foreach (var f in feeds) list.add (new OpmlEntry (f.display_title, f.url, f.site_url, f.folder));
            return list;
        }

        private string meta_path () {
            return Path.build_filename (dir, "feeds.json");
        }

        private string article_path (string feed_id) {
            return Path.build_filename (dir, "articles", feed_id + ".json");
        }

        private static string sget (Json.Object o, string k, string def = "") {
            return o.has_member (k) && o.get_member (k).get_value_type () == typeof (string) ? o.get_string_member (k) : def;
        }

        private static int64 iget (Json.Object o, string k, int64 def = 0) {
            return o.has_member (k) && o.get_member (k).get_value_type () == typeof (int64) ? o.get_int_member (k) : def;
        }

        private static bool bget (Json.Object o, string k, bool def) {
            return o.has_member (k) && o.get_member (k).get_value_type () == typeof (bool) ? o.get_boolean_member (k) : def;
        }

        public void load () throws Error {
            feeds.clear ();
            folders.clear ();
            articles.clear ();
            if (!FileUtils.test (meta_path (), FileTest.EXISTS)) return;
            var p = new Json.Parser ();
            p.load_from_file (meta_path ());
            var root = p.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return;
            var o = root.get_object ();
            legacy_settings = o.has_member ("refresh_minutes") || o.has_member ("keep_days") || o.has_member ("mark_read_on_open");
            refresh_minutes = (int) iget (o, "refresh_minutes", 30);
            keep_days = (int) iget (o, "keep_days", 30);
            mark_read_on_open = bget (o, "mark_read_on_open", true);
            unread_only = bget (o, "unread_only", false);
            last_refresh = iget (o, "last_refresh");
            if (o.has_member ("folders")) {
                foreach (var n in o.get_array_member ("folders").get_elements ()) {
                    string name = n.get_string ();
                    if (name != null && name != "" && !folders.contains (name)) folders.add (name);
                }
            }
            if (o.has_member ("feeds")) {
                foreach (var n in o.get_array_member ("feeds").get_elements ()) {
                    if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                    var fo = n.get_object ();
                    var f = new Feed ();
                    f.id = sget (fo, "id");
                    f.url = sget (fo, "url");
                    if (f.id == "" || f.url == "") continue;
                    f.title = sget (fo, "title");
                    f.site_url = sget (fo, "site_url");
                    f.folder = sget (fo, "folder");
                    f.etag = sget (fo, "etag");
                    f.last_modified = sget (fo, "last_modified");
                    f.last_checked = iget (fo, "last_checked");
                    f.last_parsed = iget (fo, "last_parsed");
                    f.error = sget (fo, "error");
                    f.full_text = sget (fo, "full_text", "auto");
                    feeds.add (f);
                    load_articles (f);
                }
            }
            update_counts ();
        }

        private void load_articles (Feed f) {
            string path = article_path (f.id);
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            var p = new Json.Parser ();
            try {
                p.load_from_file (path);
            } catch (Error e) {
                warning ("Could not read %s: %s", path, e.message);
                return;
            }
            var root = p.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return;
            foreach (var n in root.get_array ().get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                var o = n.get_object ();
                var a = new Article ();
                a.feed_id = f.id;
                a.guid = sget (o, "guid");
                if (a.guid == "") continue;
                a.title = sget (o, "title");
                a.link = sget (o, "link");
                a.author = sget (o, "author");
                a.set_content (sget (o, "content"));
                a.thumbnail = sget (o, "thumbnail");
                a.published = iget (o, "published");
                a.fetched = iget (o, "fetched");
                a.unread = bget (o, "unread", true);
                a.starred = bget (o, "starred", false);
                articles[a.key] = a;
            }
        }

        public void save_soon () {
            if (save_id != 0) return;
            save_id = Timeout.add (1200, () => {
                save_id = 0;
                save_now ();
                return Source.REMOVE;
            });
        }

        public void save_now () {
            if (save_id != 0) {
                Source.remove (save_id);
                save_id = 0;
            }
            DirUtils.create_with_parents (Path.build_filename (dir, "articles"), 0700);
            if (meta_dirty) {
                meta_dirty = false;
                var b = new Json.Builder ();
                b.begin_object ();
                b.set_member_name ("unread_only").add_boolean_value (unread_only);
                b.set_member_name ("last_refresh").add_int_value (last_refresh);
                b.set_member_name ("folders").begin_array ();
                foreach (string s in folders) b.add_string_value (s);
                b.end_array ();
                b.set_member_name ("feeds").begin_array ();
                foreach (var f in feeds) {
                    b.begin_object ();
                    b.set_member_name ("id").add_string_value (f.id);
                    b.set_member_name ("url").add_string_value (f.url);
                    b.set_member_name ("title").add_string_value (f.title);
                    b.set_member_name ("site_url").add_string_value (f.site_url);
                    b.set_member_name ("folder").add_string_value (f.folder);
                    b.set_member_name ("etag").add_string_value (f.etag);
                    b.set_member_name ("last_modified").add_string_value (f.last_modified);
                    b.set_member_name ("last_checked").add_int_value (f.last_checked);
                    b.set_member_name ("last_parsed").add_int_value (f.last_parsed);
                    b.set_member_name ("error").add_string_value (f.error);
                    b.set_member_name ("full_text").add_string_value (f.full_text);
                    b.end_object ();
                }
                b.end_array ();
                b.end_object ();
                write_json (meta_path (), b.get_root ());
            }
            foreach (string id in dirty) {
                var b = new Json.Builder ();
                b.begin_array ();
                foreach (var a in articles.values) {
                    if (a.feed_id != id) continue;
                    b.begin_object ();
                    b.set_member_name ("guid").add_string_value (a.guid);
                    b.set_member_name ("title").add_string_value (a.title);
                    b.set_member_name ("link").add_string_value (a.link);
                    b.set_member_name ("author").add_string_value (a.author);
                    b.set_member_name ("content").add_string_value (a.content);
                    b.set_member_name ("thumbnail").add_string_value (a.thumbnail);
                    b.set_member_name ("published").add_int_value (a.published);
                    b.set_member_name ("fetched").add_int_value (a.fetched);
                    b.set_member_name ("unread").add_boolean_value (a.unread);
                    b.set_member_name ("starred").add_boolean_value (a.starred);
                    b.end_object ();
                }
                b.end_array ();
                if (feed (id) != null) write_json (article_path (id), b.get_root ());
            }
            dirty.clear ();
        }

        private void write_json (string path, Json.Node node) {
            var gen = new Json.Generator ();
            gen.set_root (node);
            try {
                FileUtils.set_contents_full (path, gen.to_data (null), -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning ("Could not save %s: %s", path, e.message);
            }
        }
    }
}
