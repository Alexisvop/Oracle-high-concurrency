#!/usr/bin/env python3
"""
=============================================================================
BENCHMARK DE CONCURRENCIA Y ESTRÉS - SISTEMA TRANSACCIONAL BANCARIO EN ORACLE
=============================================================================
Simula cargas extremas de transacciones concurrentes sobre Oracle Database 23ai
comparando:
  1. Bloqueo Pesimista Ordenado (Pessimistic Ordered - Prevención Deadlock)
  2. Bloqueo Pesimista Ingenuo (Pessimistic Naive - Provoca Deadlock ORA-00060)
  3. Bloqueo Optimista (Optimistic Versioning - MVCC + Retries)
  4. Cola Masiva SKIP LOCKED (Queue Workers sin contención)
"""

import sys
import time
import random
import argparse
import json
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
import oracledb

# Configuración de conexión por defecto
DB_USER = os.getenv("DB_USER", "BANK_USER")
DB_PASS = os.getenv("DB_PASS", "BankUserPassword123#")
DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = int(os.getenv("DB_PORT", "1521"))
DB_SERVICE = os.getenv("DB_SERVICE", "FREEPDB1")

DSN = f"{DB_HOST}:{DB_PORT}/{DB_SERVICE}"

def get_connection_pool(min_conn=2, max_conn=100):
    """Crea un Connection Pool de alto rendimiento en modo Thin de python-oracledb."""
    actual_min = max(1, min(min_conn, max_conn))
    return oracledb.create_pool(
        user=DB_USER,
        password=DB_PASS,
        dsn=DSN,
        min=actual_min,
        max=max_conn,
        increment=2
    )

def percentile(data, p):
    """Calcula el percentil p de una lista ordenada."""
    if not data:
        return 0.0
    k = (len(data) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(data) - 1)
    d = k - f
    return data[f] + (data[c] - data[f]) * d

def run_worker_transaction(pool, mode, src_id, dst_id, amount, artificial_delay_ms=0):
    """Ejecuta una transacción individual dentro del pool y cronometra latencia precisa."""
    start_time = time.perf_counter()
    status = "UNKNOWN"
    err_msg = ""
    retries = 0

    try:
        with pool.acquire() as conn:
            cursor = conn.cursor()
            
            # Variables de salida para el tipo RECORD
            v_success = cursor.var(bool)
            v_code = cursor.var(str)
            v_msg = cursor.var(str)
            v_time = cursor.var(float)
            v_retries = cursor.var(int)

            plsql_block = """
            DECLARE
                res PKG_BANK_CORE.t_tx_result;
            BEGIN
                IF :mode = 'ORDERED' THEN
                    PKG_BANK_CORE.transfer_pessimistic_ordered(
                        p_source_id => :src,
                        p_dest_id   => :dst,
                        p_amount    => :amt,
                        o_result    => res
                    );
                ELSIF :mode = 'NAIVE' THEN
                    PKG_BANK_CORE.transfer_pessimistic_naive(
                        p_source_id           => :src,
                        p_dest_id             => :dst,
                        p_amount              => :amt,
                        p_artificial_delay_ms => :delay,
                        o_result              => res
                    );
                ELSIF :mode = 'OPTIMISTIC' THEN
                    PKG_BANK_CORE.transfer_optimistic(
                        p_source_id   => :src,
                        p_dest_id     => :dst,
                        p_amount      => :amt,
                        p_max_retries => 5,
                        o_result      => res
                    );
                END IF;

                :out_success := res.success;
                :out_code    := res.status_code;
                :out_msg     := res.message;
                :out_time    := res.execution_time_ms;
                :out_retries := res.retry_count;
            END;
            """

            cursor.execute(plsql_block, {
                "mode": mode,
                "src": src_id,
                "dst": dst_id,
                "amt": amount,
                "delay": artificial_delay_ms,
                "out_success": v_success,
                "out_code": v_code,
                "out_msg": v_msg,
                "out_time": v_time,
                "out_retries": v_retries
            })

            success = v_success.getvalue()
            status = v_code.getvalue() or ("SUCCESS" if success else "FAILED")
            err_msg = v_msg.getvalue() or ""
            retries = v_retries.getvalue() or 0

    except oracledb.DatabaseError as e:
        error_obj, = e.args
        err_msg = str(error_obj.message)
        if "ORA-00060" in err_msg:
            status = "DEADLOCK_DETECTED"
        elif "ORA-00054" in err_msg:
            status = "LOCK_TIMEOUT"
        else:
            status = "ORACLE_ERROR"
    except Exception as e:
        status = "EXCEPTION"
        err_msg = str(e)

    elapsed_ms = (time.perf_counter() - start_time) * 1000.0
    return {
        "status": status,
        "elapsed_ms": elapsed_ms,
        "retries": retries,
        "error": err_msg
    }

