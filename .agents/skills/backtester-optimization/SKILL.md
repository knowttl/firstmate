---
name: backtester-optimization
description: >-
  Use when the captain commissions a backtester optimization session - anchor on a baseline run, replicate it across a diversified asset set, analyze the trades with the replay analytics, then iterate one config lever at a time (entry rule models, thresholds, trade-management plans) toward a risk-adjusted objective, reporting on an annotatable board with an explicit decisions card.
user-invocable: true
metadata:
  internal: true
---

# Backtester optimization session

An optimization session tunes the strategy pipeline through CONFIG, never code: backtest runs, rule-model registry variants, trade-management plans, and strategy templates.
The deliverable is an Atelier board the captain reviews and annotates, a standalone report, and (only on his explicit decision) config changes locked into the app.
The template below is the shape of a session that took a pooled 9-asset result from -7.6R (PF 0.96) to +49.2R (PF 1.72); a session's board and report live under its own task directory in the firstmate data dir.

Use this skill when the ask is "optimize the backtester / strategy settings", "find better entry or exit config", "re-run the optimization on a new baseline", or any request to iterate configurations and compare what works best.
Do not use it for rule DESIGN against labeled examples (that is `codev-session`) or for feature work.

## Hard rails

- Live-stack access is per-session: the captain must explicitly authorize running against the live backtester; otherwise use a dev stack. Even when live is authorized, the scope is the backtester feature only - never brokers, orders, deploys, or DB surgery, and all changes go through the app API.
- Never modify or delete the captain's existing runs, plans, templates, or models during experimentation. Only ADD entities, every one namespaced `OPT-<iteration>-<lever>[-<asset>]`, with descriptions saying "Experiment - safe to delete after review".
- Adoption (activating a model, renaming/repointing plans or templates, touching anything pre-existing) happens only after the captain's explicit decision, and record the revert path when you do it.
- If a genuinely better result needs a code change or a capability the app lacks, do not write code - log it as a recommendation/decision for the captain.
- End with a cleanup inventory: every run, plan, template, and registry model the session created, by name and id.

## The objective

Default to RISK-ADJUSTED returns - pooled profit factor and expectancy per trade - with total net return at or above the anchor asset's baseline, unless the captain states otherwise.
Guard against overfitting: judge every change on the POOLED asset set and per-asset, keep a reasonable minimum trade count, and run a year-split consistency check on the winner before recommending it.

## Workflow

1. **Baseline anchor.** Take the run the captain names, read its EXACT config (`GET /api/v1/backtester/{id}`), and freeze everything he did not put in scope (typically Context/Validation models and thresholds, date range, proximity window). Pin models per run via `model_overrides` so later activations cannot shift the comparison. Re-run the anchor yourself once to confirm it reproduces before trusting any delta.
2. **Asset set.** Pick ~8 liquid names across sectors whose primary datasets cover the full date range at all three timeframes (`GET /api/v1/market-data`, check start/end per timeframe). Replicate the baseline verbatim per asset as `OPT-0-baseline-<asset>` and pool the results. Expect the baseline NOT to generalize - that gap is the work.
3. **Trade-level analysis before any tuning.** Pool all baseline trades and use the stored analytics: `mfe_r`/`mae_r` excursions, the no-take-profit replay (`replay_peak_r`, `replay_exit_r`, `replay_exit_reason`), and the skipped/cancelled aggregates (`strategy_skipped_opportunity_*`, `strategy_cancelled_would_fill_*`). The questions that matter: where do winners' unconstrained paths peak vs the TP (tail left on table)? What fraction of losers never reach +0.25R/+1R (false positives no management can rescue)? Do break-even exits later run (BE shakeout)? Does entry confidence actually rank outcomes (if non-monotone, threshold tuning is a dead lever)?
4. **Iterate one lever at a time.** Each iteration: one coherent change, all assets re-run, runs named `OPT-I<n>-<lever>-<asset>`, verdict logged before the next lever. Management levers are plan/template entities (TP legs incl. partials, break-even trigger/buffer, stop ATR multiple/method, cancel lines, overlap policy - the run request accepts a template_id plus `overlap_policy` override). Entry levers are `model_overrides.entry` swaps (registry rule models, or new hyperparameter variants saved via `POST /rule-workbench/save-to-registry` - bounds come from the type's HyperparameterSpec). Then combine the independent winners and re-verify; then refine around the combo. Stop at diminishing returns - two consecutive refinements that fail to beat the combo.
5. **Verification audits on the winner.** Year-split consistency; a parallel-overlap run (doubles as data: joining one-at-a-time skips to the parallel run's per-signal outcomes answers "are we holding the wrong signal" exactly, since per-signal simulations are independent); and any captain-specific question grounded in the stored trades rather than fresh speculation.
6. **Report as you go.** Atelier board (`atelier-axi`; if the captain needs LAN access, front it with a forwarder - `atelier-axi` binds 127.0.0.1, and never use `atelier-axi share`). Board contents: baseline anchor with frozen-vs-tunable split, per-asset baseline table with a pooled row, the trade-level findings as cards, a per-iteration table (per-asset R, pooled R/PF/expectancy/trade count) with a written verdict per iteration, and a recommendations section. Report the board URL early. Keep the `atelier-axi poll` alive; captain messages arrive through it and are answered with `--agent-reply`.
7. **Decisions, adoption, closeout.** Put every genuine captain choice on the board as an interactive decisions card (input playbook: plain-English options with upside/cost and an example, per-card queue + queue-all), and register each as a decision hold per the `decision-hold-lifecycle` skill; resolve holds with his verbatim answers routed to follow-up tasks. On "lock it in": activate the winning entry model (`POST /cascade/models/{id}/activate` - deactivates the layer's other models; note the revert), promote the winning plan/template to production names, and only repoint the captain's own defaults on his explicit word. Write the standalone report (stands alone: what/found/evidence/recommend), record session learnings for any commissioned follow-up work, and finish with the cleanup inventory.

## Tooling patterns that worked

- A `submit_run.sh` that POSTs the frozen baseline body varying only name/asset/entry-model/threshold/strategy JSON, and a sequential `run_batch.sh` that polls each run to completion - one live run at a time keeps the stack gentle; a 9-asset batch takes ~12 minutes.
- A pooled `analyze.py` over run ids: per-asset metric table, pooled PF/expectancy computed from trades, confidence-bucket outcomes, loser-MFE buckets, winner peak/MAE percentiles, BE-exit peak counts.
- Candidate-gate scans: for any proposed filter feature, compute it per trade at entry and report the summed R of the trades it would remove, pooled and for the problem assets - a gate that removes positive R is rejected without a run.
- Feature values joined from the run's own `bar_scores` (per-layer confidences) plus daily/weekly bars via `GET /market-data/{dataset_id}/bars`.
