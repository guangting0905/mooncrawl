// CSS 选择器子集与声明式字段提取。
//
// 采集器的「提什么」不该写死在代码里。本模块在 moonbit-community/html
// 解析出的 DOM 上做选择器匹配，把「容器 + 字段 → 记录」表达成数据，
// 调用方换站点只需要换选择器，不必改代码、不必重新编译引擎。
//
// 选择器语法（CSS Selectors Level 4 的可实现子集）：
//   selector-list := complex ("," complex)*
//   complex       := compound (combinator compound)*
//   combinator    := " "（后代） | ">"（子代）
//   compound      := (type | "*")? simple*
//   simple        := "." name | "#" name
//                  | "[" attr (op value)? "]"
//                  | ":first-child"
//   op            := "=" | "~=" | "^=" | "$=" | "*=" | "|="
//
// 明确不支持（不声明、不假装支持）：伪元素、`:not()`/`:has()`、
// 兄弟组合子 `+`/`~`、`nth-child` 表达式、CSS 转义序列。遇到无法识别的
// 语法时 `Selector::parse` 返回空选择器——匹配 0 个节点，而不是猜。

///|
/// 属性谓词：`[name]` 仅判存在，其余按 op 比较。
pub(all) struct AttrPredicate {
  name : String
  op : String // "" | "=" | "~=" | "^=" | "$=" | "*=" | "|="
  value : String
}

///|
/// 单个简单选择器。
pub(all) enum SimpleSelector {
  TagSel(String) // 含 "*"
  ClassSel(String)
  IdSel(String)
  AttrSel(AttrPredicate)
  FirstChildSel
}

///|
/// 复合选择器：一串简单选择器 + 它与前一个复合选择器之间的组合子。
/// `combinator` 取 ""（链首）、" "（后代）、">"（子代）。
pub(all) struct CompoundSelector {
  simples : Array[SimpleSelector]
  combinator : String
}

///|
/// 解析后的选择器：多个以逗号分隔的复杂选择器。
pub(all) struct Selector {
  chains : Array[Array[CompoundSelector]]
}

///|
/// 解析失败或空输入时返回的选择器（匹配 0 个节点）。
pub fn Selector::empty() -> Selector {
  { chains: [], }
}

///|
pub fn Selector::is_empty(self : Selector) -> Bool {
  self.chains.length() == 0
}

///|
fn is_ws(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
fn is_name_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '-' ||
  c == '_' ||
  c.to_int() > 127
}

///|
fn read_name(cs : Array[Char], from : Int32) -> (String, Int32) {
  let buf = StringBuilder()
  let mut i : Int32 = from
  let n : Int32 = cs.length()
  while i < n && is_name_char(cs[i]) {
    buf.write_char(cs[i])
    i = i + 1
  }
  (buf.to_string(), i)
}

///|
fn trim_ws(s : String) -> String {
  let cs = chars_of(s)
  let n : Int32 = cs.length()
  let mut a : Int32 = 0
  let mut b : Int32 = n
  while a < b && is_ws(cs[a]) {
    a = a + 1
  }
  while b > a && is_ws(cs[b - 1]) {
    b = b - 1
  }
  slice(cs, a, b)
}

///|
fn unquote(s : String) -> String {
  let cs = chars_of(s)
  let n : Int32 = cs.length()
  if n >= 2 &&
    ((cs[0] == '"' && cs[n - 1] == '"') || (cs[0] == '\'' && cs[n - 1] == '\'')) {
    slice(cs, 1, n - 1)
  } else {
    s
  }
}

///|
/// 解析 `[name op value]` 的内部文本。
fn parse_attr_body(body : String) -> AttrPredicate? {
  let cs = chars_of(body)
  let n : Int32 = cs.length()
  let (name, after_name) = read_name(cs, 0)
  if name == "" {
    return None
  }
  let mut i : Int32 = after_name
  while i < n && is_ws(cs[i]) {
    i = i + 1
  }
  if i >= n {
    return Some({ name, op: "", value: "", })
  }
  // 读取操作符：可能是一到两个字符
  let mut op = ""
  if cs[i] == '=' {
    op = "="
    i = i + 1
  } else if i + 1 < n && cs[i + 1] == '=' {
    let c = cs[i]
    if c == '~' || c == '^' || c == '$' || c == '*' || c == '|' {
      op = slice(cs, i, i + 2)
      i = i + 2
    }
  }
  if op == "" {
    return None
  }
  while i < n && is_ws(cs[i]) {
    i = i + 1
  }
  Some({ name, op, value: unquote(trim_ws(slice(cs, i, n))), })
}

