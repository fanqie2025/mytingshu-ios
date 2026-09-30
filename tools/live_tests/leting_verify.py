#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
乐听网 (https://www.leting.vip / https://m.leting.vip) 数据链路自检脚本
=======================================================================
只用 Python 标准库。依次验证:
  ① 分类/发现导航      GET  /sort/
  ② 分类列表(第一页)   GET  /book/{cat}/lastupdate.html  ->  GET /api/ajax/list
  ③ 搜索「三体」       GET  /search.html?searchword=..   ->  GET /api/ajax/solist
  ④ 书籍详情           GET  /book/{id}.html
  ⑤ 章节列表           GET  /bookdir/{hash}.html
  ⑥ 音频直链           GET  /tingshu/{book}/{ch}.html -> POST /api/act/readplay -> Range

运行:  python leting_verify.py
"""
import base64
import gzip
import http.cookiejar
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------- 常量
MOBILE_UA = ("Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 "
             "(KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36")
BASE = "https://m.leting.vip"            # 手机站才有声音直链; www 是桌面站
TIMEOUT = 30
SEARCH_WORD = "三体"

# 音频 Content-Type 白名单
AUDIO_CT = ("audio/mpeg", "audio/mp4", "audio/x-m4a", "m4a")

_ok = 0
_fail = 0


def report(step, good, msg):
    """打印 [OK]/[FAIL] 并累计计数。good=True 记 OK。"""
    global _ok, _fail
    tag = "[OK]" if good else "[FAIL]"
    if good:
        _ok += 1
    else:
        _fail += 1
    print("%s %s %s" % (tag, step, msg))


# ---------------------------------------------------------------- HTTP 层
class Session(object):
    """带 CookieJar 的会话, 自动处理乐听网的 pt_guid 反爬跳转。"""

    def __init__(self):
        self.cj = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cj))

    def _open(self, url, data=None, extra_headers=None, method=None, retries=4):
        headers = {
            "User-Agent": MOBILE_UA,
            "Accept": "text/html,application/xhtml+xml,application/json,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Connection": "close",
        }
        headers.update(extra_headers or {})
        last_exc = None
        for attempt in range(retries):
            try:
                req = urllib.request.Request(url, data=data, headers=headers, method=method)
                try:
                    resp = self.opener.open(req, timeout=TIMEOUT)
                except urllib.error.HTTPError as exc:
                    if exc.code >= 500:
                        raise
                    resp = exc
                raw = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    raw = gzip.decompress(raw)
                return resp.getcode(), dict(resp.headers), raw
            except Exception as exc:          # 网络抖动 / 超时 / 5xx
                last_exc = exc
                time.sleep(0.8 + attempt)
        raise last_exc

    @staticmethod
    def decode(raw, headers):
        """乐听网声明 UTF-8, 但仍按 UTF-8 -> GB18030 兜底。"""
        ctype = (headers.get("Content-Type") or "").lower()
        charset = None
        if "charset=" in ctype:
            charset = ctype.split("charset=")[-1].split(";")[0].strip()
        order = [charset] if charset in ("utf-8", "utf8", "gbk", "gb2312", "gb18030") else []
        order += ["utf-8", "gb18030"]
        for enc in order:
            try:
                return raw.decode(enc)
            except (UnicodeDecodeError, LookupError):
                continue
        return raw.decode("utf-8", "replace")

    def _solve_guard(self, url, data=None, extra_headers=None, method=None):
        """乐听网 /tingshu/ /bookdir/ 页面返回一段混淆 JS:
             var reversed = "<base64 反转串>";
             var b64 = reversed.split('').reverse().join('');
             var code = atob(b64);  // code 里是 document.cookie='pt_guid=...;'
           它不是真 JS 校验, 只要把 pt_guid(和 ptcms_guard_retry) 塞进 CookieJar 再请求即可。
        """
        code, headers, raw = self._open(url, data, extra_headers, method)
        text = self.decode(raw, headers)
        hit = re.search(r'var\s+reversed\s*=\s*"([^"]+)"\s*;', text)
        if not hit:
            return code, headers, raw
        try:
            js = base64.b64decode(hit.group(1)[::-1] + "===").decode("utf-8", "replace")
            token = re.search(r"var\s+token\s*=\s*'([^']+)'\s*;", js).group(1)
        except Exception:
            return code, headers, raw
        host = urllib.parse.urlparse(url).hostname
        for name, value in (("pt_guid", token), ("ptcms_guard_retry", "1")):
            self.cj.set_cookie(http.cookiejar.Cookie(
                0, name, value, None, False, host, False, False, "/", True,
                False, None, False, None, None, {}))
        return self._open(url, data, extra_headers, method)

    def get(self, url, extra_headers=None, save_to=None):
        code, headers, raw = self._solve_guard(url, extra_headers=extra_headers)
        text = self.decode(raw, headers)
        if save_to is not None:
            save_to.append(text)
        return code, headers, text

    def post_json(self, url, payload, extra_headers=None):
        body = json.dumps(payload).encode("utf-8") if not isinstance(payload, bytes) else payload
        headers = {"Content-Type": "application/json; charset=utf-8"}
        headers.update(extra_headers or {})
        code, hdr, raw = self._solve_guard(url, data=body, extra_headers=headers, method="POST")
        return code, hdr, self.decode(raw, hdr)


def strip_tags(html):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", html)).strip()


# ---------------------------------------------------------------- 各步骤
def step1_nav(sess):
    """① 分类/发现导航: GET /sort/  ->  dl.pd-class 分组"""
    code, headers, html = sess.get(BASE + "/sort/")
    groups = []          # [(组名, [(分类名, 相对链接), ...]), ...]
    for block in re.findall(r"<dl class=\"pd-class\">(.*?)</dl>", html, re.S):
        dt = re.search(r"<dt>.*?<a[^>]*>(.*?)</a>", block, re.S)
        gname = strip_tags(dt.group(1)) if dt else "?"
        items = []
        for href, title, label in re.findall(
                r'<dd>\s*<a href="([^"]+)"\s+title="([^"]*)"[^>]*>(.*?)</a>', block, re.S):
            items.append((strip_tags(label) or title, href))
        if items:
            groups.append((gname, items))
    total = sum(len(v) for _, v in groups)
    if code == 200 and total:
        first_g, first_items = groups[0]
        report("① 分类/发现导航",
               True,
               "GET /sort/ -> %d 组 / %d 个分类 | 首组「%s」首项「%s」-> %s"
               % (len(groups), total, first_g, first_items[0][0], first_items[0][1]))
        return groups
    report("① 分类/发现导航", False, "HTTP %s, 解析到 %d 个分类" % (code, total))
    return groups


def _cat_api_url(html):
    """分类页把 API 参数写在内联 <script> 里, 这里照抄。"""
    def var(name, default=""):
        # 坑: __API_ORDER 那行结尾没有分号, 正则必须允许缺省 ";"
        m = re.search(r"var\s+%s\s*=\s*'([^']*)'" % name, html)
        return m.group(1).strip() if m else default
    qs = urllib.parse.urlencode({
        "sort": var("__API_SORT", "1"),
        "key": var("__API_KEY", "1"),
        "tg": var("__API_TG", ""),
        "order": var("__API_ORDER", "1"),
        "page": var("__API_PAGE", "1"),
    })
    return "/api/ajax/list?" + qs


def step2_category(sess, groups):
    """② 分类列表第一页: 分类页(壳) -> /api/ajax/list (JSON)"""
    if not groups or not groups[0][1]:
        report("② 分类列表", False, "① 未拿到分类链接")
        return None
    cat_name, cat_href = groups[0][1][0]
    slug = "/".join(cat_href.strip("/").split("/")[:2])          # book/xhqh
    code, headers, html = sess.get(BASE + "/" + slug + "/lastupdate.html")
    api = _cat_api_url(html)
    code2, hdr2, body = sess.get(BASE + api, extra_headers={
        "X-Requested-With": "XMLHttpRequest", "Referer": BASE + "/" + slug + "/lastupdate.html"})
    try:
        js = json.loads(body)
        total = int(js["total"])
        last_page = int(js.get("last_page", 0))
        per_page = int(js.get("per_page", 0))
        first = js["data"][0]
        report("② 分类列表[%s] 第 1 页" % cat_name, True,
               "%s -> 共 %d 本 / %d 页 (每页 %d) | 第一本: %s -> %s"
               % (api.split("?")[0], total, last_page, per_page,
                  first["title"], first["url"]))
        return {"category": cat_name, "total": total, "first": first}
    except Exception as exc:
        report("② 分类列表[%s]" % cat_name, False, "HTTP %s JSON 解析失败: %r" % (code2, exc))
        return None


def step3_search(sess):
    """③ 搜索「三体」: /search.html 给命中总数, /api/ajax/solist 给结果"""
    q = urllib.parse.quote(SEARCH_WORD, safe="")
    code, headers, html = sess.get(BASE + "/search.html?searchword=" + q)
    # 命中数在 共“<em ...>4</em>”条
    m = re.search(r"共\s*[“\"']?\s*(?:<em[^>]*>)?\s*([\d,]+)\s*(?:</em>)?\s*[”\"']?\s*条", html)
    hits_from_page = int(m.group(1).replace(",", "")) if m else None

    # 注意: 站点自己会做两层 encodeURIComponent, 但服务端解两遍,
    # 所以这里单层 quote 同样有效(服务端第一遍解出中文, 第二遍无副作用)。
    api = "/api/ajax/solist?" + urllib.parse.urlencode(
        {"word": SEARCH_WORD, "type": "name", "page": 1, "order": 1})
    code2, hdr2, body = sess.get(BASE + api, extra_headers={
        "X-Requested-With": "XMLHttpRequest",
        "Referer": BASE + "/search.html?searchword=" + q})
    try:
        arr = json.loads(body) or []
        first = arr[0]["novel"] if arr else {}
        hits = hits_from_page if hits_from_page is not None else len(arr)
        good = bool(arr) and hits > 0
        report("③ 搜索「%s」" % SEARCH_WORD, good,
               "%s -> 命中 %s 条 | 第一条: %s -> %s"
               % (api.split("?")[0], hits,
                  first.get("name", "(无)"), first.get("url", "-")))
        return arr
    except Exception as exc:
        report("③ 搜索「%s」" % SEARCH_WORD, False, "HTTP %s JSON 解析失败: %r" % (code2, exc))
        return None


def step4_detail(sess, book_url):
    """④ 书籍详情: GET /book/{id}.html"""
    code, headers, html = sess.get(BASE + book_url)
    title = re.search(r'<h1[^>]*class="book-title"[^>]*>(.*?)</h1>', html, re.S)
    title = strip_tags(title.group(1)) if title else ""
    if not title:
        m = re.search(r"<title>(.*?)</title>", html, re.S)
        title = m.group(1).split("有声小说")[0].strip() if m else ""
    cover = re.search(r'<img[^>]*src="([^"]+)"[^>]*class="book-cover"', html) or \
            re.search(r'<img[^>]*class="book-cover"[^>]*src="([^"]+)"', html)
    cover = cover.group(1) if cover else ""
    if cover.startswith("/"):
        cover = BASE + cover
    # 播音(播讲) — 乐听网没有「作者」字段, 只有播讲人 /boyin/{id}.html
    boyin = re.search(r'<a href="(/boyin/\d+\.html)"[^>]*title="([^"]*)"[^>]*>(.*?)</a>', html, re.S)
    boyin_name = strip_tags(boyin.group(3)) if boyin else ""
    boyin_url = (BASE + boyin.group(1)) if boyin else ""
    cat = re.search(r'类型：\s*<a[^>]*>([^<]+)</a>', html)
    cat = cat.group(1).strip() if cat else ""
    dur = re.search(r"时长：\s*([\d:]+)", html)
    dur = dur.group(1) if dur else ""
    good = bool(title and cover)
    report("④ 书籍详情", good,
           "%s | 作者: (站点无作者字段) | 播音: %s (%s) | 类型: %s | 时长: %s | 封面: %s"
           % (title, boyin_name or "?", boyin_url or "-", cat or "-", dur or "-", cover))
    return {"title": title, "cover": cover, "boyin": boyin_name,
            "category": cat, "html": html}


def step5_chapters(sess, book_url, detail):
    """⑤ 章节列表: 详情页「总 N 集」+ /bookdir/... 第 1 页"""
    total_m = re.search(r"总\s*([\d,]+)\s*集", detail["html"])
    total = int(total_m.group(1).replace(",", "")) if total_m else 0
    dirurl = re.search(r'<a href="([^"]+)"\s+class="dirurl"', detail["html"]) or \
             re.search(r'<a[^>]*class="dirurl"[^>]*href="([^"]+)"', detail["html"])
    if not dirurl:
        report("⑤ 章节列表", False, "详情页未找到 a.dirurl 全本目录链接")
        return None
    code, headers, html = sess.get(BASE + dirurl.group(1))
    chaps = re.findall(r'<a href="(/tingshu/\d+/(\d+)\.html)"[^>]*title="([^"]*)"', html)
    if not chaps:
        chaps = [(u, c, "") for u, c in
                 re.findall(r'<a href="(/tingshu/\d+/(\d+)\.html)"', html)]
    if not chaps:
        report("⑤ 章节列表", False, "bookdir 页未解析到章节链接")
        return None
    href, cid, label = chaps[0]
    if not label:
        label = "第 %s 章" % cid
    good = total > 0
    report("⑤ 章节列表", good,
           "%s -> 共 %d 章 | 每页 50 章 | 第一章: %s -> %s"
           % (dirurl.group(1), total, label.strip()[:40], href))
    return {"total": total, "first_href": href, "first_title": label.strip(),
            "first_cid": cid, "dirurl": dirurl.group(1)}


def step6_audio(sess, chapter_href):
    """⑥ 音频直链: 章节页 <meta name="_c"> 是 salt, POST /api/act/readplay 换 mp3"""
    url = BASE + chapter_href
    code, headers, html = sess.get(url)

    def meta(name):
        m = re.search(r'<meta\s+name="%s"\s+content="([^"]*)"' % name, html)
        return m.group(1).strip() if m else ""

    novelid, chapterid, salt = meta("_b"), meta("_p"), meta("_c")
    if not (novelid and chapterid and salt):
        report("⑥ 音频直链", False,
               "章节页缺少 _b/_p/_c meta (novelid=%r chapterid=%r salt=%r); "
               "该页可能仍被反爬挡住" % (novelid, chapterid, salt))
        return None

    payload = json.dumps({"novelid": novelid, "chapterid": chapterid, "type": 1, "salt": salt},
                         separators=(",", ":"))
    encoded = base64.b64encode(urllib.parse.quote(payload, safe="").encode()).decode()
    body = json.dumps({"encodedData": encoded}, separators=(",", ":")).encode("utf-8")
    code2, hdr2, text = sess.post_json(
        BASE + "/api/act/readplay", body,
        extra_headers={"Referer": url, "Origin": BASE, "X-Requested-With": "XMLHttpRequest"})
    try:
        js = json.loads(text)
    except Exception:
        report("⑥ 音频直链", False, "readplay 返回非 JSON(HTTP %s): %s" % (code2, text[:120]))
        return None
    audio = js.get("audioUrl")
    if not audio:
        report("⑥ 音频直链", False, "readplay 未返回 audioUrl: %s" % text[:120])
        return None

    # Range 探测直链 (CDN 偶发抖动, 带重试)
    status, ctype, crange, blob = None, "", "", b""
    for attempt in range(4):
        req = urllib.request.Request(audio, headers={
            "User-Agent": MOBILE_UA, "Range": "bytes=0-1024", "Referer": BASE + "/"})
        try:
            resp = urllib.request.urlopen(req, timeout=TIMEOUT)
            status = resp.getcode()
            ctype = (resp.headers.get("Content-Type") or "").lower()
            crange = resp.headers.get("Content-Range") or ""
            blob = resp.read()
            break
        except urllib.error.HTTPError as exc:
            status = exc.code
            ctype = (exc.headers.get("Content-Type") or "").lower()
            crange = exc.headers.get("Content-Range") or ""
            blob = exc.read()
            break
        except Exception as exc:
            if attempt == 3:
                report("⑥ 音频直链", False, "直链请求异常: %r" % exc)
                return None
            time.sleep(1.0 + attempt)

    ct_ok = any(k in ctype for k in AUDIO_CT)
    good = status in (200, 206) and ct_ok and len(blob) > 0
    report("⑥ 音频直链", good,
           "Range bytes=0-1024 -> HTTP %s | Content-Type: %s | Content-Range: %s | %d bytes"
           % (status, ctype or "(无)", crange or "-", len(blob)))
    if good:
        print("       音频直链样例: %s" % audio)
    return audio


# ---------------------------------------------------------------- main
def main():
    print("=" * 78)
    print("乐听网 leting.vip 数据链路自检 (手机站 m.leting.vip, 移动 UA)")
    print("=" * 78)
    sess = Session()

    try:
        groups = step1_nav(sess)
    except Exception as exc:
        report("① 分类/发现导航", False, "异常: %r" % exc)
        groups = []
    try:
        cat = step2_category(sess, groups)
    except Exception as exc:
        report("② 分类列表", False, "异常: %r" % exc)
        cat = None
    try:
        search = step3_search(sess)
    except Exception as exc:
        report("③ 搜索「%s」" % SEARCH_WORD, False, "异常: %r" % exc)
        search = None

    # 详情/章节/音频: 优先用 ③ 搜到的第一本(证明"搜索->详情"链路),
    # 搜索无结果时退回 ② 分类第一本。
    book_url = None
    if search:
        book_url = search[0]["novel"]["url"]
    elif cat:
        book_url = cat["first"]["url"]
    if not book_url:
        report("④ 书籍详情", False, "没有可用的书籍 URL")
        report("⑤ 章节列表", False, "跳过")
        report("⑥ 音频直链", False, "跳过")
    else:
        detail = None
        try:
            detail = step4_detail(sess, book_url)
        except Exception as exc:
            report("④ 书籍详情", False, "异常: %r" % exc)
        chapters = None
        if detail:
            try:
                chapters = step5_chapters(sess, book_url, detail)
            except Exception as exc:
                report("⑤ 章节列表", False, "异常: %r" % exc)
        if chapters:
            try:
                step6_audio(sess, chapters["first_href"])
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
