# 项目申报书（MoonCrawl）

> 按官方申报书样本格式撰写，可直接对照填入飞书报名表。
> 本轮为**驳回后修改版**：技术实现与项目定位均已调整，第 3 节逐条回应审核意见。

## 1. 基本信息

- **项目名称**：MoonCrawl：MoonBit 的网页爬虫框架
- **参赛者**：guangting0905
- **联系方式**：2187647636@qq.com
- **GitHub 仓库链接**：https://github.com/guangting0905/mooncrawl
- **项目方向**：MoonBit 网络爬虫框架 / 数据采集基础设施
- **是否为移植项目**：否（原创实现；复用 `moonbitlang/async`、`moonbit-community/html` 作为积木，均按 Apache-2.0 声明）

## 2. 项目简介

MoonCrawl 为 MoonBit 生态提供**通用的网页爬虫框架**。它不做「配置驱动的一次性
采集脚本」，而是提供一套可复用的工程约束：什么算同一个资源、什么算礼貌、
并发怎么不失控、提取规则放在哪里。

面向三类使用者：需要批量取数的应用开发者、需要把采集嵌进流水线的工具作者、
需要在 MoonBit 里做语料构建或站点监控的库作者。框架的分层是：

| 层 | 内容 | 是否依赖 async |
| --- | --- | --- |
| 基础层 | URL 解析与规范化、布隆去重、robots.txt、frontier | 否 |
| 引擎层 | 异步调度、礼貌限速、传输层适配 | 是（`moonbitlang/async`） |
| 提取层 | 链接/标题/正文、CSS 选择器、字段映射 | 否 |
| 输出层 | JSONL / CSV | 否 |

生态里 HTTP 客户端与 HTML 解析器已经存在，缺的是把它们串起来的那层**策略与
调度**——MoonCrawl 补的是这一层（申报前查重：mooncakes.io 全量 3,265 个模块中
爬虫框架方向 0 命中，详见 `docs/查重报告.md`）。

## 3. 对审核意见的逐条回应

### 3.1 「将查询参数排序视为资源等价依据，可能改变请求含义或遗漏资源」

**已修改：默认不再排序。**

旧实现的 `normalize_url` 无条件把 query 参数按 key/value 排序，等于断言
`?a=1&b=2` 与 `?b=2&a=1` 是同一资源。这个断言没有依据——RFC 3986 §6.2.3
把参数顺序归为「可能等价、需 scheme 定义」，服务端完全可以把顺序当语义
（有序签名、重复键取值、后端按位置读参）。

新实现区分两条路径：

- `normalize_url(u)`（默认）：只折叠 RFC 3986 §6.2.2 的语法等价——
  scheme/host 大小写、协议默认端口、点段、fragment。**参数顺序原样保留**。
- `normalize_url_sorted_query(u)`（显式）：额外折叠参数顺序，函数名直接表达
  它做了什么，文档写明启用前提（调用方确认站点把 query 当无序多重集）。

代价是 `?a=1&b=2` 与 `?b=2&a=1` 会被当作两个 URL 各抓一次。这是有意选择的
方向：**宁可多抓一次，也不漏抓一个资源**。该取舍已写入 README「已知限制」第 1 条。

### 3.2 「将 robots 处理终点限定为协议子集，不足以支撑协议遵守的承诺」

**已修改：补齐 RFC 9309 的匹配算法与状态码语义，并把未覆盖项逐条列明。**

不再使用「实用子集」这种模糊表述。现在的覆盖情况是逐条可查的
（见 `docs/rfc9309-覆盖声明.md`）：

- §2.2.1 组选择：大小写不敏感前缀匹配；**多个组匹配同一 UA 时合并为一组**
  （旧实现只取第一个匹配组，同名 UA 分散在多处时规则丢失）；无匹配回退 `*` 组。
- §2.2.2 匹配：从 path 首字节起匹配、最长模式优先、等长时 Allow 优先、
  组内无规则即允许、`/robots.txt` 隐式允许（旧实现会把它当普通路径判定）。
- §2.2.3 特殊字符：`#` 注释、`*` 通配、`$` 锚定。
- §2.3.1 状态码：**这是旧实现最实质的错误**——robots.txt 取不到时按「旧惯例」
  放行。RFC 9309 §2.3.1.4 对此是 MUST：5xx 与网络错误意味着 robots.txt
  未定义，必须假定完全禁止。新实现区分三种情形：

  | robots.txt 响应 | 处理 |
  | --- | --- |
  | 2xx | 解析并执行 |
  | 4xx | unavailable，放行（§2.3.1.3） |
  | 5xx / 网络错误 | **默认完全禁止**（§2.3.1.4），可按需显式改为 `RobotsUnreachable::Allow` |

- 附加修正：剥离 UTF-8 BOM（否则带 BOM 的文件首条 `User-agent` 行失效）。

**明确不承诺的四项**（覆盖声明第 2 节，含理由）：

