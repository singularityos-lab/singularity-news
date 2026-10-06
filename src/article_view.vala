using Gtk;

namespace Singularity.Apps.News {

    public class ArticleView : Box {
        public signal void open_link (string uri);
        public signal void notice_action ();

        private Label source_label;
        private Label title_label;
        private Label meta_label;
        private Box notice_box;
        private Label notice_label;
        private Button notice_button;
        private Spinner notice_spinner;
        private TextView text;
        private TextBuffer buffer;
        private Cancellable? loading;
        private Gee.ArrayList<TextTag> link_tags = new Gee.ArrayList<TextTag> ();
        private bool hovering_link;
        private string base_url = "";

        public ArticleView () {
            Object (orientation: Orientation.VERTICAL, spacing: 6);
            add_css_class ("news-article");
            margin_top = 64;
            margin_bottom = 48;
            margin_start = 32;
            margin_end = 32;

            source_label = new Label ("");
            source_label.xalign = 0;
            source_label.add_css_class ("news-article-source");
            source_label.ellipsize = Pango.EllipsizeMode.END;
            append (source_label);

            title_label = new Label ("");
            title_label.xalign = 0;
            title_label.wrap = true;
            title_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            title_label.selectable = true;
            title_label.can_focus = false;
            title_label.add_css_class ("news-article-title");
            append (title_label);

            meta_label = new Label ("");
            meta_label.xalign = 0;
            meta_label.wrap = true;
            meta_label.add_css_class ("dim-label");
            meta_label.margin_bottom = 12;
            append (meta_label);

            notice_box = new Box (Orientation.HORIZONTAL, 8);
            notice_box.margin_bottom = 12;
            notice_box.visible = false;
            notice_spinner = new Spinner ();
            notice_spinner.visible = false;
            notice_box.append (notice_spinner);
            notice_label = new Label ("");
            notice_label.xalign = 0;
            notice_label.ellipsize = Pango.EllipsizeMode.END;
            notice_label.add_css_class ("dim-label");
            notice_label.add_css_class ("caption");
            notice_box.append (notice_label);
            notice_button = new Button ();
            notice_button.add_css_class ("flat");
            notice_button.add_css_class ("caption");
            notice_button.clicked.connect (() => notice_action ());
            notice_box.append (notice_button);
            append (notice_box);

            buffer = new TextBuffer (null);
            text = new TextView.with_buffer (buffer);
            text.editable = false;
            text.cursor_visible = false;
            text.wrap_mode = WrapMode.WORD_CHAR;
            text.pixels_below_lines = 2;
            text.add_css_class ("news-article-body");
            text.vexpand = true;
            append (text);
            create_tags ();

            var click = new GestureClick ();
            click.button = 1;
            click.released.connect ((n, x, y) => {
                string? href = link_at (x, y);
                if (href != null) {
                    TextIter s, e;
                    if (!buffer.get_selection_bounds (out s, out e)) open_link (href);
                }
            });
            text.add_controller (click);
            var motion = new EventControllerMotion ();
            motion.motion.connect ((x, y) => {
                bool over = link_at (x, y) != null;
                if (over != hovering_link) {
                    hovering_link = over;
                    text.set_cursor_from_name (over ? "pointer" : "text");
                }
            });
            text.add_controller (motion);
        }

        public void focus_body () {
            text.grab_focus ();
        }

        private string? link_at (double x, double y) {
            int bx, by;
            text.window_to_buffer_coords (TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);
            TextIter it;
            if (!text.get_iter_at_location (out it, bx, by)) return null;
            foreach (var tag in it.get_tags ()) {
                string? href = tag.get_data<string> ("href");
                if (href != null) return href;
            }
            return null;
        }

        private void create_tags () {
            var table = buffer.tag_table;
            double[] scales = { 1.6, 1.4, 1.25, 1.1, 1.0, 0.95 };
            for (int i = 0; i < 6; i++) {
                var t = new TextTag ("h%d".printf (i + 1));
                t.scale = scales[i];
                t.weight = 800;
                t.pixels_above_lines = 14;
                t.pixels_below_lines = 4;
                table.add (t);
            }
            var p = new TextTag ("p");
            p.pixels_below_lines = 12;
            table.add (p);
            var bold = new TextTag ("bold");
            bold.weight = 700;
            table.add (bold);
            var italic = new TextTag ("italic");
            italic.style = Pango.Style.ITALIC;
            table.add (italic);
            var under = new TextTag ("underline");
            under.underline = Pango.Underline.SINGLE;
            table.add (under);
            var strike = new TextTag ("strike");
            strike.strikethrough = true;
            table.add (strike);
            var code = new TextTag ("code");
            code.family = "monospace";
            code.scale = 0.92;
            table.add (code);
            var pre = new TextTag ("pre");
            pre.family = "monospace";
            pre.scale = 0.9;
            pre.wrap_mode = WrapMode.CHAR;
            pre.left_margin = 12;
            pre.right_margin = 12;
            pre.pixels_above_lines = 2;
            pre.pixels_below_lines = 2;
            table.add (pre);
            var sup = new TextTag ("sup");
            sup.rise = 5 * Pango.SCALE;
            sup.scale = 0.75;
            table.add (sup);
            var sub = new TextTag ("sub");
            sub.rise = -3 * Pango.SCALE;
            sub.scale = 0.75;
            table.add (sub);
            var small = new TextTag ("small");
            small.scale = 0.85;
            table.add (small);
            var caption = new TextTag ("caption");
            caption.scale = 0.85;
            caption.style = Pango.Style.ITALIC;
            caption.pixels_below_lines = 12;
            table.add (caption);
            var center = new TextTag ("center");
            center.justification = Justification.CENTER;
            center.pixels_below_lines = 12;
            table.add (center);
            recolor ();
        }

