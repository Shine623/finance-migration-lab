-- ============================================================
-- 索引创建脚本
--
-- 重要：索引要在数据导入之后建，否则每插一行都要更新索引，导入会慢 5-10 倍。
--       导入流程：建表（无索引）→ 导入 → 建索引 → ANALYZE
-- ============================================================

USE finance;

-- ------------------------------------------------------------
-- 凭证表索引（最重要的表）
-- ------------------------------------------------------------
-- 按日期查询（最常用）
CREATE INDEX idx_voucher_date ON VOUCHER (VOUCHER_DATE);

-- 按科目查询
CREATE INDEX idx_voucher_subject ON VOUCHER (SUBJECT_CODE);

-- 按期间查询（月度报表）
CREATE INDEX idx_voucher_period ON VOUCHER (PERIOD);

-- 组合索引：科目 + 期间（报表场景）
CREATE INDEX idx_voucher_subject_period ON VOUCHER (SUBJECT_CODE, PERIOD);

-- ------------------------------------------------------------
-- 余额表索引
-- ------------------------------------------------------------
-- 按期间查全部科目余额
CREATE INDEX idx_balance_period ON BALANCE (PERIOD);

-- ------------------------------------------------------------
-- 往来单位
-- ------------------------------------------------------------
CREATE INDEX idx_partner_tax ON PARTNER (TAX_NO);
CREATE INDEX idx_partner_name ON PARTNER (PARTNER_NAME(64));

-- ------------------------------------------------------------
-- 部门
-- ------------------------------------------------------------
CREATE INDEX idx_dept_parent ON DEPARTMENT (PARENT_CODE);

-- ------------------------------------------------------------
-- 科目
-- ------------------------------------------------------------
CREATE INDEX idx_subject_parent ON ACCOUNT_SUBJECT (PARENT_CODE);

-- ------------------------------------------------------------
-- 更新统计信息（让优化器选对执行计划）
-- ------------------------------------------------------------
ANALYZE TABLE ACCOUNT_SUBJECT, VOUCHER, BALANCE, PARTNER, DEPARTMENT, CURRENCY;
