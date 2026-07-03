# -*- coding: utf-8 -*-
"""Train and evaluate P9 baseline models for the finance AML learning task."""
from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import RandomForestClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    average_precision_score,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
)
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

from p9_utils import parse_metric_tsv, project_path, write_text, write_tsv


NUMERIC_FEATURES = [
    "amount_paid",
    "log_amount_paid",
    "is_cross_bank",
    "is_cross_currency",
    "transaction_hour",
    "hour_sin",
    "hour_cos",
    "from_total_event_count",
    "from_debit_count",
    "from_credit_count",
    "from_out_amount",
    "from_in_amount",
    "from_max_out_amount",
    "from_counterparty_count",
    "from_cross_bank_event_count",
    "from_cross_currency_event_count",
    "from_out_in_ratio",
    "from_debit_credit_ratio",
]
CATEGORICAL_FEATURES = ["payment_currency", "payment_format"]


def make_preprocessor(scale_numeric: bool = True) -> ColumnTransformer:
    """Build the sklearn preprocessing graph for numeric and categorical features."""
    numeric_steps = [("imputer", SimpleImputer(strategy="median"))]
    if scale_numeric:
        numeric_steps.append(("scaler", StandardScaler()))
    numeric_pipeline = Pipeline(numeric_steps)
    categorical_pipeline = Pipeline(
        [
            ("imputer", SimpleImputer(strategy="most_frequent")),
            ("onehot", OneHotEncoder(handle_unknown="ignore")),
        ]
    )
    return ColumnTransformer(
        [
            ("num", numeric_pipeline, NUMERIC_FEATURES),
            ("cat", categorical_pipeline, CATEGORICAL_FEATURES),
        ],
        remainder="drop",
    )


def split_dataset(df: pd.DataFrame, random_state: int):
    """Use the persisted P9 split when valid, otherwise fall back to stratified split."""
    if "split" in df.columns:
        train_df = df.loc[df["split"] == "train"].copy()
        test_df = df.loc[df["split"] == "test"].copy()
        valid_split = (
            len(train_df) > 0
            and len(test_df) > 0
            and train_df["is_laundering"].nunique() == 2
            and test_df["is_laundering"].nunique() == 2
        )
        if valid_split:
            return train_df, test_df, "stratified_random_75_25"

    train_df, test_df = train_test_split(
        df,
        test_size=0.25,
        random_state=random_state,
        stratify=df["is_laundering"],
    )
    strategy = "stratified_random_fallback_75_25"
    return train_df, test_df, strategy


def evaluate_model(name: str, model: Pipeline, x_test: pd.DataFrame, y_test: pd.Series) -> dict[str, float | str]:
    """Evaluate one baseline model with imbalance-aware metrics."""
    pred = model.predict(x_test)
    if hasattr(model, "predict_proba"):
        scores = model.predict_proba(x_test)[:, 1]
    else:
        scores = pred
    metrics: dict[str, float | str] = {
        "model": name,
        "precision": precision_score(y_test, pred, zero_division=0),
        "recall": recall_score(y_test, pred, zero_division=0),
        "f1": f1_score(y_test, pred, zero_division=0),
        "roc_auc": roc_auc_score(y_test, scores) if len(set(y_test)) > 1 else 0.0,
        "pr_auc": average_precision_score(y_test, scores) if len(set(y_test)) > 1 else 0.0,
    }
    tn, fp, fn, tp = confusion_matrix(y_test, pred, labels=[0, 1]).ravel()
    metrics.update({"tn": tn, "fp": fp, "fn": fn, "tp": tp})
    return metrics


def feature_names(preprocessor: ColumnTransformer) -> list[str]:
    """Return transformed feature names in the same order as the model sees them."""
    names: list[str] = []
    names.extend(NUMERIC_FEATURES)
    cat_pipeline = preprocessor.named_transformers_["cat"]
    onehot = cat_pipeline.named_steps["onehot"]
    names.extend(onehot.get_feature_names_out(CATEGORICAL_FEATURES).tolist())
    return names


def extract_importance(best_name: str, model: Pipeline) -> list[dict[str, object]]:
    """Extract feature importance or coefficients from the selected baseline model."""
    preprocessor = model.named_steps["preprocess"]
    names = feature_names(preprocessor)
    estimator = model.named_steps["model"]
    if hasattr(estimator, "coef_"):
        values = estimator.coef_[0]
    elif hasattr(estimator, "feature_importances_"):
        values = estimator.feature_importances_
    else:
        return []
    rows = []
    for name, value in zip(names, values):
        rows.append(
            {
                "model": best_name,
                "feature": name,
                "importance": float(value),
                "abs_importance": abs(float(value)),
            }
        )
    return sorted(rows, key=lambda item: item["abs_importance"], reverse=True)


