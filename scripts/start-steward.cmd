@echo off
rem Steward 24/7 : agent en boucle (execute) + dashboard local
cd /d "C:\Users\soufj\Desktop\Programme Créer\arc-treasury-agent"
set EXECUTE=1
set LOOP_MINUTES=15
start "steward-dashboard" /min cmd /c "node dashboard\server.mjs >> agent\dashboard.log 2>&1"
start "steward-oracle" /min cmd /c "node oracle\server.mjs >> agent\oracle.log 2>&1"
node agent\index.mjs >> agent\loop.log 2>&1
