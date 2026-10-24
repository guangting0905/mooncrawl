// frontier 队列与礼貌间隔的黑盒测试。

///|
test "frontier: FIFO 出队" {
  let f = @mooncrawl.Frontier::new(0)
  assert_true(f.push("https://a.com/1"))
  assert_true(f.push("https://a.com/2"))
  assert_true(f.push("https://b.com/1"))
  assert_eq(f.length(), 3)
  assert_eq(f.pop(), Some("https://a.com/1"))
  assert_eq(f.pop(), Some("https://a.com/2"))
  assert_eq(f.pop(), Some("https://b.com/1"))
  assert_true(f.pop() is None)
  assert_true(f.is_empty())
}

///|
test "frontier: 重复 URL 去重" {
  let f = @mooncrawl.Frontier::new(0)
  assert_true(f.push("https://a.com/x"))
  assert_true(!f.push("https://a.com/x"))
  assert_eq(f.length(), 1)
}

///|
test "frontier: mark_seen 阻止后续入队" {
  let f = @mooncrawl.Frontier::new(0)
  f.mark_seen("https://a.com/x")
  assert_true(!f.push("https://a.com/x"))
  assert_true(f.is_empty())
}

///|
test "frontier: 同 host 礼貌间隔推算" {
  let f = @mooncrawl.Frontier::new(1000)
  f.record_visit("https://a.com/1", 5_000)
  // 5s 访问过 a.com，6s 时再来 → 需等到 6s
  assert_eq(f.next_allowed_ms("https://a.com/2", 6_000), 6_000)
  assert_eq(f.next_allowed_ms("https://a.com/2", 5_500), 6_000)
  // 其他 host 不受影响
  assert_eq(f.next_allowed_ms("https://b.com/1", 5_500), 5_500)
  // 首次访问的 host 任意时刻可抓
  assert_eq(f.next_allowed_ms("https://c.com/", 0), 0)
}

///|
test "frontier: 大量 URL 消费游标无退化" {
  let f = @mooncrawl.Frontier::new(0)
  let mut i : Int32 = 0
  while i < 2000 {
    let _ = f.push("https://a.com/p/" + i.to_string())
    i = i + 1
  }
  assert_eq(f.length(), 2000)
  let mut count : Int32 = 0
  while f.pop() is Some(_) {
    count = count + 1
  }
  assert_eq(count, 2000)
}

///|
test "frontier: 无法解析的 URL 归入同一兜底桶" {
  let f = @mooncrawl.Frontier::new(1000)
  f.record_visit("not-a-url", 1_000)
  assert_eq(f.next_allowed_ms("still-not-a-url", 1_500), 2_000)
}
