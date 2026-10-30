MoonCrawl 项目申报书

## 基本信息

- **项目名称**：MoonCrawl：MoonBit 的网页爬虫框架
- **参赛者**：guangting0905
- **联系方式**：2187647636@qq.com
- **GitHub 仓库链接**：https://github.com/guangting0905/mooncrawl.git
- **项目方向**：MoonBit 网络爬虫框架 / 数据采集基础设施
- **是否为移植项目**：否（原创实现；复用 moonbitlang/async、moonbit-community/html 作为积木，均按 Apache-2.0 声明）

## 项目简介

MoonCrawl 为 MoonBit 生态提供通用的网页爬虫框架，把「抓网页 → 提数据 → 出结果」串成一条可复用的采集流水线，为数据采集、语料构建、站点监控和内容分析提供工程化的基础层。项目面向需要在 MoonBit 中做批量取数的库作者、工具开发者和应用开发者，提供 URL 解析与规范化、布隆过滤器去重、robots.txt 协议处理、按站点礼貌限速、跨 origin 异步调度、HTML 提取与 CSS 选择器字段提取，以及 JSONL / CSV 结构化导出。MoonBit 生态已有 HTTP 客户端与 HTML 解析器等积木，但缺少把它们串成采集流水线的框架层——MoonCrawl 补的正是这一层，不重复实现 socket、TLS 或 HTML 词法与树构建。申报前已按章程完成查重，mooncakes.io 全量 3,265 个模块中爬虫框架方向 0 命中（详见 docs/查重报告.md）。

## 核心功能范围

- 提供 URL 解析、规范化与相对地址展开（RFC 3986 实用子集）：scheme/host 小写化、默认端口省略、点段折叠、fragment 剥离，以及同目录、根相对、scheme 相对、查询相对的地址展开，`javascript:`/`mailto:` 等外部 scheme 拒绝解析；

- 提供保守的等价判定策略：默认只折叠 RFC 3986 §6.2.2 意义上的语法等价，**保留查询参数原始顺序**（参数顺序在部分服务端是语义，不默认视为同一资源）；需要按无序多重集去重的调用方，显式使用 `normalize_url_sorted_query`；

- 提供布隆过滤器去重模块（每元素 16 bit、7 哈希、误报率约 0.06%），支撑十万级 URL 的内存可控去重；

- 提供 robots.txt 解析与匹配（RFC 9309）：User-agent 分组大小写不敏感前缀匹配、多个组匹配同一 UA 时合并、Allow/Disallow 最长模式优先与等长 Allow 优先、`*` 与 `$` 通配、`/robots.txt` 隐式允许、Crawl-delay 毫秒化解析与 Sitemap 收集；

- 提供 robots.txt 状态码语义（RFC 9309 §2.3.1）：2xx 解析执行、4xx 视为不可用并放行、**5xx 与网络错误默认视为完全禁止**（可按需显式改为放行），未覆盖项（百分号解码、重定向链、缓存时效、解析体积上限）在 docs/rfc9309-覆盖声明.md 中逐条列明；

- 提供 URL 前沿队列（frontier）：游标式 FIFO（无大数组 shift 退化）、已见去重整合、按 host 的请求间隔推算，以及按 host 分流的批量出队 `pop_batch`，为并发调度提供同站串行保证；

- 提供异步抓取引擎 `crawl(...)`：深度与页数上限、按 origin 记账的礼貌限速（robots Crawl-delay 自动抬高间隔）、三阶段调度（串行准入判定 → 跨 origin 并行抓取 → 串行提取入队）、跨 origin 并行度可配（`max_concurrency`，同 origin 始终串行），以及抓取/成功/失败/robots 拒绝/不可达拒绝/发现链接等统计计数；

- 提供可注入传输层（`FetchFn` 闭包）与默认实现 `http_fetch`（基于 moonbitlang/async/http：30 秒超时、User-Agent 透传、协议错误与超时统一折叠），引擎可在无网络、无时钟依赖的离线环境下对假站点确定性测试；

- 提供 HTML 提取能力（基于 moonbit-community/html）：`<a href>` 链接按文档顺序收集、`<title>` 提取（实体解码、去首尾空白）、正文文本提取（跳过 script/style/noscript 子树并折叠空白）；

