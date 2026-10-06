using Singularity.Apps.News;

string fixture (string name) {
    string data;
    try {
        FileUtils.get_contents (Path.build_filename (Environment.get_variable ("NEWS_FIXTURES"), name), out data);
    } catch (Error e) {
        assert_not_reached ();
    }
    return data;
}

ParsedFeed parse_fixture (string name, string url) {
    try {
        return FeedParser.parse (fixture (name), url);
    } catch (Error e) {
        error ("%s: %s", name, e.message);
    }
}

int64 utc (int y, int mo, int d, int h, int mi, int s) {
    return new DateTime.utc (y, mo, d, h, mi, s).to_unix ();
}

void test_rss2 () {
    var f = parse_fixture ("rss2.xml", "https://blog.example.com/feed.xml");
    assert (f.kind == "rss");
    assert (f.title == "Example & Co. Blog");
    assert (f.site_url == "https://blog.example.com/");
    assert (f.items.size == 4);
    var a = f.items[0];
    assert (a.title == "Release 2.0 is out");
    assert (a.guid == "tag:example.com,2024:release-2");
    assert (a.link == "https://blog.example.com/2024/release-2");
    assert (a.author == "Ada Lovelace");
    assert (a.published == utc (2024, 3, 5, 13, 30, 0));
    assert (a.content.contains ("<b>2.0</b>"));
    assert (a.thumbnail == "https://blog.example.com/img/hero.png");
    var b = f.items[1];
    assert (b.link == "https://blog.example.com/posts/photo");
    assert (b.published == utc (2024, 3, 4, 8, 0, 0));
    assert (b.thumbnail == "https://cdn.example.com/thumb.jpg");
    assert (b.excerpt == "A lovely view");
    var c = f.items[2];
    assert (c.title == "Untitled note without link or guid");
    assert (c.guid.length == 40);
    assert (c.published == utc (2024, 3, 3, 15, 0, 0));
    assert (f.items[3].thumbnail == "https://cdn.example.com/cover.jpg");
    assert (f.items[3].published == 0);
}

void test_rss1 () {
    var f = parse_fixture ("rss1.rdf", "https://news.example.org/index.rdf");
    assert (f.kind == "rdf");
    assert (f.title == "RDF Site Summary");
    assert (f.site_url == "https://news.example.org/");
    assert (f.items.size == 2);
    assert (f.items[0].title == "Café opens");
    assert (f.items[0].guid == "https://news.example.org/a");
    assert (f.items[0].author == "José");
    assert (f.items[0].published == utc (2024, 2, 10, 8, 15, 0));
    assert (f.items[0].excerpt == "A new café in town.");
    assert (f.items[1].content == "<p>Full <em>body</em></p>");
    assert (f.items[1].published == utc (2024, 2, 9, 0, 0, 0));
}

void test_atom () {
    var f = parse_fixture ("atom.xml", "https://atom.example.net/blog/atom.xml");
    assert (f.kind == "atom");
    assert (f.title == "Atom Weblog");
    assert (f.description == "Things we write");
    assert (f.site_url == "https://atom.example.net/blog/");
    assert (f.items.size == 3);
    var a = f.items[0];
    assert (a.title == "First entry");
    assert (a.link == "https://atom.example.net/blog/2024/first");
    assert (a.guid == "urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a");
    assert (a.published == utc (2024, 1, 19, 15, 0, 0));
    assert (a.author == "Grace Hopper");
    assert (a.content.contains ("<p>") && a.content.contains ("world</a>"));
    assert (!a.content.contains ("Summary text"));
    var b = f.items[1];
    assert (b.title == "Plain & simple");
    assert (b.author == "Feed Author");
    assert (b.published == utc (2024, 1, 18, 8, 30, 0));
    assert (b.content == "<p>Line one</p><p>Line two &lt;not a tag&gt;</p>");
    assert (b.thumbnail == "https://atom.example.net/pic.jpg");
    var c = f.items[2];
    assert (c.title == "Escaped HTML");
    assert (c.thumbnail == "https://atom.example.net/t.png");
}

