// 抓取引擎的黑盒测试：注入假 fetcher，对内存中的"假站点"运行完整循环。

///|
fn fake_site(
  entries : Array[(String, @mooncrawl.FetchOutcome)],
) -> async (String, String) -> @mooncrawl.FetchOutcome {
  let site : Map[String, @mooncrawl.FetchOutcome] = Map([], capacity=16)
  for e in entries {
    let (k, v) = e
    let _ = site.set(k, v)
  }
  fn(url : String, _ua : String) -> @mooncrawl.FetchOutcome {
    match site.get(url) {
      Some(o) => o
      None => { status: 0, body: "", error: Some("no such page"), }
    }
  }
}

///|
fn ok(body : String) -> @mooncrawl.FetchOutcome {
  { status: 200, body, error: None, }
}

///|
const OPEN_ROBOTS = "User-agent: *\nDisallow:\n"

///|
async test "crawl: 假站点端到端——深度与统计" {
  let fetch = fake_site([
    ("https://fake.test/robots.txt", ok(OPEN_ROBOTS)),
    (
      "https://fake.test/",
      ok(
        "<html><head><title>Home</title></head><body><a href=\"/a\">A</a><a href=\"/b\">B</a></body></html>",
      ),
    ),
    (
      "https://fake.test/a",
      ok("<html><body><a href=\"/c\">C</a></body></html>"),
    ),
    ("https://fake.test/b", ok("<html><body>leaf</body></html>")),
    (
      "https://fake.test/c",
      ok("<html><body>never at depth 2 cap 1</body></html>"),
    ),
  ])
  let pages : Array[@mooncrawl.PageResult] = []
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 1,
      delay_ms: 0,
      respect_robots: true,
    },
    fetch,
    fn(p) { let _ = pages.push(p) },
  )
  // 深度 1 上限：种子 + /a + /b；/c 在深度 2 被发现但不入队
  assert_eq(stats.pages_fetched, 3)
  assert_eq(stats.pages_ok, 3)
  assert_eq(stats.pages_failed, 0)
  assert_eq(stats.links_discovered, 3)
  assert_eq(stats.pages_skipped_robots, 0)
  assert_eq(pages.length(), 3)
  assert_eq(pages[0].url, "https://fake.test/")
  assert_eq(pages[0].depth, 0)
  assert_eq(pages[0].title, Some("Home"))
  assert_eq(pages[0].links_found, 2)
  assert_eq(pages[1].url, "https://fake.test/a")
  assert_eq(pages[1].depth, 1)
  assert_eq(pages[2].url, "https://fake.test/b")
}

///|
async test "crawl: max_pages 截断" {
  let fetch = fake_site([
    ("https://fake.test/robots.txt", ok(OPEN_ROBOTS)),
    (
      "https://fake.test/",
      ok("<html><body><a href=\"/1\">1</a><a href=\"/2\">2</a></body></html>"),
    ),
    ("https://fake.test/1", ok("<html><body>x</body></html>")),
    ("https://fake.test/2", ok("<html><body>x</body></html>")),
  ])
  let pages : Array[@mooncrawl.PageResult] = []
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 2,
      max_depth: 2,
      delay_ms: 0,
      respect_robots: true,
    },
    fetch,
    fn(p) { let _ = pages.push(p) },
  )
  assert_eq(stats.pages_fetched, 2)
  assert_eq(pages.length(), 2)
}

///|
async test "crawl: robots 禁止的页面被跳过且不发请求" {
  let fetch = fake_site([
    ("https://fake.test/robots.txt", ok("User-agent: *\nDisallow: /b\n")),
    (
      "https://fake.test/",
      ok("<html><body><a href=\"/a\">a</a><a href=\"/b\">b</a></body></html>"),
    ),
    ("https://fake.test/a", ok("<html><body>ok</body></html>")),
    ("https://fake.test/b", ok("<html><body>secret</body></html>")),
  ])
  let pages : Array[@mooncrawl.PageResult] = []
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 1,
      delay_ms: 0,
      respect_robots: true,
    },
    fetch,
    fn(p) { let _ = pages.push(p) },
  )
  assert_eq(stats.pages_skipped_robots, 1)
  assert_eq(stats.pages_fetched, 2)
  // /b 的结果以 status=0 + error 记录
  let mut saw_skip : Bool = false
  for p in pages {
    match p.error {
      Some(e) =>
        if e == "disallowed by robots.txt" {
          saw_skip = true
          assert_eq(p.url, "https://fake.test/b")
        }
      None => ()
    }
  }
  assert_true(saw_skip)
}

