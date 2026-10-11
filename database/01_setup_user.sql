-- ============================================================================
-- SCRIPT 01: Setup Usuario y Permisos para el Sistema Transaccional Bancario
-- Compatible con Oracle Database 23ai / 21c (PDB: FREEPDB1 / XEPDB1)
-- ============================================================================

-- Conectarse a la PDB por defecto si se ejecuta como SYS
ALTER SESSION SET CONTAINER = FREEPDB1;

-- Crear el usuario BANK_USER si no existe (con permisos completos de desarrollo)
DECLARE
    v_user_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_user_exists FROM all_users WHERE username = 'BANK_USER';
    IF v_user_exists = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER BANK_USER IDENTIFIED BY "BankUserPassword123#" DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS';
    END IF;
END;
/

-- Privilegios esenciales para desarrollo PL/SQL empresarial y tuning
GRANT CONNECT, RESOURCE TO BANK_USER;
GRANT CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE SEQUENCE, CREATE TRIGGER TO BANK_USER;
GRANT UNLIMITED TABLESPACE TO BANK_USER;

-- Privilegios de instrumentación y diagnóstico (planes de ejecución y monitoreo)
GRANT SELECT ANY DICTIONARY TO BANK_USER;
GRANT SELECT_CATALOG_ROLE TO BANK_USER;
GRANT EXECUTE ON DBMS_LOCK TO BANK_USER;
GRANT EXECUTE ON DBMS_XPLAN TO BANK_USER;

PROMPT [OK] Usuario BANK_USER configurado con privilegios empresariales.