def main() -> int:
    """Train baseline models, select the best PR-AUC model, and write P9 evidence."""
    parser = argparse.ArgumentParser(description="P9 baseline model training and evaluation.")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--feature-path", default="")
    parser.add_argument("--random-state", type=int, default=20260609)
    args = parser.parse_args()

    run_dir = project_path(args.run_dir)
    if args.feature_path:
        feature_path = project_path(args.feature_path)
    else:
        metrics = parse_metric_tsv(run_dir / "feature_dataset_summary.tsv")
        feature_path = Path(metrics["feature_path"])
    df = pd.read_parquet(feature_path)
    train_df, test_df, split_strategy = split_dataset(df, args.random_state)
    x_train = train_df[NUMERIC_FEATURES + CATEGORICAL_FEATURES]
    y_train = train_df["is_laundering"].astype(int)
    x_test = test_df[NUMERIC_FEATURES + CATEGORICAL_FEATURES]
    y_test = test_df["is_laundering"].astype(int)

    scale_preprocessor = make_preprocessor(scale_numeric=True)
    tree_preprocessor = make_preprocessor(scale_numeric=False)
    models: list[tuple[str, Pipeline]] = [
        (
            "logistic_regression_balanced",
            Pipeline(
                [
                    ("preprocess", scale_preprocessor),
                    (
                        "model",
                        LogisticRegression(
                            max_iter=500,
                            class_weight="balanced",
                            random_state=args.random_state,
                            n_jobs=1,
                        ),
                    ),
                ]
            ),
        ),
        (
            "random_forest_balanced",
            Pipeline(
                [
                    ("preprocess", tree_preprocessor),
                    (
                        "model",
                        RandomForestClassifier(
                            n_estimators=80,
                            max_depth=12,
                            min_samples_leaf=20,
                            class_weight="balanced_subsample",
                            random_state=args.random_state,
                            n_jobs=1,
                        ),
                    ),
                ]
            ),
        ),
    ]

    metric_rows: list[dict[str, object]] = []
    trained: list[tuple[str, Pipeline, dict[str, float | str]]] = []
    for name, pipeline in models:
        pipeline.fit(x_train, y_train)
        metrics = evaluate_model(name, pipeline, x_test, y_test)
        metric_rows.append(metrics)
        trained.append((name, pipeline, metrics))

    best_name, best_model, best_metrics = max(trained, key=lambda item: float(item[2]["pr_auc"]))
    write_tsv(
        run_dir / "baseline_metrics.tsv",
        metric_rows,
        ["model", "precision", "recall", "f1", "roc_auc", "pr_auc", "tn", "fp", "fn", "tp"],
    )
    confusion_rows = [
        {"model": best_name, "actual": 0, "predicted": 0, "count": best_metrics["tn"]},
        {"model": best_name, "actual": 0, "predicted": 1, "count": best_metrics["fp"]},
        {"model": best_name, "actual": 1, "predicted": 0, "count": best_metrics["fn"]},
        {"model": best_name, "actual": 1, "predicted": 1, "count": best_metrics["tp"]},
    ]
    write_tsv(run_dir / "confusion_matrix.tsv", confusion_rows, ["model", "actual", "predicted", "count"])
    importance_rows = extract_importance(best_name, best_model)[:50]
    write_tsv(run_dir / "feature_importance.tsv", importance_rows, ["model", "feature", "importance", "abs_importance"])

    split_rows = [
        {
            "split": "train",
            "rows": len(train_df),
            "positive_rows": int(y_train.sum()),
            "positive_rate": float(y_train.mean()),
            "strategy": split_strategy,
        },
        {
            "split": "test",
            "rows": len(test_df),
            "positive_rows": int(y_test.sum()),
            "positive_rate": float(y_test.mean()),
            "strategy": split_strategy,
        },
    ]
    write_tsv(run_dir / "model_train_test_split_summary.tsv", split_rows, ["split", "rows", "positive_rows", "positive_rate", "strategy"])

    model_card = f"""# P9 Baseline Model Card


This model is a portfolio baseline for AML-style transaction risk classification. It is not a production financial risk model.


- Source: P3/P4 HI-Small outputs
- Feature dataset: `{feature_path}`
- Rows used: `{len(df)}`
- Positive rows: `{int(df['is_laundering'].sum())}`
- Split strategy: `{split_strategy}`


- Logistic Regression with class balancing
- Random Forest with class balancing


- Model: `{best_name}`
- Precision: `{float(best_metrics['precision']):.6f}`
- Recall: `{float(best_metrics['recall']):.6f}`
- F1: `{float(best_metrics['f1']):.6f}`
- ROC-AUC: `{float(best_metrics['roc_auc']):.6f}`
- PR-AUC: `{float(best_metrics['pr_auc']):.6f}`


- The source data is synthetic.
- The feature dataset uses all positive rows and a sampled set of negative rows.
- Label-derived account features are excluded from model training.
- Threshold tuning, leakage review, fairness analysis and production monitoring are not complete.
- Accuracy is not the main metric because labels are highly imbalanced.
"""
    write_text(run_dir / "model_card.md", model_card)

    p9_summary = f"""# P9 Model Baseline Summary

- Run dir: `{run_dir}`
- Feature dataset: `{feature_path}`
- Feature rows: `{len(df)}`
- Train rows: `{len(train_df)}`
- Test rows: `{len(test_df)}`
- Best model by PR-AUC: `{best_name}`
- Best precision: `{float(best_metrics['precision']):.6f}`
- Best recall: `{float(best_metrics['recall']):.6f}`
- Best F1: `{float(best_metrics['f1']):.6f}`
- Best ROC-AUC: `{float(best_metrics['roc_auc']):.6f}`
- Best PR-AUC: `{float(best_metrics['pr_auc']):.6f}`
- Status: `PASS`

P9 is a baseline modeling milestone. It does not replace P8 delivery artifacts and is not a production risk model.
"""
    write_text(run_dir / "p9_summary.md", p9_summary)
    print("P9_MODEL_STATUS=PASS")
    print(f"P9_BEST_MODEL={best_name}")
    print(f"P9_BEST_PR_AUC={float(best_metrics['pr_auc']):.6f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