void test_json_feed () {
    var f = parse_fixture ("feed.json", "https://json.example.com/feed.json");
    assert (f.kind == "json");
    assert (f.title == "JSON Journal");
    assert (f.site_url == "https://json.example.com/");
    assert (f.items.size == 2);
    var a = f.items[0];
    assert (a.guid == "2" && a.title == "HTML item");
    assert (a.author == "Alan Turing, Kurt Gödel");
    assert (a.thumbnail == "https://json.example.com/images/2.png");
    assert (a.published == utc (2024, 4, 1, 9, 0, 0));
    var b = f.items[1];
    assert (b.guid == "1");
    assert (b.author == "Feed Writer");
    assert (b.content == "<p>Plain text body<br>with a &lt;tag&gt;</p>");
    assert (b.title == "Plain text body with a <tag>");
    assert (b.published == utc (2024, 3, 31, 9, 0, 0));
}

void test_not_a_feed () {
    bool thrown = false;
    try {
        FeedParser.parse ("<html><body>hi</body></html>", "https://x.test/");
    } catch (FeedError e) {
        thrown = true;
    }
    assert (thrown);
    thrown = false;
    try {
        FeedParser.parse ("{\"version\": \"1\"}", "https://x.test/");
    } catch (FeedError e) {
        thrown = true;
    }
    assert (thrown);
    assert (FeedParser.looks_like_feed (fixture ("rss2.xml")));
    assert (FeedParser.looks_like_feed (fixture ("atom.xml")));
    assert (FeedParser.looks_like_feed (fixture ("feed.json")));
    assert (!FeedParser.looks_like_feed (fixture ("page.html")));
}

void test_dates () {
    assert (Dates.parse ("Wed, 02 Oct 2002 13:00:00 GMT") == utc (2002, 10, 2, 13, 0, 0));
    assert (Dates.parse ("Wed, 02 Oct 2002 15:00:00 +0200") == utc (2002, 10, 2, 13, 0, 0));
    assert (Dates.parse ("02 Oct 2002 08:00 EST") == utc (2002, 10, 2, 13, 0, 0));
    assert (Dates.parse ("2002-10-02T13:00:00Z") == utc (2002, 10, 2, 13, 0, 0));
    assert (Dates.parse ("2002-10-02T10:00:00-03:00") == utc (2002, 10, 2, 13, 0, 0));
    assert (Dates.parse ("2002-10-02") == utc (2002, 10, 2, 0, 0, 0));
    assert (Dates.parse ("") == 0);
    assert (Dates.parse ("not a date") == 0);
    assert (Dates.parse ("Wed, 32 Oct 2002 13:00:00 GMT") == 0);
}

void test_discovery () {
    var links = Discovery.find_feeds (fixture ("page.html"), "https://www.example.com/site/index.html");
    assert (links.size == 4);
    assert (links[0].url == "https://www.example.com/site/feed.xml" && links[0].title == "Posts" && links[0].type == "application/rss+xml");
    assert (links[1].url == "https://www.example.com/comments/atom");
    assert (links[2].url == "https://www.example.com/feed.json" && links[2].type == "application/feed+json");
    assert (links[3].url == "https://www.example.com/site/body.atom");
    assert (Discovery.find_feeds ("<html><head><title>x</title></head></html>", "https://a.test/").size == 0);
    assert (Discovery.find_feeds ("", "https://a.test/").size == 0);
    var g = Discovery.guesses ("https://a.test/blog/post");
    assert (g[0] == "https://a.test/feed" && g[g.length - 1] == "https://a.test/feed.json");
    assert (Discovery.normalize_address ("example.com/feed") == "https://example.com/feed");
    assert (Discovery.normalize_address ("feed://example.com/rss") == "https://example.com/rss");
    assert (Discovery.normalize_address ("feed:https://example.com/rss") == "https://example.com/rss");
    assert (Discovery.normalize_address ("http://example.com") == "http://example.com/");
    assert (Discovery.normalize_address ("lwn.net") == "https://lwn.net/");
    assert (Discovery.normalize_address ("lwn.net?x=1") == "https://lwn.net/?x=1");
    assert (Discovery.normalize_address ("https://lwn.net:8443") == "https://lwn.net:8443/");
    assert (Discovery.normalize_address ("ftp://example.com") == "");
    assert (Discovery.normalize_address ("   ") == "");
}

