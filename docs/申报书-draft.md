MoonCrawl 项目申报书

## 基本信息

- **项目名称**：MoonCrawl：MoonBit 的网页爬虫框架
- **参赛者**：guangting0905
- **联系方式**：2187647636@qq.com
- **GitHub 仓库链接**：https://github.com/guangting0905/mooncrawl.git
- **项目方向**：MoonBit 网络爬虫框架 / 数据采集基础设施
- **是否为移植项目**：否（原创实现；复用 moonbitlang/async、moonbit-community/html 作为积木，均按 Apache-2.0 声明）

## 项目简介

MoonCrawl 为 MoonBit 生态提供通用的网页爬虫框架，把「抓网页 → 提数据 → 出结果」串成一条可复用的采集流水线，为数据采集、语料构建、站点监控和内容分析提供工程化的基础层。项目面向需要在 MoonBit 中做批量取数的库作者、工具开发者和应用开发者，提供 URL 解析与规范化、布隆过滤器去重、robots.txt 协议处理、按站点礼貌限速、跨 origin 异步调度、HTML 提取与 CSS 选择器字段提取，以及 JSONL / CSV 结构化导出。MoonBit 生态已有 HTTP 客户端与 HTML 解析器等积木，但缺少把它们串成采集流水线的框架层——MoonCrawl 补的正是这一层，不重复实现 socket、TLS 或 HTML 词法与树构建。申报前已按章程完成查重：截至 2026-10-24，mooncakes.io 全量 3,265 个模块中爬虫框架方向 0 命中（详见 docs/查重报告.md）。

## 核心功能范围

- 提供 URL 解析、规范化与相对地址展开（RFC 3986 实用子集）：scheme/host 小写化、默认端口省略、点段折叠、fragment 剥离，以及同目录、根相对、scheme 相对、查询相对的地址展开，`javascript:`/`mailto:` 等外部 scheme 拒绝解析；**重复斜杠与查询参数顺序不折叠**——二者不属于 RFC 3986 §6.2.2 的语法等价，折叠会改写请求目标；

- 提供保守的等价判定策略：默认只折叠 RFC 3986 §6.2.2 意义上的语法等价，**保留查询参数原始顺序**（参数顺序在部分服务端是语义，不默认视为同一资源）；需要按无序多重集去重的调用方，显式使用 `normalize_url_sorted_query`；

- 提供布隆过滤器去重模块（每元素 16 bit、7 哈希、理论误报率约 0.07%，位用 UInt64 手工打包，十万 URL 约 200 KiB），容量可按任务规模配置（`Frontier::with_capacity`，默认 65536 个 URL），并通过 `saturation_permille()` 暴露实际填充率——容量不足时不会再静默丢链接，而是给出可观测指标与 CLI 告警；

- 提供 robots.txt 解析与匹配（RFC 9309）：User-agent 分组大小写不敏感前缀匹配、同名 UA 分散在多组时合并、不同长度 token 同时匹配时取最长（对 RFC 字面的有意偏离，与主流实现一致，已在覆盖声明 §1.1 单列）、路径匹配为从首字节起的**前缀匹配**（模式不得命中路径中段）、Allow/Disallow 最长模式优先与等长 Allow 优先、`*` 与 `$` 通配（线性双指针，无指数回溯）、不属于任何组的裸规则按 SHOULD 忽略、比较前把两侧统一到同一编码形式（unreserved 字符解码 + 非 ASCII 字符按 UTF-8 编码 + 十六进制位大写）、`/robots.txt` 隐式允许、Crawl-delay 毫秒化解析与 Sitemap 收集；

- 提供 robots.txt 状态码语义（RFC 9309 §2.3.1）：2xx 解析执行、4xx 视为不可用并放行、**5xx 与网络错误默认视为完全禁止**（可按需显式改为放行），解析上限 1 MiB（截断后前部规则照常生效，该上限只约束解析、不约束下载与内存峰值）；未覆盖项（字面星号匹配、重定向链、缓存时效）与两处有意偏离（组选择、百分号编码向）在 docs/rfc9309-覆盖声明.md 中逐条列明；

- 提供 URL 前沿队列（frontier）：游标式 FIFO（无大数组 shift 退化）、已见去重整合（容量可配，默认 65536 个 URL）、按 host 的请求间隔推算，以及按 host 分流的批量出队 `pop_batch`，为并发调度提供同站串行保证；

- 提供异步抓取引擎 `crawl(...)`：深度与页数上限、按 origin 记账的礼貌限速（robots Crawl-delay 自动抬高间隔）、三阶段调度（串行准入判定 → 跨 origin 并行抓取 → 串行提取入队）、跨 origin 并行度可配（`max_concurrency`，同 origin 始终串行）、跟随页面 `<base href>` 展开相对链接，以及抓取/成功/失败/robots 拒绝/不可达拒绝/发现链接/去重填充率等统计计数；

