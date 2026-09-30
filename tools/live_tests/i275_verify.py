#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
i275_verify.py  --  275听书网 (m.i275.com / 听中国) 数据链路自检脚本

用途
    用最少的依赖、端到端验证「分类/发现 -> 列表 -> 搜索 -> 详情 -> 章节 -> 音频直链」
    这条链路在当前线上环境是否仍然可用。逐步打印 [OK]/[FAIL]。
    任何一步失败都会继续执行后续步骤，最后给出汇总与退出码。

依赖
    仅 Python 标准库 (urllib / http.cookiejar / gzip / re / json / base64)。

运行
    C:\\Users\\Administrator\\AppData\\Local\\Python\\bin\\python.exe i275_verify.py
    退出码 0 = 全 OK；1 = 有 FAIL。

关于站点结构的重要事实（脚本按此实现，详见同目录 i275.md）
    * 站点是自研 PHP + Tailwind 的极简移动站，没有分类(栏目)体系：
        首页只有「最近上架」12 本 + 热门搜索；没有 /list.php /category.php /sort.php
        也没有任何翻页（?page= / index.php?page= 均返回同一份 HTML）。
      所以 ② 的「列表第一页」用首页「最近上架」发现列表来代表；
      另外站点提供 search.php?q=<高频字> 作为全站浏览视图（服务端 LIMIT 50，无翻页）。
    * 关键坑 1：/play/{book}/{chapter}.html 会被 302 跳回首页，必须先在同一个
      CookieJar 里请求任意页面（如 GET /）拿到 PHPSESSID + notice_seen_<md5>=1
      这两个 Cookie，再请求 play 页才会返回真正的播放页。
    * 关键坑 2：音频直链是 ximalaya CDN (audiopay.cos.tx.xmcdn.com) 的签名 m4a，
      URL 在播放页内联 JS 的 APlayer 配置里，JSON 转义成 http:\\/\\/...，需要反转义。
    * 关键坑 3：/api_chapter.php?book_id=&chapter_id= 也能拿到同一个 URL，但它有
      「冷却」：约 30 秒内重复调用会返回 {"url":null}，所以不要作为主路径。
    * 编码：Content-Type 已经是 charset=UTF-8；脚本仍按 utf-8 -> gb18030 顺序兜底。
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

# ---------------------------------------------------------------- 基础配置

UA = ("Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36")

BASE = "https://m.i275.com"

# 自检用的固定样本（线上稳定存在的老书，章节多、不会因更新而变动）
SAMPLE_BOOK_ID = "39454"                # 《灵境行者丨头陀渊出品》
SAMPLE_BOOK_URL = BASE + "/book/%s.html" % SAMPLE_BOOK_ID
SEARCH_KEYWORD = "三体"

# 音频 Content-Type 白名单
AUDIO_CT_OK = ("audio/mpeg", "audio/mp4", "audio/x-m4a", "m4a")

TIMEOUT = 40
RETRIES = 3

# ---------------------------------------------------------------- HTTP 层

_cj = http.cookiejar.CookieJar()
_opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_cj))


class Resp(object):
    __slots__ = ("status", "headers", "body", "text", "url", "error")

    def __init__(self, status, headers, body, url, error=None):
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
        self.error = error
        self.text = ""

    @property
    def ct(self):
        return (self.headers.get("Content-Type") or "")

    def ok(self):
        return self.status in (200, 206) and self.error is None


def decode(raw):
    """中文站编码兜底：先 utf-8，失败退 gb18030，再退 latin-1 保底。"""
    if raw is None:
        return ""
    for enc in ("utf-8", "gb18030", "latin-1"):
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return raw.decode("utf-8", "replace")


RETRY_STATUS = (500, 502, 503, 504, 520, 521, 522, 523, 524, 525, 526)


