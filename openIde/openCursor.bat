@echo off
chcp 65001>nul

rem cursor更新要修改路徑 
set cursorExe=%LOCALAPPDATA%\Programs\cursor\Cursor.exe

rem 設定workspaceDir 
set workspaceDir=%~1
if "%workspaceDir%" equ "" (
	echo workspaceDir為空值，請按任意鍵退出...
	goto pauseAndExit
)
rem 檢查workspaceDir是否存在 
if not exist "%workspaceDir%" (
	echo %workspaceDir%不存在，請按任意鍵退出...
	goto pauseAndExit
)

rem 開啟程式編輯器 
rem 2025.04.01 不知道為什麼把VSCODE_DEV清空才不會有錯誤 
set VSCODE_DEV=
start "" /min "%cursorExe%" "%workspaceDir%"
goto :eof

:pauseAndExit
pause>nul
goto :eof