void test_opml () {
    Gee.List<OpmlEntry> list;
    try {
        list = Opml.parse (fixture ("subscriptions.opml"));
    } catch (Error e) {
        assert_not_reached ();
    }
    assert (list.size == 3);
    assert (list[0].title == "Loose Feed" && list[0].folder == "" && list[0].html_url == "https://loose.example/");
    assert (list[1].title == "Kernel News" && list[1].folder == "Tech" && list[1].xml_url == "https://kernel.example/rss");
    assert (list[2].title == "https://deep.example/atom" && list[2].folder == "Deep");
    string out_s = Opml.serialize (list, "Mine & yours");
    assert (out_s.contains ("<title>Mine &amp; yours</title>"));
    Gee.List<OpmlEntry> back;
    try {
        back = Opml.parse (out_s);
    } catch (Error e) {
        assert_not_reached ();
    }
    assert (back.size == 3);
    foreach (var e in list) {
        bool found = false;
        foreach (var b in back) if (b.xml_url == e.xml_url && b.folder == e.folder && b.title == e.title) found = true;
        assert (found);
    }
    var tricky = new Gee.ArrayList<OpmlEntry> ();
    tricky.add (new OpmlEntry ("Quote \" & <angle>", "https://q.test/?a=1&b=2", "", "F\"x"));
    try {
        var t = Opml.parse (Opml.serialize (tricky, "t"));
        assert (t.size == 1 && t[0].title == "Quote \" & <angle>" && t[0].xml_url == "https://q.test/?a=1&b=2" && t[0].folder == "F\"x");
    } catch (Error e) {
        assert_not_reached ();
    }
    bool thrown = false;
    try {
        Opml.parse ("<rss></rss>");
    } catch (Error e) {
        thrown = true;
    }
    assert (thrown);
}

void test_sanitizer () {
    var blocks = HtmlText.render (fixture ("article.html"), "https://site.example/post/1");
    string all = "";
    foreach (var b in blocks) all += b.text () + "\n";
    assert (!all.contains ("document.cookie") && !all.contains ("color: red") && !all.contains ("secret"));
    var h = blocks[0];
    assert (h.kind == HtmlText.BlockKind.HEADING && h.level == 2 && h.text () == "Heading two");
    assert (h.to_markup () == "<b>Heading </b><i><b>two</b></i>");
    var p = blocks[1];
    assert (p.kind == HtmlText.BlockKind.PARAGRAPH);
    assert (p.text () == "Text with collapsed whitespace and a relative link, a bad link and & entity.");
    bool rel = false;
    foreach (var r in p.runs) {
        if (r.text == "relative link") rel = r.href == "https://site.example/rel/link";
        if (r.text == "bad link") assert (r.href == "");
    }
    assert (rel);
    assert (!p.to_markup ().contains ("javascript"));
    assert (p.to_markup ().contains ("&amp; entity"));
    var embed = blocks[2];
    assert (embed.runs[0].href == "https://video.example/embed/1");
    var img = blocks[3];
    assert (img.kind == HtmlText.BlockKind.IMAGE && img.src == "https://site.example/post/images/photo.jpg" && img.alt == "A photo");
    assert (blocks[4].marker == "•" && blocks[4].indent == 1 && blocks[4].text () == "One");
    assert (blocks[5].marker == "•" && blocks[5].text () == "Two");
    assert (blocks[6].marker == "3." && blocks[6].indent == 2 && blocks[6].text () == "Nested");
    assert (blocks[7].quote == 1 && blocks[7].text () == "Quoted" && blocks[7].indent == 0);
    assert (blocks[8].kind == HtmlText.BlockKind.PREFORMATTED && blocks[8].text () == "line 1\n  line 2 <tag>");
    var br = blocks[9];
    assert (br.text () == "Line\nbreak bold both x < y");
    assert (br.to_markup () == "Line\nbreak <b>bold </b><i><b>both </b></i><tt>x &lt; y</tt>");
    assert (blocks[10].kind == HtmlText.BlockKind.RULE);
    assert (blocks[11].text () == "Name | Value");
    assert (blocks.size == 12);
}