def http_get(url, referer=None, extra_headers=None, redirect=True, retries=RETRIES):
    """带重试与自动编码识别的 GET。返回 Resp。

    重试两类失败：连接被重置/超时，以及 5xx 网关错误（偶发）。
    """
    headers = {
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Accept-Encoding": "gzip",
    }
    if referer:
        headers["Referer"] = referer
    if extra_headers:
        headers.update(extra_headers)

    last_err = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=headers)
            if redirect:
                r = _opener.open(req, timeout=TIMEOUT)
            else:
                # 单次请求禁用重定向，用来观察 302 行为
                no_redir = urllib.request.build_opener(
                    urllib.request.HTTPCookieProcessor(_cj),
                    _NoRedirect(),
                )
                r = no_redir.open(req, timeout=TIMEOUT)
            try:
                raw = r.read()
                hdrs = dict(r.headers)
                if (r.headers.get("Content-Encoding") or "").lower() == "gzip":
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass  # 有些响应头写着 gzip 其实没压缩
                status = getattr(r, "status", 200) or 200
                resp = Resp(status, hdrs, raw, r.geturl())
            finally:
                r.close()
            resp.text = decode(resp.body)
            if resp.status in RETRY_STATUS and attempt < retries - 1:
                time.sleep(1.5 + attempt * 1.5)
                continue
            return resp
        except urllib.error.HTTPError as e:
            raw = b""
            try:
                raw = e.read()
            except Exception:
                pass
            if e.code in RETRY_STATUS and attempt < retries - 1:
                time.sleep(1.5 + attempt * 1.5)
                continue
            resp = Resp(e.code, dict(e.headers or {}), raw, url)
            resp.text = decode(raw)
            return resp
        except Exception as e:                      # 连接被重置 / 超时等
            last_err = e
            time.sleep(1.5 + attempt * 1.5)
    return Resp(-1, {}, b"", url, error=repr(last_err))


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def warm_up():
    """关键坑 1：先打首页，拿到 PHPSESSID + notice_seen_<md5>=1，play 页才会放行。"""
    return http_get(BASE + "/")


# ---------------------------------------------------------------- 解析工具

def html_unescape(s):
    return (s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
             .replace("&quot;", '"').replace("&#39;", "'").replace("&nbsp;", " "))


def js_unescape_url(u):
    """把内联 JS 里 JSON 转义的 URL 还原：http:\\/\\/a\\/b -> http://a/b"""
    return u.replace("\\/", "/").replace("\\u0026", "&").replace("\\", "")


def strip_tags(s):
    return html_unescape(re.sub(r"<[^>]+>", "", s)).strip()


# ---------------------------------------------------------------- 各步骤

def step1_discovery():
    """① 分类/发现导航。

    i275 没有栏目页，发现入口就是首页上的三块：
      a) 「最近上架」书籍网格 (a[href^=/book/])
      b) 「热门搜索」快捷词 (a[href^=/book/] 位于 .mt-4 里)
      c) 搜索表单 (form[action=search.php] + input[name=q])
    本步骤验证这三块是否都还在。
    """
    r = http_get(BASE + "/")
    if not r.ok():
        return False, "首页请求失败 status=%s err=%s" % (r.status, r.error)

    grid = re.findall(r'<a href="(/book/\d+\.html)"[^>]*class="bg-white', r.text)
    not_found = ("index.php", "search.php")
    has_form = ('action="search.php"' in r.text or "action='search.php'" in r.text) \
        and 'name="q"' in r.text
    hot_block = re.search(r'<span>热门搜索：</span>(.*?)</div>', r.text, re.S)
    hot = re.findall(r"href='(/book/\d+\.html)'", hot_block.group(1)) if hot_block else []

    if not grid:
        return False, "首页未找到「最近上架」书籍网格 (a.bg-white[href=/book/N.html])"
    if not has_form:
        return False, "首页未找到搜索表单 (form[action=search.php] input[name=q])"
    if not hot:
        return False, "首页未找到「热门搜索」快捷入口"

    # 站内是否真的没有栏目页：确认旧式栏目路径确实 404（信息性，不影响判定）
    probes = {}
    for p in ("/list.php", "/category.php", "/sort.php"):
        rr = http_get(BASE + p)
        probes[p] = rr.status

    return True, ("首页发现入口 3 处：最近上架 %d 本 / 热门搜索 %d 个 / 搜索表单 OK；"
                  "栏目页探测 %s（确认本站无栏目体系，发现=首页+搜索）"
                  % (len(set(grid)), len(set(hot)), probes))


