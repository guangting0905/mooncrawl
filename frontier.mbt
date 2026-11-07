// URL 前沿队列（frontier）：待抓取集合、已见去重与按 host 的礼貌间隔。
//
// 设计取舍：队列本身只做「去重入队 + FIFO 出队 + host 间隔推算」，
// 延迟等待由引擎执行（便于注入测试时钟/假 fetcher）。规范化是调用方
// 的前置义务——同一条 URL 的等价书写形式必须先折叠再入队。
//
// 关于两套间隔记账：`record_visit` / `next_allowed_ms` 按 **host** 记账，
// 是给直接使用 Frontier 的调用方准备的工具；抓取引擎走的是 crawl.mbt 的
// `Politeness`，按 **origin**（含 scheme 与端口）记账，并与 robots.txt
// 请求共享同一张时间表。两者语义不同，引擎路径不使用前者。

///|
pub struct Frontier {
  priv queue : Array[String]
  priv mut head : Int32 // 消费游标，避免大数组 shift
  priv seen : Bloom
  priv hosts : Map[String, Int32] // host -> 最近一次开始抓取的时刻(ms)
  priv min_host_delay_ms : Int32
}

///|
/// 默认去重容量：65536 个 URL（128 KiB 位数组）。
///
/// 早先写死 4096（8 KiB），超过两千个 URL 就开始出现假阳性，且因为没有
/// 任何可观测指标，表现为「抓取提前结束但统计看着正常」。默认值上调后，
/// 常见站点规模不会触碰上限；更大规模请用 `with_capacity` 显式声明。
const FRONTIER_DEFAULT_CAPACITY : Int32 = 65_536

///|
/// `min_host_delay_ms`：同一 host 两次请求的最小间隔（礼貌默认 1000）。
/// 去重容量取默认值（65536 个 URL）。
pub fn Frontier::new(min_host_delay_ms : Int32) -> Frontier {
  Frontier::with_capacity(min_host_delay_ms, FRONTIER_DEFAULT_CAPACITY)
}

///|
/// 指定去重容量的构造。
///
/// `expected_urls` 应略大于「本次任务可能入队的唯一 URL 总数」——
/// 建议不低于预期抓取页数的 8 倍。容量不足时布隆过滤器会把未见过的 URL
/// 误判为已见并静默丢弃，`saturation_permille()` 可用于事后自查。
pub fn Frontier::with_capacity(
  min_host_delay_ms : Int32,
  expected_urls : Int32,
) -> Frontier {
  {
    queue: [],
    head: 0,
    seen: Bloom::new(expected_urls),
    hosts: Map([], capacity=64),
    min_host_delay_ms,
  }
}

///|
/// 去重位数组的填充率（千分比）。接近 1000 说明容量不足，新 URL 会被
/// 大量误判为已见。
pub fn Frontier::saturation_permille(self : Frontier) -> Int32 {
  self.seen.saturation_permille()
}

///|
fn host_of(url : String) -> String {
  match parse_url(url) {
    Some(u) => u.host
    None => ""
  }
}

///|
/// 入队。已见过的 URL（含此前抓取过的）返回 false 且不入队。
pub fn Frontier::push(self : Frontier, url : String) -> Bool {
  if self.seen.maybe_contains(url) {
    return false
  }
  self.seen.add(url)
  let _ = self.queue.push(url)
  true
}

///|
/// 直接管账式登记「已见过」（用于种子的去重基线），不入队。
pub fn Frontier::mark_seen(self : Frontier, url : String) -> Unit {
  self.seen.add(url)
}

///|
/// FIFO 出队。空返回 None。
pub fn Frontier::pop(self : Frontier) -> String? {
  if self.head >= self.queue.length() {
    return None
  }
  let url = self.queue[self.head]
  self.head = self.head + 1
  Some(url)
}

///|
/// 批量出队，**每个 host 最多一个**。
///
/// 供并发调度使用：同 host 的请求必须串行（礼貌限速按站记账），
/// 不同 host 可以并行。本轮未取到的 URL 会被移到队尾，留待下一轮。
/// 扫描上界取调用时的队列长度快照，因此不会因为回填而无限循环。
pub fn Frontier::pop_batch(self : Frontier, limit : Int32) -> Array[String] {
  let out : Array[String] = []
  if limit <= 0 {
    return out
  }
  let picked : Map[String, Bool] = Map([], capacity=16)
  let stop : Int32 = self.queue.length()
  while self.head < stop && out.length() < limit {
    let url = self.queue[self.head]
    self.head = self.head + 1
    let host = host_of(url)
    match picked.get(host) {
      Some(_) => self.queue.push(url) // 同 host 本轮不取，排到队尾
      None => {
        let _ = picked.set(host, true)
        out.push(url)
      }
    }
  }
  out
}

///|
/// 待抓取数量。
pub fn Frontier::length(self : Frontier) -> Int32 {
  self.queue.length() - self.head
}

///|
/// 队列是否为空。
pub fn Frontier::is_empty(self : Frontier) -> Bool {
  self.length() == 0
}

///|
/// 抓取开始时登记：host 最近访问时刻 = `at_ms`。
pub fn Frontier::record_visit(
  self : Frontier,
  url : String,
  at_ms : Int32,
) -> Unit {
  let _ = self.hosts.set(host_of(url), at_ms)
}

///|
/// 该 URL 最早允许开始抓取的时刻（考虑 host 间隔与当前时刻）。
pub fn Frontier::next_allowed_ms(
  self : Frontier,
  url : String,
  now_ms : Int32,
) -> Int32 {
  let earliest = match self.hosts.get(host_of(url)) {
    Some(last) => last + self.min_host_delay_ms
    None => 0
  }
  if now_ms > earliest {
    now_ms
  } else {
    earliest
  }
}
