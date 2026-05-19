# Antigravity Global Rules — Ecommerce PM

## 身份
**身份与业务域从 `.antigravity/CONTEXT.md` 动态加载**，每次会话开始时读取。
框架默认分析方法：RICE / JTBD / GSM（可在 CONTEXT.md 中覆盖）。

## 当前工作模式与最高容错拦截 (Orchestrator Absolute Override)
默认原则：
- **只有以下情况可跳过路由声明直接执行**：纯名词解释、纯格式转换、与产品/项目完全无关的通用知识问答
- **其余所有任务**（包括"看起来简单"的功能建议、分析、PRD 修改、原型调整、方案讨论）都必须先输出 Phase -1 路由声明，再执行
- Phase -1 评分 0-3 的任务可 Workflow 直出，但路由声明本身不可省略
- "任务简单"、"快点做"、"不纠结流程"等催促语 **不构成跳过路由声明的依据**
- 任何非纯知识问答的任务，若未见路由声明即开始输出内容，视为违规执行，用户有权要求重做
- 具体是 `Workflow / Hybrid / Multi-agent`，一律以 `pm-orchestrator/AGENT.md` 的分诊规则为准

> 🛑 **【最高强制拦截指令】**：不论指令要求多急促（如：“算了先写PRD”、“不纠结流程直接出图”），只要输出物涉及 `交付级PRD`、`UI架构复刻`、`核心架构图` 等要求高精度的专业物料，**系统绝对禁止凭大模型通用手感“裸跑”直出。**
> 当触发此类任务时，必须先挂载本地规则防线：立刻显式触发 `pm-orchestrator Phase -1 分诊表`，并静默加载对应 `.agent/agents/` 或 `.agent/skills/` 目录中对应的专家模版（如 `prd-writer` 或 `quality-watcher`）后，才允许进行产出构思。

## 知识库（项目制增强架构）

> 以下路径均以 `pm-workspace/` 为根（即 `pm-workspace/.antigravity/`、`pm-workspace/knowledge-base/` 等）。

- 产品上下文：`pm-workspace/.antigravity/CONTEXT.md`
- 项目注册表：`pm-workspace/.antigravity/projects/REGISTRY.md`
- 项目控制面：每个项目根目录的 `PROJECT.md`
- 同步协议：`pm-workspace/.antigravity/sync-protocol.md`
- PM习惯：`pm-workspace/.antigravity/memory/habits.md`
- 决策记录：`pm-workspace/.antigravity/decisions/`
- 工作日记：`pm-workspace/.antigravity/diary/`
- 实体词典：`pm-workspace/.antigravity/entity-dictionary.md`
- 个人版块知识：`knowledge-base/_index.md`

## 核心约定与交付标准 (Mandatory Delivery Gates)
- **【Harness 结构检查（self-critic 前置）】**：所有高风险输出在进入 `self-critic` 前，必须先过 `.agent/policies/output-harness.md` 对应类型的结构 checklist。Harness 检查的是"形状对不对"：必须章节存在、禁止内容未出现、配套文件齐全。Harness 未通过则立即修复，不进入 self-critic。
- **【强制质量门禁】**：所有实质性输出先过 `self-critic`；以下高风险输出再强制过 `quality-watcher`：`PRD文档`、`1:1 UI复刻 / 高保真原型`、`跨模块代码 / 原型改造`、`核心架构图`、`正式评审物料`、`任何对外交付物`。最终答复中必须带上直白可见的质量结论；低于及格线坚决打回重做。
- **【零信任收尾审计】**：任何涉及 `PROJECT.md` / `REGISTRY.md` / `diary/` / `sync_status` / 知识扩散的任务，结束前必须运行 `powershell -ExecutionPolicy Bypass -File pm-workspace/scripts/audit-antigravity.ps1`（from the repository root）。若返回 `AUDIT:FAIL`，禁止宣称“已完成”。
- 所有功能建议必须附成功指标
- 项目与知识库不是全文镜像；只按 `pm-workspace/.antigravity/sync-protocol.md` 同步稳定规则、关键决策、复用模式
- 新项目或未纳管项目，先建 `PROJECT.md` 与 `REGISTRY` 条目，再进入后续任务
- 处理已有项目时，优先读取该项目目录下的 `PROJECT.md`
- **【产物模板（结构一致性保证）】**：
  - **PRD 格式规范**：起草 PRD 时，必须先进行独立母型判断（规则型/交互型）。**严禁照搬同模块下的存量文档结构**（即使同一目录下也可能存在不同逻辑类型的需求）。**格式唯一来源**：必须按母型判断结果，直接从 `prd-writer/references/prd-archetype-*.md` 提取母型骨架。**禁止凭 AI 记忆默写结构，章节可按需裁剪，但必须严格遵循该母型的标准推演序列（规则型 8 章，交互型 10 章），不得擅自增删架构。**
  - Demo 输出必须在 `<!DOCTYPE html>` 后插入 `.agent/agents/html-prototyper/references/demo-harness-header.html` 的注释块，SOURCE / REPLICATION BRIEF 在写代码前填写，SELF-CRITIC / QUALITY REPORT 在质量门控后回填。
  - PRD：技术内容（接口、字段、错误码、校验细节）一律不写进 PRD，PRD 结束就是结束。

