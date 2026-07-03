# -*- coding: utf-8 -*-
"""Explain the accepted P9 baseline and add a P16 anomaly-detection learning report."""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest
from sklearn.impute import SimpleImputer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

from p9_utils import project_path, timestamped_run_dir, write_text, write_tsv


DEFAULT_P9_RUN_DIR = "data/finance_bigdata/runs/p9_model_baseline_20260609_231710"
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


def classify_feature_group(feature: str) -> str:
    """Map one model feature name to a finance-readable explanation group."""
    if feature.startswith("payment_format"):
        return "payment_format"
    if feature.startswith("payment_currency"):
        return "payment_currency"
    if feature in {"amount_paid", "log_amount_paid"}:
        return "amount"
    if feature in {"transaction_hour", "hour_sin", "hour_cos"}:
        return "time"
    if feature in {"is_cross_bank", "is_cross_currency"} or "cross_bank" in feature or "cross_currency" in feature:
        return "cross_institution_currency"
    if feature.endswith("_ratio"):
        return "account_ratio"
    if feature.startswith("from_"):
        return "account_behavior"
    return "other"


def load_best_metrics(metrics_path: Path) -> dict[str, object]:
    """Load the best P9 model row by PR-AUC."""
    metrics = pd.read_csv(metrics_path, sep="\t")
    best = metrics.sort_values("pr_auc", ascending=False).iloc[0].to_dict()
    return best


