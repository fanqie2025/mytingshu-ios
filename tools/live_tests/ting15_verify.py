#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
有听网 ting15.com 数据链路自检脚本
==================================
只用 Python 标准库，实测 6 条链路（全部无需登录 / 无需 Cookie / 无需 JS）：

  ① 分类发现导航  GET  https://www.ting15.com/                     -> nav.nav 里的分类链接
  ② 分类列表      GET  https://www.ting15.com/<cat>/               -> .category-list ul li
                       再取尾页 ?index<N>.html 算全站该分类总本数
  ③ 搜索          GET  https://www.ting15.com/?s=ting-search-wd-<kw>.html
  ④ 书籍详情      GET  https://www.ting15.com/<cat>/<id>.html      -> h1 / 作者 / 播音 / 封面
  ⑤ 章节列表      同 ④ 页面里的 .plist ul 全部 <a>                  （整本一次性给出，无分页）
  ⑥ 音频直链      GET  https://www.ting15.com/<cat>/<id>/0-<n>.html
                      读 <meta name="_b|_cp|_p">，
                  POST https://www.ting15.com/?s=api-getneoplay   （form: bookId/isPay/page）
                      拿 JSON 里的 url 字段，再对 CDN 发 Range: bytes=0-1024

站点是苹果 CMS(gxlcms) 系；PC 站是 UTF-8 的静态 HTML + 一个 JSON 播放接口。
**音频直链不需要 WebView 执行 JS**：页面里的 /lianting/n2.js 已经把接口地址、参数、
请求头原样写着，直接照抄即可（见文件末尾「逆向线索」）。

运行：
  C:\\Users\\Administrator\\AppData\\Local\\Python\\bin\\python.exe ting15_verify.py

