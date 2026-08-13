@echo off
rem Steward 24/7 : agent en boucle (execute) + dashboard local
cd /d "%~dp0.."
set EXECUTE=1
set LOOP_MINUTES=15
start "steward-dashboard" /b cmd /c "node dashboard\server.mjs >> agent\dashboard.log 2>&1"
start "steward-oracle" /b cmd /c "node oracle\server.mjs >> agent\oracle.log 2>&1"
node agent\index.mjs >> agent\loop.log 2>&1
