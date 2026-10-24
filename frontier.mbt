// URL 前沿队列（frontier）：待抓取集合、已见去重与按 host 的礼貌间隔。
//
// 设计取舍：队列本身只做「去重入队 + FIFO 出队 + host 间隔推算」，
// 延迟等待由引擎执行（便于注入测试时钟/假 fetcher）。规范化是调用方
// 的前置义务——同一条 URL 的等价书写形式必须先折叠再入队。

///|
pub struct Frontier {
  priv queue : Array[String]
  priv mut head : Int32 // 消费游标，避免大数组 shift
  priv seen : Bloom
  priv hosts : Map[String, Int32] // host -> 最近一次开始抓取的时刻(ms)
  priv min_host_delay_ms : Int32
}

///|
/// `min_host_delay_ms`：同一 host 两次请求的最小间隔（礼貌默认 1000）。
pub fn Frontier::new(min_host_delay_ms : Int32) -> Frontier {
  {
    queue: [],
    head: 0,
    seen: Bloom::new(4096),
    hosts: Map([], capacity=64),
    min_host_delay_ms,
  }
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
