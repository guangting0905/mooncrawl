// 正式验收反馈的回归用例。
//
// 三条缺陷都属于「实现与 RFC 语义不符、不会报错、只会静默改变行为」，
// 因此都要在这里钉住：
// 1) robots 把无 `*` 的模式当子串搜索，Allow 会误放行路径中段的匹配
// 2) 路径规范化折叠重复斜杠，改写了请求目标
// 3) 传输层抛异常会终止整次采集，而不是记为该页失败

///|
test "regression: Allow 规则不得匹配路径中段" {
  let r = @mooncrawl.parse_robots(
    "User-agent: *\nDisallow: /\nAllow: /public\n",
  )
  // /secret/public 不以 /public 开头，必须仍被 Disallow: / 拦住
  assert_true(!r.allowed("ua", "/secret/public"))
  // 真正以 /public 开头的路径应当放行（更长的 Allow 胜出）
  assert_true(r.allowed("ua", "/public"))
  assert_true(r.allowed("ua", "/public/x"))
  // Disallow 同样是前缀语义，不能命中路径中段
  let r2 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /private\n")
  assert_true(r2.allowed("ua", "/x/private"))
  assert_true(!r2.allowed("ua", "/private/a"))
}

///|
test "regression: 重复斜杠不被折叠，点段仍折叠" {
  let u = @mooncrawl.parse_url("https://example.com/a//b").unwrap()
  inspect(@mooncrawl.normalize_url(u), content="https://example.com/a//b")
  let v = @mooncrawl.parse_url("https://example.com/a/./b").unwrap()
  inspect(@mooncrawl.normalize_url(v), content="https://example.com/a/b")
  // 空段参与 `..` 折叠，结果与 RFC 3986 remove_dot_segments 一致
  let w = @mooncrawl.parse_url("https://example.com/a//../b").unwrap()
  inspect(@mooncrawl.normalize_url(w), content="https://example.com/a/b")
  // 结尾斜杠语义保留
  let x = @mooncrawl.parse_url("https://example.com/dir//").unwrap()
  inspect(@mooncrawl.normalize_url(x), content="https://example.com/dir//")
}

///|
async test "regression: 传输层抛异常不终止采集" {
  let fetch = async fn(url : String, _ua : String) -> @mooncrawl.FetchOutcome {
    @async.pause()
    if url == "https://fake.test/robots.txt" {
      return { status: 200, body: "User-agent: *\nDisallow:\n", error: None, }
    }
    if url == "https://fake.test/" {
      return {
        status: 200,
        body: "<html><body><a href=\"/a\">a</a><a href=\"/b\">b</a></body></html>",
        error: None,
      }
    }
    fail("simulated transport failure")
  }
  let pages : Array[@mooncrawl.PageResult] = []
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 1,
      delay_ms: 0,
    },
    fetch,
    fn(p) { let _ = pages.push(p) },
  )
  // 种子成功；/a 与 /b 各抛一次，折叠为单页失败
  assert_eq(stats.pages_ok, 1)
  assert_eq(stats.pages_failed, 2)
  assert_eq(pages.length(), 3)
  // 失败结果带 error，而不是异常冒到调用方
  let mut failed_with_error : Int32 = 0
  for p in pages {
    if p.error is Some(_) {
      failed_with_error = failed_with_error + 1
    }
  }
  assert_eq(failed_with_error, 2)
}