        public override void css_changed (CssStyleChange change) {
            base.css_changed (change);
            recolor ();
        }

        private void recolor () {
            if (buffer == null) return;
            var fg = text.get_color ();
            var dim = fg;
            dim.alpha = 0.65f;
            var tint = fg;
            tint.alpha = 0.07f;
            var accent = Gdk.RGBA ();
            accent.parse (Singularity.Style.StyleManager.get_default ().accent_hex);
            var table = buffer.tag_table;
            var pre = table.lookup ("pre");
            if (pre != null) pre.paragraph_background_rgba = tint;
            var code = table.lookup ("code");
            if (code != null) code.background_rgba = tint;
            var caption = table.lookup ("caption");
            if (caption != null) caption.foreground_rgba = dim;
            for (int d = 1; d <= 6; d++) {
                var q = table.lookup ("quote%d".printf (d));
                if (q != null) q.foreground_rgba = dim;
            }
            foreach (var t in link_tags) t.foreground_rgba = accent;
        }

        private TextTag indent_tag (int quote, int indent, bool has_marker) {
            string name = "ind-%d-%d-%s".printf (quote, indent, has_marker ? "m" : "n");
            var t = buffer.tag_table.lookup (name);
            if (t != null) return t;
            t = new TextTag (name);
            t.left_margin = quote * 20 + indent * 22;
            if (has_marker) t.indent = -16;
            if (indent > 0) t.pixels_below_lines = 4;
            buffer.tag_table.add (t);
            return t;
        }

        private TextTag quote_tag (int depth) {
            int d = int.min (depth, 6);
            string name = "quote%d".printf (d);
            var t = buffer.tag_table.lookup (name);
            if (t != null) return t;
            t = new TextTag (name);
            t.style = Pango.Style.ITALIC;
            buffer.tag_table.add (t);
            recolor ();
            return t;
        }

        private TextTag link_tag (string href) {
            var t = new TextTag (null);
            t.underline = Pango.Underline.SINGLE;
            t.set_data<string> ("href", href);
            buffer.tag_table.add (t);
            link_tags.add (t);
            recolor ();
            return t;
        }

        public void set_notice (string text, string action, bool working) {
            notice_label.label = text;
            notice_button.label = action;
            notice_button.visible = action != "";
            notice_spinner.visible = working;
            notice_spinner.spinning = working;
            notice_box.visible = text != "" || action != "";
        }

        public void replace_body (string html) {
            if (loading != null) loading.cancel ();
            loading = new Cancellable ();
            render (html);
        }

        public void show_article (Article a, string source, string feed_url, string html) {
            if (loading != null) loading.cancel ();
            loading = new Cancellable ();
            source_label.label = source;
            title_label.label = a.title;
            string[] meta = {};
            if (a.author != "") meta += a.author;
            if (a.published > 0) meta += format_full_date (a.published);
            meta_label.label = string.joinv (" · ", meta);
            meta_label.visible = meta.length > 0;
            base_url = a.link != "" ? a.link : feed_url;
            render (html);
        }

        public static string format_full_date (int64 stamp) {
            var dt = new DateTime.from_unix_local (stamp);
            return dt.format (_("%A, %e %B %Y at %H:%M")).replace ("  ", " ");
        }

