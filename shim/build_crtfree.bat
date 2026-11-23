@echo off
setlocal
call "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
cl /nologo /LD /O2 /GS- /GR- /DUNICODE /D_UNICODE /D_WIN32_WINNT=0x0601 tsbcryptprng.c /link /NODEFAULTLIB kernel32.lib /ENTRY:DllMain /SUBSYSTEM:WINDOWS,6.1 /MACHINE:X64 /OUT:tsbcryptprng_win_new.dll
exit /b %ERRORLEVEL%
