///|
/// MoonCrawl CLI：礼貌地抓取一个站点，把结果以 JSONL/CSV 输出到 stdout
/// （便于 `> out.jsonl` 落盘或管道处理），最后打印统计摘要。
///
/// 用法：
///   moon run cmd/main -- https://books.toscrape.com/ --max-pages 20 --depth 1
///   moon run cmd/main -- https://quotes.toscrape.com/ --format csv > quotes.csv
async fn main {
  let matches = @argparse.Command(
    "mooncrawl",
    about="Polite web crawler for MoonBit — harvest pages to stdout as JSONL or CSV.",
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
  let max_pages = match matches.values.get("max-pages") {
    Some([v]) => parse_int_or(v, 50)
    _ => 50
  }
  let depth = match matches.values.get("depth") {
    Some([v]) => parse_int_or(v, 2)
    _ => 2
  }
  let delay_ms = match matches.values.get("delay-ms") {
    Some([v]) => parse_int_or(v, 1000)
    _ => 1000
  }
  let format = match matches.values.get("format") {
    Some([v]) => v
    _ => "jsonl"
  }
  let options : @mooncrawl.CrawlOptions = {
    max_pages,
    max_depth: depth,
    delay_ms,
    respect_robots: true,
    user_agent: "MoonCrawl/0.1 (+https://github.com/guangting0905/mooncrawl)",
  }
  let is_csv = format == "csv"
  if is_csv {
    println(@mooncrawl.csv_header().trim())
  }
  let stats = @mooncrawl.crawl(seed, options, @mooncrawl.http_fetch, fn(p) {
    if is_csv {
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
    " links=" +
    stats.links_discovered.to_string() +
    " robots_unreachable=" +
    stats.robots_unreachable.to_string(),
  )
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
