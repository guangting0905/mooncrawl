# MoonCrawl 🕷️🥮

[![CI](https://github.com/guangting0905/mooncrawl/actions/workflows/ci.yml/badge.svg)](https://github.com/guangting0905/mooncrawl/actions/workflows/ci.yml)

**MoonBit 的网页爬虫框架** —— 2026 MoonBit 黑客松 10 月赛参赛项目。

已发布到 mooncakes.io：`guangting0905/mooncrawl@0.1.1`
（[文档](https://mooncakes.io/docs/guangting0905/mooncrawl)）

```bash
moon add guangting0905/mooncrawl@0.1.1
```

MoonCrawl 把「抓网页 → 提数据 → 出结果」串成一条可复用流水线：URL 规范化、
布隆去重、robots.txt 处理、按站点礼貌限速、跨 origin 异步调度、HTML 提取与
CSS 选择器字段提取、JSONL / CSV 导出。**框架层是本项目的产出**——HTTP 客户端
（`moonbitlang/async`）与 HTML 解析器（`moonbit-community/html`）直接复用生态
现有实现，不重复造轮子。

## 为什么做这个

MoonBit 生态里 HTTP 客户端、HTML 解析器、CSV 解析器这些**积木已经齐了，
但把它们串成可用采集流水线的框架层是空白的**。空白不在于「能不能发请求」，
而在于这些工程约束：

- **什么是同一个资源** —— 大小写、默认端口、点段、fragment 折叠；
  查询参数顺序**不**折叠（见下）。
- **什么是礼貌** —— robots.txt 的解析与匹配、Crawl-delay、按 origin 记账的
  请求间隔。这些做错不会报错，只会悄悄变成滥用。
- **怎么并发不失控** —— 跨站点并行提速，同站点必须串行。
- **提取规则放哪** —— 写死在代码里换站点就得改代码；做成数据换选择器就行。

申报前已按章程完成查重（详见 [docs/查重报告.md](docs/查重报告.md)）：
mooncakes.io 截至 2026-10-24 的全量 3,265 个模块中 `crawl/spider/scrape`
相关 **0 命中**（不含本项目自身）；
awesome-moonbit 官方清单无同类条目；往期黑客松 22 个参赛项目无同类选题。

## 快速开始

作为依赖：

```bash
moon add guangting0905/mooncrawl@0.1.1
```

从源码构建与测试：

```bash
moon test --target js     # 80 个离线测试
moon run cmd/main --target js -- https://books.toscrape.com/ --max-pages 12 --depth 1
```

后端选择：**js 后端零额外依赖**，开箱可用；**native 后端需要 C 工具链**
（Windows 上是 MSVC Build Tools + Windows SDK）以及 OpenSSL 头文件
（`moonbitlang/async` 的 TLS 依赖，Ubuntu 上装 `libssl-dev`）。
CI 在两种后端上都执行全量测试。

## 能力范围

### URL 处理（`url.mbt`）

- 解析绝对 http/https URL：scheme/host 小写化、userinfo 剥离、IPv6 字面量、
  端口校验、fragment 丢弃；
- 规范化：折叠 RFC 3986 §6.2.2 意义上的语法等价（大小写、默认端口、点段、
  fragment），**默认保留查询参数原始顺序**；
- 相对地址展开：同目录、根相对、scheme 相对、查询相对，`javascript:`/`mailto:`
  等外部 scheme 拒绝解析；
- 显式的 `normalize_url_sorted_query`：仅当调用方确认站点把 query 当无序
  多重集时启用参数排序折叠。

### robots.txt（`robots.mbt`）

按 RFC 9309 实现匹配算法与状态码语义，覆盖边界逐条列在
**[docs/rfc9309-覆盖声明.md](docs/rfc9309-覆盖声明.md)**：

- §2.2.1 组选择：大小写不敏感前缀匹配、**多组匹配时合并**、`*` 组回退；
- §2.2.2 匹配：从首字节匹配、最长模式优先、等长 Allow 优先、`/robots.txt` 隐式允许；
- §2.2.3 特殊字符：`#` 注释、`*` 通配、`$` 锚定；
- §2.3.1 状态码：2xx 执行、4xx 放行、**5xx 与网络错误默认完全禁止**
  （`RobotsUnreachable::Disallow`，可按需改为 `Allow`）；
- 扩展：`Crawl-delay` 解析并在合并组时取最大值，只抬高不降低请求间隔。

### 去重与队列（`bloom.mbt` / `frontier.mbt`）

- 布隆过滤器：每元素 16 bit、7 哈希、理论误报率约 0.07%；位用 `Array[UInt64]` 手工打包，十万 URL 约 200 KiB；
- 游标式 FIFO（无大数组 shift 退化）、已见去重、按 host 的间隔推算；
- `pop_batch(n)`：批量出队且**每个 host 最多一个**，为并发调度提供同站串行保证。

### 异步抓取引擎（`crawl.mbt`）

- `async fn crawl(...)`：深度/页数上限、robots 准入、按 origin 礼貌限速；
- 三阶段调度：串行做准入判定 → 并行抓取（跨 origin）→ 串行做提取入队，
  共享状态只在串行段修改；
- `max_concurrency` 控制跨 origin 并行度，同一 origin 始终串行；
- 传输层是可注入闭包（`FetchFn`），引擎能在无网络、无时钟依赖的离线环境下
  对假站点确定性测试；默认实现 `http_fetch` 基于 `moonbitlang/async/http`
  （30 秒超时、User-Agent 透传、错误统一折叠）；
- 统计计数：抓取页数、成功/失败、robots 拒绝、robots 不可达拒绝、
  发现链接数、不可达 origin 数。

### 提取（`extract.mbt` / `selector.mbt`）

- 基础提取：`<a href>` 按文档顺序收集、`<title>` 提取、正文文本
  （跳过 script/style/noscript 并折叠空白）；
- CSS 选择器子集：类型/类/ID/属性（`=` `~=` `^=` `$=` `*=` `|=`）、
  后代与子代组合子、逗号并集、`:first-child`；
- 字段映射：`FieldSpec`（名称 + 选择器 + 可选取属性）→
  `extract_fields`（整页一条记录）与 `extract_records`（逐容器成表，
  字段选择器不越过容器边界）；
- 明确不支持：伪元素、`:not()`/`:has()`、兄弟组合子 `+`/`~`、
  `nth-child` 表达式、XPath。遇到无法识别的语法返回空选择器，不猜。

### 导出（`export.mbt`）

- CSV（RFC 4180 转义，CRLF 行尾）与 JSONL（控制字符转义）；
- 通用 `json_record` / `csv_record` 接受任意字段对，配合字段提取使用；
- 核心零文件 IO 依赖，输出走 stdout，便于重定向与管道。

### CLI（`cmd/main`）

两种模式，参数见 `--help`：

```bash
# 页面模式：每页一条元数据
moon run cmd/main --target js -- https://books.toscrape.com/ --max-pages 12 --depth 1

# 采集模式：按 CSS 选择器逐条提取记录
moon run cmd/main --target js -- \
  "https://books.toscrape.com/catalogue/category/books/travel_2/index.html" \
  --max-pages 1 --depth 0 \
  --container "article.product_pod" \
  --fields "title=h3 a@title;price=.price_color;link=h3 a@href"
```

采集模式的真实输出（字段值里的相对链接会自动展开为绝对 URL）：

```json
{"title":"It's Only the Himalayas","price":"£45.17","link":"https://books.toscrape.com/catalogue/its-only-the-himalayas_981/index.html"}
{"title":"Vagabonding: An Uncommon Guide to the Art of Long-Term World Travel","price":"£36.94","link":"https://books.toscrape.com/catalogue/vagabonding-an-uncommon-guide-to-the-art-of-long-term-world-travel_552/index.html"}
# pages_fetched=1 ok=1 failed=0 robots_skipped=0 robots_unreachable=0 links=76
```

页面模式的真实输出：

```json
{"url":"https://books.toscrape.com/","status":200,"depth":0,"links_found":94,"title":"All products | Books to Scrape - Sandbox"}
{"url":"https://books.toscrape.com/catalogue/category/books/travel_2/index.html","status":200,"depth":1,"links_found":76,"title":"Travel | Books to Scrape - Sandbox"}
# pages_fetched=12 ok=12 failed=0 robots_skipped=0 robots_unreachable=0 links=1089
```

## 库用法

```moonbit
// URL 规范化：折叠语法等价，保留参数顺序
let u = @mooncrawl.parse_url("HTTP://Example.COM:80/a/./b?b=2&a=1#top").unwrap()
println(@mooncrawl.normalize_url(u))              // http://example.com/a/b?b=2&a=1
println(@mooncrawl.normalize_url_sorted_query(u)) // http://example.com/a/b?a=1&b=2

// 相对地址展开
let base = @mooncrawl.parse_url("https://example.com/a/b/index.html").unwrap()
let next = @mooncrawl.resolve_url(base, "page2.html").unwrap()

// 布隆去重
let seen = @mooncrawl.Bloom::new(100_000)
seen.add("https://example.com/page/1")

// robots 判定与 Crawl-delay
let rules = @mooncrawl.parse_robots(robots_txt)
if rules.allowed_url("MoonCrawl/0.1", u) { /* 可以抓 */ }
let delay = rules.crawl_delay_ms("MoonCrawl/0.1")

// CSS 选择器提取
let rows = @mooncrawl.extract_records(html, "article.product_pod", [
  @mooncrawl.FieldSpec::text("title", "h3 a"),
  @mooncrawl.FieldSpec::attr("link", "h3 a", "href"),
  @mooncrawl.FieldSpec::text("price", ".price_color"),
])

// 引擎：传输层可替换（需在 async fn 中调用）
let stats = @mooncrawl.crawl(seed, options, @mooncrawl.http_fetch, on_page)
```

## 架构

```
Seeds ──▶ Frontier（FIFO + 布隆去重 + pop_batch 按 host 分流）
              │
              ▼
      Politeness（origin 间隔 + Crawl-delay）──▶ robots.txt（RFC 9309）
              │
              ▼
      Fetcher（可注入闭包 / moonbitlang/async/http）
              │  跨 origin 并行，同 origin 串行
              ▼
      Extract（链接 / 标题 / 正文 / CSS 选择器字段）
              │
              ▼
      Export（JSONL / CSV）
```

调度分三段，共享状态只在串行段改动：

```moonbit
while 未达页数上限 {
  batch = frontier.pop_batch(max_concurrency)   // 每个 host 最多一个
  阶段 1（串行）：robots 加载与准入判定
  阶段 2（并行）：@async.all 跨 origin 抓取，各自 polite.gate
  阶段 3（串行）：结果处理、链接提取、入队、统计、回调
}
```

| 模块 | 文件 | 说明 | 测试 |
| --- | --- | --- | --- |
| URL | `url.mbt` | 解析、规范化（保留参数顺序）、相对展开 | 14 |
| 去重 | `bloom.mbt` | 布隆过滤器（16 bit/元素，7 哈希，位打包） | 2 |
| robots | `robots.mbt` | RFC 9309 组选择与匹配、状态码语义、Crawl-delay | 16 |
| 队列 | `frontier.mbt` | FIFO（游标式）、`pop_batch` 按 host 分流、间隔推算 | 8 |
| 引擎 | `crawl.mbt` | 三阶段异步调度、robots 集成、统计计数 | 13 |
| 提取 | `extract.mbt` | `<a href>`、`<title>`、正文 | 5 |
| 选择器 | `selector.mbt` | CSS 子集、字段映射、逐容器成表 | 10 |
| 导出 | `export.mbt` | CSV（RFC 4180）、JSONL、通用字段行 | 7 |
| 边界 | `boundary_test.mbt` | 跨模块边界用例（URL/robots/选择器/十万元素） | 5 |
| 传输 | `fetch_http.mbt` | 官方 async http 适配：30s 超时、UA 透传 | — |
| CLI | `cmd/main` | 页面模式 / 采集模式 | — |

**80 个测试全部离线**：引擎对内存假站点运行（注入 fetch 闭包），
不依赖网络与时钟，CI 在 js 与 native 双后端执行全量测试 + `moon fmt` 门禁。

## 已知限制

写在前面，避免误用：

1. **查询参数顺序不折叠**。`?a=1&b=2` 与 `?b=2&a=1` 被视为不同 URL，
   同一资源可能被抓两次。这是有意的保守取舍：参数顺序在部分服务端是语义
   （签名、重复键、按位置读参）。确认目标站点无序时用
   `normalize_url_sorted_query`。
2. **robots 的百分号解码未实现**。`%7E` 与 `~` 不视为同一路径，
   规则可能少匹配或多匹配。详见覆盖声明表。
3. **不处理重定向链**。跟随行为交给传输层，不校验 5 次上限。
4. **robots 缓存不持久化**。只在单次 `crawl` 调用内有效，不跨进程。
5. **robots.txt 无体积上限**。超大文件会全量解析（RFC 建议 ≥500 KiB 限额）。
6. **不做 JS 渲染**。只解析服务端返回的 HTML，SPA 站点需要在渲染层另行解决。
7. **不做 XPath**。选择器只覆盖 CSS 子集。
8. **单机内存队列**。URL 全量驻留内存（布隆过滤器只做去重），不支持分布式调度。
9. **同 origin 串行**。跨 origin 才并行；单站点抓取的吞吐受 `delay_ms` 限制。

## 工程实践

- **持续提交**：提交历史按模块推进，功能提交标注测试数并关联 Issue。
- **双目标 CI**：GitHub Actions 在 js 与 native 后端跑全量测试 + `moon fmt` 门禁。
- **Issue 驱动**：立项时建 10 个 Issue 作为看板，随里程碑关闭并附交付说明。
- **接口稳定**：`moon info` 生成 `.mbti` 接口文件入库，重构可见性有据可查。
- **零告警**：`moon check` 无警告无错误，`moon fmt` 无 diff。

## 查重声明

立项前按章程完成查重（详见 [docs/查重报告.md](docs/查重报告.md)）：
mooncakes.io 全量 3,265 模块中 `crawl/spider/scrape` 相关 **0 命中**；
awesome-moonbit 官方清单无同类条目；往期黑客松 22 个参赛项目无同类选题。
本项目复用社区积木，新增的是生态空白的框架层。

## 路线图

已交付（10 月赛）：

- [x] URL 解析 / 规范化 / 相对展开（D1）
- [x] 布隆去重（D1）
- [x] robots.txt 解析匹配、状态码语义与 Crawl-delay（D2）
- [x] frontier 与礼貌调度（D2）
- [x] 异步抓取引擎（D3）
- [x] HTML 链接/标题/正文提取（D4）
- [x] CSS 选择器与声明式字段提取（D5）
- [x] JSONL/CSV 导出（D5）
- [x] 真实站点演示 + CLI 双模式（D5）
- [x] CI 双目标门禁（D6）
- [x] mooncakes.io 上架（`guangting0905/mooncrawl` v0.1.1，`moon publish` 已通过）

后续方向（季度/年度持续建设）：

- robots 百分号解码与 500 KiB 解析上限
- 重定向链显式处理（5 跳上限）
- Sitemap 发现与优先级队列
- 提取规则持久化（配置文件驱动的采集任务）
- native 单文件二进制发布 + skills.mooncakes.io 技能上架

## 开源合规

Apache-2.0，完整许可文本见 `LICENSE`。

- **NOTICE**：第三方组件归属与所引用的规范清单见 [`NOTICE`](NOTICE)。
  项目为原创实现，未复制或内联任何第三方源码；`moonbitlang/async`、
  `moonbit-community/html` 均为 Apache-2.0，以 `moon.mod` 声明的方式作为依赖使用。
- **规范引用**：RFC 3986（URL 规范化）、RFC 9309（robots.txt）、
  RFC 4180（CSV）为文档而非代码，引用处以 `docs/` 与源码注释标注。
- **打包范围**：`.moonignore` 控制发布内容，参赛材料（含联系方式与审核沟通记录）
  不随包分发。

## 作者

guangting0905 · 2026 MoonBit 黑客松 10 月赛
