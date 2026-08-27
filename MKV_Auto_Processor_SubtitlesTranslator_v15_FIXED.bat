@echo off
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0MKV_Auto_Processor_SubtitlesTranslator_v15_FIXED.ps1"
if errorlevel 1 pause
