#!/usr/bin/env python3
"""
=============================================================================
GENERADOR DE REPORTES Y GRÁFICOS VISUALES DE RENDIMIENTO (BENCHMARKS)
=============================================================================
Lee los resultados generados por stress_test.py y genera gráficas comparativas
en formato PNG y tablas en formato Markdown.
"""

import json
import os
import matplotlib.pyplot as plt
import numpy as np

def generate_charts():
    json_path = "benchmark/results/benchmark_summary.json"
    if not os.path.exists(json_path):
        print(f"[!] Archivo {json_path} no encontrado.")
        return

    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    os.makedirs("benchmark/results", exist_ok=True)
    plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')

    # 1. Comparativa de Latencias (p50, p95, p99)
    transfer_keys = ["pessimistic_ordered", "pessimistic_naive", "optimistic"]
    labels = []
    p50_list = []
    p95_list = []
    p99_list = []

    label_map = {
        "pessimistic_ordered": "Pesimista Ordenado\n(Anti-Deadlock)",
        "pessimistic_naive": "Pesimista Ingenuo\n(Con Deadlocks)",
        "optimistic": "Optimista Versionado\n(MVCC Retries)"
    }

    for k in transfer_keys:
        if k in data:
            labels.append(label_map[k])
            p50_list.append(data[k]["p50_latency_ms"])
            p95_list.append(data[k]["p95_latency_ms"])
            p99_list.append(data[k]["p99_latency_ms"])

    if labels:
        x = np.arange(len(labels))
        width = 0.25

        fig, ax = plt.subplots(figsize=(10, 6))
        rects1 = ax.bar(x - width, p50_list, width, label='p50 (Mediana)', color='#2b5c8f')
        rects2 = ax.bar(x, p95_list, width, label='p95', color='#e27c3e')
        rects3 = ax.bar(x + width, p99_list, width, label='p99 (Percentil 99)', color='#d9383a')

        ax.set_ylabel('Latencia (milisegundos)', fontsize=12, fontweight='bold')
        ax.set_title('Comparativa de Percentiles de Latencia bajo Alta Concurrencia (Oracle DB 23ai)', fontsize=13, fontweight='bold', pad=15)
        ax.set_xticks(x)
        ax.set_xticklabels(labels, fontsize=11)
        ax.legend(fontsize=11)
        ax.grid(axis='y', linestyle='--', alpha=0.7)

        # Etiquetas de valores sobre barras
        for rects in [rects1, rects2, rects3]:
            for rect in rects:
                height = rect.get_height()
                ax.annotate(f'{height:.1f}',
                            xy=(rect.get_x() + rect.get_width() / 2, height),
                            xytext=(0, 3), textcoords="offset points",
                            ha='center', va='bottom', fontsize=9)

        plt.tight_layout()
        chart_latency_path = "benchmark/results/latency_comparison.png"
        plt.savefig(chart_latency_path, dpi=300)
        plt.close()
        print(f"[OK] Gráfica guardada: {chart_latency_path}")

    # 2. Comparativa de Throughput (TPS) y Confiabilidad Transaccional
    tps_labels = []
    tps_values = []
    deadlocks = []
    colors = []

    for k, item in data.items():
        if k == "pessimistic_ordered":
            tps_labels.append("Pesimista Ordenado")
            tps_values.append(item["tps"])
            deadlocks.append(item.get("deadlock_count", 0))
            colors.append('#27ae60')
        elif k == "pessimistic_naive":
            tps_labels.append("Pesimista Ingenuo")
            tps_values.append(item["tps"])
            deadlocks.append(item.get("deadlock_count", 0))
            colors.append('#c0392b')
        elif k == "optimistic":
            tps_labels.append("Optimista MVCC")
            tps_values.append(item["tps"])
            deadlocks.append(item.get("deadlock_count", 0))
            colors.append('#2980b9')
        elif k == "queue_skip_locked":
            tps_labels.append("Cola SKIP LOCKED")
            tps_values.append(item["tps"])
            deadlocks.append(0)
            colors.append('#8e44ad')

    if tps_labels:
        fig, ax = plt.subplots(figsize=(10, 6))
        bars = ax.bar(tps_labels, tps_values, color=colors, width=0.55)

        ax.set_ylabel('Throughput (Transacciones por Segundo - TPS)', fontsize=12, fontweight='bold')
        ax.set_title('Rendimiento Transaccional (TPS) por Estrategia de Concurrencia', fontsize=13, fontweight='bold', pad=15)
        ax.grid(axis='y', linestyle='--', alpha=0.7)

        for i, bar in enumerate(bars):
            height = bar.get_height()
            dl_text = f"\n[Deadlocks: {deadlocks[i]}]" if deadlocks[i] > 0 else ""
            ax.annotate(f'{height:.1f} TPS{dl_text}',
                        xy=(bar.get_x() + bar.get_width() / 2, height),
                        xytext=(0, 4), textcoords="offset points",
                        ha='center', va='bottom', fontsize=10, fontweight='bold')

        plt.tight_layout()
        chart_tps_path = "benchmark/results/throughput_comparison.png"
        plt.savefig(chart_tps_path, dpi=300)
        plt.close()
        print(f"[OK] Gráfica guardada: {chart_tps_path}")

if __name__ == "__main__":
    generate_charts()