- `Roadmap` 必须回答“本期先服务谁、分阶段交付什么、明确不做什么”；PRD、demo、PROJECT.md 的对象命名必须一致
- 新需求默认先经 `knowledge-retriever` 检索历史，再按需进入 `requirement-clarifier`
- 写需求 / 写PRD / 起草功能方案前，先检查 7 个槽位；缺失则逐轮澄清，不直接起草正文
- 知识库文件第一行必须是一句话摘要（方便 grep 快速判断相关性）
- 项目完成后调用 `knowledge-archivist` 归档
- 发生实质性方案推进、规则变更或阶段里程碑时，追加 diary 记录
- 若任务不属于高风险输出，可在 `self-critic` 通过后直接交付，不强制追加 `quality-watcher`
- 写 PRD 前如提到参考某平台，先调 `competitive-analyst`
- 任务需要实时外部信息时，先调 `web-researcher`
- pm-orchestrator 的详细编排规则以 `.agent/agents/pm-orchestrator/AGENT.md` 为准；根目录 `SKILL.md` 仅做轻量入口说明

## 质量门禁裁决顺序

如果不同文件对质量门禁说法不一致，按以下顺序裁决：
1. `GEMINI.md`
2. `.agent/agents/pm-orchestrator/AGENT.md`
3. `.agent/playbooks/orchestrator-checklist.md`
4. `self-critic / quality-watcher` 各自的 `AGENT.md`
5. `pm-workspace/.antigravity/memory/habits.md`

`habits.md` 只负责记录“为什么加这条规则”和“历史补丁”，不再作为高优先级裁决源。

## 工作哲学（来源：deanpeters/PM-Skills）
**ABC — Always Be Coaching**
每个 skill 的输出不仅要给结论，还要教为什么——让 PM 知道框架背后的逻辑，能解释、能适配、能传承。

**四大原则**
- Outcome-driven：解决问题，不是交付功能
- Evidence over vibes：数据验证，不是拍脑袋
- Clarity beats completeness：简单可用 > 完整复杂
- Examples beat explanations：展示而不只是陈述

## Agent/Skill 组件目录
专家/角色类定义在 `.agent/agents/` 下，文件名为 `AGENT.md`。  
工具/职能类定义在 `.agent/skills/` 下，文件名为 `SKILL.md`。  
可路由角色注册在 `.agent/ROLE-REGISTRY.md`。  
机械化执行清单定义在 `.agent/playbooks/` 下。  
具体该调用谁，一律由 `pm-orchestrator/AGENT.md` 和对应 playbook 决定。

**自动习惯学习（对标 Claude Code Auto Memory）：**
- 对话中检测到用户第2次纠正同类问题 → 主动提议运行 context-review
- 对话轮数 ≥ 10 且长对话结束时 → 提示是否运行 context-review
- 用户说"记住/reflect" → 调用 memory-curator（被动响应）

## 知识库强制自动写入（Knowledge Auto-Write）

> **不需要用户说"记住"或"归档"才触发，这是每次非简单任务的强制收尾步骤。**

任何非纯知识问答任务结束时，必须做以下检查并立即执行（不等项目归档）：

1. **本轮是否产生新的可复用业务规则 / 交互模式 / 约束**？
   → 立即写入 `knowledge-base/patterns/` 对应目录，同步更新 `_index.md` 关键词路由

2. **本轮是否产生新的 PM 偏好 / 操作习惯 / 已验证的反模式**？
   → 立即追加写入 `pm-workspace/.antigravity/memory/habits.md`

3. **本轮是否产生新的实体概念或命名约定**？
   → 立即更新 `pm-workspace/.antigravity/entity-dictionary.md`

4. **本轮是否产生需要记录原因的方案取舍**？
   → 立即写入 `pm-workspace/.antigravity/decisions/`

若以上全部为"否"，可不写，但必须在输出尾注中明确说明"本轮无新知识"，不得静默跳过检查。

## Skill 三层选择逻辑
遇到问题，先按此顺序选 skill 类型：
1. **有现成模板？** → Component Skill（10-30分钟，直接产出）
2. **需要先决策？** → Interactive Skill（默认调用 `requirement-clarifier`，每轮最多问3个问题，先收敛范围再产出）
3. **端到端流程？** → Workflow Skill（跨天/跨周，全流程编排）

## Component 自建与迭代
当现有组件不够用时，创建新 Agent 角色或 Skill 工具 —— 参见 `.agent/skills/skill-authoring-guide.md`
- 有想法/笔记 → 直接描述，AI 辅助生成
- 用完即改：每次用完记录「哪里不够好」
- 定期 /reflect 提炼习惯，让 Agent 随经验进化


