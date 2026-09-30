#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
恋听网 (ting55) 数据链路自检脚本 —— 仅使用 Python 标准库
================================================================
站点入口：https://m.ting55.com  （手机版；ting55.com 是同一套模板）

依次验证并打印 [OK] / [FAIL]：
  ① 分类 / 发现导航
  ② 分类列表（第一页：共多少本、第一本标题）
  ③ 搜索「三体」（命中数 + 第一条标题/链接）
  ④ 书籍详情（标题/作者/播音/封面）
  ⑤ 章节列表（共多少章、第一章标题）
  ⑥ 音频直链（Range: bytes=0-1024 -> 200/206 且 Content-Type 为音频）

运行：
  C:\\Users\\Administrator\\AppData\\Local\\Python\\bin\\python.exe ting55_verify.py

设计要点（都是实测踩出来的，详见同目录 ting55.md）：
  * 站点整体是 UTF-8（meta 与 Content-Type 都写 UTF-8），
    解码顺序：响应头 charset -> HTML meta charset -> utf-8 -> gb18030 兜底。
  * 站点 TLS 极不稳定，会随机抛 SSLEOFError，所有请求必须带重试。
  * 章节音频地址不在 HTML 里，必须 POST /glink 拿 JSON。
  * /glink 有 IP 级频控，过快会返回 {"status":-2}，要节流 + 退避。
  * 音源有 3 个域名，其中 pp.ting55.com 是阿里云国内 CDN，
    海外出口访问会被「统一接入」网关直接 404；audio.xmcdn.com（喜马拉雅 CDN）
    与 wting.info 是第三方源。因此 ⑥ 内置了候选书回退。
