using Gtk;

namespace Singularity.Apps.News {

    public class ArticleRow : Box {
        private Label source;
        private Label date;
        private Label title;
        private Label excerpt;
        private Picture thumb;
        private Box thumb_frame;
        private Image star;
        private Widget dot;
        private Article? article;
        private ulong unread_handler;
        private ulong starred_handler;
        private ulong muted_handler;
        private Cancellable? loading;

        public ArticleRow () {
            Object (orientation: Orientation.HORIZONTAL, spacing: 12);
            add_css_class ("news-row");

            var marker = new Box (Orientation.VERTICAL, 0);
            marker.valign = Align.START;
            marker.margin_top = 5;
            dot = new Box (Orientation.HORIZONTAL, 0);
            dot.add_css_class ("news-unread-dot");
            dot.set_size_request (8, 8);
            marker.append (dot);
            append (marker);

            var texts = new Box (Orientation.VERTICAL, 3);
            texts.hexpand = true;
            var head = new Box (Orientation.HORIZONTAL, 6);
            source = new Label ("");
            source.xalign = 0;
            source.hexpand = true;
            source.ellipsize = Pango.EllipsizeMode.END;
            source.add_css_class ("news-row-source");
            head.append (source);
            star = new Image.from_icon_name ("starred-symbolic");
            star.pixel_size = 12;
            star.add_css_class ("news-star");
            head.append (star);
            date = new Label ("");
            date.add_css_class ("news-row-date");
            head.append (date);
            texts.append (head);

            title = new Label ("");
            title.xalign = 0;
            title.wrap = true;
            title.wrap_mode = Pango.WrapMode.WORD_CHAR;
            title.lines = 3;
            title.ellipsize = Pango.EllipsizeMode.END;
            title.add_css_class ("news-row-title");
            texts.append (title);

            excerpt = new Label ("");
            excerpt.xalign = 0;
            excerpt.wrap = true;
            excerpt.wrap_mode = Pango.WrapMode.WORD_CHAR;
            excerpt.lines = 2;
            excerpt.ellipsize = Pango.EllipsizeMode.END;
            excerpt.add_css_class ("news-row-excerpt");
            texts.append (excerpt);
            append (texts);

            thumb = new Picture ();
            thumb.content_fit = ContentFit.COVER;
            thumb.can_shrink = true;
            thumb.set_size_request (72, 72);
            thumb_frame = new Box (Orientation.HORIZONTAL, 0);
            thumb_frame.add_css_class ("news-thumb");
            thumb_frame.overflow = Overflow.HIDDEN;
            thumb_frame.valign = Align.START;
            thumb_frame.append (thumb);
            append (thumb_frame);
        }

        public void bind (Article a, string feed_title) {
            unbind ();
            article = a;
            source.label = feed_title;
            date.label = format_date (a.published);
            unread_handler = a.notify["unread"].connect (sync);
            starred_handler = a.notify["starred"].connect (sync);
            muted_handler = a.notify["muted"].connect (sync);
            sync ();
            thumb.paintable = null;
            thumb_frame.visible = false;
            if (a.thumbnail != "") {
                loading = new Cancellable ();
                var cancel = loading;
                var bound = a;
                ImageCache.get_default ().load.begin (a.thumbnail, 144, true, cancel, (o, res) => {
                    var tex = ImageCache.get_default ().load.end (res);
                    if (cancel.is_cancelled () || article != bound || tex == null) return;
                    thumb.paintable = tex;
                    thumb_frame.visible = true;
                });
            }
        }

        public void unbind () {
            if (loading != null) {
                loading.cancel ();
                loading = null;
            }
            if (article != null) {
                if (unread_handler != 0) article.disconnect (unread_handler);
                if (starred_handler != 0) article.disconnect (starred_handler);
                if (muted_handler != 0) article.disconnect (muted_handler);
            }
            unread_handler = 0;
            starred_handler = 0;
            muted_handler = 0;
            article = null;
        }

        private void sync () {
            if (article == null) return;
            bool muted = article.muted != "";
            if (muted) {
                add_css_class ("news-row-muted");
                title.label = _("Muted Article");
                excerpt.label = _("It mentions %s. Select it to read it.").printf (article.muted);
                excerpt.visible = true;
                thumb_frame.opacity = 0;
            } else {
                remove_css_class ("news-row-muted");
                title.label = article.title;
                excerpt.label = article.excerpt;
                excerpt.visible = article.excerpt != "";
                thumb_frame.opacity = 1;
            }
            dot.opacity = article.unread ? 1 : 0;
            star.visible = article.starred;
            if (article.unread) {
                add_css_class ("news-row-unread");
                remove_css_class ("news-row-read");
            } else {
                add_css_class ("news-row-read");
                remove_css_class ("news-row-unread");
            }
            var parts = new string[] { muted ? _("Muted Article") : article.title };
            if (article.unread) parts += _("Unread");
            if (article.starred) parts += _("Starred");
            update_property (AccessibleProperty.LABEL, string.joinv (", ", parts), -1);
        }

        public static string format_date (int64 stamp) {
            if (stamp <= 0) return "";
            var dt = new DateTime.from_unix_local (stamp);
            var now = new DateTime.now_local ();
            var diff = now.difference (dt);
            if (diff < 0) return dt.format ("%H:%M");
            if (diff < TimeSpan.HOUR) {
                int m = (int) (diff / TimeSpan.MINUTE);
                return m <= 1 ? _("Now") : ngettext ("%d min", "%d min", m).printf (m);
            }
            if (dt.get_year () == now.get_year () && dt.get_day_of_year () == now.get_day_of_year ()) return dt.format ("%H:%M");
            if (diff < 2 * TimeSpan.DAY && now.add_days (-1).get_day_of_year () == dt.get_day_of_year ()) return _("Yesterday");
            if (diff < 7 * TimeSpan.DAY) return dt.format ("%a");
            if (dt.get_year () == now.get_year ()) return dt.format ("%e %b").strip ();
            return dt.format ("%e %b %Y").strip ();
        }
    }
}
