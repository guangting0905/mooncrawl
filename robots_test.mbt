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

///|
test "robots: 百分号编码的 unreserved 字符参与比较（RFC 9309 §2.2.2）" {
  // 规则写 %7E，请求写 ~：同一路径
  let r1 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /a%7Eb\n")
  assert_true(!r1.allowed(UA, "/a~b"))
  assert_true(r1.allowed(UA, "/a~c"))
  // 反向：规则写 ~，请求写 %7E
  let r2 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /a~b\n")
  assert_true(!r2.allowed(UA, "/a%7Eb"))
  // 保留字符不解码：%2F 与 / 必须保持不同
  let r3 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /a%2Fb\n")
  assert_true(r3.allowed(UA, "/a/b"))
  assert_true(!r3.allowed(UA, "/a%2Fb"))
  // 非法转义原样保留，规则照常生效
  let r4 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /a%zzb\n")
  assert_true(!r4.allowed(UA, "/a%zzb/x"))
}

///|
test "robots: 非 ASCII 路径两侧编码形式一致（RFC 9309 §2.2.2）" {
  // 规则写原文，请求写百分号编码：同一路径
  let r1 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /café\n")
  assert_true(!r1.allowed(UA, "/caf%C3%A9"))
  assert_true(!r1.allowed(UA, "/café"))
  assert_true(r1.allowed(UA, "/cafes"))
  // 反向：规则写百分号编码，请求写原文
  let r2 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /caf%C3%A9\n")
  assert_true(!r2.allowed(UA, "/café"))
  // 三字节 UTF-8（中文）
  let r3 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /文档\n")
  assert_true(!r3.allowed(UA, "/%E6%96%87%E6%A1%A3"))
  assert_true(r3.allowed(UA, "/%E6%96%87%E6%A1%A4"))
  // 十六进制位大小写等价（RFC 3986 §6.2.2.1）
  let r4 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /caf%c3%a9\n")
  assert_true(!r4.allowed(UA, "/caf%C3%A9"))
}

///|
test "robots: 不属于任何组的裸规则被忽略（RFC 9309 §2.2.2）" {
  let r = @mooncrawl.parse_robots(
    "Disallow: /secret\nUser-agent: *\nDisallow: /other\n",
  )
  assert_true(r.allowed(UA, "/secret"))
  assert_true(!r.allowed(UA, "/other"))
  // 整份文件只有裸规则：无规则适用，全部允许
  let r2 = @mooncrawl.parse_robots("Disallow: /\nCrawl-delay: 1\n")
  assert_true(r2.allowed(UA, "/x"))
  assert_eq(r2.crawl_delay_ms(UA), None)
}

///|
test "robots: 通配符模式不产生指数回溯" {
  // 20 个 * 的规则 + 36 字符路径。逐字符递归的旧实现会在这种输入上
  // 组合数爆炸（实测 16 个 * 就超过 45 秒），本用例同时钉住性能与结果。
  let buf = StringBuilder()
  buf.write_string("User-agent: *\nDisallow: /a")
  let mut i = 0
  while i < 20 {
    buf.write_string("*a")
    i = i + 1
  }
  buf.write_string("b\n")
  let r = @mooncrawl.parse_robots(buf.to_string())
  let mut path = "/"
  let mut j = 0
  while j < 36 {
    path = path + "a"
    j = j + 1
  }
  // 模式要求以 b 结尾，路径没有 b：必为允许
  assert_true(r.allowed(UA, path))
  // 重复判定 200 次，线性实现瞬间完成
  let mut k = 0
  while k < 200 {
    let _ = r.allowed(UA, path)
    k = k + 1
  }
}

///|
test "robots: 通配符边界——连续 *、末尾 * 与 $ 组合" {
  let r = @mooncrawl.parse_robots(
    "User-agent: *\nDisallow: /a**b\nDisallow: /c$\n",
  )
  assert_true(!r.allowed(UA, "/axxb"))
  assert_true(!r.allowed(UA, "/ab"))
  assert_true(!r.allowed(UA, "/c"))
  assert_true(r.allowed(UA, "/cd"))
  // `*` 可吃掉任意长度，因此 `/c*$` 对任意以 /c 开头的路径都成立
  let r2 = @mooncrawl.parse_robots("User-agent: *\nDisallow: /c*$\n")
  assert_true(!r2.allowed(UA, "/cddddx"))
}

///|
test "robots: 超过 1 MiB 的解析上限后截断（RFC 9309 §2.5）" {
  let buf = StringBuilder()
  buf.write_string("User-agent: *\nDisallow: /blocked\n")
  let mut i = 0
  while i < 1_100_000 {
    buf.write_char('#')
    i = i + 1
  }
  let r = @mooncrawl.parse_robots(buf.to_string())
  // 截断点之前的规则必须照常生效
  assert_true(!r.allowed(UA, "/blocked"))
  assert_true(r.allowed(UA, "/other"))
}
