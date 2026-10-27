-- ============================================================
-- 目标库表结构（MySQL 8.0）
-- Oracle 19c → MySQL 8.0 迁移
--
-- 关键设计：
--   1. 金额统一 DECIMAL(18,4)，与 Oracle NUMBER(18,4) 对齐
--   2. 日期统一 DATETIME，存 UTC
--   3. 字符集 utf8mb4
--   4. Oracle 空串当 NULL，这里统一 NULL
-- ============================================================

CREATE DATABASE IF NOT EXISTS finance
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_general_ci;

USE finance;

-- ------------------------------------------------------------
-- 科目表
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ACCOUNT_SUBJECT (
    ID            BIGINT       NOT NULL AUTO_INCREMENT,
    SUBJECT_CODE  VARCHAR(32)  NOT NULL COMMENT '科目编码',
    SUBJECT_NAME  VARCHAR(128) NOT NULL COMMENT '科目名称',
    SUBJECT_TYPE  VARCHAR(16)  DEFAULT NULL COMMENT 'ASSET/LIABILITY/EQUITY/COST/PROFIT',
    PARENT_CODE   VARCHAR(32)  DEFAULT NULL COMMENT '上级科目',
    LEVEL_NO      TINYINT      DEFAULT 1,
    IS_ENABLED    TINYINT(1)   DEFAULT 1,
    CREATED_AT    DATETIME     DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (ID),
    UNIQUE KEY uk_subject_code (SUBJECT_CODE)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='会计科目';

-- ------------------------------------------------------------
-- 凭证表（最大的表，约 185 万行）
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS VOUCHER (
    ID            BIGINT        NOT NULL AUTO_INCREMENT,
    VOUCHER_NO    VARCHAR(64)   NOT NULL,
    VOUCHER_DATE  DATETIME      NOT NULL COMMENT 'UTC 时间',
    SUBJECT_CODE  VARCHAR(32)   NOT NULL,
    AMOUNT        DECIMAL(18,4) NOT NULL DEFAULT 0 COMMENT '精度必须与 Oracle 一致',
    DEBIT_CREDIT  CHAR(1)       DEFAULT NULL COMMENT 'D借 C贷',
    SUMMARY       VARCHAR(512)  DEFAULT NULL,
    DEPT_CODE     VARCHAR(32)   DEFAULT NULL,
    PERIOD        VARCHAR(8)    DEFAULT NULL COMMENT 'YYYYMM',
    CREATED_AT    DATETIME      DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (ID),
    UNIQUE KEY uk_voucher_no (VOUCHER_NO)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='会计凭证';

-- ------------------------------------------------------------
-- 余额表
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS BALANCE (
    ID             BIGINT        NOT NULL AUTO_INCREMENT,
    SUBJECT_CODE   VARCHAR(32)   NOT NULL,
    PERIOD         VARCHAR(8)    NOT NULL,
    BEGIN_BALANCE  DECIMAL(18,4) NOT NULL DEFAULT 0,
    DEBIT_AMOUNT   DECIMAL(18,4) NOT NULL DEFAULT 0,
    CREDIT_AMOUNT  DECIMAL(18,4) NOT NULL DEFAULT 0,
    END_BALANCE    DECIMAL(18,4) NOT NULL DEFAULT 0,
    CREATED_AT     DATETIME      DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (ID),
    UNIQUE KEY uk_subject_period (SUBJECT_CODE, PERIOD)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='科目余额';

-- ------------------------------------------------------------
-- 往来单位
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS PARTNER (
    ID            BIGINT       NOT NULL AUTO_INCREMENT,
    PARTNER_CODE  VARCHAR(32)  NOT NULL,
    PARTNER_NAME  VARCHAR(256) NOT NULL,
    TAX_NO        VARCHAR(64)  DEFAULT NULL,
    CONTACT       VARCHAR(64)  DEFAULT NULL,
    PHONE         VARCHAR(32)  DEFAULT NULL,
    ADDRESS       VARCHAR(512) DEFAULT NULL,
    CREATED_AT    DATETIME     DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (ID),
    UNIQUE KEY uk_partner_code (PARTNER_CODE)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='往来单位';

-- ------------------------------------------------------------
-- 部门
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DEPARTMENT (
    ID            BIGINT       NOT NULL AUTO_INCREMENT,
    DEPT_CODE     VARCHAR(32)  NOT NULL,
    DEPT_NAME     VARCHAR(128) NOT NULL,
    PARENT_CODE   VARCHAR(32)  DEFAULT NULL,
    LEVEL_NO      TINYINT      DEFAULT 1,
    CREATED_AT    DATETIME     DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (ID),
    UNIQUE KEY uk_dept_code (DEPT_CODE)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='部门';

-- ------------------------------------------------------------
-- 币种
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CURRENCY (
    ID             BIGINT        NOT NULL AUTO_INCREMENT,
    CURRENCY_CODE  VARCHAR(8)    NOT NULL,
    CURRENCY_NAME  VARCHAR(64)   NOT NULL,
    RATE           DECIMAL(18,8) NOT NULL DEFAULT 1 COMMENT '汇率精度比金额高',
    IS_BASE        TINYINT(1)    DEFAULT 0,
    CREATED_AT     DATETIME      DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (ID),
    UNIQUE KEY uk_currency_code (CURRENCY_CODE)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='币种';
