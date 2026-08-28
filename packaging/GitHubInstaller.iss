#ifndef LayoutDirectory
  #error LayoutDirectory must be supplied by Build-GitHubInstaller.ps1
#endif
#ifndef InstallerOutputDirectory
  #error InstallerOutputDirectory must be supplied by Build-GitHubInstaller.ps1
#endif
#ifndef SignedUninstallerDirectory
  #error SignedUninstallerDirectory must be supplied by Build-GitHubInstaller.ps1
#endif
#ifndef ApplicationVersion
  #define ApplicationVersion "1.1.0"
#endif

[Setup]
AppId={{8A95FB16-D832-4FE4-AD7C-CDFED12E4274}
AppName=Survey Data Workbench by LAI ZEYU
AppVersion={#ApplicationVersion}
AppVerName=Survey Data Workbench by LAI ZEYU {#ApplicationVersion}
AppPublisher=LAI ZEYU
AppPublisherURL=https://github.com/lzy2767865503-pixel/spss-auto-workflow
AppSupportURL=https://github.com/lzy2767865503-pixel/spss-auto-workflow/issues
AppUpdatesURL=https://github.com/lzy2767865503-pixel/spss-auto-workflow/releases
DefaultDirName={localappdata}\Programs\Survey Data Workbench by LAI ZEYU
DefaultGroupName=Survey Data Workbench by LAI ZEYU
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir={#InstallerOutputDirectory}
OutputBaseFilename=Survey-Data-Workbench-by-LAI-ZEYU-{#ApplicationVersion}-x64-setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
DisableWelcomePage=no
CloseApplications=no
RestartApplications=no
AppMutex=Local\LAISystems.StatFlowWorkbench
UninstallDisplayIcon={app}\StatFlow.Workbench.Desktop.exe
SignedUninstaller=yes
SignedUninstallerDir={#SignedUninstallerDirectory}
SignTool=LAISigner
VersionInfoVersion={#ApplicationVersion}.0
VersionInfoCompany=LAI ZEYU
VersionInfoDescription=Survey Data Workbench by LAI ZEYU Windows installer
VersionInfoProductName=Survey Data Workbench by LAI ZEYU
VersionInfoProductVersion={#ApplicationVersion}
VersionInfoCopyright=Copyright (C) 2026 LAI ZEYU (来泽宇)

[Files]
Source: "{#LayoutDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Survey Data Workbench by LAI ZEYU"; Filename: "{app}\StatFlow.Workbench.Desktop.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\StatFlow.Workbench.Desktop.exe"; Description: "Launch Survey Data Workbench by LAI ZEYU"; Flags: nowait postinstall skipifsilent