1. §2.2.2 百分号解码比较（`%7E` 与 `~` 不视为同一路径）；
2. §2.3.1.2 重定向链（跟随交给传输层，不校验 5 次上限）；
3. §2.4 缓存时效（仅在单次调用内缓存，不跨进程）；
4. §2.5 500 KiB 解析上限（当前不限制体积）。

承诺范围因此收敛为：**RFC 9309 §2.2 的匹配算法 + §2.3.1 的状态码语义**。
这四项已进入路线图。

### 3.3 「建议将项目定位调整为通用的爬虫框架」

**已调整。** 项目名称、README 标题、`moon.mod` description、本文档统一为
「MoonBit 的网页爬虫框架」。原先的「声明式网页采集」不再是项目定位，而降级为
提取层的一个可选特性：不配置选择器时它就是普通爬虫，配置了才做字段采集。

### 3.4 「补充声明实现：自定义数据提取（CSS / XPath 选择器）」

**已实现 CSS 选择器提取，XPath 明确不做。**

新增 `selector.mbt`，在 `moonbit-community/html` 解析出的 DOM 上做匹配，
不自行解析 HTML：

- 选择器语法（CSS Selectors Level 4 子集）：类型/`*`、`.class`、`#id`、
  属性 `[a]` `[a=v]` `[a~=v]` `[a^=v]` `[a$=v]` `[a*=v]` `[a|=v]`、
  后代（空格）与子代（`>`）组合子、逗号并集、`:first-child`；
- 字段映射 `FieldSpec { name, selector, attr? }`：
  `extract_fields` 取整页一条记录，`extract_records` 对每个列表容器成表，
  字段选择器**不越过容器边界**（避免取到兄弟条目的内容）；
- 无法识别的语法返回空选择器（匹配 0 个节点），不猜测语义。

XPath 不做的理由：MoonBit 生态没有 XPath 实现，自研 XPath 1.0 的完整语义
（轴、节点测试、函数库）成本远高于 CSS 子集，而在采集场景中 CSS 选择器
已覆盖绝大多数需求。这条写进了 README「已知限制」第 7 条。

### 3.5 「异步调度」

**已实现跨 origin 并行、同 origin 串行，并修掉了导致调度卡死的缺陷。**

引擎主循环改为三阶段，共享状态只在串行段修改：

1. 串行：robots 加载与准入判定（会改 robots 缓存、统计、blocked 集合）；
2. 并行：`@async.all` 对通过准入的 URL 按 origin 礼貌等待后抓取（只读共享状态）；
3. 串行：处理结果、提取链接、入队、统计、回调。

并行度由 `max_concurrency` 控制（默认 4）；`Frontier::pop_batch(n)` 保证
**批内每个 host 最多一个 URL**，因此同 origin 始终串行，礼貌间隔不被并发绕过。

同时修掉一个会让抓取静默卡死的缺陷：`Politeness` 原来把 `@async.now()`
返回的 64 位毫秒截断成 32 位，回绕处算出的等待时长可达数十天，表现为
`sleep` 永不返回。这也是旧版**引擎测试在 js 后端无法完成**的原因——
修掉之后全部引擎用例在 js 后端可复现通过。

### 3.6 「请求处理」

传输层是注入点，默认实现基于 `moonbitlang/async/http`：30 秒整体超时、
User-Agent 透传（robots 组匹配依赖它）、协议错误/超时/解码错误统一折叠为
`status=0 + error`，引擎不感知传输细节。状态码语义（4xx/5xx）在引擎层按
RFC 9309 处理，见 3.2。

### 3.7 「优先复用或适配已有生态」

- HTTP：复用 `moonbitlang/async/http`，不自研 socket/TLS；
- HTML：复用 `moonbit-community/html`（HTML5 容错解析），选择器在其 DOM 上
  匹配，不自研 tokenizer 或树构建；
- 参数解析：复用 `moonbitlang/core/argparse`；
- 本项目新增的只有框架层：规范化策略、robots 判定、调度、字段映射、导出格式。

## 4. 核心功能范围

- **URL 解析与规范化**（`url.mbt`）：绝对 http/https 解析（userinfo 剥离、
  IPv6 字面量、端口校验、fragment 丢弃）；语义等价的书写形式折叠；
  参数顺序默认保留；相对地址展开（同目录/根相对/scheme 相对/查询相对），
  `javascript:`/`mailto:` 等外部 scheme 拒绝。

- **布隆去重**（`bloom.mbt`）：每元素 16 bit、7 哈希、误报率约 0.06%，
  支撑十万级 URL 的内存可控去重。

- **robots.txt**（`robots.mbt`）：RFC 9309 §2.2 匹配算法（组选择与合并、
  最长匹配、Allow 优先、`*`/`$`、`/robots.txt` 隐式允许）+ §2.3.1 状态码语义；
  `Crawl-delay` 扩展解析（毫秒，合并组取最大值）。

- **URL 前沿队列**（`frontier.mbt`）：游标式 FIFO（无大数组 shift 退化）、
  已见去重、按 host 的间隔推算、`pop_batch` 按 host 分流供并发调度。

