# -*- coding: utf-8 -*-
"""复刻 App 里各源的取数逻辑，逐步定位「搜索能出、进去不行」到底卡在哪一步。"""
import re, sys, json, urllib.parse, urllib.request, http.cookiejar

sys.stdout.reconfigure(encoding="utf-8")
UA_M = "Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36"
UA_D = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
CJ = http.cookiejar.CookieJar()
OP = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CJ))


def req(url, ua=UA_M, ref=None, data=None, ctype=None):
    r = urllib.request.Request(url, data=data)
    r.add_header("User-Agent", ua)
    if ref:
        r.add_header("Referer", ref)
    if ctype:
        r.add_header("Content-Type", ctype)
    with OP.open(r, timeout=40) as x:
        return x.read().decode("utf-8", "replace"), x.status


def solve_guard(html, cookie_name="pt_guid"):
    m = re.search(r'var\s+reversed\s*=\s*"([^"]+)"', html)
    if not m:
        return None
    fwd = m.group(1)[::-1]
    import base64
    fwd += "=" * ((4 - len(fwd) % 4) % 4)
    try:
        js = base64.b64decode(fwd, validate=False).decode("utf-8", "replace")
    except Exception as e:
        print("      [guard] base64 失败", e)
        return None
    for pat in [cookie_name + r"=([^;'\" ]{6,})", r"var\s+token\s*=\s*['\"]([^'\"]+)['\"]", r"\btoken\s*=\s*['\"]([^'\"]+)['\"]"]:
        mm = re.search(pat, js)
        if mm:
            return mm.group(1)
    return None


def fetch_guarded(url, ua=UA_M, ref=None, host=None):
    html, st = req(url, ua=ua, ref=ref)
    if "var reversed" in html or "pt_guid" in html:
        tok = solve_guard(html)
        print("      [guard] 命中挑战，解出 token=%s" % (tok[:12] + "…" if tok else "失败"))
        if tok:
            import http.cookiejar as cj
            C = cj.Cookie(0, "pt_guid", tok, None, False, host, False, False, "/", True, False, None, False, None, None, {})
            CJ.set_cookie(C)
            html, st = req(url, ua=ua, ref=ref)
    return html, st


def strip(s):
    s = re.sub(r"<[^>]+>", "", s)
    return re.sub(r"\s+", " ", s).strip()


def check_ptcms(name, host, dirprefix):
    print("=" * 70)
    print("【%s】%s" % (name, host))
    kw = urllib.parse.quote("三体")
    body = ("searchword=%s" % kw).encode()
    html, st = req(host + "/novelsearch/search/result.html", ua=UA_M, ref=host + "/",
                   data=body, ctype="application/x-www-form-urlencoded")
    print("  ① 搜索 POST → HTTP %s，大小 %d" % (st, len(html)))
    items = re.findall(r"<dl class=\"list-works-dl\"[\s\S]*?</dl>", html)
    print("     条目数 %d" % len(items))
    if not items:
        return
    m = re.search(r'<dt class="list-book-dt"[^>]*>[\s\S]{0,200}?<a\s+href="([^"]+)"', items[0])
    if not m:
        m = re.search(r'href="([^"]+)"', items[0])
    book = m.group(1) if m else ""
    book = book if book.startswith("http") else host + book
    print("     第一本: %s" % book)
    page, st = req(book, ua=UA_M, ref=host + "/")
    print("  ② 书籍页 GET → HTTP %s，大小 %d" % (st, len(page)))
    dm = re.search(r'class="dirurl"[^>]*href="([^"]+)"', page) or re.search(r'href="([^"]*%s[^"]+)"' % re.escape(dirprefix), page)
    print("     目录入口: %s" % (dm.group(1) if dm else "★没找到★"))
    if not dm:
        return
    dirurl = dm.group(1) if dm.group(1).startswith("http") else host + dm.group(1)
    d, st = fetch_guarded(dirurl + ("&" if "?" in dirurl else "?") + "sort=asc", ua=UA_D, ref=book, host=urllib.parse.urlparse(host).netloc)
    print("  ③ 目录页 GET → HTTP %s，大小 %d" % (st, len(d)))
    eps = re.findall(r"<a[^>]*href=\"(/play/[^\"]+)\"[^>]*>", d)
    print("     /play/ 链接数 %d（前两条 %s）" % (len(eps), eps[:2]))
    if not eps:
        print("     ★目录页里没有 /play/ 链接，可能是被守卫拦了或选择器不对★")
        print("     页面片段:", strip(d)[:160])


