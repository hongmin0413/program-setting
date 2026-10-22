@echo off
chcp 65001>nul

rem Zed更新要修改路徑 
set zedExe=%LOCALAPPDATA%\Programs\Zed\Zed.exe

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
start "" /min "%zedExe%" "%workspaceDir%"
goto :eof

:pauseAndExit
pause>nul
goto :eof