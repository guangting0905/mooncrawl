// CSS 选择器与字段提取的黑盒测试。

///|
const PAGE : String = "<html><head><title>List</title></head><body><div class=\"item\" id=\"i1\"><h2>Alpha</h2><a href=\"/a\">A</a><span class=\"price\">10</span></div><div class=\"item\" id=\"i2\"><h2>Beta</h2><a href=\"/b\">B</a><span class=\"price\">20</span></div></body></html>"

///|
test "selector: 类型、类、ID 选择器" {
  assert_eq(@mooncrawl.select_texts(PAGE, "h2").length(), 2)
  assert_eq(@mooncrawl.select_attrs(PAGE, "a", "href")[1], "/b")
  assert_eq(@mooncrawl.select_count(PAGE, "div.item"), 2)
  assert_eq(@mooncrawl.select_texts(PAGE, "#i2 h2")[0], "Beta")
  assert_eq(@mooncrawl.select_texts(PAGE, "div.item#i1 h2")[0], "Alpha")
  assert_eq(@mooncrawl.select_count(PAGE, "*"), 12)
}

///|
test "selector: 后代与子代组合子" {
  assert_eq(@mooncrawl.select_count(PAGE, "body h2"), 2)
  assert_eq(@mooncrawl.select_count(PAGE, "body > h2"), 0)
  assert_eq(@mooncrawl.select_count(PAGE, "body > div"), 2)
  assert_eq(@mooncrawl.select_count(PAGE, "div > h2"), 2)
  // 子代链式：不能跨越中间层
  assert_eq(@mooncrawl.select_count(PAGE, "body > h2"), 0)
}

///|
test "selector: 属性选择器（存在/= ^= $= *= ~=）" {
  let html = "<a href=\"https://e.com/x.pdf\" rel=\"nofollow noopener\" " +
    "data-kind=\"doc\">x</a><a href=\"/y.html\" data-kind=\"page\">y</a>"
  assert_eq(@mooncrawl.select_count(html, "a[href]"), 2)
  assert_eq(@mooncrawl.select_count(html, "a[data-kind]"), 2)
  assert_eq(@mooncrawl.select_count(html, "a[href^=\"https://\"]"), 1)
  assert_eq(@mooncrawl.select_count(html, "a[href$=\".pdf\"]"), 1)
  assert_eq(@mooncrawl.select_count(html, "a[href*=\"e.com\"]"), 1)
  assert_eq(@mooncrawl.select_count(html, "a[rel~=\"nofollow\"]"), 1)
  assert_eq(@mooncrawl.select_count(html, "a[data-kind=\"page\"]"), 1)
  assert_eq(@mooncrawl.select_count(html, "a[data-kind=\"nope\"]"), 0)
}

///|
test "selector: 逗号并集与去重" {
  // 同一个节点同时命中两条链，只返回一次
  assert_eq(@mooncrawl.select_count(PAGE, "h2, div.item h2"), 2)
  assert_eq(@mooncrawl.select_count(PAGE, "h2, .price"), 4)
}

///|
test "selector: :first-child" {
  let html = "<ul><li>one</li><li>two</li></ul>"
  let texts = @mooncrawl.select_texts(html, "li:first-child")
  assert_eq(texts.length(), 1)
  assert_eq(texts[0], "one")
}

///|
test "selector: 文本提取跳过 script/style" {
  let html = "<div class=\"d\">hi<script>var x=1</script>" +
    "<style>.a{}</style><b>there</b></div>"
  assert_eq(@mooncrawl.select_texts(html, ".d")[0], "hi there")
}

///|
test "selector: 非法语法返回空选择器而非猜测" {
  assert_eq(@mooncrawl.select_count(PAGE, "div + div"), 0)
  assert_eq(@mooncrawl.select_count(PAGE, "div~div"), 0)
  assert_eq(@mooncrawl.select_count(PAGE, ":nth-child(2)"), 0)
  assert_eq(@mooncrawl.select_count(PAGE, "div["), 0)
  assert_eq(@mooncrawl.select_count(PAGE, ""), 0)
}

///|
test "selector: extract_fields 取首个匹配，缺失为空串" {
  let fields = [
    @mooncrawl.FieldSpec::text("title", "h2"),
    @mooncrawl.FieldSpec::attr("link", "a", "href"),
    @mooncrawl.FieldSpec::text("missing", ".nope"),
  ]
  let row = @mooncrawl.extract_fields(PAGE, fields)
  assert_eq(row.length(), 3)
  assert_eq(row[0], ("title", "Alpha"))
  assert_eq(row[1], ("link", "/a"))
  assert_eq(row[2], ("missing", ""))
}

///|
test "selector: extract_records 逐容器成表" {
  let fields = [
    @mooncrawl.FieldSpec::text("title", "h2"),
    @mooncrawl.FieldSpec::attr("link", "a", "href"),
    @mooncrawl.FieldSpec::text("price", ".price"),
  ]
  let rows = @mooncrawl.extract_records(PAGE, "div.item", fields)
  assert_eq(rows.length(), 2)
  assert_eq(rows[0][0], ("title", "Alpha"))
  assert_eq(rows[0][2], ("price", "10"))
  assert_eq(rows[1][0], ("title", "Beta"))
  assert_eq(rows[1][1], ("link", "/b"))
}

///|
test "selector: 字段选择器不越过容器边界" {
  // 第一个容器没有 h2，不能取到第二个容器的
  let html = "<div class=\"item\"><p>only</p></div>" +
    "<div class=\"item\"><h2>X</h2></div>"
  let rows = @mooncrawl.extract_records(html, "div.item", [
    @mooncrawl.FieldSpec::text("title", "h2"),
  ])
  assert_eq(rows.length(), 2)
  assert_eq(rows[0][0], ("title", ""))
  assert_eq(rows[1][0], ("title", "X"))
}
