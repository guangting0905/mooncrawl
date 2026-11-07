// 真实传输层：基于 moonbitlang/async/http 的 FetchFn 实现。
//
// 契约：**任何失败都必须折叠进 FetchOutcome**，不向引擎抛异常。
// 单页请求失败只应让这一页记 status=0 + error，不能让整次采集终止——
// 否则一个超时、一次 TLS 握手失败就会毁掉跑了半小时的任务。
//
// - 30 秒整体超时（@async.with_timeout_opt）
// - 协议错误 / 解码错误 / 底层抛出的异常：捕获后折叠为 status=0 + error
// - 重定向跟随行为取决于底层客户端（js 后端经 Node fetch 自动跟随）
// - 显式发送 User-Agent：robots.txt 的组匹配依赖它

///|
const HTTP_TIMEOUT_MS : Int32 = 30_000

///|
/// FetchFn 的默认实现。永不抛异常。
pub async fn http_fetch(url : String, user_agent : String) -> FetchOutcome {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([], capacity=4)
  let _ = headers.set(@http.CaseInsensitiveString("user-agent"), user_agent)
  let task : async () -> FetchOutcome = async fn() -> FetchOutcome {
    try {
      let (resp, data) = @http.get(url, headers~)
      let body = data.text()
      { status: resp.code, body, error: None, }
    } catch {
      e =>
        {
          status: 0,
          body: "",
          error: Some("transport error: " + e.to_string()),
        }
    }
  }
  match @async.with_timeout_opt(HTTP_TIMEOUT_MS, task) {
    Some(outcome) => outcome
    None => { status: 0, body: "", error: Some("timeout after 30s"), }
  }
}