void test_text_helpers () {
    assert (HtmlText.plain_text ("<p>Hello <b>world</b></p><p>Again</p>") == "Hello world Again");
    assert (HtmlText.plain_text ("no markup") == "no markup");
    assert (HtmlText.plain_text ("") == "");
    assert (HtmlText.plain_text ("<script>x</script>") == "");
    string long_text = string.nfill (50, 'a') + " " + string.nfill (50, 'b') + " " + string.nfill (50, 'c');
    string ex = HtmlText.excerpt ("<p>" + long_text + "</p>", 120);
    assert (ex.has_suffix ("…") && ex.char_count () <= 121 && !ex.contains ("c"));
    assert (HtmlText.first_image ("<p><img src=\"data:image/png;base64,AA\" data-src=\"lazy.png\"></p>", "https://a.test/x/") == "https://a.test/x/lazy.png");
    assert (HtmlText.first_image ("<img src=\"javascript:1\"><img src=\"ok.gif\">", "https://a.test/") == "https://a.test/ok.gif");
    assert (HtmlText.first_image ("<p>none</p>", "https://a.test/") == "");
    assert (HtmlText.safe_url ("HTTPS://a") && HtmlText.safe_url ("mailto:x@y") && !HtmlText.safe_url ("javascript:x") && !HtmlText.safe_url ("data:x"));
}

void test_store () {
    string dir;
    try {
        dir = DirUtils.make_tmp ("news-test-XXXXXX");
    } catch (Error e) {
        assert_not_reached ();
    }
    var s = new Store (dir);
    var f = s.add_feed ("https://blog.example.com/feed.xml", "", "", "Tech");
    assert (s.folders.contains ("Tech"));
    assert (s.add_feed ("https://blog.example.com/feed.xml", "", "", "") == f);
    var parsed = parse_fixture ("rss2.xml", f.url);
    int64 now = utc (2024, 3, 6, 0, 0, 0);
    assert (s.merge (f, parsed, now) == 4);
    assert (f.title == "Example & Co. Blog");
    assert (f.unread == 4 && s.total_unread () == 4);
    assert (s.merge (f, parse_fixture ("rss2.xml", f.url), now + 60) == 0);
    Article? first = null;
    foreach (var a in s.articles.values) if (a.guid == "tag:example.com,2024:release-2") first = a;
    assert (first != null);
    s.set_unread (first, false);
    s.set_starred (first, true);
    assert (f.unread == 3 && s.total_starred () == 1);
    s.save_now ();
    var s2 = new Store (dir);
    try {
        s2.load ();
    } catch (Error e) {
        assert_not_reached ();
    }
    assert (s2.feeds.size == 1 && s2.feeds[0].folder == "Tech" && s2.feeds[0].title == "Example & Co. Blog");
    assert (s2.articles.size == 4 && s2.feeds[0].unread == 3 && s2.total_starred () == 1);
    var list = new Gee.ArrayList<Article> ();
    list.add_all (s2.articles.values);
    assert (s2.mark_read (list) == 3 && s2.total_unread () == 0);
    s2.keep_days = 30;
    var empty = new ParsedFeed ();
    s2.merge (s2.feeds[0], empty, utc (2024, 6, 1, 0, 0, 0));
    assert (s2.articles.size == 1 && s2.total_starred () == 1);
    Gee.List<OpmlEntry> entries;
    try {
        entries = Opml.parse (fixture ("subscriptions.opml"));
    } catch (Error e) {
        assert_not_reached ();
    }
    var imported = s2.import_entries (entries);
    assert (imported.size == 3 && s2.feeds.size == 4 && s2.folders.contains ("Deep"));
    assert (s2.import_entries (entries).size == 0);
    s2.rename_folder ("Tech", "Technology");
    assert (s2.feeds[0].folder == "Technology" && !s2.folders.contains ("Tech"));
    s2.remove_folder ("Technology");
    assert (s2.feeds[0].folder == "");
    s2.remove_feed (s2.feeds[0]);
    assert (s2.articles.size == 0 && s2.feeds.size == 3);
    s2.save_now ();
    FileUtils.remove (Path.build_filename (dir, "feeds.json"));
    DirUtils.remove (Path.build_filename (dir, "articles"));
    DirUtils.remove (dir);
}

