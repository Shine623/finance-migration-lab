#!/bin/bash
# ============================================================
# 迁移前环境检查
#
# 检查项：
#   1. Oracle / MySQL 连通性
#   2. 磁盘空间
#   3. binlog 配置
#   4. 字符集与时区
#   5. 表结构与行数快照
# ============================================================

set -uo pipefail

ORACLE_HOST="${ORACLE_HOST:-127.0.0.1}"
ORACLE_PORT="${ORACLE_PORT:-1521}"
ORACLE_SID="${ORACLE_SID:-XE}"
ORACLE_USER="${ORACLE_USER:-system}"
ORACLE_PASS="${ORACLE_PASS:-oracle123}"

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-root123456}"
MYSQL_DB="${MYSQL_DB:-finance}"

PASS=0
FAIL=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
warn() { echo "  [WARN] $1"; }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "============================================================"
echo "  迁移前环境检查"
echo "============================================================"
echo

# ---------- 1. Oracle 连通性 ----------
echo "[1/6] Oracle 连通性"
if command -v sqlplus >/dev/null 2>&1; then
    if echo "SELECT 1 FROM DUAL;" | \
       sqlplus -S "${ORACLE_USER}/${ORACLE_PASS}@${ORACLE_HOST}:${ORACLE_PORT}/${ORACLE_SID}" \
       2>/dev/null | grep -q "1"; then
        ok "Oracle 可连接 (${ORACLE_HOST}:${ORACLE_PORT}/${ORACLE_SID})"
    else
        fail "Oracle 连接失败"
    fi
else
    warn "未安装 sqlplus，跳过 Oracle 检查"
fi
echo

# ---------- 2. MySQL 连通性 ----------
echo "[2/6] MySQL 连通性"
if mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASS" \
         -e "SELECT 1" >/dev/null 2>&1; then
    ok "MySQL 可连接 (${MYSQL_HOST}:${MYSQL_PORT})"

    # 字符集
    charset=$(mysql -h"$MYSQL_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASS" -N -e \
              "SELECT @@character_set_server")
    if [ "$charset" = "utf8mb4" ]; then
        ok "MySQL 字符集: utf8mb4"
    else
        fail "MySQL 字符集是 $charset，应为 utf8mb4"
    fi

    # 时区
    tz=$(mysql -h"$MYSQL_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASS" -N -e \
         "SELECT @@time_zone")
    if [ "$tz" = "+08:00" ] || [ "$tz" = "SYSTEM" ]; then
        ok "MySQL 时区: $tz"
    else
        warn "MySQL 时区是 $tz，建议设为 +08:00"
    fi
else
    fail "MySQL 连接失败"
fi
echo

# ---------- 3. binlog 配置 ----------
echo "[3/6] binlog 配置"
if mysql -h"$MYSQL_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT 1" >/dev/null 2>&1; then
    log_bin=$(mysql -h"$MYSQL_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASS" -N -e \
              "SELECT @@log_bin")
    binlog_format=$(mysql -h"$MYSQL_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASS" -N -e \
                    "SELECT @@binlog_format")

    if [ "$log_bin" = "1" ]; then
        ok "binlog 已开启"
    else
        fail "binlog 未开启，无法做增量追平"
    fi

    if [ "$binlog_format" = "ROW" ]; then
        ok "binlog_format = ROW"
    else
        fail "binlog_format = $binlog_format，必须改为 ROW（STATEMENT 会导致主从不一致）"
    fi
fi
echo

# ---------- 4. 磁盘空间 ----------
echo "[4/6] 磁盘空间"
avail=$(df -BG /var/lib/mysql 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
if [ -n "$avail" ]; then
    if [ "$avail" -ge 50 ]; then
        ok "MySQL 数据目录可用空间: ${avail}G"
    else
        fail "可用空间仅 ${avail}G，迁移 240 万行建议至少 50G"
    fi
else
    warn "无法获取磁盘空间"
fi
echo

# ---------- 5. 源库行数快照 ----------
echo "[5/6] 源库行数快照"
TABLES=("ACCOUNT_SUBJECT" "VOUCHER" "BALANCE" "PARTNER" "DEPARTMENT" "CURRENCY")
SNAPSHOT="rowcount_before_$(date +%Y%m%d_%H%M%S).txt"

if command -v sqlplus >/dev/null 2>&1; then
    {
        echo "# 迁移前行数快照 $(date)"
        for t in "${TABLES[@]}"; do
            cnt=$(echo "SELECT COUNT(*) FROM ${t};" | \
                  sqlplus -S "${ORACLE_USER}/${ORACLE_PASS}@${ORACLE_HOST}:${ORACLE_PORT}/${ORACLE_SID}" \
                  2>/dev/null | grep -E '^[0-9]+' | head -1)
            echo "${t} ${cnt:-N/A}"
        done
    } > "$SNAPSHOT"
    ok "快照已保存: $SNAPSHOT"
    cat "$SNAPSHOT" | sed 's/^/         /'
else
    warn "跳过（无 sqlplus）"
fi
echo

# ---------- 6. 目标库表结构 ----------
echo "[6/6] 目标库表结构"
if mysql -h"$MYSQL_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "USE $MYSQL_DB" 2>/dev/null; then
    for t in account_subject voucher balance partner department currency; do
        exists=$(mysql -h"$MYSQL_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASS" -N -e \
                 "SELECT COUNT(*) FROM information_schema.tables \
                  WHERE table_schema='$MYSQL_DB' AND table_name='$t'")
        if [ "$exists" = "1" ]; then
            ok "表 $t 已存在"
        else
            warn "表 $t 不存在，需要先执行 sql/01_schema.sql"
        fi
    done
else
    warn "数据库 $MYSQL_DB 不存在"
fi

echo
echo "============================================================"
echo "  检查结果：通过 $PASS 项，失败 $FAIL 项"
echo "============================================================"

if [ "$FAIL" -gt 0 ]; then
    echo
    echo "[!] 存在失败项，请先解决再继续迁移"
    exit 1
fi

echo
echo "[+] 环境检查通过，可以进入下一步"
