// robots.txt 解析与匹配。
//
// 覆盖范围（逐条对应 RFC 9309，详见 docs/rfc9309-覆盖声明.md）：
// - §2.2.1 组选择：product token 大小写不敏感前缀匹配；同名 UA 分散在
//   多组时规则合并；多个**不同长度**的 token 同时匹配时取最长的一个
//   （这是对 RFC 字面「合并全部匹配组」的有意偏离，与主流爬虫一致，
//   理由与影响见覆盖声明 §1.1）；无具体匹配时回退 `*` 组；都没有则无规则。
// - §2.2.2 匹配：从路径第一个字节起匹配，最具体（最多八位组）的规则胜出；
//   Allow 与 Disallow 等长时 Allow 优先；组内无规则则允许；/robots.txt
//   隐式允许；不属于任何组的规则被忽略。
// - §2.2.2 百分号：比较前把两侧统一到同一形式——`%XX` 中的 unreserved
//   字符解码、十六进制位统一大写、非 ASCII 字符编码为 UTF-8 的 `%XX`。
// - §2.2.3 特殊字符：`#` 行内注释、`*` 任意序列、`$` 锚定结尾。
//
// 不在覆盖范围内（明确不承诺）：
// - §2.2.2「匹配字面 `*`/`$` 时用 `%` 编码」：请求侧的 ASCII 保留字符不做
//   编码（否则与现实中大量未编码的 robots 规则不兼容），因此规则里的
//   `%2A` 无法命中请求路径中的字面 `*`。该条为 SHOULD。
// - §2.3.1.2 重定向链：跟随行为交给传输层，本模块不解析重定向。
// - §2.4 缓存时效：缓存仅在单次 crawl 调用内有效，不跨进程。
// - §2.5 解析上限：本模块把规则文本截断到 1 MiB（满足「MUST ≥ 500 KiB」），
//   但该上限只约束解析，不约束下载与解码阶段的内存峰值。
// 状态码语义（4xx 放行 / 5xx 拒绝）在 crawl.mbt 中实现，见 RobotsUnreachable。
//
// 匹配约定与主流实现一致：
// - 规则匹配：`*` 匹配任意序列，结尾 `$` 锚定路径末尾；
//   Allow/Disallow 同时命中时取模式更长的；等长时 Allow 优先。
// - Crawl-delay 不是 RFC 9309 内容，属广泛部署的扩展；合并组时取最大值。

///|
/// 解析后的 robots.txt 规则集。
pub struct RobotsRules {
  priv groups : Array[AgentGroup]
  priv sitemaps : Array[String]
}

///|
priv struct AgentGroup {
  agents : Array[String] // 已小写
  rules : Array[(Bool, String)] // (allow, pattern)，保持文件顺序
  mut crawl_delay_ms : Int32?
}

///|
/// RFC 3986 的 unreserved 字符集：ALPHA / DIGIT / "-" / "." / "_" / "~"。
fn is_unreserved(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '-' ||
  c == '.' ||
  c == '_' ||
  c == '~'
}

///|
fn hex_val(c : Char) -> Int32? {
  if c >= '0' && c <= '9' {
    return Some(c.to_int() - '0'.to_int())
  }
  if c >= 'a' && c <= 'f' {
    return Some(c.to_int() - 'a'.to_int() + 10)
  }
  if c >= 'A' && c <= 'F' {
    return Some(c.to_int() - 'A'.to_int() + 10)
  }
  None
}

///|
/// 把一个字节写成 `%XX`（大写十六进制）。
fn write_pct_byte(buf : StringBuilder, b : Int32) -> Unit {
  let hex = "0123456789ABCDEF"
  let hcs = chars_of(hex)
  buf.write_char('%')
  buf.write_char(hcs[b / 16 % 16])
  buf.write_char(hcs[b % 16])
}

///|
/// 把一个 Unicode 码点按 UTF-8 编码写成百分号转义序列。
fn write_utf8_pct(buf : StringBuilder, cp : Int32) -> Unit {
  if cp < 0x80 {
    write_pct_byte(buf, cp)
  } else if cp < 0x800 {
    write_pct_byte(buf, 0xC0 | (cp >> 6))
    write_pct_byte(buf, 0x80 | (cp & 0x3F))
  } else if cp < 0x10000 {
    write_pct_byte(buf, 0xE0 | (cp >> 12))
    write_pct_byte(buf, 0x80 | ((cp >> 6) & 0x3F))
    write_pct_byte(buf, 0x80 | (cp & 0x3F))
  } else {
    write_pct_byte(buf, 0xF0 | (cp >> 18))
    write_pct_byte(buf, 0x80 | ((cp >> 12) & 0x3F))
    write_pct_byte(buf, 0x80 | ((cp >> 6) & 0x3F))
    write_pct_byte(buf, 0x80 | (cp & 0x3F))
  }
}

