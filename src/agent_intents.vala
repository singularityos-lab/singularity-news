namespace Singularity.Apps.News {

    internal class NewsIntents : Object {

        private static string text(Json.Object args, string key) {
            return args.has_member(key) ? args.get_string_member(key).strip() : "";
        }

        private static string plain(Article a) {
            var sb = new StringBuilder();
            foreach (var block in HtmlText.render(a.content, a.link)) {
                string t = block.text().replace("\u00a0", " ").strip();
                if (t == "") continue;
                if (sb.len > 0) sb.append("\n\n");
                sb.append(t);
            }
            return sb.str;
        }

        private static string clip(string s, int chars) {
            if (s.char_count() <= chars) return s;
            return s.substring(0, s.index_of_nth_char(chars)).strip() + "...";
        }

        private static Feed find_feed(NewsApp app, string wanted) throws Error {
            if (wanted == "") throw new IOError.INVALID_ARGUMENT("give the feed id or title from news_feeds");
            var f = app.store.feed(wanted) ?? app.store.feed_by_url(wanted);
            if (f != null) return f;
            string w = wanted.casefold();
            foreach (var x in app.store.feeds) if (x.display_title.casefold() == w) return x;
            foreach (var x in app.store.feeds) if (x.display_title.casefold().contains(w)) return x;
            throw new IOError.NOT_FOUND("no feed %s; see news_feeds", wanted);
        }

        private static Article find_article(NewsApp app, string id) throws Error {
            if (id == "") throw new IOError.INVALID_ARGUMENT("give the article id from news_headlines");
            var a = app.store.articles[id];
            if (a == null) throw new IOError.NOT_FOUND("no article %s; it may have expired", id);
            return a;
        }

        private static string source(NewsApp app, Article a) {
            var f = app.store.feed(a.feed_id);
            return f != null ? f.display_title : a.source_name;
        }

        private static void headline(Json.Builder b, NewsApp app, Article a) {
            b.begin_object();
            b.set_member_name("id").add_string_value(a.key);
            b.set_member_name("title").add_string_value(a.title);
            b.set_member_name("source").add_string_value(source(app, a));
            if (a.published > 0) b.set_member_name("published").add_string_value(new DateTime.from_unix_local(a.published).format_iso8601());
            b.set_member_name("unread").add_boolean_value(a.unread);
            if (a.starred) b.set_member_name("starred").add_boolean_value(true);
            string summary = clip(plain(a), 280);
            if (summary != "") b.set_member_name("summary").add_string_value(summary);
            if (a.link != "") b.set_member_name("link").add_string_value(a.link);
            b.end_object();
        }

        private static async void subscribe(NewsApp app, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold();
            try {
                string address = Discovery.normalize_address(text(args, "address"));
                if (address == "") throw new IOError.INVALID_ARGUMENT("give a site or feed address");
                var r = yield app.refresher.fetcher.resolve(address, null);
                var b = new Json.Builder();
                b.begin_object();
                if (r.feed == null) {
                    b.set_member_name("choose_one").begin_array();
                    foreach (var l in r.choices) {
                        b.begin_object();
                        b.set_member_name("address").add_string_value(l.url);
                        if (l.title != "") b.set_member_name("title").add_string_value(l.title);
                        b.end_object();
                    }
                    b.end_array();
                    b.set_member_name("note").add_string_value("the site has several feeds; call news_subscribe again with one address");
                } else {
                    if (app.store.feed_by_url(r.url) != null) throw new IOError.EXISTS("already following %s", r.url);
                    var feed = app.store.add_feed(r.url, r.feed.title, r.feed.site_url, text(args, "folder"));
                    int64 now = get_real_time() / 1000000;
                    feed.etag = r.fetch.etag;
                    feed.last_modified = r.fetch.last_modified;
                    feed.last_checked = now;
                    int added = app.store.merge(feed, r.feed, now);
                    app.store.save_now();
                    var check = new Store(app.store.dir);
                    check.load();
                    if (check.feed_by_url(r.url) == null) throw new IOError.FAILED("the feed was not saved");
                    b.set_member_name("following").add_string_value(feed.display_title);
                    b.set_member_name("id").add_string_value(feed.id);
                    b.set_member_name("articles").add_int_value(added);
                    b.set_member_name("undo").add_string_value("news_unsubscribe with feed " + feed.id);
                }
                b.end_object();
                reply(b.get_root(), null);
            } catch (Error e) {
                reply(null, e);
            } finally {
                app.release();
            }
        }

        private static async void refresh(NewsApp app, owned Singularity.AppIntentReply reply) {
            app.hold();
            int added = 0, failed = 0;
            bool offline = false;
            ulong id = 0;
            bool done = false;
            id = app.refresher.finished.connect((a, f, o) => {
                added = a;
                failed = f;
                offline = o;
                done = true;
                refresh.callback();
            });
            app.refresher.refresh(app.store.feeds);
            if (!done) yield;
            app.refresher.disconnect(id);
            app.store.save_now();
            var b = new Json.Builder();
            b.begin_object();
            if (offline) b.set_member_name("offline").add_boolean_value(true);
            b.set_member_name("new_articles").add_int_value(added);
            b.set_member_name("failed_feeds").add_int_value(failed);
            b.set_member_name("unread").add_int_value(app.store.total_unread());
            b.end_object();
            app.release();
            reply(b.get_root(), null);
        }

        internal static void install(NewsApp app) {
            var agent = app.agent;
            agent.add_intent("news_feeds", "The news feeds the person follows, by folder, with unread counts.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    app.store.update_counts();
                    var b = new Json.Builder();
                    b.begin_array();
                    foreach (var f in app.store.feeds) {
                        b.begin_object();
                        b.set_member_name("id").add_string_value(f.id);
                        b.set_member_name("title").add_string_value(f.display_title);
                        if (f.folder != "") b.set_member_name("folder").add_string_value(f.folder);
                        b.set_member_name("unread").add_int_value(f.unread);
                        b.set_member_name("address").add_string_value(f.url);
                        if (f.error != "") b.set_member_name("error").add_string_value(f.error);
                        b.end_object();
                    }
                    b.end_array();
                    return b.get_root();
                });
            agent.add_intent("news_headlines", "Recent articles, newest first, from every feed or one feed, optionally only unread or starred or matching words.",
                "{\"type\":\"object\",\"properties\":{\"feed\":{\"type\":\"string\"},\"unread\":{\"type\":\"boolean\"},\"starred\":{\"type\":\"boolean\"},\"query\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    string? feed_id = text(args, "feed") != "" ? find_feed(app, text(args, "feed")).id : null;
                    bool unread = args.has_member("unread") && args.get_boolean_member("unread");
                    bool starred = args.has_member("starred") && args.get_boolean_member("starred");
                    string q = text(args, "query").casefold();
                    int limit = args.has_member("limit") ? (int) args.get_int_member("limit").clamp(1, 100) : 15;
                    var list = new Gee.ArrayList<Article>();
                    foreach (var a in app.store.articles.values) {
                        if (feed_id != null && a.feed_id != feed_id) continue;
                        if (unread && !a.unread) continue;
                        if (starred && !a.starred) continue;
                        if (a.muted != "") continue;
                        if (q != "" && !a.title.casefold().contains(q) && !a.content.casefold().contains(q)) continue;
                        list.add(a);
                    }
                    list.sort((x, y) => x.published > y.published ? -1 : (x.published < y.published ? 1 : 0));
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("matches").add_int_value(list.size);
                    b.set_member_name("articles").begin_array();
                    int n = 0;
                    foreach (var a in list) {
                        if (n++ == limit) break;
                        headline(b, app, a);
                    }
                    b.end_array();
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("news_read", "The text of an article as the feed delivered it. It is marked read unless mark_read is false.",
                "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"mark_read\":{\"type\":\"boolean\"}},\"required\":[\"id\"]}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var a = find_article(app, text(args, "id"));
                    if (!args.has_member("mark_read") || args.get_boolean_member("mark_read")) {
                        app.store.set_unread(a, false);
                        app.store.save_soon();
                    }
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("title").add_string_value(a.title);
                    b.set_member_name("source").add_string_value(source(app, a));
                    if (a.author != "") b.set_member_name("author").add_string_value(a.author);
                    if (a.link != "") b.set_member_name("link").add_string_value(a.link);
                    b.set_member_name("text").add_string_value(clip(plain(a), 15000));
                    b.end_object();
                    return b.get_root();
                });
            agent.add_intent("news_mark", "Mark articles read or unread, and star or unstar them. all_in_feed marks every article of that feed.",
                "{\"type\":\"object\",\"properties\":{\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"all_in_feed\":{\"type\":\"string\"},\"read\":{\"type\":\"boolean\"},\"starred\":{\"type\":\"boolean\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var targets = new Gee.ArrayList<Article>();
                    if (args.has_member("ids")) foreach (var n in args.get_array_member("ids").get_elements()) targets.add(find_article(app, n.get_string()));
                    if (text(args, "all_in_feed") != "") {
                        var f = find_feed(app, text(args, "all_in_feed"));
                        foreach (var a in app.store.articles.values) if (a.feed_id == f.id) targets.add(a);
                    }
                    if (targets.size == 0) throw new IOError.INVALID_ARGUMENT("give ids or all_in_feed");
                    if (!args.has_member("read") && !args.has_member("starred")) throw new IOError.INVALID_ARGUMENT("give read or starred");
                    var changed = new Gee.ArrayList<string>();
                    foreach (var a in targets) {
                        bool c = false;
                        if (args.has_member("read") && a.unread == args.get_boolean_member("read")) {
                            app.store.set_unread(a, !args.get_boolean_member("read"));
                            c = true;
                        }
                        if (args.has_member("starred") && a.starred != args.get_boolean_member("starred")) {
                            app.store.set_starred(a, args.get_boolean_member("starred"));
                            c = true;
                        }
                        if (c) changed.add(a.key);
                    }
                    app.store.save_now();
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("changed").add_int_value(changed.size);
                    b.set_member_name("unread_total").add_int_value(app.store.total_unread());
                    b.set_member_name("undo").add_string_value("news_mark with the opposite values for ids " + string.joinv(",", changed.size <= 20 ? changed.to_array() : changed.slice(0, 20).to_array()));
                    b.end_object();
                    return b.get_root();
                });
            agent.add_async_intent("news_subscribe", "Follow a site or feed by its address; if the site offers several feeds they come back to choose from.",
                "{\"type\":\"object\",\"properties\":{\"address\":{\"type\":\"string\"},\"folder\":{\"type\":\"string\"}},\"required\":[\"address\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    subscribe.begin(app, args, (owned) reply);
                });
            agent.add_intent("news_unsubscribe", "Stop following a feed; its articles, starred ones included, are removed.",
                "{\"type\":\"object\",\"properties\":{\"feed\":{\"type\":\"string\"}},\"required\":[\"feed\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args) => {
                    var f = find_feed(app, text(args, "feed"));
                    string title = f.display_title;
                    string url = f.url;
                    app.store.remove_feed(f);
                    app.store.save_now();
                    var check = new Store(app.store.dir);
                    check.load();
                    if (check.feed_by_url(url) != null) throw new IOError.FAILED("%s is still followed", title);
                    var b = new Json.Builder();
                    b.begin_object();
                    b.set_member_name("unfollowed").add_string_value(title);
                    b.set_member_name("address").add_string_value(url);
                    b.end_object();
                    return b.get_root();
                });
            agent.add_async_intent("news_refresh", "Fetch new articles from every feed now.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args, reply) => {
                    refresh.begin(app, (owned) reply);
                });
        }
    }
}
