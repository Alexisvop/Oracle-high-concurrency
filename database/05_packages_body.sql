-- ============================================================================
-- SCRIPT 05: Implementación del Package Body PKG_BANK_CORE y Compound Trigger
-- Esquema: BANK_USER | Gestión de Bloqueos, ACID, Prevención de Deadlocks y UDF
-- ============================================================================

SET SQLBLANKLINES ON;

CREATE OR REPLACE PACKAGE BODY PKG_BANK_CORE AS

    -- ------------------------------------------------------------------------
    -- 1. Auditoría Autónoma (PRAGMA AUTONOMOUS_TRANSACTION)
    -- Garantiza que el log persista incluso si la transacción padre hace ROLLBACK
    -- ------------------------------------------------------------------------
    PROCEDURE log_audit(
        p_event_type      IN VARCHAR2,
        p_severity        IN VARCHAR2,
        p_account_a       IN NUMBER DEFAULT NULL,
        p_account_b       IN NUMBER DEFAULT NULL,
        p_amount          IN NUMBER DEFAULT NULL,
        p_detail          IN VARCHAR2 DEFAULT NULL,
        p_ora_err_code    IN NUMBER DEFAULT NULL,
        p_ora_err_msg     IN VARCHAR2 DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO SYSTEM_AUDIT_LOG (
            event_type, severity, account_a, account_b, amount, detail,
            ora_err_code, ora_err_msg, session_user_name, created_at
        ) VALUES (
            p_event_type, p_severity, p_account_a, p_account_b, p_amount, p_detail,
            p_ora_err_code, SUBSTR(p_ora_err_msg, 1, 500), USER, SYSTIMESTAMP
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK; -- Salvaguarda contra excepciones dentro del logger
    END log_audit;

    -- ------------------------------------------------------------------------
    -- 2. Función Determinista con PRAGMA UDF
    -- Optimización para queries analíticas de alto volumen reduciendo context switch
    -- ------------------------------------------------------------------------
    FUNCTION fn_calculate_tier(p_balance IN NUMBER) RETURN VARCHAR2 DETERMINISTIC IS
        PRAGMA UDF;
    BEGIN
        IF p_balance >= 250000 THEN
            RETURN 'PRIVATE_BANKING';
        ELSIF p_balance >= 50000 THEN
            RETURN 'PREMIUM';
        ELSIF p_balance >= 10000 THEN
            RETURN 'PREFERRED';
        ELSE
            RETURN 'STANDARD';
        END IF;
    END fn_calculate_tier;

    -- ------------------------------------------------------------------------
    -- 3. Consulta de Saldo Seguro
    -- ------------------------------------------------------------------------
    FUNCTION fn_get_account_balance(p_account_id IN NUMBER) RETURN NUMBER IS
        v_bal NUMBER(18, 2);
    BEGIN
        SELECT balance INTO v_bal FROM ACCOUNTS WHERE account_id = p_account_id;
        RETURN v_bal;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
    END fn_get_account_balance;

    -- ------------------------------------------------------------------------
    -- 4. Transferencia Pesimista con Prevención de Deadlocks (Ordered Locking)
    -- Adquiere locks siempre en orden ascendente: LEAST(...) luego GREATEST(...)
    -- Esto rompe la condición de espera circular de Coffman (Prevención de Deadlock)
    -- ------------------------------------------------------------------------
    PROCEDURE transfer_pessimistic_ordered(
        p_source_id       IN NUMBER,
        p_dest_id         IN NUMBER,
        p_amount          IN NUMBER,
        p_lock_timeout_sec IN NUMBER DEFAULT 5,
        o_result          OUT t_tx_result
    ) IS
        v_t_start         NUMBER := DBMS_UTILITY.GET_TIME;
        v_first_id        NUMBER;
        v_second_id       NUMBER;
        
        v_src_balance     ACCOUNTS.balance%TYPE;
        v_src_status      ACCOUNTS.status%TYPE;
        v_dst_balance     ACCOUNTS.balance%TYPE;
        v_dst_status      ACCOUNTS.status%TYPE;
        
        v_first_bal       ACCOUNTS.balance%TYPE;
        v_first_status    ACCOUNTS.status%TYPE;
        v_second_bal      ACCOUNTS.balance%TYPE;
        v_second_status   ACCOUNTS.status%TYPE;
    BEGIN
        o_result.retry_count := 0;

        -- Validaciones preliminares
        IF p_source_id = p_dest_id THEN
            RAISE_APPLICATION_ERROR(-20004, 'No es posible transferir a la misma cuenta.');
        END IF;

        IF p_amount <= 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'El monto a transferir debe ser mayor a cero.');
        END IF;

        -- Estrategia de Ordenamiento Canónico: Siempre bloquear menor ID primero
        v_first_id  := LEAST(p_source_id, p_dest_id);
        v_second_id := GREATEST(p_source_id, p_dest_id);

        -- Adquisición de Locks de Fila (Row-Exclusive) de manera secuencial determinista
        SELECT balance, status INTO v_first_bal, v_first_status
          FROM ACCOUNTS
         WHERE account_id = v_first_id
           FOR UPDATE WAIT 5;

        SELECT balance, status INTO v_second_bal, v_second_status
          FROM ACCOUNTS
         WHERE account_id = v_second_id
           FOR UPDATE WAIT 5;

        -- Asignar valores según corresponda a origen o destino
        IF p_source_id = v_first_id THEN
            v_src_balance := v_first_bal;
            v_src_status  := v_first_status;
            v_dst_balance := v_second_bal;
            v_dst_status  := v_second_status;
        ELSE
            v_src_balance := v_second_bal;
            v_src_status  := v_second_status;
            v_dst_balance := v_first_bal;
            v_dst_status  := v_first_status;
        END IF;

        -- Validación de invariantes de negocio
        IF v_src_status != 'ACTIVE' OR v_dst_status != 'ACTIVE' THEN
            RAISE_APPLICATION_ERROR(-20002, 'Una de las cuentas no se encuentra activa.');
        END IF;

        IF v_src_balance < p_amount THEN
            RAISE_APPLICATION_ERROR(-20001, 'Fondos insuficientes en cuenta origen. Saldo: ' || v_src_balance || ', Requerido: ' || p_amount);
        END IF;

        -- Operaciones DML Atómicas
        UPDATE ACCOUNTS
           SET balance = balance - p_amount,
               updated_at = SYSTIMESTAMP
         WHERE account_id = p_source_id;

        UPDATE ACCOUNTS
           SET balance = balance + p_amount,
               updated_at = SYSTIMESTAMP
         WHERE account_id = p_dest_id;

        -- Registro de éxito en libro mayor
        INSERT INTO TRANSACTIONS_LOG (
            source_account_id, dest_account_id, amount, tx_type, status,
            lock_strategy, execution_time_ms
        ) VALUES (
            p_source_id, p_dest_id, p_amount, 'TRANSFER', 'COMMITTED',
            'PESSIMISTIC_ORDERED', (DBMS_UTILITY.GET_TIME - v_t_start) * 10
        );

        COMMIT;

        o_result.success           := TRUE;
        o_result.status_code       := 'SUCCESS';
        o_result.message           := 'Transferencia procesada atómicamente.';
        o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;

    EXCEPTION
        WHEN e_resource_busy THEN
            ROLLBACK;
            o_result.success           := FALSE;
            o_result.status_code       := 'LOCK_TIMEOUT';
            o_result.message           := 'Tiempo de espera de bloqueo excedido (ORA-00054).';
            o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;
            log_audit('TX_FAILED', 'WARN', p_source_id, p_dest_id, p_amount, o_result.message, -54, SQLERRM);

        WHEN e_insufficient_funds OR e_account_not_active OR e_same_account_transfer THEN
            ROLLBACK;
            o_result.success           := FALSE;
            o_result.status_code       := 'BUSINESS_RULE_VIOLATION';
            o_result.message           := SQLERRM;
            o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;
            log_audit('TX_FAILED', 'INFO', p_source_id, p_dest_id, p_amount, o_result.message, SQLCODE, SQLERRM);

        WHEN OTHERS THEN
            ROLLBACK;
            o_result.success           := FALSE;
            o_result.status_code       := 'UNEXPECTED_ERROR';
            o_result.message           := SQLERRM;
            o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;
            log_audit('TX_ERROR', 'ERROR', p_source_id, p_dest_id, p_amount, o_result.message, SQLCODE, SQLERRM);
    END transfer_pessimistic_ordered;

    -- ------------------------------------------------------------------------
    -- 5. Transferencia Pesimista Ingenua (Demostración de Deadlock ORA-00060)
    -- Adquiere locks en el orden de llegada arbitrario con un micro-delay
    -- En concurrencia cruzada (A->B simultáneo con B->A), garantiza colisión
    -- ------------------------------------------------------------------------
    PROCEDURE transfer_pessimistic_naive(
        p_source_id       IN NUMBER,
        p_dest_id         IN NUMBER,
        p_amount          IN NUMBER,
        p_artificial_delay_ms IN NUMBER DEFAULT 50,
        o_result          OUT t_tx_result
    ) IS
        v_t_start         NUMBER := DBMS_UTILITY.GET_TIME;
        v_src_balance     ACCOUNTS.balance%TYPE;
        v_dst_balance     ACCOUNTS.balance%TYPE;
    BEGIN
        o_result.retry_count := 0;

        -- Bloquear cuenta ORIGEN primero con timeout controlado
        SELECT balance INTO v_src_balance
          FROM ACCOUNTS
         WHERE account_id = p_source_id
           FOR UPDATE WAIT 2;

        -- Retraso inducido para ampliar la ventana de contención concurrente
        IF p_artificial_delay_ms > 0 THEN
            DBMS_SESSION.SLEEP(p_artificial_delay_ms / 1000.0);
        END IF;

        -- Intentar bloquear cuenta DESTINO segundo (aquí ocurre el ORA-00060 en transacciones cruzadas)
        SELECT balance INTO v_dst_balance
          FROM ACCOUNTS
         WHERE account_id = p_dest_id
           FOR UPDATE WAIT 2;

        IF v_src_balance < p_amount THEN
            RAISE_APPLICATION_ERROR(-20001, 'Fondos insuficientes.');
        END IF;

        UPDATE ACCOUNTS SET balance = balance - p_amount WHERE account_id = p_source_id;
        UPDATE ACCOUNTS SET balance = balance + p_amount WHERE account_id = p_dest_id;

        INSERT INTO TRANSACTIONS_LOG (
            source_account_id, dest_account_id, amount, tx_type, status,
            lock_strategy, execution_time_ms
        ) VALUES (
            p_source_id, p_dest_id, p_amount, 'TRANSFER', 'COMMITTED',
            'PESSIMISTIC_NAIVE', (DBMS_UTILITY.GET_TIME - v_t_start) * 10
        );

        COMMIT;

        o_result.success           := TRUE;
        o_result.status_code       := 'SUCCESS';
        o_result.message           := 'Transferencia ingenua completada sin deadlock.';
        o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;

    EXCEPTION
        WHEN e_deadlock_detected THEN
            ROLLBACK;
            o_result.success           := FALSE;
            o_result.status_code       := 'DEADLOCK_DETECTED';
            o_result.message           := 'Deadlock detectado y abortado por Oracle (ORA-00060).';
            o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;
            log_audit('DEADLOCK_CAPTURED', 'CRITICAL', p_source_id, p_dest_id, p_amount, o_result.message, -60, SQLERRM);

        WHEN e_resource_busy THEN
            ROLLBACK;
            o_result.success           := FALSE;
            o_result.status_code       := 'LOCK_CONTENTION';
            o_result.message           := 'Contención severa de fila (ORA-00054).';
            o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;
            log_audit('LOCK_CONTENTION', 'WARN', p_source_id, p_dest_id, p_amount, o_result.message, -54, SQLERRM);

        WHEN OTHERS THEN
            ROLLBACK;
            o_result.success           := FALSE;
            o_result.status_code       := 'ERROR';
            o_result.message           := SQLERRM;
            o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;
            log_audit('TX_FAILED', 'WARN', p_source_id, p_dest_id, p_amount, o_result.message, SQLCODE, SQLERRM);
    END transfer_pessimistic_naive;

    -- ------------------------------------------------------------------------
    -- 6. Transferencia Optimista con Control de Versión (Optimistic Concurrency)
    -- No coloca bloqueos en SELECT; detecta colisiones al hacer UPDATE comparando VERSION_ID
    -- ------------------------------------------------------------------------
    PROCEDURE transfer_optimistic(
        p_source_id       IN NUMBER,
        p_dest_id         IN NUMBER,
        p_amount          IN NUMBER,
        p_max_retries     IN NUMBER DEFAULT 3,
        o_result          OUT t_tx_result
    ) IS
        v_t_start         NUMBER := DBMS_UTILITY.GET_TIME;
        v_src_bal         ACCOUNTS.balance%TYPE;
        v_src_ver         ACCOUNTS.version_id%TYPE;
        v_dst_bal         ACCOUNTS.balance%TYPE;
        v_dst_ver         ACCOUNTS.version_id%TYPE;
        v_rows_updated    NUMBER;
        v_committed       BOOLEAN := FALSE;
    BEGIN
        o_result.retry_count := 0;

        FOR i IN 1..p_max_retries LOOP
            o_result.retry_count := i - 1;

            -- 1. Lectura sucia / no bloqueante (Consistente en lectura según MVCC de Oracle)
            SELECT balance, version_id INTO v_src_bal, v_src_ver
              FROM ACCOUNTS WHERE account_id = p_source_id;

            SELECT balance, version_id INTO v_dst_bal, v_dst_ver
              FROM ACCOUNTS WHERE account_id = p_dest_id;

            IF v_src_bal < p_amount THEN
                RAISE_APPLICATION_ERROR(-20001, 'Fondos insuficientes.');
            END IF;

            -- 2. Actualización optimista en orden canónico (evita bloqueos cruzados en la fase de escritura)
            DECLARE
                v_first_acc   NUMBER := LEAST(p_source_id, p_dest_id);
                v_second_acc  NUMBER := GREATEST(p_source_id, p_dest_id);
                v_first_ver   NUMBER;
                v_second_ver  NUMBER;
                v_first_delta NUMBER;
                v_second_delta NUMBER;
                v_upd1_cnt    NUMBER;
                v_upd2_cnt    NUMBER;
            BEGIN
                IF p_source_id = v_first_acc THEN
                    v_first_ver    := v_src_ver;
                    v_first_delta  := -p_amount;
                    v_second_ver   := v_dst_ver;
                    v_second_delta := p_amount;
                ELSE
                    v_first_ver    := v_dst_ver;
                    v_first_delta  := p_amount;
                    v_second_ver   := v_src_ver;
                    v_second_delta := -p_amount;
                END IF;

                -- Actualizar primera cuenta en orden canónico
                UPDATE ACCOUNTS
                   SET balance = balance + v_first_delta,
                       version_id = version_id + 1,
                       updated_at = SYSTIMESTAMP
                 WHERE account_id = v_first_acc
                   AND version_id = v_first_ver;
                v_upd1_cnt := SQL%ROWCOUNT;

                IF v_upd1_cnt = 1 THEN
                    -- Actualizar segunda cuenta en orden canónico
                    UPDATE ACCOUNTS
                       SET balance = balance + v_second_delta,
                           version_id = version_id + 1,
                           updated_at = SYSTIMESTAMP
                     WHERE account_id = v_second_acc
                       AND version_id = v_second_ver;
                    v_upd2_cnt := SQL%ROWCOUNT;

                    IF v_upd2_cnt = 1 THEN
                        INSERT INTO TRANSACTIONS_LOG (
                            source_account_id, dest_account_id, amount, tx_type, status,
                            lock_strategy, execution_time_ms
                        ) VALUES (
                            p_source_id, p_dest_id, p_amount, 'TRANSFER', 'COMMITTED',
                            'OPTIMISTIC', (DBMS_UTILITY.GET_TIME - v_t_start) * 10
                        );
                        COMMIT;
                        v_committed := TRUE;
                        EXIT; -- Éxito
                    ELSE
                        ROLLBACK;
                        DBMS_SESSION.SLEEP(DBMS_RANDOM.VALUE(0.01, 0.04));
                    END IF;
                ELSE
                    ROLLBACK;
                    DBMS_SESSION.SLEEP(DBMS_RANDOM.VALUE(0.01, 0.04));
                END IF;
            EXCEPTION
                WHEN e_deadlock_detected OR e_resource_busy THEN
                    ROLLBACK;
                    DBMS_SESSION.SLEEP(DBMS_RANDOM.VALUE(0.01, 0.05));
            END;
        END LOOP;

        IF v_committed THEN
            o_result.success           := TRUE;
            o_result.status_code       := 'SUCCESS';
            o_result.message           := 'Transferencia optimista completada con ' || o_result.retry_count || ' reintentos.';
            o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;
        ELSE
            o_result.success           := FALSE;
            o_result.status_code       := 'OPTIMISTIC_CONFLICT';
            o_result.message           := 'Límite de reintentos optimistas alcanzado por alta contención.';
            o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;
            log_audit('OPTIMISTIC_EXHAUSTED', 'WARN', p_source_id, p_dest_id, p_amount, o_result.message, -20003, SQLERRM);
        END IF;

    EXCEPTION
        WHEN e_insufficient_funds THEN
            ROLLBACK;
            o_result.success           := FALSE;
            o_result.status_code       := 'INSUFFICIENT_FUNDS';
            o_result.message           := SQLERRM;
            o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;
        WHEN OTHERS THEN
            ROLLBACK;
            o_result.success           := FALSE;
            o_result.status_code       := 'ERROR';
            o_result.message           := SQLERRM;
            o_result.execution_time_ms := (DBMS_UTILITY.GET_TIME - v_t_start) * 10;
            log_audit('OPTIMISTIC_FAIL', 'ERROR', p_source_id, p_dest_id, p_amount, o_result.message, SQLCODE, SQLERRM);
    END transfer_optimistic;

    -- ------------------------------------------------------------------------
    -- 7. Procesamiento de Lotes con SKIP LOCKED
    -- Múltiples procesos paralelos pueden consumir la cola sin esperar bloqueos
    -- ------------------------------------------------------------------------
    PROCEDURE process_settlement_batch(
        p_worker_id       IN VARCHAR2,
        p_batch_size      IN NUMBER DEFAULT 50,
        o_processed_count OUT NUMBER
    ) IS
        CURSOR c_pending IS
            SELECT queue_id, source_account_id, dest_account_id, amount
              FROM PENDING_SETTLEMENT_QUEUE
             WHERE status = 'PENDING'
             ORDER BY queue_id
               FOR UPDATE SKIP LOCKED;

        TYPE t_q_id  IS TABLE OF PENDING_SETTLEMENT_QUEUE.queue_id%TYPE;
        TYPE t_src   IS TABLE OF PENDING_SETTLEMENT_QUEUE.source_account_id%TYPE;
        TYPE t_dst   IS TABLE OF PENDING_SETTLEMENT_QUEUE.dest_account_id%TYPE;
        TYPE t_amt   IS TABLE OF PENDING_SETTLEMENT_QUEUE.amount%TYPE;

        l_q_ids  t_q_id;
        l_srcs   t_src;
        l_dsts   t_dst;
        l_amts   t_amt;

        v_tx_res t_tx_result;
    BEGIN
        o_processed_count := 0;

        OPEN c_pending;
        FETCH c_pending BULK COLLECT INTO l_q_ids, l_srcs, l_dsts, l_amts LIMIT p_batch_size;
        CLOSE c_pending;

        IF l_q_ids.COUNT > 0 THEN
            FOR idx IN 1..l_q_ids.COUNT LOOP
                -- Procesar cada liquidación con lock pesimista ordenado
                transfer_pessimistic_ordered(
                    p_source_id => l_srcs(idx),
                    p_dest_id   => l_dsts(idx),
                    p_amount    => l_amts(idx),
                    o_result    => v_tx_res
                );

                UPDATE PENDING_SETTLEMENT_QUEUE
                   SET status = CASE WHEN v_tx_res.success THEN 'COMPLETED' ELSE 'FAILED' END,
                       worker_id = p_worker_id,
                       processed_at = SYSTIMESTAMP
                 WHERE queue_id = l_q_ids(idx);

                o_processed_count := o_processed_count + 1;
            END LOOP;
            COMMIT;
        END IF;
    END process_settlement_batch;

END PKG_BANK_CORE;
/

-- ----------------------------------------------------------------------------
-- 8. COMPOUND TRIGGER: TRG_ACCOUNTS_SNAPSHOT_MAINTAINER
-- Evita el error ORA-04091 (Mutating Table) al acumular diferencias en memoria
-- durante el trigger de fila y aplicar la consolidación al finalizar la sentencia
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER TRG_ACCOUNTS_SNAPSHOT_MAINTAINER
FOR INSERT OR UPDATE OR DELETE ON ACCOUNTS
COMPOUND TRIGGER

    TYPE t_account_delta IS RECORD (
        delta_balance NUMBER(22, 2) := 0,
        delta_count   NUMBER(10)    := 0
    );
    g_delta t_account_delta;

    BEFORE STATEMENT IS
    BEGIN
        g_delta.delta_balance := 0;
        g_delta.delta_count   := 0;
    END BEFORE STATEMENT;

    AFTER EACH ROW IS
    BEGIN
        IF INSERTING THEN
            g_delta.delta_balance := g_delta.delta_balance + :NEW.balance;
            g_delta.delta_count   := g_delta.delta_count + 1;
        ELSIF UPDATING THEN
            g_delta.delta_balance := g_delta.delta_balance + (:NEW.balance - :OLD.balance);
        ELSIF DELETING THEN
            g_delta.delta_balance := g_delta.delta_balance - :OLD.balance;
            g_delta.delta_count   := g_delta.delta_count - 1;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_today DATE := TRUNC(SYSDATE);
    BEGIN
        MERGE INTO ACCOUNT_BALANCE_SNAPSHOT s
        USING (SELECT v_today AS s_date FROM DUAL) src
        ON (s.snapshot_date = src.s_date)
        WHEN MATCHED THEN
            UPDATE SET
                s.total_accounts  = s.total_accounts + g_delta.delta_count,
                s.total_liquidity = s.total_liquidity + g_delta.delta_balance,
                s.last_updated_at = SYSTIMESTAMP
        WHEN NOT MATCHED THEN
            INSERT (snapshot_date, total_accounts, total_liquidity, last_updated_at)
            VALUES (v_today, 10000 + g_delta.delta_count, 2500000000 + g_delta.delta_balance, SYSTIMESTAMP);
    END AFTER STATEMENT;

END TRG_ACCOUNTS_SNAPSHOT_MAINTAINER;
/

PROMPT [OK] Package Body y Compound Trigger compilados exitosamente.
