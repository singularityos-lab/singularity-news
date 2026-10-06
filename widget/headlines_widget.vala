using Gtk;
using GLib;
using Singularity;

namespace SingularityNewsWidget {

    public class HeadlinesProvider : Object, OverviewWidgetProvider {
        public string id { get { return "news.headlines"; } }
        public string provider_id { get { return "dev.sinty.news"; } }
        public string display_name { get { return _("Headlines"); } }
        public string icon_name { get { return "dev.sinty.news"; } }
        public WidgetSize[] supported_sizes {
            get {
                if (_sizes == null) {
                    _sizes = new WidgetSize[3];
                    _sizes[0] = WidgetSize (2, 2);
                    _sizes[1] = WidgetSize (4, 2);
                    _sizes[2] = WidgetSize (4, 4);
                }
                return _sizes;
            }
        }
        private WidgetSize[] _sizes;

        public Gtk.Widget create_instance (string instance_id, WidgetSize size, Variant? config) {
            return new HeadlinesInstance (size);
        }
    }

    private class Headline : Object {
        public string key = "";
        public string title = "";
        public string source = "";
        public int64 published;
        public bool unread;
    }

    public class HeadlinesInstance : Gtk.Box {
        private Gtk.Box list;
        private Gtk.Label empty;
        private FileMonitor? monitor;
        private string dir;
        private int limit;
        private int last_height = -1;
        private uint reload_id;
        private int generation;

        public HeadlinesInstance (WidgetSize size) {
            Object (orientation: Orientation.VERTICAL, spacing: 6);
            add_css_class ("overview-widget-card");
            hexpand = true;
            vexpand = true;
            limit = size.h >= 4 ? 16 : 8;

            var header = new Gtk.Label (_("Headlines"));
            header.add_css_class ("heading");
            header.halign = Align.START;
            header.margin_start = 14;
            header.margin_top = 10;
            append (header);

            list = new Gtk.Box (Orientation.VERTICAL, 2);
            list.margin_start = 8;
            list.margin_end = 8;
            list.margin_bottom = 8;
            list.vexpand = true;
            append (list);

            empty = new Gtk.Label (_("Subscribe to feeds in News to see the latest headlines here."));
            empty.add_css_class ("dim-label");
            empty.wrap = true;
            empty.justify = Justification.CENTER;
            empty.vexpand = true;
            empty.margin_start = 14;
            empty.margin_end = 14;
            append (empty);

            dir = Path.build_filename (Environment.get_user_data_dir (), "singularity-news");
            try {
                monitor = File.new_for_path (Path.build_filename (dir, "articles")).monitor_directory (FileMonitorFlags.NONE);
                monitor.changed.connect ((f, o, ev) => {
                    if (ev == FileMonitorEvent.CHANGES_DONE_HINT || ev == FileMonitorEvent.CREATED || ev == FileMonitorEvent.DELETED) schedule_reload ();
                });
            } catch (Error e) {
                monitor = null;
            }
            destroy.connect (() => {
                if (reload_id != 0) Source.remove (reload_id);
                reload_id = 0;
            });
            reload ();
        }

        private void schedule_reload () {
            if (reload_id != 0) Source.remove (reload_id);
            reload_id = Timeout.add (1500, () => {
                reload_id = 0;
                reload ();
                return Source.REMOVE;
            });
        }

        private void reload () {
            int gen = ++generation;
            string base_dir = dir;
            int max = limit;
            new Thread<void> ("news-headlines", () => {
                var found = load (base_dir, max);
                Idle.add (() => {
                    if (gen == generation) show (found);
                    return Source.REMOVE;
                });
            });
        }

        private static Gee.List<Headline> load (string base_dir, int max) {
            var all = new Gee.ArrayList<Headline> ();
            string meta = Path.build_filename (base_dir, "feeds.json");
            if (!FileUtils.test (meta, FileTest.EXISTS)) return all;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (meta);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return all;
                var o = root.get_object ();
                if (!o.has_member ("feeds")) return all;
                foreach (var fn in o.get_array_member ("feeds").get_elements ()) {
                    if (fn.get_node_type () != Json.NodeType.OBJECT) continue;
                    var fo = fn.get_object ();
                    string id = fo.get_string_member_with_default ("id", "");
                    if (id == "") continue;
                    string source = fo.get_string_member_with_default ("title", "");
                    if (source == "") {
                        string url = fo.get_string_member_with_default ("url", "");
                        try {
                            source = Uri.parse (url, UriFlags.NONE).get_host () ?? url;
                        } catch (Error e) {
                            source = url;
                        }
                    }
                    read_feed (base_dir, id, source, all);
                }
            } catch (Error e) {
                warning ("news widget: %s", e.message);
            }
            all.sort ((a, b) => a.published > b.published ? -1 : (a.published < b.published ? 1 : 0));
            return all.size > max ? all.slice (0, max) : all;
        }

