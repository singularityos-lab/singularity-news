namespace Singularity.Apps.News {

    public class ImageCache : Object {
        private static ImageCache? instance;
        private Soup.Session session;
        private string dir;
        private Gee.HashMap<string, Gdk.Texture> memory = new Gee.HashMap<string, Gdk.Texture> ();
        private Gee.LinkedList<string> order = new Gee.LinkedList<string> ();
        private Gee.HashSet<string> failed = new Gee.HashSet<string> ();
        private Gee.HashMap<string, string> local = new Gee.HashMap<string, string> ();
        private int active;
        private Gee.ArrayQueue<SourceFuncWrapper> waiting = new Gee.ArrayQueue<SourceFuncWrapper> ();
        private const int MAX_ACTIVE = 6;
        private const int MAX_MEMORY = 240;

        private class SourceFuncWrapper {
            public SourceFunc func;

            public SourceFuncWrapper (owned SourceFunc f) {
                func = (owned) f;
            }
        }

        public static ImageCache get_default () {
            if (instance == null) instance = new ImageCache ();
            return instance;
        }

        private ImageCache () {
            session = new Soup.Session ();
            session.user_agent = "SingularityNews/0.1 (+https://github.com/singularityos-lab)";
            session.timeout = 30;
            dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-news", "images");
            DirUtils.create_with_parents (dir, 0700);
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

        private void remember (string key, Gdk.Texture tex) {
            memory[key] = tex;
            order.remove (key);
            order.offer_tail (key);
            while (order.size > MAX_MEMORY) {
                string old = order.poll_head ();
                memory.unset (old);
            }
        }

        public void register_local (Gee.Map<string, string> files) {
            foreach (var e in files.entries) {
                local[e.key] = e.value;
                failed.remove (e.key);
            }
        }

        public async Bytes? fetch_bytes (string url, Cancellable? cancel) {
            string? path = yield download (url, cancel);
            if (path == null) return null;
            try {
                uint8[] data;
                FileUtils.get_data (path, out data);
                return new Bytes.take ((owned) data);
            } catch (Error e) {
                return null;
            }
        }

        private async string? download (string url, Cancellable? cancel) {
            if (local.has_key (url) && FileUtils.test (local[url], FileTest.EXISTS)) return local[url];
            string path = Path.build_filename (dir, Checksum.compute_for_string (ChecksumType.SHA1, url));
            var file = File.new_for_path (path);
            if (FileUtils.test (path, FileTest.EXISTS)) return path;
            if (active >= MAX_ACTIVE) {
                waiting.offer (new SourceFuncWrapper (download.callback));
                yield;
            }
            active++;
            string? result = null;
            try {
                var msg = new Soup.Message ("GET", url);
                if (msg != null) {
                    var bytes = yield session.send_and_read_async (msg, Priority.LOW, cancel);
                    if (msg.status_code >= 200 && msg.status_code < 300 && bytes.get_size () > 0 && bytes.get_size () < 24 * 1024 * 1024) {
                        try {
                            yield file.replace_contents_async (bytes.get_data (), null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
                            result = path;
                        } catch (Error e) {
                        }
                    }
                }
            } catch (Error e) {
            }
            active--;
            if (!waiting.is_empty) {
                var next = waiting.poll ();
                Idle.add ((owned) next.func);
            }
            return result;
        }

        public async Gdk.Texture? load (string url, int size, bool cover, Cancellable? cancel = null) {
            if (url == "") return null;
            string key = "%d:%s:%s".printf (size, cover ? "c" : "f", url);
            if (memory.has_key (key)) return memory[key];
            if (failed.contains (url)) return null;
            var path = yield download (url, cancel);
            if (path == null) {
                if (cancel == null || !cancel.is_cancelled ()) failed.add (url);
                return null;
            }
            try {
                int w, h;
                var fmt = yield Gdk.Pixbuf.get_file_info_async (path, cancel, out w, out h);
                if (fmt == null || w <= 0 || h <= 0) throw new IOError.INVALID_DATA ("unknown image");
                double scale = cover ? (double) size / int.min (w, h) : (double) size / int.max (w, h);
                if (scale > 1) scale = 1;
                int tw = int.max (1, (int) (w * scale)), th = int.max (1, (int) (h * scale));
                var stream = yield File.new_for_path (path).read_async (Priority.LOW, cancel);
                var pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async (stream, tw, th, false, cancel);
                var tex = texture_from_pixbuf (pixbuf);
                remember (key, tex);
                return tex;
            } catch (Error e) {
                failed.add (url);
                return null;
            }
        }

        private Gdk.Texture texture_from_pixbuf (Gdk.Pixbuf pb) {
            var format = pb.has_alpha ? Gdk.MemoryFormat.R8G8B8A8 : Gdk.MemoryFormat.R8G8B8;
            return new Gdk.MemoryTexture (pb.width, pb.height, format, pb.read_pixel_bytes (), pb.rowstride);
        }
    }
}