///|
/// RFC 9309 §2.2.2 要求的「比较前统一编码形式」。
///
/// 规则文本与请求路径两侧都过这一层，得到可直接逐字符比较的形式：
/// - `%XX` 且该字节是 unreserved（ALPHA / DIGIT / `-` `.` `_` `~`）→ 解码；
/// - 其余 `%XX` → 原样保留，但十六进制位统一大写（RFC 3986 §6.2.2.1）；
/// - 非 ASCII 字符 → 按 UTF-8 编码成 `%XX`（§2.2.2 前半句的 MUST）。
///
/// 因此 `/a%7Eb` 与 `/a~b` 判为同一路径，`/café` 与 `/caf%C3%A9` 亦然；
/// 而 `/a%2Fb` 与 `/a/b` 必须保持不同（`/` 是保留字符，不解码）。
fn normalize_compare_form(s : String) -> String {
  let cs = chars_of(s)
  let n : Int32 = cs.length()
  let buf = StringBuilder()
  let mut i : Int32 = 0
  while i < n {
    let c = cs[i]
    if c == '%' && i + 2 < n {
      match (hex_val(cs[i + 1]), hex_val(cs[i + 2])) {
        (Some(h), Some(l)) => {
          let v = h * 16 + l
          if v < 128 && is_unreserved(v.to_char().unwrap()) {
            buf.write_char(v.to_char().unwrap())
          } else {
            write_pct_byte(buf, v)
          }
          i = i + 3
        }
        _ => {
          buf.write_char('%')
          i = i + 1
        }
      }
    } else if c.to_int() < 128 {
      buf.write_char(c)
      i = i + 1
    } else {
      write_utf8_pct(buf, c.to_int())
      i = i + 1
    }
  }
  buf.to_string()
}

///|
/// robots 模式匹配（RFC 9309 §2.2.2）。
///
/// 匹配**从路径第一个字节开始**。末尾 `$` 锚定结尾；没有 `$` 时是前缀匹配
/// ——模式耗尽即成功，不允许模式出现在路径中间。旧实现把无 `*` 的模式当成
/// 子串搜索，导致 `Allow: /public` 错误放行 `/secret/public`。
///
/// 实现是双指针 + 单点回溯：`star_pi` 记住最近一个 `*` 的位置，失配时让它
/// 多吃一个字符重试。每轮迭代必定推进 `pi`、`si` 或 `star_si` 之一，因此
/// 总步数有上界，**不会指数爆炸**。早先的逐字符递归版本在 `a*a*a*…` 这类
/// 模式上组合数按 `C(n, k)` 增长，一个 34 字符的规则就能让匹配挂住数十秒
/// （见 `regression_test.mbt` 的 DoS 用例）。
fn glob_match(pattern : String, path : String) -> Bool {
  let pc = chars_of(pattern)
  let plen0 : Int32 = pc.length()
  let anchored : Bool = plen0 > 0 && pc[plen0 - 1] == '$'
  let plen : Int32 = if anchored { plen0 - 1 } else { plen0 }
  let sc = chars_of(path)
  let slen : Int32 = sc.length()
  let mut pi : Int32 = 0
  let mut si : Int32 = 0
  let mut star_pi : Int32 = -1
  let mut star_si : Int32 = 0
  // 上界：每步至少推进一个指针，留出余量
  let mut steps : Int32 = 0
  let max_steps : Int32 = (plen + 1) * 2 + (slen + 1) * 2 + 8
  while steps <= max_steps {
    steps = steps + 1
    if pi >= plen {
      if !anchored {
        // 前缀匹配：模式已用完，剩余路径不参与比较
        return true
      }
      if si >= slen {
        return true
      }
      // 锚定但路径还有剩余：让最近的 `*` 多吃一个字符再试
      if star_pi < 0 {
        return false
      }
      star_si = star_si + 1
      if star_si > slen {
        return false
      }
      si = star_si
      pi = star_pi + 1
      continue
    }
    if si >= slen {
      // 路径耗尽：模式剩余部分必须全是 `*`
      if pc[pi] == '*' {
        pi = pi + 1
        continue
      }
      return false
    }
    if pc[pi] == '*' {
      star_pi = pi
      star_si = si
      pi = pi + 1
    } else if pc[pi] == sc[si] {
      pi = pi + 1
      si = si + 1
    } else if star_pi >= 0 {
      star_si = star_si + 1
      if star_si > slen {
        return false
      }
      si = star_si
      pi = star_pi + 1
    } else {
      return false
    }
  }
  false
}

