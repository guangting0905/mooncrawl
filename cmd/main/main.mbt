///|
/// CLI 演示：把等价书写形式的 URL 折叠为同一规范化字符串。
/// 运行 `moon run cmd/main`。
fn main {
  let samples = [
    "HTTP://Example.COM:80/a/./b?b=2&a=1#top", "https://EXAMPLE.com/a?b=2&a=1", "https://example.com/x/../../docs",
    "javascript:void(0)",
  ]
  for s in samples {
    match @mooncrawl.parse_url(s) {
      Some(u) => println(@mooncrawl.normalize_url(u))
      None => println("(rejected) " + s)
    }
  }
}
