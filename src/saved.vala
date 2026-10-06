namespace Singularity.Apps.News {

    public errordomain SavedError {
        TOO_LARGE,
        WRITE
    }

    public class SavedArticle : Object {
        public string id = "";
        public string key = "";
        public string source_name = "";
        public string title = "";
        public string link = "";
        public string author = "";
        public string thumbnail = "";
        public string excerpt = "";
        public int64 published;
        public int64 saved_at;
        public int64 size;
        public bool full;
        public Gee.HashMap<string, string> images = new Gee.HashMap<string, string> ();
    }

    public class SavedStore : Object {
        public const string FEED_ID = "saved";
        public string dir;
        public int64 limit_bytes = 250 * 1024 * 1024;
        public Gee.List<SavedArticle> items = new Gee.ArrayList<SavedArticle> ();

        public signal void changed ();

        public SavedStore (string dir) {
            this.dir = dir;
        }

        public static string default_dir () {
            return Path.build_filename (Environment.get_user_data_dir (), "singularity-news", "saved");
        }

        public static string id_for (string key) {
            return Checksum.compute_for_string (ChecksumType.SHA1, key);
        }

        private string index_path () {
            return Path.build_filename (dir, "index.json");
        }

        private string item_dir (string id) {
            return Path.build_filename (dir, id);
        }

        public string content_path (SavedArticle s) {
            return Path.build_filename (item_dir (s.id), "article.html");
        }

        public string image_path (SavedArticle s, string file) {
            return Path.build_filename (item_dir (s.id), file);
        }

        public SavedArticle? find (string key) {
            foreach (var s in items) if (s.key == key) return s;
            return null;
        }

        public bool is_saved (string key) {
            return find (key) != null;
        }

        public int64 total_size () {
            int64 n = 0;
            foreach (var s in items) n += s.size;
            return n;
        }

        public Gee.List<SavedArticle> sorted () {
            var list = new Gee.ArrayList<SavedArticle> ();
            list.add_all (items);
            list.sort ((a, b) => a.saved_at > b.saved_at ? -1 : (a.saved_at < b.saved_at ? 1 : strcmp (a.title, b.title)));
            return list;
        }

        public string content_of (SavedArticle s) {
            string text;
            try {
                FileUtils.get_contents (content_path (s), out text);
                return text;
            } catch (Error e) {
                return "";
            }
        }

        public Article to_article (SavedArticle s) {
            var a = new Article ();
            a.feed_id = FEED_ID;
            a.guid = s.key;
            a.title = s.title;
            a.link = s.link;
            a.author = s.author;
            a.thumbnail = s.thumbnail;
            a.published = s.saved_at > 0 && s.published == 0 ? s.saved_at : s.published;
            a.source_name = s.source_name;
            a.unread = false;
            a.set_content (content_of (s));
            return a;
        }

        public Gee.Map<string, string> local_images (SavedArticle s) {
            var map = new Gee.HashMap<string, string> ();
            foreach (var e in s.images.entries) map[e.key] = image_path (s, e.value);
            return map;
        }

        public SavedArticle add (Article a, string source_name, string html, bool full, Gee.Map<string, Bytes> images, int64 now) throws Error {
            var old = find (a.key);
            if (old != null) remove_files (old);
            if (old != null) items.remove (old);
            var s = new SavedArticle ();
            s.key = a.key;
            s.id = id_for (a.key);
            s.source_name = source_name;
            s.title = a.title;
            s.link = a.link;
            s.author = a.author;
            s.thumbnail = a.thumbnail;
            s.published = a.published;
            s.saved_at = now;
            s.full = full;
            s.excerpt = HtmlText.excerpt (html, 220);
            int64 size = html.length;
            if (size > limit_bytes) throw new SavedError.TOO_LARGE (_("This article is larger than the space set aside for saved articles."));
            string folder = item_dir (s.id);
            if (DirUtils.create_with_parents (folder, 0700) != 0) throw new SavedError.WRITE (_("Could not create %s.").printf (folder));
            try {
                FileUtils.set_contents_full (content_path (s), html, -1, FileSetContentsFlags.CONSISTENT, 0600);
                foreach (var e in images.entries) {
                    int64 bytes = (int64) e.value.get_size ();
                    if (size + bytes > limit_bytes) continue;
                    string file = "img-" + Checksum.compute_for_string (ChecksumType.SHA1, e.key);
                    FileUtils.set_contents_full (image_path (s, file), (string) e.value.get_data (), (ssize_t) e.value.get_size (), FileSetContentsFlags.CONSISTENT, 0600);
                    s.images[e.key] = file;
                    size += bytes;
                }
            } catch (FileError e) {
                remove_files (s);
                throw new SavedError.WRITE (e.message);
            }
            s.size = size;
            items.add (s);
            enforce_limit (s);
            save_index ();
            changed ();
            return s;
        }

        public Gee.List<SavedArticle> enforce_limit (SavedArticle? keep = null) {
            var evicted = new Gee.ArrayList<SavedArticle> ();
            var oldest = new Gee.ArrayList<SavedArticle> ();
            oldest.add_all (items);
            oldest.sort ((a, b) => a.saved_at < b.saved_at ? -1 : (a.saved_at > b.saved_at ? 1 : 0));
            int64 total = total_size ();
            foreach (var s in oldest) {
                if (total <= limit_bytes) break;
                if (s == keep) continue;
                total -= s.size;
                remove_files (s);
                items.remove (s);
                evicted.add (s);
            }
            if (evicted.size > 0) save_index ();
            return evicted;
        }

        public void remove (SavedArticle s) {
            remove_files (s);
            items.remove (s);
            save_index ();
            changed ();
        }

        private void remove_files (SavedArticle s) {
            FileUtils.remove (content_path (s));
            foreach (string file in s.images.values) FileUtils.remove (image_path (s, file));
            DirUtils.remove (item_dir (s.id));
        }

        private static string sget (Json.Object o, string k) {
            return o.has_member (k) && o.get_member (k).get_value_type () == typeof (string) ? o.get_string_member (k) : "";
        }

        private static int64 iget (Json.Object o, string k) {
            return o.has_member (k) && o.get_member (k).get_value_type () == typeof (int64) ? o.get_int_member (k) : 0;
        }

        public void load () {
            items.clear ();
            var p = new Json.Parser ();
            try {
                if (!FileUtils.test (index_path (), FileTest.EXISTS)) return;
                p.load_from_file (index_path ());
            } catch (Error e) {
                warning ("Could not read saved articles: %s", e.message);
                return;
            }
            var root = p.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return;
            foreach (var n in root.get_array ().get_elements ()) {
                if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                var o = n.get_object ();
                var s = new SavedArticle ();
                s.key = sget (o, "key");
                if (s.key == "") continue;
                s.id = id_for (s.key);
                s.source_name = sget (o, "source");
                s.title = sget (o, "title");
                s.link = sget (o, "link");
                s.author = sget (o, "author");
                s.thumbnail = sget (o, "thumbnail");
                s.excerpt = sget (o, "excerpt");
                s.published = iget (o, "published");
                s.saved_at = iget (o, "saved_at");
                s.size = iget (o, "size");
                s.full = o.has_member ("full") && o.get_member ("full").get_value_type () == typeof (bool) && o.get_boolean_member ("full");
                if (o.has_member ("images") && o.get_member ("images").get_node_type () == Json.NodeType.OBJECT) {
                    var im = o.get_object_member ("images");
                    foreach (string url in im.get_members ()) {
                        string file = sget (im, url);
                        if (file != "" && !file.contains ("/")) s.images[url] = file;
                    }
                }
                if (!FileUtils.test (content_path (s), FileTest.EXISTS)) continue;
                items.add (s);
            }
        }

        public void save_index () {
            var b = new Json.Builder ();
            b.begin_array ();
            foreach (var s in items) {
                b.begin_object ();
                b.set_member_name ("key").add_string_value (s.key);
                b.set_member_name ("source").add_string_value (s.source_name);
                b.set_member_name ("title").add_string_value (s.title);
                b.set_member_name ("link").add_string_value (s.link);
                b.set_member_name ("author").add_string_value (s.author);
                b.set_member_name ("thumbnail").add_string_value (s.thumbnail);
                b.set_member_name ("excerpt").add_string_value (s.excerpt);
                b.set_member_name ("published").add_int_value (s.published);
                b.set_member_name ("saved_at").add_int_value (s.saved_at);
                b.set_member_name ("size").add_int_value (s.size);
                b.set_member_name ("full").add_boolean_value (s.full);
                b.set_member_name ("images").begin_object ();
                foreach (var e in s.images.entries) b.set_member_name (e.key).add_string_value (e.value);
                b.end_object ();
                b.end_object ();
            }
            b.end_array ();
            var gen = new Json.Generator ();
            gen.set_root (b.get_root ());
            DirUtils.create_with_parents (dir, 0700);
            try {
                FileUtils.set_contents_full (index_path (), gen.to_data (null), -1, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning ("Could not save the saved articles list: %s", e.message);
            }
        }

        public static Gee.List<string> image_urls (string html, string base_url, string thumbnail) {
            var urls = new Gee.ArrayList<string> ();
            foreach (var b in HtmlText.render (html, base_url)) {
                if (b.kind == HtmlText.BlockKind.IMAGE && !urls.contains (b.src)) urls.add (b.src);
            }
            if (thumbnail != "" && !urls.contains (thumbnail)) urls.add (thumbnail);
            return urls;
        }
    }
}