///|
fn parse_delay_ms(v : String) -> Int32? {
  let cs = chars_of(v)
  if cs.length() == 0 {
    return None
  }
  let mut int_part : Int32 = 0
  let mut i : Int32 = 0
  while i < cs.length() && cs[i] >= '0' && cs[i] <= '9' {
    int_part = int_part * 10 + (cs[i].to_int() - '0'.to_int())
    i = i + 1
  }
  let mut frac_ms : Int32 = 0
  if i < cs.length() && cs[i] == '.' {
    i = i + 1
    let mut scale : Int32 = 100
    while i < cs.length() && cs[i] >= '0' && cs[i] <= '9' && scale > 0 {
      frac_ms = frac_ms + (cs[i].to_int() - '0'.to_int()) * scale
      scale = scale / 10
      i = i + 1
    }
  }
  // 之后的非数字内容忽略（如单位后缀）
  Some(int_part * 1000 + frac_ms)
}

///|
/// robots.txt 的解析上限（字符数）。1 MiB 高于 RFC 9309 §2.5 要求的 500 KiB。
const ROBOTS_MAX_CHARS : Int32 = 1_048_576

///|
/// 去掉 UTF-8 BOM 与开头空白。带 BOM 的文件若原样解析，第一条
/// `User-agent` 行会因前导 U+FEFF 变成无法识别的指令，整组规则失效。
fn strip_leading_noise(text : String) -> String {
  let cs = chars_of(text)
  let n : Int32 = cs.length()
  let mut i : Int32 = 0
  if n > 0 && cs[0] == '\u{FEFF}' {
    i = 1
  }
  while i < n &&
        (cs[i] == ' ' || cs[i] == '\t' || cs[i] == '\r' || cs[i] == '\n') {
    i = i + 1
  }
  if i == 0 {
    return text
  }
  slice(cs, i, n)
}

///|
/// 依据待归属的 UA 列表创建新组。调用方保证 `pending` 非空——
/// 不属于任何组的裸规则按 RFC 9309 §2.2.2 直接忽略，不会落到这里。
fn new_group(pending : Array[String]) -> AgentGroup {
  { agents: pending, rules: [], crawl_delay_ms: None, }
}

///|
/// 解析 robots.txt 文本。容错：忽略注释与无法识别的行；
/// 空的 Disallow/Allow 值视为无操作。
pub fn parse_robots(text : String) -> RobotsRules {
  // RFC 9309 §2.5：解析限额不得低于 500 KiB。这里取 1 MiB，超出部分截断，
  // 防止畸形文件把内存吃穿；截断点之前的规则照常生效。
  let body = if text.length() > ROBOTS_MAX_CHARS {
    slice(chars_of(text), 0, ROBOTS_MAX_CHARS)
  } else {
    text
  }
  let groups : Array[AgentGroup] = []
  let sitemaps : Array[String] = []
  let mut pending : Array[String] = []
  let mut cur : AgentGroup? = None
  let lines = split_lines(strip_leading_noise(body))
  for line in lines {
    // 去注释
    let hash = find_char(line, '#')
    let content = match hash {
      Some(idx) => slice(chars_of(line), 0, idx)
      None => line
    }
    let ccs = chars_of(content)
    let colon = find_char(content, ':')
    let key_val = match colon {
      None => None
      Some(idx) =>
        Some(
          (lower_trim(ccs, 0, idx), trim_str(slice(ccs, idx + 1, ccs.length()))),
        )
    }
    match key_val {
      Some((key, value)) =>
        match key {
          "user-agent" =>
            if value != "" {
              match cur {
                // pending 为空说明上一组已产生内容（有规则/延迟），
                // 或此前只有裸规则 → 该 UA 行开启新组
                Some(_) if pending.length() == 0 => {
                  pending = [lower_str(value)]
                  cur = None
                }
                _ => pending.push(lower_str(value))
              }
            }
          "disallow" | "allow" => {
            let allow = key == "allow"
            let mut in_group : Bool = true
            if cur is None {
              if pending.length() == 0 {
                // RFC 9309 §2.2.2：不属于任何组的规则 SHOULD 被忽略。
                // 若在此处兜底成 `*` 组，文件开头的裸规则会意外生效。
                in_group = false
              } else {
                let g = new_group(pending)
                groups.push(g)
                cur = Some(g)
                pending = []
              }
            }
            if in_group && value != "" {
              match cur {
                Some(g) => {
                  let _ = g.rules.push((allow, normalize_compare_form(value)))
                }
                None => ()
              }
            }
          }
          "crawl-delay" => {
            let mut in_group : Bool = true
            if cur is None {
              if pending.length() == 0 {
                in_group = false
              } else {
                let g = new_group(pending)
                groups.push(g)
                cur = Some(g)
                pending = []
              }
            }
            if in_group {
              match cur {
                Some(g) => g.crawl_delay_ms = parse_delay_ms(value)
                None => ()
              }
            }
          }
          "sitemap" => if value != "" { sitemaps.push(value) }
          _ => ()
        }
      None => ()
    }
  }
  // 收尾：仅声明了 UA 但没有任何规则的组（语义为允许一切）
  if pending.length() > 0 {
    let g : AgentGroup = { agents: pending, rules: [], crawl_delay_ms: None, }
    groups.push(g)
  }
  { groups, sitemaps, }
}

