#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
单田芳评书网 (http://www.pingshu5.net) 数据链路自检脚本
=======================================================
只用 Python 标准库。依次验证:
  ① 分类/发现导航      GET  /
  ② 分类列表(第一页)   GET  /pbook/
  ③ 搜索「单田芳」     GET  /plus/search.php?kwtype=0&q=单田芳   (站点限流 3 秒/次)
  ④ 书籍详情           GET  /pbook/{slug}/
  ⑤ 章节列表           (同一详情页) div.book-list
  ⑥ 音频直链           GET  /pbook/{id}.html -> <audio><source src=...m4a> -> Range

运行:  python pingshu5_verify.py

站点特性(已实测):
  * DedeCMS (织梦) 结构, "templets/default" 模板
  * 页面字节是 UTF-8, 但部分 DedeCMS 系统页 <meta charset="gb2312"> 是错的 -> 必须 UTF-8 优先
  * 搜索限流: 3 秒内第二次搜索会返回 "管理员设定搜索时间间隔为3秒" 错误页 -> 需节流+重试
  * 没有独立手机站 (m./wap.pingshu5.net 均不解析), 站点是响应式, 手机 UA 拿到同一份 HTML
"""
import gzip
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://www.pingshu5.net"
DESKTOP_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
MOBILE_UA = ("Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 "
             "(KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36")
TIMEOUT = 30
SEARCH_WORD = "单田芳"          # 站点是单田芳专题站, 搜"三体"必然 0 命中
SEARCH_MIN_GAP = 3.2            # 实测: 站点搜索间隔硬限制 3 秒

AUDIO_CT = ("audio/mpeg", "audio/mp4", "audio/x-m4a", "m4a")

_ok = 0
_fail = 0
_last_search_ts = [0.0]


def report(step, good, msg):
    global _ok, _fail
    if good:
        _ok += 1
    else:
        _fail += 1
    print("%s %s %s" % ("[OK]" if good else "[FAIL]", step, msg))


# ---------------------------------------------------------------- HTTP 层
def decode(raw):
    """站点字节是 UTF-8; 个别 DedeCMS 系统页 meta 谎称 gb2312。
    所以先严格试 UTF-8, 失败再 gb18030 兜底(绝不按 meta 声明解码)。"""
    for enc in ("utf-8", "gb18030"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


def fetch(url, ua=DESKTOP_UA, extra_headers=None, raw_bytes=False, retries=4):
    """站点在 Cloudflare 后面, 偶发 socket 超时/5xx, 必须带退避重试。"""
    headers = {
        "User-Agent": ua,
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Connection": "close",
    }
    headers.update(extra_headers or {})
    last_exc = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=headers)
            try:
                resp = urllib.request.urlopen(req, timeout=TIMEOUT)
            except urllib.error.HTTPError as exc:
                if exc.code >= 500:
                    raise
                resp = exc                      # 4xx 当作正常响应往下走
            body = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            if raw_bytes:
                return resp.getcode(), dict(resp.headers), body
            return resp.getcode(), dict(resp.headers), decode(body)
        except Exception as exc:                # 超时 / 连接重置 / 5xx
            last_exc = exc
            time.sleep(1.0 + attempt)
    raise last_exc


def strip_tags(html):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", html)).strip()


def anchors(html):
    """返回 [(href, title, 内文)] — 站点里 title/href 顺序不固定, 逐个 <a> 解析属性。"""
    out = []
    for tag in re.findall(r"<a\b[^>]*>.*?</a>", html, re.S | re.I):
        open_tag = tag[:tag.find(">") + 1]
        href = re.search(r'href\s*=\s*"([^"]*)"', open_tag, re.I)
        title = re.search(r'title\s*=\s*"([^"]*)"', open_tag, re.I)
        out.append((href.group(1) if href else "",
                    title.group(1) if title else "",
                    strip_tags(tag)))
    return out


# ---------------------------------------------------------------- 各步骤
def step1_nav():
    """① 分类/发现导航: 首页 nav#sidr > ul#main-nav 的栏目

    坑: 导航里有一段被 <!-- --> 注释掉的旧栏目(含已 404 的 /bank/),
        必须先去注释, 否则会把死链和重复项当成真栏目。
    """
    code, headers, html = fetch(BASE + "/")
    html = re.sub(r"<!--.*?-->", "", html, flags=re.S)      # 去 HTML 注释
    block = re.search(r'<ul[^>]*id="main-nav"[^>]*>(.*?)</ul>', html, re.S)
    cats = []
    seen = set()
    if block:
        for href, title, text in anchors(block.group(1)):
            label = title or text
            if not href or href.startswith(("javascript:", "#")):
                continue
            path = urllib.parse.urlparse(href).path          # 绝对/相对链接去重
            if path in ("", "/"):
                continue                                     # 跳过"首页"
            if path in seen:
                continue
            seen.add(path)
            cats.append((label, href))
    if code == 200 and cats:
        report("① 分类/发现导航", True,
               "GET / -> nav#main-nav 共 %d 个栏目: %s"
               % (len(cats), " / ".join("%s(%s)" % (n, h) for n, h in cats)))
        return cats
    report("① 分类/发现导航", False, "HTTP %s, 解析到 %d 个栏目" % (code, len(cats)))
    return cats


def parse_book_items(html):
    """列表页/搜索页共用的卡片结构: li.col-xs-4 > ... > h5.pop-tit"""
    items = []
    for li in re.findall(r'<li class="col-xs-4.*?</li>', html, re.S):
        tit = re.search(r'<h5[^>]*class="pop-tit"[^>]*>(.*?)</h5>', li, re.S)
        href = re.search(r'href="([^"]+)"', li)
        img = re.search(r'<img[^>]*src="([^"]*)"', li)
        if tit:
            items.append({
                "title": strip_tags(tit.group(1)),
                "url": href.group(1) if href else "",
                "cover": img.group(1) if img else "",
            })
    return items


def step2_category(cats):
    """② 分类列表第一页: GET /pbook/  (单页, 83 本)"""
    slug = "/pbook/"
    if cats:
        for name, href in cats:
            if "单田芳" in name:
                slug = urllib.parse.urlparse(href).path
                break
    code, headers, html = fetch(BASE + slug)
    items = parse_book_items(html)
    pages = re.search(r'<span class="pages">(.*?)</span>', html, re.S)
    pages_txt = strip_tags(pages.group(1)) if pages else ""
    m = re.search(r"共\s*(\d+)\s*页\s*(\d+)\s*条记录", pages_txt)
    total = int(m.group(2)) if m else len(items)
    npage = int(m.group(1)) if m else 0
    good = bool(items) and total > 0
    first = items[0] if items else {"title": "?", "url": "-"}
    report("② 分类列表[单田芳评书] 第 1 页", good,
           "GET %s -> 共 %d 本 / %d 页 (单页全量) | 第一本: %s -> %s"
           % (slug, total, npage, first["title"], first["url"]))
    return {"items": items, "first": first, "total": total, "slug": slug}


def step3_search():
    """③ 搜索: /plus/search.php?kwtype=0&q=...  (3 秒限流, 需节流 + 重试)"""
    url = BASE + "/plus/search.php?" + urllib.parse.urlencode(
        {"kwtype": 0, "q": SEARCH_WORD})
    html = ""
    rate_limited = False
    for attempt in range(1, 7):
        gap = time.time() - _last_search_ts[0]
        if gap < SEARCH_MIN_GAP:
            time.sleep(SEARCH_MIN_GAP - gap)
        code, headers, html = fetch(url, extra_headers={"Referer": BASE + "/"})
        _last_search_ts[0] = time.time()
        if "管理员设定搜索时间间隔" in html:
            rate_limited = True
            continue
        if "条记录" in html:
            break
    hits = None
    m = re.search(r"共\s*(\d+)\s*页\s*/\s*(\d+)\s*条记录", html)
    if m:
        hits = int(m.group(2))
    items = parse_book_items(html)
    if hits is None:
        report("③ 搜索「%s」" % SEARCH_WORD, False,
               "未取到结果(限流=%s): %s" % (rate_limited, strip_tags(html)[:100]))
        return None
    first = items[0] if items else {"title": "(无)", "url": "-"}
    report("③ 搜索「%s」" % SEARCH_WORD, True,
           "%s -> 命中 %d 条 | 第一条: %s -> %s"
           % (urllib.parse.urlparse(url).path, hits, first["title"], first["url"]))
    return {"hits": hits, "items": items, "first": first}


def step4_detail(book_url):
    """④ 书籍详情: GET /pbook/{slug}/"""
    if book_url.startswith("http"):
        url = book_url
    else:
        url = BASE + book_url
    code, headers, html = fetch(url)
    title = re.search(r'<h3[^>]*class="[^"]*media-heading[^"]*title[^"]*"[^>]*>(.*?)</h3>', html, re.S)
    if not title:
        title = re.search(r'<h3[^>]*class="[^"]*title[^"]*"[^>]*>(.*?)</h3>', html, re.S)
    title = strip_tags(title.group(1)) if title else ""
    if not title:
        m = re.search(r"<title>(.*?)</title>", html, re.S)
        title = m.group(1).strip() if m else ""
    author = re.search(r"作者：\s*([^<\r\n]+)", html)
    author = author.group(1).strip() if author else ""
    kind = re.search(r"类型：\s*([^<\r\n]+)", html)
    kind = kind.group(1).strip() if kind else ""
    state = re.search(r"状态：\s*([^<\r\n]+)", html)
    state = state.group(1).strip() if state else ""
    cover = re.search(r'<img[^>]*class="media-object"[^>]*src="([^"]+)"', html) or \
            re.search(r'<img[^>]*src="([^"]+)"[^>]*class="media-object"', html)
    cover = cover.group(1) if cover else ""
    if cover.startswith("//"):
        cover = "http:" + cover
    # 该站没有独立的"播音"字段: 评书站里 作者==演播者(单田芳本人)
    boyin = re.search(r"演播：\s*([^<\r\n]+)|播音：\s*([^<\r\n]+)|播讲：\s*([^<\r\n]+)", html)
    boyin = next((g for g in boyin.groups() if g), "").strip() if boyin else ""
    report("④ 书籍详情", bool(title and cover),
           "%s | 作者: %s | 播音: %s | 类型: %s | 状态: %s | 封面: %s"
           % (title, author or "-", boyin or "(站点无播音字段, 作者即演播者)",
              kind or "-", state or "-", cover))
    return {"title": title, "author": author, "cover": cover, "html": html, "url": url}


def step5_chapters(detail):
    """⑤ 章节列表: 详情页底部 div.book-list > ul > li > a"""
    html = detail["html"]
    idx = html.find('<div class="book-list')
    if idx < 0:
        report("⑤ 章节列表", False, "详情页未找到 div.book-list 章节容器")
        return None
    seg = html[idx:]
    end = seg.find("</ul>")
    if end > 0:
        seg = seg[:end]
    chaps = []
    for href, title, text in anchors(seg):
        if re.search(r"/pbook/\d+\.html$", href):
            chaps.append((href, title or text))
    if not chaps:
        report("⑤ 章节列表", False, "book-list 内未解析到章节链接")
        return None
    first = chaps[0]
    report("⑤ 章节列表", True,
           "div.book-list -> 共 %d 章 (单页全量) | 第一章: %s -> %s"
           % (len(chaps), first[1], first[0]))
    return {"total": len(chaps), "items": chaps, "first": first}


def step6_audio(chapter_href):
    """⑥ 音频直链: 章节页 <audio><source src="...m4a">"""
    if chapter_href.startswith("http"):
        url = chapter_href
    else:
        url = BASE + chapter_href
    code, headers, html = fetch(url)
    src = re.search(r"<source[^>]*src=\"([^\"]+)\"", html) or \
          re.search(r"<audio[^>]*>.*?src=\"([^\"]+)\"", html, re.S)
    src = src.group(1) if src else ""
    if not src:
        report("⑥ 音频直链", False, "章节页未找到 <source src=...> (HTTP %s)" % code)
        return None
    if src.startswith("//"):
        src = "http:" + src
    audio_type = re.search(r"<source[^>]*type=\"([^\"]*)\"", html)
    audio_type = audio_type.group(1) if audio_type else ""

    try:
        st, hdr, blob = fetch(src, extra_headers={"Range": "bytes=0-1024",
                                                  "Referer": url}, raw_bytes=True)
    except Exception as exc:
        report("⑥ 音频直链", False, "直链请求异常: %r" % exc)
        return None
    ctype = (hdr.get("Content-Type") or "").lower()
    crange = hdr.get("Content-Range") or ""
    ct_ok = any(k in ctype for k in AUDIO_CT)
    good = st in (200, 206) and ct_ok and len(blob) > 0
    report("⑥ 音频直链", good,
           "Range bytes=0-1024 -> HTTP %s | Content-Type: %s | Content-Range: %s | %d bytes"
           % (st, ctype or "(无)", crange or "-", len(blob)))
    if good:
        print("       音频直链样例: %s" % src)
        if audio_type and "mpeg" in audio_type and "mp4" not in ctype:
            print("       注意: 页面 <source type> 写成 %r, 但 CDN 实际回 %r (以实际为准)"
                  % (audio_type, ctype))
    return src


# ---------------------------------------------------------------- main
def main():
    print("=" * 78)
    print("单田芳评书网 pingshu5.net 数据链路自检 (DedeCMS, 站点为响应式无独立手机站)")
    print("=" * 78)

    try:
        cats = step1_nav()
    except Exception as exc:
        report("① 分类/发现导航", False, "异常: %r" % exc)
        cats = []
    try:
        cat = step2_category(cats)
    except Exception as exc:
        report("② 分类列表", False, "异常: %r" % exc)
        cat = None
    try:
        step3_search()
    except Exception as exc:
        report("③ 搜索「%s」" % SEARCH_WORD, False, "异常: %r" % exc)

    book_url = cat["first"]["url"] if cat and cat["first"]["url"] else None
    if not book_url:
        report("④ 书籍详情", False, "没有可用的书籍 URL")
        report("⑤ 章节列表", False, "跳过")
        report("⑥ 音频直链", False, "跳过")
    else:
        detail = None
        try:
            detail = step4_detail(book_url)
        except Exception as exc:
            report("④ 书籍详情", False, "异常: %r" % exc)
        chapters = None
        if detail:
            try:
                chapters = step5_chapters(detail)
            except Exception as exc:
                report("⑤ 章节列表", False, "异常: %r" % exc)
        if chapters:
            try:
                step6_audio(chapters["first"][0])
            except Exception as exc:
                report("⑥ 音频直链", False, "异常: %r" % exc)
        else:
            report("⑥ 音频直链", False, "无章节链接")

    print("=" * 78)
    print("结果: %d OK / %d FAIL" % (_ok, _fail))
    print("=" * 78)
    return 1 if _fail else 0


if __name__ == "__main__":
    sys.exit(main())
