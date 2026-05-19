# Scripts

详细分类规则见 `.agent/policies/script-policy.md`。

## 脚本路由规则（Claude 生成脚本时强制执行）

| 场景 | 路由位置 |
|------|---------|
| 参数化、无路径硬编码、可跨项目复用的 PowerShell 工具 | `scripts/`（本目录） |
| 参数化、无路径硬编码、可跨项目复用的 Python 工具 | `tools/`（不是这里） |
| 路径或业务逻辑写死、专为某次任务而写的任何脚本 | `.antigravity/workspaces/<任务名>/`，任务结束后删除 |

**禁止**：任何临时脚本、调试脚本、`__pycache__`、非脚本文件（`.html` 等）出现在本目录。
违规会被 `audit-antigravity.ps1` 报 WARN。

---

## GEMINI 规则同步

- `sync-gemini-global.ps1` — 手动同步 GEMINI.md 到全局
  `powershell -ExecutionPolicy Bypass -File scripts/sync-gemini-global.ps1`
- `watch-gemini-sync.ps1` — 常驻监听 GEMINI.md 变更，自动回刷
- `register-gemini-sync-task.ps1` — 注册登录后自启动监听任务

## 架构健康检查

- `audit-antigravity.ps1` — 交付前结构审计（含 scripts/ 合规检查）
  `powershell -ExecutionPolicy Bypass -File scripts/audit-antigravity.ps1`
- `check-architecture-health.ps1` — 日常健康巡检
  `powershell -ExecutionPolicy Bypass -File scripts/check-architecture-health.ps1`
- `run-architecture-watch.ps1` — 统一入口（推荐）
  `powershell -ExecutionPolicy Bypass -File scripts/run-architecture-watch.ps1 -Mode Daily`
- `register-architecture-watch-task.ps1` — 注册 Windows 计划任务

## Agent Library 基础设施

- `check-agent-metadata.ps1` — 校验 role/command frontmatter、注册表关联
  `powershell -ExecutionPolicy Bypass -File scripts/check-agent-metadata.ps1`
- `build-agent-catalog.ps1` — 生成 `.agent/catalog/` 目录索引
  `powershell -ExecutionPolicy Bypass -File scripts/build-agent-catalog.ps1`
- `validate-cross-ref.ps1` — 跨文件引用一致性检查
- `validate-output-harness.ps1` — 输出 harness 结构校验
- `test-agent-library.ps1` — 一键串行跑以上所有检查

## 公共函数

- `lib/agent-library.ps1` — frontmatter 解析、角色文件扫描、注册表读取
- `make-html-portable.ps1` — 将 HTML 文件转为便携式单文件