- 提供 CSS 选择器自定义提取：类型/`*`、`.class`、`#id`、属性谓词（`=` `~=` `^=` `$=` `*=` `|=`）、后代与子代组合子、逗号并集、`:first-child`；配合字段映射 `FieldSpec`（名称 + 选择器 + 可选取属性）支持整页单条记录 `extract_fields` 与逐容器成表 `extract_records`，字段选择器不越过容器边界；无法识别的语法返回空选择器而不猜测语义；

- 提供 JSONL 与 CSV（RFC 4180 转义）两种结构化导出，含绑定抓取结果的页面行与接受任意字段对的通用记录行，核心零文件 IO 依赖，输出走 stdout 便于重定向落盘与管道处理；

- 提供命令行入口 `mooncrawl`（moonbitlang/core/argparse）两种模式：页面模式输出每页元数据，采集模式经 `--container` 与 `--fields` 按选择器逐条提取记录，并把字段值中的相对链接自动展开为绝对 URL；

- 提供 75 个 MoonBit 测试并持续保持核心回归测试通过，其中引擎与调度用例全部离线运行（注入假 fetcher，不依赖网络与时钟）；GitHub Actions CI 在 js 与 native 双后端执行全量测试与 moon fmt 格式门禁；

- 提供 README 示例，覆盖库调用（规范化/展开/去重/robots/选择器/引擎）与 CLI 双模式的真实输出，以及架构图、模块-测试对照表与已知限制清单；并提供 docs/rfc9309-覆盖声明.md 作为 robots 处理的外部一致性证据。

---

## 附：本轮修改要点（供复审参考）

针对上次审核意见的处置，技术实现与文档同步修改，均已提交并通过 CI：

- **查询参数排序不再作为资源等价依据**：默认保留 query 原始顺序，排序改为独立的显式 API `normalize_url_sorted_query`，函数名与文档说明启用前提；取舍（同一资源可能被抓两次）写入 README 已知限制第 1 条。

- **robots 处理从「协议子集」改为逐条对照 RFC 9309**：补齐 §2.2.1 多组匹配合并、§2.2.2 `/robots.txt` 隐式允许、§2.3.1.4 5xx 与网络错误默认完全禁止、UTF-8 BOM 剥离；新增 docs/rfc9309-覆盖声明.md，按 MUST/SHOULD 列出实现状态、对应测试与**明确不做的 4 项**（百分号解码比较、重定向链、缓存时效、500 KiB 解析上限）。承诺范围收敛为「§2.2 匹配算法 + §2.3.1 状态码语义」。

- **项目定位调整为通用爬虫框架**：「声明式网页采集」不再是项目定位，降为提取层的可选特性——不配置选择器时就是普通爬虫，配置后才做字段采集。

- **补充自定义数据提取**：新增 CSS 选择器模块与字段映射（见核心功能范围第 10 条）。XPath 明确不做，理由写在 README 已知限制：MoonBit 生态无 XPath 实现，自研完整语义成本远高于 CSS 子集，而采集场景中 CSS 已覆盖绝大多数需求。

- **补充异步调度**：三阶段调度 + `max_concurrency`，`Frontier::pop_batch` 保证批内每 host 最多一个 URL，同 origin 严格串行、礼貌间隔不被并发绕过。

- **顺带修复 5 个实现缺陷**（均有测试覆盖）：① 礼貌调度把 64 位毫秒截断成 32 位，等待时长溢出导致 `sleep` 永不返回、抓取静默卡死（也是引擎测试在 js 后端无法完成的根因）；② robots 不可达时放行，违反 §2.3.1.4；③ 多个组匹配同一 UA 时未合并，违反 §2.2.1；④ `/robots.txt` 未隐式允许，违反 §2.2.2；⑤ robots.txt 未剥离 UTF-8 BOM，带 BOM 时整组规则失效。

- **验证**：`moon test --target js` 75 个用例全部通过；CI 三 job（js / native / fmt）全绿；包已发布到 mooncakes.io（`guangting0905/mooncrawl` v0.1.0，`moon add guangting0905/mooncrawl@0.1.0` 可安装）；真实站点 books.toscrape.com 端到端验证，页面模式 12 页全部 200、发现 1,089 个链接，采集模式按 CSS 选择器输出书目记录（含相对链接绝对化）。
