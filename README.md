# MoonCrawl 🕷️🥮

[![CI](https://github.com/guangting0905/mooncrawl/actions/workflows/ci.yml/badge.svg)](https://github.com/guangting0905/mooncrawl/actions/workflows/ci.yml)

**纯 MoonBit 的声明式网页采集框架** —— 2026 MoonBit 黑客松 10 月赛参赛项目。

MoonCrawl 把「抓网页 → 提数据 → 出结果」变成一条可配置的流水线：
URL 规范化去重、robots 协议遵守、按站点礼貌限速、HTML 解析管道、
结构化导出（JSONL / CSV），全部以 MoonBit 为主要实现语言。

## 为什么做这个

爬虫是数据采集的第一公里。MoonBit 生态里 HTTP 客户端（`moonbitlang/async`）、
HTML 解析（`moonbit-community/html`）、CSV 解析（`NyaCSV`）这些**积木已经齐了，
但把它们串成可用采集流水线的框架层是空白的**。MoonCrawl 不重复造轮子，
做的是那层「策略 + 调度 + 管道」：

- **规范化优先** —— 同一资源的多种书写形式（大小写 / 默认端口 / 点段 /
  参数顺序 / fragment）折叠为同一 URL。去重失败大多源于此。
- **Polite by default** —— robots.txt（RFC 9309 实用子集）、Crawl-delay、
  按 origin 记账的请求间隔是一等公民，不尊重站点就是 bug。
- **可测试性内建** —— 引擎的传输层是注入点，52 个测试全部离线运行，
  CI 上 js / native 双目标验证。
- **纯 MoonBit 核心** —— 可编译到 native / wasm-gc / js 三后端
  （网络传输在 js 后端经 Node，native 后端经 openssl/schannel）。

## 快速开始

```bash
# 安装 MoonBit 工具链（https://www.moonbitlang.com/download/）后：
moon test --target js          # 52 个测试
moon run cmd/main --target js -- https://books.toscrape.com/ --max-pages 12 --depth 1
```

真实站点输出示例（JSONL，逐页一条）：

```json
{"url":"https://books.toscrape.com/","status":200,"depth":0,"links_found":94,"title":"All products | Books to Scrape - Sandbox"}
{"url":"https://books.toscrape.com/catalogue/category/books/travel_2/index.html","status":200,"depth":1,"links_found":76,"title":"Travel | Books to Scrape - Sandbox"}
# pages_fetched=12 ok=12 failed=0 robots_skipped=0 links=1089 robots_unreachable=0
```

CSV 格式：

```bash
moon run cmd/main --target js -- https://quotes.toscrape.com/ --format csv --max-pages 8 > quotes.csv
```

CLI 参数：`--max-pages`（默认 50）、`--depth`（默认 2）、
`--delay-ms`（默认 1000）、`--format jsonl|csv`。结果走 stdout，
方便重定向落盘或管道处理。

## 库用法

```moonbit
// 规范化：等价书写形式折叠为同一字符串
let u = @mooncrawl.parse_url("HTTP://Example.COM:80/a/./b?b=2&a=1#top").unwrap()
println(@mooncrawl.normalize_url(u)) // => http://example.com/a/b?a=1&b=2

// 相对地址展开
let base = @mooncrawl.parse_url("https://example.com/a/b/index.html").unwrap()
let next = @mooncrawl.resolve_url(base, "page2.html").unwrap()

// 布隆去重（10 万级 URL 内存可控，误报率约 0.06%）
let seen = @mooncrawl.Bloom::new(100_000)
seen.add("https://example.com/page/1")

// robots 判定
let rules = @mooncrawl.parse_robots(robots_txt)
if rules.allowed_url("MoonCrawl/0.1", url) { /* fetch */ }

// 引擎（传输层可替换：http_fetch 为官方 async 实现）
let stats = @mooncrawl.crawl(seed, options, @mooncrawl.http_fetch, on_page)
```

## 架构

```
Seeds ──▶ Frontier（FIFO + 布隆去重）──▶ Politeness（origin 间隔 + Crawl-delay）
              ▲                                    │
              │                              robots.txt（RFC 9309 子集）
              │                                    ▼
        URL 规范化 ◀──────────────────  Fetcher（moonbitlang/async/http）
                                             │
                                             ▼
                              Extract（链接 / 标题 / 正文）
                                             │
                                             ▼
                                   Export（JSONL / CSV）
```

| 模块 | 文件 | 说明 | 测试 |
| --- | --- | --- | --- |
| URL | `url.mbt` | 解析、规范化（RFC 3986 子集）、相对展开 | 12 |
| 去重 | `bloom.mbt` | 布隆过滤器（16 bit/元素，7 哈希） | 2 |
| robots | `robots.mbt` | UA 分组最长匹配、`*`/`$` 通配、Crawl-delay、Sitemap | 12 |
| 队列 | `frontier.mbt` | FIFO（游标式，无 shift 退化）、已见去重、host 间隔推算 | 6 |
| 引擎 | `crawl.mbt` | async 主循环：深度/页数上限、robots 集成、统计计数 | 8 |
| 提取 | `extract.mbt` | `<a href>` 收集、`<title>`、正文（跳过 script/style） | 5 |
| 导出 | `export.mbt` | CSV（RFC 4180）、JSONL（含控制字符转义） | 7 |
| 传输 | `fetch_http.mbt` | 官方 async http 适配：30s 超时、UA 透传 | — |
| CLI | `cmd/main` | argparse：seed + 4 个选项，stdout 输出 | — |

**52 个测试全部离线**：引擎对内存假站点运行（注入 fetch 闭包），
不依赖网络与时钟，CI 稳定可复现。

## 查重声明

立项前按章程完成查重（详见 [docs/查重报告.md](docs/查重报告.md)）：
mooncakes.io 全量 3,265 模块中 `crawl/spider/scrape` 相关 **0 命中**；
awesome-moonbit 官方清单无同类条目；往期黑客松 22 个参赛项目无同类选题。
本项目复用社区积木，新增的是生态空白的框架层。

## 工程实践

- **持续提交**：每个模块独立 commit，commit message 标注测试数并关联 Issue。
- **双目标 CI**：GitHub Actions 在 js 与 native 后端跑全量测试 + `moon fmt` 门禁。
- **Issue 驱动**：立项时建 10 个 Issue 作为看板，随里程碑关闭。
- **接口稳定**：`moon info` 生成 `.mbti` 接口文件入库，重构可见性有据可查。

## 路线图

已交付（10 月赛）：

- [x] URL 解析 / 规范化 / 相对展开（D1）
- [x] 布隆去重（D1）
- [x] robots.txt 解析匹配与 Crawl-delay（D2）
- [x] frontier 与礼貌调度（D2）
- [x] async 抓取引擎（D3）
- [x] HTML 链接/标题/正文提取（D4）
- [x] JSONL/CSV 导出（D5）
- [x] 真实站点演示 + CLI（D5）
- [x] CI 双目标门禁（D6）
- [x] mooncakes.io 上架准备（包名 `guangting0905/mooncrawl`，`moon publish --dry-run` 就绪）

上架步骤（需 mooncakes 账号，GitHub OAuth 登录一次即可）：

```bash
moon login        # 浏览器完成 GitHub OAuth
moon publish      # 正式上架 mooncakes.io
```

后续方向（季度/年度持续建设）：

- 跨 origin 并行调度（worker pool，仍按站限速）
- 提取规则 DSL（CSS 选择器 → 字段映射，声明式采集）
- Sitemap 发现与优先级队列
- native 单文件二进制发布 + skills.mooncakes.io 技能上架

## 开源合规

Apache-2.0。项目为原创实现；依赖的 `moonbitlang/async`、
`moonbit-community/html` 均为 Apache-2.0，按其许可证使用并在 moon.mod 声明。

## 作者

guangting0905 · 2026 MoonBit 黑客松 10 月赛
