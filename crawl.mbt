// 抓取引擎：种子 → 规范化 → robots 检查 → origin 礼貌限速 → 抓取 →
// 链接提取 → 入队，直至页数/深度上限或队列耗尽。
//
// 传输层与结果消费都是注入点：fetch 闭包让引擎可以在测试里对假站点
// 运行（无网络依赖），真实抓取由 fetch_http 提供实现。
// 礼貌策略按 origin（scheme://host[:port]）记账：robots.txt 与页面
// 请求共用同一时间表；robots 的 Crawl-delay 会抬高对应 origin 的间隔。
//
// robots.txt 的状态码语义按 RFC 9309 §2.3.1 处理：
// - 2xx：解析并执行（§2.3.1.1）
// - 4xx：视为 unavailable，允许访问该服务器资源（§2.3.1.3）
// - 5xx 或网络错误：视为 unreachable，默认完全禁止（§2.3.1.4）；
//   需要旧版「不可达即放行」行为的调用方显式选择 RobotsUnreachable::Allow。

///|
/// 单页抓取结果。status=0 表示传输失败或被策略跳过，具体原因见 error。
pub(all) struct PageResult {
  url : String // 规范化后的请求 URL
  status : Int32 // HTTP 状态码；0 表示未完成传输
  depth : Int32 // 距种子的跳数（种子为 0）
  links_found : Int32 // 本页发现的合法站内链接数（已解析，去重前）
  title : String?
  body : String? // 仅在 CrawlOptions::keep_body 为真时填充
  error : String?
}

///|
/// robots.txt 不可达（5xx 或网络错误）时的策略。
pub(all) enum RobotsUnreachable {
  /// RFC 9309 §2.3.1.4 的强制行为：视为完全禁止。
  Disallow
  /// 旧版惯例：视为允许抓取。非规范行为，仅用于目标站点长期无
  /// robots.txt 且明确接受风险的场景。
  Allow
}

///|
/// 抓取配置。
pub(all) struct CrawlOptions {
  max_pages : Int32 // 最多抓取的页面数（含失败）
  max_depth : Int32 // 最大深度（种子为 0，链接为其子深度）
  delay_ms : Int32 // 同 origin 两次请求的最小间隔；robots Crawl-delay 可抬高
  max_concurrency : Int32 // 跨 origin 并行度；同 origin 始终串行。1 = 完全串行
  respect_robots : Bool
  robots_unreachable : RobotsUnreachable // 见枚举说明
  keep_body : Bool // 是否把响应正文放进 PageResult（采集场景需要）
  user_agent : String
}

///|
pub fn CrawlOptions::default() -> CrawlOptions {
  {
    max_pages: 50,
    max_depth: 2,
    delay_ms: 1000,
    max_concurrency: 4,
    respect_robots: true,
    robots_unreachable: Disallow,
    keep_body: false,
    user_agent: "MoonCrawl/0.1 (+https://github.com/guangting0905/mooncrawl)",
  }
}

///|
/// 传输层结果：所有失败折叠进 error 字段，引擎不感知传输细节。
pub(all) struct FetchOutcome {
  status : Int32 // HTTP 状态码；传输失败为 0
  body : String
  error : String?
}

///|
/// 抓取统计。
pub struct CrawlStats {
  mut pages_fetched : Int32 // 已抓取页面数（不含 robots.txt）
  mut pages_ok : Int32
  mut pages_failed : Int32
  mut pages_skipped_robots : Int32 // 被 robots 规则拒绝的页面数
  mut pages_skipped_unreachable : Int32 // 因 robots 不可达被拒的页面数
  mut links_discovered : Int32
  mut robots_unreachable : Int32 // robots.txt 不可达（5xx/网络错误）的 origin 数
}

///|
fn CrawlStats::new() -> CrawlStats {
  {
    pages_fetched: 0,
    pages_ok: 0,
    pages_failed: 0,
    pages_skipped_robots: 0,
    pages_skipped_unreachable: 0,
    links_discovered: 0,
    robots_unreachable: 0,
  }
}

