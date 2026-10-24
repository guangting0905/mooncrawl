# MoonCrawl 🕷️🥮

**纯 MoonBit 的声明式网页采集框架** —— 2026 MoonBit 黑客松 10 月赛参赛项目。

MoonCrawl 把「抓网页 → 提数据 → 出结果」变成一条可配置的流水线：
URL 规范化与去重、robots 协议遵守、限速并发抓取、HTML 解析管道、
结构化导出（CSV / JSONL），全部用 MoonBit 实现。

## 为什么做这个

爬虫是数据采集的第一公里。MoonBit 生态里 HTTP 客户端（`moonbitlang/async`、
`moonbitstack/moonfetch`）、HTML 解析（`moonbit-community/html`）、robots 解析
（`moonbit-robots` 等 4 个库）、CSV 导出（`moonbit-community/NyaCSV`）这些
**积木已经齐了，但把它们串成可用采集流水线的框架层是空白的**。
MoonCrawl 不重复造轮子，而是做那层「胶水 + 策略」：

- **规范化优先**：同一资源的多种书写形式（大小写 / 默认端口 / 点段 /
  参数顺序 / fragment）折叠为同一 URL，去重才不会失效。
- **Polite by default**：robots.txt、限速、并发上限是一等公民。
- **纯 MoonBit**：可编译到 native / wasm，便于沙箱化运行。

## 查重声明

立项前已完成查重，详见 [docs/查重报告.md](docs/查重报告.md)。要点：

- mooncakes.io 全部 3,265 个模块中，`crawl / spider / scrape / scraper`
  相关命名 **0 命中**；
- awesome-moonbit 官方清单无同类项目；
- GitHub 上 MoonBit 语言仓库无同类框架；
- 2026 年 9 月黑客松 22 个社区参赛项目无同类选题。

## 快速开始

```bash
# 安装 moon 后，在项目根目录：
moon run cmd/main --target js      # URL 规范化演示
moon test --target js              # 14 个测试
```

代码示例（当前已发布的能力）：

```moonbit
let u = @mooncrawl.parse_url("HTTP://Example.COM:80/a/./b?b=2&a=1#top").unwrap()
println(@mooncrawl.normalize_url(u))
// => http://example.com/a/b?a=1&b=2

let base = @mooncrawl.parse_url("https://example.com/a/b/index.html").unwrap()
let next = @mooncrawl.resolve_url(base, "page2.html").unwrap()
println(@mooncrawl.normalize_url(next))
// => https://example.com/a/b/page2.html
```

## 路线图（10 月赛一周冲刺）

| 天 | 里程碑 | 状态 |
| --- | --- | --- |
| D1 (10/24) | 项目立项、URL 解析/规范化/相对展开、布隆去重、14 个测试 | ✅ |
| D2 (10/25) | robots.txt 解析与缓存、URL 前沿队列（frontier） | ⬜ |
| D3 (10/26) | 基于 `moonbitlang/async` 的抓取循环：限速、重试、超时 | ⬜ |
| D4 (10/27) | 集成 HTML 解析提取链接与正文，深度/广度控制 | ⬜ |
| D5 (10/28) | 结构化导出 CSV/JSONL、并发调度、示例：爬取公开站点 | ⬜ |
| D6 (10/29) | 文档与演示完善、发布到 mooncakes.io | ⬜ |
| D7 (10/30-31) | 验收材料、缓冲 | ⬜ |

## 设计

```
Seeds ──▶ Frontier(队列) ──▶ Scheduler(限速/并发/robots)
              ▲                       │
              │ Bloom(已见去重)        ▼
              │                  Fetcher(async HTTP)
              │                       │
              ▼                       ▼
        URL 规范化 ◀──────────── HTML 解析管道
                                      │
                                      ▼
                          提取器(链接/正文/字段) ──▶ 导出(CSV/JSONL)
```

核心模块：

- `url.mbt` — URL 解析、规范化（RFC 3986 子集）、相对地址展开
- `bloom.mbt` — 布隆过滤器（每元素 16 bit / 7 哈希，误报率约 0.06%）

## 开源合规

Apache-2.0 许可证。项目为原创实现；后续若集成第三方 MoonBit 库，
均按其许可证在 README 中注明来源。

## 作者

guangting0905 · 2026 MoonBit 黑客松 10 月赛