///|
async test "crawl: robots 不可达时默认全禁（RFC 9309 §2.3.1.4）" {
  // robots.txt 缺失（fetch 返回错误）→ unreachable → 视为完全禁止
  let fetch = fake_site([
    ("https://fake.test/", ok("<html><body><a href=\"/a\">a</a></body></html>")),
    ("https://fake.test/a", ok("<html><body>ok</body></html>")),
  ])
  let pages : Array[@mooncrawl.PageResult] = []
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 1,
      delay_ms: 0,
      respect_robots: true,
    },
    fetch,
    fn(p) { let _ = pages.push(p) },
  )
  assert_eq(stats.robots_unreachable, 1)
  assert_eq(stats.pages_ok, 0)
  assert_eq(stats.pages_fetched, 0)
  assert_eq(stats.pages_skipped_unreachable, 1)
  assert_eq(pages.length(), 1)
  assert_true(pages[0].error is Some(_))
}

///|
async test "crawl: 显式 Allow 策略下 robots 不可达仍抓取" {
  let fetch = fake_site([
    ("https://fake.test/", ok("<html><body><a href=\"/a\">a</a></body></html>")),
    ("https://fake.test/a", ok("<html><body>ok</body></html>")),
  ])
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 1,
      delay_ms: 0,
      respect_robots: true,
      robots_unreachable: @mooncrawl.RobotsUnreachable::Allow,
    },
    fetch,
    fn(_p) { () },
  )
  assert_eq(stats.robots_unreachable, 1)
  assert_eq(stats.pages_ok, 2)
}

///|
async test "crawl: robots.txt 返回 4xx 视为无规则并放行" {
  let fetch = fake_site([
    ("https://fake.test/robots.txt", { status: 404, body: "", error: None, }),
    ("https://fake.test/", ok("<html><body>ok</body></html>")),
  ])
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 0,
      delay_ms: 0,
      respect_robots: true,
    },
    fetch,
    fn(_p) { () },
  )
  assert_eq(stats.robots_unreachable, 0)
  assert_eq(stats.pages_ok, 1)
}

///|
async test "crawl: robots.txt 返回 5xx 视为不可达并全禁" {
  let fetch = fake_site([
    (
      "https://fake.test/robots.txt",
      { status: 503, body: "busy", error: None, },
    ),
    ("https://fake.test/", ok("<html><body>ok</body></html>")),
  ])
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 0,
      delay_ms: 0,
      respect_robots: true,
    },
    fetch,
    fn(_p) { () },
  )
  assert_eq(stats.robots_unreachable, 1)
  assert_eq(stats.pages_ok, 0)
  assert_eq(stats.pages_skipped_unreachable, 1)
}

///|
async test "crawl: 关闭 robots 检查则直接抓取" {
  let fetch = fake_site([
    ("https://fake.test/robots.txt", ok("User-agent: *\nDisallow: /\n")),
    ("https://fake.test/", ok("<html><body>x</body></html>")),
  ])
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 0,
      delay_ms: 0,
      respect_robots: false,
    },
    fetch,
    fn(_p) { () },
  )
  assert_eq(stats.pages_ok, 1)
  assert_eq(stats.robots_unreachable, 0)
}

