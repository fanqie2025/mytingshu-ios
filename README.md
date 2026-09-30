# 我的听书 · iOS 版

一个自用的 iOS 听书播放器：**多源聚合搜索 + 分类发现 + 章节播放 + 收藏历史 + 书源导入**。
源在手机端直连各听书站，不需要服务器。

- 目标系统：**iOS 15 / 16**（arm64）
- 安装方式：**TrollStore（巨魔）直接装未签名 IPA**
- 构建方式：**GitHub Actions 云端 macOS 编译**（本机没有 Mac）
- 无第三方依赖：编译器直接 `swiftc` 组装 `.app`，不用 Xcode 工程、不用 CocoaPods/SPM

## 怎么装（巨魔）

1. 手机浏览器打开本仓库 **Releases → latest**，下载 `MyTingShu.ipa`
2. 用 **TrollStore** 打开这个 ipa → Install
3. 首次进 App：`设置 → 源管理` 里挑要用的源

> 也可以从 Actions 的 Artifacts 下载（需登录 GitHub）。

## 怎么导入书源（跟「我的听书」的订阅一样）

`设置 → 导入书源`：

- **订阅地址**：填一个返回书源 JSON 的 URL（自己的 GitHub raw / NAS 都行），App 会下载并保存；
- **粘贴 JSON**：直接把书源 JSON 贴进去。

书源 JSON 格式（字段都可选，够用就行）：

```json
{
  "id": "ting29",
  "name": "29听书网",
  "host": "https://m.ting29.com",
  "encoding": "utf-8",
  "search": {
    "url": "{host}/search.php?searchword={kw}&page={page}",
    "list": "ul.row-b > li",
    "title": "h2 a.f-bold@text",
    "urlRule": "h2 a.f-bold@href",
    "cover": "img@src",
    "artist": "span.fr@text",
    "intro": "p.f-gray@text"
  },
  "categories": [
    {"title": "玄幻", "url": "{host}/html/221.html", "group": "小说"}
  ],
  "detail": {
    "episodes": "#yuedu ul.ul-36 li a",
    "episodeTitle": "@title",
    "episodeUrl": "@href",
    "intro": "p.f-gray@text",
    "cover": ".style-img img@src"
  },
  "audio": {"type": "regex", "pattern": "var\\s+now\\s*=\\s*\"([^\"]+)\""},
  "verification": {"url": "{host}/search.php?searchword={kw}"}
}
```

说明：

| 字段 | 含义 |
| --- | --- |
| `host` | 站点根地址；模板里可用 `{host}` |
| `encoding` | `utf-8`（默认）或 `gbk`（中文老站） |
| `search.url` | 搜索地址模板，支持 `{kw}`（自动 URL 编码）、`{page}` |
| `search.list` | 结果条目的容器**选择器** |
| `search.title` 等 | 取值规则：`选择器@text` / `@href` / `@src` / `@attr(title)` |
| `categories` | 分类页列表（`{host}` 前缀可省） |
| `detail.episodes` | 章节链接选择器；`episodeTitle`/`episodeUrl` 取每条的标题与链接 |
| `audio.type` | `regex`（在章节页跑正则，取第 1 个分组）/ `direct`（章节链接本身就是音频）/ `json`（接口字段）/ `redirect`（跟随跳转） |
| `verification.url` | 搜索要先过验证码时填（App 会弹内置浏览器让你过一次） |

选择器支持：`tag`、`.class`、`#id`、`[attr]`、`[attr=v]`、`[attr*=v]`、后代（空格）、子代（`>`）。

## 已内置的源

| 源 | 说明 |
| --- | --- |
| 22听书（一夜幻听网） | 搜索需过一次图片验证码；分类/章节/播放免验证 |
| 书音FM（mekui） | JSON 接口，稳定 |
| 酷我畅听 | 免费曲目可直接播；付费的只有 30 秒试听（标题会标「试听」） |

其余站点用上面的 JSON 书源格式自行导入。

## 本地/云端构建

```bash
bash build_ipa.sh          # 需要 macOS + Xcode 命令行工具
# 产物：build/MyTingShu.ipa
```

GitHub Actions（`.github/workflows/ios.yml`）会在每次 push 时自动构建，
把 IPA 传到 Artifacts，并更新 `latest` Release。

## 目录

```
Sources/             Swift 源码
  App.swift          入口 + 底部 Tab
  Models.swift       数据模型 + 源协议
  HTTP.swift         网络 + GBK 解码 + HTML 工具
  MiniHTML.swift     迷你 HTML 解析 + CSS 选择器（书源规则用）
  RuleSource.swift   JSON 书源 → 可执行源
  SourceStore.swift  源仓库 + 导入/删除
  Sources.swift      原生源（22听书）
  KuwoSource.swift   酷我畅听
  Player.swift       播放引擎 + 收藏/历史
  UI.swift           界面
Resources/           Info.plist + 图标
```
