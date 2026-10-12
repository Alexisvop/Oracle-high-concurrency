# Guía de Defensa Técnica para Entrevistas (Interview Defense Guide)
### Especialidad: RDBMS, PL/SQL, Exadata & Cloud Database Services

Este documento contiene las preguntas técnicas más complejas que un Tech Lead, Arquitecto de Base de Datos o Hiring Manager de empresas como **Oracle, AWS Database Services, Exadata Core Teams o Fintechs Tier-1** formulará sobre este proyecto, junto con la respuesta técnica exacta y fundamentada en los mecanismos internos del motor.

---

## 1. Arquitectura Transaccional y Lógica en el Motor

### P1: ¿Por qué decidiste encapsular la lógica de negocio en Packages PL/SQL en lugar de programarla en el Backend (Python, Java o Go)?
> **Respuesta Clave:**
> "Por tres razones críticas: **Reducción de Latencia de Red (RTT), eliminación del Context Switching y Atomicidad Garantizada**. 
> Si la lógica corre en el backend, una transferencia bancaria requiere múltiples viajes de red (RTT): `SELECT`, validación en aplicación, `UPDATE` débito, `UPDATE` crédito y `COMMIT`. Cada salto añade entre 1 y 5 ms de latencia física. 
> Al encapsularlo en `PKG_BANK_CORE` dentro de la SGA de Oracle:
> 1. La transacción se resuelve localmente en memoria sin saltos de red adicionales.
> 2. Se minimiza el cambio de contexto (*Context Switching*) entre el motor SQL y el motor PL/SQL.
> 3. El motor garantiza que las operaciones DML ocurren bajo un único límite transaccional atómico."

---

## 2. Concurrencia, ACID y Bloqueos Internos

### P2: ¿Cómo demostraste formalmente la prevención de Deadlocks (`ORA-00060`)?
> **Respuesta Clave:**
> "Basándome en las **4 Condiciones de Coffman** necesarias para que ocurra un deadlock:
> 1. Exclusión mutua (locks de fila exclusivos).
> 2. Retención y espera (*Hold and Wait*).
> 3. No apropiación (*No Preemption*).
> 4. **Espera circular (*Circular Wait*)**.
> 
> En transferencias bancarias cruzadas (Cliente A envía a B y B envía a A al mismo tiempo), la espera circular ocurre si la Sesión 1 bloquea A y espera B, mientras la Sesión 2 bloquea B y espera A.
> Para erradicar matemáticamente la condición 4, implementé una **relación de orden total estricto**:
> ```sql
> v_first_id  := LEAST(p_source_id, p_dest_id);
> v_second_id := GREATEST(p_source_id, p_dest_id);
> SELECT ... FROM ACCOUNTS WHERE account_id = v_first_id FOR UPDATE WAIT 5;
> SELECT ... FROM ACCOUNTS WHERE account_id = v_second_id FOR UPDATE WAIT 5;
> ```
> Al forzar que toda sesión adquiera el bloqueo de la cuenta con menor ID primero, **es matemáticamente imposible formar un ciclo en el Grafo de Espera (*Wait-For Graph*) de Oracle**. En nuestros benchmarks con 20 hilos sobre cuentas críticas, el número de `ORA-00060` fue estrictamente **0**."

---

### P3: ¿Cuál es la diferencia técnica entre `ORA-00054` y `ORA-00060`?
> **Respuesta Clave:**
> "* `ORA-00054: resource busy and acquire with NOWAIT specified or timeout expired`: Es un fallo por **tiempo de espera excedido**. Una sesión intentó adquirir un bloqueo de fila con `NOWAIT` o con `WAIT n`, y el recurso ya estaba retenido por otra transacción. Es un mecanismo de protección contra esperas indefinidas, no un bloqueo mutuo.
> * `ORA-00060: deadlock detected while waiting for resource`: Es un **bloqueo mutuo circular**. El proceso de fondo de Oracle (LMD/DIAG) analizó el *Wait-For Graph*, detectó una espera circular irresoluble y abortó una de las dos sentencias con rollback a nivel de sentencia para romper el ciclo."

---

### P4: ¿Por qué en la estrategia de bloqueo optimista también se debe respetar el orden canónico de IDs en la fase de escritura?
> **Respuesta Clave:**
> "Porque en cualquier base de datos relacional compatible con ACID, **la sentencia `UPDATE` adquiere físicamente un bloqueo exclusivo de fila (TX Enqueue en Modo 6)**.
> Aunque la lectura inicial sea optimista (no bloqueante vía MVCC con `VERSION_ID`), cuando llega el momento de aplicar las escrituras a las dos cuentas:
> Si la Transacción 1 actualiza Cuenta A y luego Cuenta B, y la Transacción 2 actualiza Cuenta B y luego Cuenta A, ambas adquieren el lock exclusivo del primer registro y se bloquean mutuamente en el segundo `UPDATE`.
> Por lo tanto, incluso en esquemas optimistas de múltiples recursos, **la fase de escritura debe ejecutarse en orden canónico (`LEAST` y luego `GREATEST`)** para prevenir colisiones a nivel de motor."

---

### P5: ¿Qué ventaja ofrece `FOR UPDATE SKIP LOCKED` frente a un `SELECT ... FOR UPDATE` ordinario?
> **Respuesta Clave:**
> "En procesamiento de colas y liquidaciones masivas por lotes (*batch settlement*), si 10 workers concurrentes ejecutan `SELECT ... FOR UPDATE`, todos intentan bloquear las primeras filas de la tabla, provocando una contención catastrófica donde 9 workers quedan esperando pasivamente (*thread starvation*).
> Con `SKIP LOCKED`, Oracle instruye al motor a **saltarse de forma transparente cualquier fila que ya tenga un lock exclusivo activo**. Cada worker adquiere inmediatamente un subconjunto disjunto de tareas sin esperar ni bloquearse entre sí, logrando **escalabilidad lineal y cero contención**."

