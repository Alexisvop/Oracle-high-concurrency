#!/usr/bin/env bash
# =============================================================================
# RUN_GUI.SH: Inicia el Dashboard Gráfico Web de Oracle Banking Engine
# =============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}  INTERFAZ GRÁFICA / DASHBOARD - ORACLE BANKING TRANSACTION ENGINE   ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# 1. Verificar Docker y Oracle DB
echo -e "\n${YELLOW}[1/3] Verificando contenedor Oracle Database 23ai Free...${NC}"
docker-compose up -d

echo -e "${YELLOW}[*] Comprobando disponibilidad del servicio en puerto 1521...${NC}"
until docker exec oracle-bank-db sqlplus -s BANK_USER/BankUserPassword123#@localhost:1521/FREEPDB1 <<< "SELECT 1 FROM DUAL;" > /dev/null 2>&1; do
    printf "."
    sleep 3
done
echo -e "\n${GREEN}[OK] Oracle Database 23ai Free está en línea y conectado.${NC}"

# 2. Verificar dependencias de Python
echo -e "\n${YELLOW}[2/3] Verificando dependencias del dashboard...${NC}"
if [ ! -d "benchmark/venv" ]; then
    echo "[*] Creando entorno virtual..."
    python3 -m venv benchmark/venv
    ./benchmark/venv/bin/pip install -r benchmark/requirements.txt
fi

# 3. Lanzar la aplicación Web
PORT=5000
URL="http://localhost:${PORT}"
echo -e "\n${GREEN}[3/3] Iniciando servidor Web en ${URL}${NC}"
echo -e "${BLUE}Abriendo navegador predeterminado...${NC}"

# Intentar abrir el navegador en segundo plano tras 1 segundo
(sleep 1.5 && (xdg-open "$URL" > /dev/null 2>&1 || python3 -m webbrowser "$URL" > /dev/null 2>&1 || true)) &

echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}  Dashboard disponible en: ${URL}                                     ${NC}"
echo -e "${GREEN}  Presiona [Ctrl+C] en esta terminal para detener el servidor web.    ${NC}"
echo -e "${GREEN}======================================================================${NC}\n"

./benchmark/venv/bin/python3 ui/app.py
