// URL 解析、规范化与相对地址展开。
//
// 抓取器在把 URL 放入队列前必须先规范化：同一个资源的不同书写形式
// （大小写、默认端口、点段、参数顺序、fragment）折叠为同一字符串，
// 去重和 polite 策略才不会失效。
//
// 内部扫描统一基于 Array[Char]，规避 String 索引返回 UTF-16 码元的
// 语义差异；URL 实际场景以 ASCII 为主，代价可忽略。

///|
/// 解析后的 URL。fragment 在解析阶段即被丢弃（不参与去重与请求）。
pub struct Url {
  scheme : String // 小写，"http" 或 "https"
  host : String // 小写（ASCII）
  port : Int? // None 表示协议默认端口
  path : String // 以 '/' 开头
  query : String? // 不含 '?'
}

///|
fn chars_of(s : String) -> Array[Char] {
  let out : Array[Char] = []
  for c in s {
    out.push(c)
  }
  out
}

///|
fn slice(cs : Array[Char], start : Int, end_ : Int) -> String {
  let buf = StringBuilder()
  let mut i : Int = start
  while i < end_ {
    buf.write_char(cs[i])
    i = i + 1
  }
  buf.to_string()
}

///|
fn ascii_lower_slice(cs : Array[Char], a : Int, b : Int) -> String {
  let buf = StringBuilder()
  let mut i : Int = a
  while i < b {
    let c = cs[i]
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
fn ascii_lower_str(s : String) -> String {
  ascii_lower_slice(chars_of(s), 0, s.length())
}

///|
fn find_from(cs : Array[Char], needle : Array[Char], from : Int) -> Int? {
  let n : Int = cs.length()
  let m : Int = needle.length()
  if m == 0 {
    return Some(from)
  }
  let mut i : Int = from
  while i + m <= n {
    let mut j : Int = 0
    let mut ok : Bool = true
    while j < m {
      if cs[i + j] != needle[j] {
        ok = false
        break
      }
      j = j + 1
    }
    if ok {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
fn find_char_from_last(cs : Array[Char], c : Char) -> Int? {
  let mut i : Int = cs.length() - 1
  while i >= 0 {
    if cs[i] == c {
      return Some(i)
    }
    i = i - 1
  }
  None
}

///|
/// 拆分 host[:port]。支持 '[IPv6]' 字面量与 userinfo 之后的尾部。
/// 端口非法时返回 None。
fn split_port(hp : Array[Char], start : Int, end_ : Int) -> (String, Int?)? {
  let mut colon : Int = -1
  let mut in_brackets : Bool = false
  let mut i : Int = start
  while i < end_ {
    let c = hp[i]
    if c == '[' {
      in_brackets = true
    } else if c == ']' {
      in_brackets = false
    } else if c == ':' && !in_brackets {
      colon = i
      break
    }
    i = i + 1
  }
  if colon < 0 {
    return Some((slice(hp, start, end_), None))
  }
  let host = slice(hp, start, colon)
  let mut j : Int = colon + 1
  if j == end_ {
    // "host:" 视为无端口
    return Some((host, None))
  }
  let mut p : Int = 0
  while j < end_ {
    let c = hp[j]
    if c >= '0' && c <= '9' {
      p = p * 10 + (c.to_int() - '0'.to_int())
    } else {
      return None
    }
    j = j + 1
  }
  if p < 1 || p > 65535 {
    return None
  }
  Some((host, Some(p)))
}

///|
/// 解析绝对 http/https URL。
/// 非绝对地址、非 http(s) 协议或端口非法时返回 None。
pub fn parse_url(input : String) -> Url? {
  let s = chars_of(input)
  let full_n : Int = s.length()
  // fragment 分隔符全局截断：'#' 之后不参与解析
  let mut n : Int = full_n
  let mut fi : Int = 0
  while fi < full_n {
    if s[fi] == '#' {
      n = fi
      break
    }
    fi = fi + 1
  }
  let sep_at = match find_from(s, chars_of("://"), 0) {
    Some(i) => i
    None => return None
  }
  let scheme = ascii_lower_slice(s, 0, sep_at)
  if scheme != "http" && scheme != "https" {
    return None
  }
  let after : Int = sep_at + 3
  // authority 结束于第一个 '/' 或 '?'
  let mut auth_end : Int = n
  let mut path_start : Int = n
  let mut query_start : Int = -1
  let mut i : Int = after
  while i < n {
    let c = s[i]
    if c == '/' {
      auth_end = i
      path_start = i
      break
    } else if c == '?' {
      auth_end = i
      path_start = i
      query_start = i
      break
    }
    i = i + 1
  }
  if query_start < 0 && path_start < n {
    let mut j : Int = path_start
    while j < n {
      if s[j] == '?' {
        query_start = j
        break
      }
      j = j + 1
    }
  }
  // authority 取最后一个 '@' 之后的部分（丢弃 userinfo）
  let mut hp_start : Int = after
  let mut k : Int = after
  while k < auth_end {
    if s[k] == '@' {
      hp_start = k + 1
    }
    k = k + 1
  }
  let (host_raw, port) = match split_port(s, hp_start, auth_end) {
    Some(hp) => hp
    None => return None
  }
  if host_raw.length() == 0 {
    return None
  }
  let query = if query_start >= 0 {
    Some(slice(s, query_start + 1, n))
  } else {
    None
  }
  let path_raw = if path_start >= n {
    ""
  } else if query_start >= 0 {
    slice(s, path_start, query_start)
  } else {
    slice(s, path_start, n)
  }
  let path = if path_raw == "" { "/" } else { path_raw }
  Some({ scheme, host: ascii_lower_str(host_raw), port, path, query, })
}

///|
fn is_default_port(scheme : String, p : Int) -> Bool {
  (scheme == "http" && p == 80) || (scheme == "https" && p == 443)
}

///|
/// 折叠路径中的 '.' / '..' 段与重复斜杠，保留结尾斜杠语义。
fn normalize_path(p : String) -> String {
  let cs = chars_of(p)
  let n : Int = cs.length()
  if n == 0 {
    return "/"
  }
  let segs : Array[String] = []
  let mut start : Int = 1
  let mut i : Int = 1
  let mut trailing : Bool = false
  while i <= n {
    if i == n || cs[i] == '/' {
      if i > start {
        let seg = slice(cs, start, i)
        if seg == ".." {
          if segs.length() > 0 {
            let _ = segs.pop()
          }
        } else if seg != "." {
          segs.push(seg)
        }
      }
      trailing = i == n && n > 1 && cs[n - 1] == '/'
      if i == n {
        break
      }
      i = i + 1
      start = i
    } else {
      i = i + 1
    }
  }
  let buf = StringBuilder()
  let mut first : Bool = true
  for seg in segs {
    if !first {
      buf.write_string("/")
    }
    buf.write_string(seg)
    first = false
  }
  let out = "/" + buf.to_string()
  if trailing && out != "/" {
    out + "/"
  } else {
    out
  }
}

///|
fn str_cmp(a : String, b : String) -> Int {
  let ac = chars_of(a)
  let bc = chars_of(b)
  let n = if ac.length() < bc.length() { ac.length() } else { bc.length() }
  let mut i : Int = 0
  while i < n {
    let ca = ac[i].to_int()
    let cb = bc[i].to_int()
    if ca != cb {
      return ca - cb
    }
    i = i + 1
  }
  ac.length() - bc.length()
}

///|
fn pair_cmp(x : (String, Bool, String), y : (String, Bool, String)) -> Int {
  let (k1, h1, v1) = x
  let (k2, h2, v2) = y
  let c = str_cmp(k1, k2)
  if c != 0 {
    return c
  }
  if h1 != h2 {
    // 无值参数排在有值参数之前
    return if h1 { 1 } else { -1 }
  }
  str_cmp(v1, v2)
}

///|
/// query 参数按 key（再按 value）字典序排序后重组。
fn normalize_query(q : String) -> String {
  let cs = chars_of(q)
  let n : Int = cs.length()
  let pairs : Array[(String, Bool, String)] = []
  let mut start : Int = 0
  let mut i : Int = 0
  while i <= n {
    if i == n || cs[i] == '&' {
      if i > start {
        let item = slice(cs, start, i)
        match find_from(cs, chars_of("="), start) {
          Some(idx) if idx < i =>
            pairs.push((slice(cs, start, idx), true, slice(cs, idx + 1, i)))
          _ => pairs.push((item, false, ""))
        }
      }
      i = i + 1
      start = i
    } else {
      i = i + 1
    }
  }
  // 插入排序：单个 URL 的参数数量很小
  let len : Int = pairs.length()
  let mut a : Int = 1
  while a < len {
    let cur = pairs[a]
    let mut b : Int = a - 1
    while b >= 0 && pair_cmp(pairs[b], cur) > 0 {
      pairs[b + 1] = pairs[b]
      b = b - 1
    }
    pairs[b + 1] = cur
    a = a + 1
  }
  let buf = StringBuilder()
  let mut first : Bool = true
  for kv in pairs {
    let (k, has_v, v) = kv
    if !first {
      buf.write_string("&")
    }
    first = false
    buf.write_string(k)
    if has_v {
      buf.write_string("=")
      buf.write_string(v)
    }
  }
  buf.to_string()
}

///|
/// 规范化为标准字符串形式：小写 scheme/host、省略默认端口、
/// 点段折叠、参数排序、fragment 去除（解析时已去）。
pub fn normalize_url(u : Url) -> String {
  let buf = StringBuilder()
  buf.write_string(u.scheme)
  buf.write_string("://")
  buf.write_string(u.host)
  match u.port {
    Some(p) =>
      if !is_default_port(u.scheme, p) {
        buf.write_string(":")
        buf.write_string(p.to_string())
      }
    None => ()
  }
  buf.write_string(normalize_path(u.path))
  match u.query {
    Some(q) =>
      if q != "" {
        buf.write_string("?")
        buf.write_string(normalize_query(q))
      }
    None => ()
  }
  buf.to_string()
}

///|
fn starts_with_root(pp : String) -> Bool {
  let cs = chars_of(pp)
  cs.length() > 0 && cs[0] == '/'
}

///|
/// 检测 href 是否以非 http(s) 的 scheme 前缀开头
/// （javascript:、mailto: 等），是则拒绝解析。
fn has_foreign_scheme(h : Array[Char]) -> Bool {
  let n : Int = h.length()
  if n == 0 {
    return false
  }
  let first = h[0]
  if !((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z')) {
    return false
  }
  let mut i : Int = 0
  while i < n {
    let c = h[i]
    if c == ':' {
      let sch = ascii_lower_slice(h, 0, i)
      return sch != "http" && sch != "https"
    }
    let is_alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    let is_scheme_extra = i > 0 &&
      ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.')
    if !is_alpha && !is_scheme_extra {
      return false
    }
    i = i + 1
  }
  false
}

///|
/// 以 base 为基准展开相对地址。
/// 空地址、纯 fragment、javascript:/mailto: 等非 http(s) 地址返回 None。
pub fn resolve_url(base : Url, href : String) -> Url? {
  let h = chars_of(href.trim().to_owned())
  let hn : Int = h.length()
  if hn == 0 {
    return None
  }
  if h[0] == '#' {
    return None
  }
  if has_foreign_scheme(h) {
    return None
  }
  // 丢弃 fragment
  let mut end2 : Int = hn
  let mut f : Int = 0
  while f < hn {
    if h[f] == '#' {
      end2 = f
      break
    }
    f = f + 1
  }
  if end2 == 0 {
    return None
  }
  // 绝对地址
  let mut a : Int = 0
  while a + 3 <= end2 {
    if h[a] == ':' && h[a + 1] == '/' && h[a + 2] == '/' {
      return parse_url(slice(h, 0, end2))
    }
    a = a + 1
  }
  // scheme 相对：//host/path
  if end2 >= 2 && h[0] == '/' && h[1] == '/' {
    return parse_url(base.scheme + ":" + slice(h, 0, end2))
  }
  // 查询相对：?x=1
  if h[0] == '?' {
    return Some({
      scheme: base.scheme,
      host: base.host,
      port: base.port,
      path: base.path,
      query: Some(slice(h, 1, end2)),
    })
  }
  let mut qpos : Int = -1
  let mut q : Int = 0
  while q < end2 {
    if h[q] == '?' {
      qpos = q
      break
    }
    q = q + 1
  }
  let (path_part, query) = if qpos >= 0 {
    (slice(h, 0, qpos), Some(slice(h, qpos + 1, end2)))
  } else {
    (slice(h, 0, end2), None)
  }
  let merged = if starts_with_root(path_part) {
    path_part
  } else {
    let bcs = chars_of(base.path)
    let dir = match find_char_from_last(bcs, '/') {
      Some(idx) => slice(bcs, 0, idx + 1)
      None => "/"
    }
    normalize_path(dir + path_part)
  }
  Some({
    scheme: base.scheme,
    host: base.host,
    port: base.port,
    path: merged,
    query,
  })
}