        private static void read_feed (string base_dir, string id, string source, Gee.List<Headline> into) {
            string path = Path.build_filename (base_dir, "articles", id + ".json");
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.ARRAY) return;
                foreach (var n in root.get_array ().get_elements ()) {
                    if (n.get_node_type () != Json.NodeType.OBJECT) continue;
                    var ao = n.get_object ();
                    string guid = ao.get_string_member_with_default ("guid", "");
                    string title = ao.get_string_member_with_default ("title", "").strip ();
                    if (guid == "" || title == "") continue;
                    var h = new Headline ();
                    h.key = id + "\n" + guid;
                    h.title = title;
                    h.source = source;
                    h.published = ao.get_int_member_with_default ("published", 0);
                    h.unread = ao.get_boolean_member_with_default ("unread", true);
                    into.add (h);
                }
            } catch (Error e) {
                warning ("news widget: %s", e.message);
            }
        }

        public override void size_allocate (int width, int height, int baseline) {
            base.size_allocate (width, height, baseline);
            if (height == last_height) return;
            last_height = height;
            Idle.add (() => {
                fit_rows ();
                return Source.REMOVE;
            });
        }

        private void fit_rows () {
            int room = list.get_height ();
            if (room <= 0) return;
            int used = 0;
            Widget? child = list.get_first_child ();
            bool full = false;
            while (child != null) {
                int min, nat, mb, nb;
                child.measure (Orientation.VERTICAL, list.get_width (), out min, out nat, out mb, out nb);
                bool fits = !full && used + nat <= room;
                if (fits) used += nat + list.spacing;
                else full = true;
                child.set_child_visible (fits);
                child = child.get_next_sibling ();
            }
        }

        private void show (Gee.List<Headline> headlines) {
            Widget? child;
            while ((child = list.get_first_child ()) != null) list.remove (child);
            empty.visible = headlines.size == 0;
            list.visible = headlines.size > 0;
            foreach (var h in headlines) list.append (make_row (h));
            Idle.add (() => {
                fit_rows ();
                return Source.REMOVE;
            });
        }

        private Gtk.Widget make_row (Headline h) {
            var button = new Gtk.Button ();
            button.add_css_class ("flat");
            button.tooltip_text = h.title;
            var box = new Gtk.Box (Orientation.VERTICAL, 1);
            var title = new Gtk.Label (h.title);
            title.xalign = 0;
            title.ellipsize = Pango.EllipsizeMode.END;
            if (h.unread) title.add_css_class ("heading");
            box.append (title);
            string when = relative (h.published);
            var source = new Gtk.Label (when != "" ? "%s · %s".printf (h.source, when) : h.source);
            source.xalign = 0;
            source.ellipsize = Pango.EllipsizeMode.END;
            source.add_css_class ("caption");
            source.add_css_class ("dim-label");
            box.append (source);
            button.child = box;
            string key = h.key;
            button.clicked.connect (() => open (key));
            return button;
        }

        private static string relative (int64 stamp) {
            if (stamp <= 0) return "";
            int64 diff = new DateTime.now_utc ().to_unix () - stamp;
            if (diff < 3600) return ngettext ("%d minute ago", "%d minutes ago", (int) int64.max (diff / 60, 1)).printf ((int) int64.max (diff / 60, 1));
            if (diff < 86400) return ngettext ("%d hour ago", "%d hours ago", (int) (diff / 3600)).printf ((int) (diff / 3600));
            return new DateTime.from_unix_local (stamp).format ("%x");
        }

        private void open (string key) {
            Bus.get.begin (BusType.SESSION, null, (o, res) => {
                try {
                    var bus = Bus.get.end (res);
                    var args = new VariantBuilder (new VariantType ("av"));
                    args.add ("v", new Variant.string (key));
                    bus.call.begin ("dev.sinty.news", "/dev/sinty/news", "org.freedesktop.Application", "ActivateAction",
                        new Variant ("(s@av@a{sv})", "open-article", args.end (), new VariantBuilder (VariantType.VARDICT).end ()),
                        null, DBusCallFlags.NONE, 10000, null);
                } catch (Error e) {
                    warning ("news widget: %s", e.message);
                }
            });
        }
    }

    [CCode (cname = "singularity_news_widget_new")]
    public static Object singularity_news_widget_new () {
        return new HeadlinesProvider ();
    }
}