def step2_listing():
    """② 列表第一页：共多少本、第一本标题。

    i275 无分类目录、无翻页，所以取首页「最近上架」发现列表作为列表第一页；
    同时给出 search.php?q=<高频字> 的全站浏览视图（服务端 LIMIT 50）。
    """
    r = http_get(BASE + "/")
    if not r.ok():
        return False, "首页请求失败 status=%s" % r.status

    # 逐块切出「最近上架」下的条目，拿标题
    items = []
    for m in re.finditer(
            r'<a href="(/book/\d+\.html)"[^>]*class="bg-white[^"]*"[^>]*>(.*?)</a>',
            r.text, re.S):
        href, inner = m.group(1), m.group(2)
        tm = re.search(r'<div class="font-medium[^"]*">(.*?)</div>', inner, re.S)
        title = strip_tags(tm.group(1)) if tm else strip_tags(
            re.search(r'alt="([^"]*)"', inner).group(1) if re.search(r'alt="([^"]*)"', inner) else "")
        if title:
            items.append((href, title))

    if not items:
        return False, "无法从首页「最近上架」解析出书籍条目"

    # 附：全站浏览视图（高频字命中，服务端 LIMIT 50，无翻页）
    browse_url = BASE + "/search.php?q=" + urllib.parse.quote("第")
    rb = http_get(browse_url)
    bm = re.search(r"的结果\s*\((\d+)\)", rb.text) if rb.ok() else None
    browse_n = bm.group(1) if bm else "?"

    detail = ("列表(首页最近上架) 共 %d 本 | 第一本: %s  ->  %s\n"
              "            全站浏览视图 search.php?q=第 命中 %s 本（服务端 LIMIT 50，无翻页）"
              % (len(items), items[0][1], items[0][0], browse_n))
    return True, detail


def step3_search():
    """③ 搜索「三体」：命中数 + 第一条标题/链接。"""
    url = BASE + "/search.php?q=" + urllib.parse.quote(SEARCH_KEYWORD)
    r = http_get(url)
    if not r.ok():
        return False, "搜索请求失败 status=%s err=%s" % (r.status, r.error)

    m = re.search(r"的结果\s*\((\d+)\)", r.text)
    if not m:
        return False, "搜索页未找到命中数标记（正则：的结果\\s*\\((\\d+)\\)）"
    count = int(m.group(1))
    if count <= 0:
        return False, "搜索「%s」命中 0 条" % SEARCH_KEYWORD

    first = re.search(
        r'<a href="(/book/\d+\.html)"[^>]*class="flex p-4 gap-4[^"]*"[^>]*>(.*?)</a>',
        r.text, re.S)
    if not first:
        return False, "搜索页有命中数但解析不出第一条结果"
    link = first.group(1)
    tm = re.search(r'<h3[^>]*>(.*?)</h3>', first.group(2), re.S)
    title = strip_tags(tm.group(1)) if tm else "(无标题)"

    return True, ("命中 %d 条 | 第一条: %s  ->  %s" % (count, title, link))


def step4_detail():
    """④ 书籍详情：标题 / 作者 / 播音 / 封面。"""
    r = http_get(SAMPLE_BOOK_URL)
    if not r.ok():
        return False, "书籍页请求失败 status=%s" % r.status

    tm = re.search(r'<h1 class="text-2xl font-bold text-gray-800">(.*?)</h1>', r.text, re.S)
    title = strip_tags(tm.group(1)) if tm else ""

    am = re.search(r"作者：<span[^>]*>(.*?)</span>", r.text, re.S)
    author = strip_tags(am.group(1)) if am else ""

    nm = re.search(r"演播：<span[^>]*>(.*?)</span>", r.text, re.S)
    narrator = strip_tags(nm.group(1)) if nm else ""

    cm = re.search(r'<div class="w-32 h-44[^"]*">\s*<img src="([^"]+)"', r.text)
    cover = cm.group(1) if cm else ""

    missing = [k for k, v in (("标题", title), ("作者", author),
                              ("播音", narrator), ("封面", cover)) if not v]
    if missing:
        return False, "书籍详情缺字段: %s (title=%r author=%r narrator=%r cover=%r)" % (
            ",".join(missing), title, author, narrator, cover)

    return True, ("标题: %s | 作者: %s | 播音: %s | 封面: %s"
                  % (title, author, narrator, cover))