///|
/// 扫描出的选择器词法单元。
priv enum SelTok {
  TName(String)
  TClass(String)
  TId(String)
  TAttr(AttrPredicate)
  TFirstChild
  TDesc
  TChild
  TComma
}

///|
fn tokenize_selector(input : String) -> Array[SelTok]? {
  let cs = chars_of(input)
  let n : Int32 = cs.length()
  let out : Array[SelTok] = []
  let mut i : Int32 = 0
  while i < n {
    let c = cs[i]
    if is_ws(c) {
      // 连续空白折叠成一个后代组合子；紧跟在逗号/子代符后不重复记录
      while i < n && is_ws(cs[i]) {
        i = i + 1
      }
      let last = out.length() - 1
      let redundant = match out.length() {
        0 => true
        _ =>
          match out[last] {
            TComma | TChild | TDesc => true
            _ => false
          }
      }
      if !redundant {
        out.push(TDesc)
      }
    } else if c == ',' {
      out.push(TComma)
      i = i + 1
    } else if c == '>' {
      // 覆盖掉紧邻的后代组合子
      match out.length() {
        0 => ()
        _ =>
          match out[out.length() - 1] {
            TDesc => out[out.length() - 1] = TChild
            _ => out.push(TChild)
          }
      }
      i = i + 1
    } else if c == '.' {
      let (name, next) = read_name(cs, i + 1)
      if name == "" {
        return None
      }
      out.push(TClass(name))
      i = next
    } else if c == '#' {
      let (name, next) = read_name(cs, i + 1)
      if name == "" {
        return None
      }
      out.push(TId(name))
      i = next
    } else if c == '[' {
      let mut j : Int32 = i + 1
      let mut closed : Bool = false
      while j < n {
        if cs[j] == ']' {
          closed = true
          break
        }
        j = j + 1
      }
      if !closed {
        return None
      }
      match parse_attr_body(slice(cs, i + 1, j)) {
        Some(pred) => out.push(TAttr(pred))
        None => return None
      }
      i = j + 1
    } else if c == ':' {
      let (name, next) = read_name(cs, i + 1)
      // 只支持 :first-child；其余伪类视为无法识别
      if name != "first-child" {
        return None
      }
      out.push(TFirstChild)
      i = next
    } else if c == '*' {
      out.push(TName("*"))
      i = i + 1
    } else if is_name_char(c) {
      let (name, next) = read_name(cs, i)
      out.push(TName(name))
      i = next
    } else {
      return None
    }
  }
  Some(out)
}

///|
/// 解析选择器字符串。非法语法返回 `Selector::empty()`。
pub fn Selector::parse(input : String) -> Selector {
  let tokens = match tokenize_selector(input) {
    Some(t) => t
    None => return Selector::empty()
  }
  let chains : Array[Array[CompoundSelector]] = []
  let mut chain : Array[CompoundSelector] = []
  let mut simples : Array[SimpleSelector] = []
  let mut pending : String = "" // 待挂到下一个复合选择器上的组合子
  let mut next_comb : String = ""
  for tok in tokens {
    let is_combinator = match tok {
      TComma | TDesc | TChild => true
      _ => false
    }
    if is_combinator {
      match tok {
        TComma => {
          if simples.length() > 0 {
            chain.push({ simples, combinator: pending, })
            simples = []
          }
          if chain.length() > 0 {
            chains.push(chain)
            chain = []
          }
          pending = ""
          next_comb = ""
        }
        TDesc => next_comb = " "
        _ => next_comb = ">"
      }
      continue
    }
    if next_comb != "" && simples.length() > 0 {
      chain.push({ simples, combinator: pending, })
      simples = []
      pending = next_comb
      next_comb = ""
    }
    match tok {
      TName(name) => simples.push(TagSel(name))
      TClass(name) => simples.push(ClassSel(name))
      TId(name) => simples.push(IdSel(name))
      TAttr(pred) => simples.push(AttrSel(pred))
      _ => simples.push(FirstChildSel)
    }
  }
  if simples.length() > 0 {
    chain.push({ simples, combinator: pending, })
  }
  if chain.length() > 0 {
    chains.push(chain)
  }
  { chains, }
}

///|
fn attr_value(el : @html.Element, name : String) -> String? {
  for pair in el.attributes {
    let (k, v) = pair
    if k == name {
      return Some(v)
    }
  }
  None
}

///|
fn split_words(s : String) -> Array[String] {
  let out : Array[String] = []
  let cs = chars_of(s)
  let n : Int32 = cs.length()
  let mut start : Int32 = 0
  let mut i : Int32 = 0
  while i <= n {
    if i == n || is_ws(cs[i]) {
      if i > start {
        out.push(slice(cs, start, i))
      }
      i = i + 1
      start = i
    } else {
      i = i + 1
    }
  }
  out
}

