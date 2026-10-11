# Oracle High-Concurrency Banking Transaction Engine & Performance Tuning Suite

[![Oracle Database](https://img.shields.io/badge/Oracle_Database-23ai_Free-F80000?logo=oracle&logoColor=white)](https://www.oracle.com/database/)
[![PL/SQL](https://img.shields.io/badge/PL%2FSQL-Advanced_Engine_Logic-red)](https://docs.oracle.com/en/database/oracle/oracle-database/)
[![Python](https://img.shields.io/badge/Python-3.14-blue?logo=python&logoColor=white)](https://www.python.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

> **Simulación de un sistema financiero de alta concurrencia desarrollado directamente sobre el motor de Oracle Database 23ai.**  
> Diseñado para demostrar dominio avanzado de PL/SQL nativo, resolución matemática de *Deadlocks*, control de concurrencia pesimista vs. optimista, procesamiento de colas con `SKIP LOCKED`, y sintonización de consultas mediante planes de ejecución (`EXPLAIN PLAN`) y el Optimizador Basado en Costos (CBO).

---

## 🏛️ Arquitectura del Sistema

```
                                  [ Clientes Concurrentes ]
                              (100+ Threads en Python / oracledb)
                                               │
                        ┌──────────────────────┴──────────────────────┐
                        ▼                                             ▼
             [ Modo Transaccional ]                        [ Modo Cola Batch ]
                        │                                             │
      ┌─────────────────┴─────────────────┐               [ SKIP LOCKED Workers ]
      ▼                                   ▼                           │
[ Pesimista Ordenado ]           [ Optimista Versionado ]             │
  • LEAST/GREATEST (Anti-DL)       • VERSION_ID Check                 │
  • FOR UPDATE WAIT 5              • Backoff Exponencial              │
      │                                   │                           │
      └─────────────────┬─────────────────┘                           │
                        ▼                                             ▼
                 ┌────────────────────────────────────────────────────────┐
                 │                MOTOR ORACLE DATABASE 23ai              │
                 │                                                        │
                 │  • Package PKG_BANK_CORE (Lógica Modular Transaccional)│
                 │  • Compound Trigger (Evita ORA-04091 Mutating Table)   │
                 │  • PRAGMA AUTONOMOUS_TRANSACTION (Auditoría Persistente│
                 │  • PRAGMA UDF & DETERMINISTIC (Optimización CBO)       │
                 │  • Índices Compuestos y Function-Based (Reducción I/O) │
                 └────────────────────────────────────────────────────────┘
```

---

## ⚡ Pilares Técnicos Implementados

### 1. Lógica Nativa en el Motor (PL/SQL Avanzado)
* **`PKG_BANK_CORE`:** Encapsula toda la lógica de negocio y transaccionalidad dentro del motor, minimizando el salto de red y cambio de contexto (*context switching*).
* **Transacciones Autónomas (`PRAGMA AUTONOMOUS_TRANSACTION`):** Si una transferencia falla por saldo insuficiente o tiempo de espera, se revierte con `ROLLBACK`, pero el evento se registra de forma persistente e inalterable en `SYSTEM_AUDIT_LOG`.
* **Funciones Deterministas con `PRAGMA UDF`:** La función `fn_calculate_tier` informa al CBO que puede precalcular y almacenar en caché el resultado para queries SQL masivas.
* **Compound Trigger Anti-Mutating (`TRG_ACCOUNTS_SNAPSHOT_MAINTAINER`):** Mantiene una tabla agregada de liquidez en tiempo real acumulando deltas en memoria durante las fases de fila (`AFTER EACH ROW`) y consolidando en `AFTER STATEMENT`, **previniendo el error `ORA-04091: table is mutating`**.

---

### 2. Concurrencia, ACID y Prevención de Deadlocks
* **Pesimista con Ordenamiento Canónico (Anti-Deadlock):**
  Al transferir entre dos cuentas, el motor siempre adquiere los bloqueos exclusivos (`FOR UPDATE`) ordenando los IDs:
  $$\text{Lock}_1 = \min(\text{ID}_A, \text{ID}_B), \quad \text{Lock}_2 = \max(\text{ID}_A, \text{ID}_B)$$
  Esto rompe formalmente la condición de **espera circular de Coffman**, garantizando **0 Deadlocks (`ORA-00060`)** bajo contención extrema.
* **Pesimista Ingenuo (Simulador de Colisión):**
  Adquiere bloqueos en orden de llegada. En transferencias cruzadas ($A \rightarrow B$ y $B \rightarrow A$ simultáneas), reproduce y captura `ORA-00060 Deadlock detected`.
* **Optimista por Control de Versión (`VERSION_ID`):**
  Lecturas consistentes no bloqueantes (MVCC). Las actualizaciones condicionan `WHERE version_id = :expected_ver`. Ante colisión, detecta `SQL%ROWCOUNT = 0`, aplica *exponential backoff* aleatorio y reintenta.
* **Colas de Alta Capacidad con `SKIP LOCKED`:**
  Procesamiento en lote donde múltiples *workers* consumen tareas de `PENDING_SETTLEMENT_QUEUE` sin esperar ni bloquearse entre sí, logrando rendimiento lineal.

---

### 3. Tuning de Base de Datos y Optimizador Basado en Costos (CBO)
* **Function-Based Indexes (FBI):** Creación de `IDX_ACC_FBI_EMAIL` sobre `UPPER(holder_email)`. Reduce el costo del CBO de **68 a 2** (**97% de reducción en I/O**), transformando un Full Table Scan en un `INDEX RANGE SCAN`.
* **Índice Compuesto Estratégico:** Creación de `IDX_TX_COMP_SRC_STATUS_DT` sobre `(source_account_id, status, created_at DESC)`. Cumple la regla de cardinalidad (*leading column*) y **elimina por completo el paso `SORT ORDER BY` en memoria PGA**.

---

## 📊 Resultados de Benchmarks de Estrés

Ejecutados con conexión nativa multihilo (`python-oracledb`) sobre **Oracle Database 23ai**:

| Estrategia de Concurrencia | Concurrencia (Hilos) | Throughput (TPS) | Tasa de Éxito | Deadlocks (`ORA-60`) | Latencia p50 | Latencia p95 | Latencia p99 |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Pesimista Ordenado (Anti-DL)** | **25** | **413.8 tx/s** | **100.0%** | **0** | **50.3 ms** | **122.5 ms** | **142.3 ms** |
| **Pesimista Ingenuo** | 20 | Variable | Fallos por colisión | **Generados activamente** | Alto | Alto | Alto |
| **Optimista Versionado** | 25 | ~200 tx/s | Resuelto con retries | **0** | Con backoff | Con backoff | Con backoff |
| **Cola SKIP LOCKED (Batch)** | 8 Workers | **> 1,000 items/s** | **100.0%** | **0** | **< 10 ms** | **< 25 ms** | **< 40 ms** |

*(Gráficas visuales generadas automáticamente en `benchmark/results/`)*

---

## 🚀 Guía de Despliegue Rápido

### Requisitos
* Docker y Docker Compose
* Python 3.10+

### 1. Levantar Oracle Database en Docker
```bash
docker-compose up -d
```
El contenedor inicializará Oracle 23ai Free en el puerto `1521` con la base de datos `FREEPDB1`.

### 2. Desplegar Esquema, Packages y Semillas
```bash
# Crear esquema DDL e invariantes
docker exec -i oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 < database/02_schema_ddl.sql

# Sembrar 10,000 cuentas bancarias y recolectar estadísticas CBO
docker exec -i oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 < database/03_seed_data.sql

# Compilar Especificación y Cuerpo del Package PL/SQL + Triggers
docker exec -i oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 < database/04_packages_spec.sql
docker exec -i oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 < database/05_packages_body.sql

# Ejecutar análisis de Tuning y Planes de Ejecución
docker exec -i oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 < database/06_tuning_and_plans.sql
```

### 3. Ejecutar la Suite de Estrés y Benchmarking
```bash
# Activar entorno virtual
source benchmark/venv/bin/activate

# Ejecutar benchmark completo
python benchmark/stress_test.py --mode all --txs 300 --concurrency 25 --hotspots 8

# Generar gráficas comparativas PNG
python benchmark/generate_report.py
```

---

## 📁 Estructura del Repositorio

```text
.
├── docker-compose.yml              # Orquestación de Oracle Database 23ai Free
├── README.md                       # Documentación principal del proyecto
├── database/                       # Scripts SQL y PL/SQL nativos
│   ├── 01_setup_user.sql           # Configuración de roles y privilegios de sistema
│   ├── 02_schema_ddl.sql           # Tablas, constraints, checks e invariantes ACID
│   ├── 03_seed_data.sql            # Ingesta masiva FORALL de 10,000 cuentas y CBO stats
│   ├── 04_packages_spec.sql        # Especificación del Package PKG_BANK_CORE
│   ├── 05_packages_body.sql        # Implementación de bloqueos, triggers y UDF
│   └── 06_tuning_and_plans.sql     # Demostración de EXPLAIN PLAN y análisis de I/O
├── benchmark/                      # Suite de estrés y análisis de rendimiento
│   ├── requirements.txt            # Dependencias Python (oracledb, matplotlib, pandas)
│   ├── stress_test.py              # Runner multihilo de contención extrema
│   ├── generate_report.py          # Generador de gráficos de latencia y throughput
│   └── results/                    # Gráficas PNG y resumen JSON
└── docs/                           # Documentación de ingeniería en profundidad
    ├── ARCHITECTURE.md             # Detalles de bajo nivel: TX locks, ITL, MVCC y ACID
    └── TUNING_GUIDE.md             # Guía CBO: Planes de ejecución, FBI y Cost I/O
```

---

## 👨‍💻 Autor
Proyecto diseñado y desarrollado para demostrar capacidades avanzadas en **RDBMS, PL/SQL, Exadata y Database Cloud Services**.
