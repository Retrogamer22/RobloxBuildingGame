@echo off
title PBR Texture Forge Server
echo.
echo   Starting PBR Texture Forge...
echo.
start http://localhost:8090
node "%~dp0server.js"
pause
