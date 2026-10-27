-- ============================================================
-- 回滚脚本
--
-- 触发条件（满足任一即回滚）：
--   - L1/L2/L3 任一校验失败，30 分钟内无法定位
--   - 冒烟测试任一用例失败，30 分钟内无法修复
--   - 时间超过 04:00 仍未完成切换
--
-- 注意：如果切换后已有新数据写入 MySQL，回滚时要处理这些数据。
--       应对：切换后 24 小时保持双写（Oracle 主、MySQL 从）。
-- ============================================================

-- 说明：这个脚本只处理数据库侧。
-- 应用侧的回滚需要改连接串并重启，见 05_cutover.sh 的说明。

USE finance;

-- ------------------------------------------------------------
-- 1. 检查切换后是否有新数据
-- ------------------------------------------------------------
-- 记录切换时刻（实际使用时替换成真实时间）
SET @cutover_time = '2025-06-15 01:15:00';

SELECT '=== 切换后的新增数据量 ===' AS info;

SELECT 'VOUCHER' AS table_name, COUNT(*) AS new_rows
FROM VOUCHER
WHERE CREATED_AT > @cutover_time
UNION ALL
SELECT 'BALANCE', COUNT(*)
FROM BALANCE
WHERE CREATED_AT > @cutover_time
UNION ALL
SELECT 'PARTNER', COUNT(*)
FROM PARTNER
WHERE CREATED_AT > @cutover_time;

-- ------------------------------------------------------------
-- 2. 导出新数据（供人工补回 Oracle）
-- ------------------------------------------------------------
-- 如果双写已开启，这部分数据在 Oracle 里也有，不需要补
-- 如果没开双写，需要把下面的查询结果导出成 CSV，人工补录

SELECT '=== 需要补回 Oracle 的凭证 ===' AS info;

SELECT VOUCHER_NO, VOUCHER_DATE, SUBJECT_CODE, AMOUNT, DEBIT_CREDIT,
       SUMMARY, DEPT_CODE, PERIOD
FROM VOUCHER
WHERE CREATED_AT > @cutover_time
ORDER BY VOUCHER_DATE;

-- ------------------------------------------------------------
-- 3. 回滚检查清单
-- ------------------------------------------------------------
/*
回滚操作清单（手工执行，不要盲目跑脚本）：

[ ] 1. 停止应用
        systemctl stop finance-app

[ ] 2. 改回 Oracle 连接串
        sed -i 's|jdbc:mysql.*|jdbc:oracle:thin:@oracle:1521:XE|' /opt/app/config.yml

[ ] 3. 启动应用
        systemctl start finance-app

[ ] 4. 关闭维护页
        curl -X POST http://app:8080/admin/maintenance -d enable=false

[ ] 5. 检查切换后新增数据
        如果双写已开启：无需处理
        如果未开双写：用上面的查询导出，人工补录到 Oracle

[ ] 6. 通知业务方

[ ] 7. 保留 MySQL 环境（不要删），用于排查

[ ] 8. 收集日志，24 小时内出复盘报告
*/