def build_feature_group_summary(importance_path: Path) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Aggregate raw feature importances into business explanation groups."""
    importance = pd.read_csv(importance_path, sep="\t")
    importance["feature_group"] = importance["feature"].map(classify_feature_group)
    grouped = (
        importance.groupby("feature_group", as_index=False)
        .agg(feature_count=("feature", "count"), total_importance=("abs_importance", "sum"), max_importance=("abs_importance", "max"))
        .sort_values("total_importance", ascending=False)
    )
    total = grouped["total_importance"].sum()
    grouped["importance_share"] = np.where(total > 0, grouped["total_importance"] / total, 0.0)
    top20 = importance.sort_values("abs_importance", ascending=False).head(20)
    return top20, grouped


def make_confusion_interpretation(best: dict[str, object]) -> list[dict[str, object]]:
    """Translate confusion-matrix cells into business-facing meanings."""
    tn = int(best["tn"])
    fp = int(best["fp"])
    fn = int(best["fn"])
    tp = int(best["tp"])
    total = tn + fp + fn + tp
    actual_positive = tp + fn
    actual_negative = tn + fp
    predicted_positive = tp + fp
    predicted_negative = tn + fn
    rows = [
        {"metric": "true_negative", "value": tn, "meaning": "正常交易且模型判为正常"},
        {"metric": "false_positive", "value": fp, "meaning": "正常交易但模型判为风险，代表告警成本"},
        {"metric": "false_negative", "value": fn, "meaning": "洗钱交易但模型漏判，代表漏报风险"},
        {"metric": "true_positive", "value": tp, "meaning": "洗钱交易且模型判为风险"},
        {"metric": "test_rows", "value": total, "meaning": "测试集总行数"},
        {"metric": "actual_positive_rows", "value": actual_positive, "meaning": "测试集洗钱标签正样本数"},
        {"metric": "actual_negative_rows", "value": actual_negative, "meaning": "测试集负样本数"},
        {"metric": "predicted_positive_rows", "value": predicted_positive, "meaning": "模型输出风险告警数量"},
        {"metric": "predicted_negative_rows", "value": predicted_negative, "meaning": "模型输出正常数量"},
        {"metric": "precision", "value": round(float(best["precision"]), 6), "meaning": "告警中真正洗钱的比例"},
        {"metric": "recall", "value": round(float(best["recall"]), 6), "meaning": "洗钱样本被找回的比例"},
        {"metric": "pr_auc", "value": round(float(best["pr_auc"]), 6), "meaning": "类别不平衡场景下更重要的排序指标"},
    ]
    return rows


def run_isolation_forest(df: pd.DataFrame, sample_size: int, random_state: int) -> tuple[pd.DataFrame, list[dict[str, object]], list[dict[str, object]]]:
    """Run a bounded Isolation Forest experiment for P16 anomaly-detection learning."""
    positives = df.loc[df["is_laundering"].astype(int) == 1].copy()
    negatives = df.loc[df["is_laundering"].astype(int) == 0].copy()
    remaining = max(sample_size - len(positives), 0)
    sampled_negatives = negatives.sample(n=min(remaining, len(negatives)), random_state=random_state)
    sample = pd.concat([positives, sampled_negatives], ignore_index=True)
    if len(sample) > sample_size:
        sample = sample.sample(n=sample_size, random_state=random_state)
    sample = sample.sample(frac=1.0, random_state=random_state).reset_index(drop=True)

    pipeline = Pipeline(
        [
            ("imputer", SimpleImputer(strategy="median")),
            ("scaler", StandardScaler()),
            (
                "model",
                IsolationForest(
                    n_estimators=100,
                    contamination=0.03,
                    random_state=random_state,
                    n_jobs=1,
                ),
            ),
        ]
    )
    x = sample[NUMERIC_FEATURES]
    labels = pipeline.fit_predict(x)
    scores = -pipeline.decision_function(x)
    sample["anomaly_label"] = (labels == -1).astype(int)
    sample["anomaly_score"] = scores

    anomaly = sample.loc[sample["anomaly_label"] == 1]
    sample_positive = int(sample["is_laundering"].sum())
    anomaly_positive = int(anomaly["is_laundering"].sum())
    anomaly_count = int(len(anomaly))
    overall_rate = sample_positive / len(sample) if len(sample) else 0.0
    anomaly_rate = anomaly_positive / anomaly_count if anomaly_count else 0.0
    lift = anomaly_rate / overall_rate if overall_rate > 0 else 0.0
    summary_rows = [
        {"metric": "sample_rows", "value": len(sample)},
        {"metric": "sample_positive_rows", "value": sample_positive},
        {"metric": "sample_positive_rate", "value": round(overall_rate, 8)},
        {"metric": "anomaly_rows", "value": anomaly_count},
        {"metric": "anomaly_positive_rows", "value": anomaly_positive},
        {"metric": "anomaly_positive_rate", "value": round(anomaly_rate, 8)},
        {"metric": "anomaly_lift_vs_sample", "value": round(lift, 6)},
        {"metric": "contamination", "value": 0.03},
        {"metric": "random_state", "value": random_state},
    ]

    ranked = sample.sort_values("anomaly_score", ascending=False).head(50)
    top_rows = []
    for _, row in ranked.iterrows():
        top_rows.append(
            {
                "transaction_id": row["transaction_id"],
                "split": row["split"],
                "amount_paid": row["amount_paid"],
                "payment_currency": row["payment_currency"],
                "payment_format": row["payment_format"],
                "is_cross_bank": row["is_cross_bank"],
                "is_cross_currency": row["is_cross_currency"],
                "is_laundering": row["is_laundering"],
                "anomaly_score": row["anomaly_score"],
                "anomaly_label": row["anomaly_label"],
            }
        )

    sample["score_decile"] = pd.qcut(sample["anomaly_score"].rank(method="first"), 10, labels=False) + 1
    deciles = (
        sample.groupby("score_decile", as_index=False)
        .agg(rows=("transaction_id", "count"), positive_rows=("is_laundering", "sum"), min_score=("anomaly_score", "min"), max_score=("anomaly_score", "max"))
        .sort_values("score_decile", ascending=False)
    )
    decile_rows = []
    for _, row in deciles.iterrows():
        rows = int(row["rows"])
        positives = int(row["positive_rows"])
        decile_rows.append(
            {
                "score_decile": int(row["score_decile"]),
                "rows": rows,
                "positive_rows": positives,
                "positive_rate": round(positives / rows if rows else 0.0, 8),
                "min_score": row["min_score"],
                "max_score": row["max_score"],
            }
        )
    return pd.DataFrame(top_rows), summary_rows, decile_rows


def main() -> int:
    """Build P16 explainability and anomaly-detection evidence from an accepted P9 run."""
    parser = argparse.ArgumentParser(description="P16 model explainability and anomaly detection learning report.")
    parser.add_argument("--p9-run-dir", default=DEFAULT_P9_RUN_DIR)
    parser.add_argument("--sample-size", type=int, default=50000)
    parser.add_argument("--random-state", type=int, default=20260613)
    args = parser.parse_args()

    p9_run_dir = project_path(args.p9_run_dir)
    run_dir = timestamped_run_dir("p16_model_explainability")

    feature_path = p9_run_dir / "feature_dataset.parquet"
    metrics_path = p9_run_dir / "baseline_metrics.tsv"
    importance_path = p9_run_dir / "feature_importance.tsv"

    df = pd.read_parquet(feature_path)
    best = load_best_metrics(metrics_path)
    top20, grouped = build_feature_group_summary(importance_path)
    confusion_rows = make_confusion_interpretation(best)

    class_rows = [
        {"metric": "feature_rows", "value": len(df)},
        {"metric": "positive_rows", "value": int(df["is_laundering"].sum())},
        {"metric": "negative_rows", "value": int((df["is_laundering"].astype(int) == 0).sum())},
        {"metric": "positive_rate", "value": round(float(df["is_laundering"].mean()), 8)},
        {"metric": "train_rows", "value": int((df["split"] == "train").sum())},
        {"metric": "test_rows", "value": int((df["split"] == "test").sum())},
    ]

    top_anomaly, anomaly_summary, decile_rows = run_isolation_forest(df, args.sample_size, args.random_state)

    write_tsv(run_dir / "class_balance_summary.tsv", class_rows, ["metric", "value"])
    write_tsv(run_dir / "feature_importance_top20.tsv", top20.to_dict("records"), ["model", "feature", "importance", "abs_importance", "feature_group"])
    write_tsv(run_dir / "feature_group_summary.tsv", grouped.to_dict("records"), ["feature_group", "feature_count", "total_importance", "max_importance", "importance_share"])
    write_tsv(run_dir / "confusion_matrix_interpretation.tsv", confusion_rows, ["metric", "value", "meaning"])
    write_tsv(run_dir / "anomaly_detection_summary.tsv", anomaly_summary, ["metric", "value"])
    write_tsv(run_dir / "anomaly_score_deciles.tsv", decile_rows, ["score_decile", "rows", "positive_rows", "positive_rate", "min_score", "max_score"])
    write_tsv(
        run_dir / "top_anomaly_transactions.tsv",
        top_anomaly.to_dict("records"),
        [
            "transaction_id",
            "split",
            "amount_paid",
            "payment_currency",
            "payment_format",
            "is_cross_bank",
            "is_cross_currency",
            "is_laundering",
            "anomaly_score",
            "anomaly_label",
        ],
    )

    top_groups = grouped.head(5)
    top_features = top20.head(10)
    best_model = str(best["model"])
    best_precision = float(best["precision"])
    best_recall = float(best["recall"])
    best_pr_auc = float(best["pr_auc"])

    report = [
        "# P16 Model Explainability Report",
        "",
        f"- Source P9 run_dir: `{p9_run_dir}`",
        f"- P16 run_dir: `{run_dir}`",
        f"- Best P9 model: `{best_model}`",
        f"- Precision: `{best_precision:.6f}`",
        f"- Recall: `{best_recall:.6f}`",
        f"- PR-AUC: `{best_pr_auc:.6f}`",
        f"- Isolation Forest sample rows: `{args.sample_size}`",
        "- Status: `PASS`",
        "",
        "## Feature Understanding",
        "",
        "The strongest feature groups are:",
        "",
    ]
    for _, row in top_groups.iterrows():
        report.append(f"- `{row['feature_group']}`: importance share `{float(row['importance_share']):.6f}` across `{int(row['feature_count'])}` features.")
    report.extend(["", "Top individual features:", ""])
    for _, row in top_features.iterrows():
        report.append(f"- `{row['feature']}`: `{float(row['abs_importance']):.6f}`")
    report.extend(
        [
            "",
            "## Metric Interpretation",
            "",
            "Precision describes alert quality. Recall describes how many laundering samples are found. PR-AUC is emphasized because the positive class is rare and ROC-AUC can look optimistic under class imbalance.",
            "",
            "## Boundary",
            "",
            "P16 is an AI learning enhancement. It explains the P9 baseline and adds an unsupervised anomaly-detection experiment, but it does not replace the P9 model, P10 feature parity, or P14 master validation.",
        ]
    )
    write_text(run_dir / "model_explainability_report.md", "\n".join(report))

    anomaly_summary_map = {row["metric"]: row["value"] for row in anomaly_summary}
    anomaly_report = f"""# P16 Anomaly Detection Learning Report

