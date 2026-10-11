#!/usr/bin/env bash
# =============================================================================
# RUN_ALL.SH: Script de Automatización Completa del Proyecto Bancario Oracle
# =============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  SISTEMA TRANSACCIONAL BANCARIO & OPTIMIZACIÓN CBO - ORACLE DB 23ai  ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# 1. Verificar Docker y levantar contenedor
echo -e "\n${YELLOW}[1/5] Verificando Contenedor de Oracle Database...${NC}"
docker-compose up -d

echo -e "${YELLOW}[*] Esperando a que Oracle Database esté completamente listo (OPEN READ WRITE)...${NC}"
until docker exec oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 <<< "SELECT 1 FROM DUAL;" > /dev/null 2>&1; do
    printf "."
    sleep 3
done
echo -e "\n${GREEN}[OK] Oracle Database 23ai Free está operativo y saludable.${NC}"

# 2. Despliegue de Esquema y Datos DDL
echo -e "\n${YELLOW}[2/5] Desplegando DDL y Semillas Masivas (10,000 cuentas)...${NC}"
docker exec -i oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 < database/02_schema_ddl.sql
docker exec -i oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 < database/03_seed_data.sql

# 3. Compilación de Packages PL/SQL y Triggers
echo -e "\n${YELLOW}[3/5] Compilando Package PKG_BANK_CORE y Compound Triggers...${NC}"
docker exec -i oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 < database/04_packages_spec.sql
docker exec -i oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 < database/05_packages_body.sql

# 4. Demostración de Tuning y EXPLAIN PLAN
echo -e "\n${YELLOW}[4/5] Ejecutando análisis de Tuning, Índices y CBO Plans...${NC}"
docker exec -i oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 < database/06_tuning_and_plans.sql

# 5. Benchmarking de Concurrencia y Generación de Gráficas
echo -e "\n${YELLOW}[5/5] Ejecutando Benchmarks de Concurrencia Multihilo en Python...${NC}"
if [ ! -d "benchmark/venv" ]; then
    echo "[*] Creando entorno virtual Python e instalando dependencias..."
    python3 -m venv benchmark/venv
    ./benchmark/venv/bin/pip install -r benchmark/requirements.txt
fi

./benchmark/venv/bin/python3 benchmark/stress_test.py --mode all --txs 300 --concurrency 25 --hotspots 8
./benchmark/venv/bin/python3 benchmark/generate_report.py

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}  [ÉXITO] PROYECTO EJECUTADO COMPLETAMENTE Y LISTO PARA PORTFOLIO/CV   ${NC}"
echo -e "${GREEN}  Reportes y Gráficas disponibles en: benchmark/results/              ${NC}"
echo -e "${GREEN}======================================================================${NC}"
