// robots.txt 解析与匹配的黑盒测试。

///|
const UA = "mooncrawl"

///|
test "robots: 基本组与 Disallow" {
  let r = @mooncrawl.parse_robots(
    "User-agent: *\nDisallow: /private\nDisallow: /tmp\n",
  )
  assert_true(r.allowed(UA, "/public/page"))
  assert_true(!r.allowed(UA, "/private/x"))
  assert_true(!r.allowed(UA, "/tmp/1"))
  assert_true(r.allowed(UA, "/temporary")) // 前缀外
}

///|
test "robots: 注释、空行与大小写" {
  let r = @mooncrawl.parse_robots(
    "# 注释行\nUser-agent: MOONCRAWL  # 行内注释\nDisallow: /a\n\nUser-agent: other\nDisallow: /",
  )
  assert_true(!r.allowed(UA, "/a"))
  assert_true(r.allowed(UA, "/b"))
}

///|
test "robots: 组选择取最长 UA 前缀" {
  let r = @mooncrawl.parse_robots(
    "User-agent: moon\nDisallow: /moon-only\n\nUser-agent: mooncrawl\nDisallow: /self\n\nUser-agent: *\nDisallow: /",
  )
  assert_true(r.allowed(UA, "/moon-only")) // mooncrawl 组没有禁它
  assert_true(!r.allowed(UA, "/self"))
  assert_true(!r.allowed("moondog", "/moon-only")) // moondog 匹配 moon 组
  assert_true(!r.allowed("nobody", "/anything")) // 回退 * 组全禁
}

///|
test "robots: 通配符 * 与结尾 $" {
  let r = @mooncrawl.parse_robots(
    "User-agent: *\nDisallow: /p/*/edit\nDisallow: /*.pdf$\n",
  )
  assert_true(!r.allowed(UA, "/p/123/edit"))
  assert_true(!r.allowed(UA, "/p/a/b/edit"))
  assert_true(r.allowed(UA, "/p/123/view"))
  assert_true(!r.allowed(UA, "/files/doc.pdf"))
  assert_true(r.allowed(UA, "/files/doc.pdfx")) // $ 锚定
  // 无 $ 的模式贯穿 query（匹配 path?query 整体）
  let r2 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /*.pdf\n")
  assert_true(!r2.allowed(UA, "/a.pdf?download"))
}

///|
test "robots: Allow/Disallow 同时命中取更长模式，等长 Allow 优先" {
  let r = @mooncrawl.parse_robots(
    "User-agent: *\nDisallow: /p\nAllow: /p/public\n",
  )
  assert_true(!r.allowed(UA, "/p/private"))
  assert_true(r.allowed(UA, "/p/public/x")) // 更长的 Allow
  let r2 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /pa\nAllow: /pa\n")
  assert_true(r2.allowed(UA, "/path")) // 等长 Allow 优先
}

///|
test "robots: 空值 Disallow 为无操作" {
  let r = @mooncrawl.parse_robots("User-agent: *\nDisallow:\nDisallow: /x\n")
  assert_true(!r.allowed(UA, "/x"))
  assert_true(r.allowed(UA, "/y"))
}

///|
test "robots: 无匹配组时允许一切" {
  let r = @mooncrawl.parse_robots("User-agent: otherbot\nDisallow: /\n")
  assert_true(r.allowed(UA, "/anything"))
  let empty = @mooncrawl.parse_robots("")
  assert_true(empty.allowed(UA, "/"))
}

///|
test "robots: 仅 UA 无规则的组允许一切" {
  let r = @mooncrawl.parse_robots(
    "User-agent: mooncrawl\nUser-agent: moonbot\n",
  )
  assert_true(r.allowed(UA, "/"))
}

///|
test "robots: crawl-delay 解析为毫秒" {
  let r = @mooncrawl.parse_robots(
    "User-agent: mooncrawl\nCrawl-delay: 2\nDisallow:\n\nUser-agent: botx\nCrawl-delay: 1.5\n",
  )
  assert_eq(r.crawl_delay_ms(UA), Some(2000))
  assert_eq(r.crawl_delay_ms("botx"), Some(1500))
  assert_eq(r.crawl_delay_ms("unknown"), None)
}

///|
test "robots: sitemap 收集与组无关" {
  let r = @mooncrawl.parse_robots(
    "Sitemap: https://example.com/s1.xml\nUser-agent: *\nDisallow: /\nSitemap: https://example.com/s2.xml\n",
  )
  assert_eq(r.sitemaps().length(), 2)
  assert_eq(r.sitemaps()[0], "https://example.com/s1.xml")
}

///|
test "robots: allowed_url 用 path+query 匹配" {
  let r = @mooncrawl.parse_robots("User-agent: *\nDisallow: /search\n")
  let u1 = @mooncrawl.parse_url("https://example.com/search?q=1").unwrap()
  assert_true(!r.allowed_url(UA, u1))
  // 无 $ 的前缀模式同样命中 /searching
  let u2 = @mooncrawl.parse_url("https://example.com/searching").unwrap()
  assert_true(!r.allowed_url(UA, u2))
  // $ 锚定后 /searching 不再命中
  let r2 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /search$\n")
  assert_true(r2.allowed_url(UA, u2))
  // fragment 不参与匹配
  let u3 = @mooncrawl.parse_url("https://example.com/search#frag").unwrap()
  assert_true(!r.allowed_url(UA, u3))
}

///|
test "robots: 同一 UA 分散在多个组时规则合并（RFC 9309 §2.2.1）" {
  let r = @mooncrawl.parse_robots(
    "User-agent: mooncrawl\nDisallow: /a\n\nUser-agent: mooncrawl\nDisallow: /b\n",
  )
  assert_true(!r.allowed(UA, "/a"))
  assert_true(!r.allowed(UA, "/b"))
  assert_true(r.allowed(UA, "/c"))
}

///|
test "robots: 合并组时 Crawl-delay 取最大值" {
  let r = @mooncrawl.parse_robots(
    "User-agent: mooncrawl\nCrawl-delay: 1\nDisallow: /a\n\nUser-agent: mooncrawl\nCrawl-delay: 3\nDisallow: /b\n",
  )
  assert_eq(r.crawl_delay_ms(UA), Some(3000))
}

///|
test "robots: /robots.txt 隐式允许（RFC 9309 §2.2.2）" {
  let r = @mooncrawl.parse_robots("User-agent: *\nDisallow: /\n")
  assert_true(r.allowed(UA, "/robots.txt"))
  assert_true(!r.allowed(UA, "/"))
}

///|
test "robots: UTF-8 BOM 不影响首条指令" {
  let r = @mooncrawl.parse_robots("\u{FEFF}User-agent: *\nDisallow: /secret\n")
  assert_true(!r.allowed(UA, "/secret/x"))
  assert_true(r.allowed(UA, "/open"))
}

///|
test "robots: 真实风格文件端到端" {
  let r = @mooncrawl.parse_robots(
    "User-agent: *\nDisallow: /admin\nCrawl-delay: 1\n\nUser-agent: mooncrawl\nDisallow: /admin/secret\nAllow: /admin/\n\nSitemap: https://example.com/sitemap.xml",
  )
  assert_true(!r.allowed(UA, "/admin/secret/x")) // 更长的 Disallow
  assert_true(r.allowed(UA, "/admin/settings")) // 组内 Allow 且比 * 组更具体
  assert_eq(r.crawl_delay_ms(UA), None) // mooncrawl 组未声明 Crawl-delay
  assert_eq(r.crawl_delay_ms("randombot"), Some(1000)) // 回退 * 组
  assert_eq(r.sitemaps().length(), 1)
}
