// 真实传输层：基于 moonbitlang/async/http 的 FetchFn 实现。
//
// - 30 秒整体超时（@async.with_timeout_opt）
// - 失败（协议错误/超时/解码错误）统一折叠为 status=0 + error
// - 重定向跟随行为取决于底层客户端（js 后端经 Node fetch 自动跟随）
// - 显式发送 User-Agent：robots.txt 的组匹配依赖它

///|
const HTTP_TIMEOUT_MS : Int32 = 30_000

///|
/// FetchFn 的默认实现。
pub async fn http_fetch(url : String, user_agent : String) -> FetchOutcome {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([], capacity=4)
  let _ = headers.set(@http.CaseInsensitiveString("user-agent"), user_agent)
  let task : async () -> FetchOutcome = async fn() -> FetchOutcome {
    let (resp, data) = @http.get(url, headers~)
    let body = data.text()
    { status: resp.code, body, error: None, }
  }
  match @async.with_timeout_opt(HTTP_TIMEOUT_MS, task) {
    Some(outcome) => outcome
    None => { status: 0, body: "", error: Some("timeout after 30s"), }
  }
}
