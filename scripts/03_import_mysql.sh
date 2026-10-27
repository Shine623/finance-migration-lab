#!/bin/bash
# ============================================================
# 导入数据到 MySQL
#
# 优化点：
#   1. 导入前禁用索引（大表快 5-10 倍）
#   2. 分批提交（避免主从延迟）
#   3. 导入后重建索引并 ANALYZE
# ============================================================

set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-root123456}"
MYSQL_DB="${MYSQL_DB:-finance}"
EXPORT_DIR="${EXPORT_DIR:-./export}"

BATCH_SIZE="${BATCH_SIZE:-5000}"

echo "============================================================"
echo "  导入数据到 MySQL"
echo "============================================================"
echo "  目标: ${MYSQL_USER}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
echo "  批次: ${BATCH_SIZE} 行/批"
echo "============================================================"
echo

mysql_cmd() {
    mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASS" \
          --local-infile=1 "$@"
}

# ---------- 1. 建库建表 ----------
echo "[1/4] 建库建表"
if [ -f "sql/01_schema.sql" ]; then
    mysql_cmd < sql/01_schema.sql
    echo "  [OK] 表结构已创建"
else
    echo "  [!] 找不到 sql/01_schema.sql"
    exit 1
fi
echo

# ---------- 2. 禁用索引 ----------
echo "[2/4] 禁用非唯一索引（提升导入速度）"

mysql_cmd "$MYSQL_DB" <<'EOF'
SET SESSION sql_log_bin = 0;

-- 记录要禁用的索引
DROP TABLE IF EXISTS _idx_backup;
CREATE TABLE _idx_backup AS
SELECT table_name, index_name, GROUP_CONCAT(column_name ORDER BY seq_in_index) AS cols
FROM information_schema.statistics
WHERE table_schema = DATABASE()
  AND index_name != 'PRIMARY'
  AND non_unique = 1
GROUP BY table_name, index_name;

SELECT CONCAT('待禁用索引: ', COUNT(*), ' 个') AS info FROM _idx_backup;
EOF

# 生成并执行 ALTER TABLE ... DISABLE KEYS
mysql_cmd "$MYSQL_DB" -N -e \
    "SELECT CONCAT('ALTER TABLE ', table_name, ' DISABLE KEYS;') FROM _idx_backup" \
    | mysql_cmd "$MYSQL_DB" || true

echo "  [OK] 索引已禁用"
echo

# ---------- 3. 导入 CSV ----------
echo "[3/4] 导入数据（分批 ${BATCH_SIZE} 行）"

mysql_cmd "$MYSQL_DB" <<EOF
SET autocommit = 0;
SET unique_checks = 0;
SET foreign_key_checks = 0;
EOF

for csv in "${EXPORT_DIR}"/*.csv; do
    [ -f "$csv" ] || continue
    table=$(basename "$csv" .csv)

    if [ "$table" = "_export_info" ]; then
        continue
    fi

    total=$(wc -l < "$csv")
    echo -n "  - ${table}: ${total} 行 ... "

    # LOAD DATA 一次性导入（MySQL 内部会处理，比分批 INSERT 快得多）
    # 但为了控制主从延迟，这里按批次切分
    start=2   # 跳过表头
    imported=0

    while [ "$start" -le "$total" ]; do
        end=$((start + BATCH_SIZE - 1))
        if [ "$end" -gt "$total" ]; then
            end=$total
        fi

        # 用 sed 截取一段，通过管道喂给 LOAD DATA
        sed -n "${start},${end}p" "$csv" | mysql_cmd "$MYSQL_DB" <<EOF
SET autocommit = 0;
SET unique_checks = 0;
LOAD DATA LOCAL INFILE '/dev/stdin'
INTO TABLE ${table}
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;
COMMIT;
EOF

        imported=$((imported + end - start + 1))
        start=$((end + 1))

        # 让主从有机会追上
        sleep 0.1
    done

    echo "导入 ${imported} 行"
done

mysql_cmd "$MYSQL_DB" <<'EOF'
SET unique_checks = 1;
SET foreign_key_checks = 1;
COMMIT;
EOF

echo

# ---------- 4. 重建索引 ----------
echo "[4/4] 重建索引并分析表"

mysql_cmd "$MYSQL_DB" -N -e \
    "SELECT CONCAT('ALTER TABLE ', table_name, ' ENABLE KEYS;') FROM _idx_backup" \
    | mysql_cmd "$MYSQL_DB" || true

mysql_cmd "$MYSQL_DB" -e \
    "ANALYZE TABLE ACCOUNT_SUBJECT, VOUCHER, BALANCE, PARTNER, DEPARTMENT, CURRENCY;"

mysql_cmd "$MYSQL_DB" -e "DROP TABLE IF EXISTS _idx_backup;"

echo "  [OK] 索引已重建"
echo

echo "============================================================"
echo "  导入完成"
echo "============================================================"
echo
echo "  下一步："
echo "    python3 scripts/04_verify.py --level all"
