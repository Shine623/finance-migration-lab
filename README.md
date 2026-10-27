# 企业财务系统实施与数据迁移

Oracle → MySQL 异构迁移的完整演练：需求调研、环境部署、数据迁移、三级校验、割接验收。

## 背景

财务系统更换数据库是高风险操作——停机窗口通常只有 4 小时，一旦数据不一致就要回滚。

本项目模拟一个集团财务系统的迁移场景，完整走一遍实施流程，沉淀出可复用的脚本与文档模板。

> 与常见的「数据库迁移教程」的区别：本项目重点不在 SQL 语法，而在**实施流程**——需求怎么调研、方案怎么写、割接怎么组织、出问题怎么回滚。

## 技术栈

| 环节 | 工具 |
|---|---|
| 源库 | Oracle 19c XE |
| 目标库 | MySQL 8.0.35 |
| 虚拟化 | VMware Workstation 17 |
| 脚本 | Shell / Python |
| 文档 | Word / Visio / Excel |
| 校验 | Python + pandas |

## 项目结构

```
finance-migration-lab/
├── scripts/
│   ├── 01_precheck.sh          迁移前环境检查
│   ├── 02_export_oracle.sh     Oracle 导出
│   ├── 03_import_mysql.sh      MySQL 导入
│   ├── 04_verify.py            三级一致性校验
│   └── 05_cutover.sh           割接执行
├── sql/
│   ├── 01_schema.sql           目标库表结构
│   ├── 02_index.sql            索引（导入后建）
│   └── 03_rollback.sql         回滚脚本
├── config/
│   └── field_mapping.xlsx      字段映射表
├── docs/
│   ├── 需求规格说明书.md
│   ├── 实施方案.md
│   ├── 割接方案.md
│   └── 测试报告.md
└── samples/                    示例数据
```

## 实施流程

```
需求调研 → 方案设计 → 环境部署 → 预迁移 → 三级校验
                                            ↓
                        验收 ← 冒烟测试 ← 割接切换
                          ↓
                    观察期 7 天 → 回滚预案
```

## 关键设计

### 1. 三级一致性校验

| 级别 | 方法 | 能发现什么 | 耗时 |
|---|---|---|---|
| L1 | 总行数比对 | 漏导、重复导入 | 3 min |
| L2 | 关键字段 checksum | 字段错位、类型转换错误 | 8 min |
| L3 | 抽样 200 条逐字段核对 | 精度丢失、空值处理、编码问题 | 12 min |

**为什么分三级**：全量逐字段核对要 40 分钟，超出割接窗口预算。三级递进，能在 23 分钟内达到 99% 的把握。

### 2. 字段映射表

用 Excel 维护，逐字段确认：源字段、目标字段、类型、长度、精度、空值处理、默认值、转换规则。

这是迁移最容易出问题的地方，必须逐个字段过一遍。

### 3. 割接时间轴

| 时间 | 操作 | 耗时 |
|---|---|---|
| 00:00 | 停写，进维护页 | 5 min |
| 00:05 | 记录最终 binlog 位置 | 2 min |
| 00:07 | 增量追平 | 15 min |
| 00:22 | L1 校验 | 3 min |
| 00:25 | L2 校验 | 8 min |
| 00:33 | L3 校验 | 12 min |
| 00:45 | 切换应用连接 | 10 min |
| 00:55 | 冒烟测试 | 20 min |
| 01:15 | 开放访问 | - |

**实际演练 186 分钟**，比计划 240 分钟快 22%。

## 快速开始

### 1. 环境检查

```bash
chmod +x scripts/*.sh
./scripts/01_precheck.sh
```

检查项：Oracle/MySQL 连通性、磁盘空间、binlog 配置、字符集、时区。

### 2. 导出 Oracle

```bash
./scripts/02_export_oracle.sh
```

### 3. 导入 MySQL

```bash
./scripts/03_import_mysql.sh
```

### 4. 一致性校验

```bash
python3 scripts/04_verify.py --level all
```

### 5. 割接演练

```bash
./scripts/05_cutover.sh --dry-run    # 先演练
./scripts/05_cutover.sh              # 正式执行
```

## 迁移中发现的问题

| # | 问题 | 表现 | 解决 |
|---|---|---|---|
| 1 | 金额精度丢失 | `NUMBER(18,4)` → `DECIMAL(18,2)` 截断小数 | 改 `DECIMAL(18,4)` |
| 2 | 空串 vs NULL | Oracle 把 `''` 当 NULL，MySQL 区分 | 导出时 `''` 转 NULL |
| 3 | 日期时区偏移 | Oracle DATE 无时区 | 统一存 UTC |
| 4 | 中文乱码 | 导出 GBK，MySQL utf8mb4 | 设 `NLS_LANG=AL32UTF8` |
| 5 | 自增主键冲突 | Oracle 序列 vs MySQL AUTO_INCREMENT | 导入后重置 |
| 6 | 导入极慢 | 先建索引再导入 | 导入前禁索引，后重建 |

## 踩过的坑

1. **主从延迟飙到几百秒**
   一个大事务 50 万行 INSERT，主库 3 秒，从库单线程回放要几分钟。
   解决：分批导入（每批 5000 行）+ `slave_parallel_workers=4`。

2. **binlog 格式选错导致主从不一致**
   `STATEMENT` 格式遇到 `NOW()`、`RAND()` 时主从数据不同。
   解决：改 `ROW` 格式。代价是 binlog 体积约 3 倍。

3. **checksum 校验对不上**
   Oracle 导出列顺序和 MySQL 建表顺序不同。
   解决：校验脚本显式指定列顺序，不依赖 `SELECT *`。

4. **expdp 中文表名报错**
   `NLS_LANG` 没设对，中文表名变 `????`。
   解决：`export NLS_LANG=AMERICAN_AMERICA.AL32UTF8`。

5. **割接窗口内校验跑太久**
   全量 checksum 40 分钟，超预算。
   解决：三级校验，压到 23 分钟。

6. **回滚脚本没测过**
   第一次演练时以为回滚就是改回连接串，实际还要处理双写期间的新数据。
   解决：切换后 24 小时保持双写（Oracle 主、MySQL 从），回滚时补数据。

## 文档

- [需求规格说明书](docs/需求规格说明书.md)
- [割接方案](docs/割接方案.md)
- [测试报告](docs/测试报告.md)

## License

MIT
