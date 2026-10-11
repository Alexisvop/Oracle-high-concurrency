-- ============================================================================
-- SCRIPT 03: Generación Masiva de Datos Sintéticos para Benchmarks de Estrés
-- Esquema: BANK_USER | 10,000 Cuentas con distribución gaussiana/aleatoria
-- ============================================================================

SET SERVEROUTPUT ON;
SET TIMING ON;

DECLARE
    v_total_records CONSTANT NUMBER := 10000;
    v_batch_size    CONSTANT NUMBER := 1000;

    TYPE t_account_num  IS TABLE OF ACCOUNTS.account_number%TYPE;
    TYPE t_holder_name  IS TABLE OF ACCOUNTS.holder_name%TYPE;
    TYPE t_holder_email IS TABLE OF ACCOUNTS.holder_email%TYPE;
    TYPE t_balance      IS TABLE OF ACCOUNTS.balance%TYPE;
    
    l_acc_nums   t_account_num  := t_account_num();
    l_names      t_holder_name  := t_holder_name();
    l_emails     t_holder_email := t_holder_email();
    l_balances   t_balance      := t_balance();
    
    v_start_time NUMBER;
    v_end_time   NUMBER;
BEGIN
    DBMS_OUTPUT.PUT_LINE('[*] Iniciando generación de ' || v_total_records || ' cuentas bancarias usando FORALL...');
    v_start_time := DBMS_UTILITY.GET_TIME;

    -- Limpiar cuentas previas
    EXECUTE IMMEDIATE 'TRUNCATE TABLE TRANSACTIONS_LOG';
    EXECUTE IMMEDIATE 'TRUNCATE TABLE SYSTEM_AUDIT_LOG';
    EXECUTE IMMEDIATE 'TRUNCATE TABLE PENDING_SETTLEMENT_QUEUE';
    
    -- Para ACCOUNTS usamos DELETE o TRUNCATE si no hay FKs activas bloqueando
    DELETE FROM ACCOUNTS;
    COMMIT;

    FOR i IN 1..v_total_records LOOP
        l_acc_nums.EXTEND;
        l_names.EXTEND;
        l_emails.EXTEND;
        l_balances.EXTEND;

        l_acc_nums(l_acc_nums.LAST) := 'MXN' || LPAD(TO_CHAR(i), 10, '0') || LPAD(TO_CHAR(MOD(i * 37, 99999)), 5, '0');
        l_names(l_names.LAST)       := 'Cliente Bancario ' || i;
        l_emails(l_emails.LAST)     := 'cliente.' || i || '@banco-demo.com';
        -- Saldos entre $5,000.00 y $500,000.00 con 2 decimales
        l_balances(l_balances.LAST) := ROUND(DBMS_RANDOM.VALUE(5000, 500000), 2);

        IF MOD(i, v_batch_size) = 0 THEN
            -- Inserción masiva de alto rendimiento minimizando context switching
            FORALL idx IN 1..l_acc_nums.COUNT
                INSERT INTO ACCOUNTS (
                    account_number, holder_name, holder_email, balance, currency, status, version_id
                ) VALUES (
                    l_acc_nums(idx), l_names(idx), l_emails(idx), l_balances(idx), 'USD', 'ACTIVE', 1
                );
            COMMIT;

            l_acc_nums.DELETE;
            l_names.DELETE;
            l_emails.DELETE;
            l_balances.DELETE;
        END IF;
    END LOOP;

    -- Procesar remanente si existiera
    IF l_acc_nums.COUNT > 0 THEN
        FORALL idx IN 1..l_acc_nums.COUNT
            INSERT INTO ACCOUNTS (
                account_number, holder_name, holder_email, balance, currency, status, version_id
            ) VALUES (
                l_acc_nums(idx), l_names(idx), l_emails(idx), l_balances(idx), 'USD', 'ACTIVE', 1
            );
        COMMIT;
    END IF;

    -- Recolectar estadísticas frescas para el Cost-Based Optimizer (CBO)
    DBMS_STATS.GATHER_TABLE_STATS(
        ownname          => USER,
        tabname          => 'ACCOUNTS',
        estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
        method_opt       => 'FOR ALL COLUMNS SIZE AUTO',
        cascade          => TRUE
    );

    v_end_time := DBMS_UTILITY.GET_TIME;
    DBMS_OUTPUT.PUT_LINE('[OK] ' || v_total_records || ' cuentas insertadas y estadísticas CBO recolectadas en ' || 
                         ROUND((v_end_time - v_start_time) / 100, 2) || ' segundos.');
END;
/
