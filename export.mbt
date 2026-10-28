// 结构化导出：CSV（RFC 4180 转义）与 JSONL（逐行 JSON）。
//
// 输出以行为单位累积成字符串，由 CLI 决定写往 stdout 还是文件，
// 框架核心因此不依赖任何文件 IO —— 在 native / js / wasm 上行为一致。

///|
/// 单字段 CSV 转义：含逗号、引号、换行时整体加引号，内部引号翻倍。
pub fn csv_escape(field : String) -> String {
  let need_quote = {
    let cs = chars_of(field)
    let mut n = false
    for c in cs {
      if c == ',' || c == '"' || c == '\n' || c == '\r' {
        n = true
        break
      }
    }
    n
  }
  if !need_quote {
    return field
  }
  let buf = StringBuilder()
  buf.write_char('"')
  for c in field {
    if c == '"' {
      buf.write_char('"')
      buf.write_char('"')
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// CSV 行组装（字段按传入顺序，CRLF 行尾符合 RFC 4180）。
pub fn csv_row(fields : Array[String]) -> String {
  let buf = StringBuilder()
  let mut first : Bool = true
  for f in fields {
    if !first {
      buf.write_char(',')
    }
    first = false
    buf.write_string(csv_escape(f))
  }
  buf.write_string("\r\n")
  buf.to_string()
}

///|
/// JSON 字符串值转义（引号/反斜杠/控制字符；其余 UTF-8 原样透传）。
pub fn json_escape(s : String) -> String {
  let buf = StringBuilder()
  buf.write_char('"')
  for c in s {
    let n = c.to_int()
    if c == '"' {
      buf.write_string("\\\"")
    } else if c == '\\' {
      buf.write_string("\\\\")
    } else if c == '\n' {
      buf.write_string("\\n")
    } else if c == '\r' {
      buf.write_string("\\r")
    } else if c == '\t' {
      buf.write_string("\\t")
    } else if n < 0x20 {
      // 固定 4 位小写十六进制
      let hex = "0123456789abcdef"
      let hcs = chars_of(hex)
      let mut v : Int32 = n
      let digits : Array[Char] = ['0', '0', '0', '0']
      let mut k : Int32 = 3
      while k >= 0 {
        digits[k] = hcs[v % 16]
        v = v / 16
        k = k - 1
      }
      buf.write_string("\\u")
      for d in digits {
        buf.write_char(d)
      }
    } else {
      buf.write_char(c)
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// 通用记录行：字段对按传入顺序输出为一行 JSON。
///
/// 与 `jsonl_page` 的区别是不绑定任何结构体——配合 `extract_fields` /
/// `extract_records` 使用，字段名来自调用方的 `FieldSpec`。
pub fn json_record(fields : Array[(String, String)]) -> String {
  let buf = StringBuilder()
  buf.write_char('{')
  let mut first : Bool = true
  for kv in fields {
    let (k, v) = kv
    if !first {
      buf.write_char(',')
    }
    first = false
    buf.write_string(json_escape(k))
    buf.write_char(':')
    buf.write_string(json_escape(v))
  }
  buf.write_char('}')
  buf.to_string()
}

///|
/// 通用记录行：字段对按传入顺序输出为一行 CSV（字段名作为表头来源）。
pub fn csv_record(fields : Array[(String, String)]) -> String {
  let values : Array[String] = []
  for kv in fields {
    let (_, v) = kv
    values.push(v)
  }
  csv_row(values)
}

///|
/// 通用表头行。
pub fn csv_record_header(fields : Array[(String, String)]) -> String {
  let names : Array[String] = []
  for kv in fields {
    let (k, _) = kv
    names.push(k)
  }
  csv_row(names)
}

///|
/// JSONL 行：抓取结果一行一条记录。
pub fn jsonl_page(p : PageResult) -> String {
  let buf = StringBuilder()
  buf.write_string("{\"url\":")
  buf.write_string(json_escape(p.url))
  buf.write_string(",\"status\":")
  buf.write_string(p.status.to_string())
  buf.write_string(",\"depth\":")
  buf.write_string(p.depth.to_string())
  buf.write_string(",\"links_found\":")
  buf.write_string(p.links_found.to_string())
  match p.title {
    Some(t) => {
      buf.write_string(",\"title\":")
      buf.write_string(json_escape(t))
    }
    None => ()
  }
  match p.error {
    Some(e) => {
      buf.write_string(",\"error\":")
      buf.write_string(json_escape(e))
    }
    None => ()
  }
  buf.write_char('}')
  buf.to_string()
}

///|
/// CSV 表头（与 jsonl_page 字段对应）。
pub fn csv_header() -> String {
  csv_row(["url", "status", "depth", "links_found", "title", "error"])
}

///|
/// CSV 数据行：Option 字段以空串表示缺失。
pub fn csv_page(p : PageResult) -> String {
  csv_row([
    p.url,
    p.status.to_string(),
    p.depth.to_string(),
    p.links_found.to_string(),
    match p.title {
      Some(t) => t
      None => ""
    },
    match p.error {
      Some(e) => e
      None => ""
    },
  ])
}
