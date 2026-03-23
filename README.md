# WiFi Sensing Localization

A notebook-based pipeline for indoor localization from WiFi sensing data. The project builds a hybrid dataset that combines angle/phase features with amplitude-derived fingerprints, pretrains an amplitude encoder with self-supervision, trains a supervised hybrid model, fine-tunes it on a target domain, and performs confidence-weighted inference with session-level aggregation.

## Repository layout

| File / directory | Purpose |
| --- | --- |
| `01_build_dataset.ipynb` | Scans the raw `Train/` and `Pred/` domains, normalizes labels, and exports hybrid `.npz` datasets for downstream stages. |
| `02_ssl_pretrain.ipynb` | Self-supervised pretraining for the amplitude branch encoder. |
| `03_supervised_source_train.ipynb` | Supervised source-domain training for the hybrid AoA + amplitude model. |
| `04_transfer_finetune.ipynb` | Target-domain transfer learning / fine-tuning using support and query data. |
| `05_kde_infer_aggregate.ipynb` | Final window-level inference plus confidence-weighted session aggregation. |
| `dataset_build_hybrid/` | Example dataset artifacts and label mapping produced by notebook 1. |
| `ssl_pretrain_runs/` | Example self-supervised training history and summary JSON files. |
| `hybrid_train_runs/` | Example supervised training summaries and class-center outputs. |
| `hybrid_transfer_runs/` | Example transfer-learning histories and evaluation summaries. |
| `hybrid_infer_runs/` | Example inference metrics after aggregation. |

## Pipeline overview

The notebooks are intended to be run in order:

1. **Build the dataset** with `01_build_dataset.ipynb`.
   - Reads raw data from `Train/` and `Pred/` folders under a configurable `DATA_ROOT`.
   - Normalizes occupancy / position labels.
   - Produces labeled, unlabeled, support, and query splits for the hybrid pipeline.
2. **Pretrain the amplitude encoder** with `02_ssl_pretrain.ipynb`.
   - Uses unlabeled training data and optionally target-domain support/query data.
   - Learns an amplitude representation before supervised training.
3. **Train the source-domain hybrid model** with `03_supervised_source_train.ipynb`.
   - Combines geometry-oriented phase/AoA features with the amplitude branch.
   - Optimizes multiple objectives such as presence, class, AoA, delta, and final losses.
4. **Fine-tune on the target domain** with `04_transfer_finetune.ipynb`.
   - Starts from the best supervised model.
   - Adapts the hybrid model using target-domain support data and evaluates on query samples.
5. **Run inference and aggregate predictions** with `05_kde_infer_aggregate.ipynb`.
   - Generates window-level predictions.
   - Applies confidence-based weighting and session-level aggregation.

## Data and labels

The sample artifacts in `dataset_build_hybrid/dataset_summary.json` show the expected class set and split sizes for one run:

- Classes: `Empty`, `LeftDown`, `LeftMid`, `LeftUp`, `MiddleDown`, `MiddleUp`, `RightDown`, `RightMid`, `RightUp`
- Split sizes:
  - `train_labeled_n`: 1774
  - `train_unlabeled_n`: 761
  - `pred_support_n`: 60
  - `pred_query_n`: 526

All notebooks use a configurable `DATA_ROOT` that currently points to `/home/tonyliao/Location_AMP` in the saved examples, so you will need to update those paths for your environment.

## Environment requirements

The notebooks import the following Python packages:

- `numpy`
- `pandas`
- `scipy`
- `scikit-learn`
- `matplotlib`
- `tensorflow`
- `IPython`
- Standard-library modules such as `json`, `math`, `os`, `pathlib`, `random`, and `re`

A typical setup could look like this:

```bash
python -m venv .venv
source .venv/bin/activate
pip install numpy pandas scipy scikit-learn matplotlib tensorflow ipython jupyter
```

> Note: TensorFlow GPU support is referenced in the notebooks, so a CUDA-enabled environment may be helpful if you plan to train the models at scale.

## Outputs and example results

This repository already includes example summary artifacts from a completed run:

- **SSL pretraining** (`ssl_pretrain_runs/amp_ssl_summary.json`)
  - 100 epochs
  - Batch size 32
  - Projection dimension 128
  - Embedding dimension 256
- **Supervised hybrid training** (`hybrid_train_runs/hybrid_train_summary.json`)
  - 100 epochs
  - Batch size 16
  - Multi-task loss weights for presence, class, AoA, delta, and final outputs
- **Transfer fine-tuning** (`hybrid_transfer_runs/transfer_summary.json`)
  - Query set size: 526
  - Mean XY error: about 0.1604
  - Median XY error: about 0.1404
  - Class accuracy: 1.0
- **Final inference aggregation** (`hybrid_infer_runs/infer_summary.json`)
  - Window class accuracy: 1.0
  - Session mean error (weighted): about 0.1357
  - Confidence mode: `exp_score`

These metrics are useful as a reference point when checking whether a rerun is behaving as expected.

## How to use this repository

1. Open the notebooks in Jupyter Lab or Jupyter Notebook.
2. Update `DATA_ROOT` and any other path-related configuration cells to point at your dataset location.
3. Run the notebooks sequentially from `01_build_dataset.ipynb` through `05_kde_infer_aggregate.ipynb`.
4. Inspect the generated JSON summaries and model artifacts inside the corresponding output folders.
5. Compare your metrics against the included example summaries.

## Notes and caveats

- The repository is notebook-first; there is no packaged Python module or CLI yet.
- Paths in the saved notebook configs are environment-specific and should be treated as examples, not defaults you can rely on.
- Because the project depends on local dataset folders that are not committed here, reproducing the full pipeline requires access to the original WiFi sensing data.

## Suggested next improvements

- Export shared utility code from notebooks into Python modules for easier reuse and testing.
- Add an `environment.yml` or `requirements.txt` for reproducible setup.
- Save representative model architecture diagrams or notebook screenshots if this repo is meant for presentation.
- Add a data dictionary describing each stored feature array in the generated `.npz` files.
