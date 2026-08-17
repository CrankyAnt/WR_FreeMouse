Option Explicit

Dim shell, fso, processEnv
Dim scriptDir, psScript, psExe, command
Dim i, rc

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
Set processEnv = shell.Environment("Process")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "WR FreeMouse Launch.ps1")
psExe = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

processEnv("WRFM_ARG_COUNT") = CStr(WScript.Arguments.Count)

For i = 0 To WScript.Arguments.Count - 1
    processEnv("WRFM_ARG_" & CStr(i)) = WScript.Arguments(i)
Next

command = Chr(34) & psExe & Chr(34) & _
          " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
          Chr(34) & psScript & Chr(34)

' Window style 0 = hidden. Wait=True keeps this GUI host alive for the same
' lifetime as the hidden PowerShell launch coordinator.
rc = shell.Run(command, 0, True)

WScript.Quit rc
