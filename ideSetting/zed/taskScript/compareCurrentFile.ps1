# 2026.10.21 用Zed開啟目前檔案的比較(左=修改前、右=修改後)，在Zed裡按F3執行(Zed全域tasks.json的 compare current file)
#   要比較的檔案：Zed的task會設定環境變數ZED_FILE(路徑有中文時透過args傳會變亂碼，所以用環境變數)
#   -DryRun：只印出要傳給zed的參數，不開啟(測試用)
param(
    [switch]$DryRun
)

$git = 'C:\Program Files\Git\cmd\git.exe'
$zed = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'Programs\Zed\bin\zed.exe')
$q = [char]34
$utf8 = [System.Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($env:ZED_FILE)) {
    Write-Host '沒有開啟中的檔案(環境變數ZED_FILE是空的)'
    exit 1
}

# 執行git並回傳標準輸出(自己指定UTF-8解碼，不依賴console編碼：Zed終端機是cp950，中文路徑會亂碼)
# 2026.10.21 每呼叫一次git約100ms，為了開啟速度盡量少呼叫
function Invoke-Git([string]$gitArgs) {
    $pi = [Diagnostics.ProcessStartInfo]::new()
    $pi.FileName = $git
    $pi.Arguments = $gitArgs
    $pi.RedirectStandardOutput = $true
    $pi.RedirectStandardError = $true
    $pi.UseShellExecute = $false
    $pi.CreateNoWindow = $true
    $pi.StandardOutputEncoding = $utf8
    $p = [Diagnostics.Process]::Start($pi)
    $out = $p.StandardOutput.ReadToEnd()
    [void]$p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $script:gitExit = $p.ExitCode
    return $out
}

