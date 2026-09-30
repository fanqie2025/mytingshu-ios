#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ting13_verify.py  --  13听书网 / 听13网 (www.ting13.cc / m.ting13.cc) 数据链路自检

用法:  python ting13_verify.py
依赖:  仅标准库 (urllib / http.cookiejar / re / json / gzip / ssl / zlib)

依次验证并打印 [OK]/[FAIL]:
  ① 分类/发现导航            ② 分类列表第一页(共多少本 / 第一本标题)
  ③ 搜索「三体」(命中数 / 第一条标题+链接)
  ④ 书籍详情(标题/作者/播音/封面)
  ⑤ 章节列表(共多少章 / 第一章标题)
  ⑥ 音频直链(Range: bytes=0-1024, 要求 200/206 且 Content-Type 为音频)

关键结论(详见 sources/ting13.md):
  * 与爱听书是同一套 PTCMS 程序(连书库都相同), 页面 UTF-8。
  * 播放页 HTML 里 **没有** 明文音频地址。手机版播放页加载
        /cdn/wap/script/read.js      (jsjiami.com.v7 混淆)
    PC 版加载 /cdn/web/script/player/mian.js (同样是 jsjiami.com.v7)
    两者最终都走  POST /api/mapi/play  并带请求头  sc / sp
      sc = <meta name="_c">   sp = 由 sc 混淆生成(本脚本已用纯 Python 复刻)
    返回 JSON: {"status":200,"name":"1_2","url":"http://mp3ms.ysxs.top/.../0001.m4a"}
  * 所以 **不需要 WebView 嗅探**, 纯 Python 就能拿到明文 m4a 直链。
