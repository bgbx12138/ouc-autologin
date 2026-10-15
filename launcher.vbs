' Zero-console launcher for the scheduled task.
' wscript is a GUI-subsystem host: it allocates no console, so no terminal window ever flashes
' (powershell.exe launched directly would get a console host, and Windows Terminal shows that as a
' window for ~1s even with -WindowStyle Hidden).
' PowerShell MUST be given by absolute path: the task context's PATH does not reliably contain it,
' and Shell.Run's error is otherwise silently swallowed by wscript (symptom: task "succeeds", no log).
Option Explicit

Dim shell, fso, rootDir, mode, cmd, psExe, f
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

rootDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
psExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"

mode = "check"
If WScript.Arguments.Count > 0 Then mode = WScript.Arguments(0)

cmd = """" & psExe & """ -NoProfile -ExecutionPolicy Bypass -File """ & rootDir & "ouc-autologin.ps1"" " & mode & " -Quiet"

On Error Resume Next
shell.Run cmd, 0, True
If Err.Number <> 0 Then
    Dim errNo, errDesc
    errNo = Err.Number
    errDesc = Err.Description
    Err.Clear
    Set f = fso.OpenTextFile(rootDir & "launcher-error.log", 8, True)
    f.WriteLine Now & "  Run failed: " & cmd
    f.WriteLine "  error " & errNo & " " & errDesc
    f.Close
End If
On Error GoTo 0