# 一次取出多個版本的檔案內容，存成檔案：git cat-file --batch(只啟動一次git)
# 位元組原樣寫出，編碼和換行不會變；沒有這個版本(例如新檔案)就寫成空檔
function Save-Blobs($blobs) {
    $pi = [Diagnostics.ProcessStartInfo]::new()
    $pi.FileName = $git
    $pi.Arguments = "-C $q$root$q cat-file --batch"
    $pi.RedirectStandardInput = $true
    $pi.RedirectStandardOutput = $true
    $pi.RedirectStandardError = $true
    $pi.UseShellExecute = $false
    $pi.CreateNoWindow = $true
    $pi.StandardInputEncoding = $utf8
    $p = [Diagnostics.Process]::Start($pi)
    foreach ($b in $blobs) { $p.StandardInput.Write($b[0] + "`n") }
    $p.StandardInput.Close()
    $stream = $p.StandardOutput.BaseStream
    foreach ($b in $blobs) {
        # 標頭一行：<sha> <type> <size>，找不到時是 <spec> missing
        $header = [System.Text.StringBuilder]::new()
        while (($c = $stream.ReadByte()) -ge 0 -and $c -ne 10) { [void]$header.Append([char]$c) }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($b[1]))
        $parts = $header.ToString().Split(' ')
        if ($parts.Length -eq 3 -and $parts[1] -eq 'blob') {
            $buf = [byte[]]::new([int]$parts[2])
            $read = 0
            while ($read -lt $buf.Length) {
                $n = $stream.Read($buf, $read, $buf.Length - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            [void]$stream.ReadByte()
            [IO.File]::WriteAllBytes($b[1], $buf)
        } else {
            [IO.File]::WriteAllBytes($b[1], [byte[]]@())
        }
    }
    [void]$p.StandardError.ReadToEnd()
    $p.WaitForExit()
}

# 專案根目錄：Zed的task會設定ZED_WORKTREE_ROOT(目前檔案所在的專案資料夾)，不用再問git；沒有才用git找
$abs = [IO.Path]::GetFullPath($env:ZED_FILE)
$root = $env:ZED_WORKTREE_ROOT
if ([string]::IsNullOrWhiteSpace($root) -or -not $abs.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    $root = (Invoke-Git "-C $q$([IO.Path]::GetDirectoryName($abs))$q rev-parse --show-toplevel").Trim()
    if ($script:gitExit -ne 0 -or $root -eq '') {
        Write-Host "不是git專案裡的檔案：$abs"
        exit 1
    }
}
$root = [IO.Path]::GetFullPath($root)
$f = [IO.Path]::GetRelativePath($root, $abs).Replace('\', '/')
$leaf = [IO.Path]::GetFileName($abs)

# 一次取得檔案狀態：XY，X=暫存區的狀態、Y=工作目錄的狀態，??=全新沒加入git的檔案；沒有輸出=沒變更或skip-worktree
$status = Invoke-Git "-C $q$root$q status --porcelain=v1 -z -- $q$f$q"
if ($script:gitExit -ne 0) {
    Write-Host "不是git專案裡的檔案：$abs"
    exit 1
}
$xy = if ($status.Length -ge 2) { $status.Substring(0, 2) } else { '' }
$untracked = ($xy -eq '??')
$staged = ($xy -ne '' -and -not $untracked -and $xy[0] -ne ' ')
$unstaged = ($xy -ne '' -and -not $untracked -and $xy[1] -ne ' ')

# 比較用的暫存檔放在 %LOCALAPPDATA%\Temp\zed-compare\<隨機名稱>(不靠TEMP環境變數：Zed的task環境沒有)
$compareRoot = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'Temp\zed-compare')
$work = [IO.Path]::Combine($compareRoot, [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)

# 右邊用真實檔案(可編輯)；檔案已不存在就用空檔
function Get-WorkFile([string]$sub) {
    if ([IO.File]::Exists($abs)) { return $abs }
    $e = [IO.Path]::Combine($work, "$sub\$leaf(已刪除)")
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($e))
    [IO.File]::WriteAllBytes($e, [byte[]]@())
    [IO.File]::SetAttributes($e, [IO.FileAttributes]::ReadOnly)
    return $e
}

# 要取出的版本：@(git的物件名稱, 存檔路徑)；路徑用 ./ 開頭，相對於專案資料夾
$blobs = @()
$readOnlyFiles = @()
$pairs = @()
# 1. 未暫存：index <-> 目前檔案
if ($unstaged) {
    $l = [IO.Path]::Combine($work, "unstaged\$leaf(未暫存)")
    $blobs += , @(":./$f", $l)
    $pairs += , @($l, (Get-WorkFile 'unstaged'))
}
# 2. 已暫存：HEAD <-> index(沒有未暫存修改時右邊用真實檔案，才能編輯)
if ($staged) {
    # 同時有未暫存修改時，右邊是唯讀的暫存複本，標籤寫清楚；標籤放在左邊的檔名(右邊的檔名要保持原樣，Zed才會上色)
    $stagedLabel = if ($unstaged) { '已暫存，無法編輯' } else { '已暫存，可編輯' }
    $l = [IO.Path]::Combine($work, "staged\$leaf($stagedLabel)")
    $blobs += , @("HEAD:./$f", $l)
    if ($unstaged) {
        $r = [IO.Path]::Combine($work, "staged\index\$leaf")   # 檔名不加標籤，Zed才認得副檔名、才會上色
        $blobs += , @(":./$f", $r)
        # 這份只是暫存區的複本，改了不會寫回任何地方，設成唯讀避免白改；要改請到「未暫存」分頁(右邊是真實檔案)
        $readOnlyFiles += $r
    } else {
        $r = Get-WorkFile 'staged'
    }
    $pairs += , @($l, $r)
}
# 3. 全新、沒加入git的檔案：空檔 <-> 目前檔案
if ($untracked) {
    $l = [IO.Path]::Combine($work, "untracked\$leaf(新檔案)")
    $blobs += , @(':', $l)
    $pairs += , @($l, $abs)
}
# 4. git看不出差異(沒變更、skip-worktree)：index <-> 目前檔案
if ($pairs.Count -eq 0) {
    $l = [IO.Path]::Combine($work, "other\$leaf(index)")
    $blobs += , @(":./$f", $l)
    $pairs += , @($l, (Get-WorkFile 'other'))
}
Save-Blobs $blobs
foreach ($r in $readOnlyFiles) { [IO.File]::SetAttributes($r, [IO.FileAttributes]::ReadOnly) }

# -a：加進目前使用中的Zed視窗(從Zed按F3，目前視窗就是使用中的視窗)
$zedArgs = @('-a')
foreach ($p in $pairs) {
    $zedArgs += '--diff'
    $zedArgs += ($q + $p[0] + $q)
    $zedArgs += ($q + $p[1] + $q)
}

if ($DryRun) {
    'zed ' + (($zedArgs | ForEach-Object { if ($_ -like "$q*") { Split-Path $_.Trim($q) -Leaf } else { $_ } }) -join ' ')
} else {
    # zed.exe是console程式，用隱藏視窗的方式啟動，避免閃一下黑色視窗；用.NET啟動，比Start-Process cmdlet快
    $pi = [Diagnostics.ProcessStartInfo]::new()
    $pi.FileName = $zed
    $pi.Arguments = ($zedArgs -join ' ')
    # UseShellExecute=true加Hidden：完全脫離目前的終端機(不然Zed冷啟動時終端機會一直不結束)，而且不會閃黑視窗
    $pi.UseShellExecute = $true
    $pi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    [void][Diagnostics.Process]::Start($pi)
}

# 清掉超過1天的暫存資料夾(開啟之後才清，不拖慢開啟速度)
foreach ($d in [IO.Directory]::GetDirectories($compareRoot)) {
    if ([IO.Directory]::GetLastWriteTime($d) -lt [DateTime]::Now.AddDays(-1)) {
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}