# -*- coding: utf-8 -*-
"""守卫（JS Cookie 挑战）的解 cookie 逻辑 —— 这是要移植回 Swift 的最终算法。
覆盖三种形态：
  A) document.cookie = '__51guid__=' + encodeURIComponent(token) + '; ' + config;
  B) var mainCookie = 'pt_guid=' + encodeURIComponent(token) + '; ' + config;  ... document.cookie = mainCookie;
  C) 直接内联值： document.cookie = 'name=value; path=/'
"""
import re
import sys
import base64
import urllib.parse
import urllib.request
import http.cookiejar

sys.stdout.reconfigure(encoding="utf-8")

UA_D = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
UA_M = "Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36"

VAR_RE = r"var\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'([^']*)'"
COOKIE_EXPR = r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'([A-Za-z_][A-Za-z0-9_]*)='\s*\+\s*(?:encodeURIComponent\()?([A-Za-z_][A-Za-z0-9_]*)\)?"


def decode_guard_js(html):
    m = re.search(r'var\s+reversed\s*=\s*"([^"]+)"', html)
    if not m:
        return None
    fwd = m.group(1)[::-1]
    fwd += "=" * ((4 - len(fwd) % 4) % 4)
    try:
        return base64.b64decode(fwd, validate=False).decode("utf-8", "replace")
    except Exception:
        return None


def extract_cookies(js):
    """返回 [(cookieName, value), ...]"""
    vars_ = dict(re.findall(VAR_RE, js))
    out = []

    # 形态 A / B：xxx = '<cookieName>=' + [encodeURIComponent(](var)
    via_var = {}
    for m in re.finditer(COOKIE_EXPR, js):
        lhs, cname, var = m.group(1), m.group(2), m.group(3)
        val = vars_.get(var, "")
        via_var[lhs] = (cname, val)

    # document.cookie = <expr>
    for m in re.finditer(r"document\.cookie\s*=\s*([^;\n]+)", js):
        expr = m.group(1).strip()
        # A) 直接字符串拼接
        mm = re.match(r"'([A-Za-z_][A-Za-z0-9_]*)='\s*\+\s*(?:encodeURIComponent\()?([A-Za-z_][A-Za-z0-9_]*)\)?", expr)
        if mm:
            out.append((mm.group(1), vars_.get(mm.group(2), "")))
            continue
        # C) 纯字面量 'name=value'
        mm = re.match(r"'([A-Za-z_][A-Za-z0-9_]*)=([^;']*)", expr)
        if mm:
            out.append((mm.group(1), mm.group(2)))
            continue
        # B) 引用变量
        mm = re.match(r"([A-Za-z_][A-Za-z0-9_]*)$", expr)
        if mm and mm.group(1) in via_var:
            out.append(via_var[mm.group(1)])
    # 去重（同名后者覆盖前者）
    merged = {}
    for k, v in out:
        merged[k] = v
    return list(merged.items())


def fetch_with_guard(url, ua, referer, netloc, verbose=True):
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    def get(u):
        r = urllib.request.Request(u)
        r.add_header("User-Agent", ua)
        r.add_header("Referer", referer)
        with op.open(r, timeout=45) as x:
            return x.read().decode("utf-8", "replace")

    html = get(url)
    if "var reversed" in html:
        js = decode_guard_js(html)
        cookies = extract_cookies(js) if js else []
        if verbose:
            print("     挑战页 %d 字节 → 解析出 cookie: %s" % (len(html), [c[0] for c in cookies]))
        for name, val in cookies:
            jar.set_cookie(http.cookiejar.Cookie(0, name, urllib.parse.quote(val, safe=""), None, False,
                                                 netloc, False, False, "/", True, False, None, False, None, None, {}))
        html = get(url)
        if verbose:
            print("     重放后 %d 字节" % len(html))
    return html


def check(name, url, ua, referer, netloc, want):
    print("=" * 66)
    print("【%s】" % name)
    html = fetch_with_guard(url, ua, referer, netloc)
    n = len(re.findall(want, html))
    print("     结果：%d 字节，目标链接 %d 条  %s" % (len(html), n, "✅" if n else "❌"))
    return n > 0


if __name__ == "__main__":
    ok = []
    ok.append(check("13听书网 目录页", "https://www.ting13.cc/tingdirs/UBuaNlHg/cbbhATaaUIuhLmGg.html",
                    UA_D, "https://www.ting13.cc/youshengxiaoshuo/37352/", "www.ting13.cc", r'href="(/play/[^"]+)"'))
    ok.append(check("爱听书 目录页", "https://www.itingshu.net/itingshus/ujMkGg/cbbhATaaUIuhLmHd.html",
                    UA_D, "https://www.itingshu.net/youshengxiaoshuo/37352/", "www.itingshu.net", r'href="(/play/[^"]+)"'))
    ok.append(check("乐听网 目录页", "https://m.leting.vip/bookdir/TlIb/cbbhATaaUIuhLmHi.html?sort=asc",
                    UA_M, "https://m.leting.vip/book/9181.html", "m.leting.vip", r'href="(/tingshu/[^"]+)"'))
    ok.append(check("29听书网 目录页", "https://m.ting29.com/bookdir/ubSqFe/cbbhATaaUIuhLmJf.html",
                    UA_M, "https://m.ting29.com/book/18654.html", "m.ting29.com", r'href="(/tingshu/[^"]+)"'))
    print("=" * 66)
    print("全部通过" if all(ok) else "有失败：" + str(ok))
