// HTML 提取的黑盒测试。

///|
test "extract: 链接收集保持文档顺序" {
  let links = @mooncrawl.extract_links(
    "<html><body><a href=\"/a\">a</a><p>x</p><a href='/b'>b</a><a>c</a><a href=\"https://ext.example/x\">ext</a></body></html>",
  )
  assert_eq(links.length(), 3)
  assert_eq(links[0], "/a")
  assert_eq(links[1], "/b")
  assert_eq(links[2], "https://ext.example/x")
}

///|
test "extract: 嵌套标签中的链接" {
  let links = @mooncrawl.extract_links(
    "<html><body><div><ul><li><a href=\"/deep\">d</a></li></ul></div></body></html>",
  )
  assert_eq(links.length(), 1)
  assert_eq(links[0], "/deep")
}

///|
test "extract: 标题提取与实体解码" {
  assert_eq(
    @mooncrawl.extract_title(
      "<html><head><title>Hello &amp; World</title></head></html>",
    ),
    Some("Hello & World"),
  )
  assert_true(
    @mooncrawl.extract_title("<html><body>no title</body></html>") is None,
  )
}

///|
test "extract: 正文跳过 script/style 并折叠空白" {
  let text = @mooncrawl.extract_text(
    "<html><head><style>body { color: red }</style></head><body><script>var x = 1;</script><p>Hello   \n  World</p><p>第二段</p></body></html>",
  )
  assert_eq(text, "Hello World 第二段")
}

///|
test "extract: 标签属性顺序无关 href 提取" {
  let links = @mooncrawl.extract_links(
    "<html><body><a class=\"lnk\" data-x=\"1\" href=\"/z\" id=\"go\">z</a></body></html>",
  )
  assert_eq(links.length(), 1)
  assert_eq(links[0], "/z")
}