///|
async test "crawl: 跨页面同一链接只抓一次" {
  let fetch = fake_site([
    ("https://fake.test/robots.txt", ok(OPEN_ROBOTS)),
    (
      "https://fake.test/",
      ok("<html><body><a href=\"/c\">c</a><a href=\"/a\">a</a></body></html>"),
    ),
    (
      "https://fake.test/a",
      ok("<html><body><a href=\"/c\">c again</a></body></html>"),
    ),
    ("https://fake.test/c", ok("<html><body>once</body></html>")),
  ])
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 2,
      delay_ms: 0,
      respect_robots: true,
    },
    fetch,
    fn(_p) { () },
  )
  // /c 被种子和 /a 双双引用，只抓一次：种子 + /c + /a
  assert_eq(stats.pages_fetched, 3)
  assert_eq(stats.links_discovered, 3)
}

///|
async test "crawl: 传输失败计入 pages_failed 并产生 error 结果" {
  let fetch = fake_site([
    ("https://fake.test/robots.txt", ok(OPEN_ROBOTS)),
    (
      "https://fake.test/",
      ok("<html><body><a href=\"/boom\">b</a></body></html>"),
    ),
    // /boom 缺失
  ])
  let pages : Array[@mooncrawl.PageResult] = []
  let stats = @mooncrawl.crawl(
    "https://fake.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 1,
      delay_ms: 0,
      respect_robots: true,
    },
    fetch,
    fn(p) { let _ = pages.push(p) },
  )
  assert_eq(stats.pages_failed, 1)
  assert_eq(pages[1].status, 0)
  assert_eq(pages[1].error, Some("no such page"))
}

///|
async test "crawl: 非法种子返回全零统计" {
  let fetch = fake_site([])
  let stats = @mooncrawl.crawl(
    "not-a-url",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 1,
      delay_ms: 0,
      respect_robots: true,
    },
    fetch,
    fn(_p) { () },
  )
  assert_eq(stats.pages_fetched, 0)
  assert_eq(stats.links_discovered, 0)
}

///|
/// 多 host 假站点：种子在 a.test，链接到 b.test 与 c.test。
/// 抓取时记录同时在途的请求数峰值，用来验证并行度。
async fn multi_host_peak(concurrency : Int32) -> (Int32, Bool) {
  let active = [0]
  let peak = [0]
  // 每个任务必须拿到自己的 URL：闭包若按引用捕获循环变量，这里会露馅
  let hits = [false, false, false]
  let fetch = async fn(url : String, _ua : String) -> @mooncrawl.FetchOutcome {
    active[0] = active[0] + 1
    if active[0] > peak[0] {
      peak[0] = active[0]
    }
    @async.sleep(10)
    active[0] = active[0] - 1
    if url == "https://b.test/" {
      hits[1] = true
    }
    if url == "https://c.test/" {
      hits[2] = true
    }
    if url == "https://a.test/" {
      hits[0] = true
      return {
        status: 200,
        body: "<html><body><a href=\"https://b.test/\">b</a>" +
        "<a href=\"https://c.test/\">c</a></body></html>",
        error: None,
      }
    }
    if url == "https://b.test/robots.txt" || url == "https://c.test/robots.txt" {
      return { status: 200, body: OPEN_ROBOTS, error: None, }
    }
    { status: 200, body: "<html><body>leaf</body></html>", error: None, }
  }
  let stats = @mooncrawl.crawl(
    "https://a.test/",
    {
      ..@mooncrawl.CrawlOptions::default(),
      max_pages: 10,
      max_depth: 1,
      delay_ms: 0,
      max_concurrency: concurrency,
    },
    fetch,
    fn(_p) { () },
  )
  assert_eq(stats.pages_ok, 3)
  (peak[0], hits[0] && hits[1] && hits[2])
}

///|
async test "crawl: 跨 host 并行且每个任务拿到自己的 URL" {
  let (peak, all_hit) = multi_host_peak(3)
  assert_true(peak >= 2)
  assert_true(all_hit)
}

///|
async test "crawl: max_concurrency=1 时完全串行" {
  let (peak, all_hit) = multi_host_peak(1)
  assert_eq(peak, 1)
  assert_true(all_hit)
}
