# SwiftTerm（vendored）

这是 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 的**精简本地副本**，
不是完整仓库，也没有保留上游的 git 历史。

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

## 本地改动（只有一处）

`Sources/SwiftTerm/Mac/MacTerminalView.swift`：`becomeFirstResponder()` /
`resignFirstResponder()` 由 `public override` 改为 `open override`。

上游 iOS 侧同名的这两个方法就是 `open`（`iOSTerminalView.swift:2961/2973`），macOS 侧漏写。
CogniTerm 需要在 `CogniTerminalView` 里覆盖它们来发布键盘焦点（供 Scene 级菜单项做
`disabled` 判据），`public` 会让模块外覆盖直接编译失败：
`overriding non-open instance method`。改动处有行内注释，升级时按下面的步骤重新施加即可。

## 升级步骤

```bash
# 1) 取回固定版本，并校验 sha256 必须等于上表
curl -fL -o /tmp/swiftterm.tar.gz \
  https://github.com/migueldeicaza/SwiftTerm/archive/2dad6a1e516f755bed77cf9bbd09455062f54758.tar.gz
shasum -a 256 /tmp/swiftterm.tar.gz

# 2) 只覆盖 Sources/SwiftTerm 与 LICENSE，其余不动
# 3) 重新施加上面那处 open 改动（改 TAG/COMMIT 时记得同步本文件的上表）
# 4) 验证
scripts/run-tests.sh && scripts/build-app.sh
```
