// HTML 提取：链接、标题与正文文本。
//
// 基于 moonbit-community/html（HTML5 容错解析）。三个入口都是纯函数，
// 引擎对抓到的页面逐一调用；脚本与样式子树不参与正文。

///|
/// 收集页面中所有 <a href> 的原始值（文档顺序，未解析）。
pub fn extract_links(html : String) -> Array[String] {
  let out : Array[String] = []
  let doc = @html.parse(html)
  walk_links(doc, doc.document_element, out)
  out
}

///|
fn walk_links(doc : @html.Document, node : Int32, out : Array[String]) -> Unit {
  if node < 0 {
    return
  }
  match doc.get_node(node) {
    Some(@html.ElementNode(el)) => {
      if doc.is_html_element(node, "a") {
        match get_attr(el, "href") {
          Some(href) => {
            let _ = out.push(href)
          }
          None => ()
        }
      }
      for child in el.children {
        walk_links(doc, child, out)
      }
    }
    _ => ()
  }
}

///|
fn get_attr(el : @html.Element, name : String) -> String? {
  for pair in el.attributes {
    let (k, v) = pair
    if k == name {
      return Some(v)
    }
  }
  None
}

///|
/// 提取 <title> 文本（去实体、去首尾空白）。无 title 返回 None。
pub fn extract_title(html : String) -> String? {
  let doc = @html.parse(html)
  match find_title(doc, doc.document_element) {
    Some(t) => Some(trim_str(t))
    None => None
  }
}

///|
fn find_title(doc : @html.Document, node : Int32) -> String? {
  if node < 0 {
    return None
  }
  match doc.get_node(node) {
    Some(@html.ElementNode(el)) => {
      if doc.is_html_element(node, "title") {
        return Some(doc.get_text_content(node))
      }
      for child in el.children {
        match find_title(doc, child) {
          Some(t) => return Some(t)
          None => ()
        }
      }
      None
    }
    _ => None
  }
}

///|
/// 提取正文文本：body 子树内的可见文本，跳过 script/style，
/// 相邻文本以空格合并并折叠连续空白。
pub fn extract_text(html : String) -> String {
  let doc = @html.parse(html)
  let parts : Array[String] = []
  collect_text(doc, doc.body_element, parts)
  join_collapsed(parts)
}

///|
fn collect_text(
  doc : @html.Document,
  node : Int32,
  out : Array[String],
) -> Unit {
  if node < 0 {
    return
  }
  match doc.get_node(node) {
    Some(@html.ElementNode(el)) => {
      let tag = el.tag_name
      if tag == "script" || tag == "style" || tag == "noscript" {
        return
      }
      for child in el.children {
        collect_text(doc, child, out)
      }
    }
    Some(@html.TextNode(s)) => if s != "" { let _ = out.push(s) }
    _ => ()
  }
}

///|
fn join_collapsed(parts : Array[String]) -> String {
  let buf = StringBuilder()
  let mut pending_space : Bool = false
  let mut wrote_any : Bool = false
  for p in parts {
    let cs = chars_of(p)
    for c in cs {
      if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
        pending_space = true
      } else {
        if pending_space && wrote_any {
          buf.write_char(' ')
        }
        pending_space = false
        wrote_any = true
        buf.write_char(c)
      }
    }
    pending_space = true
  }
  buf.to_string()
}
