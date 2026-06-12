# model-eval agent 特化改造设计（benchmark-test 分支）

> 分支：`benchmark-test`　│　日期：2026-06-10
> 目标：把 `acpx_auto_tester_test` 在 `benchmark-test` 分支上**特化为专门测 model 的 agent**，从 **效率 / 准确率** 两维评价候选模型，反推 `flash` / `pro` / `max` 三档各配哪个真实模型。
> 这是一次**有意的分叉**：benchmark-test 不需兼容生产工作流，可直接颠覆为生产服务的复杂度。

---

## 1. 目标与背景

测试团队新建 GitLab 仓库，把原 hulat 配置上传到 `dev`/`master`，并复制了若干 issue。现在要用这些 issue 做模型能力验证：让同一个 issue 在多个候选模型上各跑一遍，采集效率、准确率，对比后决定 `model:flash` / `model:pro` / `model:max` 三档各绑定哪个真实模型。

`acpx claude exec` 唤起 Claude Code 后，顺序经过 `hulat/agents/` 的三个子 agent —— `detector.md`（scanner）→ `testcase-generator.md`（generator）→ `executor.md`（executor，实际执行生成的 Robot Framework 用例）。三步在**单次 `acpx claude exec` 内**串联，有数据依赖，都经 `TASK_OUTPUT_DIR` 写入同一个 `OUTPUT_DIR`。

---

## 2. 关键决策（已与用户确认）

| # | 决策 | 取值 |
|---|------|------|
| D1 | 模型评测粒度 | **整条 run 一档**：一个 issue 的一个 attempt 用一个模型（不给单步指定模型） |
| D2 | issue 是否拆 scanner/generator/executor | **交项目方决定，agent 不强制** |
| D3 | 评测维度 | **效率 + 准确率两维**；**cost 不采**（由专门部门统计） |
| D4 | 准确率口径 | **robot 执行通过率**（解析 Robot Framework `output.xml`） |
| D5 | 评测形态 | **长期内建**；benchmark-test 分支**特化**为 model-eval agent |
| D6 | 留档方式 | **每 attempt 独立不可变分支** + 全量 log 入库（默认行为） |
| D7 | sweep 编排 | **operator 驱动**：每换一个模型手动触发一轮，`pin_model_tier` 指定 |
| D8 | 颠覆范围（移除） | **失败升档阶梯**、**MR/pr 流程**、**continue 续作**三套移除；保留 per-side 失败标签 |
| D9 | 落地节奏 | **分两阶段**：阶段一让评测跑起来，阶段二删死代码 |

### D1/D2 的硬限制（同步给项目方）

即便项目方把一个 issue 拆成 scanner/generator/executor 三个 issue，模型仍是「整 run 一个 `settings.json`」，**无法给单个步骤配不同模型**。拆 issue 只能分别观测三步产物质量，不改变「一 run 一模型」。

---

## 3. 特化定位：保留什么、颠覆什么

### 3.1 颠覆/移除（D8）

| 子系统 | 为什么评测用不上 | 处理 |
|--------|------------------|------|
| **失败升档阶梯** `resolve_model_tier` 的 hard/soft 升档、`quality:low`、`model_upgrade_continue_threshold`、`model:<tier>` 单调不变式 | 评测的 model 由 operator pin 决定，不能「失败自动换大模型」，且 sweep 要在同一 issue 上换不同档 | model 改由 `pin_model_tier` 决定；放弃单调上升 |
| **MR / pr 流程** `create_mr.sh`、executor Step 7/8、`pr` 标签、`done→pr` 替换 | 评测不合入代码 | 跳过 → 终态就是 `done` |
| **continue 续作** `continue` 标签、`prepare_attempt` 的 restore、`build_prompt` 的 past-attempt/reviewer 注入、`continue_mode.md` | 评测每轮要从干净基线起跑保证横向可比 | 只保留 fresh，强制每轮重置 |

### 3.2 一律保留（可靠性核心，不动）

`reconcile` + 证据文件、`flock` 单实例、`precheck` 环境门禁、`timeout`/孤儿进程防护、UI 账号池分配（robot 登录被测系统跑用例必需）、并发 per-issue worktree、anonymous spawn + async callback、状态文件由 dispatcher 统一写、**per-side 失败标签拆分**（`blocked-cc`/`blocked-dispatcher`/`failed-cc`/`failed-dispatcher` + `blocked→failed` 升级）。

### 3.3 评测两维（D3/D4）

- **efficiency** = `wall_clock_seconds`：`run_acpx_attempt.sh` 在 acpx 调用前后掐 epoch 戳。
- **accuracy** = robot 通过率：解析 `OUTPUT_DIR` 下 Robot Framework `output.xml` 的 `<statistics>`/`<total>` → `passed/failed/total/pass_rate`，多文件聚合。
- **cost 不采**：交专门部门。

