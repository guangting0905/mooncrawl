// MoonCrawl — MoonBit 的网页爬虫框架。
//
// 根包包含采集流水线的全部实现：
// - url.mbt      : URL 解析、规范化（默认保留查询参数顺序）与相对地址展开
// - bloom.mbt    : 位打包布隆过滤器，用于已见 URL 去重
// - robots.mbt   : robots.txt 解析与 RFC 9309 匹配、Crawl-delay
// - frontier.mbt : URL 前沿队列，按 host 分流以支撑并发调度
// - extract.mbt  : HTML 基础提取（链接 / 标题 / 正文）
// - selector.mbt : CSS 选择器子集与字段映射
// - export.mbt   : JSONL / CSV 导出
// - crawl.mbt    : 异步抓取引擎（三阶段调度）
// - fetch_http.mbt : 基于 moonbitlang/async/http 的默认传输层
//
// 后端：js 与 native 均可构建与测试（CI 双目标验证）。wasm-gc 不支持——
// 引擎依赖的 moonbitlang/async/http 目前没有 wasm 实现，`@http.get` 不存在。
// 命令行走 cmd/main。
