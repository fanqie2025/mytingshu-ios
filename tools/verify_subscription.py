# -*- coding: utf-8 -*-
"""
按 subscription/sources.json 里的规则，把每个源真跑一遍（搜索 → 详情 → 章节 → 音频直链 → Range 探测）。
这就是 iOS 端 RuleSource 的执行逻辑的 Python 复刻版，用来在电脑上先验证「订阅链接里的源能不能用」。

用法：
    python verify_subscription.py                 # 校验仓库里的 subscription/sources.json
    python verify_subscription.py <本地或URL>      # 校验指定文件/订阅地址
"""
import json
import re
import sys
import urllib.parse
import urllib.request
import http.cookiejar

sys.stdout.reconfigure(encoding="utf-8")

UA_DESKTOP = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
UA_MOBILE = "Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36"

# 整个进程共用一个 CookieJar（i275 这类站要先访问首页拿 session）
COOKIES = http.cookiejar.CookieJar()
OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(COOKIES))


def fetch(url, data=None, referer=None, ua=UA_DESKTOP, method=None, extra=None):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("User-Agent", ua)
    req.add_header("Accept-Language", "zh-CN,zh;q=0.9")
    if referer:
        req.add_header("Referer", referer)
    for k, v in (extra or {}).items():
        req.add_header(k, v)
    with OPENER.open(req, timeout=30) as r:
        return r.read(), dict(r.headers), r.status


