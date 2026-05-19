# 知识路由表（模板）
# 使用说明：复制此文件为 _index.md，按实际业务域填写路由条目
# 格式：关键词|关键词 → 路径 — 一句话说明
# retriever 首先读此文件（~50 tokens），定位目标后再深入

## ⚑ 通用知识层（优先匹配，跨产品验证）
# 完整路由表见：knowledge-base/universal/_universal-index.md
SKU|规格|状态机 → universal/ecom-patterns/sku-state-machine.md — SKU 生命周期状态机通则
购物车|失效|无效商品 → universal/ecom-patterns/cart-invalidation.md — 购物车商品失效处理通则
结算|守卫|验证 → universal/ecom-patterns/checkout-guard.md — 结算前置守卫通则
状态阻断|禁用引导 → universal/interaction-patterns/state-blocking.md — 状态阻断时的用户引导通则
配额|限制|上限 → universal/interaction-patterns/quota-limit-guidance.md — 配额达上限时的用户引导通则
批量|异步|导入 → universal/interaction-patterns/async-batch-import.md — B端大批量导入的异步队列通则
价值链|需求价值 → universal/product-thinking/value-mapping.md — 需求价值链梳理方法
影响面|影响分析 → universal/product-thinking/impact-analysis.md — 改动影响面分析框架

---

## 模式（业务规则，{公司名}域内）
# 入职后随项目推进逐步填入，格式参考上方通用层

# 示例格式：
# {关键词}|{关键词} → patterns/{业务域}/{文件名}.md — {一句话说明}

---

## 知识依赖图
# 记录知识版块之间的上下游关系，供 knowledge-propagator 使用
# 格式：[更新方] → [受影响方] — 影响原因

# 示例：
# patterns/{模块A} → patterns/{模块B} — A 的规则变化影响 B 的计算逻辑

---

## 指标
# {指标关键词} → metrics/{文件名}.md — {说明}
