using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.News {

    public class NewsApp : Singularity.Application {
        public Store store;
        public Refresher refresher;
        public GLib.Settings settings;
        public SavedStore saved;
        public FullText full_text;
        public MuteList mute = new MuteList ();
        public bool mute_dims;

        public signal void mute_changed ();

        private const string[] KEEP_IDS = { "week", "month", "three-months", "forever" };
        private const int[] KEEP_DAYS = { 7, 30, 90, 0 };

        private int64 shown_badge = -1;
        private NewsSearch? search;
        private bool add_feed_pending;

        public NewsApp () {
            Object (application_id: "dev.sinty.news", flags: ApplicationFlags.HANDLES_OPEN);
            search = new NewsSearch (this);
            search.export (this);
            add_main_option ("add-feed", 0, OptionFlags.NONE, OptionArg.NONE, _("Subscribe to a new feed"), null);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("add-feed")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("news: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("add-feed", null);
                return 0;
            }
            add_feed_pending = true;
            return -1;
        }

        protected override void startup () {
            base.startup ();
            Environment.set_application_name (_("News"));
            store = new Store (Store.default_dir ());
            try {
                store.load ();
            } catch (Error e) {
                warning ("Could not load subscriptions: %s", e.message);
            }
            settings = new GLib.Settings ("dev.sinty.news");
            if (store.legacy_settings) migrate_settings ();
            apply_settings ();
            settings.changed.connect (() => apply_settings ());
            refresher = new Refresher (store);
            saved = new SavedStore (SavedStore.default_dir ());
            saved.load ();
            saved.limit_bytes = (int64) settings.get_int ("saved-limit-mb") * 1000 * 1000;
            foreach (var s in saved.items) ImageCache.get_default ().register_local (saved.local_images (s));
            full_text = new FullText (refresher.fetcher);
            full_text.prune (60);
            load_mute ();
            settings.changed["muted-words"].connect (() => load_mute ());
            settings.changed["muted-action"].connect (() => load_mute ());
            settings.changed["saved-limit-mb"].connect (() => {
                saved.limit_bytes = (int64) settings.get_int ("saved-limit-mb") * 1000 * 1000;
                if (saved.enforce_limit ().size > 0) saved.changed ();
            });
            ImageCache.get_default ().prune (30);
            IconTheme.get_for_display (Gdk.Display.get_default ()).add_resource_path ("/dev/sinty/news/icons");
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);

            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("Add Feed…"), "win.add");
            f1.append (_("New Folder…"), "win.new-folder");
            file.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Import OPML…"), "win.import");
            f2.append (_("Export OPML…"), "win.export");
            file.append_section (null, f2);
            var f3 = new GLib.Menu ();
            f3.append (_("Close Window"), "win.close");
            f3.append (_("Quit"), "app.quit");
            file.append_section (null, f3);
            menu.append_submenu (_("File"), file);

            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Find"), "win.find");
            edit.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Mark as Read or Unread"), "win.toggle-read");
            e2.append (_("Star or Remove Star"), "win.toggle-star");
            e2.append (_("Mark All as Read"), "win.mark-all-read");
            e2.append (_("Save for Later"), "win.save-later");
            edit.append_section (null, e2);
            var e3 = new GLib.Menu ();
            e3.append (_("Muted Words…"), "win.muted-words");
            edit.append_section (null, e3);
            var e4 = new GLib.Menu ();
            e4.append (_("Settings"), "app.settings");
            edit.append_section (null, e4);
            menu.append_submenu (_("Edit"), edit);

            var view = new GLib.Menu ();
            var v1 = new GLib.Menu ();
            v1.append (_("Next Article"), "win.next");
            v1.append (_("Previous Article"), "win.previous");
            v1.append (_("Open in Browser"), "win.open-browser");
            v1.append (_("Show Full Article"), "win.full-article");
            view.append_section (null, v1);
            var v2 = new GLib.Menu ();
            v2.append (_("Show Only Unread"), "win.unread-only");
            v2.append (_("Show Muted Articles"), "win.show-muted");
            v2.append (_("Saved Articles"), "win.show-saved");
            v2.append (_("Show Sidebar"), "win.sidebar");
            view.append_section (null, v2);
            var v3 = new GLib.Menu ();
            v3.append (_("Refresh"), "win.refresh");
            view.append_section (null, v3);
            menu.append_submenu (_("View"), view);
            set_menubar (menu);

            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => {
                foreach (var w in get_windows ()) w.close ();
            });
            add_action (quit);
            var open_article_action = new SimpleAction ("open-article", VariantType.STRING);
            open_article_action.activate.connect ((param) => open_article (param.get_string ()));
            add_action (open_article_action);
            var add_feed_action = new SimpleAction ("add-feed", null);
            add_feed_action.activate.connect (() => {
                activate ();
                var w = get_active_window () as NewsWindow;
                if (w != null) w.add_feed ("");
            });
            add_action (add_feed_action);
            if (settings.get_int64 ("last-seen") == 0) settings.set_int64 ("last-seen", new DateTime.now_utc ().to_unix ());
            store.counts_changed.connect (update_badge);
            store.articles_changed.connect (update_badge);
            settings.changed["last-seen"].connect (update_badge);
            update_badge ();
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.news");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);

            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.add", { "<Control>n", "<Control>l" });
            set_accels_for_action ("win.import", { "<Control>o" });
            set_accels_for_action ("win.export", { "<Control><Shift>s" });
            set_accels_for_action ("win.find", { "<Control>f" });
            set_accels_for_action ("win.refresh", { "<Control>r", "F5" });
            set_accels_for_action ("win.mark-all-read", { "<Control><Shift>a" });
            set_accels_for_action ("win.sidebar", { "F9" });
            set_accels_for_action ("win.unread-only", { "<Control>u" });
            set_accels_for_action ("win.save-later", { "<Control>d" });
            set_accels_for_action ("win.muted-words", { "<Control><Shift>m" });
            set_accels_for_action ("win.full-article", { "<Control>e" });
            set_accels_for_action ("win.show-muted", { "<Control><Shift>h" });
            set_accels_for_action ("win.show-saved", { "<Control><Shift>d" });
        }

        private void migrate_settings () {
            settings.set_int ("refresh-minutes", store.refresh_minutes.clamp (5, 1440));
            settings.set_boolean ("mark-read-on-open", store.mark_read_on_open);
            int days = store.keep_days;
            settings.set_string ("keep-read", days <= 0 ? "forever" : (days <= 7 ? "week" : (days <= 30 ? "month" : "three-months")));
            GLib.Settings.sync ();
            store.legacy_settings = false;
            store.touch_meta ();
        }

        private void load_mute () {
            mute = new MuteList.from_strv (settings.get_strv ("muted-words"));
            mute_dims = settings.get_string ("muted-action") == "dim";
            mute_changed ();
        }

        private void apply_settings () {
            store.refresh_minutes = settings.get_int ("refresh-minutes");
            store.mark_read_on_open = settings.get_boolean ("mark-read-on-open");
            string keep = settings.get_string ("keep-read");
            for (int i = 0; i < KEEP_IDS.length; i++) if (KEEP_IDS[i] == keep) store.keep_days = KEEP_DAYS[i];
        }

        public override void activate () {
            if (add_feed_pending) {
                add_feed_pending = false;
                activate_action ("add-feed", null);
                return;
            }
            var w = get_active_window ();
            if (w == null) {
                var nw = new NewsWindow (this);
                nw.notify["is-active"].connect (() => {
                    if (nw.is_active) mark_seen ();
                });
                w = nw;
            }
            w.present ();
        }

        public void open_article (string key) {
            activate ();
            var w = get_active_window () as NewsWindow;
            if (w != null) w.open_article (key);
        }

        public void search_articles (string text) {
            activate ();
            var w = get_active_window () as NewsWindow;
            if (w != null) w.search_for (text);
        }

        private void mark_seen () {
            settings.set_int64 ("last-seen", new DateTime.now_utc ().to_unix ());
        }

        public int new_article_count () {
            int64 seen = settings.get_int64 ("last-seen");
            int n = 0;
            foreach (var a in store.articles.values) {
                if (a.unread && a.fetched > seen && store.feed (a.feed_id) != null) n++;
            }
            return n;
        }

        private void update_badge () {
            var conn = get_dbus_connection ();
            if (conn == null) return;
            int64 n = new_article_count ();
            if (n == shown_badge) return;
            shown_badge = n;
            var props = new VariantBuilder (VariantType.VARDICT);
            props.add ("{sv}", "count", new Variant.int64 (n));
            props.add ("{sv}", "count-visible", new Variant.boolean (n > 0));
            try {
                conn.emit_signal (null, "/com/canonical/Unity/LauncherEntry", "com.canonical.Unity.LauncherEntry", "Update",
                    new Variant ("(s@a{sv})", "application://dev.sinty.news.desktop", props.end ()));
            } catch (Error e) {
                warning ("news: %s", e.message);
            }
        }

        public override void open (File[] files, string hint) {
            activate ();
            var w = get_active_window () as NewsWindow;
            if (w == null) return;
            foreach (var f in files) {
                string uri = f.get_uri ();
                string lower = uri.down ();
                if (f.is_native ()) {
                    if (lower.has_suffix (".opml")) w.import_opml_file.begin (f);
                } else if (lower.has_prefix ("feed:") || lower.has_prefix ("http://") || lower.has_prefix ("https://")) {
                    w.add_feed (uri);
                }
            }
        }

        public override void shutdown () {
            if (store != null) store.save_now ();
            base.shutdown ();
        }

        private const string CSS = """
.news-list-pane {
    border-right: 1px solid alpha(@borders, 0.6);
}

.news-list {
    background: transparent;
    padding: 0 6px 6px 6px;
}

.news-list > row {
    border-radius: 12px;
    padding: 10px 10px;
    margin: 1px 0;
}

.news-list > row:selected {
    background-color: @hover_btn_bg;
    color: @hover_btn_fg;
}

.news-unread-dot {
    border-radius: 99px;
    background-color: @accent_bg_color;
    min-width: 8px;
    min-height: 8px;
}

.news-list > row:selected .news-unread-dot {
    background-color: @hover_btn_fg;
}

.news-row-source {
    font-size: 12px;
    font-weight: 700;
    opacity: 0.7;
}

.news-row-date {
    font-size: 12px;
    font-feature-settings: "tnum";
    opacity: 0.6;
}

.news-row-title {
    font-size: 15px;
    font-weight: 500;
}

.news-row-unread .news-row-title {
    font-weight: 800;
}

.news-row-muted {
    opacity: 0.5;
}

.news-row-muted .news-row-title {
    font-style: italic;
}

.news-row-read .news-row-title {
    opacity: 0.75;
}

.news-row-excerpt {
    font-size: 13px;
    opacity: 0.65;
}

.news-thumb {
    border-radius: 10px;
    min-width: 72px;
    min-height: 72px;
}

.news-star {
    color: #e5a50a;
}

.news-count {
    font-size: 12px;
    font-feature-settings: "tnum";
    opacity: 0.6;
}

.news-sidebar-nested {
    margin-left: 14px;
}

.news-status {
    font-size: 12px;
    opacity: 0.75;
    padding: 8px 12px;
    border-top: 1px solid alpha(@borders, 0.5);
}

.news-article-scroll {
    background-color: @view_bg_color;
}

.news-article-source {
    font-size: 13px;
    font-weight: 700;
    color: @accent_color;
}

.news-article-title {
    font-size: 28px;
    font-weight: 800;
    line-height: 1.15;
}

.news-article-body,
.news-article-body text {
    background: transparent;
    font-size: 16px;
    line-height: 1.5;
}

.news-article-image {
    border-radius: 10px;
    margin: 6px 0;
}
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-news", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-news", "UTF-8");
        Intl.textdomain ("singularity-news");
        return new NewsApp ().run (args);
    }
}