---

## 4. 改造设计（4 个单元）

### 单元 1 ── 全量留档 + per-attempt 不可变分支（默认行为）

- **`stage_and_guard.sh`**：force-add **整个 `${LOG_DIR}`**（`acpx_raw.log`、`git_diff.patch`、`acpx_command.txt`、`timing.txt`、`metrics.json`），保留删除守卫。
- **`commit_and_push.sh`**：把 push 目标从「force-push 单一 `WORK_BRANCH`」改为 **push 不可变分支 `issue/<iid>-att<NNN>`**（每 attempt 唯一、非 force、永不覆盖）。每个模型的整轮产物 + log + `metrics.json` 永久留存、互不覆盖。（阶段一可暂留 `WORK_BRANCH` 作为「最新指针」；阶段二确认无消费者后移除。）

### 单元 2 ── 指标采集 `collect_metrics.sh`（始终开启）

subagent 在 `run_acpx_attempt.sh` 之后、`stage_and_guard.sh` 之前新增一步（executor_prompt Step 1.5），产出 `${LOG_DIR}/metrics.json`：

```jsonc
{
  "iid": 14, "attempt_number": 3, "model": "pro",
  "wall_clock_seconds": 842,
  "accuracy": { "available": true, "passed": 18, "failed": 2, "total": 20, "pass_rate": 0.90, "robot_files": 5 },
  "status": "done"
}
```

`collect_metrics.sh` 是 **best-effort 观测脚本**：`output.xml` 找不到时记 `accuracy.available=false`、退出 0，**绝不阻断 issue 工作流**——指标是观测产物不是工作产出，这是对 strict no-fallback 的有意例外（脚本自身的 bash 语法/IO 错误仍按常规失败）。

头条数字经 **subagent compact JSON 回执的新 `metrics` 字段**回传 orchestrator（沿用「compact JSON 携带 Phase 6 所需一切事实」的既有模式）。

### 单元 3 ── 模型 pin（新 trigger 字段 `pin_model_tier`，取代升档阶梯）

- 取值必须是 `model_tiers` 的某元素，否则 abort `"invalid_pin_model_tier"`。
- **本分支必填**：缺失 abort `"pin_model_tier_required"`（评测必须显式指定 model；这样升档阶梯路径根本不会被触发，阶段二可安全删除其代码）。
- 设置时 `MODEL` = 该档，照常经 `model_settings_dir` 把 `${MODEL}-settings.json` 复制为 `.claude/settings.json`（真正切换底层模型的机制保留），并 stamp `model:<tier>` 标签留痕；**允许在同一 issue 上从高档切回低档**（放弃单调不变式）。
- **per-tick，非 carry-forward**（每轮显式指定）。

sweep（operator 驱动）：对同一 issue 连续触发多轮，每轮 `pin_model_tier` 指定下一个候选模型；每轮 = 一个新 attempt = 一次 tick（callback 门控下一轮）。

### 单元 4 ── 汇总（metrics ledger + `aggregate_benchmark.sh`）

- orchestrator 在 Phase 6（`dispatch_followup.sh`）把 compact JSON 的 `metrics` **append 到** `ifp-result/_dispatcher/benchmark/metrics.jsonl`（append-only，绕开 `attempt_state.json` 每 attempt 被覆盖的问题）。
- 新增 `aggregate_benchmark.sh`：读 ledger → 输出 `issue × model` 矩阵（`wall_clock` / `pass_rate`），按需运行，产 markdown/CSV 供拍板。

---

## 5. 两阶段落地路线（D9）

### 阶段一：让评测跑起来（行为变更，不删大段代码）

目标：能对同一 issue pin 不同 model 跑出 per-attempt 留档 + eff/acc 指标 + 对比矩阵。

1. 新增 `pin_model_tier`（必填），`resolve_model_tier` 走 pin 分支、跳过升档、放宽单调。
2. `run_acpx_attempt.sh` 加 `timing.txt`；新增 `collect_metrics.sh`（eff+acc）。
3. `stage_and_guard.sh` 全量 force-add `${LOG_DIR}`。
4. `commit_and_push.sh` push per-attempt 不可变分支。
5. executor_prompt 加 Step 1.5；**跳过** Step 7/8（MR/pr），终态 `done`。
6. dispatcher **强制 fresh**（忽略 continue 标签）。
7. compact JSON + `state_schema` 加 `metrics`；`dispatch_followup` append ledger。
8. 新增 `aggregate_benchmark.sh`。
9. reconcile/followup 分类：`done` 即成功终态（不再依赖 `pr`）。

### 阶段二：删死代码（清洁化，不改评测行为）