///|
fn starts_with_str(s : String, prefix : String) -> Bool {
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
fn ends_with_str(s : String, suffix : String) -> Bool {
  let sc = chars_of(s)
  let pc = chars_of(suffix)
  if pc.length() > sc.length() {
    return false
  }
  let off = sc.length() - pc.length()
  let mut i : Int32 = 0
  while i < pc.length() {
    if sc[off + i] != pc[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn contains_str(s : String, needle : String) -> Bool {
  let sc = chars_of(s)
  let pc = chars_of(needle)
  if pc.length() == 0 {
    return true
  }
  if pc.length() > sc.length() {
    return false
  }
  let mut i : Int32 = 0
  while i + pc.length() <= sc.length() {
    let mut j : Int32 = 0
    let mut ok : Bool = true
    while j < pc.length() {
      if sc[i + j] != pc[j] {
        ok = false
        break
      }
      j = j + 1
    }
    if ok {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn attr_matches(actual : String, pred : AttrPredicate) -> Bool {
  match pred.op {
    "" => true
    "=" => actual == pred.value
    "~=" => {
      let words = split_words(actual)
      let mut hit : Bool = false
      for w in words {
        if w == pred.value {
          hit = true
          break
        }
      }
      hit
    }
    "^=" => pred.value != "" && starts_with_str(actual, pred.value)
    "$=" => pred.value != "" && ends_with_str(actual, pred.value)
    "*=" => pred.value != "" && contains_str(actual, pred.value)
    "|=" => actual == pred.value || starts_with_str(actual, pred.value + "-")
    _ => false
  }
}

///|
fn is_first_element_child(doc : @html.Document, node : Int32) -> Bool {
  let p = doc.get_parent(node)
  if p < 0 || p == node {
    return false
  }
  for child in doc.get_children(p) {
    match doc.get_node(child) {
      Some(@html.ElementNode(_)) => return child == node
      _ => ()
    }
  }
  false
}

///|
fn matches_simple(
  doc : @html.Document,
  node : Int32,
  el : @html.Element,
  s : SimpleSelector,
) -> Bool {
  match s {
    TagSel(tag) => tag == "*" || el.tag_name == tag
    ClassSel(cls) =>
      match attr_value(el, "class") {
        Some(v) => {
          let words = split_words(v)
          let mut hit : Bool = false
          for w in words {
            if w == cls {
              hit = true
              break
            }
          }
          hit
        }
        None => false
      }
    IdSel(id) =>
      match attr_value(el, "id") {
        Some(v) => v == id
        None => false
      }
    AttrSel(pred) =>
      match attr_value(el, pred.name) {
        Some(v) => attr_matches(v, pred)
        None => false
      }
    FirstChildSel => is_first_element_child(doc, node)
  }
}

///|
fn matches_compound(
  doc : @html.Document,
  node : Int32,
  c : CompoundSelector,
) -> Bool {
  match doc.get_node(node) {
    Some(@html.ElementNode(el)) => {
      for s in c.simples {
        if !matches_simple(doc, node, el, s) {
          return false
        }
      }
      true
    }
    _ => false
  }
}

///|
/// node 是否位于 root 的子树内（含 root 自身）。用来把匹配限制在
/// `extract_records` 的容器内部，避免字段选择器越过容器边界。
fn is_within(doc : @html.Document, node : Int32, root : Int32) -> Bool {
  let mut p = node
  let mut steps : Int32 = 0
  while p >= 0 && steps < 512 {
    if p == root {
      return true
    }
    let q = doc.get_parent(p)
    if q == p {
      return false
    }
    p = q
    steps = steps + 1
  }
  false
}

///|
fn matches_chain(
  doc : @html.Document,
  node : Int32,
  chain : Array[CompoundSelector],
  idx : Int32,
  root : Int32,
) -> Bool {
  if !is_within(doc, node, root) {
    return false
  }
  if !matches_compound(doc, node, chain[idx]) {
    return false
  }
  if idx == 0 {
    return true
  }
  let combinator = chain[idx].combinator
  if combinator == ">" {
    let p = doc.get_parent(node)
    if p < 0 || p == node {
      return false
    }
    return matches_chain(doc, p, chain, idx - 1, root)
  }
  // 后代：沿祖先链逐个尝试
  let mut p = doc.get_parent(node)
  while p >= 0 && p != node {
    if matches_chain(doc, p, chain, idx - 1, root) {
      return true
    }
    p = doc.get_parent(p)
  }
  false
}

///|
fn walk_elements(
  doc : @html.Document,
  node : Int32,
  visit : (Int32) -> Unit,
) -> Unit {
  if node < 0 {
    return
  }
  match doc.get_node(node) {
    Some(@html.ElementNode(el)) => {
      visit(node)
      for child in el.children {
        walk_elements(doc, child, visit)
      }
    }
    _ => ()
  }
}

///|
/// 在整篇文档内按选择器收集节点（文档顺序，不重复）。
fn select_nodes(
  doc : @html.Document,
  sel : Selector,
  root : Int32,
) -> Array[Int32] {
  let out : Array[Int32] = []
  if sel.is_empty() {
    return out
  }
  walk_elements(doc, root, fn(node) {
    for chain in sel.chains {
      if matches_chain(doc, node, chain, chain.length() - 1, root) {
        let _ = out.push(node)
        return
      }
    }
  })
  out
}

///|
/// 选中节点的可见文本（去 script/style/noscript，折叠空白）。
fn node_text(doc : @html.Document, node : Int32) -> String {
  let parts : Array[String] = []
  collect_text(doc, node, parts)
  join_collapsed(parts)
}

///|
/// 按选择器提取文本，返回文档顺序的数组。
pub fn select_texts(html : String, selector : String) -> Array[String] {
  let doc = @html.parse(html)
  let sel = Selector::parse(selector)
  let out : Array[String] = []
  for node in select_nodes(doc, sel, doc.document_element) {
    out.push(node_text(doc, node))
  }
  out
}

///|
/// 按选择器提取指定属性的值；缺该属性的节点被跳过。
pub fn select_attrs(
  html : String,
  selector : String,
  attr : String,
) -> Array[String] {
  let doc = @html.parse(html)
  let sel = Selector::parse(selector)
  let out : Array[String] = []
  for node in select_nodes(doc, sel, doc.document_element) {
    match doc.get_node(node) {
      Some(@html.ElementNode(el)) =>
        match attr_value(el, attr) {
          Some(v) => out.push(v)
          None => ()
        }
      _ => ()
    }
  }
  out
}

///|
/// 按选择器统计匹配节点数。
pub fn select_count(html : String, selector : String) -> Int32 {
  let doc = @html.parse(html)
  select_nodes(doc, Selector::parse(selector), doc.document_element).length()
}

///|
/// 一个待提取字段：名称 + 选择器 + 可选取属性（None 取文本）。
pub(all) struct FieldSpec {
  name : String
  selector : String
  attr : String?
}

///|
/// 文本字段构造。
pub fn FieldSpec::text(name : String, selector : String) -> FieldSpec {
  { name, selector, attr: None, }
}

///|
/// 属性字段构造（如 `FieldSpec::attr("link", "a.next", "href")`）。
pub fn FieldSpec::attr(
  name : String,
  selector : String,
  attr : String,
) -> FieldSpec {
  { name, selector, attr: Some(attr), }
}

///|
/// 在给定节点上取一个字段的值；无匹配返回空串。
fn field_value(doc : @html.Document, root : Int32, spec : FieldSpec) -> String {
  let nodes = select_nodes(doc, Selector::parse(spec.selector), root)
  if nodes.length() == 0 {
    return ""
  }
  let first = nodes[0]
  match spec.attr {
    None => node_text(doc, first)
    Some(name) =>
      match doc.get_node(first) {
        Some(@html.ElementNode(el)) =>
          match attr_value(el, name) {
            Some(v) => v
            None => ""
          }
        _ => ""
      }
  }
}

///|
/// 从整页提取一组字段（每个字段取首个匹配），返回 (字段名, 值) 对。
/// 字段无匹配时值为空串，保证 CSV 列数稳定。
pub fn extract_fields(
  html : String,
  fields : Array[FieldSpec],
) -> Array[(String, String)] {
  let doc = @html.parse(html)
  let out : Array[(String, String)] = []
  for spec in fields {
    out.push((spec.name, field_value(doc, doc.document_element, spec)))
  }
  out
}

///|
/// 列表页采集：对每个容器匹配，在容器子树内提取字段，得到一张表。
///
/// 字段选择器不会越过容器边界（`matches_chain` 的 root 约束），因此
/// 容器内的相对选择器不会误取兄弟容器的内容。
pub fn extract_records(
  html : String,
  container : String,
  fields : Array[FieldSpec],
) -> Array[Array[(String, String)]] {
  let doc = @html.parse(html)
  let out : Array[Array[(String, String)]] = []
  let roots = select_nodes(
    doc,
    Selector::parse(container),
    doc.document_element,
  )
  for root in roots {
    let row : Array[(String, String)] = []
    for spec in fields {
      row.push((spec.name, field_value(doc, root, spec)))
    }
    out.push(row)
  }
  out
}
