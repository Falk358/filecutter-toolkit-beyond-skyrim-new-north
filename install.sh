#! /bin/sh

clear

Libreoffice_macro_path=$HOME/.config/libreoffice/4/user/Scripts/python
Audacity_macro_path=$HOME/.audacity-data/Macros
Libreoffice_macro_file=Skyrim.py
Audacity_macro_file=Skyrim_Label.txt

echo "-----[ Filecutter Toolkit installer ]-----"
echo "."

echo "Checking for installation folders..."

if [ -d "$Libreoffice_macro_path" ]; then
  echo "$Libreoffice_macro_path found."
else
  echo "$Libreoffice_macro_path not found."
  echo  "Creating it now."
  mkdir -p $Libreoffice_macro_path
fi

if [ -d "$Audacity_macro_path" ]; then
  echo "$Audacity_macro_path found."
else
  echo "$Audacity_macro_path not found."
  echo  "Creating it now."
  mkdir -p $Audacity_macro_path
fi

echo "."


echo "Installing the Toolkit files..."
echo "Copying $Libreoffice_macro_file inside $Libreoffice_macro_path"
cp $Libreoffice_macro_file $Libreoffice_macro_path
echo "Copying Skyrim_Label.txt inside $Audacity_macro_path"
cp $Audacity_macro_file $Audacity_macro_path
echo "."

echo "The Filecutter Toolkit is now installed"
echo "."
echo "------------------------------------------"
echo "."

