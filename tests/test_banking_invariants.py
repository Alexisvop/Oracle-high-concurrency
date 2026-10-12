#!/usr/bin/env python3
"""
=============================================================================
SUITE DE PRUEBAS AUTOMATIZADAS DE INVARIANTES Y REGLAS DE NEGOCIO ACID
=============================================================================
Valida que el motor Oracle Database 23ai aplique estrictamente:
  1. Invariantes de dominio (Saldos no negativos, integridad referencial).
  2. Comportamiento atómico en transferencias pesimistas y optimistas.
  3. Rechazo de sobregiros y transferencias a la misma cuenta.
  4. Persistencia de auditoría autónoma tras fallos transaccionales (ROLLBACK).
  5. Determinismo de funciones de cálculo de nivel de cliente.
"""

import unittest
import oracledb
import os

DB_USER = os.getenv("DB_USER", "BANK_USER")
DB_PASS = os.getenv("DB_PASS", "BankUserPassword123#")
DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = int(os.getenv("DB_PORT", "1521"))
DB_SERVICE = os.getenv("DB_SERVICE", "FREEPDB1")
DSN = f"{DB_HOST}:{DB_PORT}/{DB_SERVICE}"

class TestBankingInvariants(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        """Conexión a la base de datos Oracle antes de los tests."""
        cls.conn = oracledb.connect(user=DB_USER, password=DB_PASS, dsn=DSN)

    @classmethod
    def tearDownClass(cls):
        """Cierre de conexión."""
        cls.conn.close()

    def test_01_pessimistic_transfer_happy_path(self):
        """Verifica que una transferencia pesimista válida modifique saldos atómicamente."""
        cur = self.conn.cursor()
        src_id, dst_id, amount = 101, 102, 150.0

        # Obtener saldos previos
        cur.execute("SELECT balance FROM ACCOUNTS WHERE account_id = :1", [src_id])
        bal_src_init = float(cur.fetchone()[0])
        cur.execute("SELECT balance FROM ACCOUNTS WHERE account_id = :1", [dst_id])
        bal_dst_init = float(cur.fetchone()[0])

        # Ejecutar procedimiento pesimista
        v_success = cur.var(bool)
        v_code = cur.var(str)
        v_msg = cur.var(str)
        v_time = cur.var(float)
        v_retries = cur.var(int)

        cur.execute("""
            DECLARE
                res PKG_BANK_CORE.t_tx_result;
            BEGIN
                PKG_BANK_CORE.transfer_pessimistic_ordered(:src, :dst, :amt, 5, res);
                :s := res.success;
                :c := res.status_code;
                :m := res.message;
            END;
        """, {"src": src_id, "dst": dst_id, "amt": amount, "s": v_success, "c": v_code, "m": v_msg})

        self.assertTrue(v_success.getvalue())
        self.assertEqual(v_code.getvalue(), "SUCCESS")

        # Verificar nuevos saldos
        cur.execute("SELECT balance FROM ACCOUNTS WHERE account_id = :1", [src_id])
        bal_src_new = float(cur.fetchone()[0])
        cur.execute("SELECT balance FROM ACCOUNTS WHERE account_id = :1", [dst_id])
        bal_dst_new = float(cur.fetchone()[0])

        self.assertAlmostEqual(bal_src_new, bal_src_init - amount, places=2)
        self.assertAlmostEqual(bal_dst_new, bal_dst_init + amount, places=2)

    def test_02_insufficient_funds_rejection(self):
        """Verifica que un intento de sobregiro sea rechazado sin modificar los saldos."""
        cur = self.conn.cursor()
        src_id, dst_id = 103, 104

        cur.execute("SELECT balance FROM ACCOUNTS WHERE account_id = :1", [src_id])
        bal_src = float(cur.fetchone()[0])

        # Intentar transferir más del saldo disponible
        overdraft_amount = bal_src + 1000000.0

        v_success = cur.var(bool)
        v_code = cur.var(str)
        v_msg = cur.var(str)

        cur.execute("""
            DECLARE
                res PKG_BANK_CORE.t_tx_result;
            BEGIN
                PKG_BANK_CORE.transfer_pessimistic_ordered(:src, :dst, :amt, 5, res);
                :s := res.success;
                :c := res.status_code;
                :m := res.message;
            END;
        """, {"src": src_id, "dst": dst_id, "amt": overdraft_amount, "s": v_success, "c": v_code, "m": v_msg})

        self.assertFalse(v_success.getvalue())
        self.assertEqual(v_code.getvalue(), "BUSINESS_RULE_VIOLATION")

        # Saldo inalterado
        cur.execute("SELECT balance FROM ACCOUNTS WHERE account_id = :1", [src_id])
        self.assertAlmostEqual(float(cur.fetchone()[0]), bal_src, places=2)

    def test_03_same_account_transfer_rejection(self):
        """Verifica que el motor rechace transferencias hacia la misma cuenta."""
        cur = self.conn.cursor()
        v_success = cur.var(bool)
        v_code = cur.var(str)

        cur.execute("""
            DECLARE
                res PKG_BANK_CORE.t_tx_result;
            BEGIN
                PKG_BANK_CORE.transfer_pessimistic_ordered(105, 105, 100.0, 5, res);
                :s := res.success;
                :c := res.status_code;
            END;
        """, {"s": v_success, "c": v_code})

        self.assertFalse(v_success.getvalue())
        self.assertEqual(v_code.getvalue(), "BUSINESS_RULE_VIOLATION")

    def test_04_optimistic_transfer_increments_version(self):
        """Verifica que la transferencia optimista incremente las versiones de ambas cuentas."""
        cur = self.conn.cursor()
        src_id, dst_id, amount = 106, 107, 75.0

        cur.execute("SELECT version_id FROM ACCOUNTS WHERE account_id = :1", [src_id])
        v1_src = cur.fetchone()[0]
        cur.execute("SELECT version_id FROM ACCOUNTS WHERE account_id = :1", [dst_id])
        v1_dst = cur.fetchone()[0]

        v_success = cur.var(bool)
        cur.execute("""
            DECLARE
                res PKG_BANK_CORE.t_tx_result;
            BEGIN
                PKG_BANK_CORE.transfer_optimistic(:src, :dst, :amt, 5, res);
                :s := res.success;
            END;
        """, {"src": src_id, "dst": dst_id, "amt": amount, "s": v_success})

        self.assertTrue(v_success.getvalue())

        cur.execute("SELECT version_id FROM ACCOUNTS WHERE account_id = :1", [src_id])
        self.assertEqual(cur.fetchone()[0], v1_src + 1)
        cur.execute("SELECT version_id FROM ACCOUNTS WHERE account_id = :1", [dst_id])
        self.assertEqual(cur.fetchone()[0], v1_dst + 1)

    def test_05_autonomous_audit_persists_after_rollback(self):
        """Verifica que el log de auditoría autónomo persista incluso tras un fallo transaccional."""
        cur = self.conn.cursor()
        cur.execute("SELECT COUNT(*) FROM SYSTEM_AUDIT_LOG WHERE event_type = 'TX_FAILED'")
        count_before = cur.fetchone()[0]

        # Forzar un fallo por fondos insuficientes
        cur.execute("""
            DECLARE
                res PKG_BANK_CORE.t_tx_result;
            BEGIN
                PKG_BANK_CORE.transfer_pessimistic_ordered(108, 109, 999999999.0, 5, res);
            END;
        """)

        cur.execute("SELECT COUNT(*) FROM SYSTEM_AUDIT_LOG WHERE event_type = 'TX_FAILED'")
        count_after = cur.fetchone()[0]

        # El log autónomo se confirmó a pesar de que la transferencia falló
        self.assertGreater(count_after, count_before)

    def test_06_check_constraint_prevents_negative_balance(self):
        """Verifica que la restricción CHECK chk_acc_balance_non_negative rechace saldos negativos a nivel de motor."""
        cur = self.conn.cursor()
        with self.assertRaises(oracledb.DatabaseError) as cm:
            cur.execute("UPDATE ACCOUNTS SET balance = -500 WHERE account_id = 110")
        self.assertIn("ORA-02290", str(cm.exception))

    def test_07_deterministic_tier_function(self):
        """Verifica las categorías deterministas de clientes calculadas por fn_calculate_tier."""
        cur = self.conn.cursor()
        cur.execute("""
            SELECT PKG_BANK_CORE.fn_calculate_tier(300000) AS tier_private,
                   PKG_BANK_CORE.fn_calculate_tier(60000)  AS tier_prem,
                   PKG_BANK_CORE.fn_calculate_tier(15000)  AS tier_pref,
                   PKG_BANK_CORE.fn_calculate_tier(1000)   AS tier_std
              FROM DUAL
        """)
        row = cur.fetchone()
        self.assertEqual(row[0], 'PRIVATE_BANKING')
        self.assertEqual(row[1], 'PREMIUM')
        self.assertEqual(row[2], 'PREFERRED')
        self.assertEqual(row[3], 'STANDARD')

if __name__ == "__main__":
    unittest.main(verbosity=2)
