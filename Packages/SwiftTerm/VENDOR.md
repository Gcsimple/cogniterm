# SwiftTerm（vendored）

这是 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 的**精简本地副本**，
不是完整仓库。由 `scripts/vendor-swiftterm.sh` 生成，**不要手工改 Sources/ 下的任何文件**
（升级请改脚本里的 TAG/COMMIT/TARBALL_SHA256 后重跑）。

| 项 | 值 |
|---|---|
| upstream tag | `v1.99.0` |
| upstream commit | `2dad6a1e516f755bed77cf9bbd09455062f54758` |
| tarball sha256 | `942a89ea11b5807190bf405c90848afc45f19f815e19aa9a4f3fbb8ca2de66e5` |
| 取用范围 | 仅 `Sources/SwiftTerm`（＋ `LICENSE`） |
| 生成文件 | `Sources/SwiftTerm/Generated/{SwiftTermBuildInfo,SwiftTermTerminfo}.swift`（上游 `SwiftTermBuildInfoGenerator` 的产物） |
| 许可 | MIT，见 `LICENSE-SwiftTerm.txt` |

未取用的上游内容：`Tests/`、`TerminalApp/`、`Benchmarks/`、`Sources/SwiftTermFuzz`、
`Sources/Termcast`、`Plugins/`、`Sources/SwiftTermBuildInfoGenerator`（vendor 期用一次）、
`swifterm-terminfo`（已烘进生成文件）、`SwiftTermWebWasm` 等。

升级步骤：改脚本头部的 `TAG` / `COMMIT` / `TARBALL_SHA256` → 重跑
`scripts/vendor-swiftterm.sh` → `scripts/run-tests.sh` → `scripts/build-app.sh`。
