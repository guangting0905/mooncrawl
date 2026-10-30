///|
/// MoonCrawl CLI：礼貌地抓取站点。
///
/// 两种输出模式：
/// - 页面模式（默认）：每页一条元数据（URL/状态/深度/标题/链接数）。
/// - 采集模式：给出 `--container` 与 `--fields` 后，按 CSS 选择器从每页
///   的列表容器里提取字段，每个条目输出一条记录。
///
/// 用法：
///   moon run cmd/main -- https://example.com/ --max-pages 20 --depth 1
///   moon run cmd/main -- https://books.toscrape.com/ \
///     --container "article.product_pod" \
///     --fields "title=h3 a@title;price=.price_color;link=h3 a@href" \
///     --format csv

///|
fn is_ws(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
fn trim_str(s : String) -> String {
  let cs : Array[Char] = []
  for c in s {
    cs.push(c)
  }
  let n = cs.length()
  let mut a = 0
  let mut b = n
  while a < b && is_ws(cs[a]) {
    a = a + 1
  }
  while b > a && is_ws(cs[b - 1]) {
    b = b - 1
  }
  let buf = StringBuilder()
  let mut i = a
  while i < b {
    buf.write_char(cs[i])
    i = i + 1
  }
  buf.to_string()
}

///|
fn split_by(s : String, sep : Char) -> Array[String] {
  let cs : Array[Char] = []
  for c in s {
    cs.push(c)
  }
  let out : Array[String] = []
  let n = cs.length()
  let buf = StringBuilder()
  let mut i = 0
  while i < n {
    if cs[i] == sep {
      out.push(buf.to_string())
      buf.reset()
    } else {
      buf.write_char(cs[i])
    }
    i = i + 1
  }
  out.push(buf.to_string())
  out
}

///|
fn index_of(s : String, ch : Char) -> Int32? {
  let cs : Array[Char] = []
  for c in s {
    cs.push(c)
  }
  let mut i = 0
  while i < cs.length() {
    if cs[i] == ch {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
fn last_index_of(s : String, ch : Char) -> Int32? {
  let cs : Array[Char] = []
  for c in s {
    cs.push(c)
  }
  let mut i = cs.length() - 1
  while i >= 0 {
    if cs[i] == ch {
      return Some(i)
    }
    i = i - 1
  }
  None
}

///|
fn slice_str(s : String, a : Int32, b : Int32) -> String {
  let cs : Array[Char] = []
  for c in s {
    cs.push(c)
  }
  let buf = StringBuilder()
  let mut i = a
  while i < b && i < cs.length() {
    buf.write_char(cs[i])
    i = i + 1
  }
  buf.to_string()
}

///|
/// 解析字段规格：`name=selector` 或 `name=selector@attr`，多项以 `;` 分隔。
/// 形如 `title=h3 a@title;price=.price_color`。
fn parse_field_specs(s : String) -> Array[@mooncrawl.FieldSpec] {
  let out : Array[@mooncrawl.FieldSpec] = []
  for raw in split_by(s, ';') {
    let item = trim_str(raw)
    if item == "" {
      continue
    }
    match index_of(item, '=') {
      Some(eq) => {
        let name = trim_str(slice_str(item, 0, eq))
        let rest = trim_str(slice_str(item, eq + 1, item.length()))
        if name == "" || rest == "" {
          continue
        }
        match last_index_of(rest, '@') {
          Some(at) => {
            let sel = trim_str(slice_str(rest, 0, at))
            let attr = trim_str(slice_str(rest, at + 1, rest.length()))
            if sel != "" && attr != "" {
              out.push(@mooncrawl.FieldSpec::attr(name, sel, attr))
            }
          }
          None => out.push(@mooncrawl.FieldSpec::text(name, rest))
        }
      }
      None => ()
    }
  }
  out
}

///|
fn parse_int_or(s : String, fallback : Int32) -> Int32 {
  let mut v : Int32 = 0
  let mut seen_digit : Bool = false
  for c in s {
    if c >= '0' && c <= '9' {
      v = v * 10 + (c.to_int() - '0'.to_int())
      seen_digit = true
    } else {
      return fallback
    }
  }
  if seen_digit {
    v
  } else {
    fallback
  }
}

///|
fn option_or(
  values : Map[String, Array[String]],
  key : String,
  fallback : String,
) -> String {
  match values.get(key) {
    Some(arr) => if arr.length() > 0 { arr[0] } else { fallback }
    None => fallback
  }
}

///|
/// 把以 `/`、`./`、`../` 开头的相对值展开为绝对 URL，其余值原样返回。
/// 只对「长得像站内相对路径」的值生效，纯文本字段（价格、标题）不受影响。
fn absolutize(base : @mooncrawl.Url, value : String) -> String {
  let cs : Array[Char] = []
  for c in value {
    cs.push(c)
  }
  let n = cs.length()
  if n == 0 {
    return value
  }
  let looks_relative = if cs[0] == '/' {
    // "/x" 与 "//host/x"（scheme 相对）都要按 base 展开
    true
  } else if cs[0] == '.' {
    (n > 1 && cs[1] == '/') || (n > 2 && cs[1] == '.' && cs[2] == '/')
  } else {
    false
  }
  if !looks_relative {
    return value
  }
  match @mooncrawl.resolve_url(base, value) {
    Some(u) => @mooncrawl.normalize_url(u)
    None => value
  }
}

///|
async fn main {
  let matches = @argparse.Command(
    "mooncrawl",
    about="Polite web crawler for MoonBit — page metadata or CSS-selected records as JSONL/CSV.",
    options=[
      OptionArg(
        "max-pages",
        long="max-pages",
        about="maximum number of pages to fetch (default 50)",
      ),
      OptionArg(
        "depth",
        long="depth",
        about="maximum link depth from the seed (default 2)",
      ),
      OptionArg(
        "delay-ms",
        long="delay-ms",
        about="minimum delay between requests to the same origin (default 1000)",
      ),
      OptionArg(
        "concurrency",
        long="concurrency",
        about="parallel requests across origins; same origin stays serial (default 4)",
      ),
      OptionArg(
        "container",
        long="container",
        about="CSS selector for repeating item containers (enables harvesting)",
      ),
      OptionArg(
        "fields",
        long="fields",
        about="field specs: name=selector[@attr];name=selector;...",
      ),
      OptionArg(
        "format",
        long="format",
        about="output format: jsonl or csv (default jsonl)",
      ),
    ],
    positionals=[
      PositionArg(
        "seed",
        about="seed URL (http/https)",
        num_args=@argparse.ValueRange::single(),
      ),
    ],
  ).parse()
  guard matches.values is { "seed": [seed], .. } else {
    fail("seed URL is required")
  }
  let max_pages = parse_int_or(option_or(matches.values, "max-pages", "50"), 50)
  let depth = parse_int_or(option_or(matches.values, "depth", "2"), 2)
  let delay_ms = parse_int_or(
    option_or(matches.values, "delay-ms", "1000"),
    1000,
  )
  let concurrency = parse_int_or(
    option_or(matches.values, "concurrency", "4"),
    4,
  )
  let container = option_or(matches.values, "container", "")
  let fields = parse_field_specs(option_or(matches.values, "fields", ""))
  let format = option_or(matches.values, "format", "jsonl")
  let harvest = container != "" && fields.length() > 0
  let options : @mooncrawl.CrawlOptions = {
    ..@mooncrawl.CrawlOptions::default(),
    max_pages,
    max_depth: depth,
    delay_ms,
    max_concurrency: concurrency,
    keep_body: harvest,
  }
  let is_csv = format == "csv"
  if harvest && is_csv {
    let names : Array[String] = []
    for f in fields {
      names.push(f.name)
    }
    println(@mooncrawl.csv_row(names).trim())
  }
  let stats = @mooncrawl.crawl(seed, options, @mooncrawl.http_fetch, fn(p) {
    if harvest {
      match p.body {
        Some(html) => {
          let base = @mooncrawl.parse_url(p.url)
          for row in @mooncrawl.extract_records(html, container, fields) {
            let cells : Array[(String, String)] = []
            for kv in row {
              let (k, v) = kv
              let resolved = match base {
                Some(b) => absolutize(b, v)
                None => v
              }
              cells.push((k, resolved))
            }
            if is_csv {
              println(@mooncrawl.csv_record(cells).trim())
            } else {
              println(@mooncrawl.json_record(cells))
            }
          }
        }
        None => ()
      }
    } else if is_csv {
      println(@mooncrawl.csv_page(p).trim())
    } else {
      println(@mooncrawl.jsonl_page(p))
    }
  })
  println(
    "# pages_fetched=" +
    stats.pages_fetched.to_string() +
    " ok=" +
    stats.pages_ok.to_string() +
    " failed=" +
    stats.pages_failed.to_string() +
    " robots_skipped=" +
    stats.pages_skipped_robots.to_string() +
    " robots_unreachable=" +
    stats.robots_unreachable.to_string() +
    " links=" +
    stats.links_discovered.to_string(),
  )
}
