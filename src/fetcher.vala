namespace Singularity.Apps.News {

    public class FetchResult : Object {
        public bool not_modified;
        public string body = "";
        public string etag = "";
        public string last_modified = "";
        public string final_url = "";
        public string content_type = "";
    }

    public class Resolution : Object {
        public ParsedFeed? feed;
        public FetchResult? fetch;
        public string url = "";
        public Gee.List<FeedLink> choices = new Gee.ArrayList<FeedLink> ();
    }

    public class Fetcher : Object {
        private Soup.Session session;
        private const int64 MAX_BYTES = 16 * 1024 * 1024;

        public Fetcher () {
            session = (Soup.Session) Object.new (typeof (Soup.Session), max_conns_per_host: 2);
            session.user_agent = "SingularityNews/0.1 (+https://github.com/singularityos-lab)";
            session.timeout = 30;
        }

        public static string http_message (uint status) {
            switch (status) {
                case 401:
                case 403: return _("The server refused access (error %u).").printf (status);
                case 404: return _("The feed was not found (error 404).");
                case 410: return _("The feed no longer exists (error 410).");
                case 429: return _("The server asked to slow down. Try again later.");
                default:
                    if (status >= 500) return _("The server had a problem (error %u).").printf (status);
                    return _("The server answered with error %u.").printf (status);
            }
        }

        public async FetchResult fetch (string url, string etag, string last_modified, Cancellable? cancel) throws Error {
            Soup.Message msg;
            try {
                msg = new Soup.Message.from_uri ("GET", Uri.parse (url, UriFlags.NONE));
            } catch (Error e) {
                throw new FeedError.NETWORK (_("The address is not valid."));
            }
            var h = msg.request_headers;
            h.replace ("Accept", "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, text/xml;q=0.8, text/html;q=0.7, */*;q=0.5");
            if (etag != "") h.replace ("If-None-Match", etag);
            if (last_modified != "") h.replace ("If-Modified-Since", last_modified);
            Bytes bytes;
            try {
                bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancel);
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                throw new FeedError.NETWORK (_("Could not connect: %s").printf (e.message));
            }
            var r = new FetchResult ();
            r.final_url = msg.get_uri ().to_string ();
            uint status = msg.status_code;
            if (status == 304) {
                r.not_modified = true;
                r.etag = etag;
                r.last_modified = last_modified;
                return r;
            }
            if (status < 200 || status >= 300) throw new FeedError.HTTP (http_message (status));
            if (bytes.get_size () > MAX_BYTES) throw new FeedError.HTTP (_("The feed is too large."));
            var rh = msg.response_headers;
            r.etag = rh.get_one ("ETag") ?? "";
            r.last_modified = rh.get_one ("Last-Modified") ?? "";
            r.content_type = rh.get_content_type (null) ?? "";
            r.body = bytes_to_string (bytes);
            return r;
        }

        public async string fetch_page (string url, Cancellable? cancel) throws Error {
            Soup.Message msg;
            try {
                msg = new Soup.Message.from_uri ("GET", Uri.parse (url, UriFlags.NONE));
            } catch (Error e) {
                throw new FeedError.NETWORK (_("The address is not valid."));
            }
            msg.request_headers.replace ("Accept", "text/html, application/xhtml+xml;q=0.9, */*;q=0.5");
            Bytes bytes;
            try {
                bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancel);
            } catch (IOError.CANCELLED e) {
                throw e;
            } catch (Error e) {
                throw new FeedError.NETWORK (_("Could not connect: %s").printf (e.message));
            }
            uint status = msg.status_code;
            if (status < 200 || status >= 300) throw new FeedError.HTTP (http_message (status));
            if (bytes.get_size () > MAX_BYTES) throw new FeedError.HTTP (_("The page is too large."));
            return Extract.decode (bytes, msg.response_headers.get_one ("Content-Type") ?? "");
        }

        public static string bytes_to_string (Bytes bytes) {
            var arr = new uint8[bytes.get_size () + 1];
            Memory.copy (arr, bytes.get_data (), bytes.get_size ());
            arr[bytes.get_size ()] = 0;
            return (string) arr;
        }

        private bool try_parse (FetchResult f, Resolution res) {
            if (!FeedParser.looks_like_feed (f.body) && !f.content_type.contains ("xml") && !f.content_type.contains ("json")) return false;
            try {
                res.feed = FeedParser.parse (f.body, f.final_url);
                res.fetch = f;
                res.url = f.final_url;
                return true;
            } catch (FeedError e) {
                return false;
            }
        }

        public async Resolution resolve (string address, Cancellable? cancel) throws Error {
            var res = new Resolution ();
            var first = yield fetch (address, "", "", cancel);
            if (try_parse (first, res)) return res;
            var links = Discovery.find_feeds (first.body, first.final_url);
            if (links.size > 1) {
                res.choices = links;
                return res;
            }
            string[] candidates = {};
            if (links.size == 1) candidates += links[0].url;
            else foreach (string g in Discovery.guesses (first.final_url)) candidates += g;
            foreach (string c in candidates) {
                try {
                    var f = yield fetch (c, "", "", cancel);
                    if (try_parse (f, res)) return res;
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    if (links.size == 1) throw e;
                }
            }
            throw new FeedError.NOT_A_FEED (_("No feed was found at this address."));
        }
    }

    public class Refresher : Object {
        public Store store;
        public Fetcher fetcher = new Fetcher ();
        public bool running { get; private set; }
        public int done { get; private set; }
        public int total { get; private set; }

        public signal void finished (int added, int failed, bool offline);

        private Gee.ArrayQueue<Feed> queue = new Gee.ArrayQueue<Feed> ();
        private int active;
        private int added;
        private int failed;
        private Cancellable? cancel;
        private const int PARALLEL = 4;

        public Refresher (Store store) {
            this.store = store;
        }

        public void refresh (Gee.Collection<Feed> feeds) {
            if (!NetworkMonitor.get_default ().network_available) {
                finished (0, 0, true);
                return;
            }
            foreach (var f in feeds) {
                if (f.busy) continue;
                f.busy = true;
                queue.offer (f);
                total++;
            }
            if (!running) {
                running = true;
                added = 0;
                failed = 0;
                cancel = new Cancellable ();
            }
            pump ();
        }

        public void stop () {
            if (cancel != null) cancel.cancel ();
        }

        private void pump () {
            while (active < PARALLEL && !queue.is_empty) {
                var f = queue.poll ();
                active++;
                update_feed.begin (f, (o, r) => {
                    update_feed.end (r);
                    active--;
                    done++;
                    if (queue.is_empty && active == 0) {
                        running = false;
                        store.last_refresh = get_real_time () / 1000000;
                        store.touch_meta ();
                        int a = added, fl = failed;
                        done = 0;
                        total = 0;
                        finished (a, fl, false);
                    } else {
                        pump ();
                    }
                });
            }
        }

        private async void update_feed (Feed f) {
            int64 now = get_real_time () / 1000000;
            try {
                var r = yield fetcher.fetch (f.url, f.etag, f.last_modified, cancel);
                f.last_checked = now;
                if (!r.not_modified) {
                    var parsed = FeedParser.parse (r.body, r.final_url);
                    f.etag = r.etag;
                    f.last_modified = r.last_modified;
                    added += store.merge (f, parsed, now);
                }
                f.error = "";
            } catch (IOError.CANCELLED e) {
            } catch (Error e) {
                f.error = e.message;
                failed++;
            }
            f.busy = false;
            store.touch_meta ();
        }
    }
}