        private void render (string html) {
            foreach (var t in link_tags) buffer.tag_table.remove (t);
            link_tags.clear ();
            buffer.text = "";
            var blocks = HtmlText.render (html, base_url);
            TextIter end;
            bool first = true;
            if (blocks.size == 0) {
                buffer.get_end_iter (out end);
                buffer.insert_with_tags_by_name (ref end, _("This article has no text. Open it in the browser to read it."), -1, "caption");
                return;
            }
            foreach (var b in blocks) {
                buffer.get_end_iter (out end);
                if (!first) buffer.insert (ref end, "\n", -1);
                first = false;
                int start_offset = end.get_offset ();
                switch (b.kind) {
                    case HtmlText.BlockKind.IMAGE:
                        insert_image (b);
                        break;
                    case HtmlText.BlockKind.RULE:
                        var anchor = buffer.create_child_anchor (end);
                        var sep = new Separator (Orientation.HORIZONTAL);
                        sep.set_size_request (360, -1);
                        sep.margin_top = sep.margin_bottom = 8;
                        text.add_child_at_anchor (sep, anchor);
                        break;
                    default:
                        if (b.marker != "") {
                            buffer.insert (ref end, b.marker + " ", -1);
                        }
                        insert_runs (b);
                        break;
                }
                TextIter s, e;
                buffer.get_iter_at_offset (out s, start_offset);
                buffer.get_end_iter (out e);
                switch (b.kind) {
                    case HtmlText.BlockKind.HEADING:
                        buffer.apply_tag_by_name ("h%d".printf (b.level.clamp (1, 6)), s, e);
                        break;
                    case HtmlText.BlockKind.PREFORMATTED:
                        buffer.apply_tag_by_name ("pre", s, e);
                        break;
                    case HtmlText.BlockKind.CAPTION:
                        buffer.apply_tag_by_name ("caption", s, e);
                        break;
                    case HtmlText.BlockKind.IMAGE:
                    case HtmlText.BlockKind.RULE:
                        buffer.apply_tag_by_name ("center", s, e);
                        break;
                    default:
                        if (b.indent == 0) buffer.apply_tag_by_name ("p", s, e);
                        break;
                }
                if (b.quote > 0) buffer.apply_tag (quote_tag (b.quote), s, e);
                if (b.quote > 0 || b.indent > 0) buffer.apply_tag (indent_tag (b.quote, b.indent, b.marker != ""), s, e);
            }
            buffer.get_start_iter (out end);
            buffer.place_cursor (end);
        }

        private void insert_runs (HtmlText.Block b) {
            foreach (var r in b.runs) {
                TextIter end;
                buffer.get_end_iter (out end);
                int so = end.get_offset ();
                buffer.insert (ref end, r.text, -1);
                TextIter s, e;
                buffer.get_iter_at_offset (out s, so);
                buffer.get_end_iter (out e);
                if ((r.style & HtmlText.Style.BOLD) != 0) buffer.apply_tag_by_name ("bold", s, e);
                if ((r.style & HtmlText.Style.ITALIC) != 0) buffer.apply_tag_by_name ("italic", s, e);
                if ((r.style & HtmlText.Style.UNDERLINE) != 0) buffer.apply_tag_by_name ("underline", s, e);
                if ((r.style & HtmlText.Style.STRIKE) != 0) buffer.apply_tag_by_name ("strike", s, e);
                if ((r.style & HtmlText.Style.CODE) != 0 && b.kind != HtmlText.BlockKind.PREFORMATTED) buffer.apply_tag_by_name ("code", s, e);
                if ((r.style & HtmlText.Style.SUP) != 0) buffer.apply_tag_by_name ("sup", s, e);
                if ((r.style & HtmlText.Style.SUB) != 0) buffer.apply_tag_by_name ("sub", s, e);
                if ((r.style & HtmlText.Style.SMALL) != 0) buffer.apply_tag_by_name ("small", s, e);
                if (r.href != "") buffer.apply_tag (link_tag (r.href), s, e);
            }
        }

        private void insert_image (HtmlText.Block b) {
            TextIter end;
            buffer.get_end_iter (out end);
            var anchor = buffer.create_child_anchor (end);
            var pic = new Picture ();
            pic.can_shrink = true;
            pic.content_fit = ContentFit.CONTAIN;
            pic.alternative_text = b.alt;
            pic.tooltip_text = b.alt != "" ? b.alt : null;
            pic.add_css_class ("news-article-image");
            pic.set_size_request (1, 1);
            string href = b.runs.size > 0 ? b.runs[0].href : "";
            if (href != "") {
                pic.cursor = new Gdk.Cursor.from_name ("pointer", null);
                var c = new GestureClick ();
                c.released.connect (() => open_link (href));
                pic.add_controller (c);
            }
            text.add_child_at_anchor (pic, anchor);
            var cancel = loading;
            ImageCache.get_default ().load.begin (b.src, 1600, false, cancel, (o, res) => {
                var tex = ImageCache.get_default ().load.end (res);
                if (cancel.is_cancelled ()) return;
                if (tex == null) {
                    pic.visible = false;
                    return;
                }
                pic.paintable = tex;
                fit_picture (pic, tex);
            });
        }

        private void fit_picture (Picture pic, Gdk.Texture tex) {
            int avail = text.get_width () - text.left_margin - text.right_margin - 8;
            if (avail < 100) avail = 640;
            int w = int.min (tex.width, avail);
            int h = (int) ((double) w * tex.height / tex.width);
            if (pic.width_request != w || pic.height_request != h) pic.set_size_request (w, h);
        }

        private int last_width;
        private uint refit_id;

        public override void size_allocate (int width, int height, int baseline) {
            base.size_allocate (width, height, baseline);
            if (width == last_width || refit_id != 0) return;
            last_width = width;
            refit_id = Idle.add (() => {
                refit_id = 0;
                for (var child = text.get_first_child (); child != null; child = child.get_next_sibling ()) {
                    var pic = child as Picture;
                    if (pic == null) continue;
                    var tex = pic.paintable as Gdk.Texture;
                    if (tex != null) fit_picture (pic, tex);
                }
                return Source.REMOVE;
            });
        }
    }
}
