#!/bin/bash
# ============================================================
# Oracle 数据导出
#
# 关键：NLS_LANG 必须设 UTF8，否则中文表名/数据乱码
# ============================================================

set -euo pipefail

ORACLE_USER="${ORACLE_USER:-system}"
ORACLE_PASS="${ORACLE_PASS:-oracle123}"
ORACLE_SID="${ORACLE_SID:-XE}"
EXPORT_DIR="${EXPORT_DIR:-./export}"
TS=$(date +%Y%m%d_%H%M%S)
DUMP="migration_${TS}"

# 中文乱码的根源
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8

mkdir -p "$EXPORT_DIR"

echo "============================================================"
echo "  Oracle 数据导出"
echo "============================================================"
echo "  源库: ${ORACLE_USER}@${ORACLE_SID}"
echo "  输出: ${EXPORT_DIR}"
echo "  NLS_LANG: ${NLS_LANG}"
echo "============================================================"
echo

TABLES=("ACCOUNT_SUBJECT" "VOUCHER" "BALANCE" "PARTNER" "DEPARTMENT" "CURRENCY")

# ---------- 1. 导出 dmp（用于完整备份） ----------
echo "[1/3] 导出 dmp 文件"
TABLE_LIST=$(IFS=,; echo "${TABLES[*]}")

if command -v expdp >/dev/null 2>&1; then
    expdp "${ORACLE_USER}/${ORACLE_PASS}@${ORACLE_SID}" \
        directory=DATA_PUMP_DIR \
        dumpfile="${DUMP}.dmp" \
        logfile="${DUMP}.log" \
        tables="${TABLE_LIST}" \
        content=ALL \
        compression=ALL \
        2>&1 | tail -20
    echo "  [OK] dmp 导出完成"
else
    echo "  [WARN] 未安装 expdp，跳过"
fi
echo

# ---------- 2. 导出 CSV（用于校验） ----------
echo "[2/3] 导出 CSV（供一致性校验使用）"

for t in "${TABLES[@]}"; do
    echo -n "  - $t ... "

    # 用 SET MARKUP CSV 保证正确的 CSV 转义
    sqlplus -S "${ORACLE_USER}/${ORACLE_PASS}@${ORACLE_SID}" <<EOF > "${EXPORT_DIR}/${t}.csv"
SET PAGESIZE 0
SET FEEDBACK OFF
SET LINESIZE 32767
SET TRIMSPOOL ON
SET MARKUP CSV ON QUOTE ON
SELECT * FROM ${t};
EXIT
EOF

    lines=$(wc -l < "${EXPORT_DIR}/${t}.csv")
    echo "${lines} 行"
done
echo

# ---------- 3. 记录导出元信息 ----------
echo "[3/3] 记录导出元信息"

cat > "${EXPORT_DIR}/_export_info.txt" <<EOF
导出时间: $(date '+%Y-%m-%d %H:%M:%S')
源库: ${ORACLE_SID}
NLS_LANG: ${NLS_LANG}
表清单: ${TABLE_LIST}
dmp 文件: ${DUMP}.dmp
EOF

echo "  [OK] 元信息: ${EXPORT_DIR}/_export_info.txt"
echo

echo "============================================================"
echo "  导出完成"
echo "============================================================"
echo
echo "  下一步："
echo "    ./scripts/03_import_mysql.sh"