def benchmark_transfers(mode_name, strategy_mode, total_txs=1000, concurrency=50, hotspot_accounts=10, artificial_delay=0):
    """Ejecuta una batería completa de transacciones bajo concurrencia extrema."""
    print(f"\n{'='*75}")
    print(f"BENCHMARK: {mode_name.upper()} | Txs: {total_txs} | Concurrency: {concurrency} hilos | Cuentas Hotspot: {hotspot_accounts}")
    print(f"{'='*75}")

    pool = get_connection_pool(min_conn=10, max_conn=concurrency + 5)
    
    # Rango de cuentas con alta contención intencional
    account_pool = list(range(1, hotspot_accounts + 1))

    tasks = []
    for _ in range(total_txs):
        src, dst = random.sample(account_pool, 2)
        amount = round(random.uniform(10.0, 100.0), 2)
        tasks.append((src, dst, amount))

    results = []
    wall_start = time.perf_counter()

    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [
            executor.submit(run_worker_transaction, pool, strategy_mode, src, dst, amt, artificial_delay)
            for src, dst, amt in tasks
        ]

        completed_count = 0
        for f in as_completed(futures):
            res = f.result()
            results.append(res)
            completed_count += 1
            if completed_count % max(1, total_txs // 10) == 0:
                sys.stdout.write(f"\rProgreso: {completed_count}/{total_txs} ({completed_count*100//total_txs}%)")
                sys.stdout.flush()

    wall_duration = time.perf_counter() - wall_start
    pool.close()
    print("\nCompletado.")

    # Análisis de métricas
    latencies = sorted([r["elapsed_ms"] for r in results])
    statuses = {}
    for r in results:
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1

    success_count = statuses.get("SUCCESS", 0)
    deadlocks = statuses.get("DEADLOCK_DETECTED", 0)
    timeouts = statuses.get("LOCK_TIMEOUT", 0)
    conflicts = statuses.get("OPTIMISTIC_CONFLICT", 0)

    p50 = percentile(latencies, 50)
    p90 = percentile(latencies, 90)
    p95 = percentile(latencies, 95)
    p99 = percentile(latencies, 99)
    avg_lat = sum(latencies) / len(latencies) if latencies else 0
    tps = total_txs / wall_duration if wall_duration > 0 else 0

    metrics = {
        "strategy": mode_name,
        "total_txs": total_txs,
        "concurrency": concurrency,
        "wall_time_sec": round(wall_duration, 3),
        "tps": round(tps, 2),
        "success_rate": round(success_count / total_txs * 100, 2),
        "success_count": success_count,
        "deadlock_count": deadlocks,
        "timeout_count": timeouts,
        "conflict_count": conflicts,
        "avg_latency_ms": round(avg_lat, 2),
        "p50_latency_ms": round(p50, 2),
        "p90_latency_ms": round(p90, 2),
        "p95_latency_ms": round(p95, 2),
        "p99_latency_ms": round(p99, 2),
        "status_distribution": statuses
    }

    print(f"--- RESULTADOS [{mode_name}] ---")
    print(f"  Throughput (TPS):    {metrics['tps']} tx/s")
    print(f"  Éxito:               {metrics['success_rate']}% ({success_count}/{total_txs})")
    print(f"  Deadlocks (ORA-60):  {deadlocks}")
    print(f"  Timeouts (ORA-54):   {timeouts}")
    print(f"  Conflictos Versión:  {conflicts}")
    print(f"  Latencia p50:        {metrics['p50_latency_ms']} ms")
    print(f"  Latencia p95:        {metrics['p95_latency_ms']} ms")
    print(f"  Latencia p99:        {metrics['p99_latency_ms']} ms")
    print(f"  Estados:             {statuses}")

    return metrics

def benchmark_queue_skip_locked(total_items=2000, num_workers=8, batch_size=25):
    """Puebla la cola de liquidación y ejecuta múltiples workers concurrentes con SKIP LOCKED."""
    print(f"\n{'='*75}")
    print(f"BENCHMARK: COLA BATCH 'SKIP LOCKED' | Items: {total_items} | Workers: {num_workers} | Batch Size: {batch_size}")
    print(f"{'='*75}")

    # 1. Poblar la cola
    conn = oracledb.connect(user=DB_USER, password=DB_PASS, dsn=DSN)
    cur = conn.cursor()
    cur.execute("TRUNCATE TABLE PENDING_SETTLEMENT_QUEUE")
    
    rows = []
    for i in range(total_items):
        src = random.randint(1, 500)
        dst = random.randint(501, 1000)
        rows.append((src, dst, round(random.uniform(5.0, 50.0), 2)))
        
    cur.executemany("""
        INSERT INTO PENDING_SETTLEMENT_QUEUE (source_account_id, dest_account_id, amount, status)
        VALUES (:1, :2, :3, 'PENDING')
    """, rows)
    conn.commit()
    conn.close()
    print(f"[*] {total_items} registros insertados en PENDING_SETTLEMENT_QUEUE.")

    # 2. Consumir con Workers concurrentes
    pool = get_connection_pool(min_conn=2, max_conn=num_workers + 2)

    def worker_consumer(worker_id):
        processed_total = 0
        w_start = time.perf_counter()
        while True:
            with pool.acquire() as w_conn:
                w_cur = w_conn.cursor()
                v_count = w_cur.var(int)
                w_cur.execute("""
                    BEGIN
                        PKG_BANK_CORE.process_settlement_batch(
                            p_worker_id       => :wid,
                            p_batch_size      => :bsize,
                            o_processed_count => :pcount
                        );
                    END;
                """, {"wid": worker_id, "bsize": batch_size, "pcount": v_count})
                batch_processed = v_count.getvalue() or 0
                if batch_processed == 0:
                    break
                processed_total += batch_processed
        return {"worker_id": worker_id, "processed": processed_total, "duration_sec": time.perf_counter() - w_start}

    wall_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=num_workers) as executor:
        futures = [executor.submit(worker_consumer, f"Worker-{w}") for w in range(num_workers)]
        worker_results = [f.result() for f in as_completed(futures)]

    total_duration = time.perf_counter() - wall_start
    pool.close()

    total_proc = sum(w["processed"] for w in worker_results)
    tps = total_proc / total_duration if total_duration > 0 else 0

    metrics = {
        "strategy": "Queue SKIP LOCKED",
        "total_items": total_items,
        "workers": num_workers,
        "processed_items": total_proc,
        "wall_time_sec": round(total_duration, 3),
        "tps": round(tps, 2),
        "worker_details": worker_results
    }

    print(f"--- RESULTADOS [Queue SKIP LOCKED] ---")
    print(f"  Items procesados:    {total_proc}/{total_items}")
    print(f"  Throughput (TPS):    {metrics['tps']} items/s")
    print(f"  Tiempo total:        {metrics['wall_time_sec']} s")
    for w in worker_results:
        print(f"    {w['worker_id']}: {w['processed']} items en {round(w['duration_sec'], 2)}s")

    return metrics

