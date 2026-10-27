#!/bin/bash
# ============================================================
# 割接执行脚本
#
# 用法:
#   ./05_cutover.sh --dry-run   演练，只打印不执行
#   ./05_cutover.sh             正式执行
#
# 每一步都有确认提示，避免误操作
# ============================================================

set -uo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-root123456}"
MYSQL_DB="${MYSQL_DB:-finance}"
APP_HOST="${APP_HOST:-127.0.0.1:8080}"
APP_CONF="${APP_CONF:-/opt/app/config.yml}"

LOG="cutover_$(date +%Y%m%d_%H%M%S).log"
START_TS=$(date +%s)

log() { echo "$(date '+%H:%M:%S')  $*" | tee -a "$LOG"; }
step() { echo "" | tee -a "$LOG"; echo "=== $* ===" | tee -a "$LOG"; }

elapsed() {
    local now=$(date +%s)
    echo $(( (now - START_TS) / 60 ))
}

confirm() {
    if [ "$DRY_RUN" = "1" ]; then
        log "  [dry-run] 跳过确认: $1"
        return 0
    fi
    read -rp "  确认「$1」已完成？(yes/no) " ans
    if [ "$ans" != "yes" ]; then
        log "  [!] 用户中止"
        exit 1
    fi
}

echo "============================================================"
echo "  财务系统割接"
echo "============================================================"
if [ "$DRY_RUN" = "1" ]; then
    echo "  模式: 演练（不会实际执行）"
else
    echo "  模式: 正式执行"
fi
echo "  日志: $LOG"
echo "============================================================"

# ---------- 步骤 1: 停止写入 ----------
step "步骤 1/9 停止写入（T+0min）"
log "  目标: 应用切到维护页，停止数据库写入"

if [ "$DRY_RUN" = "1" ]; then
    log "  [dry] curl -X POST http://${APP_HOST}/admin/maintenance -d enable=true"
else
    curl -sS -X POST "http://${APP_HOST}/admin/maintenance" -d "enable=true" \
        && log "  应用已切到维护页" || log "  [!] 切换失败"
fi

confirm "应用已停止写入"
log "  耗时: $(elapsed) 分钟"

# ---------- 步骤 2: 记录 binlog 位置 ----------
step "步骤 2/9 记录最终 binlog 位置（T+5min）"

if [ "$DRY_RUN" = "1" ]; then
    log "  [dry] mysql -e 'FLUSH LOGS; SHOW MASTER STATUS'"
else
    mysql -h"$MYSQL_HOST" -u"$MYSQL_USER" -p"$MYSQL_PASS" \
        -e "FLUSH LOGS; SHOW MASTER STATUS\G" | tee -a "$LOG"
fi

confirm "binlog 位置已记录"
log "  耗时: $(elapsed) 分钟"

# ---------- 步骤 3: 增量追平 ----------
step "步骤 3/9 增量追平（T+7min）"
log "  目标: 把预迁移之后的增量数据应用到目标库"
log "  预计 15 分钟"

if [ "$DRY_RUN" = "1" ]; then
    log "  [dry] mysqlbinlog --start-position=... | mysql"
else
    log "  [TODO] 需要手动指定 binlog 文件与位置"
    log "         命令: mysqlbinlog --start-position=<预迁移pos> --stop-position=<最终pos> \\"
    log "               mysql-bin.0000XX | mysql -h target -u root -p finance"
fi

confirm "增量追平完成"
log "  耗时: $(elapsed) 分钟"

# ---------- 步骤 4-6: 三级校验 ----------
step "步骤 4/9 L1 行数校验（T+22min）"
if [ "$DRY_RUN" = "1" ]; then
    log "  [dry] python3 scripts/04_verify.py --level L1"
else
    python3 scripts/04_verify.py --level L1 || {
        log "  [!] L1 校验失败，立即停止"
        log "  执行回滚: ./05_cutover.sh --rollback"
        exit 1
    }
fi
confirm "L1 校验通过"
log "  耗时: $(elapsed) 分钟"

step "步骤 5/9 L2 checksum 校验（T+25min）"
if [ "$DRY_RUN" = "1" ]; then
    log "  [dry] python3 scripts/04_verify.py --level L2"
else
    python3 scripts/04_verify.py --level L2 || {
        log "  [!] L2 校验失败，立即停止"
        exit 1
    }
fi
confirm "L2 校验通过"
log "  耗时: $(elapsed) 分钟"

step "步骤 6/9 L3 抽样校验（T+33min）"
if [ "$DRY_RUN" = "1" ]; then
    log "  [dry] python3 scripts/04_verify.py --level all"
else
    python3 scripts/04_verify.py --level all || {
        log "  [!] L3 校验失败，立即停止"
        exit 1
    }
fi
confirm "L3 校验通过"
log "  耗时: $(elapsed) 分钟"

# ---------- 步骤 7: 切换应用 ----------
step "步骤 7/9 切换应用连接（T+45min）"

if [ "$DRY_RUN" = "1" ]; then
    log "  [dry] sed -i 's|jdbc:oracle|jdbc:mysql|' $APP_CONF"
    log "  [dry] systemctl restart finance-app"
else
    if [ -f "$APP_CONF" ]; then
        cp "$APP_CONF" "${APP_CONF}.bak.$(date +%s)"
        sed -i 's|jdbc:oracle[^"'"'"' ]*|jdbc:mysql://'"$MYSQL_HOST"':3306/'"$MYSQL_DB"'|' "$APP_CONF"
        log "  配置已修改（原文件已备份）"
        systemctl restart finance-app 2>/dev/null || log "  [WARN] 重启服务失败，请手动处理"
    else
        log "  [!] 配置文件不存在: $APP_CONF"
    fi
fi

confirm "应用已切换并启动"
log "  耗时: $(elapsed) 分钟"

# ---------- 步骤 8: 冒烟测试 ----------
step "步骤 8/9 冒烟测试（T+55min）"
log "  请手工验证以下用例："
log "    [ ] 登录"
log "    [ ] 按日期范围查询凭证"
log "    [ ] 录入一张新凭证"
log "    [ ] 打开资产负债表"
log "    [ ] 查询某科目余额"

confirm "冒烟测试全部通过"
log "  耗时: $(elapsed) 分钟"

# ---------- 步骤 9: 开放访问 ----------
step "步骤 9/9 开放访问（T+75min）"

if [ "$DRY_RUN" = "1" ]; then
    log "  [dry] curl -X POST http://${APP_HOST}/admin/maintenance -d enable=false"
else
    curl -sS -X POST "http://${APP_HOST}/admin/maintenance" -d "enable=false" \
        && log "  已开放访问" || log "  [!] 开放失败"
fi

log "  耗时: $(elapsed) 分钟"

# ---------- 完成 ----------
echo ""
echo "============================================================"
echo "  割接完成"
echo "============================================================"
log "  总耗时: $(elapsed) 分钟"
log "  日志: $LOG"
echo ""
log "  接下来："
log "    1. 保持双写开启 24 小时"
log "    2. 进入观察期（7 天）"
log "    3. T+7 删除 Oracle 环境"
echo ""

if [ "$DRY_RUN" != "1" ]; then
    log "  [!] 如需回滚: ./05_cutover.sh --rollback"
fi
