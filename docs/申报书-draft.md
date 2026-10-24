# 项目申报书（终稿）

> 提交飞书报名表时按字段拆填；本文件为内容底稿。

## 项目名称

MoonCrawl —— 纯 MoonBit 的声明式网页采集框架

## GitHub 仓库

https://github.com/guangting0905/mooncrawl

## 一句话介绍

把「抓网页 → 提数据 → 出结果」做成一条可配置流水线：URL 规范化去重、
robots 遵守、按站点礼貌限速、HTML 解析管道、JSONL/CSV 导出，
全部以 MoonBit 为主要实现语言，52 个离线测试 + 双后端 CI 门禁。

## 背景与动机

- MoonBit 生态的 HTTP 客户端（moonbitlang/async）、HTML 解析
  （moonbit-community/html）、robots/CSV 等积木已就位，但缺少把它们
  串成可用采集流水线的框架层（查重见 docs/查重报告.md）。
- 数据采集是数据分析、AI 语料构建、监控告警的第一公里，
  边界清晰、可验证，且能充分展示 MoonBit 的工程能力。

## 交付内容（10 月赛，全部完成）

| 模块 | 亮点 | 测试 |
| --- | --- | --- |
| URL 解析/规范化/相对展开 | RFC 3986 子集；等价书写折叠；UTF-16 语义正确处理 | 12 |
| 布隆过滤器 | 16 bit/元素 + 7 哈希，误报约 0.06%，内存可控 | 2 |
| robots.txt | RFC 9309 实用子集：分组最长匹配、通配、Crawl-delay、Sitemap | 12 |
| frontier | 游标式 FIFO（无 shift 退化）、按 host 间隔推算 | 6 |
| async 引擎 | 深度/页数上限、origin 礼貌限速、robots 集成、统计；传输层可注入 | 8 |
| HTML 提取 | 链接/标题/正文，跳过 script/style，实体解码 | 5 |
| 导出 | CSV（RFC 4180）、JSONL（控制字符转义）；核心零文件 IO 依赖 | 7 |
| 传输层 | moonbitlang/async/http：30s 超时、UA 透传、错误折叠 | — |
| CLI | argparse：4 选项 + seed；stdout 管道友好 | — |

**合计 52 个测试，全部离线可复现**（引擎对内存假站点运行，不依赖网络与时钟）。

## 真实站点验证

```
$ moon run cmd/main --target js -- https://books.toscrape.com/ --max-pages 12 --depth 1
{"url":"https://books.toscrape.com/","status":200,"depth":0,"links_found":94,"title":"All products | Books to Scrape - Sandbox"}
...（共 12 条）
# pages_fetched=12 ok=12 failed=0 robots_skipped=0 links=1089 robots_unreachable=0
```

## 工程实践（对标季度/年度评审）

- **持续提交**：9 个功能 commit，每个标注测试数并关联 Issue；
  立项时建 10 个 Issue 看板，8 个随里程碑关闭并附交付说明。
- **双目标 CI**：GitHub Actions 在 js 与 native 后端全量测试
  + `moon fmt` 格式门禁，首跑即绿。
- **接口可查**：`moon info` 生成的 `.mbti` 接口文件入库。
- **AI 可解释**：AI 辅助编码，架构设计、查重、测试验收与代码审查由本人负责；
  全部决策过程留痕于 Issue 与 commit。

## 与已有工作的区别

- 不重复造轮子：复用官方 async 运行时与社区 HTML 解析，
  提供生态空白的「策略与调度」框架层（查重 0 命中，见 docs/查重报告.md）。
- 规范化优先是核心差异点：去重失败大多源于 URL 等价形式未折叠。
- 可测试性是第二差异点：传输层注入让爬虫框架可以离线确定性测试。

## 验收对照（官方标准 → 本项目）

| 官方验收标准 | 本项目落实 |
| --- | --- |
| MoonBit 为主 | 全部核心代码为 MoonBit |
| 仓库公开、持续提交 | github.com/guangting0905/mooncrawl，9+ commits，Issue 全程留痕 |
| 能运行 | CLI 真实站点演示 + README 可复现命令 + 52 测试 |
| 实质新增 | 8 个模块全部本期实现 |
| 开源合规 | Apache-2.0；依赖均为 Apache-2.0 并在 moon.mod 声明 |
| AI 可解释 | 决策、架构、验收过程在 Issue/commit 中可追溯 |

## 团队

单人（guangting0905）。

## 后续计划（季度/年度持续建设）

跨 origin 并行调度、声明式提取规则 DSL（CSS 选择器 → 字段映射）、
Sitemap 发现与优先级队列、mooncakes 上架与 native 二进制发布。
