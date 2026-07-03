# config Configuration

Language: [中文](README_zh.md) | [English](README_en.md)

`config/` stores local and cluster runtime templates. Configuration files keep paths, namespaces and processing parameters only. They must not contain local sensitive values.

| File | Purpose |
| --- | --- |
| `finance_bigdata.local.yaml` | Default local data paths and processing parameters for P0-P4, P9, P14, P17 and related stages |
| `finance_bigdata.cluster.yaml` | Cluster-side project paths, HDFS paths, namespaces and release parameters |

Configuration review should confirm:

- The default dataset remains `HI-Small`.
- `raw_dir` uses the repository-relative `datas` directory.
- Local outputs are written under `data/finance_bigdata`.
- The cluster namespace remains `finance_bigdata`.
- V2 scripts write to `data/finance_bigdata_v2` and do not overwrite V1 outputs.

