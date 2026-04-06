# localization_wifi_sensing

Passive Wi-Fi sensing pipeline for **through-wall indoor localization** using CSI-derived amplitude and phase features.

This repository contains a staged notebook workflow for:
- building paired A/B-view CSI datasets,
- self-supervised pretraining of an amplitude encoder,
- supervised hybrid localization training,
- inference, aggregation, and evaluation on unseen sessions.

## Pipeline overview

The current workflow is organized into four main stages.

### Stage 0 — CSI window building
Input CSI logs are converted into fixed windows with metadata.

Expected outputs include per-window tensors such as:
- amplitude windows,
- phase windows,
- optional AveCSI-normalized amplitude,
- metadata fields such as label, session, source file, and pair/view information.

Reference script:
- `0_csi_build_windows.txt`

### Stage 1 — Dataset building
Build paired A/B samples and save dataset manifests and compressed NPZ files.

Notebook:
- `01_build_dataset.ipynb`

Main outputs:
- `dataset_build_hybrid/train_labeled.npz`
- `dataset_build_hybrid/train_unlabeled.npz` (optional)
- `dataset_build_hybrid/pred_support.npz`
- `dataset_build_hybrid/pred_query.npz`
- `dataset_build_hybrid/label_map.json`
- `dataset_build_hybrid/dataset_summary.json`

Key notes:
- supports paired A/B folders,
- supports amplitude and phase branches,
- supports AveCSI-based amplitude input,
- keeps metadata needed for later aggregation and analysis.

### Stage 2 — SSL pretraining for amplitude encoder
Pretrain the amplitude branch using self-supervised contrastive learning.

Notebook:
- `02_ssl_pretrain.ipynb`

Main outputs:
- `ssl_pretrain_runs/amp_ssl_encoder_best.keras`
- `ssl_pretrain_runs/amp_ssl_encoder_final.keras`
- `ssl_pretrain_runs/amp_ssl_projector_final.keras`
- `ssl_pretrain_runs/amp_ssl_history.json`
- `ssl_pretrain_runs/amp_ssl_summary.json`

Default behavior in the current notebook:
- uses `train_unlabeled.npz` if available,
- otherwise can fall back to labeled training data with labels ignored,
- can optionally include `pred_support` and `pred_query` in SSL.

### Stage 3 — Supervised hybrid training
Train a hybrid model that fuses amplitude and phase inputs.

Notebook:
- `03_supervised_source_train.ipynb`

Main outputs:
- `hybrid_train_runs/hybrid_model_best.keras`
- `hybrid_train_runs/hybrid_model_final.keras`
- `hybrid_train_runs/hybrid_train_history.json`
- `hybrid_train_runs/hybrid_train_summary.json`
- `hybrid_train_runs/class_centers.json`

Model structure:
- amplitude encoder initialized from SSL,
- phase branch for geometry/phase-guided features,
- multi-head outputs including:
  - presence,
  - anchor/class prediction,
  - geometry/AoA-related XY,
  - amplitude correction delta,
  - final fused XY.

### Stage 4 — Inference and aggregation
Run per-window prediction on unseen sessions, compute confidence weights, aggregate session-level coordinates, and visualize results.

Notebook:
- `04_kde_infer_aggregate.ipynb`

Main outputs:
- `hybrid_infer_runs/*.csv`
- `hybrid_infer_runs/*.json`
- session plots and evaluation figures

The inference notebook currently supports:
- per-window prediction,
- confidence weighting using score or softmax margin,
- presence-aware weighting,
- session-level aggregation,
- continuous-coordinate evaluation,
- nearest-anchor evaluation for coarse localization reporting.

---

## Data assumptions

The pipeline assumes a passive Wi-Fi sensing setting with:
- stationary or near-stationary human presence,
- paired A/B receiver viewpoints,
- anchor-based supervised training labels,
- optional unseen prediction sessions for evaluation.

Typical anchor labels include:
- `Empty`
- `LeftDown`
- `LeftMid`
- `LeftUp`
- `MiddleDown`
- `MiddleUp`
- `RightDown`
- `RightMid`
- `RightUp`

Unseen sessions may include cases such as:
- `LeftUp_Pred`
- `LeftUp_Near`
- `LeftDown_Far`
- `Center`
- `Wall`
- `Empty_Pred`
- `Corner`
---

## Recommended execution order

1. Run Stage 0 to build clean CSI windows.
2. Run `01_build_dataset.ipynb`.
3. Run `02_ssl_pretrain.ipynb`.
4. Run `03_supervised_source_train.ipynb`.
5. Run `04_01_kde_infer_aggregate.ipynb`. or `04_02_kde_infer_aggregate_nearest_anchor_eval.ipynb`

---

## Important implementation notes

### 1. Check model path consistency
`03_supervised_source_train.ipynb` saves the trained model to:
- `hybrid_train_runs/`