---

## 3. Disparadores y Transacciones Autónomas

### P6: ¿Por qué utilizaste un `COMPOUND TRIGGER` y qué problema resuelve?
> **Respuesta Clave:**
> "Resuelve el infame error `ORA-04091: table ACCOUNTS is mutating`.
> En triggers tradicionales a nivel de fila (`AFTER EACH ROW`), Oracle prohíbe que el trigger consulte o agregue la misma tabla que disparó el evento DML para prevenir lecturas inconsistentes (*mutating table*).
> Un **Compound Trigger** resuelve esto proveyendo múltiples puntos de interrupción con un espacio de memoria común:
> 1. `BEFORE STATEMENT`: Inicializa acumuladores en memoria.
> 2. `AFTER EACH ROW`: Acumula los deltas de saldo (`:NEW.balance - :OLD.balance`) en variables de memoria sin consultar la tabla.
> 3. `AFTER STATEMENT`: Una vez que la tabla ya no está en estado mutante, aplica la consolidación atómica sobre `ACCOUNT_BALANCE_SNAPSHOT`."

---

### P7: ¿Qué ocurre a nivel de SCN (*System Change Number*) con `PRAGMA AUTONOMOUS_TRANSACTION`?
> **Respuesta Clave:**
> "La directiva `PRAGMA AUTONOMOUS_TRANSACTION` bifurca el contexto transaccional:
> 1. Suspende temporalmente la transacción principal del usuario.
> 2. Crea un bloque transaccional completamente independiente con su propio SCN (*System Change Number*), buffers de Redo y segmentos de Undo.
> 3. Emite un `COMMIT` que consolida exclusivamente el log de auditoría (`SYSTEM_AUDIT_LOG`).
> 4. Reanuda la transacción principal.
> Esto garantiza que si la transferencia bancaria falla por saldo insuficiente o tiempo de espera y hace `ROLLBACK`, **el registro del intento en la auditoría persiste de forma inmutable**."

---

## 4. Tuning, Índices y Optimizador Basado en Costos (CBO)

### P8: ¿Cómo evalúa el CBO de Oracle el costo de una consulta y por qué un Function-Based Index (FBI) redujo el costo de 68 a 2?
> **Respuesta Clave:**
> "El CBO calcula el costo estimado como una ponderación de I/O blocks leídos más ciclos de CPU:
> $$\text{Cost} = \text{I/O Cost} + (\text{CPU Cost} \times \text{Factor})$$
> Cuando una consulta utiliza una expresión como `WHERE UPPER(holder_email) = :valor`, el optimizador **no puede utilizar un índice B-Tree estándar** sobre `holder_email` porque la función transforma el valor antes de la comparación, forzando un costoso **Full Table Scan (FTS)** que lee todos los bloques de la tabla (Costo = 68).
> Al crear el **Function-Based Index**:
> ```sql
> CREATE INDEX idx_acc_fbi_email ON ACCOUNTS(UPPER(holder_email));
> ```
> Oracle precalcula la función durante las operaciones DML, almacena el resultado en las hojas del índice B-Tree y crea una columna virtual con estadísticas en el diccionario. En la consulta, el optimizador transforma el predicado `filter` en un predicado `access` directo de árbol B (`INDEX RANGE SCAN`), reduciendo los accesos a disco de 68 a 2 bloques (**97% de reducción de I/O**)."

---

### P9: ¿Cómo elimina el Índice Compuesto la operación `SORT ORDER BY` en memoria PGA?
> **Respuesta Clave:**
> "Creamos el índice compuesto con el orden:
> ```sql
> CREATE INDEX idx_tx_comp_src_status_dt 
> ON TRANSACTIONS_LOG(source_account_id, status, created_at DESC);
> ```
> 1. **Leading Column:** `source_account_id` tiene alta cardinalidad (muchos valores distintos), satisfaciendo la regla de selectividad de primera columna.
> 2. **Segunda Columna:** `status` resuelve la condición de igualdad.
> 3. **Orden Físico:** Al indexar `created_at DESC`, los punteros de fila (`ROWIDs`) ya están físicamente ordenados en las hojas del árbol B.
> Cuando la consulta ejecuta `ORDER BY created_at DESC`, el optimizador reconoce que el índice ya entrega las filas en el orden solicitado, **eliminando la operación `SORT ORDER BY`**, lo que ahorra alocación de memoria en el área de ordenamiento de la PGA (*Program Global Area*) y previene desbordamientos de ordenamiento hacia el Tablespace temporal (`TEMP`)."

---

### P10: ¿Qué es el evento de espera `enq: TX - allocate ITL entry` y cómo se soluciona en bloques de 8KB?
> **Respuesta Clave:**
> "Cada bloque de datos de Oracle (típicamente de 8KB) posee una cabecera llamada **Interested Transaction List (ITL)**, configurada por el parámetro `INITRANS` (que por defecto es 1 o 2).
> Si múltiples transacciones concurrentes intentan actualizar filas diferentes pero que residen dentro del **mismo bloque físico de 8KB**, cada transacción debe obtener una entrada en la lista ITL de esa cabecera.
> Si la lista se satura y no hay espacio disponible en el bloque para expandirla dinámicamente, las sesiones se encolan con el evento de espera **`enq: TX - allocate ITL entry`**.
> **Solución técnica aplicada:**
> 1. Configurar `ALTER TABLE ... INITRANS 30;` para prealocar ranuras de transacción en la cabecera de cada bloque.
> 2. Distribuir las cuentas críticas entre múltiples bloques físicos o mediante *Hash Partitioning*."
