@echo off
title Instalador AutoCatch PKA
color 0A

where python >nul 2>nul
if %errorlevel% neq 0 (
    color 0C
    echo [ERRO] Python 3 nao foi encontrado no PATH.
    echo Instale Python 3 ou execute: py -3 "%~dp0patch_notebook.py"
    echo.
    pause
    exit /b 1
)

python "%~dp0patch_notebook.py" %*
set RESULT=%errorlevel%
echo.
if not "%RESULT%"=="0" pause
exit /b %RESULT%
