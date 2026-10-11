# Guía de Optimización de Rendimiento y Tuning en Oracle Database

Este documento documenta las técnicas de tuning de base de datos implementadas en el proyecto, analizando cómo el **Cost-Based Optimizer (CBO)** evalúa consultas y cómo la indexación estratégica reduce el consumo de I/O y CPU.

---

## 1. El Optimizador Basado en Costos (CBO)

El CBO de Oracle determina la ruta de ejecución más eficiente (*Execution Plan*) calculando una función de costo estimada en función de:
$$\text{Cost} = \text{I/O Cost} + (\text{CPU Cost} \times \text{Factor de Ponderación})$$

Donde el I/O Cost se traduce en el número estimado de bloques de disco que el motor debe leer del búfer de datos (`Buffer Cache`) o del almacenamiento físico (`Direct Path Reads`).

Las estadísticas del CBO se recolectan con:
```sql
EXEC DBMS_STATS.GATHER_TABLE_STATS(
    ownname          => USER,
    tabname          => 'ACCOUNTS',
    estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
    method_opt       => 'FOR ALL COLUMNS SIZE AUTO',
    cascade          => TRUE
);
```

---

## 2. Caso 1: Búsquedas con Transformación y Function-Based Indexes (FBI)

### Problema
Una consulta clásica de autenticación o búsqueda de usuario evalúa correos sin distinguir mayúsculas de minúsculas:
```sql
SELECT account_id, holder_name, balance 
  FROM ACCOUNTS 
 WHERE UPPER(holder_email) = 'CLIENTE.500@BANCO-DEMO.COM';
```
Incluso si existe un índice normal sobre `holder_email`, el uso de la función `UPPER()` sobre la columna hace que el optimizador ignore el índice estándar, forzando un **Full Table Scan (FTS)**.

### Plan de Ejecución ANTES (FTS):
```text
------------------------------------------------------------------------------
| Id  | Operation         | Name     | Rows  | Bytes | Cost (%CPU)| Time     |
------------------------------------------------------------------------------
|   0 | SELECT STATEMENT  |          |   100 |  6000 |     68  (0)| 00:00:01 |
|*  1 |  TABLE ACCESS FULL| ACCOUNTS |   100 |  6000 |     68  (0)| 00:00:01 |
------------------------------------------------------------------------------
Predicate Information:
   1 - filter(UPPER("HOLDER_EMAIL")='CLIENTE.500@BANCO-DEMO.COM')
```
* **Costo CBO:** 68
* **I/O Operación:** Lectura secuencial de cada bloque de la tabla (`filter` tardío).

### Solución: Índice Basado en Funciones
```sql
CREATE INDEX idx_acc_fbi_email ON ACCOUNTS(UPPER(holder_email));
```
Oracle almacena en el índice el resultado precomputado de la función y genera internamente una columna virtual en las estadísticas.

### Plan de Ejecución DESPUÉS (FBI):
```text
---------------------------------------------------------------------------------------------------------
| Id  | Operation                            | Name              | Rows  | Bytes | Cost (%CPU)| Time     |
---------------------------------------------------------------------------------------------------------
|   0 | SELECT STATEMENT                     |                   |     1 |    60 |      2  (0)| 00:00:01 |
|   1 |  TABLE ACCESS BY INDEX ROWID BATCHED | ACCOUNTS          |     1 |    60 |      2  (0)| 00:00:01 |
|*  2 |   INDEX RANGE SCAN                   | IDX_ACC_FBI_EMAIL |     1 |       |      1  (0)| 00:00:01 |
---------------------------------------------------------------------------------------------------------
Predicate Information:
   2 - access(UPPER("HOLDER_EMAIL")='CLIENTE.500@BANCO-DEMO.COM')
```
* **Costo CBO:** Se reduce de **68 a 2** (**97% de reducción de costo de I/O**).
* **Tipo de Acceso:** Pasa de `filter` a `access` directo por árbol B.

---

## 3. Caso 2: Índice Compuesto y Eliminación de Ordenamientos en Memoria (`SORT ORDER BY`)

### Consulta:
```sql
SELECT transaction_id, amount, created_at
  FROM TRANSACTIONS_LOG
 WHERE source_account_id = 1
   AND status = 'COMMITTED'
 ORDER BY created_at DESC;
```

### Sin Índice Compuesto:
El motor debe hacer un Full Table Scan y luego alocar memoria en la PGA (*Program Global Area*) para ordenar los resultados en memoria (`SORT ORDER BY`):
```text
---------------------------------------------------------------------------------------
| Id  | Operation          | Name             | Rows  | Bytes | Cost (%CPU)| Time     |
---------------------------------------------------------------------------------------
|   0 | SELECT STATEMENT   |                  |     1 |    64 |      4 (25)| 00:00:01 |
|   1 |  SORT ORDER BY     |                  |     1 |    64 |      4 (25)| 00:00:01 |
|*  2 |   TABLE ACCESS FULL| TRANSACTIONS_LOG |     1 |    64 |      3  (0)| 00:00:01 |
---------------------------------------------------------------------------------------
```

### Solución: Índice Compuesto Estratégico
```sql
CREATE INDEX idx_tx_comp_src_status_dt 
ON TRANSACTIONS_LOG(source_account_id, status, created_at DESC);
```
**Reglas de diseño aplicadas:**
1. **Regla de Mayor Selectividad (Leading Column):** `source_account_id` tiene alta cardinalidad (muchos valores distintos), por lo que va en la primera posición.
2. **Columnas de Igualdad:** `status` va a continuación para completar la llave de filtrado exacta.
3. **Ordenamiento Pre-ordenado:** Al definir `created_at DESC` directamente en las hojas del índice, los datos ya están en el orden requerido.

### Plan de Ejecución con Índice Compuesto:
```text
---------------------------------------------------------------------------------------------------------
| Id  | Operation                   | Name                      | Rows  | Bytes | Cost (%CPU)| Time     |
---------------------------------------------------------------------------------------------------------
|   0 | SELECT STATEMENT            |                           |     1 |    31 |      2  (0)| 00:00:01 |
|   1 |  TABLE ACCESS BY INDEX ROWID| TRANSACTIONS_LOG          |     1 |    31 |      2  (0)| 00:00:01 |
|*  2 |   INDEX RANGE SCAN          | IDX_TX_COMP_SRC_STATUS_DT |     1 |       |      1  (0)| 00:00:01 |
---------------------------------------------------------------------------------------------------------
```
* **Resultado:** La operación `SORT ORDER BY` desaparece por completo del plan, liberando ciclos de CPU y consumo de PGA.

---

## 4. Caso 3: Indexación de Funciones Deterministas PL/SQL

Oracle permite indexar funciones personalizadas desarrolladas en PL/SQL, siempre y cuando se declaren como `DETERMINISTIC`:

```sql
CREATE INDEX idx_acc_fbi_tier ON ACCOUNTS(PKG_BANK_CORE.fn_calculate_tier(balance));
```
Al indexar la función determinista, las consultas que agrupan o filtran por niveles de cliente (`TIER`) consultan directamente las hojas del índice sin necesidad de invocar repetidamente la función PL/SQL para cada fila en la tabla.
