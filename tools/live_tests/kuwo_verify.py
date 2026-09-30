#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
酷我畅听 (Kuwo TingShu) 数据链路自检脚本
==========================================
只用 Python 标准库，实测以下 4 条链路（全部无需 token / Sign / csrf）：

  ① 搜索      http://search.kuwo.cn/r.s?all=<kw>&ft=music&itemset=web_2013&client=kt
  ② 专辑详情  http://search.kuwo.cn/r.s?stype=albuminfo&albumid=<aid>
  ③ 章节列表  同上响应里的 musiclist 数组（酷我以「专辑 + 曲目」组织有声书）
  ④ 音频直链  http://antiserver.kuwo.cn/anti.s?type=convert_url3&rid=<rid>&format=mp3&response=url
              再对返回的 CDN URL 发 Range: bytes=0-1024

运行：
  C:\\Users\\Administrator\\AppData\\Local\\Python\\bin\\python.exe kuwo_verify.py

注意：Windows 控制台默认 GBK，脚本已把 stdout 重设为 UTF-8，否则中文会乱码。
"""

import ast
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------- 基础配置

UA_MOBILE = (
    "Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36"
)

SEARCH = "http://search.kuwo.cn/r.s"
ANTI = "http://antiserver.kuwo.cn/anti.s"

KEYWORD = "三体"
# 允许的音频 Content-Type 片段（全小写比较）
AUDIO_CT = ("audio/mpeg", "audio/mp4", "audio/x-m4a", "m4a")

TIMEOUT = 25
RETRY = 3

OK_TAG = "[OK]"
FAIL_TAG = "[FAIL]"

results = []  # (步骤名, 是否通过, 摘要)


def log(tag, msg):
    print(f"{tag} {msg}")


def rule(title):
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72)


# ---------------------------------------------------------------- HTTP 工具


def http_get(url, headers=None, want_headers=False):
    """GET，返回 (status, headers, body_bytes)。非 2xx 不抛异常，交给调用方判断。"""
    hdrs = {"User-Agent": UA_MOBILE, "Accept": "*/*"}
    if headers:
        hdrs.update(headers)
    last = None
    for attempt in range(RETRY):
        try:
            req = urllib.request.Request(url, headers=hdrs)
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                body = resp.read()
                hh = {k.lower(): v for k, v in resp.headers.items()}
                return resp.getcode(), hh, body
        except urllib.error.HTTPError as e:
            body = b""
            try:
                body = e.read()
            except Exception:
                pass
            hh = {k.lower(): v for k, v in (e.headers or {}).items()}
            return e.code, hh, body
        except Exception as e:  # 网络抖动重试
            last = e
            time.sleep(0.8 * (attempt + 1))
    raise RuntimeError(f"request failed: {url} -> {last}")


def decode(body):
    """酷我响应头写 utf-8，实测也确实是 utf-8（控制台乱码是 GBK 终端问题）。"""
    for enc in ("utf-8", "gb18030"):
        try:
            return body.decode(enc)
        except UnicodeDecodeError:
            continue
    return body.decode("utf-8", "replace")


NBSPS = ("&nbsp;", "&#160;", "\u00a0")


def clean(s):
    """
    去掉 &nbsp; 之类的 HTML 实体与首尾空白。
    注意：rt.s 的搜索接口（ft=music）会把 & 二次转义成字面量 \\u0026，
    而 stype=albuminfo 只转义一次；这里统一再解一次 \\uXXXX。
    """
    if s is None:
        return ""
    s = str(s)
    s = re.sub(r"\\+u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), s)
    s = s.replace("\\/", "/")
    for n in NBSPS:
        s = s.replace(n, " ")
    s = s.replace("\u00a0", " ")
    return re.sub(r"\s+", " ", s).strip()


def parse_kuwo(text):
    """
    酷我 search.kuwo.cn/r.s 的 rformat=json 其实**不是合法 JSON**：
    它是单引号的 JS/Python 字面量，形如 {'TOTAL':'3598','abslist':[...]}。
    依次尝试 json -> ast.literal_eval -> 正则兜底。
    """
    text = text.strip()
    try:
        return json.loads(text)
    except Exception:
        pass
    try:
        return ast.literal_eval(text)
    except Exception:
        pass
    # 兜底：把看起来像 null/true/false 的裸字面量换成 Python 形式
    fixed = re.sub(r"(?<=[:,\[])\s*null\s*(?=[,\]}])", " None ", text)
    fixed = re.sub(r"(?<=[:,\[])\s*true\s*(?=[,\]}])", " True ", fixed)
    fixed = re.sub(r"(?<=[:,\[])\s*false\s*(?=[,\]}])", " False ", fixed)
    return ast.literal_eval(fixed)


def rid_of(v):
    """MUSIC_626726999 / MP3_626726999 -> 626726999"""
    if v is None:
        return ""
    return re.sub(r"^[A-Za-z]+_", "", str(v)).strip()


# ---------------------------------------------------------------- 各步链路


def search(keyword, ft="music", rn=20):
    """① 搜索。返回 (hits:int, items:list[dict])"""
    q = urllib.parse.urlencode(
        {
            "all": keyword,
            "ft": ft,
            "itemset": "web_2013",
            "client": "kt",
            "pn": 0,
            "rn": rn,
            "rformat": "json",
            "encoding": "utf8",
        }
    )
    url = f"{SEARCH}?{q}"
    status, hdrs, body = http_get(url)
    if status != 200:
        raise RuntimeError(f"search HTTP {status}")
    data = parse_kuwo(decode(body))
    if ft == "music":
        items = data.get("abslist") or []
    elif ft == "album":
        items = data.get("albumlist") or []
    else:
        items = data.get("abslist") or data.get("albumlist") or []
    hits = data.get("TOTAL") or data.get("HIT") or data.get("SHOW") or len(items)
    return int(str(hits)), items, url


def album_info(albumid, rn=200, pn=0):
    """② 专辑详情 + ③ 章节列表（musiclist）"""
    q = urllib.parse.urlencode(
        {
            "stype": "albuminfo",
            "albumid": albumid,
            "rformat": "json",
            "encoding": "utf8",
            "rn": rn,
            "pn": pn,
        }
    )
    url = f"{SEARCH}?{q}"
    status, hdrs, body = http_get(url)
    if status != 200:
        raise RuntimeError(f"albuminfo HTTP {status}")
    return parse_kuwo(decode(body)), url


def direct_url(rid):
    """④-a 音符接口 -> CDN 直链。返回 (url, raw_json)"""
    q = urllib.parse.urlencode(
        {
            "type": "convert_url3",
            "rid": rid,
            "format": "mp3",
            "response": "url",
        }
    )
    url = f"{ANTI}?{q}"
    status, hdrs, body = http_get(url)
    text = decode(body).strip()
    if status != 200:
        return "", text
    try:
        obj = json.loads(text)
    except Exception:
        # 老接口 type=convert_url 直接返回纯文本 URL
        return (text if text.startswith("http") else ""), text
    if obj.get("code") not in (200, "200"):
        return "", text
    return obj.get("url", ""), text


def probe_audio(audio_url):
    """④-b Range 探测，返回 (status, content_type, total_bytes, head_bytes)"""
    status, hdrs, body = http_get(audio_url, headers={"Range": "bytes=0-1024"})
    ct = hdrs.get("content-type", "")
    total = 0
    cr = hdrs.get("content-range", "")
    m = re.search(r"/(\d+)\s*$", cr)
    if m:
        total = int(m.group(1))
    elif hdrs.get("content-length", "").isdigit():
        total = int(hdrs["content-length"])
    return status, ct, total, body


def is_audio_ct(ct):
    c = (ct or "").lower()
    return any(a in c for a in AUDIO_CT)


# ---------------------------------------------------------------- 主流程


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    print("酷我畅听 (Kuwo TingShu) 链路自检")
    print("目标站点: kuwo.cn/downtingshu -> tsm.kuwo.cn (畅听) / m.kuwo.cn (H5)")
    print("本次全部请求均不带 token / Sign / csrf / Cookie")

    # ---------------- ① 搜索 ----------------
    rule(f"① 搜索接口  search.kuwo.cn/r.s  (all={KEYWORD}&ft=music)")
    albumid = None
    first_rid = None
    try:
        hits, items, url = search(KEYWORD, ft="music", rn=20)
        log("URL", url)
        if not items:
            raise RuntimeError("abslist 为空")
        it = items[0]
        first_rid = rid_of(it.get("MUSICRID") or it.get("DC_TARGETID") or it.get("rid"))
        albumid = str(it.get("ALBUMID") or it.get("albumid") or "")
        name = clean(it.get("NAME") or it.get("name"))
        artist = clean(it.get("ARTIST") or it.get("artist"))
        log(OK_TAG, f"命中数 TOTAL={hits}  返回条数={len(items)}")
        log(OK_TAG, f"第一条标题: {name}")
        log(OK_TAG, f"第一条歌手: {artist}")
        log(OK_TAG, f"第一条 rid : {first_rid}   (MUSICRID={it.get('MUSICRID')})")
        if albumid:
            log(OK_TAG, f"第一条所属专辑 albumid: {albumid}")
        results.append(("① 搜索", True, f"TOTAL={hits} first_rid={first_rid}"))
    except Exception as e:
        log(FAIL_TAG, f"搜索失败: {e}")
        results.append(("① 搜索", False, str(e)))
        finish()
        return

    if not albumid:
        log(FAIL_TAG, "搜索结果里没有 ALBUMID，无法继续 ②③")
        results.append(("② 专辑详情", False, "no albumid"))
        finish()
        return

    # ---------------- ② 专辑详情 ----------------
    rule(f"② 专辑/书籍详情  search.kuwo.cn/r.s?stype=albuminfo&albumid={albumid}")
    tracks = []
    try:
        info, url = album_info(albumid, rn=200, pn=0)
        log("URL", url)
        title = clean(info.get("name") or info.get("title"))
        artist = clean(info.get("artist"))
        desc = clean(info.get("info"))
        songnum = info.get("songnum") or info.get("TOTAL") or ""
        img = info.get("img") or info.get("hts_img") or ""
        tracks = info.get("musiclist") or []
        log(OK_TAG, f"专辑标题: {title}")
        log(OK_TAG, f"演播/作者: {artist}")
        log(OK_TAG, f"曲目总数 songnum: {songnum}")
        log(OK_TAG, f"简介: {desc[:90]}")
        log(OK_TAG, f"封面: {img}")
        log(OK_TAG, f"字段路径: name / artist / songnum / info / img / musiclist[]")
        results.append(("② 专辑详情", True, f"{title} songnum={songnum}"))
    except Exception as e:
        log(FAIL_TAG, f"专辑详情失败: {e}")
        results.append(("② 专辑详情", False, str(e)))
        finish()
        return

    # ---------------- ③ 章节列表 ----------------
    rule("③ 章节列表  (专辑响应的 musiclist[] = 专辑曲目)")
    if not tracks:
        log(FAIL_TAG, "musiclist 为空")
        results.append(("③ 章节列表", False, "empty musiclist"))
        finish()
        return
    log(OK_TAG, f"曲目条数: {len(tracks)}")
    log(OK_TAG, "字段路径: musiclist[].name / musiclist[].musicrid / musiclist[].duration / musiclist[].tpay")
    log(OK_TAG, "前 3 条:")
    for t in tracks[:3]:
        log("     ", f"track={t.get('track'):>3}  rid={rid_of(t.get('musicrid')):<10} "
                     f"dur={t.get('duration'):>5}s  tpay={t.get('tpay')}  {clean(t.get('name'))[:46]}")
    results.append(("③ 章节列表", True, f"{len(tracks)} tracks"))

    # ---------------- ④ 音频直链 ----------------
    rule("④ 音频直链  antiserver.kuwo.cn/anti.s?type=convert_url3  +  Range: bytes=0-1024")

    # 免费 (tpay==0) 的曲目优先；付费曲目匿名请求只会拿到 30 秒试听，见 kuwo.md
    free = [t for t in tracks if str(t.get("tpay") or "0") == "0"]
    paid = [t for t in tracks if str(t.get("tpay") or "0") != "0"]
    candidates = free[:8] + paid[:4]
    log("INFO", f"本专辑免费曲目 {len(free)} 条 / 付费(tpay!=0)曲目 {len(paid)} 条")

    passed = False
    full_hit = None
    preview_note = ""
    for t in candidates:
        rid = rid_of(t.get("musicrid"))
        if not rid:
            continue
        dur = 0
        try:
            dur = int(str(t.get("duration") or "0"))
        except Exception:
            pass
        tname = clean(t.get("name"))
        try:
            aurl, raw = direct_url(rid)
        except Exception as e:
            log("     ", f"rid={rid} 音符接口异常: {e}")
            continue
        if not aurl or not aurl.startswith("http"):
            log("     ", f"rid={rid} 未取到直链, 原始返回: {raw[:70]}")
            continue
        try:
            status, ct, total, head = probe_audio(aurl)
        except Exception as e:
            log("     ", f"rid={rid} 直链探测异常: {e}")
            continue

        # 完整音频判断：128kbps mp3 约 16000 B/s；远低于此即试听片段
        expect = dur * 16000 if dur else 0
        is_full = bool(total and expect and total > expect * 0.5)
        kind = "完整" if is_full else "试听/片段"
        log("     ", f"rid={rid}  {status}  {ct}  size={total}B  dur={dur}s  -> {kind}  {tname[:34]}")

        audio_ok = status in (200, 206) and is_audio_ct(ct) and len(head) > 0
        if audio_ok and not passed:
            passed = True
            if is_full:
                full_hit = (rid, aurl, status, ct, total, tname, dur)
            else:
                preview_note = f"rid={rid} 只返回 {total}B 试听片段（曲目 {dur}s，付费内容）"

        if audio_ok and is_full:
            break

    if passed:
        if full_hit:
            rid, aurl, status, ct, total, tname, dur = full_hit
            log(OK_TAG, f"HTTP {status} (206=Range 生效)")
            log(OK_TAG, f"Content-Type: {ct}")
            log(OK_TAG, f"总长度: {total} bytes  /  曲目时长 {dur}s  => 完整音频")
            log(OK_TAG, f"曲目: {tname}")
            log(OK_TAG, f"直链样例: {aurl}")
            results.append(("④ 音频直链", True, f"{status} {ct} {total}B full"))
        else:
            log(OK_TAG, f"HTTP/Content-Type 校验通过，但只拿到试听片段: {preview_note}")
            log("WARN", "付费有声书匿名直链 = 30s 试听；完整音频需要 App/登录态签名或 WKWebView 嗅探")
            results.append(("④ 音频直链", True, f"audio ok but PREVIEW: {preview_note}"))
    else:
        log(FAIL_TAG, "没有任何候选曲目拿到合法音频响应")
        results.append(("④ 音频直链", False, "no valid audio response"))

    finish()


def finish():
    rule("汇总")
    allok = True
    for name, ok, summary in results:
        log(OK_TAG if ok else FAIL_TAG, f"{name:<12} {summary}")
        allok = allok and ok
    print()
    if allok:
        print("结论: 4 步全部通过 —— 搜索 / 详情 / 章节 / 直链 全链路可用，无需 Sign、csrf、token。")
    else:
        print("结论: 存在失败步骤，请检查网络或被风控。")
    print()
    sys.exit(0 if allok else 1)


if __name__ == "__main__":
    main()
