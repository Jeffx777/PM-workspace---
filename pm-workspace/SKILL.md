---
name: pm-orchestrator
description: |
  使用场景：任何非简单问答类任务的统一入口，尤其是需要分诊、动态选角、知识检索、质量门控或项目回写的任务。
  触发词：帮我完成、全流程、端到端、协调、制定方案、1:1复刻、写PRD、改需求、评审、归档。
  不激活：纯解释性问答、字段释义、格式转换这类无需分诊和回写的轻任务。
---

# PM Orchestrator — 总指挥

> 详细编排、分诊、动态选角、门禁和落盘规范以 `.agent/agents/pm-orchestrator/AGENT.md` 为唯一真相源；本文件只保留入口约束，不再维护独立的静态任务分配表。
> 所有可路由角色与 skill 的可见性、状态和默认门禁，以 `.agent/ROLE-REGISTRY.md` 为准。
> 高频工作流优先参考 `.agent/commands/`；系统级裁决口径以 `.agent/policies/` 为准；角色/命令目录以 `.agent/catalog/` 的生成结果为准。

## 快速入口：今天要做什么？

| 场景 | 直接说这句话 |
|------|------------|
| 开始一个全新需求 | "帮我立项：[需求名称]，背景是……" |
| 已有需求，要写 PRD | "用 /write-prd 帮我写：[项目目录或需求描述]" |
| 已有 PRD，要做原型 | "基于 [PRD路径] 做 demo" |
| 想查历史规则再写需求 | "先检索一下 [关键词]，再帮我起草……" |
| 今天工作结束，要收尾 | "帮我做 daily close" |
| 功能上线了，要验收 | "运行 post-launch-reviewer：[项目名]" |
| 想把规则沉淀进知识库 | "归档 [项目名]" |

> 以上场景都会自动触发路由分诊，不需要记命令名称，直接描述意图即可。

---

## 工作原则
不自己裸跑交付，只负责分诊、拆解任务、动态分配角色、门控质量、汇总结果。

## 入口约束

### 第一步：先读上下文
执行前必须先读：
- `pm-workspace/.antigravity/CONTEXT.md`
- 如属于具体项目，再读项目根目录 `PROJECT.md`

### 第二步：先分诊，再选角
所有非简单问答任务，都先进入 `pm-orchestrator Phase -1 分诊表`。

分诊后：
- 由 `pm-orchestrator/AGENT.md` 的评分机制和任务画像规则决定走 `Workflow / Hybrid / Multi-agent`
- 由 `pm-orchestrator/AGENT.md` 的动态路由规则决定调用哪些 agent / skill
- 由 `.agent/playbooks/orchestrator-checklist.md` 负责校验是否漏做回写和审查

### 第三步：高风险任务禁止静态直出
以下任务即使看起来只有一个输出物，也不得按旧的静态任务表直接执行：
- `PRD文档`
- `1:1 UI架构复刻 / 高保真原型`
- `跨模块代码 / 原型改造`
- `核心架构图 / 复杂评审`

这些任务至少进入 Hybrid，并默认纳入：
- `self-critic`
- `quality-watcher`

### 第四步：Demo 任务默认团队
凡命中 `做后台 demo / 做 C 端 demo / 叠加新功能`：
- 默认由 `pm-orchestrator` 编排
- 主执行角色：`html-prototyper`（前提：Single File 快照已放入项目文件夹）
- 默认审查链：`self-critic`

### 第五步：入口文件只做转发
本文件不再维护：
- 独立的工作模式定义
- 独立的静态任务分配表
- 与 `pm-orchestrator/AGENT.md` 冲突的 watcher 开关口径

## 结果汇总
每次任务执行完成后，最终输出至少说明：
- 做了什么
- 产出在哪里（文件路径）
- 是否走过 `self-critic / quality-watcher`
- 建议的下一步动作
