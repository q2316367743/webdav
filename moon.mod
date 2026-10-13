// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "q2316367743/webdav"

version = "0.1.0"

readme = "README.mbt.md"

// 源码根在 src/：根包（对外门面）位于 src/webdav.mbt，
// 各实现包在 src/types、src/xmlutil、src/client 等子目录。

source = "src"

repository = "https://github.com/q2316367743/webdav"

license = "Apache-2.0"

keywords = [ "webdav", "http-client" ]

// moonhttp 基于 moonbitlang/async 异步运行时，仅 native 后端可用，
// 因此本模块的默认目标必须与之一致。

preferred_target = "native"

description = "MoonBit WebDAV 客户端：文件上传/下载（流式+进度）、目录、移动/复制、PROPFIND/PROPPATCH。"

// async 测试（async test）与演示程序（async fn main）需要显式引入，
// 版本与 moonhttp 的传递依赖保持一致。
import {
  "q2316367743/moonhttp@0.5.0",
  "Milky2018/xml@0.5.0",
  "moonbitlang/async@0.22.2",
}