- 提供可注入传输层（`FetchFn` 闭包）与默认实现 `http_fetch`（基于 moonbitlang/async/http：30 秒超时、User-Agent 透传），协议错误、超时与底层抛出的异常统一折叠为单页失败（`status=0 + error`），不中断整次采集；引擎可在无网络、无时钟依赖的离线环境下对假站点确定性测试；

- 提供 HTML 提取能力（基于 moonbit-community/html）：`<a href>` 链接按文档顺序收集、`<title>` 提取（实体解码、去首尾空白）、正文文本提取（跳过 script/style/noscript 子树并折叠空白）、`<base href>` 提取；`extract_page` 一次解析同时产出链接/标题/base，引擎每页只解析一遍 HTML；

- 提供 CSS 选择器自定义提取：类型/`*`、`.class`、`#id`、属性谓词（`=` `~=` `^=` `$=` `*=` `|=`）、后代与子代组合子、逗号并集、`:first-child`；配合字段映射 `FieldSpec`（名称 + 选择器 + 可选取属性）支持整页单条记录 `extract_fields` 与逐容器成表 `extract_records`，字段选择器不越过容器边界；无法识别的语法（含链首或悬空的子代组合子 `> p`、`div >`）返回空选择器而不降级成合法选择器；

- 提供 JSONL 与 CSV（RFC 4180 转义，CRLF 行尾）两种结构化导出，含绑定抓取结果的页面行与接受任意字段对的通用记录行，核心零文件 IO 依赖，输出走 stdout 便于重定向落盘与管道处理；CLI 的 CSV 同样输出 CRLF，以 `#` 开头的行是统计/告警而非数据；

- 提供命令行入口 `mooncrawl`（moonbitlang/core/argparse）两种模式：页面模式输出每页元数据，采集模式经 `--container` 与 `--fields` 按选择器逐条提取记录，并把字段值中的相对链接自动展开为绝对 URL；

- 提供 95 个 MoonBit 测试并持续保持核心回归测试通过，其中引擎与调度用例全部离线运行（注入假 fetcher，不依赖网络与时钟）；GitHub Actions CI 在 js 与 native 双后端执行全量测试与 moon fmt 格式门禁（wasm-gc 不支持：引擎依赖的 moonbitlang/async/http 无 wasm 实现）；

- 提供 README 示例，覆盖库调用（规范化/展开/去重/robots/选择器/引擎）与 CLI 双模式的真实输出，以及架构图、模块-测试对照表与已知限制清单；并提供 docs/rfc9309-覆盖声明.md 作为 robots 处理的外部一致性证据。

---

## 附：本轮修改说明

针对上次审核意见的处置，技术实现与文档同步修改，均已提交并通过 CI：

- **查询参数排序不再作为资源等价依据**：默认保留 query 原始顺序，排序改为独立的显式 API `normalize_url_sorted_query`，函数名与文档说明启用前提；取舍（同一资源可能被抓两次）写入 README 已知限制第 1 条。

- **robots 处理从「协议子集」改为逐条对照 RFC 9309**：补齐 §2.2.1 多组匹配合并、§2.2.2 `/robots.txt` 隐式允许、§2.3.1.4 5xx 与网络错误默认完全禁止、UTF-8 BOM 剥离；新增 docs/rfc9309-覆盖声明.md，按 MUST/SHOULD 列出实现状态与对应测试。随后补齐 §2.2.2 的百分号比较与 §2.5 的 1 MiB 解析上限。**§2.2 与 §2.3.1 的 MUST 条款中有两项与字面不完全一致，已在覆盖声明 §1.1/§1.2 单列**：组选择采用「最长 token 优先」而非「全部匹配组合并」；百分号编码向只覆盖非 ASCII 字符、ASCII 保留字符不编码。未覆盖的 SHOULD 为字面星号匹配、重定向链与缓存时效。

- **项目定位调整为通用爬虫框架**：「声明式网页采集」不再是项目定位，降为提取层的可选特性——不配置选择器时就是普通爬虫，配置后才做字段采集。

- **补充自定义数据提取**：新增 CSS 选择器模块与字段映射（见核心功能范围第 10 条）。XPath 明确不做（README 已知限制第 11 条）：自研完整 XPath 语义的成本远高于 CSS 子集，而采集场景中 CSS 已覆盖绝大多数需求；若后续生态出现可复用的 XPath 实现，可另行接入，本项目不重复造这一层。

- **补充异步调度**：三阶段调度 + `max_concurrency`，`Frontier::pop_batch` 保证批内每 host 最多一个 URL，同 origin 严格串行、礼貌间隔不被并发绕过。

