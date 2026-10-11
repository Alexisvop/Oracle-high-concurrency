-- ============================================================================
-- SCRIPT 04: Especificación del Package PKG_BANK_CORE
-- Esquema: BANK_USER | API Transaccional Bancaria de Alta Concurrencia
-- ============================================================================

CREATE OR REPLACE PACKAGE PKG_BANK_CORE AS

    -- Excepciones de Dominio y Negocio
    e_insufficient_funds    EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_insufficient_funds, -20001);

    e_account_not_active    EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_account_not_active, -20002);

    e_optimistic_conflict   EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_optimistic_conflict, -20003);

    e_same_account_transfer EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_same_account_transfer, -20004);

    -- Excepciones de Motor Oracle
    e_deadlock_detected     EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_deadlock_detected, -00060);

    e_resource_busy         EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_resource_busy, -00054);

    -- Tipos de retorno
    TYPE t_tx_result IS RECORD (
        success           BOOLEAN,
        status_code       VARCHAR2(30),
        message           VARCHAR2(500),
        execution_time_ms NUMBER(10, 3),
        retry_count       NUMBER(5)
    );

    -- 1. Auditoría Autónoma (PRAGMA AUTONOMOUS_TRANSACTION)
    PROCEDURE log_audit(
        p_event_type      IN VARCHAR2,
        p_severity        IN VARCHAR2,
        p_account_a       IN NUMBER DEFAULT NULL,
        p_account_b       IN NUMBER DEFAULT NULL,
        p_amount          IN NUMBER DEFAULT NULL,
        p_detail          IN VARCHAR2 DEFAULT NULL,
        p_ora_err_code    IN NUMBER DEFAULT NULL,
        p_ora_err_msg     IN VARCHAR2 DEFAULT NULL
    );

    -- 2. Transferencia Pesimista con Prevención Matemática de Deadlocks (Orden de Lock)
    PROCEDURE transfer_pessimistic_ordered(
        p_source_id       IN NUMBER,
        p_dest_id         IN NUMBER,
        p_amount          IN NUMBER,
        p_lock_timeout_sec IN NUMBER DEFAULT 5,
        o_result          OUT t_tx_result
    );

    -- 3. Transferencia Pesimista Ingenua (Sin orden de adquisición - Simulación de Deadlock)
    PROCEDURE transfer_pessimistic_naive(
        p_source_id       IN NUMBER,
        p_dest_id         IN NUMBER,
        p_amount          IN NUMBER,
        p_artificial_delay_ms IN NUMBER DEFAULT 50,
        o_result          OUT t_tx_result
    );

    -- 4. Transferencia Optimista con Control de Versión (Version ID + Reintentos con Backoff)
    PROCEDURE transfer_optimistic(
        p_source_id       IN NUMBER,
        p_dest_id         IN NUMBER,
        p_amount          IN NUMBER,
        p_max_retries     IN NUMBER DEFAULT 3,
        o_result          OUT t_tx_result
    );

    -- 5. Consumo de Cola en Lote con SKIP LOCKED (Cero contención entre Workers)
    PROCEDURE process_settlement_batch(
        p_worker_id       IN VARCHAR2,
        p_batch_size      IN NUMBER DEFAULT 50,
        o_processed_count OUT NUMBER
    );

    -- 6. Función Determinista con PRAGMA UDF para Optimización CBO en SQL
    FUNCTION fn_calculate_tier(p_balance IN NUMBER) RETURN VARCHAR2 DETERMINISTIC;

    -- 7. Consulta de Saldo con validación
    FUNCTION fn_get_account_balance(p_account_id IN NUMBER) RETURN NUMBER;

END PKG_BANK_CORE;
/
