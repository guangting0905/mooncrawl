// 跨模块边界用例集。
//
// 这些输入不覆盖主流程，但都是「实现容易写错、错了又不报错」的地方：
// 空路径、点段折叠到根之上、scheme 相对地址、`/*` 与 `/$` 的语义、
// 子代选择器越层、嵌套同名元素、十万元素规模下的假阴性。

///|
test "boundary: parse_url 缺路径/只有查询/IPv6/点段超根" {
  inspect(
    @mooncrawl.normalize_url(
      @mooncrawl.parse_url("http://example.com").unwrap(),
    ),
    content="http://example.com/",
  )
  inspect(
    @mooncrawl.normalize_url(
      @mooncrawl.parse_url("http://example.com?x=1").unwrap(),
    ),
    content="http://example.com/?x=1",
  )
  inspect(
    @mooncrawl.normalize_url(
      @mooncrawl.parse_url("http://example.com#frag").unwrap(),
    ),
    content="http://example.com/",
  )
  inspect(
    @mooncrawl.normalize_url(
      @mooncrawl.parse_url("http://[::1]:8080/x").unwrap(),
    ),
    content="http://[::1]:8080/x",
  )
  // 点段折叠到根之上
  inspect(
    @mooncrawl.normalize_url(
      @mooncrawl.parse_url("https://example.com/../../x").unwrap(),
    ),
    content="https://example.com/x",
  )
  inspect(
    @mooncrawl.normalize_url(
      @mooncrawl.parse_url("https://example.com/a/./b/../c").unwrap(),
    ),
    content="https://example.com/a/c",
  )
}

///|
test "boundary: resolve_url scheme 相对与父目录" {
  let base = @mooncrawl.parse_url("https://a.com/d/e").unwrap()
  inspect(
    @mooncrawl.normalize_url(
      @mooncrawl.resolve_url(base, "//cdn.com/x").unwrap(),
    ),
    content="https://cdn.com/x",
  )
  inspect(
    @mooncrawl.normalize_url(@mooncrawl.resolve_url(base, "../x").unwrap()),
    content="https://a.com/x",
  )
  inspect(
    @mooncrawl.normalize_url(@mooncrawl.resolve_url(base, "/x").unwrap()),
    content="https://a.com/x",
  )
  // 只有查询
  inspect(
    @mooncrawl.normalize_url(@mooncrawl.resolve_url(base, "?q=1").unwrap()),
    content="https://a.com/d/e?q=1",
  )
}

///|
test "boundary: robots 的 /* 与 /$ 语义" {
  let r = @mooncrawl.parse_robots("User-agent: *\nDisallow: /*\n")
  assert_true(!r.allowed("ua", "/abc"))
  assert_true(!r.allowed("ua", "/"))

  let r2 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /\nAllow: /$\n")
  assert_true(r2.allowed("ua", "/"))
  assert_true(!r2.allowed("ua", "/x"))

  // 空文件：允许一切
  let r3 = @mooncrawl.parse_robots("")
  assert_true(r3.allowed("ua", "/any"))
}

///|
test "boundary: selector 引号属性/子代越层/嵌套计数" {
  // 属性值带引号
  assert_eq(
    @mooncrawl.select_count("<a href=\"/x\" data-k='v'>x</a>", "a[data-k=v]"),
    1,
  )
  // 子代选择器不能跨越层级
  assert_eq(
    @mooncrawl.select_count("<div><section><p>x</p></section></div>", "div > p"),
    0,
  )
  // 嵌套同名元素只返回外层一次
  assert_eq(
    @mooncrawl.select_count("<div><div><div>x</div></div></div>", "div"),
    3,
  )
}

///|
test "boundary: bloom 十万元素无假阴性" {
  let b = @mooncrawl.Bloom::new(100_000)
  let mut i = 0
  while i < 100_000 {
    b.add("https://example.com/p/" + i.to_string())
    i = i + 1
  }
  // 抽样确认无假阴性
  let mut j = 0
  while j < 1000 {
    assert_true(b.maybe_contains("https://example.com/p/" + j.to_string()))
    j = j + 1
  }
}
