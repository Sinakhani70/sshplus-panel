; CK Client installer (NSIS). Build: makensis installer/ck-client.nsi  (run from ck-client/)
Unicode true
!define APP "CK Client"
!define VERSION "1.0.0"
!define UNKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\CKClient"

Name "${APP}"
OutFile "..\dist\CK-Client-Setup.exe"
RequestExecutionLevel admin
InstallDir "$PROGRAMFILES64\${APP}"
InstallDirRegKey HKLM "Software\CKClient" "InstallDir"
SetCompressor /SOLID lzma
BrandingText "${APP} ${VERSION}"

!include "MUI2.nsh"
!include "x64.nsh"

!define MUI_ICON "..\assets\ck.ico"
!define MUI_UNICON "..\assets\ck.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\ck-client.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch ${APP}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "Farsi"

VIProductVersion "1.0.0.0"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "${APP} installer"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "${APP} needs 64-bit Windows."
    Abort
  ${EndIf}
  SetRegView 64
  ; refuse a path that would make uninstall dangerous (drive root)
FunctionEnd

Function .onVerifyInstDir
  StrLen $0 $INSTDIR
  IntCmp $0 3 0 +2 +2
    Abort
FunctionEnd

Section "${APP} (required)" SecMain
  SectionIn RO
  SetRegView 64
  SetOutPath "$INSTDIR"
  nsExec::Exec 'taskkill /F /IM ck-client.exe'
  Sleep 500
  File "..\dist\ck-client.exe"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  WriteRegStr HKLM "Software\CKClient" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${UNKEY}" "DisplayName" "${APP}"
  WriteRegStr HKLM "${UNKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNKEY}" "Publisher" "CK Producer"
  WriteRegStr HKLM "${UNKEY}" "DisplayIcon" "$INSTDIR\ck-client.exe"
  WriteRegStr HKLM "${UNKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKLM "${UNKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNKEY}" "NoRepair" 1

  CreateDirectory "$SMPROGRAMS\${APP}"
  CreateShortcut "$SMPROGRAMS\${APP}\${APP}.lnk" "$INSTDIR\ck-client.exe"
  CreateShortcut "$SMPROGRAMS\${APP}\Uninstall ${APP}.lnk" "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Desktop shortcut" SecDesktop
  CreateShortcut "$DESKTOP\${APP}.lnk" "$INSTDIR\ck-client.exe"
SectionEnd

LangString DESC_Main ${LANG_ENGLISH} "The application files."
LangString DESC_Main ${LANG_FARSI} "فایل‌های برنامه."
LangString DESC_Desk ${LANG_ENGLISH} "Create a shortcut on the desktop."
LangString DESC_Desk ${LANG_FARSI} "ساخت میان‌بر روی دسکتاپ."
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} $(DESC_Main)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} $(DESC_Desk)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  SetRegView 64
  nsExec::Exec 'taskkill /F /IM ck-client.exe'
  Sleep 500
  ; undo anything a crashed session could have left behind (DNS rule)
  nsExec::Exec "powershell -NoProfile -NonInteractive -Command $\"Get-DnsClientNrptRule | Where-Object { $$_.Comment -eq 'CKClient' } | Remove-DnsClientNrptRule -Force$\""

  Delete "$INSTDIR\ck-client.exe"
  Delete "$INSTDIR\wintun.dll"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"            ; only removed if empty - never wipes a shared folder
  Delete "$DESKTOP\${APP}.lnk"
  Delete "$SMPROGRAMS\${APP}\${APP}.lnk"
  Delete "$SMPROGRAMS\${APP}\Uninstall ${APP}.lnk"
  RMDir "$SMPROGRAMS\${APP}"
  DeleteRegKey HKLM "${UNKEY}"
  DeleteRegKey HKLM "Software\CKClient"

  MessageBox MB_YESNO|MB_ICONQUESTION "Also delete saved profiles and settings?" IDNO +2
    RMDir /r "$APPDATA\CKClient"
SectionEnd