///|
fn find_char(s : String, c : Char) -> Int32? {
  let cs = chars_of(s)
  let mut i : Int32 = 0
  while i < cs.length() {
    if cs[i] == c {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
fn lower_trim(cs : Array[Char], a : Int32, b : Int32) -> String {
  let buf = StringBuilder()
  let mut started : Bool = false
  let mut end_ : Int32 = b
  let mut i : Int32 = b
  // 右侧去空白
  while i > a {
    let c = cs[i - 1]
    if c == ' ' || c == '\t' || c == '\r' {
      end_ = i - 1
      i = i - 1
    } else {
      break
    }
  }
  i = a
  while i < end_ {
    let c = cs[i]
    if !started && (c == ' ' || c == '\t' || c == '\r') {
      i = i + 1
      continue
    }
    started = true
    if c >= 'A' && c <= 'Z' {
      buf.write_char((c.to_int() + 32).to_char().unwrap())
    } else {
      buf.write_char(c)
    }
    i = i + 1
  }
  buf.to_string()
}

///|
fn lower_str(s : String) -> String {
  ascii_lower_str(s)
}

///|
fn trim_str(s : String) -> String {
  let cs = chars_of(s)
  let mut a : Int32 = 0
  let mut b : Int32 = cs.length()
  while a < b &&
        (cs[a] == ' ' || cs[a] == '\t' || cs[a] == '\r' || cs[a] == '\n') {
    a = a + 1
  }
  while b > a &&
        (
          cs[b - 1] == ' ' ||
          cs[b - 1] == '\t' ||
          cs[b - 1] == '\r' ||
          cs[b - 1] == '\n'
        ) {
    b = b - 1
  }
  slice(cs, a, b)
}

///|
fn split_lines(text : String) -> Array[String] {
  let out : Array[String] = []
  let cs = chars_of(text)
  let n : Int32 = cs.length()
  let mut start : Int32 = 0
  let mut i : Int32 = 0
  while i <= n {
    if i == n || cs[i] == '\n' {
      let mut end_ = i
      if end_ > start && cs[end_ - 1] == '\r' {
        end_ = end_ - 1
      }
      out.push(slice(cs, start, end_))
      i = i + 1
      start = i
    } else {
      i = i + 1
    }
  }
  out
}

///|
/// 该组与 agent 的最长 product token 前缀长度；不匹配返回 -1。
/// `*` 不参与具体匹配，由 `has_wildcard` 单独处理。
fn agent_prefix_len(g : AgentGroup, agent : String) -> Int32 {
  let mut best : Int32 = -1
  for ag in g.agents {
    if ag != "*" && starts_with(agent, ag) && ag.length() > best {
      best = ag.length()
    }
  }
  best
}

///|
fn has_wildcard(g : AgentGroup) -> Bool {
  for ag in g.agents {
    if ag == "*" {
      return true
    }
  }
  false
}

///|
/// 合并后的生效规则集：规则按文件顺序拼接，Crawl-delay 取最大值。
priv struct EffectiveRules {
  rules : Array[(Bool, String)]
  crawl_delay_ms : Int32?
}

///|
/// 按 RFC 9309 §2.2.1 选出适用组并合并：
/// 1. 所有与 product token 前缀匹配的组里，取最长的 token 长度；
/// 2. 长度等于该值的**全部**组合并（同名 UA 分散在多处时规则累加）；
/// 3. 没有任何具体匹配时，合并全部 `*` 组；
/// 4. 都没有则为空规则集（无规则适用 → 允许）。
///
/// 第 1 步是对 RFC 字面表述的**有意偏离**：RFC 要求「所有匹配的组合并」，
/// 不区分 token 长度。这里采用最长优先（与 Google 等主流实现一致），
/// 代价是更具体的组可以豁免更宽泛的组所禁止的路径。取舍与可观测差异见
/// `docs/rfc9309-覆盖声明.md` §1.1。
fn effective_rules(rules : RobotsRules, agent : String) -> EffectiveRules {
  let a = lower_str(agent)
  let mut best_len : Int32 = -1
  for g in rules.groups {
    let l = agent_prefix_len(g, a)
    if l > best_len {
      best_len = l
    }
  }
  let out : Array[(Bool, String)] = []
  let mut delay : Int32? = None
  for g in rules.groups {
    let hit = if best_len >= 0 {
      agent_prefix_len(g, a) == best_len
    } else {
      has_wildcard(g)
    }
    if hit {
      for r in g.rules {
        out.push(r)
      }
      match g.crawl_delay_ms {
        Some(d) =>
          match delay {
            Some(cur) => if d > cur { delay = Some(d) }
            None => delay = Some(d)
          }
        None => ()
      }
    }
  }
  { rules: out, crawl_delay_ms: delay, }
}

///|
/// `/robots.txt` 本身隐式允许（RFC 9309 §2.2.2）。
fn is_robots_txt_path(path : String) -> Bool {
  path == "/robots.txt" || starts_with(path, "/robots.txt?")
}

///|
/// 判定 agent 是否允许抓取 path（含 "?query"，不含 host 与 fragment）。
/// 无匹配组、组内无规则或路径为 /robots.txt 时允许。
///
/// 规则与 path 都先过 `normalize_compare_form`，比较的是同一编码形式，
/// 因此 `%7E`/`~`、`café`/`caf%C3%A9` 视为同一路径，`%2F` 与 `/` 保持不同。
pub fn RobotsRules::allowed(
  self : RobotsRules,
  agent : String,
  path : String,
) -> Bool {
  if is_robots_txt_path(path) {
    return true
  }
  let eff = effective_rules(self, agent)
  if eff.rules.length() == 0 {
    return true
  }
  let path_form = normalize_compare_form(path)
  let mut best_len : Int32 = -1
  let mut verdict : Bool = true
  for entry in eff.rules {
    let (allow, pat) = entry
    if glob_match(pat, path_form) {
      let plen = chars_of(pat).length()
      if plen > best_len || (plen == best_len && allow) {
        best_len = plen
        verdict = allow
      }
    }
  }
  if best_len < 0 {
    return true
  }
  verdict
}

///|
/// 生效规则集里声明的 Crawl-delay（毫秒），多组合并时取最大值。
/// 无组/未声明返回 None。
pub fn RobotsRules::crawl_delay_ms(
  self : RobotsRules,
  agent : String,
) -> Int32? {
  effective_rules(self, agent).crawl_delay_ms
}

///|
fn starts_with(s : String, prefix : String) -> Bool {
  let sc = chars_of(s)
  let pc = chars_of(prefix)
  if pc.length() > sc.length() {
    return false
  }
  let mut i : Int32 = 0
  while i < pc.length() {
    if sc[i] != pc[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// 文件中声明的 Sitemap URL 列表。
pub fn RobotsRules::sitemaps(self : RobotsRules) -> Array[String] {
  self.sitemaps
}

///|
/// 便捷方法：对已解析的 Url 做 robots 判定（匹配目标为 path+query）。
pub fn RobotsRules::allowed_url(
  self : RobotsRules,
  agent : String,
  url : Url,
) -> Bool {
  let path = match url.query {
    Some(q) => url.path + "?" + q
    None => url.path
  }
  self.allowed(agent, path)
}
