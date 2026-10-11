-- ============================================================================
-- SCRIPT 02: DDL de Esquema para el Sistema Transaccional Bancario
-- Esquema: BANK_USER | Tablas ACID, Constraints, Auditoría e Invariantes
-- ============================================================================

SET SQLBLANKLINES ON;
SET ECHO OFF;
SET FEEDBACK ON;

-- Limpieza si existen previamente
BEGIN
    FOR t IN (SELECT table_name FROM user_tables WHERE table_name IN (
        'ACCOUNT_BALANCE_SNAPSHOT',
        'SYSTEM_AUDIT_LOG',
        'PENDING_SETTLEMENT_QUEUE',
        'TRANSACTIONS_LOG',
        'ACCOUNTS'
    )) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
    END LOOP;
END;
/

-- ----------------------------------------------------------------------------
-- 1. TABLA: ACCOUNTS (Cuentas Bancarias con Control de Concurrencia e Invariantes)
-- ----------------------------------------------------------------------------
CREATE TABLE ACCOUNTS (
    account_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_number   VARCHAR2(34) NOT NULL,
    holder_name      VARCHAR2(100) NOT NULL,
    holder_email     VARCHAR2(150) NOT NULL,
    balance          NUMBER(18, 2) DEFAULT 0.00 NOT NULL,
    currency         VARCHAR2(3)   DEFAULT 'USD' NOT NULL,
    status           VARCHAR2(20)  DEFAULT 'ACTIVE' NOT NULL,
    version_id       NUMBER(12)    DEFAULT 1 NOT NULL, -- Optimistic Concurrency Control
    created_at       TIMESTAMP(6)  DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at       TIMESTAMP(6)  DEFAULT SYSTIMESTAMP NOT NULL,
    
    -- Invariante ACID de integridad de dominio: No se permite saldo negativo
    CONSTRAINT chk_acc_balance_non_negative CHECK (balance >= 0),
    CONSTRAINT chk_acc_status CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    CONSTRAINT uq_acc_account_number UNIQUE (account_number)
);

-- ----------------------------------------------------------------------------
-- 2. TABLA: TRANSACTIONS_LOG (Libro Mayor / Histórico de Transacciones)
-- ----------------------------------------------------------------------------
CREATE TABLE TRANSACTIONS_LOG (
    transaction_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_account_id  NUMBER NOT NULL,
    dest_account_id    NUMBER NOT NULL,
    amount             NUMBER(18, 2) NOT NULL,
    tx_type            VARCHAR2(20) NOT NULL,
    status             VARCHAR2(20) NOT NULL,
    lock_strategy      VARCHAR2(30) NOT NULL,
    execution_time_ms  NUMBER(10, 3),
    error_message      VARCHAR2(500),
    created_at         TIMESTAMP(6) DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT fk_tx_src_acc FOREIGN KEY (source_account_id) REFERENCES ACCOUNTS(account_id),
    CONSTRAINT fk_tx_dst_acc FOREIGN KEY (dest_account_id) REFERENCES ACCOUNTS(account_id),
    CONSTRAINT chk_tx_amount_positive CHECK (amount > 0),
    CONSTRAINT chk_tx_status CHECK (status IN ('COMMITTED', 'FAILED', 'ROLLED_BACK', 'RETRIED'))
);

-- ----------------------------------------------------------------------------
-- 3. TABLA: PENDING_SETTLEMENT_QUEUE (Cola de liquidación masiva para SKIP LOCKED)
-- ----------------------------------------------------------------------------
CREATE TABLE PENDING_SETTLEMENT_QUEUE (
    queue_id           NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id           VARCHAR2(50),
    source_account_id  NUMBER NOT NULL,
    dest_account_id    NUMBER NOT NULL,
    amount             NUMBER(18, 2) NOT NULL,
    status             VARCHAR2(20) DEFAULT 'PENDING' NOT NULL,
    worker_id          VARCHAR2(50),
    locked_at          TIMESTAMP(6),
    processed_at       TIMESTAMP(6),
    created_at         TIMESTAMP(6) DEFAULT SYSTIMESTAMP NOT NULL,

    CONSTRAINT chk_queue_status CHECK (status IN ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED'))
);

-- ----------------------------------------------------------------------------
-- 4. TABLA: SYSTEM_AUDIT_LOG (Auditoría Persistente vía Transacción Autónoma)
-- No se revierte con ROLLBACK de la transacción principal
-- ----------------------------------------------------------------------------
CREATE TABLE SYSTEM_AUDIT_LOG (
    audit_id           NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_type         VARCHAR2(50) NOT NULL,
    severity           VARCHAR2(10) NOT NULL,
    account_a          NUMBER,
    account_b          NUMBER,
    amount             NUMBER(18, 2),
    detail             VARCHAR2(1000),
    ora_err_code       NUMBER,
    ora_err_msg        VARCHAR2(500),
    session_user_name  VARCHAR2(128) DEFAULT USER,
    created_at         TIMESTAMP(6) DEFAULT SYSTIMESTAMP NOT NULL
);

-- ----------------------------------------------------------------------------
-- 5. TABLA: ACCOUNT_BALANCE_SNAPSHOT (Resumen agregado mantenido por Trigger)
-- ----------------------------------------------------------------------------
CREATE TABLE ACCOUNT_BALANCE_SNAPSHOT (
    snapshot_date      DATE PRIMARY KEY,
    total_accounts     NUMBER(10) NOT NULL,
    total_liquidity    NUMBER(22, 2) NOT NULL,
    last_updated_at    TIMESTAMP(6) DEFAULT SYSTIMESTAMP NOT NULL
);

PROMPT [OK] Tablas de esquema DDL bancario creadas exitosamente.
