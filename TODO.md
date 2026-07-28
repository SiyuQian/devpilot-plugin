# DevPilot Plugin 改进清单

Skills 从裸目录迁移为 Claude Code plugin 之后的后续改进项。

## P0 — 结构性收益

- [x] **pr-review fanout 改用 plugin `agents/`** — Agent A–F 抽成 `agents/pr-review-*.md`（固定 system prompt + 只读工具白名单）；`fanout.md` 瘦身为 dispatch 说明，保留 standalone fallback。
- [x] **CI 校验（GitHub Action）** — `.github/workflows/validate.yml` 跑 `scripts/validate.py`：manifest JSON、skill/agent/command frontmatter、name 与目录一致、description 非空。

## P1 — 可用性与发布流程

- [x] **加 `commands/` 目录** — `/pr-review`、`/pr`、`/repo-scan`、`/resolve-issues`、`/dead-code`。
- [x] **版本管理与 CHANGELOG** — bump 到 1.1.0，新增 `CHANGELOG.md`。后续每次改动 skill 应继续 bump + 记录；可选打 tag/Release。
- [x] **交叉引用一致性检查** — 并入 `scripts/validate.py`（`devpilot:<skill>` 引用存在性 + 残留旧 `devpilot-` 前缀检测）；已借此修掉 `harness-engineering/evals/README.md` 里一处迁移误改写。
- [x] **`scanning-repos` 迁到 `scripts/codegraph.sh`** — 随 1.6.0 的 codegraph
      后端切换一起做完：`SKILL.md` 步骤 2.4 改走 wrapper（`ensure` + `-- hubs`
      并按 `action` 分支），三个 scanner agent 改用 `"$CG" -- callers_of /
      tests_for / context`。整个 plugin 已无任何 `devpilot graph` 调用。

- [ ] **观察 codegraph caller 精度** — 1.6.0 引入 `caveats` 机制（`ambiguous_name`、
      `cross_community_method_binding`、`unresolved_call_sites`）来给 caller 数量
      分级，因为 CodeGraph 按名字绑定引用、不做 receiver 类型检查（实测
      `store.go::Close` 收到 93 个「调用者」）。跑一段真实 PR 后统计
      `confident:false` 的比例：若某个 caveat 常态化到让 graph 失去意义，考虑
      收紧过滤（例如要求 import 佐证）而不是继续放宽。

- [ ] **评估 `hooks/` 机会** — 例如 PreToolUse hook 机制化 pr-review 的 "subagent 不许 post"（现已部分由 agent 工具白名单覆盖，优先级降低）；pr-creator 的 commit message 规范检查。

## P2 — 清理

- [x] **metadata 收敛** — marketplace.json 的重复 description 移除（回退到 plugin.json）；canonical repo 确认为 `SiyuQian/devpilot-plugin`（origin remote 一致）。
- [x] **LICENSE 合并** — 11 份相同的 Apache-2.0 `LICENSE.txt` 合并为根目录 `LICENSE-APACHE-2.0.txt`，README 注明来源 skill 列表。
- [x] **README skill 列表防漂移** — 由 `scripts/validate.py` 检查每个 skill 都出现在 README 表格中（未做自动生成，drift 检查已足够）。
