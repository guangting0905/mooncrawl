// CSV / JSONL 导出的黑盒测试。

///|
test "csv: 无需转义的字段原样输出" {
  assert_eq(@mooncrawl.csv_escape("plain"), "plain")
}

///|
test "csv: 逗号引号换行触发引号包裹" {
  assert_eq(@mooncrawl.csv_escape("a,b"), "\"a,b\"")
  assert_eq(@mooncrawl.csv_escape("say \"hi\""), "\"say \"\"hi\"\"\"")
  assert_eq(@mooncrawl.csv_escape("l1\nl2"), "\"l1\nl2\"")
}

///|
test "csv: 行组装与 CRLF" {
  assert_eq(@mooncrawl.csv_row(["a", "b"]), "a,b\r\n")
  assert_eq(@mooncrawl.csv_row(["x,y", "z"]), "\"x,y\",z\r\n")
}

///|
test "json: 引号与反斜杠转义" {
  assert_eq(@mooncrawl.json_escape("a\"b"), "\"a\\\"b\"")
  assert_eq(@mooncrawl.json_escape("a\\b"), "\"a\\\\b\"")
}

///|
test "json: 控制字符转义为 \\uXXXX，中文原样透传" {
  assert_eq(@mooncrawl.json_escape("\u{0001}"), "\"\\u0001\"")
  assert_eq(@mooncrawl.json_escape(" tab\t"), "\" tab\\t\"")
  assert_eq(@mooncrawl.json_escape("中文"), "\"中文\"")
}

///|
test "jsonl: PageResult 序列化字段完整" {
  let line = @mooncrawl.jsonl_page({
    url: "https://example.com/a b",
    status: 200,
    depth: 1,
    links_found: 3,
    title: Some("T\"X\""),
    body: None,
    error: None,
  })
  assert_eq(
    line, "{\"url\":\"https://example.com/a b\",\"status\":200,\"depth\":1,\"links_found\":3,\"title\":\"T\\\"X\\\"\"}",
  )
  let line2 = @mooncrawl.jsonl_page({
    url: "u",
    status: 0,
    depth: 0,
    links_found: 0,
    title: None,
    body: None,
    error: Some("boom"),
  })
  assert_eq(
    line2, "{\"url\":\"u\",\"status\":0,\"depth\":0,\"links_found\":0,\"error\":\"boom\"}",
  )
}

///|
test "csv: PageResult 行与表头对应" {
  assert_eq(
    @mooncrawl.csv_header(),
    "url,status,depth,links_found,title,error\r\n",
  )
  let row = @mooncrawl.csv_page({
    url: "u",
    status: 404,
    depth: 2,
    links_found: 0,
    title: None,
    body: None,
    error: Some("not found"),
  })
  assert_eq(row, "u,404,2,0,,not found\r\n")
}
