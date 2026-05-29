@echo off
:: run_tests.bat — Launch headless LibreOffice, run the integration tests,
::                 and clean up afterwards.
::
:: Usage:
::   run_tests.bat [pytest-args...]
::
:: Set NO_PAUSE=1 before calling to suppress the final pause
:: (useful in CI). When double-clicked the window stays open.
::
setlocal EnableDelayedExpansion

:: ── Resolve script directory and cd into it ──────────────────────────────
pushd "%~dp0"

set "LO_PORT=2002"
set "VENV_DIR=.venv"
set "SOFFICE_PID="
set "SOFFICE_CMD="
set "PYTHON_CMD="
set "TEST_EXIT=1"

:: ── Locate Python ────────────────────────────────────────────────────────

where python >nul 2>&1 && (
    set "PYTHON_CMD=python"
    goto :found_python
)
where py >nul 2>&1 && (
    set "PYTHON_CMD=py -3"
    goto :found_python
)
echo ERROR: Python is not installed or not on PATH.
echo Please install Python and ensure it is added to your PATH.
goto :cleanup

:found_python
echo Using Python: !PYTHON_CMD!

:: ── Locate soffice ───────────────────────────────────────────────────────

where soffice >nul 2>&1 && (
    set "SOFFICE_CMD=soffice"
    goto :found_soffice
)
if exist "C:\Program Files\LibreOffice\program\soffice.exe" (
    set "SOFFICE_CMD=C:\Program Files\LibreOffice\program\soffice.exe"
    goto :found_soffice
)
if exist "C:\Program Files (x86)\LibreOffice\program\soffice.exe" (
    set "SOFFICE_CMD=C:\Program Files (x86)\LibreOffice\program\soffice.exe"
    goto :found_soffice
)
echo ERROR: LibreOffice is not installed or not on PATH.
echo Please install LibreOffice or add its program directory to your PATH.
goto :cleanup

:found_soffice
echo Using soffice: !SOFFICE_CMD!

:: ── Kill any existing LO on the test port ────────────────────────────────

for /f "tokens=5" %%a in ('netstat -ano 2^>nul ^| findstr ":!LO_PORT! " ^| findstr "LISTENING"') do (
    echo Killing existing process on port !LO_PORT! ^(PID %%a^)...
    taskkill /PID %%a /F >nul 2>&1
)
timeout /t 2 /nobreak >nul

:: ── Set up the virtual environment ───────────────────────────────────────

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo Creating virtual environment with system site-packages ^(for UNO^)...
    !PYTHON_CMD! -m venv --system-site-packages "%VENV_DIR%"
    if !errorlevel! neq 0 (
        echo ERROR: Failed to create virtual environment.
        goto :cleanup
    )
)

echo Installing test dependencies...
"%VENV_DIR%\Scripts\pip.exe" install --quiet -r requirements.txt
if !errorlevel! neq 0 (
    echo ERROR: pip install failed.
    goto :cleanup
)

:: ── Launch LibreOffice headless ──────────────────────────────────────────

echo Starting LibreOffice Calc ^(headless^) on port %LO_PORT%...
start "" /B "!SOFFICE_CMD!" --headless --norestore --nologo --calc --accept="socket,host=localhost,port=%LO_PORT%;urp;"

:: Give it a moment to create the process
timeout /t 2 /nobreak >nul

:: ── Capture the soffice PID ──────────────────────────────────────────────
:: Try wmic first (available on most Windows 10, some Windows 11)
for /f "tokens=2 delims=," %%p in (
    'wmic process where "name='soffice.bin'" get ProcessId /format:csv 2^>nul ^| findstr /r "[0-9]"'
) do for /f "tokens=* delims= " %%q in ("%%p") do set "SOFFICE_PID=%%q"

:: Fallback to tasklist if wmic did not work or is unavailable
if not defined SOFFICE_PID (
    for /f "tokens=2 delims=:" %%p in (
        'tasklist /FI "IMAGENAME eq soffice.bin" /FO LIST 2^>nul ^| findstr /i "PID"'
    ) do for /f "tokens=* delims= " %%q in ("%%p") do set "SOFFICE_PID=%%q"
)

if defined SOFFICE_PID (
    echo LibreOffice PID: !SOFFICE_PID!
) else (
    echo WARNING: Could not determine LibreOffice PID. Cleanup may require manual intervention.
)

:: ── Wait until the UNO socket is accepting connections ───────────────────

set "LO_ATTEMPTS=0"
<nul set /p="Waiting for LibreOffice to be ready"

:wait_loop
set /a "LO_ATTEMPTS+=1"
if !LO_ATTEMPTS! gtr 30 (
    echo.
    echo ERROR: LibreOffice did not become ready in 30 seconds.
    goto :cleanup
)

"%VENV_DIR%\Scripts\python.exe" -c "import uno, sys; ctx = uno.getComponentContext(); r = ctx.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver', ctx); r.resolve('uno:socket,host=localhost,port=%LO_PORT%;urp;StarOffice.ComponentContext'); sys.exit(0)" 2>nul
if !errorlevel! equ 0 (
    echo  ready!
    goto :lo_ready
)

<nul set /p="."
timeout /t 1 /nobreak >nul
goto :wait_loop

:lo_ready

:: ── Quick sanity check ───────────────────────────────────────────────────

if defined SOFFICE_PID (
    tasklist /FI "PID eq !SOFFICE_PID!" 2>nul | findstr "!SOFFICE_PID!" >nul
    if !errorlevel! neq 0 (
        echo.
        echo ERROR: LibreOffice failed to start.
        goto :cleanup
    )
)

:: ── Run the tests ────────────────────────────────────────────────────────

echo.
echo -- Running integration tests ------------------------------------------
"%VENV_DIR%\Scripts\python.exe" -m pytest test_macros.py -v %*
set "TEST_EXIT=!errorlevel!"

:: ── Cleanup ──────────────────────────────────────────────────────────────

:cleanup
echo.
echo -- Cleaning up --------------------------------------------------------

:: Kill the LibreOffice process we started
if defined SOFFICE_PID (
    tasklist /FI "PID eq !SOFFICE_PID!" 2>nul | findstr "!SOFFICE_PID!" >nul
    if not errorlevel 1 (
        echo Stopping LibreOffice ^(PID !SOFFICE_PID!^)...
        taskkill /PID !SOFFICE_PID! /F >nul 2>&1
    )
)
:: Also kill any soffice.bin children that may have been spawned
taskkill /IM soffice.bin /F >nul 2>&1

:: Remove any lock files left over in the project directory
for %%f in (".~lock.*") do (
    if exist "%%f" (
        echo Removing lock file: %%f
        del /f /q "%%f" 2>nul
    )
)

popd
echo Done.

:: Pause for interactive (double-click) users; skip in CI
if not defined NO_PAUSE pause

endlocal & exit /b %TEST_EXIT%