///|
fn origin_of(u : Url) -> String {
  let buf = StringBuilder()
  buf.write_string(u.scheme)
  buf.write_string("://")
  buf.write_string(u.host)
  match u.port {
    Some(p) =>
      if !is_default_port(u.scheme, p) {
        buf.write_string(":")
        buf.write_string(p.to_string())
      }
    None => ()
  }
  buf.to_string()
}

///|
/// 礼貌调度状态：按 origin 记录最近请求时刻与生效间隔。
///
/// 时刻一律用 Int64 毫秒。`@async.now()` 返回 64 位毫秒，若截断成 32 位，
/// 差值在回绕处会算出巨大的等待时长（表现为抓取卡死），必须全程保留宽度。
priv struct Politeness {
  last_visit : Map[String, Int64]
  delay : Map[String, Int32] // origin -> robots Crawl-delay 抬高后的间隔
  base_ms : Int32
}

///|
fn Politeness::new(base_ms : Int32) -> Politeness {
  { last_visit: Map([], capacity=64), delay: Map([], capacity=16), base_ms, }
}

///|
fn Politeness::delay_of(self : Politeness, origin : String) -> Int32 {
  match self.delay.get(origin) {
    Some(d) => d
    None => self.base_ms
  }
}

///|
/// 该 origin 最早允许发起下一次请求的时刻。
fn Politeness::next_allowed(
  self : Politeness,
  origin : String,
  now_ms : Int64,
) -> Int64 {
  let delay = self.delay_of(origin).to_int64()
  let earliest = match self.last_visit.get(origin) {
    Some(last) => last + delay
    None => 0L
  }
  if now_ms > earliest {
    now_ms
  } else {
    earliest
  }
}

///|
/// 若需等待则挂起至允许时刻，然后登记本次访问。
async fn Politeness::gate(self : Politeness, origin : String) -> Unit {
  let now = @async.now()
  let t = self.next_allowed(origin, now)
  if t > now {
    @async.sleep((t - now).to_int())
  }
  let _ = self.last_visit.set(origin, @async.now())
}

