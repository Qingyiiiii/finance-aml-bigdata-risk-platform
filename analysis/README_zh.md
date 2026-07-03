# analysis 说明

Language: [中文](README_zh.md) | [English](README_en.md)

`analysis/` 是金融 AML 项目的分析、特征、建模和解释性实验目录。它读取离线数仓阶段生成的小型证据，产出可复盘的 EDA、特征表、baseline 指标、模型解释和异常检测报告。

## 文件职责

| 文件 | 阶段 | 职责 | 主要输出 |
| --- | --- | --- | --- |
| `p9_utils.py` | 公共工具 | 项目路径、run_dir、TSV/JSON/文本写入、指标读取 | helper functions |
| `p9_label_eda.py` | P9 EDA | 标签分布、金额分箱、支付方式和币种标签率 | `label_distribution.tsv`、`eda_metrics.tsv`、`eda_summary.md` |
| `p9_feature_build.py` | P9 特征工程 | 构建非泄漏建模表，固定正负样本抽样和 train/test split | `feature_dataset.parquet`、`feature_schema.md` |
| `p9_baseline_model.py` | P9 baseline | 训练 Logistic Regression 和 Random Forest，输出不平衡任务指标 | `baseline_metrics.tsv`、`model_card.md`、`feature_importance.tsv` |
| `p16_model_explainability.py` | P16 AI 增强 | 解释 P9 baseline，并补充 Isolation Forest 异常检测实验 | `model_explainability_report.md`、`anomaly_detection_report.md` |

## 执行顺序

```text
p9_label_eda.py
  -> p9_feature_build.py
  -> p9_baseline_model.py
  -> p16_model_explainability.py
```

`p9_utils.py` 被上述脚本复用，不单独代表业务阶段。

## 设计边界

- P9/P16 是作品集级分析和实验，不是生产 AML 模型。
- `is_laundering` 只作为合成数据标签使用。
- 特征工程明确排除标签衍生字段和未来信息。
- baseline 指标优先关注 precision、recall、F1、ROC-AUC 和 PR-AUC，不使用 accuracy 作为核心结论。
- P16 的解释性报告说明模型关注点，不构成因果证明或生产合规解释。
- Isolation Forest 只用于无监督异常检测学习，不替代 P9 监督 baseline。

## 输出位置

默认输出写入：

```text
data/finance_bigdata/runs/
```

公开仓库不保存运行后生成的大型数据、模型中间产物或本地敏感配置。需要复现时先准备 `datas/` 输入文件，再运行对应 `bin/` 编排脚本。

