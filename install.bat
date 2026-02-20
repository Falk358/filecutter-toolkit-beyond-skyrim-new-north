@echo off
cls

set "Libreoffice_macro_path=%APPDATA%\LibreOffice\4\user\Scripts\python\"
set "Audacity_macro_path=%APPDATA%\audacity\macros\"
set "Libreoffice_macro_file=Skyrim.py"
set "Audacity_macro_file=Skyrim_Label.txt"

echo -----[ Filecutter Toolkit installer ]-----
echo.

echo Checking for installation folders...

if exist "%Libreoffice_macro_path%" (
  echo [*] %Libreoffice_macro_path% found.
) else (
  echo [ ] %Libreoffice_macro_path% NOT found.
  echo    [*] Creating it now.
  mkdir %Libreoffice_macro_path%
)
if exist "%Audacity_macro_path%" (
  echo [*] %Audacity_macro_path% found.
) else (
  echo [ ] %Audacity_macro_path% NOT found.
  echo    [*] Creating it now.
  mkdir %Audacity_macro_path%
)
echo.


echo Installing the Toolkit files...
echo Copying %Libreoffice_macro_file% inside %Libreoffice_macro_path%
echo f | xcopy /s /y /f /q %Libreoffice_macro_file% %Libreoffice_macro_path%
echo Copying Skyrim_Label.txt inside %Audacity_macro_path%
echo f | xcopy /s /y /f /q %Audacity_macro_file% %Audacity_macro_path%
echo.

echo The Filecutter Toolkit is now installed
echo.
echo ------------------------------------------
echo.
endlocal
pause
