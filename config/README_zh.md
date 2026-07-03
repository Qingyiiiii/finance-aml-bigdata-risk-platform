# config 配置说明

Language: [中文](README_zh.md) | [English](README_en.md)

`config/` 保存本地和集群运行模板。配置文件只记录路径、命名空间和处理参数，不保存本地敏感值。

| 文件 | 作用 |
| --- | --- |
| `finance_bigdata.local.yaml` | 本地 P0-P4、P9、P14、P17 等阶段的默认数据路径和处理参数 |
| `finance_bigdata.cluster.yaml` | 集群侧项目路径、HDFS 路径、命名空间和发布参数 |

检查配置时关注：

- 默认数据集是否仍为 `HI-Small`。
- `raw_dir` 是否使用仓库相对目录 `datas`。
- 本地输出是否写入 `data/finance_bigdata`。
- 集群命名空间是否保持 `finance_bigdata`。
- V2 脚本是否单独写入 `data/finance_bigdata_v2`，不得覆盖 V1 输出。

