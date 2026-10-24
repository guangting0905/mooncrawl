// 抓取引擎：种子 → 规范化 → robots 检查 → origin 礼貌限速 → 抓取 →
// 链接提取 → 入队，直至页数/深度上限或队列耗尽。
//
// 传输层与结果消费都是注入点：fetch 闭包让引擎可以在测试里对假站点
// 运行（无网络依赖），真实抓取由 fetch_http 提供实现。
// 礼貌策略按 origin（scheme://host[:port]）记账：robots.txt 与页面
// 请求共用同一时间表；robots 的 Crawl-delay 会抬高对应 origin 的间隔。

///|
/// 单页抓取结果。status=0 表示传输失败或被策略跳过，具体原因见 error。
pub(all) struct PageResult {
  url : String // 规范化后的请求 URL
  status : Int32 // HTTP 状态码；0 表示未完成传输
  depth : Int32 // 距种子的跳数（种子为 0）
  links_found : Int32 // 本页发现的合法站内链接数（已解析，去重前）
  title : String?
  error : String?
}

///|
/// 抓取配置。
pub(all) struct CrawlOptions {
  max_pages : Int32 // 最多抓取的页面数（含失败）
  max_depth : Int32 // 最大深度（种子为 0，链接为其子深度）
  delay_ms : Int32 // 同 origin 两次请求的最小间隔；robots Crawl-delay 可抬高
  respect_robots : Bool
  user_agent : String
}

///|
pub fn CrawlOptions::default() -> CrawlOptions {
  {
    max_pages: 50,
    max_depth: 2,
    delay_ms: 1000,
    respect_robots: true,
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
  mut pages_skipped_robots : Int32
  mut links_discovered : Int32
  mut robots_unreachable : Int32 // robots.txt 抓取失败的 origin 数
}

///|
fn CrawlStats::new() -> CrawlStats {
  {
    pages_fetched: 0,
    pages_ok: 0,
    pages_failed: 0,
    pages_skipped_robots: 0,
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
priv struct Politeness {
  last_visit : Map[String, Int32]
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
  now_ms : Int32,
) -> Int32 {
  let earliest = match self.last_visit.get(origin) {
    Some(last) => last + self.delay_of(origin)
    None => 0
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
  let now = @async.now().to_int()
  let t = self.next_allowed(origin, now)
  if t > now {
    @async.sleep(t - now)
  }
  let _ = self.last_visit.set(origin, @async.now().to_int())
}

///|
/// 引擎主循环：顺序抓取 + per-origin 礼貌间隔（跨 host 并行见路线图）。
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
  let polite = Politeness::new(options.delay_ms)
  let _ = frontier.push(seed_norm)
  let _ = depths.set(seed_norm, 0)
  let mut fetched : Int32 = 0
  while fetched < options.max_pages {
    let url = match frontier.pop() {
      Some(u) => u
      None => break
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
    // ---- robots（每个 origin 只取一次） ----
    if options.respect_robots && robots_tried.get(origin) is None {
      let robots_url = origin + "/robots.txt"
      polite.gate(origin)
      let out = fetch(robots_url, options.user_agent)
      let _ = robots_tried.set(origin, true)
      match out.error {
        // robots 不可达：按惯例视为允许抓取
        Some(_) => stats.robots_unreachable = stats.robots_unreachable + 1
        None => {
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
    }
    if options.respect_robots {
      match robots_map.get(origin) {
        Some(rules) =>
          if !rules.allowed_url(options.user_agent, u) {
            stats.pages_skipped_robots = stats.pages_skipped_robots + 1
            on_page({
              url,
              status: 0,
              depth,
              links_found: 0,
              title: None,
              error: Some("disallowed by robots.txt"),
            })
            continue
          }
        None => ()
      }
    }
    // ---- 礼貌限速后抓取 ----
    polite.gate(origin)
    fetched = fetched + 1
    stats.pages_fetched = stats.pages_fetched + 1
    let out = fetch(url, options.user_agent)
    match out.error {
      Some(e) => {
        stats.pages_failed = stats.pages_failed + 1
        on_page({
          url,
          status: 0,
          depth,
          links_found: 0,
          title: None,
          error: Some(e),
        })
        continue
      }
      None => ()
    }
    stats.pages_ok = stats.pages_ok + 1
    // ---- 提取与入队 ----
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
      error: None,
    })
  }
  stats
}
