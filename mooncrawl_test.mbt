// 黑盒测试：面向 @mooncrawl 公开 API 的高层行为。
// 运行 `moon test`。

///|
test "parse_url: 基本解析" {
  let u = @mooncrawl.parse_url("https://example.com/docs/index.html?a=1").unwrap()
  assert_eq(u.scheme, "https")
  assert_eq(u.host, "example.com")
  assert_eq(u.path, "/docs/index.html")
  assert_eq(u.query.unwrap(), "a=1")
}

///|
test "parse_url: host 大小写与 userinfo 被处理" {
  let u = @mooncrawl.parse_url("http://Admin@Example.COM/Path").unwrap()
  assert_eq(u.scheme, "http")
  assert_eq(u.host, "example.com")
  assert_eq(u.path, "/Path")
}

///|
test "parse_url: 非法输入返回 None" {
  assert_true(@mooncrawl.parse_url("ftp://example.com/x") is None)
  assert_true(@mooncrawl.parse_url("/relative/path") is None)
  assert_true(@mooncrawl.parse_url("http:///nohost") is None)
  assert_true(@mooncrawl.parse_url("http://host:99999/") is None)
  assert_true(@mooncrawl.parse_url("http://host:abc/") is None)
}

///|
test "normalize_url: 大小写、默认端口、点段与参数排序" {
  let u = @mooncrawl.parse_url("HTTP://Example.COM:80/a/./b?b=2&a=1#frag").unwrap()
  inspect(@mooncrawl.normalize_url(u), content="http://example.com/a/b?a=1&b=2")
}

///|
test "normalize_url: 非默认端口保留" {
  let u = @mooncrawl.parse_url("http://example.com:8080/x").unwrap()
  inspect(@mooncrawl.normalize_url(u), content="http://example.com:8080/x")
}

///|
test "normalize_url: 路径上溯被折叠" {
  let u = @mooncrawl.parse_url("https://example.com/x/../../top").unwrap()
  inspect(@mooncrawl.normalize_url(u), content="https://example.com/top")
}

///|
test "normalize_url: 保留结尾斜杠语义" {
  let a = @mooncrawl.parse_url("https://example.com/dir/").unwrap()
  inspect(@mooncrawl.normalize_url(a), content="https://example.com/dir/")
  let b = @mooncrawl.parse_url("https://example.com/dir").unwrap()
  inspect(@mooncrawl.normalize_url(b), content="https://example.com/dir")
}

///|
test "normalize_url: 等价书写形式折叠为同一字符串" {
  let a = @mooncrawl.parse_url("HTTPS://EXAMPLE.com:443/a?x=2&y=1").unwrap()
  let b = @mooncrawl.parse_url("https://example.com/a?y=1&x=2").unwrap()
  assert_eq(@mooncrawl.normalize_url(a), @mooncrawl.normalize_url(b))
}

///|
test "resolve_url: 同目录相对路径" {
  let base = @mooncrawl.parse_url("https://example.com/a/b/index.html").unwrap()
  let r = @mooncrawl.resolve_url(base, "page2.html").unwrap()
  inspect(
    @mooncrawl.normalize_url(r),
    content="https://example.com/a/b/page2.html",
  )
}

///|
test "resolve_url: 根相对与 scheme 相对" {
  let base = @mooncrawl.parse_url("https://example.com/a/b/index.html").unwrap()
  let r1 = @mooncrawl.resolve_url(base, "/top.html").unwrap()
  inspect(@mooncrawl.normalize_url(r1), content="https://example.com/top.html")
  let r2 = @mooncrawl.resolve_url(base, "//cdn.example.com/x.js").unwrap()
  inspect(@mooncrawl.normalize_url(r2), content="https://cdn.example.com/x.js")
}

///|
test "resolve_url: 查询相对与 fragment 丢弃" {
  let base = @mooncrawl.parse_url("https://example.com/list?page=1").unwrap()
  let r1 = @mooncrawl.resolve_url(base, "?page=2").unwrap()
  inspect(
    @mooncrawl.normalize_url(r1),
    content="https://example.com/list?page=2",
  )
  let r2 = @mooncrawl.resolve_url(base, "#section-2")
  assert_true(r2 is None)
}

///|
test "resolve_url: 非 http 地址被拒" {
  let base = @mooncrawl.parse_url("https://example.com/").unwrap()
  assert_true(@mooncrawl.resolve_url(base, "javascript:void(0)") is None)
  assert_true(@mooncrawl.resolve_url(base, "mailto:a@b.com") is None)
  assert_true(@mooncrawl.resolve_url(base, "") is None)
}

///|
test "bloom: 已添加键必命中" {
  let b = @mooncrawl.Bloom::new(500)
  let mut i : Int = 0
  while i < 500 {
    b.add("https://example.com/page/" + i.to_string())
    i = i + 1
  }
  let mut j : Int = 0
  while j < 500 {
    assert_true(b.maybe_contains("https://example.com/page/" + j.to_string()))
    j = j + 1
  }
}

///|
test "bloom: 未添加键误报率低于 2%" {
  let b = @mooncrawl.Bloom::new(500)
  let mut i : Int = 0
  while i < 500 {
    b.add("https://example.com/page/" + i.to_string())
    i = i + 1
  }
  let mut fp : Int = 0
  let mut j : Int = 0
  while j < 1000 {
    if b.maybe_contains("https://other.com/x/" + j.to_string()) {
      fp = fp + 1
    }
    j = j + 1
  }
  // 理论误报约 0.6 个（0.06%），留工程余量
  assert_true(fp < 20)
}