- **顺带修复 5 个实现缺陷**（均有测试覆盖）：① 礼貌调度把 64 位毫秒截断成 32 位，等待时长溢出导致 `sleep` 永不返回、抓取静默卡死（也是引擎测试在 js 后端无法完成的根因）；② robots 不可达时放行，违反 §2.3.1.4；③ 多个组匹配同一 UA 时未合并，违反 §2.2.1；④ `/robots.txt` 未隐式允许，违反 §2.2.2；⑤ robots.txt 未剥离 UTF-8 BOM，带 BOM 时整组规则失效。

- **开源合规**：Apache-2.0，LICENSE 全文入库；新增 NOTICE，列明第三方组件（moonbitlang/async、moonbit-community/html，均 Apache-2.0，Copyright 2025 International Digital Economy Academy）与所引用的规范（RFC 3986 / 9309 / 4180）；`.moonignore` 控制打包范围，参赛材料不随包分发。

- **正式验收反馈的修复（2026-11-07）**：① robots 路径匹配改为严格前缀语义，`Disallow: /` 配 `Allow: /public` 不再误放行 `/secret/public`（原实现把无 `*` 的模式当子串搜索）；② 路径规范化保留重复斜杠，只折叠点段，不再把 `/a//b` 改写成 `/a/b`；③ 默认传输层与引擎两侧都捕获异常，单页失败折叠为 `status=0 + error`，不再终止整次采集。三条均有回归测试（`regression_test.mbt`）。

- **已知限制**（完整清单共 15 条，见 README「已知限制」）：查询参数顺序与重复斜杠不折叠；布隆去重是概率性的，超容量后无法与真实重复区分（已有填充率指标与告警）；不限制站外链接；robots 组选择为最长 token 优先、无法匹配字面 `*`、1 MiB 上限只约束解析；`extract_records` 的字段选择器不能引用容器外祖先；不做 JS 渲染与 XPath；单机内存队列，不支持分布式调度；同 origin 串行；无请求重试。

- **验证**：`moon test` 95 个用例全部通过（默认 js 目标）；CI 三 job（js / native / fmt）全绿；包已发布到 mooncakes.io（`guangting0905/mooncrawl` v0.1.4，`build_status: success`；`moon add guangting0905/mooncrawl@0.1.4` 已在全新项目中安装，并实际调用 `Frontier::with_capacity`、`extract_base_href`、非 ASCII robots 匹配等新 API 验证）；真实站点 books.toscrape.com 端到端验证，页面模式 12 页全部 200、发现 1,089 个链接（复审修正后复跑，数字一致），采集模式按 CSS 选择器输出书目记录（含相对链接绝对化）。

- **第二轮复审修正（2026-11-07）**：上一轮之后又做了四类对抗性检查——不再只喂「顺利输入」，而是喂超规模、恶意规则和畸形语法。四处缺陷均已修复并有回归用例：
  ① **布隆去重容量写死 4096**（8 KiB），实测插入到第 2260 个唯一 URL 起开始把新链接误判为已见并静默丢弃，两万个 URL 丢 1954 个，而统计上看不出异常。改为容量可配（`Frontier::with_capacity`，默认 65536、`crawl` 按 `max_pages` 推算），新增 `saturation_permille()` 与 CLI 的 `# warning`。
  ② **robots 通配符匹配是指数回溯**：`glob_at` 对每个 `*` 做全位置递归，实测 8 个 `*` 耗时 100ms、12 个 2334ms、16 个超过 45 秒未返回——一条 34 字符的规则即可让抓取卡死。改为线性双指针（单点回溯），20 个 `*` 的规则重复判定 200 次仍在毫秒级。
  ③ **§2.2.2 的编码方向缺失**：只解码 unreserved、不编码非 ASCII，导致 `/café` 与 `/caf%C3%A9` 互不匹配（两侧都应视为同一路径）。已实现「非 ASCII → UTF-8 百分号编码 + 十六进制位大写」，双向匹配有测试。同时补上 §2.2.2「不属于任何组的裸规则 SHOULD 被忽略」——原实现把文件开头的裸规则兜底成 `*` 组，会意外扩大禁止范围。
  ④ **补 `<base href>` 支持**（相对链接基准，真实站点常见）、**主机名字符集校验**（`http://exa mple.com/x` 不再被当成合法地址）、**畸形选择器拒绝**（`> p`、`div >` 原会静默降级成 `p`/`div`）、**CSV 行尾修正**（CLI 原用 `trim()` 抹掉 CRLF，实际输出 LF）。

- **文档与代码对齐**：重写 `docs/rfc9309-覆盖声明.md`，把「组选择最长优先」「百分号编码向只做非 ASCII」两处标为**有意偏离**并给出可观测差异与理由；删掉 README 路线图里已实现的条目；修正 `robots.mbt` 文件头与函数注释相互矛盾之处；把「站外链接不设限」「容量不足无法区分真假重复」等新增到已知限制。