"""

import sys
import os
import re
import ssl
import json
import time
import gzip
import secrets
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------- 基础配置

BASE = "https://m.ting55.com"
HOME = BASE + "/"
REFERER = BASE + "/"

UA = ("Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36")

# 主用书（详情/章节/音频首选）；其余为音频候选回退
PRIMARY_BOOK = "14884"          # 我的恐怖直播间，第1集音源在 audio.xmcdn.com
AUDIO_BOOK_CANDIDATES = ["14884", "14929", "14823", "14933", "14922"]

SEARCH_KEYWORD = "三体"
CATEGORY_ID = "1"               # 玄幻

TIMEOUT = 25
RETRIES = 6
GLINK_MIN_INTERVAL = 1.5        # /glink 最小调用间隔（秒），规避频控

AUDIO_CT_OK = ("audio/mpeg", "audio/mp4", "audio/x-m4a", "m4a")

# ---------------------------------------------------------------- 输出工具

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def _supports_color():
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR"):
        return True
    try:
        return sys.stdout.isatty()
    except Exception:
        return False


class C:
    OK = "\033[32m" if _supports_color() else ""
    NO = "\033[31m" if _supports_color() else ""
    DI = "\033[36m" if _supports_color() else ""
    Z = "\033[0m" if _supports_color() else ""


def head(n, title):
    print("\n" + "=" * 70)
    print("%s) %s" % (n, title))
    print("=" * 70)


def ok(msg):
    print("  %s[OK]%s %s" % (C.OK, C.Z, msg))


def fail(msg):
    print("  %s[FAIL]%s %s" % (C.NO, C.Z, msg))


def info(msg):
    print("  %s->%s %s" % (C.DI, C.Z, msg))


# ---------------------------------------------------------------- HTTP 层

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def http(url, data=None, headers=None, referer=REFERER, tries=RETRIES, timeout=TIMEOUT):
    """带重试的请求。返回 (status, headers_dict, raw_bytes, final_url)。

    站点 TLS 会随机 EOF，且 /glink 会频控，所以这里对
    连接类异常与 5xx 都做指数退避重试。
    """
    hdr = {
        "User-Agent": UA,
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Accept-Encoding": "gzip",
        "Connection": "close",
    }
    if referer:
        hdr["Referer"] = referer
    if data is not None:
        hdr.setdefault("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
    if headers:
        hdr.update(headers)

    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, data=data, headers=hdr)
            with urllib.request.urlopen(req, timeout=timeout, context=_CTX) as resp:
                raw = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    try:
                        raw = gzip.decompress(raw)
                    except Exception:
                        pass
                return resp.status, dict(resp.headers), raw, resp.geturl()
        except urllib.error.HTTPError as e:
            body = b""
            try:
                body = e.read()
            except Exception:
                pass
            # 4xx 不重试（除 429），5xx 重试
            if e.code < 500 and e.code != 429:
                return e.code, dict(e.headers), body, e.url
            last = e
        except Exception as e:
            last = e
        time.sleep(min(0.6 * (i + 1), 4.0))
    raise last if last else RuntimeError("request failed: %s" % url)


def decode_body(raw, ctype=""):
    """按 响应头 charset -> meta charset -> utf-8 -> gb18030 兜底 解码。"""
    encs = []
    m = re.search(r"charset=([\w\-]+)", ctype or "", re.I)
    if m:
        encs.append(m.group(1))
    head_txt = raw[:4096].decode("latin-1", "ignore")
    m = re.search(r'<meta[^>]+charset=["\']?([\w\-]+)', head_txt, re.I)
    if m:
        encs.append(m.group(1))
    encs += ["utf-8", "gb18030"]
    seen = set()
    for enc in encs:
        enc = enc.lower()
        if enc in seen:
            continue
        seen.add(enc)
        try:
            return raw.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return raw.decode("utf-8", "replace")


def get_html(url, referer=REFERER):
    """返回 (status, decoded_html, raw_bytes, content_type)。"""
    st, hd, raw, fin = http(url, referer=referer)
    ctype = hd.get("Content-Type", "")
    return st, decode_body(raw, ctype), raw, ctype


def strip_tags(s):
    return re.sub(r"<[^>]+>", "", s).strip()


def abs_url(u):
    if not u:
        return u
    if u.startswith("//"):
        return "https:" + u
    if u.startswith("/"):
        return BASE + u
    return u


# ---------------------------------------------------------------- 解析工具

def parse_categories(html):
    """导航分类：<nav class="nav clear"> 内的 /category/N 链接。"""
    m = re.search(r'<nav class="nav clear">(.*?)</nav>', html, re.S)
    seg = m.group(1) if m else html
    out = []
    for href, name in re.findall(r'<a[^>]*href="(/category/\d+)"[^>]*>([^<]+)</a>', seg):
        out.append((href, name.strip()))
    return out


def parse_book_list(html):
    """分类页/搜索页的书本列表：<div class="clist|slist"> 内 <a href=/book/N> ... <h3>。"""
    m = re.search(r'<div class="(?:clist|slist)">(.*?)</div>\s*(?:<div class="cpage"|</section>)',
                  html, re.S)
    seg = m.group(1) if m else html
    items = []
    for href, bid, t in re.findall(r'<a href="(/book/(\d+))".*?<h3[^>]*>(.*?)</h3>', seg, re.S):
        items.append({"url": href, "id": bid, "title": strip_tags(t)})
    return items


def parse_pager(html):
    m = re.search(r'页次\s*(\d+)\s*/\s*(\d+)', html)
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def parse_book_detail(html):
    d = {}
    m = re.search(r'<div class="bimg">.*?<img[^>]*src="([^"]+)"', html, re.S)
    d["cover"] = abs_url(m.group(1)) if m else None
    m = re.search(r'<h1>(.*?)</h1>', html, re.S)
    d["title"] = strip_tags(m.group(1)) if m else None

    info_seg = ""
    m = re.search(r'<div class="binfo">(.*?)</div>', html, re.S)
    if m:
        info_seg = m.group(1)

    def field(label):
        mm = re.search(r'<p>\s*%s[：:]\s*(.*?)</p>' % label, info_seg, re.S)
        return strip_tags(mm.group(1)) if mm else None

    d["type"] = field("类型")
    d["author"] = field("作者")
    # 播音有两种写法：<a class="by"> 或 <span class="bys">
    mm = re.search(r'<p>\s*播音[：:]\s*(.*?)</p>', info_seg, re.S)
    if mm:
        names = re.findall(r'<(?:a|span)[^>]*class="by[s]?"[^>]*>(.*?)</(?:a|span)>', mm.group(1), re.S)
        d["announcer"] = " ".join(strip_tags(n) for n in names) if names else strip_tags(mm.group(1))
    else:
        d["announcer"] = None
    d["status"] = field("状态")
    d["update"] = field("时间")

    m = re.search(r'<h2>\s*分集收听\s*[（(]\s*共\s*(\d+)\s*[集章]', html)
    d["chapter_count_header"] = int(m.group(1)) if m else None

    m = re.search(r'<div class="plist">(.*?)</div>', html, re.S)
    chapters = []
    if m:
        for href, txt in re.findall(r'<a[^>]*href="(/book/\d+-\d+)"[^>]*>(.*?)</a>', m.group(1), re.S):
            chapters.append({"url": href, "title": strip_tags(txt)})
    d["chapters"] = chapters
    return d


def parse_metas(html):
    """分集页 <meta name="_x" content="..."> —— /glink 需要 _c 与 _h。"""
    return dict(re.findall(r'<meta name="(_[a-z]+)"\s+content="([^"]*)"', html))


# ---------------------------------------------------------------- /glink

_last_glink = [0.0]


def glink(book_id, page=1, episode_html=None):
    """POST /glink -> 音频地址 JSON。

    返回 dict：{"status":1,"url":...,"ourl":...,"title":...}
    status: 1 正常；-1 收费需登录；-2 访问过快（IP 频控，约 1 小时）
    """
    if episode_html is None:
        _, episode_html, _, _ = get_html("%s/book/%s-%s" % (BASE, book_id, page),
                                         referer=REFERER)

    metas = parse_metas(episode_html)
    xt = metas.get("_c", "")
    is_pay = metas.get("_h", "0")
    if not xt:
        raise RuntimeError("分集页缺少 <meta name='_c'>，book=%s page=%s" % (book_id, page))

    # 节流：/glink 有频控，自己先限速（对站点友好）
    wait = GLINK_MIN_INTERVAL - (time.time() - _last_glink[0])
    if wait > 0:
        time.sleep(wait)

    form = urllib.parse.urlencode({
        "bookId": str(book_id),
        "isPay": str(is_pay),
        "page": str(page),
    }).encode()

    ep_url = "%s/book/%s-%s" % (BASE, book_id, page)
    st, hd, raw, fin = http(
        BASE + "/glink",
        data=form,
        referer=ep_url,
        headers={
            "X-Requested-With": "XMLHttpRequest",
            "Origin": BASE,
            "xt": xt,
            "Accept": "application/json, text/javascript, */*; q=0.01",
            # 站点会下发 mhting55 作为访客会话标记，频控按这个 cookie 计数。
            # 不携带 cookie 时会退化成 IP 计数（共享 IP 很容易被误封）。
            # 这里模拟浏览器「每次新会话」的行为，随机一个 mhting55。
            "Cookie": "mhting55=" + secrets.token_hex(8),
        },
    )
    _last_glink[0] = time.time()

    txt = decode_body(raw, hd.get("Content-Type", "")).strip()
    try:
        data = json.loads(txt)
    except Exception:
        raise RuntimeError("/glink 返回非 JSON（HTTP %s）：%s" % (st, txt[:200]))

    data["_metas"] = metas
    data["_episode_url"] = ep_url
    return data


def glink_with_backoff(book_id, page=1, attempts=3):
    """/glink 频控(status -2)时退避重试。"""
    delay = 15
    last = None
    for i in range(attempts):
        last = glink(book_id, page)
        if last.get("status") != -2:
            return last
        if i < attempts - 1:
            info("/glink 被频控(status=-2)，%ds 后重试 (%d/%d)" % (delay, i + 1, attempts - 1))
            time.sleep(delay)
            delay = min(delay * 2, 60)
    return last


def audio_range_check(audio_url, referer):
    """Range: bytes=0-1024 校验音频直链。"""
    st, hd, raw, fin = http(
        audio_url,
        referer=referer,
        tries=3,
        headers={"Range": "bytes=0-1024", "Accept": "*/*"},
    )
    ct = (hd.get("Content-Type") or "").lower()
    return st, ct, raw, fin, hd


# ---------------------------------------------------------------- 主流程

def main():
    results = {}

    print("恋听网 (ting55) 数据链路自检")
    print("入口: %s" % HOME)
    print("UA  : %s" % UA)

    # ---------------------------------------------------------- ① 导航
    head(1, "分类 / 发现导航")
    try:
        st, html, raw, ctype = get_html(HOME)
        info("GET %s -> HTTP %s, %d bytes, Content-Type: %s"
             % (HOME, st, len(raw), ctype or "(无)"))
        cats = parse_categories(html)
        books = parse_book_list(html)
        if st == 200 and cats:
            ok("发现 %d 个分类导航，首页推荐位 %d 本书" % (len(cats), len(books)))
            info("分类: " + "、".join("%s%s" % (n, h) for h, n in cats[:6]) + " ...")
            results["1"] = True
        else:
            fail("首页无分类导航（HTTP %s, categories=%d）" % (st, len(cats)))
            results["1"] = False
    except Exception as e:
        fail("首页请求失败: %s: %s" % (type(e).__name__, e))
        results["1"] = False

    # ---------------------------------------------------------- ② 分类列表
    head(2, "分类列表（第一页）")
    cat_url = "%s/category/%s" % (BASE, CATEGORY_ID)
    try:
        st, html, raw, ctype = get_html(cat_url)
        items = parse_book_list(html)
        cur, total = parse_pager(html)
        h1 = re.search(r'<section class="category">\s*<h1>(.*?)</h1>', html, re.S)
        cat_name = strip_tags(h1.group(1)) if h1 else "?"
        if st == 200 and items:
            ok("GET %s -> HTTP %s" % (cat_url, st))
            info("分类名: %s    本页共 %d 本" % (cat_name, len(items)))
            info("第一本: %s  %s" % (items[0]["title"], BASE + items[0]["url"]))
            info("翻页: 第 %s/%s 页，模板 %s/category/%s/page/{n}"
                 % (cur, total, BASE, CATEGORY_ID))
            results["2"] = True
        else:
            fail("分类页解析失败（HTTP %s, items=%d）" % (st, len(items)))
            results["2"] = False
    except Exception as e:
        fail("分类页请求失败: %s: %s" % (type(e).__name__, e))
        results["2"] = False

    # ---------------------------------------------------------- ③ 搜索
    head(3, "搜索「%s」" % SEARCH_KEYWORD)
    q = urllib.parse.quote(SEARCH_KEYWORD)
    search_url = "%s/search/%s" % (BASE, q)
    try:
        st, html, raw, ctype = get_html(search_url, referer=HOME)
        hits = parse_book_list(html)
        if st == 200 and hits:
            ok("GET %s -> HTTP %s" % (search_url, st))
            info("命中 %d 条" % len(hits))
            info("第一条: %s  %s" % (hits[0]["title"], BASE + hits[0]["url"]))
            results["3"] = True
        else:
            fail("搜索无结果（HTTP %s, hits=%d）" % (st, len(hits)))
            results["3"] = False
    except Exception as e:
        fail("搜索请求失败: %s: %s" % (type(e).__name__, e))
        results["3"] = False

    # ---------------------------------------------------------- ④ 详情
    head(4, "书籍详情 /book/%s" % PRIMARY_BOOK)
    detail = None
    detail_url = "%s/book/%s" % (BASE, PRIMARY_BOOK)
    try:
        st, html, raw, ctype = get_html(detail_url)
        detail = parse_book_detail(html)
        if st == 200 and detail.get("title"):
            ok("GET %s -> HTTP %s" % (detail_url, st))
            info("标题: %s" % detail["title"])
            info("作者: %s" % detail["author"])
            info("播音: %s" % detail["announcer"])
            info("类型: %s   状态: %s" % (detail["type"], detail["status"]))
            info("封面: %s" % detail["cover"])
            results["4"] = bool(detail["cover"])
            if not detail["cover"]:
                fail("未解析到封面")
        else:
            fail("详情页解析失败（HTTP %s）" % st)
            results["4"] = False
    except Exception as e:
        fail("详情页请求失败: %s: %s" % (type(e).__name__, e))
        results["4"] = False

    # ---------------------------------------------------------- ⑤ 章节列表
    head(5, "章节列表")
    try:
        if detail is None:
            raise RuntimeError("详情页不可用，跳过")
        chapters = detail["chapters"]
        n_header = detail["chapter_count_header"]
        if chapters:
            ok("共 %d 章（页面标注：共 %s 集）"
               % (len(chapters), n_header if n_header is not None else "?"))
            info("第一章: %s  %s"
                 % (chapters[0]["title"], BASE + chapters[0]["url"]))
            info("末一章: %s  %s"
                 % (chapters[-1]["title"], BASE + chapters[-1]["url"]))
            results["5"] = True
        else:
            fail("未解析到章节（plist 为空）")
            results["5"] = False
    except Exception as e:
        fail("章节列表失败: %s: %s" % (type(e).__name__, e))
        results["5"] = False

    # ---------------------------------------------------------- ⑥ 音频直链
    head(6, "音频直链（Range: bytes=0-1024）")
    try:
        used_book = None
        last_err = ""
        payload = None

        # 主用书优先，失败则回退候选书；整轮跑两遍（站点 TLS 抖动很大，值得再来一次）
        order = [PRIMARY_BOOK] + [b for b in AUDIO_BOOK_CANDIDATES if b != PRIMARY_BOOK]
        banned = False
        for rnd in (1, 2):
            if payload or banned:
                break
            if rnd == 2:
                info("第 1 轮未取到可用音源，重试一轮候选书…")
            for book_id in order:
                ep_url = "%s/book/%s-1" % (BASE, book_id)
                try:
                    _, ep_html, _, _ = get_html(ep_url, referer=detail_url)
                    j = glink_with_backoff(book_id, 1)
                except Exception as e:
                    last_err = "%s: %s" % (type(e).__name__, e)
                    info("book %s 取音频地址失败：%s" % (book_id, last_err))
                    continue

                status = j.get("status")
                if status == -2:
                    last_err = ("/glink 频控(status=-2)：%s"
                                % (j.get("_msg") or "您访问过快！请1小时后用推荐浏览器收听！"))
                    info(last_err)
                    info("频控按 mhting55 cookie 分桶，不带 cookie 会退化成 IP 计数。")
                    banned = True
                    break
                if status == -1:
                    last_err = "book %s 为收费章节(status=-1)，需登录" % book_id
                    info(last_err)
                    continue

                aurl = j.get("ourl") or j.get("url") or ""
                # title 是 percent-encoded，且 '+' 代表空格
                title = urllib.parse.unquote_plus(j.get("title") or "")
                if not aurl:
                    last_err = "book %s /glink 未返回 url" % book_id
                    info(last_err)
                    continue

                info("book %s 第1集 → %s" % (book_id, aurl))
                if title:
                    info("第1集标题(URL编码字段已解码): %s" % title)

                try:
                    ast, act, araw, afin, ahd = audio_range_check(aurl, ep_url)
                except Exception as e:
                    last_err = "book %s Range 请求异常: %s: %s" % (book_id, type(e).__name__, e)
                    info(last_err)
                    continue

                host = urllib.parse.urlparse(aurl).netloc
                info("Range 响应: HTTP %s, Content-Type=%s, Content-Range=%s"
                     % (ast, act or "(无)", ahd.get("Content-Range") or "(无)"))

                ct_ok = any(k in act for k in AUDIO_CT_OK)
                if ast in (200, 206) and ct_ok:
                    used_book = book_id
                    payload = (aurl, ast, act, araw, ahd, host)
                break
            last_err = ("book %s 音源 %s 校验不通过（HTTP %s, CT=%s）"
                        % (book_id, host, ast, act or "无"))

        if payload:
            aurl, ast, act, araw, ahd, host = payload
            ok("音频直链可用（book %s，音源域名 %s）" % (used_book, host))
            info("URL: %s" % aurl)
            info("状态码: %s    Content-Type: %s    Content-Range: %s"
                 % (ast, act, ahd.get("Content-Range") or "(无)"))
            info("前 16 字节: %r" % araw[:16])
            results["6"] = True
        else:
            fail("所有候选书均未取到可用音频直链")
            if last_err:
                info("最后一次失败原因: %s" % last_err)
            info("提示：pp.ting55.com 是阿里云国内 CDN，海外出口会被网关 404；"
                 "audio.xmcdn.com / wting.info 为第三方源。")
            results["6"] = False
    except Exception as e:
        fail("音频直链校验异常: %s: %s" % (type(e).__name__, e))
        results["6"] = False

    # ---------------------------------------------------------- 汇总
    print("\n" + "=" * 70)
    names = {"1": "分类/发现导航", "2": "分类列表", "3": "搜索",
             "4": "书籍详情", "5": "章节列表", "6": "音频直链"}
    all_ok = True
    for k in "123456":
        v = results.get(k, False)
        all_ok = all_ok and v
        print("  %s  %s %s" % ("[OK]  " if v else "[FAIL]", k, names[k]))
    print("=" * 70)
    print("总结果: %s" % ("全部通过 ✔" if all_ok else "存在失败 ✘"))
    return 0 if all_ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n中断")
        sys.exit(130)
