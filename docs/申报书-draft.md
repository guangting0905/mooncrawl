# 项目申报书（MoonCrawl）

> 按官方申报书样本格式撰写；联系方式留占位符，提交飞书表单前补齐。

## 基本信息

- **项目名称**：MoonCrawl：MoonBit 的声明式网页采集框架
- **参赛者**：guangting0905
- **联系方式**：【提交前填写：手机号/微信】
- **GitHub 仓库链接**：https://github.com/guangting0905/mooncrawl.git
- **项目方向**：MoonBit 数据采集基础库 / 数据处理基础设施
- **是否为移植项目**：否（原创实现；复用 moonbitlang/async、moonbit-community/html 等生态积木，均已按 Apache-2.0 声明）

## 项目简介

MoonCrawl 为 MoonBit 生态提供可复用的网页采集（爬虫）框架，面向需要在
MoonBit 中做数据采集、语料构建、监控与分析的库作者、工具开发者和应用开发者，
提供 URL 解析与规范化、布隆过滤器去重、robots.txt 协议遵守、按站点礼貌限速、
异步抓取引擎、HTML 链接/标题/正文提取以及 JSONL/CSV 结构化导出的完整流水线。
MoonBit 生态已有 HTTP 客户端与 HTML 解析等积木，但缺少把它们串成采集流水线的
框架层——MoonCrawl 补齐的正是这一空白（申报前已按章程完成查重，
mooncakes.io 全量 3,265 个模块中爬虫框架方向 0 命中，详见 docs/查重报告.md）。

## 核心功能范围

- 提供 URL 解析、规范化与相对地址展开（RFC 3986 实用子集）：scheme/host 小写化、
  默认端口省略、点段折叠、query 参数排序、fragment 剥离，等价书写形式折叠为
  同一字符串，支持正确处理 UTF-16 码元语义；

- 提供布隆过滤器去重模块（每元素 16 bit、7 哈希、误报率约 0.06%），支撑
  十万级 URL 的内存可控去重；

- 提供 robots.txt 解析与匹配（RFC 9309 实用子集）：User-agent 分组最长前缀匹配、
  Allow/Disallow 最长模式优先、`*` 与 `$` 通配、Crawl-delay 毫秒化解析、
  Sitemap 收集，以及按 path+query 的 `allowed_url` 便捷判定；

- 提供 URL 前沿队列（frontier）：游标式 FIFO（无大数组 shift 退化）、
  已见去重整合、按 host 的请求间隔推算；

- 提供异步抓取引擎 `crawl(...)`：深度与页数上限、按 origin 记账的礼貌限速
  （robots Crawl-delay 自动抬高间隔）、robots 不可达的容错回退、
  pages_fetched/ok/failed/skipped/links 等统计计数；

- 提供可注入传输层（FetchFn 闭包）与默认实现 `http_fetch`（基于
  moonbitlang/async/http：30 秒超时、User-Agent 透传、错误统一折叠），
  引擎可在无网络、无时钟依赖的离线环境下对假站点确定性测试；

- 提供 HTML 提取模块（基于 moonbit-community/html）：`<a href>` 链接按文档
  顺序收集、`<title>` 提取（实体解码、去首尾空白）、正文文本提取
  （跳过 script/style/noscript 子树并折叠空白）；

- 提供 JSONL 与 CSV（RFC 4180 转义）两种结构化导出，核心零文件 IO 依赖，
  输出走 stdout 便于重定向落盘与管道处理；

- 提供命令行入口 `mooncrawl`（moonbitlang/core/argparse）：seed URL +
  --max-pages / --depth / --delay-ms / --format 四个选项；

- 已通过真实站点端到端验证（books.toscrape.com：12 页全部 200、
  发现 1,089 个链接、robots 全程遵守），并在 README 提供一键复现命令；

- 提供 52 个 MoonBit 测试并持续保持核心回归测试通过；GitHub Actions CI
  在 js 与 native 双后端执行全量测试与 moon fmt 格式门禁；

- 提供 README 示例，覆盖库调用（规范化/展开/去重/robots/引擎）与 CLI 使用，
  以及架构图与模块-测试对照表。
