# 通用知识路由表
# 格式：关键词|关键词 → 路径 — 一句话说明
# 来源：从域内 patterns/ 中提炼的、超越单一产品的通用规则
# 分层：Universal（任何电商/产品适用）→ Domain（Domain-specific）→ Project（单项目细节）

## 电商通用模式 ecom-patterns/
SKU|规格|状态机|禁用|下架 → universal/ecom-patterns/sku-state-machine.md — SKU 生命周期状态机通则（跨平台电商适用）
购物车|加购|失效|无效商品 → universal/ecom-patterns/cart-invalidation.md — 购物车商品失效处理通则
结算|下单|守卫|验证 → universal/ecom-patterns/checkout-guard.md — 结算前置守卫通则

## 交互模式 interaction-patterns/
状态阻断|禁用引导|不可用 → universal/interaction-patterns/state-blocking.md — 状态阻断时的用户引导通则
配额|限制|上限引导|付费墙|席位 → universal/interaction-patterns/quota-limit-guidance.md — 配额达上限时的用户引导通则（含升级/释放两条出路）

## PM 方法论 product-thinking/
价值链|需求价值|循序渐进|需求拆解 → universal/product-thinking/value-mapping.md — 需求价值链梳理方法（自顶向下 4 级拆解）
影响面|以小见大|影响分析|改动范围 → universal/product-thinking/impact-analysis.md — 改动影响面分析框架（三层影响模型）

---

## 通用知识依赖图

### 电商状态链
sku-state-machine → cart-invalidation — SKU状态变化直接触发购物车失效逻辑
sku-state-machine → checkout-guard — 结算前需核验SKU当前可达状态
cart-invalidation → checkout-guard — 购物车失效商品处理影响结算守卫的拦截逻辑

### 交互模式
state-blocking → quota-limit-guidance — 两者共用"状态受阻→引导操作"的交互范式

### PM 方法论
value-mapping → impact-analysis — 先确认做什么（价值链），再评估怎么做最安全（影响面）
impact-analysis → sku-state-machine — SKU 状态机改动是影响面分析的典型应用场景

---

## 维护规则

- 本文件由 `knowledge-archivist` 在归档时自动追加新条目
- 每条条目必须标注 `scope: universal`（确认跨产品适用）
- 域内专有规则不进入此索引，保留在 `knowledge-base/_index.md`