def check_leting():
    host = "https://m.leting.vip"
    print("=" * 70)
    print("【乐听网】%s" % host)
    kw = urllib.parse.quote("三体")
    txt, st = req("%s/api/ajax/solist?word=%s&type=name&page=1&order=1" % (host, kw), ua=UA_M, ref=host + "/")
    print("  ① 搜索接口 → HTTP %s，大小 %d" % (st, len(txt)))
    try:
        j = json.loads(txt)
        items = j if isinstance(j, list) else j.get("data", [])
        print("     条目 %d" % len(items))
        node = items[0].get("novel", items[0]) if items else {}
        url = node.get("url", "")
        print("     第一本: %s  title=%s" % (url, node.get("name") or node.get("title")))
    except Exception as e:
        print("     ★JSON 解析失败★", e, txt[:120])
        return
    book = url if url.startswith("http") else host + url
    page, st = req(book, ua=UA_M, ref=host + "/")
    print("  ② 书籍页 → HTTP %s，大小 %d" % (st, len(page)))
    dm = re.search(r'<a[^>]*href="([^"]*bookdir[^"]*)"', page)
    print("     目录入口: %s" % (dm.group(1) if dm else "★没找到★"))
    if not dm:
        return
    dirurl = dm.group(1) if dm.group(1).startswith("http") else host + dm.group(1)
    d, st = fetch_guarded(dirurl + ("&" if "?" in dirurl else "?") + "sort=asc", ua=UA_M, ref=book, host="m.leting.vip")
    print("  ③ 目录页 → HTTP %s，大小 %d" % (st, len(d)))
    eps = re.findall(r"href=\"(/tingshu/[^\"]+)\"", d)
    print("     /tingshu/ 链接数 %d（前两条 %s）" % (len(eps), eps[:2]))
    if not eps:
        print("     ★没解析到章节★  片段:", strip(d)[:160])


def check_ting29():
    host = "https://m.ting29.com"
    print("=" * 70)
    print("【29听书网】%s" % host)
    kw = urllib.parse.quote("三体")
    txt, st = req("%s/api/ajax/solist?word=%s&type=name&page=1&order=1" % (host, kw), ua=UA_M, ref=host + "/")
    print("  ① 搜索接口 → HTTP %s，大小 %d" % (st, len(txt)))
    try:
        j = json.loads(txt)
        items = j if isinstance(j, list) else j.get("data", [])
        node = items[0].get("novel", items[0]) if items else {}
        print("     条目 %d，第一本 url=%s title=%s" % (len(items), node.get("url"), node.get("title") or node.get("name")))
        url = node.get("url", "")
    except Exception as e:
        print("     ★JSON 解析失败★", e, txt[:160])
        return
    book = url if url.startswith("http") else host + url
    page, st = req(book, ua=UA_M, ref=host + "/")
    print("  ② 书籍页 → HTTP %s，大小 %d" % (st, len(page)))
    dm = re.search(r'href="([^"]*bookdir[^"]*)"', page)
    print("     目录入口: %s" % (dm.group(1) if dm else "★没找到★"))
    if not dm:
        print("     页面片段:", strip(page)[:200])
        return
    dirurl = dm.group(1) if dm.group(1).startswith("http") else host + dm.group(1)
    d, st = fetch_guarded(dirurl, ua=UA_M, ref=book, host="m.ting29.com")
    print("  ③ 目录页 → HTTP %s，大小 %d" % (st, len(d)))
    eps = re.findall(r"href=\"(/tingshu/[^\"]+)\"", d)
    print("     /tingshu/ 链接数 %d（前两条 %s）" % (len(eps), eps[:2]))
    if not eps:
        print("     ★没解析到章节★  片段:", strip(d)[:160])


def check_ting15_rule():
    print("=" * 70)
    print("【有听网】规则源：搜索页 + 详情页")
    host = "https://www.ting15.com"
    kw = urllib.parse.quote("三体")
    h, st = req("%s/?s=ting-search-wd-%s.html" % (host, kw), ua=UA_D, ref=host + "/")
    print("  ① 搜索 → HTTP %s 大小 %d" % (st, len(h)))
    blk = re.search(r'<div class="category-list">([\s\S]*?)</ul>', h)
    if not blk:
        print("     ★没找到 .category-list★")
        return
    a = re.search(r'<h4>\s*<a[^>]*href="([^"]+)"', blk.group(1))
    print("     第一本: %s" % (a.group(1) if a else "★未匹配 h4>a★"))
    if not a:
        print("     片段:", strip(blk.group(1))[:160])
        return
    book = a.group(1) if a.group(1).startswith("http") else host + a.group(1)
    b, st = req(book, ua=UA_D, ref=host + "/")
    print("  ② 书籍页 → HTTP %s 大小 %d" % (st, len(b)))
    pl = re.search(r'<div class="plist">([\s\S]*?)</div>', b)
    print("     plist 块: %s" % ("有" if pl else "★没有★"))
    if pl:
        eps = re.findall(r"<a[^>]*href=\"([^\"]+)\"", pl.group(1))
        print("     章节链接数 %d（前两条 %s）" % (len(eps), eps[:2]))
    else:
        print("     页面片段:", strip(b)[:200])


if __name__ == "__main__":
    check_ptcms("13听书网", "https://www.ting13.cc", "/tingdirs/")
    check_ptcms("爱听书", "https://www.itingshu.net", "/itingshus/")
    check_leting()
    check_ting29()
    check_ting15_rule()
