## 这个 PR 做了什么

<!-- 一句话说清。剩下的细节放下面。 -->

## 为什么这样做

<!-- 有取舍就写取舍：否掉了哪些方案、依据是什么。没有依据的改动先讨论再写。 -->

## 有没有动到这些地方

- [ ] 沙箱 profile（`App/Resources/sandbox/*.sb`）
- [ ] MCP 契约（`TerminalMCPServer` 的 JSON-RPC 形状）
- [ ] dsh patch（`App/Resources/patches/*.yml`）
- [ ] 审批逻辑 / 风险评估（`PolicyEngine`）

> 上面任一项打了勾，请在描述里说明「失败时会怎样」——这几处默认 fail-closed，
> 改动要么证明仍然 fail-closed，要么明确写出放宽了什么。

## 验证

```bash
scripts/run-tests.sh     # 期望：EXIT=0，且用例数不比改动前少
```

- [ ] 新增/修改的行为有测试覆盖
- [ ] 手动验证过真实链路（不只是单测）：命令真的落到了 PTY / SSH 上

## 截图（UI 改动）

<!-- 前后对比最好。别把真机主机名、内网地址、API Key 截进去。 -->
