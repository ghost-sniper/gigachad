#ifndef AppVersion
  #error AppVersion must be supplied with /DAppVersion
#endif

[Setup]
AppId=gigachad
AppName=gigachad
AppVersion={#AppVersion}
DefaultDirName={commonpf64}\gigachad
DisableDirPage=yes
UsePreviousAppDir=no
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesEnvironment=yes
OutputDir=..\dist
OutputBaseFilename=gigachad-{#AppVersion}-windows-x86_64-setup
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\gigachad.exe

[Files]
Source: "..\zig-out\bin\gigachad.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion

[Code]
const
  InstallerKey = 'Software\gigachad\Installer';
  PathMarker = 'AddedToUserPath';

function NormalizePathEntry(Entry: String): String;
begin
  Result := RemoveBackslashUnlessRoot(RemoveQuotes(Trim(Entry)));
end;

// Compare whole entries; preserve the spelling, order and empty entries of others.
function WithoutAppPath(const UserPath: String): String;
var
  I, EntryStart, Kept: Integer;
  Entry, AppDir: String;
begin
  Result := '';
  EntryStart := 1;
  Kept := 0;
  AppDir := NormalizePathEntry(ExpandConstant('{app}'));
  for I := 1 to Length(UserPath) + 1 do
  begin
    if I <= Length(UserPath) then
      if UserPath[I] <> ';' then
        Continue;
    Entry := Copy(UserPath, EntryStart, I - EntryStart);
    if CompareText(NormalizePathEntry(Entry), AppDir) <> 0 then
    begin
      if Kept > 0 then
        Result := Result + ';';
      Result := Result + Entry;
      Kept := Kept + 1;
    end;
    EntryStart := I + 1;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  UserPath, NewPath: String;
begin
  if CurStep <> ssPostInstall then
    Exit;
  UserPath := '';
  RegQueryStringValue(HKCU, 'Environment', 'Path', UserPath);
  if WithoutAppPath(UserPath) <> UserPath then
    Exit;

  NewPath := ExpandConstant('{app}');
  if UserPath <> '' then
    NewPath := UserPath + ';' + NewPath;
  // Persist ownership across reinstalls; do not claim a pre-existing PATH entry.
  if not RegWriteDWordValue(HKCU, InstallerKey, PathMarker, 1) then
    RaiseException('Could not record the user PATH change.');
  if not RegWriteExpandStringValue(HKCU, 'Environment', 'Path', NewPath) then
  begin
    RegDeleteValue(HKCU, InstallerKey, PathMarker);
    RaiseException('Could not add gigachad to the user PATH.');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Added: Cardinal;
  UserPath: String;
begin
  if CurUninstallStep <> usUninstall then
    Exit;
  if not RegQueryDWordValue(HKCU, InstallerKey, PathMarker, Added) then
    Exit;
  if Added <> 1 then
    Exit;
  if RegQueryStringValue(HKCU, 'Environment', 'Path', UserPath) then
    if not RegWriteExpandStringValue(HKCU, 'Environment', 'Path', WithoutAppPath(UserPath)) then
      RaiseException('Could not remove gigachad from the user PATH.');
  RegDeleteValue(HKCU, InstallerKey, PathMarker);
  RegDeleteKeyIfEmpty(HKCU, InstallerKey);
end;
