// robots.txt 解析与匹配（RFC 9309 实用子集）。
//
// Polite crawling 的第一道闸门：引擎在抓取任何 URL 前先用本模块
// 判定是否允许，并读取 Crawl-delay 作为限速下限。
//
// 匹配约定与主流实现一致：
// - 组选择：与目标 UA 前缀匹配的组里取「最长 agent 前缀」的组；
//   没有匹配组时回退到 `*` 组；连 `*` 组都没有则允许一切。
// - 规则匹配：`*` 匹配任意序列，结尾 `$` 锚定路径末尾；
//   Allow/Disallow 同时命中时取模式更长的；等长时 Allow 优先。

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
fn glob_match(pattern : String, path : String) -> Bool {
  let mut pat = pattern
  let mut anchored : Bool = false
  let pc = chars_of(pattern)
  if pc.length() > 0 && pc[pc.length() - 1] == '$' {
    anchored = true
    pat = slice(pc, 0, pc.length() - 1)
  }
  // 按 '*' 切分模式段
  let pcs = chars_of(pat)
  let segs : Array[Array[Char]] = []
  let mut start : Int32 = 0
  let mut i : Int32 = 0
  while i <= pcs.length() {
    if i == pcs.length() || pcs[i] == '*' {
      segs.push(subarray(pcs, start, i))
      if i < pcs.length() {
        i = i + 1
      } else {
        break
      }
      start = i
    } else {
      i = i + 1
    }
  }
  let a = chars_of(path)
  return glob_segs_match(segs, 0, a, 0, anchored)
}

///|
fn subarray(cs : Array[Char], a : Int32, b : Int32) -> Array[Char] {
  let out : Array[Char] = []
  let mut i : Int32 = a
  while i < b {
    out.push(cs[i])
    i = i + 1
  }
  out
}

///|
fn seg_eq(cs : Array[Char], pos : Int32, seg : Array[Char]) -> Bool {
  if pos + seg.length() > cs.length() {
    return false
  }
  let mut j : Int32 = 0
  while j < seg.length() {
    if cs[pos + j] != seg[j] {
      return false
    }
    j = j + 1
  }
  true
}

///|
/// 依次消费模式段：非末段用「找子串并推进」处理，末段按锚定语义收尾。
fn glob_segs_match(
  segs : Array[Array[Char]],
  si : Int32,
  path : Array[Char],
  pos : Int32,
  anchored : Bool,
) -> Bool {
  if si == segs.length() - 1 {
    let last = segs[si]
    if anchored {
      return pos + last.length() == path.length() && seg_eq(path, pos, last)
    }
    // 非锚定：last 段允许出现在 pos 之后的任意位置
    let mut p = pos
    while p + last.length() <= path.length() {
      if seg_eq(path, p, last) {
        return true
      }
      p = p + 1
    }
    return last.length() == 0
  }
  let seg = segs[si]
  if !seg_eq(path, pos, seg) {
    return false
  }
  let next = pos + seg.length()
  if si + 1 <= segs.length() - 1 {
    // 中间段：尝试所有可能的下一段起点（由后续递归处理）
    let mut p = next
    while p <= path.length() {
      if glob_segs_match(segs, si + 1, path, p, anchored) {
        return true
      }
      p = p + 1
    }
    return false
  }
  glob_segs_match(segs, si + 1, path, next, anchored)
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
/// 依据待归属的 UA 列表创建新组；无 UA 声明时归入隐式 * 组。
fn new_group(pending : Array[String]) -> AgentGroup {
  let agents = if pending.length() > 0 { pending } else { ["*"] }
  { agents, rules: [], crawl_delay_ms: None, }
}

///|
/// 解析 robots.txt 文本。容错：忽略注释与无法识别的行；
/// 空的 Disallow/Allow 值视为无操作。
pub fn parse_robots(text : String) -> RobotsRules {
  let groups : Array[AgentGroup] = []
  let sitemaps : Array[String] = []
  let mut pending : Array[String] = []
  let mut cur : AgentGroup? = None
  let lines = split_lines(text)
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
            if cur is None {
              let g = new_group(pending)
              groups.push(g)
              cur = Some(g)
              pending = []
            }
            if value != "" {
              match cur {
                Some(g) => {
                  let _ = g.rules.push((allow, value))
                }
                None => ()
              }
            }
          }
          "crawl-delay" => {
            if cur is None {
              let g = new_group(pending)
              groups.push(g)
              cur = Some(g)
              pending = []
            }
            match cur {
              Some(g) => g.crawl_delay_ms = parse_delay_ms(value)
              None => ()
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
  while a < b && (cs[a] == ' ' || cs[a] == '\t' || cs[a] == '\r') {
    a = a + 1
  }
  while b > a && (cs[b - 1] == ' ' || cs[b - 1] == '\t' || cs[b - 1] == '\r') {
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
/// 选择适用组：agent 前缀最长匹配；无具体匹配回退 '*' 组。
fn select_group(rules : RobotsRules, agent : String) -> AgentGroup? {
  let a = lower_str(agent)
  let mut best : AgentGroup? = None
  let mut best_len : Int32 = -1
  for g in rules.groups {
    for ag in g.agents {
      if ag != "*" && starts_with(a, ag) && ag.length() > best_len {
        best = Some(g)
        best_len = ag.length()
      }
    }
  }
  match best {
    Some(_) => best
    None => {
      for g in rules.groups {
        for ag in g.agents {
          if ag == "*" {
            return Some(g)
          }
        }
      }
      None
    }
  }
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
/// 判定 agent 是否允许抓取 path（含 "?query"，不含 host 与 fragment）。
/// 无任何匹配组时允许。
pub fn RobotsRules::allowed(
  self : RobotsRules,
  agent : String,
  path : String,
) -> Bool {
  let g = match select_group(self, agent) {
    Some(g) => g
    None => return true
  }
  if g.rules.length() == 0 {
    return true
  }
  let mut best_len : Int32 = -1
  let mut verdict : Bool = true
  for entry in g.rules {
    let (allow, pat) = entry
    if glob_match(pat, path) {
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
/// 适用组的 Crawl-delay（毫秒）。无组/未声明返回 None。
pub fn RobotsRules::crawl_delay_ms(
  self : RobotsRules,
  agent : String,
) -> Int32? {
  match select_group(self, agent) {
    Some(g) => g.crawl_delay_ms
    None => None
  }
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
