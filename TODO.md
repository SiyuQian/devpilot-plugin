# DevPilot Plugin 改进清单

Skills 从裸目录迁移为 Claude Code plugin 之后的后续改进项。

## P0 — 结构性收益

- [x] **pr-review fanout 改用 plugin `agents/`** — Agent A–F 抽成 `agents/pr-review-*.md`（固定 system prompt + 只读工具白名单）；`fanout.md` 瘦身为 dispatch 说明，保留 standalone fallback。
- [x] **CI 校验（GitHub Action）** — `.github/workflows/validate.yml` 跑 `scripts/validate.py`：manifest JSON、skill/agent/command frontmatter、name 与目录一致、description 非空。

## P1 — 可用性与发布流程

- [x] **加 `commands/` 目录** — `/pr-review`、`/pr`、`/repo-scan`、`/resolve-issues`、`/dead-code`。
- [x] **版本管理与 CHANGELOG** — bump 到 1.1.0，新增 `CHANGELOG.md`。后续每次改动 skill 应继续 bump + 记录；可选打 tag/Release。
- [x] **交叉引用一致性检查** — 并入 `scripts/validate.py`（`devpilot:<skill>` 引用存在性 + 残留旧 `devpilot-` 前缀检测）；已借此修掉 `harness-engineering/evals/README.md` 里一处迁移误改写。
- [ ] **`scanning-repos` 迁到 `scripts/codegraph.sh`** — `pr-review` 已经不再直接调
      `devpilot graph`（改走 wrapper，缺失时引导安装）。但 `scanning-repos` 仍然
      在 `SKILL.md:49` 直接 `devpilot graph build` / `graph hubs`，三个 scanner
      agent（`security-scanner`、`edge-case-hunter`、`coverage-auditor`）也各自
      直接调 graph 查询。这些是「MANDATORY」步骤，没装 CLI 就整体降级成 grep
      噪音，和 pr-review 改之前是同一个 bug。换成 wrapper 即可复用同一套
      resolve / 安装同意 / opt-out 逻辑。本次未做，因为需求范围只到 pr-review。

- [ ] **评估 `hooks/` 机会** — 例如 PreToolUse hook 机制化 pr-review 的 "subagent 不许 post"（现已部分由 agent 工具白名单覆盖，优先级降低）；pr-creator 的 commit message 规范检查。

## P2 — 清理

- [x] **metadata 收敛** — marketplace.json 的重复 description 移除（回退到 plugin.json）；canonical repo 确认为 `SiyuQian/devpilot-plugin`（origin remote 一致）。
- [x] **LICENSE 合并** — 11 份相同的 Apache-2.0 `LICENSE.txt` 合并为根目录 `LICENSE-APACHE-2.0.txt`，README 注明来源 skill 列表。
- [x] **README skill 列表防漂移** — 由 `scripts/validate.py` 检查每个 skill 都出现在 README 表格中（未做自动生成，drift 检查已足够）。