///|
/// 引擎主循环：按批取待抓 URL，批内跨 host 并行、同 host 严格串行。
///
/// 三阶段结构让并发不污染共享状态：
/// 1. 串行：robots 加载与准入判定（会修改 robots 缓存、统计、blocked）；
/// 2. 并行：对通过准入的 URL 按 origin 礼貌等待后抓取（只读共享状态）；
/// 3. 串行：处理抓取结果、提取链接、入队、统计与回调。
///
/// `max_concurrency = 1` 时退化为完全串行，行为与单请求循环一致。
/// 无效种子返回全零统计。
pub async fn crawl(
  seed : String,
  options : CrawlOptions,
  fetch : async (String, String) -> FetchOutcome,
  on_page : (PageResult) -> Unit,
) -> CrawlStats {
  let stats = CrawlStats::new()
  let seed_url = match parse_url(seed) {
    Some(u) => u
    None => return stats
  }
  let seed_norm = normalize_url(seed_url)
  let frontier = Frontier::new(options.delay_ms)
  let depths : Map[String, Int32] = Map([], capacity=256)
  let robots_map : Map[String, RobotsRules] = Map([], capacity=16)
  let robots_tried : Map[String, Bool] = Map([], capacity=16)
  // robots 不可达且策略为 Disallow 的 origin：其下所有页面一律不发请求
  let blocked : Map[String, Bool] = Map([], capacity=16)
  let polite = Politeness::new(options.delay_ms)
  let _ = frontier.push(seed_norm)
  let _ = depths.set(seed_norm, 0)
  let concurrency = if options.max_concurrency < 1 {
    1
  } else {
    options.max_concurrency
  }
  let mut fetched : Int32 = 0
  while fetched < options.max_pages {
    let batch = frontier.pop_batch(concurrency)
    if batch.length() == 0 {
      break
    }
    // ---- 阶段 1（串行）：robots 加载 + 准入判定 ----
    let ready_urls : Array[String] = []
    let ready_origins : Array[String] = []
    let ready_depths : Array[Int32] = []
    for url in batch {
      if fetched + ready_urls.length() >= options.max_pages {
        break
      }
      let u = match parse_url(url) {
        Some(u) => u
        None => continue
      }
      let depth = match depths.get(url) {
        Some(d) => d
        None => 0
      }
      let origin = origin_of(u)
      // robots（每个 origin 只取一次）
      if options.respect_robots && robots_tried.get(origin) is None {
        let robots_url = origin + "/robots.txt"
        polite.gate(origin)
        let out = fetch(robots_url, options.user_agent)
        let _ = robots_tried.set(origin, true)
        let robots_down = match out.error {
          Some(_) => true
          None => out.status == 0 || (out.status >= 500 && out.status <= 599)
        }
        if robots_down {
          // RFC 9309 §2.3.1.4：robots.txt 未定义 → 视为完全禁止
          stats.robots_unreachable = stats.robots_unreachable + 1
          if options.robots_unreachable is Disallow {
            let _ = blocked.set(origin, true)
          }
        } else if out.status >= 400 && out.status <= 499 {
          // §2.3.1.3 unavailable：无规则适用，允许访问
        } else {
          let rules = parse_robots(out.body)
          match rules.crawl_delay_ms(options.user_agent) {
            Some(d) =>
              if d > polite.delay_of(origin) {
                let _ = polite.delay.set(origin, d)
              }
            None => ()
          }
          let _ = robots_map.set(origin, rules)
        }
      }
      if options.respect_robots {
        let mut skip : String? = None
        match blocked.get(origin) {
          Some(_) => {
            stats.pages_skipped_unreachable = stats.pages_skipped_unreachable +
              1
            skip = Some("robots.txt unreachable: disallowed by policy")
          }
          None =>
            match robots_map.get(origin) {
              Some(rules) =>
                if !rules.allowed_url(options.user_agent, u) {
                  stats.pages_skipped_robots = stats.pages_skipped_robots + 1
                  skip = Some("disallowed by robots.txt")
                }
              None => ()
            }
        }
        match skip {
          Some(reason) => {
            on_page({
              url,
              status: 0,
              depth,
              links_found: 0,
              title: None,
              body: None,
              error: Some(reason),
            })
            continue
          }
          None => ()
        }
      }
      ready_urls.push(url)
      ready_origins.push(origin)
      ready_depths.push(depth)
    }
    if ready_urls.length() == 0 {
      continue
    }
    // ---- 阶段 2（并行）：跨 origin 抓取；同 origin 在批内最多一个 ----
    let tasks : Array[async () -> FetchOutcome] = []
    let n_ready : Int32 = ready_urls.length()
    let mut k : Int32 = 0
    while k < n_ready {
      let url = ready_urls[k]
      let origin = ready_origins[k]
      tasks.push(async fn() -> FetchOutcome {
        polite.gate(origin)
        fetch(url, options.user_agent)
      })
      k = k + 1
    }
    let outcomes = @async.all(tasks)
    // ---- 阶段 3（串行）：结果处理、链接提取、入队与统计 ----
    let mut i : Int32 = 0
    while i < n_ready {
      let url = ready_urls[i]
      let depth = ready_depths[i]
      let out = outcomes[i]
      i = i + 1 // 先自增：下面的 continue 分支不会漏掉推进
      fetched = fetched + 1
      stats.pages_fetched = stats.pages_fetched + 1
      match out.error {
        Some(e) => {
          stats.pages_failed = stats.pages_failed + 1
          on_page({
            url,
            status: 0,
            depth,
            links_found: 0,
            title: None,
            body: None,
            error: Some(e),
          })
          continue
        }
        None => ()
      }
      stats.pages_ok = stats.pages_ok + 1
      let u = match parse_url(url) {
        Some(u) => u
        None => continue
      }
      let links = extract_links(out.body)
      let mut discovered : Int32 = 0
      for href in links {
        match resolve_url(u, href) {
          Some(child) => {
            let child_norm = normalize_url(child)
            discovered = discovered + 1
            if depth + 1 <= options.max_depth {
              if frontier.push(child_norm) {
                let _ = depths.set(child_norm, depth + 1)
              }
            }
          }
          None => ()
        }
      }
      stats.links_discovered = stats.links_discovered + discovered
      on_page({
        url,
        status: out.status,
        depth,
        links_found: discovered,
        title: extract_title(out.body),
        body: if options.keep_body {
          Some(out.body)
        } else {
          None
        },
        error: None,
      })
    }
  }
  stats
}
