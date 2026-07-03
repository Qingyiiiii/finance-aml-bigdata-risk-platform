# analysis

Language: [中文](README_zh.md) | [English](README_en.md)

`analysis/` contains analysis, feature engineering, baseline modeling and explainability experiments for the finance AML project. It reads small evidence outputs from the offline warehouse stages and produces reproducible EDA, feature tables, baseline metrics, model explanations and anomaly detection reports.

### File Responsibilities

| File | Phase | Responsibility | Main Output |
| --- | --- | --- | --- |
| `p9_utils.py` | Shared utility | Project paths, run directory handling, TSV/JSON/text writing and metric loading | Helper functions |
| `p9_label_eda.py` | P9 EDA | Label distribution, amount buckets, payment-format and currency label rates | `label_distribution.tsv`, `eda_metrics.tsv`, `eda_summary.md` |
| `p9_feature_build.py` | P9 feature engineering | Build a non-leakage modeling table with fixed sampling and train/test split | `feature_dataset.parquet`, `feature_schema.md` |
| `p9_baseline_model.py` | P9 baseline | Train Logistic Regression and Random Forest models and report imbalanced-task metrics | `baseline_metrics.tsv`, `model_card.md`, `feature_importance.tsv` |
| `p16_model_explainability.py` | P16 AI enhancement | Explain the P9 baseline and add an Isolation Forest anomaly detection experiment | `model_explainability_report.md`, `anomaly_detection_report.md` |

### Execution Order

```text
p9_label_eda.py
  -> p9_feature_build.py
  -> p9_baseline_model.py
  -> p16_model_explainability.py
```

`p9_utils.py` is reused by the scripts above and does not represent a standalone business phase.

### Design Boundary

- P9/P16 are portfolio-level analysis and experiments, not production AML models.
- `is_laundering` is used only as a synthetic-data label.
- Feature engineering explicitly excludes label-derived fields and future information.
- Baseline evaluation focuses on precision, recall, F1, ROC-AUC and PR-AUC. Accuracy is not used as the core conclusion.
- P16 explainability reports describe model focus areas. They are not causal proof or production compliance explanations.
- Isolation Forest is used only for unsupervised anomaly detection learning and does not replace the P9 supervised baseline.

### Output Location

Default outputs are written to:

```text
data/finance_bigdata/runs/
```

The public repository does not store generated large datasets, model artifacts or local sensitive configuration. To reproduce the pipeline, prepare the `datas/` input files first and then run the corresponding orchestration scripts under `bin/`.