def step5_chapters():
    """⑤ 章节列表：共多少章、第一章标题。

    章节直接内嵌在书籍详情页里（整页 400KB 左右），形如
        <a id="chapter-pos-1" href="/play/39454/23581985.html" ...>
            <span class="text-sm text-gray-700 truncate">灵境行者 第1集 礼物</span>
    页面上还写着「正文目录 (570)」，两个数字必须一致。
    """
    r = http_get(SAMPLE_BOOK_URL)
    if not r.ok():
        return False, "书籍页请求失败 status=%s" % r.status

    # 注意：章节锚点带 id="chapter-pos-N"，必须按 id 匹配。
    # 页面上「立即开始收听」按钮用的是同一个 /play/... href，按 href 找会先命中按钮。
    anchors = re.findall(
        r'<a id="chapter-pos-(\d+)"[^>]*href="(/play/\d+/\d+\.html)"[^>]*>(.*?)</a>',
        r.text, re.S)

    seen, ordered = set(), []
    for _, h, _inner in anchors:
        if h not in seen:
            seen.add(h)
            ordered.append(h)

    cm = re.search(r"正文目录\s*\((\d+)\)", r.text)
    declared = int(cm.group(1)) if cm else -1

    first_title = ""
    if anchors:
        tm = re.search(r'<span class="text-sm text-gray-700 truncate">(.*?)</span>',
                       anchors[0][2], re.S)
        if tm:
            first_title = strip_tags(tm.group(1))
    if not first_title:
        return False, "解析出 %d 个章节链接但取不到第一章标题" % len(ordered)

    if declared > 0 and declared != len(ordered):
        return False, ("页内声明 %d 章，实际解析出 %d 个章节链接，不一致"
                       % (declared, len(ordered)))

    return True, "共 %d 章（页内声明 %s）| 第一章: %s  ->  %s" % (
        len(ordered), declared if declared > 0 else "?", first_title, ordered[0])


def _play_page(book_id, chapter_id):
    """取真正的播放页。必须先 warm_up()，否则 302 回首页。"""
    warm_up()
    url = "%s/play/%s/%s.html" % (BASE, book_id, chapter_id)
    return url, http_get(url, referer=SAMPLE_BOOK_URL)