def main():
    parser = argparse.ArgumentParser(description="Stress Testing Oracle Banking Engine")
    parser.add_argument("--mode", choices=["ordered", "naive", "optimistic", "queue", "all"], default="all",
                        help="Estrategia a evaluar")
    parser.add_argument("--txs", type=int, default=500, help="Número de transacciones")
    parser.add_argument("--concurrency", type=int, default=30, help="Número de hilos concurrentes")
    parser.add_argument("--hotspots", type=int, default=8, help="Número de cuentas en contención activa")
    args = parser.parse_args()

    os.makedirs("benchmark/results", exist_ok=True)
    summary_report = {}

    if args.mode in ["ordered", "all"]:
        summary_report["pessimistic_ordered"] = benchmark_transfers(
            "Pesimista Ordenado (Anti-Deadlock)", "ORDERED",
            total_txs=args.txs, concurrency=args.concurrency, hotspot_accounts=args.hotspots
        )

    if args.mode in ["naive", "all"]:
        summary_report["pessimistic_naive"] = benchmark_transfers(
            "Pesimista Ingenuo (Demostración Deadlock)", "NAIVE",
            total_txs=min(args.txs, 20), concurrency=min(args.concurrency, 4),
            hotspot_accounts=2, artificial_delay=5
        )

    if args.mode in ["optimistic", "all"]:
        summary_report["optimistic"] = benchmark_transfers(
            "Optimista Versionado (MVCC Retries)", "OPTIMISTIC",
            total_txs=args.txs, concurrency=args.concurrency, hotspot_accounts=args.hotspots
        )

    if args.mode in ["queue", "all"]:
        summary_report["queue_skip_locked"] = benchmark_queue_skip_locked(
            total_items=300, num_workers=4, batch_size=25
        )

    # Guardar resumen en formato JSON
    json_path = "benchmark/results/benchmark_summary.json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(summary_report, f, indent=2, ensure_ascii=False)
    print(f"\n[OK] Resumen de benchmarks guardado en: {json_path}")

if __name__ == "__main__":
    main()
