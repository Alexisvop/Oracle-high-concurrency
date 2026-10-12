#!/usr/bin/env python3
"""
=============================================================================
ORACLE BANKING TRANSACTION ENGINE - DASHBOARD & INTERFAZ GRÁFICA WEB
=============================================================================
Servidor Flask con API REST interactiva para:
  1. Monitoreo en tiempo real del motor Oracle Database 23ai.
  2. Ejecución manual de transferencias con selección de estrategia ACID.
  3. Ejecución y visualización reactiva de benchmarks de estrés y contención.
  4. Inspección de tablas de auditoría (AUTONOMOUS_TRANSACTION) y ledger.
  5. Visualizador de planes de ejecución del Cost-Based Optimizer (CBO).
"""

import os
import sys
import time
import json
import oracledb
from flask import Flask, render_template, request, jsonify

# Agregar el directorio raíz al path para importar benchmark/stress_test.py
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE_DIR)

from benchmark.stress_test import (
    benchmark_transfers,
    benchmark_queue_skip_locked,
    get_connection_pool,
    DB_USER, DB_PASS, DSN
)
from benchmark.generate_report import generate_charts

app = Flask(__name__, template_folder="templates", static_folder="static")

def get_db_connection():
    """Retorna una conexión directa a la base de datos."""
    return oracledb.connect(user=DB_USER, password=DB_PASS, dsn=DSN)

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/status", methods=["GET"])
def get_status():
    """Consulta el estado del motor Oracle y métricas agregadas."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        cur.execute("SELECT banner FROM v$version WHERE ROWNUM = 1")
        version = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*), NVL(SUM(balance), 0) FROM ACCOUNTS")
        acc_count, total_liquidity = cur.fetchone()

        cur.execute("SELECT COUNT(*) FROM TRANSACTIONS_LOG")
        tx_count = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM SYSTEM_AUDIT_LOG")
        audit_count = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM PENDING_SETTLEMENT_QUEUE WHERE status = 'PENDING'")
        queue_pending = cur.fetchone()[0]

        conn.close()
        return jsonify({
            "status": "ONLINE",
            "version": version,
            "total_accounts": acc_count,
            "total_liquidity": float(total_liquidity),
            "total_transactions": tx_count,
            "total_audit_events": audit_count,
            "queue_pending": queue_pending
        })
    except Exception as e:
        return jsonify({
            "status": "OFFLINE",
            "error": str(e)
        }), 500

@app.route("/api/transfer", methods=["POST"])
def execute_transfer():
    """Ejecuta una transferencia individual mediante el package PL/SQL."""
    data = request.json or {}
    source_id = int(data.get("source_id", 1))
    dest_id = int(data.get("dest_id", 2))
    amount = float(data.get("amount", 100.0))
    strategy = data.get("strategy", "ORDERED").upper()

    try:
        conn = get_db_connection()
        cur = conn.cursor()

        v_success = cur.var(bool)
        v_code = cur.var(str)
        v_msg = cur.var(str)
        v_time = cur.var(float)
        v_retries = cur.var(int)

        plsql_block = """
        DECLARE
            res PKG_BANK_CORE.t_tx_result;
        BEGIN
            IF :strat = 'ORDERED' THEN
                PKG_BANK_CORE.transfer_pessimistic_ordered(:src, :dst, :amt, 5, res);
            ELSIF :strat = 'OPTIMISTIC' THEN
                PKG_BANK_CORE.transfer_optimistic(:src, :dst, :amt, 5, res);
            ELSIF :strat = 'NAIVE' THEN
                PKG_BANK_CORE.transfer_pessimistic_naive(:src, :dst, :amt, 10, res);
            END IF;

            :out_s := res.success;
            :out_c := res.status_code;
            :out_m := res.message;
            :out_t := res.execution_time_ms;
            :out_r := res.retry_count;
        END;
        """

        cur.execute(plsql_block, {
            "strat": strategy,
            "src": source_id,
            "dst": dest_id,
            "amt": amount,
            "out_s": v_success,
            "out_c": v_code,
            "out_m": v_msg,
            "out_t": v_time,
            "out_r": v_retries
        })

        success = v_success.getvalue()
        code = v_code.getvalue() or ("SUCCESS" if success else "FAILED")
        message = v_msg.getvalue() or ""
        exec_time = v_time.getvalue() or 0.0
        retries = v_retries.getvalue() or 0

        # Obtener nuevos saldos
        cur.execute("SELECT balance FROM ACCOUNTS WHERE account_id = :1", [source_id])
        src_row = cur.fetchone()
        src_bal = float(src_row[0]) if src_row else None

        cur.execute("SELECT balance FROM ACCOUNTS WHERE account_id = :1", [dest_id])
        dst_row = cur.fetchone()
        dst_bal = float(dst_row[0]) if dst_row else None

        conn.close()
        return jsonify({
            "success": success,
            "status_code": code,
            "message": message,
            "execution_time_ms": exec_time,
            "retries": retries,
            "source_balance": src_bal,
            "dest_balance": dst_bal
        })

    except Exception as e:
        return jsonify({
            "success": False,
            "status_code": "EXCEPTION",
            "message": str(e),
            "execution_time_ms": 0
        }), 500

@app.route("/api/benchmark", methods=["POST"])
def run_benchmark():
    """Ejecuta un benchmark de estrés bajo demanda y devuelve resultados en JSON."""
    data = request.json or {}
    mode = data.get("mode", "all")
    txs = int(data.get("txs", 100))
    concurrency = int(data.get("concurrency", 10))
    hotspots = int(data.get("hotspots", 5))

    results = {}

    if mode in ["ordered", "all"]:
        results["pessimistic_ordered"] = benchmark_transfers(
            "Pesimista Ordenado (Anti-Deadlock)", "ORDERED",
            total_txs=txs, concurrency=concurrency, hotspot_accounts=hotspots
        )

    if mode in ["naive", "all"]:
        results["pessimistic_naive"] = benchmark_transfers(
            "Pesimista Ingenuo (Demostración Deadlock)", "NAIVE",
            total_txs=min(txs, 20), concurrency=min(concurrency, 4),
            hotspot_accounts=2, artificial_delay=5
        )

    if mode in ["optimistic", "all"]:
        results["optimistic"] = benchmark_transfers(
            "Optimista Versionado (MVCC Retries)", "OPTIMISTIC",
            total_txs=txs, concurrency=concurrency, hotspot_accounts=hotspots
        )

    if mode in ["queue", "all"]:
        results["queue_skip_locked"] = benchmark_queue_skip_locked(
            total_items=min(txs * 2, 300), num_workers=min(concurrency, 4), batch_size=25
        )

    # Guardar resumen y generar imágenes
    json_path = os.path.join(BASE_DIR, "benchmark", "results", "benchmark_summary.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    try:
        generate_charts()
    except Exception as e:
        print("[!] Error generando gráficas:", e)

    return jsonify(results)

@app.route("/api/transactions", methods=["GET"])
def get_transactions():
    """Devuelve las últimas 20 transacciones registradas."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("""
            SELECT transaction_id, source_account_id, dest_account_id, amount,
                   tx_type, status, lock_strategy, execution_time_ms,
                   TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS')
              FROM TRANSACTIONS_LOG
             ORDER BY transaction_id DESC
            FETCH FIRST 20 ROWS ONLY
        """)
        cols = ["id", "source_id", "dest_id", "amount", "type", "status", "strategy", "time_ms", "created_at"]
        data = [dict(zip(cols, row)) for row in cur.fetchall()]
        conn.close()
        return jsonify(data)
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/audit", methods=["GET"])
def get_audit():
    """Devuelve los últimos 20 eventos de auditoría (AUTONOMOUS_TRANSACTION)."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("""
            SELECT audit_id, event_type, severity, account_a, account_b,
                   ora_err_code, detail, TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS')
              FROM SYSTEM_AUDIT_LOG
             ORDER BY audit_id DESC
            FETCH FIRST 20 ROWS ONLY
        """)
        cols = ["id", "event", "severity", "acc_a", "acc_b", "ora_code", "detail", "created_at"]
        data = [dict(zip(cols, row)) for row in cur.fetchall()]
        conn.close()
        return jsonify(data)
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/accounts", methods=["GET"])
def get_accounts():
    """Devuelve una muestra de las primeras cuentas con sus saldos y categorías."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("""
            SELECT account_id, account_number, holder_name, balance, status, version_id,
                   PKG_BANK_CORE.fn_calculate_tier(balance) AS tier
              FROM ACCOUNTS
             ORDER BY account_id ASC
            FETCH FIRST 15 ROWS ONLY
        """)
        cols = ["id", "account_number", "holder_name", "balance", "status", "version_id", "tier"]
        data = [dict(zip(cols, row)) for row in cur.fetchall()]
        conn.close()
        return jsonify(data)
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    port = int(os.getenv("PORT", 5000))
    print(f"[*] Iniciando Dashboard Web de Oracle Banking Engine en http://localhost:{port}")
    app.run(host="0.0.0.0", port=port, debug=False)
