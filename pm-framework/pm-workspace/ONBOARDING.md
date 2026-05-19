# Onboarding Guide

This framework separates reusable workflow rules from private product data.

Use this guide when setting up PM Framework for a new product, team, or company.

## Framework Layer vs Content Layer

| Layer | Location | Versioned? |
|---|---|---|
| Framework layer | `.agent/`, `scripts/`, `tools/`, `GEMINI.md`, `SKILL.md` | Yes |
| Content layer | `.antigravity/CONTEXT.md`, project registry, decisions, diary, `knowledge-base/patterns/`, `product-artifacts/` | No, keep private |

## First-Day Setup

### 1. Clone

```bash
git clone <repo-url>
cd pm-framework
```

### 2. Create Product Context

Create `pm-workspace/.antigravity/CONTEXT.md`:

```markdown
# Product Context

## My Role
{role} @ {team/company}
Responsible for: {domain}

## Product Overview
- Product: {name}
- Users: {B2B / B2C / internal operations / other}
- Core scenarios: {1-3 scenarios}
- Platforms: {web / app / backend / other}

## Current Focus
- Stage: {0-to-1 / growth / optimization}
- Current goals or metrics: {fill in}

## Terms
- {term}: {definition}
```

### 3. Create Entity Dictionary

Create `pm-workspace/.antigravity/entity-dictionary.md`:

```markdown
# Entity Dictionary

| Entity | Definition | Aliases to avoid |
|---|---|---|
| {entity} | {definition} | {ambiguous names} |
```

### 4. Initialize Knowledge Router

```bash
cp pm-workspace/knowledge-base/_index-template.md pm-workspace/knowledge-base/_index.md
```

Replace placeholders with your real product domains as projects produce reusable knowledge.

### 5. Initialize Project Registry

Create `pm-workspace/.antigravity/projects/REGISTRY.md` from `projects/_template.md` when the first project starts.

## Start the First Requirement

Ask your AI IDE:

```text
Help me start a project: [requirement name]. Background: ...
```

The framework will route through project bootstrap, knowledge retrieval, requirement clarification, and the relevant expert roles.

## Before Publishing a Fork

- Remove or ignore all real product artifacts.
- Do not commit `CONTEXT.md`, project registries, decisions, diary entries, or workspaces.
- Do not commit private `knowledge-base/patterns/`, `archives/`, `metrics/`, or `_index.md`.
- Scan for private URLs, credentials, customer names, internal project names, and local absolute paths.
- If private content was committed in Git history, publish from a clean repository or rewrite history.

## Directory Reference

```text
pm-workspace/
├── .agent/                   # Framework core: agents / skills / playbooks / policies
├── scripts/                  # Health checks and audit automation
├── tools/                    # Reusable Python tools
├── knowledge-base/
│   ├── universal/            # Reusable cross-product knowledge
│   ├── patterns/             # Private product rules, ignored by default
│   ├── archives/             # Private project knowledge cards, ignored by default
│   └── _index-template.md    # Template copied to private _index.md
├── inbox/                    # Requirement intake
├── .antigravity/
│   ├── decisions/            # Private decisions
│   ├── diary/                # Private work diary
│   ├── memory/habits.md      # Local working habits and anti-patterns
│   ├── projects/             # Private project registry
│   └── sync-protocol.md      # Project/knowledge sync protocol
├── GEMINI.md                 # Runtime rules
├── SKILL.md                  # Quick entry point
└── ONBOARDING.md             # This guide
```
