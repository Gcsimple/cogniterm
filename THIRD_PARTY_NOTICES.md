# 第三方组件与许可

本项目以 [MIT](LICENSE) 发布。以下组件随仓库分发或被构建流程拉取，各自保留原始许可与版权声明。

| 组件 | 许可 | 位置 | 说明 |
|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT | `Packages/SwiftTerm/` | vendored 本地副本，含一处已注明的本地改动，见 `VENDOR.md` |
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`） | MIT | 构建时拉取到 `App/Resources/runtime/`（**不入库**） | 由 `scripts/vendor-runtime.sh` 下载并固定版本 |
| [Node.js](https://nodejs.org/) | MIT | 同上 | 作为 dsh 的运行时随包分发 |

SwiftTerm 的版权声明：

```
Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)
```

完整文本见 `Packages/SwiftTerm/LICENSE-SwiftTerm.txt`。

> 注意：`App/Resources/runtime/` 里的 node_modules 会带各自的 LICENSE 文件，随 App 一起分发；
> 它不进本仓库，所以本文件只列直接依赖。