- **异步抓取引擎**（`crawl.mbt`）：三阶段调度、深度/页数上限、
  按 origin 记账的礼貌限速（Crawl-delay 自动抬高间隔）、robots 不可达的
  保守回退、六项统计计数（抓取/成功/失败/robots 拒绝/不可达拒绝/发现链接）。

- **可注入传输层**（`fetch_http.mbt`）：`FetchFn` 闭包 + 默认 http 实现，
  引擎可在无网络、无时钟依赖的离线环境下对假站点确定性测试。

- **HTML 提取**（`extract.mbt`）：`<a href>` 按文档顺序收集、`<title>` 提取、
  正文文本（跳过 script/style/noscript 并折叠空白）。

- **CSS 选择器与字段提取**（`selector.mbt`）：见 3.4。

- **结构化导出**（`export.mbt`）：JSONL（控制字符转义）与 CSV（RFC 4180，
  CRLF 行尾），含绑定 `PageResult` 的页面行与接受任意字段对的通用记录行；
  核心零文件 IO 依赖。

- **命令行**（`cmd/main`）：页面模式（每页一条元数据）与采集模式
  （`--container` + `--fields` 按选择器逐条提取），后者会把字段值里的
  相对链接自动展开为绝对 URL。

## 5. 验证与证据

### 5.1 测试

`moon test --target js` → **75 个测试全部通过**，全部离线（引擎对内存假站点
运行，不依赖网络与时钟）：

| 文件 | 用例数 | 覆盖 |
| --- | --- | --- |
| `mooncrawl_test.mbt` | 16 | URL 解析/规范化/展开（含参数顺序不折叠的断言）、布隆过滤器 |
| `robots_test.mbt` | 16 | 组选择与合并、最长匹配、通配、BOM、隐式允许、Crawl-delay |
| `frontier_test.mbt` | 8 | FIFO、去重、间隔推算、`pop_batch` 按 host 分流与收敛 |
| `crawl_test.mbt` | 13 | 深度/页数、robots 准入、4xx/5xx/不可达分支、跨 host 并行、同 host 串行 |
| `selector_test.mbt` | 10 | 各类选择器、非法语法、字段映射、容器边界 |
| `extract_test.mbt` | 5 | 链接、标题、正文 |
| `export_test.mbt` | 7 | CSV 转义、JSONL 转义 |

CI 在 js 与 native 双后端执行全量测试，并跑 `moon fmt` 格式门禁。

### 5.2 真实站点端到端

books.toscrape.com（公开的爬虫练习站点）：

```
# 页面模式
{"url":"https://books.toscrape.com/","status":200,"depth":0,"links_found":94,"title":"All products | Books to Scrape - Sandbox"}
# pages_fetched=12 ok=12 failed=0 robots_skipped=0 robots_unreachable=0 links=1089

# 采集模式（CSS 选择器 + 字段映射）
{"title":"It's Only the Himalayas","price":"£45.17","link":"https://books.toscrape.com/catalogue/its-only-the-himalayas_981/index.html"}
{"title":"Vagabonding: An Uncommon Guide to the Art of Long-Term World Travel","price":"£36.94","link":"https://books.toscrape.com/catalogue/vagabonding-an-uncommon-guide-to-the-art-of-long-term-world-travel_552/index.html"}
```

复现命令见 README「CLI」一节。

### 5.3 权威外部一致性

- robots.txt：逐条对照 RFC 9309（`docs/rfc9309-覆盖声明.md`），
  含 MUST/SHOULD 级别与未覆盖项；
- URL 规范化：只折叠 RFC 3986 §6.2.2 的语法等价，§6.2.3 的参数顺序不做默认折叠；
- CSV：RFC 4180 的引号与 CRLF 规则。

## 6. 本轮修复的缺陷清单

驳回意见之外，本轮复查还修掉了 5 个实现缺陷，均有测试覆盖：

1. **礼貌调度 64→32 位截断**：等待时长溢出，`sleep` 永不返回（抓取卡死）。
2. **robots 不可达时放行**：违反 RFC 9309 §2.3.1.4 的 MUST。
3. **多个组匹配同一 UA 时未合并**：同名 UA 分散在多处时规则丢失，违反 §2.2.1。
4. **`/robots.txt` 未隐式允许**：`Disallow: /` 的站点会把 robots.txt 自身判为禁止，
   违反 §2.2.2。
5. **robots.txt 未剥离 UTF-8 BOM**：带 BOM 的文件整组规则失效。

## 7. 已知限制

完整清单在 README「已知限制」，摘要：

- 参数顺序不折叠（取舍见 3.1），同一资源可能被抓两次；
- robots 百分号解码未实现，重定向链/缓存时效/解析上限未覆盖；
- 不做 JS 渲染，不做 XPath；
- 单机内存队列，不支持分布式调度；
- 同 origin 串行，单站点吞吐受 `delay_ms` 限制。

## 8. 开源合规

Apache-2.0（完整 `LICENSE` 入库）。项目为原创实现；依赖的
`moonbitlang/async`、`moonbit-community/html` 均为 Apache-2.0，
按其许可证使用并在 `moon.mod` 中声明。第三方组件归属与许可见
`docs/查重报告.md` 与 README。
