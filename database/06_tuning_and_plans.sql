-- ============================================================================
-- SCRIPT 06: Optimización, Planes de Ejecución (EXPLAIN PLAN) e Indexación
-- Esquema: BANK_USER | Comparativa de Costos CBO, FTS vs Index Range Scan
-- ============================================================================

SET LINESIZE 180;
SET PAGESIZE 1000;
SET FEEDBACK ON;

PROMPT ============================================================================
PROMPT 1. CASO 1: Consulta por Correo con Función (Búsqueda Insensible a Mayúsculas)
PROMPT ============================================================================

-- Plan ANTES de crear el Function-Based Index (Fuerza FULL TABLE SCAN)
EXPLAIN PLAN FOR
SELECT account_id, holder_name, balance 
  FROM ACCOUNTS 
 WHERE UPPER(holder_email) = 'CLIENTE.500@BANCO-DEMO.COM';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'TYPICAL'));

-- Creación del Índice Basado en Funciones (Function-Based Index)
CREATE INDEX idx_acc_fbi_email ON ACCOUNTS(UPPER(holder_email));

-- Recolectar estadísticas de la columna virtual generada
EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'ACCOUNTS', cascade => TRUE);

-- Plan DESPUÉS de crear el Function-Based Index (Cambia a INDEX RANGE SCAN con reducción drástica de costo)
EXPLAIN PLAN FOR
SELECT account_id, holder_name, balance 
  FROM ACCOUNTS 
 WHERE UPPER(holder_email) = 'CLIENTE.500@BANCO-DEMO.COM';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'TYPICAL'));


PROMPT ============================================================================
PROMPT 2. CASO 2: Consulta Analítica Multicriterio sobre Historial Transaccional
PROMPT ============================================================================

-- Plan ANTES del Índice Compuesto (FTS sobre TRANSACTIONS_LOG)
EXPLAIN PLAN FOR
SELECT transaction_id, amount, created_at
  FROM TRANSACTIONS_LOG
 WHERE source_account_id = 1
   AND status = 'COMMITTED'
 ORDER BY created_at DESC;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'TYPICAL'));

-- Creación de Índice Compuesto Estratégico (Leading column de alta cardinalidad)
CREATE INDEX idx_tx_comp_src_status_dt ON TRANSACTIONS_LOG(source_account_id, status, created_at DESC);

EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'TRANSACTIONS_LOG', cascade => TRUE);

-- Plan DESPUÉS del Índice Compuesto (Elimina SORT y realiza INDEX RANGE SCAN)
EXPLAIN PLAN FOR
SELECT transaction_id, amount, created_at
  FROM TRANSACTIONS_LOG
 WHERE source_account_id = 1
   AND status = 'COMMITTED'
 ORDER BY created_at DESC;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'TYPICAL'));


PROMPT ============================================================================
PROMPT 3. CASO 3: Indexación de Función Determinista PL/SQL (fn_calculate_tier)
PROMPT ============================================================================

-- Creación de índice sobre función de paquete determinista
CREATE INDEX idx_acc_fbi_tier ON ACCOUNTS(PKG_BANK_CORE.fn_calculate_tier(balance));

EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'ACCOUNTS', cascade => TRUE);

EXPLAIN PLAN FOR
SELECT account_id, balance, holder_name
  FROM ACCOUNTS
 WHERE PKG_BANK_CORE.fn_calculate_tier(balance) = 'PRIVATE_BANKING';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'TYPICAL'));

PROMPT [OK] Demostración de tuning y planes de ejecución completada.
