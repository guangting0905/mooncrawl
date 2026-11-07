// HTML 提取：链接、标题与正文文本。
//
// 基于 moonbit-community/html（HTML5 容错解析）。三个入口都是纯函数，
// 引擎对抓到的页面逐一调用；脚本与样式子树不参与正文。

///|
/// 一页的提取结果：链接、标题与 `<base href>`。
pub(all) struct PageExtract {
  links : Array[String]
  title : String?
  base_href : String?
}

///|
/// 单次解析同时提取链接、标题与 `<base href>`。
///
/// 引擎每页只需调用它一次：分开调 `extract_links` 与 `extract_title` 会让
/// 同一份文档被 HTML 解析器处理两遍，大页面上是纯浪费。
///
/// `base_href` 取文档中第一个带非空 href 的 `<base>`（HTML5 语义），
/// 调用方应把它相对页面 URL 解析后再用它展开其它相对链接。
pub fn extract_page(html : String) -> PageExtract {
  let doc = @html.parse(html)
  let links : Array[String] = []
  let bases : Array[String] = []
  walk_page(doc, doc.document_element, links, bases)
  let title = match find_title(doc, doc.document_element) {
    Some(t) => Some(trim_str(t))
    None => None
  }
  let base_href = if bases.length() > 0 { Some(bases[0]) } else { None }
  { links, title, base_href, }
}

///|
fn walk_page(
  doc : @html.Document,
  node : Int32,
  links : Array[String],
  bases : Array[String],
) -> Unit {
  if node < 0 {
    return
  }
  match doc.get_node(node) {
    Some(@html.ElementNode(el)) => {
      if doc.is_html_element(node, "a") {
        match get_attr(el, "href") {
          Some(href) => {
            let _ = links.push(href)
          }
          None => ()
        }
      } else if doc.is_html_element(node, "base") && bases.length() == 0 {
        // HTML5：只认第一个带非空 href 的 <base>
        match get_attr(el, "href") {
          Some(href) => if href != "" { let _ = bases.push(href) }
          None => ()
        }
      }
      for child in el.children {
        walk_page(doc, child, links, bases)
      }
    }
    _ => ()
  }
}

///|
/// 收集页面中所有 <a href> 的原始值（文档顺序，未解析）。
pub fn extract_links(html : String) -> Array[String] {
  extract_page(html).links
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
  extract_page(html).title
}

///|
/// 提取文档中第一个 `<base href>` 的原始值。没有则返回 None。
pub fn extract_base_href(html : String) -> String? {
  extract_page(html).base_href
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
