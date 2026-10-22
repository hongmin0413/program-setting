# 2026.10.21 對檔案執行 git update-index --skip-worktree，失敗時用訊息視窗說明原因(git本身只會說 fatal: Unable to mark file)
#   由SourceGit的自訂動作(範圍：檔案)呼叫，工作目錄是專案資料夾，-Path 是SourceGit傳的${FILE}(相對於專案資料夾)
#   skip-worktree只是「隱藏已追蹤檔案之後在工作目錄的修改」，不會讓檔案不被commit：
#   - 已經commit過的檔案：可以用(本機自己改的設定檔就是這種用途)
#   - 已暫存的新檔案：沒有意義，它還是在暫存區、還是會被commit，所以直接擋下來說明
#   - 全新還沒追蹤的檔案、被.gitignore忽略的檔案：git不給用(fatal: Unable to mark file)
#   不想commit的新檔案要用.gitignore或.git/info/exclude
#   -DryRun：不顯示訊息視窗，改成把訊息印出來(測試用)
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$DryRun
)

# termianl 執行方式：
# C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -Command "& (Join-Path $env:APPDATA 'Zed\taskScript\skipWorktree.ps1') -Path '${FILE}'"

$git = 'C:\Program Files\Git\cmd\git.exe'
$q = [char]34
$utf8 = [System.Text.UTF8Encoding]::new($false)
$wd = [IO.Directory]::GetCurrentDirectory()

# 執行git並回傳標準輸出和錯誤訊息(自己指定UTF-8解碼，不依賴console編碼)
function Invoke-Git([string]$gitArgs) {
    $pi = [Diagnostics.ProcessStartInfo]::new()
    $pi.FileName = $git
    $pi.Arguments = $gitArgs
    $pi.WorkingDirectory = $wd
    $pi.RedirectStandardOutput = $true
    $pi.RedirectStandardError = $true
    $pi.UseShellExecute = $false
    $pi.CreateNoWindow = $true
    $pi.StandardOutputEncoding = $utf8
    $pi.StandardErrorEncoding = $utf8
    $p = [Diagnostics.Process]::Start($pi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $script:gitExit = $p.ExitCode
    return ($out + $err).Trim()
}

# 顯示訊息(要用到才載入Windows Forms，成功的時候不用載入，比較快)
function Show-Message([string]$text, [string]$icon) {
    if ($DryRun) {
        "[$icon] $text"
        return
    }
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($text, 'skip-worktree', 'OK', $icon)
}

$name = $Path.Replace('\', '/')
$full = [IO.Path]::Combine($wd, $name.Replace('/', '\'))

# 檔案在git的狀態：ls-files -v 有輸出=git已經追蹤；開頭S=已經是skip-worktree
$tracked = Invoke-Git "-c core.quotepath=false ls-files -v -- $q$name$q"
if ($tracked -ne '') {
    if ($tracked.StartsWith('S ')) {
        Show-Message "已經是 skip-worktree：`n$name" 'Information'
        return
    }
    # 已暫存的新檔案(狀態開頭A)：skip-worktree沒有意義，還是在暫存區、還是會被commit
    $state = Invoke-Git "status --porcelain=v1 -- $q$name$q"
    if ($state.StartsWith('A')) {
        Show-Message "已暫存的新檔案，skip-worktree 沒有意義(還是會被 commit)：`n$name`n`n不想 commit 請先取消暫存，再用 .gitignore 或 .git/info/exclude。" 'Warning'
        return
    }
    $result = Invoke-Git "update-index --skip-worktree -- $q$name$q"
    if ($script:gitExit -ne 0) {
        Show-Message "skip-worktree 失敗：`n$name`n`n$result" 'Error'
    } elseif ($DryRun) {
        "[成功] 已對 $name 執行 skip-worktree"
    }
    return
}

# git沒有追蹤這個檔案，說明原因
if (-not [IO.File]::Exists($full)) {
    Show-Message "找不到檔案：`n$name" 'Error'
    return
}
[void](Invoke-Git "check-ignore -q -- $q$name$q")
if ($script:gitExit -eq 0) {
    Show-Message "被 .gitignore 忽略，不需要 skip-worktree：`n$name" 'Information'
} else {
    Show-Message "新增的檔案，git 還沒追蹤，不能 skip-worktree：`n$name`n`n不想 commit 請用 .gitignore 或 .git/info/exclude。" 'Warning'
}
