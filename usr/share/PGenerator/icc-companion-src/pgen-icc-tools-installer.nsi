Unicode true
RequestExecutionLevel user
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "LogicLib.nsh"

Name "PGenerator+ ICC Tools"
OutFile "..\icc-companion\windows-x64\PGeneratorPlusICCSetup.exe"
InstallDir "$LOCALAPPDATA\PGenerator+\ICC Tools"
InstallDirRegKey HKCU "Software\PGenerator+\ICC Tools" "InstallDir"
BrandingText "PGenerator+"

VIProductVersion "1.0.0.0"
VIAddVersionKey "ProductName" "PGenerator+ ICC Tools"
VIAddVersionKey "FileDescription" "PGenerator+ ICC Companion and Profile Loader installer"
VIAddVersionKey "FileVersion" "1.0.0"
VIAddVersionKey "LegalCopyright" "GNU GPL"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\PGenProfileLoader.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Start PGenerator+ Profile Loader"
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\README.txt"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Show setup notes"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section "ICC Companion and Profile Loader" SEC_CORE
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "..\icc-companion\windows-x64\PGenICCCompanion.exe"
  File "..\icc-companion\windows-x64\PGenProfileLoader.exe"
  File "..\icc-companion\windows-x64\SDL3.dll"
  File /oname=README.txt "README.txt"
  File "PROFILE-LOADER-README.txt"
  File "..\icc-companion\SDL3-LICENSE.txt"

  IfFileExists "$EXEDIR\PGenICCCompanion.conf" 0 missing_config
    CopyFiles /SILENT "$EXEDIR\PGenICCCompanion.conf" "$INSTDIR\PGenICCCompanion.conf"
    Goto config_done
  missing_config:
    MessageBox MB_OK|MB_ICONEXCLAMATION "PGenICCCompanion.conf was not found beside the installer. The patch companion will try to discover PGenerator+ at pgenerator.local, but downloading a paired installer again is recommended."
  config_done:

  CreateDirectory "$SMPROGRAMS\PGenerator+"
  CreateShortcut "$SMPROGRAMS\PGenerator+\ICC Companion.lnk" "$INSTDIR\PGenICCCompanion.exe"
  CreateShortcut "$SMPROGRAMS\PGenerator+\Profile Loader.lnk" "$INSTDIR\PGenProfileLoader.exe"
  CreateShortcut "$SMPROGRAMS\PGenerator+\Uninstall ICC Tools.lnk" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\PGenerator+\ICC Tools" "InstallDir" "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Start Profile Loader with Windows" SEC_STARTUP
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" \
              "PGenerator+ Profile Loader" '"$INSTDIR\PGenProfileLoader.exe" --tray'
SectionEnd

LangString DESC_SEC_CORE ${LANG_ENGLISH} "Installs the paired patch companion and the tray profile loader."
LangString DESC_SEC_STARTUP ${LANG_ENGLISH} "Starts the profile loader at sign-in so it can verify and restore the selected display profile."
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_CORE} $(DESC_SEC_CORE)
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_STARTUP} $(DESC_SEC_STARTUP)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  ExecWait '"$SYSDIR\taskkill.exe" /IM PGenICCCompanion.exe /F'
  ExecWait '"$SYSDIR\taskkill.exe" /IM PGenProfileLoader.exe /F'
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "PGenerator+ Profile Loader"
  DeleteRegKey HKCU "Software\PGenerator+\ICC Tools"
  Delete "$SMPROGRAMS\PGenerator+\ICC Companion.lnk"
  Delete "$SMPROGRAMS\PGenerator+\Profile Loader.lnk"
  Delete "$SMPROGRAMS\PGenerator+\Uninstall ICC Tools.lnk"
  RMDir "$SMPROGRAMS\PGenerator+"
  Delete "$INSTDIR\PGenICCCompanion.exe"
  Delete "$INSTDIR\PGenProfileLoader.exe"
  Delete "$INSTDIR\SDL3.dll"
  Delete "$INSTDIR\PGenICCCompanion.conf"
  Delete "$INSTDIR\README.txt"
  Delete "$INSTDIR\PROFILE-LOADER-README.txt"
  Delete "$INSTDIR\SDL3-LICENSE.txt"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
SectionEnd
