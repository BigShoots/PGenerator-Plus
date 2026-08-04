Unicode true
RequestExecutionLevel user
SetCompressor /SOLID lzma
CRCCheck off

!include "MUI2.nsh"
!include "LogicLib.nsh"

Name "PGenerator+ ICC Tools"
OutFile "..\icc-companion\windows-x64\PGeneratorPlusICCSetup.exe"
InstallDir "$LOCALAPPDATA\PGenerator+\ICC Tools"
InstallDirRegKey HKCU "Software\PGenerator+\ICC Tools" "InstallDir"
BrandingText "PGenerator+"

VIProductVersion "1.1.0.0"
VIAddVersionKey "ProductName" "PGenerator+ ICC Tools"
VIAddVersionKey "FileDescription" "PGenerator+ ICC Companion and Profile Loader installer"
VIAddVersionKey "FileVersion" "1.1.0"
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

  ; The Pi appends a fixed 512-byte pairing trailer to this installer at
  ; download time. Read it from our own executable so the user receives one
  ; self-contained setup file.
  FileOpen $0 "$EXEPATH" r
  IfErrors pairing_error
  FileSeek $0 -512 END
  IfErrors pairing_error
  FileRead $0 $1
  StrCpy $2 $1 15
  StrCmp $2 "PGEN_PAIRING_V1" 0 pairing_error
  FileRead $0 $3
  StrCpy $2 $3 7
  StrCmp $2 "SERVER=" 0 pairing_error
  FileRead $0 $4
  StrCpy $2 $4 6
  StrCmp $2 "TOKEN=" 0 pairing_error
  FileClose $0
  FileOpen $0 "$INSTDIR\PGenICCCompanion.conf" w
  IfErrors pairing_error
  FileWrite $0 "# Paired automatically by PGenerator+$\r$\n"
  FileWrite $0 $3
  FileWrite $0 $4
  FileClose $0
  Goto pairing_done
  pairing_error:
    FileClose $0
    MessageBox MB_OK|MB_ICONSTOP "This installer does not contain valid PGenerator+ pairing information. Download a new Windows installer directly from the ICC Profile workspace."
    Abort
  pairing_done:

  CreateDirectory "$SMPROGRAMS\PGenerator+"
  CreateShortcut "$SMPROGRAMS\PGenerator+\ICC Companion.lnk" "$INSTDIR\PGenICCCompanion.exe"
  CreateShortcut "$SMPROGRAMS\PGenerator+\Profile Loader.lnk" "$INSTDIR\PGenProfileLoader.exe"
  CreateShortcut "$SMPROGRAMS\PGenerator+\Uninstall ICC Tools.lnk" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\PGenerator+\ICC Tools" "InstallDir" "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; Register the per-user installation in Windows Settings > Apps > Installed
  ; apps and the legacy Programs and Features control panel.
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools" \
              "DisplayName" "PGenerator+ ICC Tools"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools" \
              "DisplayVersion" "1.1.0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools" \
              "Publisher" "PGenerator+"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools" \
              "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools" \
              "DisplayIcon" "$INSTDIR\PGenProfileLoader.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools" \
              "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools" \
              "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools" \
                "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools" \
                "NoRepair" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools" \
                "EstimatedSize" 6280
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
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PGeneratorPlusICCTools"
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
