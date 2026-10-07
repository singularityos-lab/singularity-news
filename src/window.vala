using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.News {

    public enum FullState {
        NONE,
        LOADING,
        SHOWN,
        FAILED
    }

    public class NewsWindow : Singularity.Widgets.Window {
        private NewsApp app;
        private Store store;
        private Refresher refresher;
        private AppSidebar sidebar;
        private Stack stack;
        private Stack list_stack;
        private Box list_empty;
        private GLib.ListStore model;
        private SingleSelection selection;
        private ListView list;
        private Label status_label;
        private Stack article_stack;
        private ArticleView article_view;
        private ScrolledWindow article_scroll;
        private SearchBubble search;
        private Button add_bubble;
        private Button refresh_bubble;
        private Button read_all_bubble;
        private Button unread_bubble;
        private Button star_bubble;
        private Button browser_bubble;
        private Button save_bubble;
        private SavedStore saved;
        private FullText full_text;
        private Box muted_bar;
        private Label muted_label;
        private Button muted_toggle;
        private bool show_muted;
        private int muted_hidden;
        private int muted_dimmed;
        private bool saving;
        private Cancellable? full_cancel;
        private FullState full_state = FullState.NONE;
        private SimpleAction show_muted_action;
        private Gee.HashSet<string> revealed = new Gee.HashSet<string> ();
        private Gee.HashMap<string, bool> full_choice = new Gee.HashMap<string, bool> ();
        private Gee.HashMap<string, Article> saved_cache = new Gee.HashMap<string, Article> ();
        private string source = "all";
        private string query = "";
        private Article? current;
        private bool rebuilding;
        private uint rebuild_id;
        private uint tick_id;
        private uint status_clear_id;
        private Gee.HashMap<string, SidebarRow> rows = new Gee.HashMap<string, SidebarRow> ();
        private Gee.HashMap<string, Label> badges = new Gee.HashMap<string, Label> ();
        private Gee.HashSet<string> watched = new Gee.HashSet<string> ();
        private Gee.HashMap<string, Feed> feed_index = new Gee.HashMap<string, Feed> ();

        public NewsWindow (NewsApp app) {
            Object (application: app);
            this.app = app;
            this.store = app.store;
            this.refresher = app.refresher;
            this.saved = app.saved;
            this.full_text = app.full_text;
            set_default_size (1200, 780);
            set_title (_("News"));

            sidebar = new AppSidebar (240);
            set_sidebar (sidebar);

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.add_named (build_welcome (), "welcome");
            stack.add_named (build_main (), "main");
            set_content (stack);

            search = add_bubble_search (_("Search Articles"), (t) => {
                query = t.strip ();
                schedule_rebuild ();
            });
            add_bubble = add_bubble_icon ("list-add-symbolic", _("Add Feed (Ctrl+N)"), () => add_feed (""));
            refresh_bubble = add_bubble_icon ("view-refresh-symbolic", _("Refresh (Ctrl+R)"), () => refresh_all ());
            read_all_bubble = add_bubble_icon ("news-mark-read-symbolic", _("Mark All as Read (Ctrl+Shift+A)"), () => mark_all_read ());
            unread_bubble = add_bubble_icon ("mail-unread-symbolic", _("Mark as Unread (M)"), () => toggle_read ());
            star_bubble = add_bubble_icon ("non-starred-symbolic", _("Star (S)"), () => toggle_star ());
            save_bubble = add_bubble_icon ("bookmark-new-symbolic", _("Save for Later (Ctrl+D)"), () => toggle_saved ());
            browser_bubble = add_bubble_icon ("web-browser-symbolic", _("Open in Browser (O)"), () => open_in_browser ());

            store.feeds_changed.connect (() => {
                rebuild_sidebar ();
                schedule_rebuild ();
                sync_stack ();
            });
            store.counts_changed.connect (update_badges);
            store.articles_changed.connect (schedule_rebuild);
            app.mute_changed.connect (() => {
                show_muted_action.set_enabled (!app.mute_dims);
                schedule_rebuild ();
            });
            saved.changed.connect (() => {
                update_badges ();
                if (source == "saved") schedule_rebuild ();
            });
            refresher.notify["done"].connect (show_progress);
            refresher.finished.connect (on_refreshed);
            NetworkMonitor.get_default ().network_changed.connect ((available) => {
                if (available) Timeout.add_seconds (3, () => {
                    maybe_refresh ();
                    return Source.REMOVE;
                });
            });

            install_actions ();
            rebuild_sidebar ();
            rebuild_list ();
            sync_stack ();

            tick_id = Timeout.add_seconds (60, () => {
                maybe_refresh ();
                return Source.CONTINUE;
            });
            Timeout.add_seconds (2, () => {
                maybe_refresh ();
                return Source.REMOVE;
            });
            close_request.connect (() => {
                if (tick_id != 0) Source.remove (tick_id);
                tick_id = 0;
                refresher.stop ();
                store.save_now ();
                return false;
            });
        }

        private Widget build_welcome () {
            var wp = new WelcomePage ();
            wp.app_icon_name = "dev.sinty.news";
            wp.title = _("News");
            wp.subtitle = _("Follow the sites you love, all in one place");
            wp.add_action ("network-workgroup", _("Add Feed"), _("Follow a website or a feed address"), () => add_feed (""));
            wp.add_action ("folder-download", _("Import OPML"), _("Bring your subscriptions from another reader"), () => import_opml ());
            return wp;
        }

        private Widget build_main () {
            model = new GLib.ListStore (typeof (Article));
            selection = new SingleSelection (model);
            selection.autoselect = false;
            selection.can_unselect = true;
            selection.notify["selected"].connect (() => {
                if (rebuilding) return;
                uint pos = selection.selected;
                if (pos == INVALID_LIST_POSITION) show_article (null);
                else show_article ((Article) model.get_item (pos));
            });

            var factory = new SignalListItemFactory ();
            factory.setup.connect ((o) => {
                var item = (ListItem) o;
                item.child = new ArticleRow ();
            });
            factory.bind.connect ((o) => {
                var item = (ListItem) o;
                var a = (Article) item.item;
                var f = feed_index[a.feed_id];
                ((ArticleRow) item.child).bind (a, f != null ? f.display_title : a.source_name);
            });
            factory.unbind.connect ((o) => {
                var item = (ListItem) o;
                ((ArticleRow) item.child).unbind ();
            });

            list = new ListView (selection, factory);
            list.add_css_class ("news-list");
            list.activate.connect ((pos) => {
                var a = (Article) model.get_item (pos);
                if (a != null && a.link != "") launch (a.link);
            });
            list.update_property (AccessibleProperty.LABEL, _("Articles"), -1);

            var list_scroll = new ScrolledWindow ();
            list_scroll.hscrollbar_policy = PolicyType.NEVER;
            list_scroll.vexpand = true;
            list_scroll.child = list;

            list_empty = new Box (Orientation.VERTICAL, 0);
            list_empty.vexpand = true;

            list_stack = new Stack ();
            list_stack.add_named (list_scroll, "list");
            list_stack.add_named (list_empty, "empty");
            list_stack.vexpand = true;
            Singularity.Widgets.apply_view_edge (list_stack);

            status_label = new Label ("");
            status_label.add_css_class ("news-status");
            status_label.wrap = true;
            status_label.visible = false;

            var list_pane = new Box (Orientation.VERTICAL, 0);
            list_pane.add_css_class ("news-list-pane");
            list_pane.set_size_request (280, -1);
            list_pane.append (list_stack);
            list_pane.append (build_muted_bar ());
            list_pane.append (status_label);

            article_view = new ArticleView ();
            article_view.open_link.connect ((uri) => launch (uri));
            article_view.notice_action.connect (() => on_notice_action ());
            var clamp = new Clamp (article_view);
            clamp.maximum = 760;
            article_scroll = new ScrolledWindow ();
            article_scroll.hscrollbar_policy = PolicyType.NEVER;
            article_scroll.child = clamp;
            article_scroll.add_css_class ("news-article-scroll");

            var none = new WelcomePage ();
            none.is_section = true;
            none.app_icon_name = "dev.sinty.news";
            none.title = _("No Article Selected");
            none.subtitle = _("Choose an article from the list. Press J and K to move between articles.");
            none.add_action ("emblem-synchronizing", _("Refresh Feeds"), _("Look for new articles now"), () => refresh_all ());
            none.add_action ("network-workgroup", _("Add Feed"), _("Follow a website or a feed address"), () => add_feed (""));
            none.add_action ("system-search", _("Search Articles"), _("Find an article by its words"), () => search.grab_focus_entry ());

            article_stack = new Stack ();
            article_stack.transition_type = StackTransitionType.CROSSFADE;
            article_stack.add_named (none, "none");
            article_stack.add_named (new Box (Orientation.VERTICAL, 0), "blank");
            article_stack.add_named (article_scroll, "article");
            article_stack.hexpand = true;
            article_stack.set_size_request (360, -1);

            var paned = new Paned (Orientation.HORIZONTAL);
            paned.start_child = list_pane;
            paned.end_child = article_stack;
            paned.resize_start_child = false;
            paned.shrink_start_child = false;
            paned.shrink_end_child = false;
            paned.position = 340;
            return paned;
        }

        private Widget build_muted_bar () {
            muted_bar = new Box (Orientation.HORIZONTAL, 8);
            muted_bar.add_css_class ("news-status");
            muted_bar.visible = false;
            muted_label = new Label ("");
            muted_label.xalign = 0;
            muted_label.hexpand = true;
            muted_label.wrap = true;
            muted_bar.append (muted_label);
            muted_toggle = new Button ();
            muted_toggle.add_css_class ("flat");
            muted_toggle.add_css_class ("caption");
            muted_toggle.valign = Align.CENTER;
            muted_toggle.clicked.connect (() => set_show_muted (!show_muted));
            muted_bar.append (muted_toggle);
            var manage = new Button.from_icon_name ("document-edit-symbolic");
            manage.add_css_class ("flat");
            manage.add_css_class ("circular");
            manage.valign = Align.CENTER;
            manage.tooltip_text = _("Muted Words");
            manage.update_property (AccessibleProperty.LABEL, _("Muted Words"), -1);
            manage.clicked.connect (() => open_muted_words ());
            muted_bar.append (manage);
            return muted_bar;
        }

        private void set_show_muted (bool on) {
            show_muted = on;
            show_muted_action.set_state (new Variant.boolean (on));
            rebuild_list ();
        }

        private void open_muted_words () {
            var dlg = new MutedWordsDialog (app, app.settings);
            dlg.transient_for = this;
            dlg.present ();
        }

        private void update_muted_bar (int hidden, int dimmed) {
            muted_hidden = hidden;
            muted_dimmed = dimmed;
            if (source == "saved" || (hidden == 0 && dimmed == 0)) {
                muted_bar.visible = false;
                return;
            }
            muted_bar.visible = true;
            if (!app.mute_dims && !show_muted) {
                muted_label.label = ngettext ("%d muted article hidden", "%d muted articles hidden", hidden).printf (hidden);
                muted_toggle.label = _("Show");
                muted_toggle.visible = true;
            } else if (!app.mute_dims) {
                muted_label.label = ngettext ("%d muted article shown", "%d muted articles shown", dimmed).printf (dimmed);
                muted_toggle.label = _("Hide");
                muted_toggle.visible = true;
            } else {
                muted_label.label = ngettext ("%d muted article dimmed", "%d muted articles dimmed", dimmed).printf (dimmed);
                muted_toggle.visible = false;
            }
        }

        private string mute_word (Article a) {
            if (revealed.contains (a.key)) return "";
            var r = app.mute.match (a);
            return r != null ? r.pattern : "";
        }

        private Article saved_article (SavedArticle s) {
            var a = saved_cache[s.key];
            if (a == null) {
                a = saved.to_article (s);
                saved_cache[s.key] = a;
            }
            return a;
        }

        private string saved_key (Article a) {
            return a.feed_id == SavedStore.FEED_ID ? a.guid : a.key;
        }

        private void launch (string uri) {
            new UriLauncher (uri).launch.begin (this, null, (o, res) => {
                try {
                    new UriLauncher (uri).launch.end (res);
                } catch (Error e) {
                }
            });
        }

        private void sync_stack () {
            bool has = store.feeds.size > 0;
            stack.visible_child_name = has ? "main" : "welcome";
            set_sidebar_visible (has);
            sync_bubbles ();
        }

        private void sync_bubbles () {
            bool main = store.feeds.size > 0;
            search.visible = main;
            add_bubble.visible = main;
            refresh_bubble.visible = main;
            read_all_bubble.visible = main;
            refresh_bubble.sensitive = !refresher.running;
            bool has = main && current != null;
            bool copy = has && current.feed_id == SavedStore.FEED_ID;
            unread_bubble.visible = has && !copy;
            star_bubble.visible = has && !copy;
            save_bubble.visible = has;
            save_bubble.sensitive = !saving;
            browser_bubble.visible = has && current.link != "";
            if (current != null) {
                bool is_saved = saved.is_saved (saved_key (current));
                save_bubble.icon_name = is_saved ? "user-bookmarks-symbolic" : "bookmark-new-symbolic";
                save_bubble.tooltip_text = is_saved ? _("Remove from Saved (Ctrl+D)") : _("Save for Later (Ctrl+D)");
            }
            if (current != null) {
                unread_bubble.icon_name = current.unread ? "mail-read-symbolic" : "mail-unread-symbolic";
                unread_bubble.tooltip_text = current.unread ? _("Mark as Read (M)") : _("Mark as Unread (M)");
                star_bubble.icon_name = current.starred ? "starred-symbolic" : "non-starred-symbolic";
                star_bubble.tooltip_text = current.starred ? _("Remove Star (S)") : _("Star (S)");
            }
            enable_action ("export", main);
            enable_action ("find", main);
            enable_action ("next", main);
            enable_action ("previous", main);
            enable_action ("sidebar", main);
            enable_action ("mark-all-read", main);
            enable_action ("show-saved", main);
            enable_action ("refresh", main && !refresher.running);
            enable_action ("toggle-read", has && !copy);
            enable_action ("toggle-star", has && !copy);
            enable_action ("save-later", has && !saving);
            enable_action ("open-browser", has && current.link != "");
            enable_action ("share", has && current.link != "");
            enable_action ("full-article", has && !copy && current.link != "");
        }

        private void enable_action (string name, bool on) {
            var a = lookup_action (name) as SimpleAction;
            if (a != null) a.set_enabled (on);
        }

        private void add_source_row (string id, string icon, string title, bool nested = false) {
            var row = new SidebarRow (icon, title);
            if (nested) row.add_css_class ("news-sidebar-nested");
            var badge = new Label ("");
            badge.add_css_class ("news-count");
            var inner = row.get_child () as Box;
            if (inner != null) inner.append (badge);
            row.clicked.connect (() => select_source (id));
            rows[id] = row;
            badges[id] = badge;
            if (id.has_prefix ("feed:") || id.has_prefix ("folder:")) {
                var click = new GestureClick ();
                click.button = 3;
                click.pressed.connect ((n, x, y) => {
                    click.set_state (EventSequenceState.CLAIMED);
                    if (id.has_prefix ("feed:")) {
                        var f = store.feed (id.substring (5));
                        if (f != null) feed_menu (row, f, x, y);
                    } else {
                        folder_menu (row, id.substring (7), x, y);
                    }
                });
                row.add_controller (click);
            }
            sidebar.box.append (row);
        }

        private void rebuild_sidebar () {
            Widget? child;
            while ((child = sidebar.box.get_first_child ()) != null) sidebar.box.remove (child);
            rows.clear ();
            badges.clear ();
            feed_index.clear ();
            foreach (var f in store.feeds) {
                feed_index[f.id] = f;
                if (!watched.contains (f.id)) {
                    watched.add (f.id);
                    string fid = f.id;
                    f.notify["busy"].connect (() => sync_feed_row (fid));
                    f.notify["error"].connect (() => sync_feed_row (fid));
                }
            }
            add_source_row ("all", "news-feed-symbolic", _("All Articles"));
            add_source_row ("unread", "mail-unread-symbolic", _("Unread"));
            add_source_row ("starred", "starred-symbolic", _("Starred"));
            add_source_row ("saved", "user-bookmarks-symbolic", _("Saved"));
            var sorted = new Gee.ArrayList<Feed> ();
            sorted.add_all (store.feeds);
            sorted.sort ((a, b) => a.display_title.collate (b.display_title));
            bool loose = false;
            foreach (var f in sorted) if (f.folder == "") loose = true;
            if (loose || store.folders.size > 0) sidebar.box.append (new SidebarSectionLabel (_("Feeds")));
            foreach (var f in sorted) {
                if (f.folder != "") continue;
                add_source_row ("feed:" + f.id, "news-feed-symbolic", f.display_title);
                sync_feed_row (f.id);
            }
            var folders = new Gee.ArrayList<string> ();
            folders.add_all (store.folders);
            folders.sort ((a, b) => a.collate (b));
            foreach (string name in folders) {
                add_source_row ("folder:" + name, "folder-symbolic", name);
                foreach (var f in sorted) {
                    if (f.folder != name) continue;
                    add_source_row ("feed:" + f.id, "news-feed-symbolic", f.display_title, true);
                    sync_feed_row (f.id);
                }
            }
            if (!rows.has_key (source)) source = "all";
            foreach (var e in rows.entries) e.value.set_active (e.key == source);
            update_badges ();
        }

        private void sync_feed_row (string id) {
            var row = rows["feed:" + id];
            var f = feed_index[id];
            if (row == null || f == null) return;
            if (f.busy) {
                row.update_icon_name ("view-refresh-symbolic");
                row.tooltip_text = _("Updating…");
            } else if (f.error != "") {
                row.update_icon_name ("dialog-warning-symbolic");
                row.tooltip_text = f.error;
            } else {
                row.update_icon_name ("news-feed-symbolic");
                row.tooltip_text = f.url;
            }
            if (source == "feed:" + id && list_stack.visible_child_name == "empty") update_empty ();
        }

        private void update_badges () {
            var folder_counts = new Gee.HashMap<string, int> ();
            foreach (var f in store.feeds) {
                if (f.folder != "") folder_counts[f.folder] = folder_counts[f.folder] + f.unread;
                set_badge ("feed:" + f.id, f.unread);
            }
            foreach (string name in store.folders) set_badge ("folder:" + name, folder_counts.has_key (name) ? folder_counts[name] : 0);
            int total = store.total_unread ();
            set_badge ("all", total);
            set_badge ("unread", total);
            set_badge ("starred", store.total_starred ());
            set_badge ("saved", saved.items.size);
            sync_bubbles ();
        }

        private void set_badge (string id, int count) {
            var b = badges[id];
            if (b == null) return;
            b.label = count > 9999 ? "9999+" : count.to_string ();
            b.visible = count > 0;
        }

        private void select_source (string id) {
            bool was_saved = source == "saved";
            source = id;
            foreach (var e in rows.entries) e.value.set_active (e.key == id);
            current = null;
            rebuild_list ();
            show_article (null);
            if (id == "saved") show_saved_usage ();
            else if (was_saved) show_status ("", false);
        }

        private bool in_source (Article a) {
            if (a == current) return true;
            bool unread_only = store.unread_only;
            switch (source) {
                case "all": return !unread_only || a.unread;
                case "unread": return a.unread;
                case "starred": return a.starred;
            }
            if (unread_only && !a.unread) return false;
            if (source.has_prefix ("feed:")) return a.feed_id == source.substring (5);
            if (source.has_prefix ("folder:")) {
                var f = feed_index[a.feed_id];
                return f != null && f.folder == source.substring (7);
            }
            return true;
        }

        private void schedule_rebuild () {
            if (rebuild_id != 0) return;
            rebuild_id = Timeout.add (120, () => {
                rebuild_id = 0;
                rebuild_list ();
                return Source.REMOVE;
            });
        }

        private void rebuild_list () {
            if (rebuild_id != 0) {
                Source.remove (rebuild_id);
                rebuild_id = 0;
            }
            var items = new Gee.ArrayList<Article> ();
            int hidden = 0, dimmed = 0;
            if (source == "saved") {
                var alive = new Gee.HashSet<string> ();
                foreach (var s in saved.sorted ()) {
                    alive.add (s.key);
                    var a = saved_article (s);
                    if (a.matches (query)) items.add (a);
                }
                var stale = new Gee.ArrayList<string> ();
                foreach (string k in saved_cache.keys) if (!alive.contains (k)) stale.add (k);
                foreach (string k in stale) saved_cache.unset (k);
            } else {
                foreach (var a in store.articles.values) {
                    if (!feed_index.has_key (a.feed_id)) continue;
                    if (!in_source (a) || !a.matches (query)) continue;
                    string word = a == current ? "" : mute_word (a);
                    if (word != "") {
                        if (!app.mute_dims && !show_muted) {
                            hidden++;
                            continue;
                        }
                        dimmed++;
                    }
                    if (a.muted != word) a.muted = word;
                    items.add (a);
                }
                items.sort ((a, b) => {
                    if (a.published != b.published) return a.published > b.published ? -1 : 1;
                    return strcmp (a.title, b.title);
                });
            }
            update_muted_bar (hidden, dimmed);
            Object[] arr = new Object[items.size];
            int keep = -1;
            for (int i = 0; i < items.size; i++) {
                arr[i] = items[i];
                if (items[i] == current) keep = i;
            }
            rebuilding = true;
            model.splice (0, model.get_n_items (), arr);
            selection.selected = keep >= 0 ? keep : INVALID_LIST_POSITION;
            rebuilding = false;
            if (keep < 0 && current != null) show_article (null);
            var shown = list_empty.get_first_child ();
            bool from_skeleton = list_stack.visible_child_name == "empty" && shown != null && shown.has_css_class ("news-skeleton");
            list_stack.visible_child_name = items.size > 0 ? "list" : "empty";
            if (from_skeleton && items.size > 0) {
                var page = list_stack.visible_child;
                page.opacity = 0.0;
                Singularity.Motion.tween (page, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            }
            if (current == null) article_stack.visible_child_name = items.size > 0 ? "none" : "blank";
            if (source == "saved") show_saved_usage ();
            if (items.size == 0) update_empty ();
        }

        private void update_empty () {
            var old = list_empty.get_first_child ();
            if (old != null) list_empty.remove (old);
            list_empty.append (build_empty ());
        }

        private StatusPage status_empty (string icon, string title, string description) {
            var page = new StatusPage ();
            page.icon_name = icon;
            page.title = title;
            page.description = description;
            page.vexpand = true;
            return page;
        }

        private Button pill (string label, bool suggested) {
            var b = new Button.with_label (label);
            b.add_css_class ("pill");
            if (suggested) b.add_css_class ("suggested-action");
            b.halign = Align.CENTER;
            return b;
        }

        private Widget loading_skeleton (string description) {
            var skeleton = Singularity.Widgets.Skeleton.list (6, false);
            skeleton.add_css_class ("news-skeleton");
            skeleton.valign = Align.START;
            skeleton.update_property (AccessibleProperty.LABEL, description, -1);
            return skeleton;
        }

        private WelcomePage welcome_empty (string icon, string title, string subtitle) {
            var wp = new WelcomePage ();
            wp.is_section = true;
            wp.vexpand = true;
            wp.app_icon_name = icon;
            wp.title = title;
            wp.subtitle = subtitle;
            return wp;
        }

        private Widget build_empty () {
            if (query != "") {
                var page = status_empty ("system-search", _("No Results"), _("No articles match your search."));
                var clear = pill (_("Clear Search"), true);
                clear.clicked.connect (() => search.clear ());
                page.child = clear;
                return page;
            }
            if (source.has_prefix ("feed:")) {
                var f = feed_index[source.substring (5)];
                if (f != null && f.error != "") {
                    var page = status_empty ("network-error", _("Could Not Update This Feed"), f.error);
                    var retry = pill (_("Try Again"), false);
                    retry.clicked.connect (() => refresh_feeds (single (f)));
                    page.child = retry;
                    return page;
                }
                if (f != null && (f.busy || f.last_checked == 0)) {
                    return loading_skeleton (_("Getting the latest from %s.").printf (f.display_title));
                }
            }
            if (refresher.running && store.articles.size == 0) {
                return loading_skeleton (_("Getting the latest from your feeds."));
            }
            WelcomePage wp;
            switch (source) {
                case "saved":
                    wp = welcome_empty ("user-bookmarks", _("No Saved Articles"), _("Save an article with Ctrl+D to keep it here. Saved articles can be read offline."));
                    wp.add_action ("dev.sinty.news", _("All Articles"), _("Pick something to save for later"), () => select_source ("all"));
                    return wp;
                case "unread":
                    wp = welcome_empty ("dev.sinty.news", _("All Caught Up"), _("There are no unread articles."));
                    wp.add_action ("emblem-synchronizing", _("Refresh Feeds"), _("Look for new articles now"), () => refresh_all ());
                    wp.add_action ("network-workgroup", _("Add Feed"), _("Follow another website"), () => add_feed (""));
                    return wp;
                case "starred":
                    wp = welcome_empty ("dev.sinty.news", _("No Starred Articles"), _("Star articles to keep them here for later."));
                    wp.add_action ("dev.sinty.news", _("All Articles"), _("Pick something to star"), () => select_source ("all"));
                    return wp;
            }
            if (store.unread_only) {
                wp = welcome_empty ("dev.sinty.news", _("All Caught Up"), _("There are no unread articles here."));
                wp.add_action ("text-html", _("Show Read Articles"), _("Turn off Show Only Unread"), () => ((GLib.ActionGroup) this).activate_action ("unread-only", null));
                wp.add_action ("emblem-synchronizing", _("Refresh Feeds"), _("Look for new articles now"), () => refresh_all ());
                return wp;
            }
            wp = welcome_empty ("dev.sinty.news", _("No Articles"), _("New articles appear here as soon as they are published."));
            wp.add_action ("emblem-synchronizing", _("Refresh Feeds"), _("Look for new articles now"), () => refresh_all ());
            wp.add_action ("network-workgroup", _("Add Feed"), _("Follow another website"), () => add_feed (""));
            return wp;
        }

        private static Gee.List<Feed> single (Feed f) {
            var l = new Gee.ArrayList<Feed> ();
            l.add (f);
            return l;
        }

        private bool wants_full (Article a, Feed? f) {
            if (a.link == "" || a.feed_id == SavedStore.FEED_ID) return false;
            if (full_choice.has_key (a.key)) return full_choice[a.key];
            string mode = f != null ? f.full_text : "auto";
            if (mode == "always") return true;
            if (mode == "never") return false;
            return Extract.is_truncated (a.content);
        }

        private bool accept_full (Article a, Feed? f, string html) {
            if (full_choice.has_key (a.key) && full_choice[a.key]) return true;
            if (f != null && f.full_text == "always") return true;
            return Extract.improves (html, a.content);
        }

        private static string host_of (string url) {
            try {
                return Uri.parse (url, UriFlags.NONE).get_host () ?? url;
            } catch (Error e) {
                return url;
            }
        }

        private void show_full_notice () {
            if (current == null) return;
            switch (full_state) {
                case FullState.LOADING:
                    article_view.set_notice (_("Loading the full article…"), _("Show Feed Version"), true);
                    break;
                case FullState.SHOWN:
                    article_view.set_notice (_("Full article from %s").printf (host_of (current.link)), _("Show Feed Version"), false);
                    break;
                case FullState.FAILED:
                    article_view.set_notice (_("The full article could not be loaded."), _("Try Again"), false);
                    break;
                default:
                    if (current.feed_id == SavedStore.FEED_ID) {
                        var s = saved.find (current.guid);
                        string when = s != null ? ArticleView.format_full_date (s.saved_at) : "";
                        article_view.set_notice (s != null && s.full ? _("Full article saved %s").printf (when) : _("Saved %s").printf (when), "", false);
                    } else if (current.link != "") {
                        article_view.set_notice ("", _("Load Full Article"), false);
                    } else {
                        article_view.set_notice ("", "", false);
                    }
                    break;
            }
        }

        private void show_article (Article? a) {
            if (full_cancel != null) {
                full_cancel.cancel ();
                full_cancel = null;
            }
            current = a;
            full_state = FullState.NONE;
            if (a == null) {
                article_stack.visible_child_name = model.get_n_items () > 0 ? "none" : "blank";
                sync_bubbles ();
                return;
            }
            if (a.muted != "") {
                revealed.add (a.key);
                a.muted = "";
                update_muted_bar (muted_hidden, int.max (0, muted_dimmed - 1));
            }
            var f = feed_index[a.feed_id];
            string html = a.content;
            if (wants_full (a, f)) {
                string? cached = full_text.cached (a.link);
                if (cached != null) {
                    if (accept_full (a, f, cached)) {
                        html = cached;
                        full_state = FullState.SHOWN;
                    }
                } else if (full_text.has_failed (a.link)) {
                    full_state = FullState.FAILED;
                } else {
                    full_state = FullState.LOADING;
                    load_full (a, f);
                }
            }
            article_view.show_article (a, f != null ? f.display_title : a.source_name, f != null ? f.url : "", html);
            show_full_notice ();
            article_scroll.vadjustment.value = 0;
            article_stack.visible_child_name = "article";
            if (store.mark_read_on_open && a.feed_id != SavedStore.FEED_ID) store.set_unread (a, false);
            sync_bubbles ();
        }

        private void load_full (Article a, Feed? f) {
            var cancel = new Cancellable ();
            full_cancel = cancel;
            full_text.load.begin (a.link, a.title, cancel, (o, res) => {
                string? html = null;
                try {
                    html = full_text.load.end (res);
                } catch (Error e) {
                    html = null;
                }
                if (cancel.is_cancelled () || current != a) return;
                full_cancel = null;
                if (html == null) {
                    full_state = FullState.FAILED;
                } else if (accept_full (a, f, html)) {
                    full_state = FullState.SHOWN;
                    article_view.replace_body (html);
                } else {
                    full_state = FullState.NONE;
                }
                show_full_notice ();
            });
        }

        private void on_notice_action () {
            if (current == null || current.link == "" || current.feed_id == SavedStore.FEED_ID) return;
            switch (full_state) {
                case FullState.SHOWN:
                case FullState.LOADING:
                    full_choice[current.key] = false;
                    break;
                default:
                    full_text.forget_failure (current.link);
                    full_choice[current.key] = true;
                    break;
            }
            var keep = article_scroll.vadjustment.value;
            show_article (current);
            if (full_state != FullState.LOADING) article_scroll.vadjustment.value = keep;
        }

        private void toggle_saved () {
            if (current == null || saving) return;
            string key = saved_key (current);
            var s = saved.find (key);
            if (s != null) {
                saved.remove (s);
                saved_cache.unset (key);
                if (source == "saved") {
                    current = null;
                    rebuild_list ();
                    show_article (null);
                }
                show_status (_("Removed from saved articles"), true);
                sync_bubbles ();
                return;
            }
            save_for_later.begin (current);
        }

        private async void save_for_later (Article a) {
            saving = true;
            sync_bubbles ();
            show_status (_("Saving for later…"), false);
            var f = feed_index[a.feed_id];
            string html = a.content;
            bool full = false;
            if (a.link != "") {
                string? extracted = full_text.cached (a.link);
                if (extracted == null && wants_full (a, f)) {
                    try {
                        extracted = yield full_text.load (a.link, a.title, null);
                    } catch (Error e) {
                        extracted = null;
                    }
                }
                if (extracted != null && accept_full (a, f, extracted)) {
                    html = extracted;
                    full = true;
                }
            }
            var urls = SavedStore.image_urls (html, a.link, a.thumbnail);
            var images = new Gee.HashMap<string, Bytes> ();
            foreach (string url in urls) {
                var bytes = yield ImageCache.get_default ().fetch_bytes (url, null);
                if (bytes != null) images[url] = bytes;
            }
            try {
                var s = saved.add (a, f != null ? f.display_title : a.source_name, html, full, images, get_real_time () / 1000000);
                ImageCache.get_default ().register_local (saved.local_images (s));
                int missing = urls.size - s.images.size;
                if (missing > 0) show_status (ngettext ("Saved for later, but %d image could not be kept", "Saved for later, but %d images could not be kept", missing).printf (missing), true);
                else show_status (_("Saved for later. You can read it offline."), true);
            } catch (Error e) {
                show_status ("", false);
                Dialogs.error (app, this, _("Could Not Save the Article"), e.message);
            }
            saving = false;
            sync_bubbles ();
        }

        private void show_saved_usage () {
            if (source != "saved") return;
            int n = saved.items.size;
            if (n == 0) {
                show_status ("", false);
                return;
            }
            show_status (ngettext ("%d saved article, %s of %s used", "%d saved articles, %s of %s used", n).printf (n, format_size ((uint64) saved.total_size ()), format_size ((uint64) saved.limit_bytes)), false);
        }

        private void move (int delta) {
            uint n = model.get_n_items ();
            if (n == 0) return;
            uint pos = selection.selected;
            uint next;
            if (pos == INVALID_LIST_POSITION) next = delta > 0 ? 0 : n - 1;
            else if (delta > 0) next = uint.min (pos + 1, n - 1);
            else next = pos > 0 ? pos - 1 : 0;
            if (next == pos) return;
            selection.selected = next;
            list.scroll_to (next, ListScrollFlags.NONE, null);
        }

        private void toggle_read () {
            if (current == null) return;
            store.set_unread (current, !current.unread);
            sync_bubbles ();
        }

        private void toggle_star () {
            if (current == null) return;
            store.set_starred (current, !current.starred);
            update_badges ();
        }

        private void open_in_browser () {
            if (current != null && current.link != "") launch (current.link);
        }

        private void mark_all_read () {
            var list_items = new Gee.ArrayList<Article> ();
            for (uint i = 0; i < model.get_n_items (); i++) list_items.add ((Article) model.get_item (i));
            int n = store.mark_read (list_items);
            show_status (n > 0 ? ngettext ("%d article marked as read", "%d articles marked as read", n).printf (n) : _("Everything here is already read"), true);
            sync_bubbles ();
        }

        private void maybe_refresh () {
            if (refresher.running || store.feeds.size == 0) return;
            int64 now = get_real_time () / 1000000;
            if (now - store.last_refresh < (int64) store.refresh_minutes * 60) return;
            if (!NetworkMonitor.get_default ().network_available) {
                show_status (_("You are offline. Showing saved articles."), false);
                return;
            }
            refresh_all ();
        }

        public void refresh_all () {
            refresh_feeds (store.feeds);
        }

        private void refresh_feeds (Gee.Collection<Feed> feeds) {
            if (feeds.size == 0) return;
            refresher.refresh (feeds);
            sync_bubbles ();
            show_progress ();
            if (list_stack.visible_child_name == "empty") update_empty ();
        }

        private void show_progress () {
            if (!refresher.running) return;
            show_status (_("Updating feeds (%d of %d)…").printf (refresher.done, refresher.total), false);
        }

        private void on_refreshed (int added, int failed, bool offline) {
            sync_bubbles ();
            rebuild_sidebar ();
            schedule_rebuild ();
            if (offline) show_status (_("You are offline. Showing saved articles."), false);
            else if (failed > 0) show_status (ngettext ("%d feed could not be updated", "%d feeds could not be updated", failed).printf (failed), false);
            else if (added > 0) show_status (ngettext ("%d new article", "%d new articles", added).printf (added), true);
            else show_status (_("Everything is up to date"), true);
        }

        private void show_status (string text, bool fade) {
            if (status_clear_id != 0) {
                Source.remove (status_clear_id);
                status_clear_id = 0;
            }
            status_label.label = text;
            status_label.visible = text != "";
            if (fade) status_clear_id = Timeout.add_seconds (6, () => {
                status_clear_id = 0;
                status_label.visible = false;
                return Source.REMOVE;
            });
        }

        public void add_feed (string initial) {
            var dlg = new AddFeedDialog (app, store, refresher.fetcher, initial);
            dlg.transient_for = this;
            dlg.added.connect ((feed, parsed, fetch) => {
                int64 now = get_real_time () / 1000000;
                feed.etag = fetch.etag;
                feed.last_modified = fetch.last_modified;
                feed.last_checked = now;
                store.merge (feed, parsed, now);
                rebuild_sidebar ();
                select_source ("feed:" + feed.id);
            });
            dlg.present ();
        }

        private void popup_menu (ContextMenu menu, Widget anchor, double x, double y) {
            var rect = Gdk.Rectangle ();
            rect.x = (int) x;
            rect.y = (int) y;
            rect.width = 1;
            rect.height = 1;
            menu.pointing_to = rect;
            menu.position = PositionType.BOTTOM;
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void feed_menu (Widget row, Feed f, double x, double y) {
            var menu = new ContextMenu (row);
            menu.add_item (_("Refresh"), "view-refresh-symbolic", () => refresh_feeds (single (f)));
            menu.add_item (_("Mark as Read"), "news-mark-read-symbolic", () => {
                var l = new Gee.ArrayList<Article> ();
                foreach (var a in store.articles.values) if (a.feed_id == f.id) l.add (a);
                store.mark_read (l);
            });
            menu.add_item (_("Rename…"), "document-edit-symbolic", () => {
                Dialogs.ask_name (app, this, _("Rename Feed"), _("Name"), f.display_title, _("Rename"), (name) => store.rename_feed (f, name));
            });
            var sub = menu.add_submenu (_("Move To"), "folder-symbolic");
            sub.add_item (_("No Folder"), f.folder == "" ? "object-select-symbolic" : null, () => store.move_feed (f, ""));
            foreach (string name in store.folders) {
                string target = name;
                sub.add_item (name, f.folder == name ? "object-select-symbolic" : null, () => store.move_feed (f, target));
            }
            sub.add_item (_("New Folder…"), "folder-new-symbolic", () => {
                Dialogs.ask_name (app, this, _("New Folder"), _("Folder Name"), "", _("Create"), (name) => store.move_feed (f, name));
            });
            var full = menu.add_submenu (_("Full Article"), "x-office-document-symbolic");
            string[] modes = { "auto", "always", "never" };
            string[] labels = { _("When the Feed Is Short"), _("Always"), _("Never") };
            for (int i = 0; i < modes.length; i++) {
                string mode = modes[i];
                full.add_item (labels[i], f.full_text == mode ? "object-select-symbolic" : null, () => {
                    store.set_full_text (f, mode);
                    full_choice.clear ();
                    if (current != null && current.feed_id == f.id) show_article (current);
                });
            }
            menu.add_separator ();
            if (f.site_url != "") menu.add_item (_("Open Website"), "web-browser-symbolic", () => launch (f.site_url));
            menu.add_item (_("Copy Feed Address"), "edit-copy-symbolic", () => get_clipboard ().set_text (f.url));
            menu.add_separator ();
            menu.add_item (_("Unfollow…"), "user-trash-symbolic", () => confirm_remove (f), "destructive-action");
            popup_menu (menu, row, x, y);
        }

        private void folder_menu (Widget row, string name, double x, double y) {
            var menu = new ContextMenu (row);
            menu.add_item (_("Mark as Read"), "news-mark-read-symbolic", () => {
                var l = new Gee.ArrayList<Article> ();
                foreach (var a in store.articles.values) {
                    var f = feed_index[a.feed_id];
                    if (f != null && f.folder == name) l.add (a);
                }
                store.mark_read (l);
            });
            menu.add_item (_("Rename…"), "document-edit-symbolic", () => {
                Dialogs.ask_name (app, this, _("Rename Folder"), _("Folder Name"), name, _("Rename"), (n) => {
                    if (source == "folder:" + name) source = "folder:" + n;
                    store.rename_folder (name, n);
                });
            });
            menu.add_separator ();
            menu.add_item (_("Delete Folder…"), "user-trash-symbolic", () => {
                var dlg = new ConfirmDialog (app, _("Delete %s?").printf (name), null, _("The feeds in this folder are kept and moved out of it."), _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
                dlg.transient_for = this;
                dlg.response.connect ((r) => {
                    if (r == ConfirmDialog.Response.PRIMARY) store.remove_folder (name);
                });
                dlg.present ();
            }, "destructive-action");
            popup_menu (menu, row, x, y);
        }

        private void confirm_remove (Feed f) {
            var dlg = new ConfirmDialog (app, _("Unfollow %s?").printf (f.display_title), null, _("Its saved articles are removed from this computer, starred ones included."), _("Unfollow"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                if (current != null && current.feed_id == f.id) current = null;
                if (source == "feed:" + f.id) source = "all";
                store.remove_feed (f);
                show_article (current);
            });
            dlg.present ();
        }

        private void new_folder () {
            Dialogs.ask_name (app, this, _("New Folder"), _("Folder Name"), "", _("Create"), (name) => store.add_folder (name));
        }

        public void import_opml () {
            var dialog = new FileDialog ();
            dialog.title = _("Import Subscriptions");
            var filters = new GLib.ListStore (typeof (FileFilter));
            var f = new FileFilter ();
            f.name = _("OPML Files");
            f.add_pattern ("*.opml");
            f.add_pattern ("*.xml");
            f.add_mime_type ("text/x-opml+xml");
            f.add_mime_type ("text/x-opml");
            filters.append (f);
            dialog.filters = filters;
            dialog.open.begin (this, null, (o, res) => {
                try {
                    import_opml_file.begin (dialog.open.end (res));
                } catch (Error e) {
                }
            });
        }

        public async void import_opml_file (File file) {
            try {
                uint8[] data;
                yield file.load_contents_async (null, out data, null);
                var entries = Opml.parse ((string) data);
                var added = store.import_entries (entries);
                if (entries.size == 0) {
                    Dialogs.error (app, this, _("Nothing to Import"), _("The file does not list any feeds."));
                    return;
                }
                show_status (added.size > 0 ? ngettext ("%d feed imported", "%d feeds imported", added.size).printf (added.size) : _("You already follow all the feeds in this file."), true);
                refresh_feeds (added);
            } catch (Error e) {
                Dialogs.error (app, this, _("Could Not Import"), e.message);
            }
        }

        public void export_opml () {
            var dialog = new FileDialog ();
            dialog.title = _("Export Subscriptions");
            dialog.initial_name = "subscriptions.opml";
            dialog.save.begin (this, null, (o, res) => {
                try {
                    var file = dialog.save.end (res);
                    string text = Opml.serialize (store.export_entries (), _("News Subscriptions"));
                    file.replace_contents_bytes_async.begin (new Bytes (text.data), null, false, FileCreateFlags.REPLACE_DESTINATION, null, (o2, r2) => {
                        try {
                            file.replace_contents_bytes_async.end (r2, null);
                            show_status (_("Subscriptions exported"), true);
                        } catch (Error e) {
                            Dialogs.error (app, this, _("Could Not Export"), e.message);
                        }
                    });
                } catch (Error e) {
                }
            });
        }

        public void open_article (string key) {
            var a = store.articles[key];
            if (a == null || store.feed (a.feed_id) == null) return;
            if (search.text != "") search.text = "";
            query = "";
            select_source ("feed:" + a.feed_id);
            show_article (a);
            rebuild_list ();
        }

        public void search_for (string text) {
            search.text = text;
            query = text.strip ();
            rebuild_list ();
        }

        public void set_unread_only (bool on) {
            store.unread_only = on;
            store.touch_meta ();
            rebuild_list ();
        }

        private void install_actions () {
            string[] names = { "add", "import", "export", "new-folder", "refresh", "mark-all-read", "toggle-read", "toggle-star", "open-browser", "share", "find", "next", "previous", "sidebar", "save-later", "muted-words", "full-article", "show-saved", "close" };
            foreach (string n in names) {
                var a = new SimpleAction (n, null);
                string name = n;
                a.activate.connect (() => {
                    switch (name) {
                        case "add": add_feed (""); break;
                        case "import": import_opml (); break;
                        case "export": export_opml (); break;
                        case "new-folder": new_folder (); break;
                        case "refresh": refresh_all (); break;
                        case "mark-all-read": mark_all_read (); break;
                        case "toggle-read": toggle_read (); break;
                        case "toggle-star": toggle_star (); break;
                        case "open-browser": open_in_browser (); break;
                        case "share": if (current != null && current.link != "") Singularity.Share.uris (this, { current.link }, current.title); break;
                        case "find": if (store.feeds.size > 0) search.grab_focus_entry (); break;
                        case "next": move (1); break;
                        case "previous": move (-1); break;
                        case "sidebar": if (store.feeds.size > 0) set_sidebar_visible (!get_sidebar_visible ()); break;
                        case "save-later": toggle_saved (); break;
                        case "muted-words": open_muted_words (); break;
                        case "full-article": on_notice_action (); break;
                        case "show-saved": if (store.feeds.size > 0) select_source ("saved"); break;
                        case "close": close (); break;
                    }
                });
                add_action (a);
            }
            var unread_only = new SimpleAction.stateful ("unread-only", null, new Variant.boolean (store.unread_only));
            unread_only.activate.connect (() => {
                bool v = !unread_only.get_state ().get_boolean ();
                unread_only.set_state (new Variant.boolean (v));
                set_unread_only (v);
            });
            add_action (unread_only);
            show_muted_action = new SimpleAction.stateful ("show-muted", null, new Variant.boolean (false));
            show_muted_action.activate.connect (() => set_show_muted (!show_muted));
            show_muted_action.set_enabled (!app.mute_dims);
            add_action (show_muted_action);

            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                if ((state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK | Gdk.ModifierType.SUPER_MASK)) != 0) return false;
                var focus = get_focus ();
                if (focus is Editable) {
                    if (keyval == Gdk.Key.Escape && search.text != "") {
                        search.clear ();
                        list.grab_focus ();
                        return true;
                    }
                    if (keyval == Gdk.Key.Down && focus.is_ancestor (search)) {
                        list.grab_focus ();
                        return true;
                    }
                    return false;
                }
                if (store.feeds.size == 0) return false;
                switch (keyval) {
                    case Gdk.Key.j:
                    case Gdk.Key.n:
                        move (1);
                        return true;
                    case Gdk.Key.k:
                    case Gdk.Key.p:
                        move (-1);
                        return true;
                    case Gdk.Key.m:
                        toggle_read ();
                        return true;
                    case Gdk.Key.s:
                        toggle_star ();
                        return true;
                    case Gdk.Key.o:
                    case Gdk.Key.v:
                        open_in_browser ();
                        return true;
                    case Gdk.Key.slash:
                        search.grab_focus_entry ();
                        return true;
                    case Gdk.Key.Right:
                        if (current != null && list.get_focus_child () != null) {
                            article_view.focus_body ();
                            return true;
                        }
                        return false;
                    case Gdk.Key.Left:
                        if (current != null && list.get_focus_child () == null) {
                            list.grab_focus ();
                            return true;
                        }
                        return false;
                }
                return false;
            });
            ((Widget) this).add_controller (keys);
        }
    }
}
