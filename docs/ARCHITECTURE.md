# Arquitectura Transaccional, Concurrencia y Garantías ACID en Oracle Database

Este documento profundiza en la ingeniería interna y los mecanismos a nivel de motor utilizados en este proyecto para garantizar alta disponibilidad transaccional, integridad de datos y latencias predecibles bajo contención extrema.

---

## 1. Modelo de Bloqueos y Encolamiento Interno de Oracle (TX Enqueues)

A diferencia de motores como SQL Server o MySQL con aislamiento estándar, Oracle Database **nunca bloquea a los lectores**.
* **Lecturas No Bloqueantes (MVCC):** Las consultas `SELECT` normales acceden a imágenes consistentes en el tiempo de los bloques de datos mediante el espacio de **UNDO Tablespace** utilizando el **SCN (System Change Number)**. Los lectores no adquieren bloqueos compartidos y no son bloqueados por transacciones escribiendo en las mismas filas.
* **Bloqueos a Nivel de Fila (TX Locks):** Cuando se ejecuta `SELECT ... FOR UPDATE` o sentencias `UPDATE`, Oracle adquiere un bloqueo exclusivo de transacción (*Transaction Enqueue* en modo 6 - Exclusive) directamente en la cabecera del bloque (*Interested Transaction List* o ITL) apuntando a la fila en cuestión.

---

## 2. Prevención Determinista de Deadlocks (`ORA-00060`)

Un *Deadlock* (bloqueo mutuo) ocurre cuando dos o más sesiones intentan adquirir recursos en un orden cruzado circular:
1. Sesión 1 bloquea Cuenta A y solicita bloqueo sobre Cuenta B.
2. Sesión 2 bloquea Cuenta B y solicita bloqueo sobre Cuenta A.

Oracle detecta esta condición mediante un **Wait-For Graph (WFG)** interno que se evalúa periódicamente (cada 3 segundos por defecto). Al detectar un ciclo, el proceso en segundo plano (LMD/DIAG) aborta una de las sentencias con la excepción `ORA-00060: deadlock detected while waiting for resource`.

### Solución Matemática Aplicada: Ordenamiento Canónico de Recursos
Para eliminar el deadlock en el diseño, se elimina la cuarta condición de Coffman (**espera circular**) imponiendo un orden total en la adquisición de bloqueos:

```sql
v_first_id  := LEAST(p_source_id, p_dest_id);
v_second_id := GREATEST(p_source_id, p_dest_id);

-- Siempre se bloquea la cuenta con menor ID primero
SELECT balance FROM ACCOUNTS WHERE account_id = v_first_id FOR UPDATE WAIT 5;
SELECT balance FROM ACCOUNTS WHERE account_id = v_second_id FOR UPDATE WAIT 5;
```

**Demostración:** Si la Sesión 1 transfiere de 10 a 50 y la Sesión 2 transfiere de 50 a 10:
* Ambas sesiones intentarán bloquear primero el ID menor (10).
* La sesión ganadora adquiere el bloqueo sobre 10; la segunda espera pasivamente.
* Al ser un orden estrictamente lineal, **es matemáticamente imposible generar una espera circular**.

---

## 3. Control de Concurrencia Optimista vs. Pesimista

| Característica | Bloqueo Pesimista (`FOR UPDATE`) | Bloqueo Optimista (`VERSION_ID`) |
| :--- | :--- | :--- |
| **Estrategia** | Asume alta contención y bloquea antes de operar. | Asume baja contención y valida al momento de escribir. |
| **Overhead de Bloqueo** | Adquiere y retiene locks de fila hasta el `COMMIT`. | Cero retención de locks durante la fase de lectura. |
| **Comportamiento en Colisión** | Las transacciones competidoras se encolan en espera (`WAIT`). | Falla inmediatamente (`SQL%ROWCOUNT = 0`) y reintenta con backoff. |
| **Escenario Ideal** | Cuentas bancarias de alto tráfico ("hotspots"), saldos compartidos. | Perfiles de usuario, carritos de compra, operaciones mayoritariamente disjuntas. |

### Implementación del Bloqueo Optimista con Backoff:
```sql
UPDATE ACCOUNTS
   SET balance = balance - p_amount,
       version_id = version_id + 1,
       updated_at = SYSTIMESTAMP
 WHERE account_id = p_source_id
   AND version_id = v_expected_version;

IF SQL%ROWCOUNT = 0 THEN
    -- Conflicto detectado: otra transacción actualizó la fila concurrentemente
    ROLLBACK;
    DBMS_SESSION.SLEEP(DBMS_RANDOM.VALUE(0.01, 0.05)); -- Backoff aleatorio
    -- Reintento
END IF;
```

---

## 4. Consumo de Colas de Alto Rendimiento con `SKIP LOCKED`

En arquitecturas distribuidas de pago, múltiples procesos trabajadores (*workers*) consumen tareas de una cola compartida. Si los workers usan `SELECT ... FOR UPDATE`, todos compiten por las primeras filas de la tabla, provocando una contención catastrófica.

Con la cláusula `FOR UPDATE SKIP LOCKED`:
```sql
CURSOR c_pending IS
    SELECT queue_id, source_account_id, dest_account_id, amount
      FROM PENDING_SETTLEMENT_QUEUE
     WHERE status = 'PENDING'
     ORDER BY queue_id
       FOR UPDATE SKIP LOCKED;
```
* Cada trabajador salta inmediatamente las filas que ya están siendo procesadas por otros trabajadores sin esperar.
* Esto permite **escalabilidad lineal**: a mayor número de cores/workers, mayor throughput global sin bloqueos.

---

## 5. Auditoría Independiente con `PRAGMA AUTONOMOUS_TRANSACTION`

En un sistema bancario, si una transferencia falla o es abortada por un intento de sobregiro o deadlock, es imperativo registrar el evento en el log de auditoría sin que el `ROLLBACK` de la transacción principal borre dicho registro.

La directiva `PRAGMA AUTONOMOUS_TRANSACTION` suspende temporalmente el contexto de la transacción principal, crea una subtransacción con su propio SCN y realiza su propio `COMMIT`:

```sql
PROCEDURE log_audit(...) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO SYSTEM_AUDIT_LOG (...) VALUES (...);
    COMMIT; -- Solo confirma el log de auditoría, la transacción padre continúa intacta
END;
```

---

## 6. Compound Triggers y la Prevención de `ORA-04091: Table is Mutating`

Cuando un trigger a nivel de fila (`FOR EACH ROW`) intenta consultar o modificar la misma tabla que disparó el evento, Oracle aborta la operación con `ORA-04091` para prevenir lecturas inconsistentes de una tabla en estado mutante.

El **Compound Trigger** resuelve esto proveyendo múltiples puntos de interrupción con un espacio de memoria común:
1. `BEFORE STATEMENT`: Inicializa estructuras de agregación en memoria.
2. `AFTER EACH ROW`: Acumula los deltas de saldo (`:NEW.balance - :OLD.balance`) en variables en memoria sin consultar la tabla.
3. `AFTER STATEMENT`: Aplica las consolidaciones acumuladas sobre la tabla agregada (`ACCOUNT_BALANCE_SNAPSHOT`) cuando la tabla principal ya no está en estado mutante.