void test_legacy_settings () {
    string dir;
    try {
        dir = DirUtils.make_tmp ("news-test-XXXXXX");
        FileUtils.set_contents (Path.build_filename (dir, "feeds.json"), "{ \"refresh_minutes\": 60, \"keep_days\": 90, \"mark_read_on_open\": false, \"feeds\": [] }");
    } catch (Error e) {
        assert_not_reached ();
    }
    var s = new Store (dir);
    try {
        s.load ();
    } catch (Error e) {
        assert_not_reached ();
    }
    assert (s.legacy_settings && s.refresh_minutes == 60 && s.keep_days == 90 && !s.mark_read_on_open);
    s.touch_meta ();
    s.save_now ();
    var s2 = new Store (dir);
    try {
        s2.load ();
    } catch (Error e) {
        assert_not_reached ();
    }
    assert (!s2.legacy_settings);
    FileUtils.remove (Path.build_filename (dir, "feeds.json"));
    DirUtils.remove (Path.build_filename (dir, "articles"));
    DirUtils.remove (dir);
}


Bytes fixture_bytes (string name) {
    uint8[] data;
    try {
        FileUtils.get_data (Path.build_filename (Environment.get_variable ("NEWS_FIXTURES"), name), out data);
    } catch (Error e) {
        error ("%s: %s", name, e.message);
    }
    return new Bytes.take ((owned) data);
}

string extracted_text (string name, out string html) {
    html = Extract.article (Extract.decode (fixture_bytes (name), "text/html"));
    return HtmlText.plain_text (html);
}

bool has_image (string html, string base_url, string src) {
    foreach (var b in HtmlText.render (html, base_url)) if (b.kind == HtmlText.BlockKind.IMAGE && b.src == src) return true;
    return false;
}

void test_extract_newspaper () {
    string html;
    string t = extracted_text ("pages/newspaper.html", out html);
    assert (t.contains ("voted eleven to four"));
    assert (t.contains ("My children have only ever seen that river"));
    assert (t.contains ("What happens next"));
    assert (t.contains ("giving the river back"));
    assert (t.contains ("maintenance costs could grow"));
    foreach (string junk in new string[] { "Skip to content", "Politics", "morning briefing", "Most read", "Bridge closure", "Finally! This took", "Copyright", "cookies", "Freight yard sale falls through", "Share" }) {
        if (t.contains (junk)) error ("newspaper kept boilerplate: %s", junk);
    }
    assert (!html.contains ("<script") && !html.contains ("<form"));
    assert (has_image (html, "https://gazette.example/2026/03/park", "https://gazette.example/media/river-park.jpg"));
    string titled = Extract.article (Extract.decode (fixture_bytes ("pages/newspaper.html"), "text/html"), "City council approves the  new river park");
    var blocks = HtmlText.render (titled, "");
    assert (blocks[0].kind != HtmlText.BlockKind.HEADING && HtmlText.plain_text (titled).contains ("What happens next"));
}