10. 删升档阶梯逻辑（`resolve_model_tier` 的 hard/soft 触发、`quality:low`、`model_upgrade_continue_threshold`、单调不变式）及相关 references。
11. 删 `create_mr.sh`、`pr` 标签全链路、`done→pr` 逻辑、MR 描述生成。
12. 删 continue 机器（`prepare_attempt` continue 分支、`build_prompt` 注入、`continue_mode.md`），`WORK_BRANCH` 若确认无消费者一并移除。
13. 同步精简 `SKILL.md` / `label_lifecycle.md` / `statemachine.v2.md`。

---

## 6. 改动文件清单（标注阶段）

| 文件 | 阶段 | 改动 |
|------|:----:|------|
| `scripts/run_acpx_attempt.sh` | P1 | acpx 前后写 `timing.txt` |
| `scripts/collect_metrics.sh` | P1 | **新增**：解析 efficiency + accuracy → `metrics.json`（best-effort） |
| `scripts/stage_and_guard.sh` | P1 | force-add 整个 `${LOG_DIR}` |
| `scripts/commit_and_push.sh` | P1 | push 不可变 `issue/<iid>-att<NNN>` |
| `scripts/dispatch_prepare_tick.sh` | P1 | 校验 `pin_model_tier`（必填）；走 pin、放宽单调；强制 fresh；跳过 MR 准备 |
| `scripts/_dispatch_lib.sh` | P1/P2 | `resolve_model_tier` pin 分支（P1）→ 删升档（P2）；ledger append 辅助 |
| `scripts/dispatch_followup.sh` | P1 | Phase 6 append `metrics.jsonl`；`done` 即成功终态 |
| `scripts/aggregate_benchmark.sh` | P1 | **新增**：ledger → `issue × model` 矩阵 |
| `references/executor_prompt.md` | P1 | 加 Step 1.5；跳过 Step 7/8；终态 `done` |
| `references/trigger_command.md` | P1/P2 | 加 `pin_model_tier`（P1）；删 escalation 相关字段（P2） |
| `references/state_schema.md` | P1 | compact JSON 加 `metrics`；ledger schema |
| `references/label_lifecycle.md` | P1/P2 | 终态 `done`（P1）；删 pr/escalation 语义（P2） |
| `scripts/create_mr.sh` | P2 | **删除** |
| `references/continue_mode.md` | P2 | **删除** |
| `scripts/prepare_attempt.sh`、`scripts/build_prompt.sh` | P2 | 删 continue 分支与注入 |
| `SKILL.md` | P1/P2 | 增补 pin/评测分支；删 escalation/MR/continue 描述；**每次 workspace 改动 bump `SKILL_VERSION`** |
| `statemachine.v2.md`（仓库根） | P1/P2 | 记录特化偏离（非 workspace，不触发 bump） |

> `workspace-acpx_auto_tester/` 下每次改动都走 code-review 子代理循环并 bump `SKILL_VERSION`。

---

## 7. 外部依赖（落地前必须确认，已降为 2 项）

1. **Robot Framework `output.xml` 落点**：测试团队确认 `executor.md` 确实产出 `output.xml`（及 `report.html`）及其在 `OUTPUT_DIR` 下相对路径。accuracy 解析器据此实现；找不到则 `accuracy.available=false`。
2. **候选模型清单**：明确 `model_settings_dir` 里各 `<tier>-settings.json` 对应哪个真实模型，sweep 才能把 pinned 档映射回真实模型做对比。

> （原「acpx 用量输出格式」依赖随 cost 维度删除已消除。）

---

## 8. 已知局限

- **pass-rate 盲区**：通过率只衡量「能跑绿」，不衡量「测得对」——模型可能生成「恒通过但无效」或漏测的用例。若后期失真，再叠加「黄金参考比对」交叉校验。本期按用户选择只做通过率。
- **cost 不在本 agent 视野内**：由专门部门统计，评测矩阵的成本维度需在 agent 之外人工并入。

---

## 9. 非目标（YAGNI）

- per-step 模型指定与隔离评测、per-step 时长细分。
- dispatcher 自动 sweep（本期 operator 驱动）。
- agent 自动给出三档最终决策（只产对比矩阵，决策由人做）。
- cost 采集、黄金参考比对、人工 rubric。
- 与生产工作流的兼容（本分支有意分叉）。

---

## 10. 验收标准

1. 对同一 issue 用 `pin_model_tier` 分别跑 flash/pro/max 三轮，远端出现三个互不覆盖的 `issue/<iid>-att<NNN>` 分支，各含完整 log + `metrics.json`。
2. `metrics.jsonl` 累积三条，每条含 `model`、`wall_clock_seconds`、`pass_rate`（或 `available=false`）。
3. `aggregate_benchmark.sh` 输出 `issue × model` 对比矩阵。
4. 评测不产生 MR、不打 `pr` 标签、不进入 continue；缺 `pin_model_tier` 直接 abort。
5. 阶段二删码后，评测行为与阶段一一致（清洁化不改结果）。
