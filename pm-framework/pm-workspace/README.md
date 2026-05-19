# PM Workspace

This folder is the working area used by PM Framework. It contains the reusable agent system, governance rules, automation scripts, and placeholders for your private product context.

The repository is designed so framework files can be public while product data stays local.

## Layers

```text
pm-workspace/
├── .agent/                 # Framework layer: agents, skills, commands, playbooks, policies
├── .antigravity/           # Local state layer: context, projects, decisions, diary, memory
├── docs/                   # In-progress analysis and requirement support files
├── inbox/                  # Intake folder for raw ideas and untriaged requests
├── knowledge-base/         # Universal knowledge + private patterns and archives
├── scripts/                # PowerShell checks, audits, and catalog generation
├── tools/                  # Reusable Python tools
├── GEMINI.md               # Runtime rules for AI IDEs that read this file
└── SKILL.md                # Orchestrator entry point
```

## What Is Public vs Private

| Layer | Public in this repo | Private in your local workspace |
|---|---|---|
| Framework | `.agent/`, `scripts/`, `tools/`, `GEMINI.md`, `SKILL.md` | Local edits that encode company-specific rules |
| Product context | templates and README files | `.antigravity/CONTEXT.md`, `entity-dictionary.md`, `ROADMAP.md` |
| Projects | `_template.md` files | `REGISTRY.md`, project `PROJECT.md`, PRDs, demos |
| Knowledge | `universal/`, `_index-template.md`, section READMEs | `_index.md`, `patterns/`, `archives/`, `metrics/` |
| Process logs | diary templates | diary entries, workspaces, health reports |

## Main Components

### `.agent/`

Defines how work is routed and reviewed.

- `agents/`: expert roles such as `pm-orchestrator`, `prd-writer`, `ux-critic`, `tech-review`, `quality-watcher`.
- `skills/`: reusable methods such as requirement clarification, knowledge retrieval, knowledge archiving, daily close, and SingleFile preprocessing.
- `commands/`: stable shortcuts such as `/discover`, `/write-prd`, `/review-prd`, `/close-day`.
- `policies/`: routing, output structure, quality gates, rule cross references, script governance.
- `playbooks/`: checklists that prevent missed write-backs, reviews, and sync steps.
- `catalog/`: generated index of roles and commands.

### `.antigravity/`

Stores local runtime state. Most real files in this layer should stay private.

- `CONTEXT.md`: product and team context, created after cloning.
- `projects/REGISTRY.md`: project index, created locally.
- `decisions/`: ADRs and key tradeoffs.
- `diary/`: append-only progress notes.
- `memory/habits.md`: working preferences and lessons.
- `workspaces/`: temporary folders for multi-step tasks.

### `knowledge-base/`

Stores reusable knowledge.

- `universal/`: general PM, ecommerce, and interaction patterns that can ship with the framework.
- `patterns/`: product-specific business rules, ignored by default.
- `archives/`: completed project knowledge cards, ignored by default.
- `metrics/`: team-specific metric definitions, ignored by default.
- `_index-template.md`: copy to `_index.md` when creating a local workspace.

### `docs/` and `inbox/`

Use `inbox/` to capture raw ideas. Move active work into `docs/analysis/` or `docs/requirements/` when the task becomes concrete.

## Common Commands

```text
/discover        Explore a rough idea
/write-prd       Draft a PM-first PRD
/review-prd      Review an existing PRD
/sync-singlefile Prepare a SingleFile HTML snapshot
/close-day       Write back progress and sync notes
/weekly-review   Review project health across the week
```

## Automation

Run from `pm-workspace/`:

```powershell
# Validate agent and command metadata
powershell -ExecutionPolicy Bypass -File scripts/check-agent-metadata.ps1

# Regenerate .agent/catalog/
powershell -ExecutionPolicy Bypass -File scripts/build-agent-catalog.ps1

# Run the full lightweight framework check
powershell -ExecutionPolicy Bypass -File scripts/test-agent-library.ps1

# Run daily architecture health checks
powershell -ExecutionPolicy Bypass -File scripts/run-architecture-watch.ps1 -Mode Daily
```

## First Local Setup

1. Create `pm-workspace/.antigravity/CONTEXT.md`.
2. Copy `knowledge-base/_index-template.md` to `knowledge-base/_index.md`.
3. Create `pm-workspace/.antigravity/projects/REGISTRY.md` when the first real project starts.
4. Keep private content out of Git unless intentionally publishing a sanitized example.
