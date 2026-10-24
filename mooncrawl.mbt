// MoonCrawl — 纯 MoonBit 的声明式网页采集框架。
//
// 根包当前包含两个纯逻辑核心模块：
// - url.mbt   : URL 解析、规范化与相对地址展开（抓取去重的前置）。
// - bloom.mbt : 布隆过滤器，用于大规模已抓取 URL 的去重。
//
// 网络抓取（基于 moonbitlang/async）、robots 协议、HTML 解析管道与
// 结构化导出将在后续版本加入，见 README 路线图。
