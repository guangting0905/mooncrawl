# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

## 本项目的约定

- **包结构**：根包 `guangting0905/mooncrawl` 同时包含纯逻辑模块（URL、去重、
  robots、frontier、提取、选择器、导出）与异步引擎（`crawl.mbt`、
  `fetch_http.mbt`）；`cmd/main` 是 CLI。
- **后端边界**：根包 import `moonbitlang/async` 与 `async/http`，因此只支持
  **js 与 native**。wasm-gc 不可用（`async/http` 无 wasm 实现）。若将来要把
  纯逻辑模块提供给 wasm 用户，需要把引擎拆成子包，不要靠改文档掩盖。
- **测试分层**：`*_test.mbt` 只打公开 API；引擎用注入的假 fetcher 做离线
  端到端，断言统计与回调内容，不依赖网络与真实时钟。
- **文档同步**：改动 URL 规范化策略或 robots 行为时，必须同步
  `docs/rfc9309-覆盖声明.md` 与 README 的「已知限制」，不允许只改代码。