退出码：0 = 6 项全过；1 = 有 FAIL。
"""

import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------- 基础配置

# 站点对 Android UA 会在 JS 里把 PC 页跳到 m.ting15.com；但那是客户端 JS，
# 用 curl/urllib 请求 PC 站不会跳，所以这里固定用 PC 站（HTML 结构比手机站好解析）。
UA_MOBILE = (
    "Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36"
)

BASE = "https://www.ting15.com"
MOBILE_BASE = "https://m.ting15.com"

SEARCH_KEYWORD = "三体"
# 允许的音频 Content-Type 片段（全小写子串比较）
AUDIO_CT = ("audio/mpeg", "audio/mp4", "audio/x-m4a", "m4a")

TIMEOUT = 30
RETRY = 3

OK_TAG = "[OK]"
FAIL_TAG = "[FAIL]"
WARN_TAG = "[--]"

results = []  # (步骤名, 是否通过, 摘要)


# ---------------------------------------------------------------- 输出工具

def log(tag, msg):
    print(f"{tag} {msg}")
    sys.stdout.flush()


def rule(title):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)
    sys.stdout.flush()


def record(step, ok, summary):
    results.append((step, ok, summary))


# ---------------------------------------------------------------- 编码工具

def decode_body(body, ctype=""):
    """站点页面全是 UTF-8；仍按中文站惯例做 gb18030 兜底。

    BOM 必须吃掉：/?s=api-getneoplay 返回的 JSON 带 UTF-8 BOM，
    直接 json.loads 会炸 'Unexpected UTF-8 BOM'。
    """
    if body[:3] == b"\xef\xbb\xbf":
        return body.decode("utf-8-sig", "replace")
    cl = ctype.lower()
    if "gbk" in cl or "gb2312" in cl:          # 响应头明说 GBK 就别猜了
        return body.decode("gb18030", "replace")
    try:
        return body.decode("utf-8")
    except UnicodeDecodeError:
        return body.decode("gb18030", "replace")


def decode_json(body):
    txt = decode_body(body)
    try:
        return json.loads(txt)
    except Exception:
        # 极端情况：无 BOM 但内容是 gb18030
        return json.loads(body.decode("gb18030", "replace"))


# ---------------------------------------------------------------- HTTP 工具

def normalize_url(url):
    """把音频直链规范成可以直接请求的形式。

    ★ 这里是全站最大的坑：/?s=api-getneoplay 返回的 url 字段**可能是两种形态**——
        a) 已百分号编码（纯 ASCII）：.../028-santi/%E7%AC%AC%E4%B8%80%E5%AD%A3/%E2%80%8B1.m4a
        b) 原样中文（非 ASCII）：    .../t010/15-无敌剑域-有声的紫襟/0001.m4a
    对 a) 再调 urllib.parse.quote() 会把 '%' 二次编码成 '%25' -> CDN 直接 404。
    所以规则是：纯 ASCII 就原样用，含非 ASCII 才编码。
    """
    if url.isascii():
        return url
    p = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit(
        (p.scheme, p.netloc, urllib.parse.quote(p.path), p.query, p.fragment)
    )


def _open(url, headers, data=None):
    req = urllib.request.Request(url, data=data, headers=headers)
    return urllib.request.urlopen(req, timeout=TIMEOUT)


def http_get(url, referer=BASE + "/", rng=None, max_bytes=None):
    """GET，返回 (status, headers_lower, body_bytes)。

    - 非 2xx 不抛异常，交给调用方判断；
    - max_bytes 用于音频 Range 探测：即使服务端忽略 Range 返回 200 全量，
      也只读前 max_bytes 字节，避免把几十 MB 拉进内存。
    """
    hdrs = {
        "User-Agent": UA_MOBILE,
        "Accept": "*/*",
        "Accept-Encoding": "identity",
        "Referer": referer,
    }
    if rng:
        hdrs["Range"] = rng
    url = normalize_url(url)
    last = None
    for attempt in range(RETRY):
        try:
            with _open(url, hdrs) as resp:
                body = resp.read(max_bytes) if max_bytes else resp.read()
                return resp.getcode(), {k.lower(): v for k, v in resp.headers.items()}, body
        except urllib.error.HTTPError as e:
            body = b""
            try:
                body = e.read(max_bytes) if max_bytes else e.read()
            except Exception:
                pass
            return e.code, {k.lower(): v for k, v in e.headers.items()}, body
        except Exception as e:  # noqa: BLE001 网络抖动重试
            last = e
            time.sleep(1.0 + attempt)
    raise last


def http_post_form(url, fields, referer):
    """POST application/x-www-form-urlencoded，返回 (status, headers, body)。"""
    data = urllib.parse.urlencode(fields).encode("utf-8")
    hdrs = {
        "User-Agent": UA_MOBILE,
        "Accept": "*/*",
        "Accept-Encoding": "identity",
        "Referer": referer,
        "X-Requested-With": "XMLHttpRequest",
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
    }
    last = None
    for attempt in range(RETRY):
        try:
            with _open(url, hdrs, data=data) as resp:
                return resp.getcode(), {k.lower(): v for k, v in resp.headers.items()}, resp.read()
        except urllib.error.HTTPError as e:
            return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1.0 + attempt)
    raise last


# ---------------------------------------------------------------- HTML 解析
# 全部用正则，不依赖 bs4/lxml。选择器对应关系见 ting15.md。

RE_NAV_BLOCK = re.compile(r'<nav class="nav">(.*?)</nav>', re.S)
RE_NAV_A = re.compile(r'<a\s+href="([^"]+)"\s+title="([^"]*)"[^>]*>')
RE_CATLIST = re.compile(r'<div class="category-list">(.*?)</ul>', re.S)
RE_LI = re.compile(r'<li>(.*?)</li>', re.S)
RE_ITEM_TITLE = re.compile(r'<h4>\s*<a\s+href="([^"]+)"\s+title="([^"]*)"')
RE_ITEM_IMG = re.compile(r'<img[^>]*src="([^"]+)"')
RE_ITEM_FIELD = {
    "category": re.compile(r"<p>类别：([^<]*)</p>"),
    "author": re.compile(r"<p>作者：([^<]*)</p>"),
    "announcer": re.compile(r"<p>播音：([^<]*)</p>"),
    "status": re.compile(r"<p>状态：([^<]*)"),
    "time": re.compile(r"<p>时间：([^<]*)</p>"),
}
RE_PAGE_BLOCK = re.compile(r'<div class="c-page">(.*?)</div>', re.S)
RE_DATA_P = re.compile(r'data="p-(\d+)"')

RE_DETAIL_H1 = re.compile(r'<h1>([^<]*)</h1>')
RE_DETAIL_BYS = re.compile(r'<p>播音：<span class="bys">([^<]*)</span></p>')
RE_DETAIL_COVER = re.compile(r'<div class="bimg">\s*<img[^>]*src="([^"]+)"')
RE_DETAIL_TITLE = re.compile(r"<title>([^<]*)</title>")

RE_PLIST = re.compile(r'<div class="plist">(.*?)</ul>', re.S)
# 章节 <a> 有两种写法：免费集带 class="f"，其余不带；必须兼容
RE_CHAPTER = re.compile(r'<a[^>]*href="(/\w+/\d+/\d+-\d+\.html)"[^>]*>([^<]*)</a>')
RE_META = re.compile(r'<meta name="(_[a-z]+)" content="([^"]*)"')


def parse_nav(html):
    m = RE_NAV_BLOCK.search(html)
    if not m:
        return []
    out = []
    for href, title in RE_NAV_A.findall(m.group(1)):
        if href == "/":
            continue
        out.append((title, href))
    return out


def parse_items(html):
    """解析 .category-list 里的书籍条目（分类页 / 搜索页共用同一套 DOM）。"""
    m = RE_CATLIST.search(html)
    if not m:
        return []
    items = []
    for chunk in RE_LI.findall(m.group(1)):
        t = RE_ITEM_TITLE.search(chunk)
        if not t:
            continue
        item = {"href": t.group(1), "title": t.group(2)}
        img = RE_ITEM_IMG.search(chunk)
        item["cover"] = img.group(1) if img else ""
        for key, rx in RE_ITEM_FIELD.items():
            v = rx.search(chunk)
            item[key] = v.group(1).strip() if v else ""
        items.append(item)
    return items


def parse_last_page(html):
    """从分页条 data="p-N" 里取最大页码（尾页）。"""
    nums = []
    for blk in RE_PAGE_BLOCK.findall(html):
        nums += [int(x) for x in RE_DATA_P.findall(blk)]
    return max(nums) if nums else 1


def parse_detail(html):
    d = {}
    m = RE_DETAIL_TITLE.search(html)
    d["page_title"] = m.group(1) if m else ""
    m = RE_DETAIL_H1.search(html)
    d["title"] = m.group(1).strip() if m else ""
    m = RE_DETAIL_BYS.search(html)
    d["announcer"] = m.group(1).strip() if m else ""
    m = RE_ITEM_FIELD["author"].search(html)
    d["author"] = m.group(1).strip() if m else ""
    m = RE_ITEM_FIELD["category"].search(html)
    d["category"] = m.group(1).strip() if m else ""
    m = RE_ITEM_FIELD["status"].search(html)
    d["status"] = m.group(1).strip() if m else ""
    m = RE_DETAIL_COVER.search(html)
    d["cover"] = m.group(1) if m else ""
    return d


def parse_chapters(html):
    m = RE_PLIST.search(html)
    if not m:
        return []
    return [{"href": h, "title": t.strip()} for h, t in RE_CHAPTER.findall(m.group(1))]


def parse_play_meta(html):
    return dict(RE_META.findall(html))


# ---------------------------------------------------------------- 业务动作

def fetch(url, referer=BASE + "/"):
    status, hdrs, body = http_get(url, referer=referer)
    return status, hdrs, decode_body(body, hdrs.get("content-type", ""))


def get_audio_url(chapter_url):
    """走完整链路：章节页 -> meta -> POST api-getneoplay -> 音频直链。

    返回 (audio_url, info)。audio_url 为 None 时 info 里带失败原因。
    """
    status, hdrs, html = fetch(chapter_url)
    if status != 200:
        return None, {"stage": "chapter_page", "status": status}
    meta = parse_play_meta(html)
    book_id, page = meta.get("_b"), meta.get("_cp")
    if not book_id or not page:
        return None, {"stage": "meta", "status": status, "meta": meta}

    api = f"{BASE}/?s=api-getneoplay"
    st, ah, body = http_post_form(
        api, {"bookId": book_id, "isPay": meta.get("_p", "0"), "page": page}, referer=chapter_url
    )
    if st != 200:
        return None, {"stage": "api_http", "status": st}
    try:
        data = decode_json(body)
    except Exception as e:  # noqa: BLE001
        return None, {"stage": "api_json", "status": st, "err": str(e)[:80],
                      "raw": body[:120].decode("utf-8", "replace")}

    s = data.get("status")
    if s != 1:
        return None, {"stage": "api_status", "status": st, "api_status": s,
                      "note": {0: "章节不存在", -1: "本章收费/未授权"}.get(s, "未知")}
    url = data.get("url") or data.get("ourl")
    if not url:
        return None, {"stage": "api_empty", "status": st, "raw": data}
    url = normalize_url(url)
    return url, {"stage": "ok", "status": st, "meta": meta, "api_status": s,
                 "plink": data.get("plink", "")}


def probe_audio(audio_url, referer):
    """Range 探测：返回 (ok, note)。"""
    status, hdrs, body = http_get(audio_url, referer=referer, rng="bytes=0-1024", max_bytes=1025)
    ct = (hdrs.get("content-type") or "").lower()
    ok = status in (200, 206) and any(a in ct for a in AUDIO_CT)
    note = {
        "status": status,
        "content_type": ct,
        "content_range": hdrs.get("content-range", ""),
        "content_length": hdrs.get("content-length", ""),
        "magic": body[:12].hex(" "),
        "final_url": audio_url,
    }
    return ok, note


# ---------------------------------------------------------------- 主流程

def main():
    rule("有听网 ting15.com 数据链路自检")
    log("--", f"BASE = {BASE}   UA = Android 9/SM-S9280（手机 UA 但走 PC 站）")
    log("--", f"手机站 {MOBILE_BASE} 是另一套 HTML，但共用同一个播放 API（本脚本不依赖它）")

    # ---------------------------------------------------------- ① 分类/发现导航
    rule("① 分类/发现导航")
    nav, nav_html = [], ""
    try:
        st, hd, nav_html = fetch(BASE + "/")
        nav = parse_nav(nav_html)
        if st == 200 and len(nav) >= 5:
            log(OK_TAG, f"首页 HTTP {st}，发现 {len(nav)} 个分类：")
            for name, href in nav:
                log("   ", f"{name:<8} {BASE}{href}")
            record("① 分类导航", True, f"{len(nav)} 个分类")
        else:
            log(FAIL_TAG, f"首页 HTTP {st}，nav 解析到 {len(nav)} 个分类")
            record("① 分类导航", False, f"HTTP {st}, nav={len(nav)}")
    except Exception as e:  # noqa: BLE001
        log(FAIL_TAG, f"首页请求异常：{type(e).__name__}: {e}")
        record("① 分类导航", False, str(e)[:60])

    # ---------------------------------------------------------- ② 分类列表
    rule("② 分类列表（第一页）")
    cat_book = None
    if not nav:
        log(FAIL_TAG, "① 没拿到分类，跳过")
        record("② 分类列表", False, "无分类可测")
    else:
        cat_name, cat_path = nav[0]
        cat_url = BASE + cat_path
        try:
            st, hd, html = fetch(cat_url)
            items = parse_items(html)
            last = parse_last_page(html)
            per_page = len(items)
            total = per_page
            if last > 1 and per_page:
                _, _, last_html = fetch(f"{cat_url}index{last}.html")
                total = (last - 1) * per_page + len(parse_items(last_html))
            if st == 200 and items:
                cat_book = items[0]
                log(OK_TAG, f"分类「{cat_name}」 {cat_url}  HTTP {st}")
                log("   ", f"本页 {per_page} 本 / 共 {last} 页 -> 该分类合计 {total} 本")
                log("   ", f"第一本：{items[0]['title']}  {BASE}{items[0]['href']}")
                log("   ", f"        作者={items[0]['author']}  播音={items[0]['announcer']}"
                           f"  状态={items[0]['status']}")
                record("② 分类列表", True, f"{total} 本（{last} 页）")
            else:
                log(FAIL_TAG, f"分类页 HTTP {st}，解析到 {len(items)} 本")
                record("② 分类列表", False, f"HTTP {st}, items={len(items)}")
        except Exception as e:  # noqa: BLE001
            log(FAIL_TAG, f"分类页异常：{type(e).__name__}: {e}")
            record("② 分类列表", False, str(e)[:60])

    # ---------------------------------------------------------- ③ 搜索
    rule("③ 搜索")
    search_book = None
    search_url = ""
    kw = urllib.parse.quote(SEARCH_KEYWORD, safe="")
    search_url = f"{BASE}/?s=ting-search-wd-{kw}.html"
    try:
        st, hd, html = fetch(search_url, referer=BASE + "/")
        hits = parse_items(html)
        last = parse_last_page(html)
        if st == 200 and hits:
            search_book = hits[0]
            log(OK_TAG, f"搜索「{SEARCH_KEYWORD}」 {search_url}  HTTP {st}")
            log("   ", f"命中 {len(hits)} 条（本页）/ 共 {last} 页")
            log("   ", f"第一条：{hits[0]['title']}  {BASE}{hits[0]['href']}")
            log("   ", f"        作者={hits[0]['author']}  播音={hits[0]['announcer']}"
                       f"  封面={hits[0]['cover'][:70]}")
            record("③ 搜索", True, f"{len(hits)} 命中")
        else:
            log(FAIL_TAG, f"搜索页 HTTP {st}，解析到 {len(hits)} 条")
            record("③ 搜索", False, f"HTTP {st}, hits={len(hits)}")
    except Exception as e:  # noqa: BLE001
        log(FAIL_TAG, f"搜索异常：{type(e).__name__}: {e}")
        record("③ 搜索", False, str(e)[:60])

    # ---------------------------------------------------------- ④ 书籍详情
    rule("④ 书籍详情")
    detail_book = None
    detail_chapters = []
    if not search_book:
        log(FAIL_TAG, "③ 没拿到搜索结果，跳过")
        record("④ 书籍详情", False, "无搜索结果")
    else:
        book_url = BASE + search_book["href"]
        try:
            st, hd, html = fetch(book_url, referer=search_url)
            d = parse_detail(html)
            detail_chapters = parse_chapters(html)
            if st == 200 and d["title"]:
                detail_book = d
                detail_book["url"] = book_url
                detail_book["href"] = search_book["href"]
                log(OK_TAG, f"详情页 {book_url}  HTTP {st}")
                log("   ", f"标题：{d['title']}   （页面 title={d['page_title']}）")
                log("   ", f"作者：{d['author']}    播音：{d['announcer']}")
                log("   ", f"类别：{d['category']}  状态：{d['status']}")
                log("   ", f"封面：{d['cover']}")
                record("④ 书籍详情", True, d["title"])
            else:
                log(FAIL_TAG, f"详情页 HTTP {st}，标题={d['title']!r}")
                record("④ 书籍详情", False, f"HTTP {st}")
        except Exception as e:  # noqa: BLE001
            log(FAIL_TAG, f"详情异常：{type(e).__name__}: {e}")
            record("④ 书籍详情", False, str(e)[:60])

    # ---------------------------------------------------------- ⑤ 章节列表
    rule("⑤ 章节列表")
    if not detail_chapters:
        log(FAIL_TAG, "④ 没解析到章节，跳过")
        record("⑤ 章节列表", False, "无章节")
    else:
        free = detail_chapters
        log(OK_TAG, f"共 {len(free)} 章（整本一次性输出在 .plist，无分页）")
        log("   ", f"第一章：{free[0]['title']}  {BASE}{free[0]['href']}")
        log("   ", f"末一章：{free[-1]['title']}  {BASE}{free[-1]['href']}")
        record("⑤ 章节列表", True, f"{len(free)} 章")

    # ---------------------------------------------------------- ⑥ 音频直链
    rule("⑥ 音频直链（Range: bytes=0-1024）")
    # 候选顺序：③→④→⑤ 链路上的书先试，失败再退到 ② 的分类第一本兜底。
    # 需要兜底的真实原因：不少书只有前几集免费（三体仅 1-6 集，第 7 集起 api status=-1），
    # 章节页/文件偶尔也会被站方挪走，候选链能让脚本不因为单本书而整体 FAIL。
    candidates = []
    seen = set()
    if detail_chapters:
        for ch in detail_chapters[:2]:
            u = BASE + ch["href"]
            if u not in seen:
                seen.add(u)
                candidates.append(("搜索结果链", u))
    if cat_book:
        cat_path = cat_book["href"]           # /<cat>/<id>.html
        stem = cat_path[:-5]                  # /<cat>/<id>
        try:
            _, _, html = fetch(BASE + cat_path, referer=BASE + "/")
            for ch in parse_chapters(html)[:2]:
                u = BASE + ch["href"]
                if u not in seen:
                    seen.add(u)
                    candidates.append(("分类第一本", u))
        except Exception as e:  # noqa: BLE001
            log(WARN_TAG, f"兜底书章节页拉取失败：{type(e).__name__}: {e}")
        # 即使章节页失败也补一个按模板拼的 URL
        u = f"{BASE}{stem}/0-1.html"
        if u not in seen:
            seen.add(u)
            candidates.append(("分类第一本(模板)", u))

    if not candidates:
        log(FAIL_TAG, "没有可用章节，跳过")
        record("⑥ 音频直链", False, "无章节可测")
    else:
        tried = []
        got = None
        for src, ch_url in candidates:
            try:
                audio_url, info = get_audio_url(ch_url)
            except Exception as e:  # noqa: BLE001
                tried.append(f"{ch_url} -> {type(e).__name__}")
                continue
            if not audio_url:
                reason = info.get("note") or info.get("err") or info.get("stage")
                if info.get("stage") == "api_status":
                    reason = f"api status={info.get('api_status')}（{info.get('note')}）"
                tried.append(f"{ch_url} -> {reason}")
                continue
            ok, note = probe_audio(audio_url, referer=ch_url)
            if ok:
                got = (src, ch_url, audio_url, note)
                break
            tried.append(f"{ch_url} -> {note['status']} {note['content_type'] or '(无 CT)'}")
            if note["status"] in (200, 206):
                # 状态码对但 CT 不在白名单，也记下来
                tried[-1] += "  ← CT 不在白名单"

        for t in tried:
            log(WARN_TAG, f"跳过候选：{t}")

        if not got:
            log(FAIL_TAG, "所有候选都没有拿到可播放的音频直链")
            record("⑥ 音频直链", False, "全部候选失败")
        else:
            src, ch_url, audio_url, note = got
            cr = note["content_range"]
            m = re.search(r"/(\d+)\s*$", cr)
            size = f"{m.group(1)} bytes（Content-Range 总长）" if m else (
                f"{note['content_length']} bytes（服务端忽略 Range）")
            log(OK_TAG, f"来源：{src}  {ch_url}")
            log("   ", f"音频直链：{audio_url}")
            log("   ", f"Range 探测：HTTP {note['status']}  Content-Type: {note['content_type']}")
            log("   ", f"Content-Range: {cr or '(无，服务端未实现 Range)'}")
            log("   ", f"文件大小：{size}   前 12 字节 magic: {note['magic']}")
            log("   ", f"防盗链：该 CDN 不带 Referer 会返回 400/301，"
                       f"必须带 Referer: {BASE}/")
            record("⑥ 音频直链", True, f"{note['status']} {note['content_type']}")

    # ---------------------------------------------------------- 汇总
    rule("汇总")
    for step, ok, summary in results:
        log(OK_TAG if ok else FAIL_TAG, f"{step}  {summary}")
    passed = sum(1 for _, ok, _ in results if ok)
    total = len(results)
    print()
    if passed == total:
        log(OK_TAG, f"全部 {total} 项通过 ✔")
        return 0
    log(FAIL_TAG, f"{passed}/{total} 项通过")
    return 1


if __name__ == "__main__":
    # Windows 控制台默认 GBK，中文会炸/乱码；强制 stdout 用 UTF-8
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)

# ---------------------------------------------------------------- 逆向线索
# 1) 章节页只会渲染出一个空壳播放器：
#      <div class="player"></div>
#    真正的地址由 /lianting/n2.js 里这段 ajax 拿（原文）：
#      headers['xt'] = $("meta[name='_c']").attr("content");
#      headers['l']  = $("meta[name='_l']").attr("content");
#      $.ajax({ url: "/?s=api-getneoplay", type: "POST",
#               data: { 'bookId': b /*meta _b*/, 'isPay': p /*meta _p*/, 'page': g /*meta _cp*/ },
#               dataType: "json",
#               success: function(a){ if (a.status != -1) { var u = a.ourl; ... var c = a.url; ... } } });
#    实测：xt / l 两个头可有可无（传错值也照样返回）；bookId/isPay/page 三个 form 字段才是关键。
# 2) 章节页 <head> 里的 meta：_b=书 id、_cp=当前集号、_m=总集数、_p=是否付费、_f=mp3/m4a、
#    _l=1、_c=固定哈希 d2fa3fafe23091a1c3f8f6708304a81d（全站同一个常量）。
# 3) 音频宿主不止一个：oss-links.guoguo.org.cn（主力）、aod.cos.tx.xmcdn.com（喜马拉雅 CDN）、
#    res.wx.qq.com/voice/getvoice（微信语音，会忽略 Range 返回 200 全量、CT=audio/mp3）。
