using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.News {

    public class AddFeedDialog : ConfirmDialog {
        public signal void added (Feed feed, ParsedFeed parsed, FetchResult fetch);

        private Store store;
        private Fetcher fetcher;
        private EntryRow address;
        private SelectionRow folder;
        private SelectionRow? choice;
        private PreferencesGroup group;
        private Box status;
        private Spinner spinner;
        private Label hint;
        private bool hold;
        private bool busy;
        private Cancellable? cancel;
        private Gee.List<FeedLink>? choices;

        public AddFeedDialog (Gtk.Application app, Store store, Fetcher fetcher, string initial) {
            base (app, _("Add Feed"), null, _("Enter the address of a feed or of a website that has one."), _("Add"), ConfirmDialog.ActionStyle.SUGGESTED);
            this.store = store;
            this.fetcher = fetcher;
            group = new PreferencesGroup ();
            address = new EntryRow (_("Address"));
            address.text = initial;
            group.add_row (address);
            string[] names = { _("No Folder") };
            foreach (string f in store.folders) names += f;
            folder = new SelectionRow (_("Folder"), names, names[0]);
            folder.selected.connect ((v) => folder.current_value = v);
            group.add_row (folder);
            custom_area.append (group);

            status = new Box (Orientation.HORIZONTAL, 8);
            status.halign = Align.CENTER;
            spinner = new Spinner ();
            spinner.visible = false;
            status.append (spinner);
            hint = new Label ("");
            hint.wrap = true;
            hint.max_width_chars = 44;
            hint.justify = Justification.CENTER;
            hint.add_css_class ("dim-label");
            hint.add_css_class ("caption");
            hint.valign = Align.START;
            hint.map.connect (() => {
                int w, h;
                hint.create_pango_layout ("X\nX").get_pixel_size (out w, out h);
                hint.height_request = h;
            });
            status.append (hint);
            custom_area.append (status);

            address.entry_changed.connect (() => {
                choices = null;
                if (choice != null) {
                    group.remove_row (choice);
                    choice = null;
                }
                validate ();
            });
            address.entry_activated.connect (() => {
                if (primary_sensitive) {
                    response (ConfirmDialog.Response.PRIMARY);
                    close_dialog ();
                }
            });
            response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    hold = true;
                    start ();
                } else if (cancel != null) {
                    cancel.cancel ();
                }
            });
            validate ();
        }

        public override void close_dialog () {
            if (hold) {
                hold = false;
                return;
            }
            if (cancel != null) cancel.cancel ();
            base.close_dialog ();
        }

        private void validate () {
            string url = Discovery.normalize_address (address.text);
            primary_sensitive = url != "" && !busy;
            if (busy) return;
            if (address.text.strip () == "") show_hint (_("For example example.com or https://example.com/feed.xml"), false);
            else if (url == "") show_hint (_("This is not a web address."), false);
            else if (store.feed_by_url (url) != null) show_hint (_("You already follow this feed."), false);
            else show_hint ("", false);
        }

        private void show_hint (string text, bool working) {
            hint.label = text;
            spinner.visible = working;
            spinner.spinning = working;
            if (working) hint.remove_css_class ("error");
        }

        private void show_error (string text) {
            show_hint (text, false);
            hint.add_css_class ("error");
        }

        private string folder_name () {
            return folder.current_value == _("No Folder") ? "" : folder.current_value;
        }

        private void start () {
            string url = Discovery.normalize_address (address.text);
            if (choices != null && choice != null) {
                foreach (var l in choices) if (label_for (l) == choice.current_value) url = l.url;
            }
            if (url == "") return;
            var existing = store.feed_by_url (url);
            if (existing != null) {
                show_error (_("You already follow this feed."));
                return;
            }
            busy = true;
            primary_sensitive = false;
            address.sensitive = false;
            show_hint (_("Looking for the feed…"), true);
            cancel = new Cancellable ();
            fetcher.resolve.begin (url, cancel, (o, res) => {
                busy = false;
                address.sensitive = true;
                try {
                    var r = fetcher.resolve.end (res);
                    if (r.feed == null) {
                        offer_choices (r.choices);
                        return;
                    }
                    if (store.feed_by_url (r.url) != null) {
                        show_error (_("You already follow this feed."));
                        primary_sensitive = true;
                        return;
                    }
                    var feed = store.add_feed (r.url, r.feed.title, r.feed.site_url, folder_name ());
                    added (feed, r.feed, r.fetch);
                    base.close_dialog ();
                } catch (IOError.CANCELLED e) {
                } catch (Error e) {
                    show_error (e.message);
                    primary_sensitive = true;
                }
            });
        }

        private static string label_for (FeedLink l) {
            return l.title != "" ? "%s (%s)".printf (l.title, l.url) : l.url;
        }

        private void offer_choices (Gee.List<FeedLink> links) {
            choices = links;
            string[] labels = {};
            foreach (var l in links) labels += label_for (l);
            if (choice != null) group.remove_row (choice);
            choice = new SelectionRow (_("Feed"), labels, labels[0]);
            choice.selected.connect ((v) => choice.current_value = v);
            choice.expanded = true;
            group.add_row (choice);
            show_hint (_("This website has several feeds. Choose one."), false);
            primary_sensitive = true;
        }
    }

    public class MutedWordsDialog : AppDialog {
        private GLib.Settings settings;
        private EntryRow entry;
        private SegmentedControl kind;
        private Label hint;
        private Button add_button;
        private Box list_box;
        private ulong changed_id;

        public MutedWordsDialog (Gtk.Application app, GLib.Settings settings) {
            base (app, false);
            this.settings = settings;
            set_title (_("Muted Words"));
            set_default_size (480, 600);

            var box = new Box (Orientation.VERTICAL, 18);
            box.margin_top = 18;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;

            var intro = new Label (_("Articles that mention these words are hidden or dimmed, as chosen in Settings."));
            intro.wrap = true;
            intro.xalign = 0;
            intro.add_css_class ("dim-label");
            box.append (intro);

            var add_group = new PreferencesGroup (_("Add a Word or Phrase"));
            entry = new EntryRow (_("Word, Phrase or Pattern"));
            add_group.add_row (entry);
            box.append (add_group);

            kind = new SegmentedControl ();
            kind.add_option ("text", _("Contains"));
            kind.add_option ("word", _("Whole Word"));
            kind.add_option ("regex", _("Regular Expression"));
            kind.set_active ("text");
            kind.selected.connect (() => validate ());
            box.append (kind);

            var add_row = new Box (Orientation.HORIZONTAL, 12);
            hint = new Label ("");
            hint.wrap = true;
            hint.xalign = 0;
            hint.hexpand = true;
            hint.add_css_class ("caption");
            hint.add_css_class ("dim-label");
            add_row.append (hint);
            add_button = new Button.with_label (_("Mute"));
            add_button.add_css_class ("pill");
            add_button.add_css_class ("suggested-action");
            add_button.valign = Align.CENTER;
            add_button.clicked.connect (() => add_current ());
            add_row.append (add_button);
            box.append (add_row);

            list_box = new Box (Orientation.VERTICAL, 0);
            box.append (list_box);

            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = box;
            content_box.append (scroll);

            entry.entry_changed.connect (() => validate ());
            entry.entry_activated.connect (() => add_current ());
            changed_id = settings.changed["muted-words"].connect (() => rebuild ());
            close_request.connect (() => {
                if (changed_id != 0) settings.disconnect (changed_id);
                changed_id = 0;
                return false;
            });
            rebuild ();
            validate ();
        }

        private MuteKind current_kind () {
            switch (kind.active_option) {
                case "word": return MuteKind.WORD;
                case "regex": return MuteKind.REGEX;
                default: return MuteKind.CONTAINS;
            }
        }

        private MuteList current_list () {
            return new MuteList.from_strv (settings.get_strv ("muted-words"));
        }

        private void validate () {
            string text = entry.text.strip ();
            hint.remove_css_class ("error");
            if (text == "") {
                hint.label = current_kind () == MuteKind.REGEX ? _("For example (spoiler|leak)s?") : _("Matching ignores upper and lower case.");
                add_button.sensitive = false;
                return;
            }
            if (current_kind () == MuteKind.REGEX) {
                string? problem = MuteRule.regex_problem (text);
                if (problem != null) {
                    hint.label = problem;
                    hint.add_css_class ("error");
                    add_button.sensitive = false;
                    return;
                }
            }
            if (current_list ().contains (new MuteRule (text, current_kind ()))) {
                hint.label = _("This is already muted.");
                add_button.sensitive = false;
                return;
            }
            hint.label = current_kind () == MuteKind.WORD ? _("Only whole words match, so %s does not match longer words.").printf (text) : "";
            add_button.sensitive = true;
        }

        private void add_current () {
            if (!add_button.sensitive) return;
            var list = current_list ();
            list.rules.add (new MuteRule (entry.text.strip (), current_kind ()));
            settings.set_strv ("muted-words", list.to_strv ());
            entry.text = "";
            entry.grab_focus ();
        }

        private void rebuild () {
            Widget? child;
            while ((child = list_box.get_first_child ()) != null) list_box.remove (child);
            var list = current_list ();
            var group = new PreferencesGroup (_("Muted"));
            if (list.is_empty) {
                var row = new ActionRow (_("Nothing Is Muted"), _("Words you add appear here."));
                group.add_row (row);
            }
            foreach (var r in list.rules) {
                var row = new ActionRow (r.pattern, r.describe ());
                var remove = new Button.from_icon_name ("user-trash-symbolic");
                remove.add_css_class ("flat");
                remove.add_css_class ("circular");
                remove.valign = Align.CENTER;
                remove.tooltip_text = _("Unmute");
                remove.update_property (AccessibleProperty.LABEL, _("Unmute %s").printf (r.pattern), -1);
                var rule = r;
                remove.clicked.connect (() => {
                    var now = current_list ();
                    var keep = new MuteList ();
                    foreach (var x in now.rules) if (!(x.kind == rule.kind && x.pattern == rule.pattern)) keep.rules.add (x);
                    settings.set_strv ("muted-words", keep.to_strv ());
                });
                row.add_suffix (remove);
                group.add_row (row);
            }
            list_box.append (group);
            validate ();
        }
    }

    namespace Dialogs {
        public delegate void NameCallback (string name);

        public void ask_name (Gtk.Application app, Gtk.Window parent, string title, string label, string initial, string action, owned NameCallback done) {
            NameCallback cb = (owned) done;
            var dlg = new ConfirmDialog (app, title, null, null, action, ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = parent;
            var group = new PreferencesGroup ();
            var entry = new EntryRow (label);
            entry.text = initial;
            group.add_row (entry);
            dlg.custom_area.append (group);
            dlg.primary_sensitive = initial.strip () != "";
            entry.entry_changed.connect (() => dlg.primary_sensitive = entry.text.strip () != "");
            entry.entry_activated.connect (() => {
                if (entry.text.strip () == "") return;
                dlg.response (ConfirmDialog.Response.PRIMARY);
                dlg.close_dialog ();
            });
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) cb (entry.text.strip ());
            });
            dlg.present ();
            entry.grab_focus ();
        }

        public void error (Gtk.Application app, Gtk.Window parent, string title, string message) {
            var dlg = new ConfirmDialog.message (app, title, "dialog-error", message);
            dlg.transient_for = parent;
            dlg.present ();
        }
    }
}