def text_of(html):
    s = re.sub(r"(?s)<script.*?</script>", " ", html)
    s = re.sub(r"(?s)<style.*?</style>", " ", s)
    s = re.sub(r"<[^>]+>", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def select_items(html, container):
    """极简选择器：'a > b' / 'a b' 两级 + 末级 tag，支持 [attr*=值] 过滤。"""
    parts = [p.strip() for p in re.split(r"\s*>\s*", container) if p.strip()]
    tag = parts[-1]
    attr_filter = None
    m_attr = re.search(r"\[([\w-]+)\*=\s*([^\]]+)\]", tag)
    if m_attr:
        attr_filter = (m_attr.group(1), m_attr.group(2))
        tag = tag[:m_attr.start()]
    tag = tag.strip() or "a"
    if len(parts) >= 2:
        first = parts[0]
        m = re.match(r"([a-zA-Z0-9]+)?(?:\.([\w-]+))?", first)
        ftag = (m.group(1) or "div") if m else "div"
        fcls = m.group(2) if m else None
        if fcls:
            anchor = re.search(r"<%s[^>]*class=\"[^\"]*%s[^\"]*\"[^>]*>" % (ftag, re.escape(fcls)), html)
        else:
            anchor = re.search(r"<%s[^>]*>" % ftag, html)
        if anchor:
            rest = html[anchor.end():]
            ul = re.search(r"<ul[^>]*>([\s\S]*?)</ul>", rest)
            html = ul.group(1) if ul else rest[:200000]
    items = re.findall(r"<%s[^>]*>[\s\S]*?</%s>" % (tag, tag), html)
    if attr_filter:
        name, val = attr_filter
        items = [i for i in items if re.search(r'%s="[^"]*%s' % (re.escape(name), re.escape(val)), i[:400])]
    return items


def pick(item, rule):
    """rule 形如 'sel@text' / 'sel@href' / 'sel@title' / 'sel@regex(作者：([^<]*))'"""
    if "@" not in rule:
        sel, acc = rule, "text"
    else:
        sel, acc = rule.split("@", 1)
    frag = item
    if sel:
        # 取选择器最后一段的标签与 class
        last = sel.split()[-1]
        tag = re.match(r"[a-zA-Z0-9]+", last)
        tag = tag.group(0) if tag else "a"
        cls = re.search(r"\.([\w-]+)", last)
        # 找到该标签（可带 class）内部
        pat = r"<%s[^>]*%s[\s\S]*?</%s>" % (tag, ('class="[^"]*%s' % cls.group(1)) if cls else "", tag)
        m = re.search(pat, frag)
        if not m:
            m = re.search(r"<%s[^>]*>[\s\S]*?</%s>" % (tag, tag), frag)
        frag = m.group(0) if m else ""
    if acc == "text":
        return text_of(frag)
    if acc.startswith("regex("):
        inner = acc[len("regex("):-1]
        pattern, group = inner, 1
        if "," in inner and inner.rsplit(",", 1)[1].strip().isdigit():
            pattern, group = inner.rsplit(",", 1)
            group = int(group)
        m = re.search(pattern, frag)
        return m.group(group) if m else ""
    m = re.search(r'%s="([^"]*)"' % re.escape(acc), frag)
    return m.group(1) if m else ""


def meta(html, name):
    m = re.search(r'<meta[^>]+name="%s"[^>]*content="([^"]*)"' % re.escape(name), html)
    if not m:
        m = re.search(r'<meta[^>]+content="([^"]*)"[^>]*name="%s"' % re.escape(name), html)
    return m.group(1) if m else ""


def fill(tpl, host, kw=None, page=None, extra=None):
    s = tpl.replace("{host}", host)
    if kw is not None:
        s = s.replace("{kw}", urllib.parse.quote(kw))
    if page is not None:
        s = s.replace("{page}", str(page))
    for k, v in (extra or {}).items():
        s = s.replace("{%s}" % k, v)
    if s.startswith("http"):
        return s
    if s.startswith("/"):
        return host.rstrip("/") + s
    return host.rstrip("/") + "/" + s


def check_one(rule):
    name = rule.get("name", rule.get("id"))
    host = rule["host"]
    ua = UA_MOBILE if (rule.get("ua") or "mobile") == "mobile" else UA_DESKTOP
    ok_all = True
    print("=" * 60)
    print("源：%s  %s" % (name, host))

    # 预热（拿 session / Cookie）
    if rule.get("warmup"):
        try:
            fetch(fill(rule["warmup"], host), referer=host + "/", ua=ua)
            print("  [OK]   ⓪ 预热 %s" % fill(rule["warmup"], host))
        except Exception as e:
            print("  [WARN] ⓪ 预热失败：%s" % e)

    # ① 搜索
    sr = rule.get("search")
    books = []
    if sr:
        url = fill(sr["url"], host, kw="三体", page=1)
        html = fetch(url, referer=host + "/", ua=ua)[0].decode("utf-8", "replace")
        items = select_items(html, sr["list"])
        for it in items:
            t = pick(it, sr["title"])
            u = pick(it, sr.get("urlRule") or sr["title"].replace("@text", "@href"))
            if t and u:
                books.append({"title": t, "url": u if u.startswith("http") else host.rstrip("/") + u,
                              "cover": pick(it, sr["cover"]) if sr.get("cover") else "",
                              "artist": pick(it, sr["artist"]) if sr.get("artist") else ""})
        if books:
            print("  [OK]   ① 搜索「三体」→ %d 条，第一条《%s》 播音=%s" % (len(books), books[0]["title"], books[0]["artist"]))
        else:
            print("  [FAIL] ① 搜索没解析出条目"); ok_all = False
    else:
        print("  [SKIP] ① 该源没有搜索规则")

    # ② 分类
    cats = rule.get("categories") or []
    if cats:
        url = fill(cats[0]["url"], host)
        html = fetch(url, referer=host + "/", ua=ua)[0].decode("utf-8", "replace")
        items = select_items(html, (sr or {}).get("list", "")) if sr else []
        print("  [%s]   ② 分类「%s」→ %d 条" % ("OK" if items else "FAIL", cats[0]["title"], len(items)))
        ok_all = ok_all and bool(items)
    else:
        print("  [SKIP] ② 无分类")

    if not books:
        return ok_all

    dr = rule.get("detail") or {}
    ar = rule.get("audio") or {}
    play_ref = (ar.get("referer") or host + "/").replace("{host}", host)

    def probe(url):
        """真拉 1KB，确认是音频"""
        r = urllib.request.Request(url)
        r.add_header("User-Agent", ua)
        r.add_header("Referer", play_ref)
        r.add_header("Range", "bytes=0-1024")
        try:
            with urllib.request.urlopen(r, timeout=30) as x:
                head = x.read(1025)
                ct = x.headers.get("Content-Type", "")
                good = x.status in (200, 206) and ("audio" in ct or "mpeg" in ct or head[4:8] == b"ftyp" or head[:3] == b"ID3")
                print("  [%s]   ⑤ 音频可播：HTTP %s  %s  %d 字节" % ("OK" if good else "FAIL", x.status, ct, len(head)))
                return good
        except Exception as e:
            print("  [WARN] ⑤ 这本的音频拉不动：%s" % e)
            return False

    # ③④⑤ 详情 → 章节 → 音频：试前 3 本，只要有一本真能放，就算这个源可用
    # （站方常有单本音频源失效的情况，不该因此判定整个源坏了）
    for idx, book in enumerate(books[:3]):
        html = fetch(book["url"], referer=host + "/", ua=ua)[0].decode("utf-8", "replace")
        eps = []
        if dr.get("episodes"):
            for it in select_items(html, dr["episodes"]):
                t = pick(it, dr.get("episodeTitle") or "@text")
                u = pick(it, dr.get("episodeUrl") or "@href")
                if u:
                    eps.append({"title": t, "url": u if u.startswith("http") else host.rstrip("/") + u})
            print("  [%s]   ③ 《%s》章节 %d 集，第一集《%s》"
                  % ("OK" if eps else "FAIL", book["title"][:16], len(eps), eps[0]["title"] if eps else ""))
            ok_all = ok_all and bool(eps)
        if not eps:
            continue

        ep = eps[0]
        audio = ""
        if ar.get("type") == "post":
            page = fetch(ep["url"], referer=host + "/", ua=ua)[0].decode("utf-8", "replace")
            vars_ = {k: meta(page, v) for k, v in (ar.get("metaFrom") or {}).items()}
            # body 是表单内容，不能当 URL 补前缀（只做变量替换）
            body_tpl = ar.get("body", "")
            for k, v in vars_.items():
                body_tpl = body_tpl.replace("{%s}" % k, v)
            api = fill(ar["url"], host, extra=vars_)
            raw, _, _ = fetch(api, data=body_tpl.encode(), referer=host + "/", ua=ua,
                              extra={"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"})
            try:
                audio = (json.loads(raw.decode("utf-8-sig", "replace")).get(ar.get("field", "url")) or "")
            except Exception as e:
                print("  [FAIL] ④ 播放接口返回不是 JSON：%s / %s" % (e, raw[:120]))
        elif ar.get("type") == "regex":
            page = fetch(ep["url"], referer=host + "/", ua=ua)[0].decode("utf-8", "replace")
            m = re.search(ar["pattern"], page)
            audio = (m.group(1) if m else "").replace("\\/", "/")
        elif ar.get("type") == "direct":
            audio = ep["url"]

        if not audio:
            print("  [FAIL] ④ 这本没取到音频地址（第 %d 本）" % (idx + 1))
            continue
        print("  [OK]   ④ 音频地址 %s" % audio[:100])
        if probe(audio):
            return ok_all

    print("  [FAIL] 试了 %d 本都放不出声" % min(3, len(books)))
    return False


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "subscription/sources.json"
    if src.startswith("http"):
        raw = fetch(src, ua=UA_DESKTOP)[0].decode("utf-8", "replace")
        rules = json.loads(raw)
    else:
        with open(src, encoding="utf-8") as f:
            rules = json.load(f)
    if isinstance(rules, dict):
        rules = rules.get("sources") or rules.get("rules") or [rules]
    results = []
    for r in rules:
        try:
            results.append((r.get("name"), check_one(r)))
        except Exception as e:
            print("  [FAIL] 异常：%s" % e)
            results.append((r.get("name"), False))
    print("=" * 60)
    for n, ok in results:
        print("%s  %s" % ("✅" if ok else "❌", n))
    return 0 if all(ok for _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())

