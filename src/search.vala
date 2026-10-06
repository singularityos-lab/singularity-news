namespace Singularity.Apps.News {

    public class NewsSearch : Singularity.SearchProviderService {
        private const int MAX_RESULTS = 20;
        private NewsApp app;

        public NewsSearch (NewsApp app) {
            this.app = app;
        }

        public override async string[] get_initial_results (string[] terms, Cancellable? cancellable) throws Error {
            string query = string.joinv (" ", terms).strip ();
            if (query.char_count () < 2 || app.store == null) return {};
            var found = new Gee.ArrayList<Article> ();
            foreach (var a in app.store.articles.values) {
                if (app.store.feed (a.feed_id) == null) continue;
                if (a.matches (query)) found.add (a);
            }
            found.sort ((x, y) => {
                bool tx = x.title.casefold ().contains (query.casefold ());
                bool ty = y.title.casefold ().contains (query.casefold ());
                if (tx != ty) return tx ? -1 : 1;
                return x.published > y.published ? -1 : (x.published < y.published ? 1 : 0);
            });
            string[] ids = {};
            foreach (var a in found) {
                ids += a.key;
                if (ids.length >= MAX_RESULTS) break;
            }
            return ids;
        }

        public override async Singularity.SearchResultMeta[] get_result_metas (string[] ids, Cancellable? cancellable) throws Error {
            Singularity.SearchResultMeta[] metas = {};
            foreach (string id in ids) {
                var a = app.store.articles[id];
                if (a == null) continue;
                var meta = new Singularity.SearchResultMeta (id, a.title != "" ? a.title : _("Untitled Article"));
                var f = app.store.feed (a.feed_id);
                string source = f != null ? f.display_title : a.source_name;
                string when = a.published > 0 ? new DateTime.from_unix_local (a.published).format ("%x") : "";
                meta.description = when != "" ? "%s · %s".printf (source, when) : source;
                if (a.link != "") meta.add_action ("browser", _("Open in Browser"), "web-browser-symbolic");
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result (string id, string[] terms, uint32 timestamp) throws Error {
            app.open_article (id);
            return null;
        }

        public override async Singularity.SearchActivationReply? activate_action (string id, string action_id, string[] terms, uint32 timestamp) throws Error {
            var a = app.store.articles[id];
            if (a == null || action_id != "browser" || a.link == "") return null;
            try {
                AppInfo.launch_default_for_uri (a.link, null);
            } catch (Error e) {
                warning ("news: %s", e.message);
            }
            return null;
        }

        public override void launch_search (string[] terms, uint32 timestamp) {
            app.search_articles (string.joinv (" ", terms));
        }
    }
}
