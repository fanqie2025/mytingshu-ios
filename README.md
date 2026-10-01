# 我的听书 · iOS 版（播放器外壳）

一个自用的 iOS 听书播放器：**App 本身只是外壳，不内置任何书源**。
书源在 App 内「设置 → 导入书源」用**订阅地址**或**粘贴 JSON** 在线导入；
另外内置一个 **Audiobookshelf** 连接器（连你自己的服务器）。

- 目标系统：**iOS 15 / 16**（arm64）
- 安装方式：**TrollStore（巨魔）直接装未签名 IPA**
- 构建：GitHub Actions 云端 macOS 编译（本机没有 Mac），无第三方依赖

## 安装（巨魔）

1. 手机浏览器打开 **Releases → latest**，下载 `MyTingShu.ipa`
2. 用 **TrollStore** 打开 → Install
3. 进 App：`设置 → 源管理` 里能看到内置的 Audiobookshelf；抓站书源要自己导入

```
https://github.com/fanqie2025/mytingshu-ios/releases/latest/download/MyTingShu.ipa
```

## 界面

底部五个页签：**书架 / 搜索 / 书源 / 历史 / 设置**

| 页签 | 内容 |
| --- | --- |
| 书架 | 正在播放、继续收听（最近 5 条历史，点一下续播）、收藏 |
| 搜索 | 对所有已启用源聚合搜索（逐源 20 秒超时，互不拖累）；可一键清空 |
| 书源 | 各源的分类发现入口 |
| 历史 | 全部收听记录，可清空 |
| 设置 | 源管理（启用/禁用 + Audiobookshelf 配置）、导入书源、播放、缓存、诊断 |

## 导入书源

`设置 → 源管理 → 导入书源`：

- **订阅地址**：填一个返回书源 JSON 的 URL；
- **粘贴 JSON**：直接把书源 JSON 贴进去（支持单个对象、数组，或 `{"sources":[…]}` 包裹）。

一个书源条目的格式（字段都可选）：

```json
{
  "id": "ting15",
  "name": "有听网",
  "host": "https://www.ting15.com",
  "encoding": "utf-8",
  "ua": "desktop",
  "search": {
    "url": "{host}/?s=ting-search-wd-{kw}.html",
    "pageUrl": "{host}/?s=ting-search-wd-{kw}-p-{page}.html",
    "list": ".category-list ul > li",
    "title": ".info h4 > a@title",
    "urlRule": ".info h4 > a@href",
    "cover": ".img img@src",
    "artist": ".info@regex(播音：([^<]*))"
  },
  "categories": [{ "title": "武侠玄幻", "url": "{host}/wuxiaxuanhuan/", "group": "有声小说" }],
  "detail": {
    "episodes": ".playlist .plist ul > li > a",
    "episodeTitle": "@text",
    "episodeUrl": "@href"
  },
  "audio": {
    "type": "post",
    "url": "{host}/?s=api-getneoplay",
    "metaFrom": { "bookId": "_b", "isPay": "_p", "page": "_cp" },
    "body": "bookId={bookId}&isPay={isPay}&page={page}",
    "field": "url",
    "referer": "{host}/"
  }
}
```

| 字段 | 含义 |
| --- | --- |
| `host` | 站点根地址，模板里可用 `{host}` |
| `encoding` | `utf-8`（默认）/ `gbk` |
| `ua` | `mobile`（默认）/ `desktop`（有些站对手机 UA 跳转或限流） |
| `warmup` | 首次请求前先 GET 这个地址拿 Cookie/session |
| `search.url` / `pageUrl` | 搜索地址模板（`{kw}`、`{page}`） |
| `search.list` | 结果条目容器**选择器** |
| `search.title` 等 | 取值规则：`选择器@text` / `@href` / `@src` / `@attr(名)` / `@regex(模式)` |
| `detail.episodes` | 章节链接选择器；`episodeTitle` / `episodeUrl` 取每条标题与链接 |
| `audio.type` | `regex`（章节页跑正则）/ `direct`（章节链接就是音频）/ `json`（接口字段）/ `redirect` / `post`（表单换地址，配 `metaFrom`+`body`+`field`） |
| `verification.url` | 搜索要先过验证码时填（App 会弹内置浏览器让过一次） |

选择器支持 `tag` / `.class` / `#id` / `[attr]` / `[attr=v]` / `[attr*=v]` / 后代（空格）/ 子代（`>`）。

> 我自用的那批书源（各站具体实现 + 逐站校验脚本）**不在本仓库**，单独放在私有仓库；
> 本仓库只保留这份格式说明。抓站源会随站点改版失效，私库里配有校验脚本。

## Audiobookshelf

`设置 → 源管理 → Audiobookshelf → 配置`：填服务器地址（如 `http://192.168.10.111:13378`）和 **API Token**
（ABS 里 设置 → 用户 → API Token），点「保存并测试连接」。

之后你的 ABS 书库会作为一个源出现在「书源」和「搜索」里，音频直接从你的服务器播放。

## 基础功能

| 功能 | 在哪 |
| --- | --- |
| 自定义倍速 0.50x–3.00x（播放页直接滑） | 播放页「倍速」/ 设置 |
| 跳过片头 / 片尾（每集自动跳，片尾到点自动下一集） | 播放页「片头片尾」/ 设置 |
| 定时关闭（5–300 分钟）+ 听完本集停止 | 播放页「定时」/ 设置 |
| 选集（播放页「选集」→ 输入集号直接跳） | 播放页 |
| 缓存：默认**关**；章节列表可单集手动缓存，播放优先用本地文件 | 章节列表 ↓ / 设置 → 缓存 |
| 15 秒快退/快进、后台播放、锁屏控制 | 播放页 / 自动 |
| 收藏、历史、书架 | 底部页签 |
| 诊断（逐源测搜索/详情/音频，结果可复制） | 设置 → 诊断 |

## 构建

```bash
bash build_ipa.sh          # 需要 macOS + Xcode 命令行工具；产物 build/MyTingShu.ipa
```

GitHub Actions 每次 push 自动编译 + 产物自检（Mach-O 必须是 iOS arm64 可执行文件），并更新 `latest` Release。

## 免责声明

- 本项目是**个人自用的播放器外壳**，**不提供、不托管、不传播任何音频内容**；
- 书源是**使用者自行导入**的第三方站点解析规则，与本仓库作者无关；请只导入你有权访问的内容；
- 仅供**本地测试与个人学习**，请勿用于商业用途或大规模抓取（会给源站带来压力）；
- 音频版权归原站与版权方所有；若权利方认为本仓库内容不妥，请提 Issue，我会立刻移除。

## 目录

```
Sources/
  App.swift          入口 + 底部页签
  Models.swift       数据模型 + 源协议
  HTTP.swift         网络 + 编码 + 超时 + 守卫解 cookie
  MiniHTML.swift     迷你 HTML 解析 + CSS 选择器（书源规则用）
  RuleSource.swift   JSON 书源 → 可执行源
  SourceStore.swift  源仓库 + 导入/删除
  AbsSource.swift    Audiobookshelf 连接器
  Player.swift       播放引擎 + 收藏/历史
  Cache.swift        缓存
  Diagnostics.swift  诊断
  UI.swift           界面
Resources/           Info.plist + 图标
tools/check_macho.py 产物自检
```