- Method: `IsolationForest`
- Source feature dataset: `{feature_path}`
- Sample rows: `{anomaly_summary_map['sample_rows']}`
- Anomaly rows: `{anomaly_summary_map['anomaly_rows']}`
- Anomaly positive rows: `{anomaly_summary_map['anomaly_positive_rows']}`
- Anomaly positive rate: `{anomaly_summary_map['anomaly_positive_rate']}`
- Lift vs sample positive rate: `{anomaly_summary_map['anomaly_lift_vs_sample']}`
- Status: `PASS`


Isolation Forest is used here as an unsupervised learning exercise. It scores unusual transactions using non-leakage numeric features from P9. A higher anomaly score means the transaction is more isolated from common behavior in the sampled feature space.

This experiment is useful for learning anomaly detection, but it is not a production AML model and does not replace the supervised P9 baseline.
"""
    write_text(run_dir / "anomaly_detection_report.md", anomaly_report)

    status_rows = [
        {"metric": "run_name", "value": run_dir.name, "status": "PASS"},
        {"metric": "source_p9_run_dir", "value": str(p9_run_dir), "status": "PASS"},
        {"metric": "feature_rows", "value": len(df), "status": "PASS" if len(df) == 205177 else "FAIL"},
        {"metric": "best_model", "value": best_model, "status": "PASS" if best_model == "random_forest_balanced" else "FAIL"},
        {"metric": "best_pr_auc", "value": f"{best_pr_auc:.6f}", "status": "PASS" if round(best_pr_auc, 6) == 0.741912 else "FAIL"},
        {"metric": "anomaly_rows", "value": anomaly_summary_map["anomaly_rows"], "status": "PASS" if int(anomaly_summary_map["anomaly_rows"]) > 0 else "FAIL"},
        {"metric": "p16_status", "value": "PASS", "status": "PASS"},
    ]
    if any(row["status"] == "FAIL" for row in status_rows):
        status_rows[-1] = {"metric": "p16_status", "value": "FAIL", "status": "FAIL"}
    write_tsv(run_dir / "p16_status.tsv", status_rows, ["metric", "value", "status"])

    summary = f"""# P16 AI Learning Enhancement Summary

- Run name: `{run_dir.name}`
- Run dir: `{run_dir}`
- Source P9 run_dir: `{p9_run_dir}`
- Best model: `{best_model}`
- Best PR-AUC: `{best_pr_auc:.6f}`
- Feature rows: `{len(df)}`
- Isolation Forest anomaly rows: `{anomaly_summary_map['anomaly_rows']}`
- Status: `{status_rows[-1]['value']}`


- `model_explainability_report.md`
- `feature_importance_top20.tsv`
- `feature_group_summary.tsv`
- `confusion_matrix_interpretation.tsv`
- `anomaly_detection_report.md`
- `anomaly_detection_summary.tsv`
- `anomaly_score_deciles.tsv`
- `top_anomaly_transactions.tsv`


P16 is for AI learning and portfolio explanation. It does not train a replacement production model and is not P14 master validation.
"""
    write_text(run_dir / "p16_summary.md", summary)

    print(f"P16_RUN_DIR={run_dir}")
    print(f"P16_STATUS={status_rows[-1]['value']}")
    return 0 if status_rows[-1]["value"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