void test_extract_blog () {
    string html;
    string t = extracted_text ("pages/blog.html", out html);
    assert (t.contains ("seventeen degrees"));
    assert (t.contains ("Feed with warmer water"));
    assert (t.contains ("one part starter, three parts flour"));
    assert (t.contains ("cut the time to peak"));
    foreach (string junk in new string[] { "Notes from a home baker", "Recipes", "Share this", "A simple rye loaf", "Recent Posts", "December 2025", "fridge trick worked", "Proudly baked" }) {
        if (t.contains (junk)) error ("blog kept boilerplate: %s", junk);
    }
    bool code = false;
    foreach (var b in HtmlText.render (html, "https://crumb.example/2026/01/starter")) {
        if (b.kind == HtmlText.BlockKind.PREFORMATTED && b.text ().contains ("water:   60 g")) code = true;
    }
    assert (code);
    assert (has_image (html, "https://crumb.example/2026/01/starter", "https://crumb.example/wp-content/uploads/2026/01/starter-jar.jpg"));
}

void test_extract_divsoup () {
    string html;
    string t = extracted_text ("pages/divsoup.html", out html);
    assert (t.contains ("café au lait"));
    assert (t.contains ("returned this week"));
    assert (t.contains ("Tickets sold out"));
    assert (t.contains ("The journey takes eleven hours"));
    assert (t.contains ("single track"));
    foreach (string junk in new string[] { "Log in", "Deals", "weekly rail newsletter", "Ten scenic railway", "Save 20 percent", "Advertise" }) {
        if (t.contains (junk)) error ("divsoup kept boilerplate: %s", junk);
    }
    assert (has_image (html, "https://rail.example/news/night-trains", "https://rail.example/img/sleeper-car.jpg"));
}

void test_extract_docs () {
    string html;
    string t = extracted_text ("pages/docs.html", out html);
    assert (t.contains ("a few lines can go missing"));
    assert (t.contains ("Copy and truncate"));
    assert (t.contains ("Nothing is lost"));
    assert (t.contains ("Loses lines"));
    assert (!t.contains ("On this page"));
    assert (!t.contains ("Previous: File permissions"));
}