But `04_kde_infer_aggregate.ipynb` is configured to load from:
- `hybrid_transfer_runs/`

If no separate transfer-learning stage is used, update the inference notebook so that `MODEL_PATH` points to the trained model actually produced by Stage 3.

Recommended fix:
```python
TRAIN_DIR = DATA_ROOT / "hybrid_train_runs"
MODEL_PATH = TRAIN_DIR / "hybrid_model_best.keras"
```

### 2. Be explicit about the SSL regime
The current SSL notebook can include `pred_support` and `pred_query`.
This changes the evaluation setting.

Use one of these clearly:
- **strict inductive**: do not include target query data in SSL,
- **transductive / UDA-style**: include target support or query, but report it clearly.

### 3. Continuous error vs nearest-anchor evaluation
Two evaluation modes are useful:

- **Continuous localization error**: Euclidean distance between predicted XY and GT XY.
- **Nearest-anchor evaluation**: snap the predicted point to the closest anchor center and report coarse zone-level correctness.

Nearest-anchor evaluation can look better in tables, but it should be reported as a secondary metric rather than replacing continuous localization accuracy.

---

## Current limitations

Based on the current pipeline and recent results:
- sessions such as `LeftUp_Pred` and `Empty_Pred` are relatively stable,
- `Wall` and `Center` remain difficult,
- snapping predictions to nearest anchors does not fix sessions that are already biased toward the wrong anchor,
- this suggests the main problem is not only aggregation but also **systematic per-window prediction bias** and **insufficient anchor support**.

---

## Suggestions to improve results

### Highest-priority changes

#### 1. Fix inference-to-training mismatch first
Before changing the model, make sure inference loads the correct trained checkpoint.

Why:
- loading the wrong directory or a stale transfer model can invalidate all comparisons.

#### 2. Add more anchors near failure regions
Your hardest cases are not solved by snapping because the model is still choosing the wrong region.

Recommended:
- add anchors near `Wall`,
- add one or more anchors near `Center`,
- add wall-adjacent and out-of-grid support points if those are part of the target task.

Why:
- current anchors mainly cover an internal grid,
- sessions outside or near the boundary are under-supported.

#### 3. Strengthen the phase branch rather than only changing aggregation
Recent behavior suggests the issue is upstream of aggregation.

Recommended:
- use phase-difference features between antennas,
- use sanitized phase slope / detrended phase features,
- add phase reliability features such as phase variance or consistency,
- treat the phase branch as a robust phase-feature-guided branch rather than claiming explicit AoA unless AoA is truly estimated.

#### 4. Use robust session aggregation
Weighted mean is simple but still sensitive to biased windows.

Try:
- weighted median of X and Y,
- trimmed weighted mean,
- Huber-style robust aggregation,
- outlier rejection before session fusion.

Why:
- if a minority of windows are badly shifted, robust aggregation is often better than plain mean.

#### 5. Separate “presence confidence” from “localization confidence”
The current weighting multiplies by presence probability.
This can suppress empty sessions well, but it may not be the right confidence signal for localization quality.

Try:
- a localization uncertainty head,
- class-margin-only weighting,
- quality weighting based on window stability features,
- calibrating presence and localization weights separately.

### Medium-priority changes

#### 6. Make validation session-aware
Ensure train/validation splits are session-level, not random-window-level.

Why:
- window leakage can make validation look better than true generalization.

#### 7. Clarify target adaptation usage
If target data are from the same room but only different positions, prioritize:
- denser anchors,
- better phase robustness,
- better confidence gating.

If environment/setup changes, then target adaptation becomes more useful.

#### 8. Add anchor-prototype diagnostics
For each session, log:
- nearest anchor to weighted XY,
- class-majority anchor,
- distance to top-2 anchor centers,
- per-window class entropy,
- per-session variance.

This helps distinguish:
- ambiguous sessions,
- out-of-support sessions,
- confidently wrong sessions.

---

## Suggested immediate next changes

If you want the fastest path to better results, do these first:

1. update `MODEL_PATH` in inference to match Stage 3 output,
2. keep continuous error as the primary metric,
3. keep nearest-anchor error as a secondary metric,
4. add 1–3 anchors near `Wall` and `Center`,
5. replace weighted mean with weighted median or trimmed weighted mean,
6. refine the phase branch and confidence design before changing the whole architecture.

---

## Repository status summary

Current repository status is best described as:
- a staged research pipeline,
- optimized for notebook-based experimentation,
- suitable for passive Wi-Fi sensing localization experiments,
- still evolving in evaluation design and model calibration.

For publication-quality reporting, document clearly:
- dataset split policy,
- whether target query data are used in SSL,
- whether evaluation is continuous or nearest-anchor based,
- which checkpoint was used for inference,
- exact anchor coordinates and units.