def step6_audio(chapter_link):
    """⑥ 音频直链：拿 URL + Range 探测。

    音频 URL 藏在播放页内联 JS 的 APlayer 初始化里：
        const ap = new APlayer({ ..., audio: [{ name:"...", url:"http:\\/\\/audiopay...m4a?sign=...", ... }] })
    需要把 \\/ 还原成 /。
    """
    m = re.match(r"^/play/(\d+)/(\d+)\.html$", chapter_link or "")
    if not m:
        return False, "章节链接格式异常: %r" % chapter_link
    book_id, chapter_id = m.group(1), m.group(2)

    url, r = _play_page(book_id, chapter_id)
    if not r.ok():
        return False, "播放页请求失败 status=%s err=%s (%s)" % (r.status, r.error, url)
    if "APlayer" not in r.text:
        return False, ("播放页未返回播放器（可能被 302 回首页：len=%d）。"
                       "检查是否遗漏 warm_up() 拿 PHPSESSID + notice_seen_* Cookie" % len(r.text))

    am = re.search(r'url:\s*"((?:[^"\\]|\\.)*?\.(?:m4a|mp3)(?:[^"\\]|\\.)*)"', r.text)
    if not am:
        return False, "播放页内联 JS 里找不到 APlayer 的 audio[].url"
    audio = js_unescape_url(am.group(1))
    if not audio.startswith("http"):
        return False, "解析出的音频 URL 不合法: %r" % audio[:120]

    # Range 探测
    rr = http_get(audio, referer=url, extra_headers={"Range": "bytes=0-1024"})
    ct = rr.ct.lower()
    ct_hit = any(t in ct for t in AUDIO_CT_OK)
    if not rr.ok():
        return False, "音频 Range 请求失败 status=%s ct=%s (%s)" % (rr.status, rr.ct, audio[:110])
    if not ct_hit:
        return False, "音频 Content-Type 不在白名单: %r (%s)" % (rr.ct, audio[:110])

    # 附：api_chapter.php 备用路径（有 ~30s 冷却，仅作信息展示，不参与判定）
    api_note = ""
    api = "%s/api_chapter.php?book_id=%s&chapter_id=%s" % (BASE, book_id, chapter_id)
    ra = http_get(api, referer=url)
    if ra.ok():
        try:
            d = json.loads(ra.text)
            api_note = ("  |  备用 /api_chapter.php: url=%s"
                        % ("OK" if d.get("url") else "null(冷却中/非法访问)"))
        except Exception:
            api_note = "  |  备用 /api_chapter.php: 非 JSON"

    return True, ("HTTP %d | Content-Type: %s | Content-Range: %s | 取回 %d 字节%s\n"
                  "            音频直链: %s"
                  % (rr.status, rr.ct, rr.headers.get("Content-Range"),
                     len(rr.body), api_note, audio))


# ---------------------------------------------------------------- 主流程

def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    print("=" * 78)
    print("275听书网 (i275) 数据链路自检")
    print("  入口: %s" % BASE)
    print("  样本: %s  |  搜索词: %s" % (SAMPLE_BOOK_URL, SEARCH_KEYWORD))
    print("  UA  : %s" % UA)
    print("=" * 78)

    # 关键坑 1：全程共用一个 CookieJar，并且先 warm_up
    warm_up()

    chapter_link = None
    results = []

    # ① 发现导航
    ok, detail = step1_discovery()
    results.append(("① 分类/发现导航", ok, detail))
    print("\n[%s] ① 分类/发现导航\n     %s" % ("OK" if ok else "FAIL", detail))

    # ② 列表第一页
    ok, detail = step2_listing()
    results.append(("② 列表第一页", ok, detail))
    print("\n[%s] ② 列表第一页（共多少本 / 第一本标题）\n     %s"
          % ("OK" if ok else "FAIL", detail))

    # ③ 搜索
    ok, detail = step3_search()
    results.append(("③ 搜索「三体」", ok, detail))
    print("\n[%s] ③ 搜索「%s」\n     %s" % ("OK" if ok else "FAIL", SEARCH_KEYWORD, detail))

    # ④ 书籍详情
    ok, detail = step4_detail()
    results.append(("④ 书籍详情", ok, detail))
    print("\n[%s] ④ 书籍详情\n     %s" % ("OK" if ok else "FAIL", detail))

    # ⑤ 章节列表
    ok, detail = step5_chapters()
    results.append(("⑤ 章节列表", ok, detail))
    print("\n[%s] ⑤ 章节列表\n     %s" % ("OK" if ok else "FAIL", detail))
    m = re.search(r"->\s*(/play/\d+/\d+\.html)", detail)
    if m:
        chapter_link = m.group(1)

    # ⑥ 音频直链
    ok, detail = step6_audio(chapter_link)
    results.append(("⑥ 音频直链", ok, detail))
    print("\n[%s] ⑥ 音频直链\n     %s" % ("OK" if ok else "FAIL", detail))

    # 汇总
    print("\n" + "=" * 78)
    failed = [n for n, o, _ in results if not o]
    for name, o, _ in results:
        print("  [%s] %s" % ("OK" if o else "FAIL", name))
    print("-" * 78)
    if failed:
        print("结果: %d/%d 项通过，失败: %s" % (len(results) - len(failed), len(results),
                                              ", ".join(failed)))
        return 1
    print("结果: 全部 %d 项通过 [OK]" % len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