void test_extract_helpers () {
    assert (Extract.article ("") == "");
    assert (Extract.article ("<html><body><ul><li><a href='/a'>A</a></li><li><a href='/b'>B</a></li></ul></body></html>") == "");
    assert (Extract.is_truncated ("<p>Short teaser.</p>"));
    string para = string.nfill (60, 'x').replace ("x", "word ") ;
    string long_body = "<p>" + para + "</p><p>" + para + "</p>";
    assert (!Extract.is_truncated (long_body));
    assert (Extract.is_truncated ("<p>" + para + "</p><p>" + para + " and then…</p>"));
    assert (Extract.is_truncated ("<p>" + para + "</p><p>" + para + " [...]</p>"));
    assert (Extract.is_truncated ("<p>" + para + "</p><p>" + para + " … <a href='x'>Continue reading</a></p>"));
    assert (!Extract.is_truncated ("<p>Wait... " + para + "</p><p>" + para + "</p>"));
    assert (Extract.improves ("<p>" + para + para + "</p>", "<p>Short teaser.</p>"));
    assert (!Extract.improves ("<p>" + para + "</p>", long_body));
    assert (Extract.charset_of ("text/html; charset=ISO-8859-1", "") == "iso-8859-1");
    assert (Extract.charset_of ("text/html", "<meta charset=\"windows-1252\">") == "windows-1252");
    assert (Extract.charset_of ("", "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">") == "utf-8");
    uint8[] latin = { 'c', 'a', 'f', 0xE9 };
    assert (Extract.decode (new Bytes (latin), "text/html; charset=iso-8859-1") == "café");
    assert (Extract.decode (new Bytes (latin), "text/html") == "café");
    assert (Extract.decode (new Bytes ("café".data), "text/html") == "café");
}

void test_full_text_cache () {
    string dir;
    try {
        dir = DirUtils.make_tmp ("news-full-XXXXXX");
    } catch (Error e) {
        assert_not_reached ();
    }
    var cache = new FullText (new Fetcher (), dir);
    assert (cache.cached ("https://a.test/1") == null);
    cache.store ("https://a.test/1", "<p>Body</p>");
    var again = new FullText (new Fetcher (), dir);
    assert (again.cached ("https://a.test/1") == "<p>Body</p>");
    assert (again.cached ("") == null);
    string file = Path.build_filename (dir, Checksum.compute_for_string (ChecksumType.SHA1, "https://a.test/1") + ".html");
    assert (FileUtils.test (file, FileTest.EXISTS));
    FileUtils.remove (file);
    DirUtils.remove (dir);
}

Article make_article (string title, string html) {
    var a = new Article ();
    a.feed_id = "f";
    a.guid = title;
    a.title = title;
    a.set_content (html);
    return a;
}

void test_mute () {
    var list = new MuteList.from_strv ({ "text:Spoiler", "word:cat", "regex:elect(ion|ed)s?", "plain phrase", "", "word:", "regex:([bad" });
    assert (list.rules.size == 5);
    assert (list.rules[3].kind == MuteKind.CONTAINS && list.rules[3].pattern == "plain phrase");
    assert (!list.rules[4].valid);
    assert (list.match (make_article ("Big SPOILERS ahead", "<p>x</p>")).pattern == "Spoiler");
    assert (list.match (make_article ("A cat on the roof", "")).pattern == "cat");
    assert (list.match (make_article ("Concatenate strings", "<p>catalogue</p>")) == null);
    assert (list.match (make_article ("News", "<p>The CAT.</p>")) != null);
    assert (list.match (make_article ("Local Elections today", "")).pattern == "elect(ion|ed)s?");
    assert (list.match (make_article ("Selected works", "")) != null);
    assert (list.match (make_article ("Nothing here", "<p>A plainphrase? no</p>")) == null);
    assert (list.match (make_article ("Something", "<p>with a Plain Phrase inside</p>")) != null);
    var word = new MuteRule ("New York", MuteKind.WORD);
    assert (word.matches ("Flights to New York.", "flights to new york."));
    assert (!word.matches ("New Yorker magazine", "new yorker magazine"));
    assert (word.matches ("new yorker, new york", "new yorker, new york"));
    var accent = new MuteRule ("café", MuteKind.WORD);
    assert (accent.matches ("Le Café", "le café".casefold ()));
    assert (!accent.matches ("cafés", "cafés"));
    assert (MuteRule.regex_problem ("(open") != null && MuteRule.regex_problem ("ok+") == null);
    string[] back = list.to_strv ();
    assert (back[0] == "text:Spoiler" && back[1] == "word:cat" && back[3] == "text:plain phrase");
    var dup = new MuteList.from_strv ({ "text:Cat", "text:cat", "word:cat" });
    assert (dup.rules.size == 2);
    assert (new MuteList ().match (make_article ("x", "")) == null);
}

void test_saved_store () {
    string dir;
    try {
        dir = DirUtils.make_tmp ("news-saved-XXXXXX");
    } catch (Error e) {
        assert_not_reached ();
    }
    var store = new SavedStore (dir);
    store.limit_bytes = 4000;
    var a = make_article ("First", "");
    a.link = "https://s.test/1";
    a.thumbnail = "https://s.test/t.jpg";
    a.published = 100;
    var imgs = new Gee.HashMap<string, Bytes> ();
    imgs["https://s.test/a.png"] = new Bytes (new uint8[1000]);
    imgs["https://s.test/t.jpg"] = new Bytes (new uint8[500]);
    string html = "<p>Saved body</p><img src=\"a.png\">";
    SavedArticle first;
    try {
        first = store.add (a, "Site", html, true, imgs, 1000);
    } catch (Error e) {
        error (e.message);
    }
    assert (store.is_saved (a.key) && first.size == html.length + 1500 && first.images.size == 2);
    assert (store.content_of (first) == html);
    var local = store.local_images (first);
    assert (FileUtils.test (local["https://s.test/a.png"], FileTest.EXISTS));
    var urls = SavedStore.image_urls (html, a.link, a.thumbnail);
    assert (urls.size == 2 && urls[0] == "https://s.test/a.png" && urls[1] == "https://s.test/t.jpg");

    var reload = new SavedStore (dir);
    reload.load ();
    assert (reload.items.size == 1);
    var r = reload.find (a.key);
    assert (r != null && r.title == "First" && r.source_name == "Site" && r.full && r.images.size == 2 && r.saved_at == 1000);
    var copy = reload.to_article (r);
    assert (copy.feed_id == SavedStore.FEED_ID && copy.guid == a.key && copy.content == html && copy.source_name == "Site" && !copy.unread);

    var b = make_article ("Second", "");
    var big = new Gee.HashMap<string, Bytes> ();
    big["https://s.test/b.png"] = new Bytes (new uint8[3000]);
    try {
        store.add (b, "Site", "<p>Two</p>", false, big, 2000);
    } catch (Error e) {
        error (e.message);
    }
    assert (store.items.size == 1 && !store.is_saved (a.key) && store.is_saved (b.key));
    assert (!FileUtils.test (local["https://s.test/a.png"], FileTest.EXISTS));
    assert (store.total_size () <= store.limit_bytes);

    var c = make_article ("Third", "");
    var huge = new Gee.HashMap<string, Bytes> ();
    huge["https://s.test/huge.png"] = new Bytes (new uint8[5000]);
    try {
        var sc = store.add (c, "Site", "<p>Three</p>", false, huge, 3000);
        assert (sc.images.size == 0);
    } catch (Error e) {
        error (e.message);
    }
    assert (store.sorted ()[0].title == "Third");
    bool thrown = false;
    try {
        store.add (make_article ("Too big", ""), "Site", string.nfill (5000, 'x'), false, new Gee.HashMap<string, Bytes> (), 4000);
    } catch (Error e) {
        thrown = e is SavedError.TOO_LARGE;
    }
    assert (thrown);
    store.limit_bytes = 20;
    var evicted = store.enforce_limit ();
    assert (evicted.size == 1 && store.items.size == 1 && store.items[0].title == "Third");
    foreach (var s in store.sorted ()) store.remove (s);
    assert (store.items.size == 0);
    var empty = new SavedStore (dir);
    empty.load ();
    assert (empty.items.size == 0);
    FileUtils.remove (Path.build_filename (dir, "index.json"));
    DirUtils.remove (dir);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/feed/rss2", test_rss2);
    Test.add_func ("/feed/rss1", test_rss1);
    Test.add_func ("/feed/atom", test_atom);
    Test.add_func ("/feed/json", test_json_feed);
    Test.add_func ("/feed/not-a-feed", test_not_a_feed);
    Test.add_func ("/feed/dates", test_dates);
    Test.add_func ("/discovery", test_discovery);
    Test.add_func ("/opml", test_opml);
    Test.add_func ("/html/sanitizer", test_sanitizer);
    Test.add_func ("/html/helpers", test_text_helpers);
    Test.add_func ("/store", test_store);
    Test.add_func ("/store/legacy-settings", test_legacy_settings);
    Test.add_func ("/extract/newspaper", test_extract_newspaper);
    Test.add_func ("/extract/blog", test_extract_blog);
    Test.add_func ("/extract/div-soup", test_extract_divsoup);
    Test.add_func ("/extract/docs", test_extract_docs);
    Test.add_func ("/extract/helpers", test_extract_helpers);
    Test.add_func ("/extract/cache", test_full_text_cache);
    Test.add_func ("/mute", test_mute);
    Test.add_func ("/saved", test_saved_store);
    return Test.run ();
}