"""

import gzip
import http.cookiejar
import json
import random
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib

# --------------------------------------------------------------------------
# 配置
# --------------------------------------------------------------------------
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
# 站方按 UA 分流, 两个 UA 各有脾气(实测):
#   手机 UA : 分类列表/搜索页完整渲染(20 条/页); 但 /tingdirs/ 章节目录会被 429;
#             而且 www 播放页会被下成 <meta name="_b/_p/_c"> 全空的空壳。
#   桌面 UA : 章节目录正常、www 播放页 meta 正常; 但分类列表只渲染 6 条(被截断)。
# 所以默认用手机 UA, 命中 429 自动切桌面 UA; 播放页/音频接口固定用桌面 UA。
UA_MOBILE = ("Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 "
             "(KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36")
UA_ROTATION = [UA_MOBILE, UA]

SITE = "https://www.ting13.cc"
SITE_M = "https://m.ting13.cc"

CATEGORY = "/yousheng/xuanhuan/lastupdate.html"   # 玄幻修真分类第一页
DEMO_BOOK = 8219                                   # 百炼成仙(演示用, 数据稳定)
SEARCH_WORD = "三体"

AUDIO_TYPES = ("audio/mpeg", "audio/mp4", "audio/x-m4a", "m4a")
SP_ALPHABET = "PXhw7U1B0a9kQDKZsTjIASmOeNzxYG4CHo1JyRfg2b8FLpEvr3FtVnlqMidu6c"

_SSL_UNVERIFIED = ssl._create_unverified_context()

RESULTS = []


# --------------------------------------------------------------------------
# sp 签名: read.js / mian.js 内 _0x39d980() / _0x9926ad() 的等价实现
#   对 sc 的每个字符 c:
#       i = ALPHABET.find(c)
#       t = c if i < 0 else ALPHABET[(i + 3) % 62]
#       out += ALPHABET[rand(62)] + t + ALPHABET[rand(62)]
#   服务端只校验「每 3 个字符里中间那个回退 3 位 == sc」, 两侧是随机烟雾弹。
# --------------------------------------------------------------------------
def make_sp(sc, alphabet=SP_ALPHABET):
    n = len(alphabet)
    out = []
    for ch in sc:
        i = alphabet.find(ch)
        t = ch if i < 0 else alphabet[(i + 3) % n]
        out.append(alphabet[random.randrange(n)] + t + alphabet[random.randrange(n)])
    return "".join(out)


def unsp(sp, alphabet=SP_ALPHABET):
    """逆运算, 用于自校验。"""
    n = len(alphabet)
    res = []
    for i in range(0, len(sp) - 2, 3):
        t = sp[i + 1]
        j = alphabet.find(t)
        res.append(alphabet[(j - 3) % n] if j >= 0 else t)
    return "".join(res)


# --------------------------------------------------------------------------
# HTTP 客户端
# --------------------------------------------------------------------------
class Client(object):
    def __init__(self, ua=UA_MOBILE):
        self.ua = ua
        self.cj = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cj),
            urllib.request.HTTPSHandler(context=_SSL_UNVERIFIED),
        )
        self.challenges = 0

    def _raw(self, url, data=None, headers=None, method=None, timeout=30, ua=None):
        h = {
            "User-Agent": ua or self.ua,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Accept-Encoding": "gzip, deflate",
        }
        if headers:
            h.update(headers)
        req = urllib.request.Request(url, data=data, headers=h, method=method)
        try:
            r = self.op.open(req, timeout=timeout)
            st, hd, body = r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            st, hd, body = e.code, dict(e.headers), e.read()
        except Exception as e:
            return None, {"err": repr(e)}, b""
        enc = (hd.get("Content-Encoding") or "").lower()
        if "gzip" in enc:
            try:
                body = gzip.decompress(body)
            except Exception:
                pass
        elif "deflate" in enc:
            try:
                body = zlib.decompress(body, -zlib.MAX_WBITS)
            except Exception:
                pass
        return st, hd, body

    @staticmethod
    def decode(body, hd):
        ct = ((hd or {}).get("Content-Type") or "").lower()
        if "gb" in ct:
            return body.decode("gb18030", "replace")
        head = body[:4096].lower()
        if b"gb2312" in head or b"gbk" in head or b"gb18030" in head:
            return body.decode("gb18030", "replace")
        try:
            return body.decode("utf-8")
        except Exception:
            return body.decode("gb18030", "replace")

    @staticmethod
    def _solve_challenge(html):
        m = re.search(r'var\s+reversed\s*=\s*"([^"]+)"', html)
        if not m:
            return None
        import base64
        s = m.group(1)[::-1]
        s += "=" * (-len(s) % 4)
        try:
            code = base64.b64decode(s).decode("utf-8", "replace")
        except Exception:
            return None
        t = re.search(r"var\s+token\s*=\s*'([^']*)'", code)
        return t.group(1) if t else None

    def get(self, url, data=None, headers=None, method=None, tries=4, sleep=6.0, ua=None):
        """返回 (status, headers, text)。自动处理 429(换 UA 重试) 与 51.LA 挑战。"""
        last = (None, {"err": "no attempt"}, b"")
        cur_ua = ua
        for attempt in range(tries + 1):
            st, hd, body = self._raw(url, data=data, headers=headers, method=method, ua=cur_ua)
            if st is None:
                last = (st, hd, body)
                time.sleep(sleep)
                continue
            txt = self.decode(body, hd)
            if st == 429 or "请求过于频繁" in txt:
                last = (st, hd, body)
                alt = [u for u in UA_ROTATION if u != (cur_ua or self.ua)]
                cur_ua = alt[0] if alt else cur_ua
                time.sleep(sleep * (attempt + 1))
                continue
            tok = self._solve_challenge(txt)
            if tok is not None:
                self.challenges += 1
                host = urllib.parse.urlparse(url).hostname
                self.cj.set_cookie(http.cookiejar.Cookie(
                    0, "__51guid__", tok, None, False, host, False, True,
                    "/", True, False, None, True, None, None, {}))
                continue
            return st, hd, txt
        return last[0], last[1], self.decode(last[2], last[1])


def clean(s):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", s)).strip()


def book_items(html):
    out = []
    for m in re.finditer(r'<dt class="list-book-dt">(.*?)</dt>', html, re.S):
        blk = m.group(1)
        a = re.search(r'<a\s+href="(/youshengxiaoshuo/(\d+)/)"[^>]*>([^<]+)</a>', blk)
        if a:
            out.append((a.group(2), clean(a.group(3)), a.group(1)))
    if not out:
        for m in re.finditer(r'<a\s+class="thumb"\s*href="(/youshengxiaoshuo/(\d+)/)"\s*title="([^"]*)"', html):
            out.append((m.group(2), clean(m.group(3)).replace("有声小说", ""), m.group(1)))
    return out


# --------------------------------------------------------------------------
# 步骤
# --------------------------------------------------------------------------
def step1_nav(c):
    st, hd, html = c.get(SITE + "/")
    cats = []
    seen = set()
    for m in re.finditer(r'<a\s+href="(/yousheng/[^"]+)"[^>]*>([^<]{1,20})</a>', html):
        href, name = m.group(1), clean(m.group(2))
        if not name or href in seen or "/lastupdate" not in href:
            continue
        seen.add(href)
        cats.append((name, href))
    if st == 200 and len(cats) >= 5:
        names = ", ".join(n for n, _ in cats[:8])
        return True, "导航 %d 个分类入口 (%s ...)  HTTP %s" % (len(cats), names, st)
    return False, "HTTP %s, 只解析到 %d 个分类入口" % (st, len(cats))


def step2_category(c):
    st, hd, html = c.get(SITE + CATEGORY)
    if st != 200:
        return False, "HTTP %s" % st, None
    cnt = re.search(r'共\s*<[^>]*>\s*(\d+)\s*<[^>]*>\s*本', html)
    pages = re.search(r'共\s*<span[^>]*>\s*(\d+)\s*</span>\s*页', html)
    items = book_items(html)
    if not items:
        return False, "分类页解析不到书籍条目", None
    bid, title, url = items[0]
    return True, "共 %s 本 / %s 页, 本页 %d 条, 第一本《%s》 %s" % (
        cnt.group(1) if cnt else "?", pages.group(1) if pages else "?", len(items), title, url), (bid, title, url)


def step3_search(c):
    data = urllib.parse.urlencode({"searchword": SEARCH_WORD}).encode("utf-8")
    st, hd, html = c.get(SITE + "/novelsearch/search/result.html", data=data,
                         headers={"Content-Type": "application/x-www-form-urlencoded",
                                  "Referer": SITE + "/"})
    if st != 200:
        return False, "HTTP %s" % st, None
    items = book_items(html)
    pages = re.search(r'共\s*<span[^>]*>\s*(\d+)\s*</span>\s*页', html)
    if not items:
        return False, "搜索无结果条目", None
    bid, title, url = items[0]
    return True, "「%s」第1页命中 %d 条 / 共 %s 页; 第一条《%s》 %s%s" % (
        SEARCH_WORD, len(items), pages.group(1) if pages else "?", title, SITE, url), (bid, title, url)


def step4_detail(c, bookid):
    url = "%s/youshengxiaoshuo/%d/" % (SITE, bookid)
    st, hd, html = c.get(url)
    if st != 200:
        return False, "HTTP %s" % st, None
    h1 = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.S)
    title = clean(h1.group(1)) if h1 else ""
    title = re.sub(r"有声小说$", "", title)
    au = re.search(r'作者[：:]\s*</span>\s*<a[^>]*>([^<]+)</a>', html) or \
         re.search(r'作者[：:]\s*<a[^>]*>([^<]+)</a>', html)
    by = re.search(r'(?:演播|播讲)[：:]\s*</span>\s*<a[^>]*>([^<]+)</a>', html) or \
         re.search(r'(?:演播|播讲)[：:]\s*<a[^>]*>([^<]+)</a>', html)
    cv = re.search(r'<img[^>]*src="(https?://image\.[^"]+\.(?:gif|jpg|jpeg|png|webp))"', html)
    if not cv:
        cv = re.search(r'<meta\s+property="og:image"\s*content="([^"]+)"', html)
    author = clean(au.group(1)) if au else ""
    boyin = clean(by.group(1)) if by else ""
    cover = cv.group(1) if cv else ""
    if title and author and boyin and cover:
        return True, "《%s》 作者:%s 播音:%s 封面:%s  %s" % (title, author, boyin, cover, url), html
    return False, "解析不完整 title=%r author=%r boyin=%r cover=%r" % (title, author, boyin, cover), html


def step5_chapters(c, bookid):
    # 总集数「总N集」只出现在手机版书籍页 -> 用 m. 站点拿
    st_m, hd_m, htm = c.get("%s/youshengxiaoshuo/%d/" % (SITE_M, bookid))
    total = None
    dirurl = None
    if st_m == 200:
        t = re.search(r'(?:共|总)\s*(?:<[^>]*>)?\s*(\d+)\s*(?:</[^>]*>)?\s*集', htm)
        if t:
            total = t.group(1)
        m = re.search(r'href="(/(?:tingdirs)/[^"]+\.html)"', htm)
        if m:
            dirurl = m.group(1)
    if not dirurl:
        return False, "书籍页找不到「全部章节」目录链接 (m 站 HTTP %s)" % st_m, None
    # 目录页固定用桌面 UA (手机 UA 会被 429)
    st, hd, dh = c.get(SITE + dirurl, ua=UA)
    if st != 200:
        st, hd, dh = c.get(SITE_M + dirurl, ua=UA)
    if st != 200:
        return False, "章节目录 HTTP %s" % st, None
    i = dh.find('id="playlist"')
    seg = dh[i:] if i >= 0 else dh
    chaps = re.findall(r"<a[^>]*href=['\"](/play/\d+_\d+_\d+\.html)['\"][^>]*>(.*?)</a>", seg, re.S)
    if not chaps:
        return False, "章节目录解析不到章节", None
    first_title = clean(chaps[0][1])
    rng = re.search(r'<li class="chapter-item[^"]*"><a href="javascript:;">(\d+)~(\d+)</a></li>', dh)
    per = ("%s/页" % (int(rng.group(2)) - int(rng.group(1)) + 1)) if rng else "?"
    if not total:
        return False, "拿不到总集数", None
    return True, "共 %s 章(每页 %s), 目录第1页 %d 条; 第一章《%s》 %s%s" % (
        total, per, len(chaps), first_title, SITE, chaps[0][0]), (chaps[0][0], first_title, total)


def step6_audio(c, play_url, tries=5):
    """取音频直链。

    站方 /api/mapi/play 有突发限流: 命中时返回 HTTP 200 但 status=404/405,
    并给一个 **随机诱饵** m4a 地址(url 字段不能信)。所以每次重试都重新拉播放页,
    用新的 <meta name="_c"> 随机数重新签名。
    """
    last = "未执行"
    for attempt in range(tries):
        st, hd, html = c.get(play_url, ua=UA)
        if st != 200:
            last = "播放页 HTTP %s" % st
            time.sleep(4)
            continue
        meta = dict((m.group(1), m.group(2)) for m in
                    re.finditer(r'<meta\s+name="(_[a-z])"\s*content="([^"]*)"', html))
        if not meta.get("_c") or not meta.get("_b") or not meta.get("_p"):
            last = "播放页缺少 _b/_p/_c meta (被下发了空壳页)"
            time.sleep(4)
            continue

        sc = meta["_c"]
        data = urllib.parse.urlencode({"nid": meta["_b"], "cid": meta["_p"],
                                       "sort": meta.get("_d") or "read"}).encode("utf-8")
        st2, hd2, body = c.get(SITE + "/api/mapi/play", data=data, headers={
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "X-Requested-With": "XMLHttpRequest",
            "Referer": play_url,
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "sc": sc,
            "sp": make_sp(sc),
        }, ua=UA)
        try:
            j = json.loads(body)
        except Exception:
            last = "音频接口非 JSON: %s" % body[:160]
            time.sleep(4)
            continue
        if j.get("status") != 200 or not j.get("url"):
            last = "第%d次: 接口 status=%s msg=%s (诱饵 url=%s)" % (
                attempt + 1, j.get("status"), j.get("msg"), str(j.get("url"))[:70])
            time.sleep(5)
            continue

        url = j["url"]
        # ting13 的 CDN 走 http 即可; 若给了 https 也一并试
        cands = [url]
        if url.startswith("https://"):
            cands.insert(0, "http://" + url[len("https://"):])
        for cand in cands:
            safe = urllib.parse.quote(cand, safe=":/?&=%-._~")
            st3, hd3, blob = c.get(safe, headers={"Range": "bytes=0-1024", "Accept": "*/*",
                                                  "Referer": SITE + "/"}, ua=UA)
            if st3 is None:
                last = "请求异常 %s" % hd3.get("err")
                continue
            ct = (hd3.get("Content-Type") or "").lower()
            last = "HTTP %s Content-Type=%s Content-Range=%s" % (st3, ct, hd3.get("Content-Range"))
            if st3 in (200, 206) and any(a in ct for a in AUDIO_TYPES):
                return True, "章节《%s》 HTTP %s  Content-Type: %s  Content-Range: %s  " \
                             "取回 %d 字节  %s" % (j.get("name"), st3, ct,
                                                  hd3.get("Content-Range"), len(blob), cand[:100]), cand
        time.sleep(4)
    return False, "音频直链校验失败: %s" % last, None


# --------------------------------------------------------------------------
def report(no, name, ok, detail):
    tag = "[OK]  " if ok else "[FAIL]"
    print("%s %s %s" % (tag, no, name))
    print("        %s" % detail)
    RESULTS.append(ok)
    time.sleep(2.0)


def main():
    print("=" * 78)
    print("13听书网 ting13 数据链路自检   %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
    print("=" * 78)
    c = Client()

    try:
        ok, d = step1_nav(c)
    except Exception as e:
        ok, d = False, "异常 %r" % (e,)
    report("①", "分类/发现导航      ", ok, d)

    cand = []
    try:
        ok, d, got = step2_category(c)
        if got:
            cand.append(int(got[0]))
    except Exception as e:
        ok, d = False, "异常 %r" % (e,)
    report("②", "分类列表(第1页)    ", ok, d)

    try:
        ok, d, got = step3_search(c)
        if got:
            cand.insert(0, int(got[0]))
    except Exception as e:
        ok, d = False, "异常 %r" % (e,)
    report("③", "搜索「%s」       " % SEARCH_WORD, ok, d)

    order = []
    for b in cand + [DEMO_BOOK]:
        if b not in order:
            order.append(b)
    ok4, d4, bookid = False, "所有候选书目详情都解析失败", DEMO_BOOK
    for bid in order:
        try:
            ok4, d4, _ = step4_detail(c, bid)
        except Exception as e:
            ok4, d4 = False, "异常 %r" % (e,)
        if ok4:
            bookid = bid
            break
    report("④", "书籍详情           ", ok4, d4 + "  [bookid=%d]" % bookid)

    chap = None
    try:
        ok5, d5, chap = step5_chapters(c, bookid)
    except Exception as e:
        ok5, d5, chap = False, "异常 %r" % (e,), None
    report("⑤", "章节列表           ", ok5, d5)

    try:
        if chap:
            ok6, d6, _ = step6_audio(c, SITE + chap[0])
        else:
            ok6, d6 = False, "上一步没有拿到章节链接"
    except Exception as e:
        ok6, d6 = False, "异常 %r" % (e,)
    report("⑥", "音频直链(Range)    ", ok6, d6)

    print("-" * 78)
    n_ok = sum(1 for x in RESULTS if x)
    print("结果: %d/%d 通过   51.LA 挑战解出 %d 次" % (n_ok, len(RESULTS), c.challenges))
    return 0 if n_ok == len(RESULTS) else 1


if __name__ == "__main__":
    sys.exit(main())
