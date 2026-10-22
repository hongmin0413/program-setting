# 2026.10.21 用Zed開啟「合併衝突檔案」的比較，由SourceGit的自訂動作(範圍：專案)呼叫，工作目錄是專案資料夾(沒有設Zed的快捷鍵)
#   Zed開啟方式：這個專案已經有Zed視窗就切過去、加進那個視窗；沒有就開這個專案的新視窗
#   比較的方式：只看有衝突的地方
#     左邊：對方(incoming)的版本，檔名加上(合併衝突，對方 vs 自己)；衝突的地方放對方的內容
#     右邊：自己的檔案，衝突的地方只留我方的內容，可以直接編輯(哪些要採用對方的，自己改右邊)
#     沒衝突的地方(包含git自動合併成功的)左右完全一樣，所以比較畫面只會出現有衝突的地方
#   開啟哪些檔案：
#     第一次(有任何衝突檔案還有衝突標記<<<<<<<)：直接開啟全部衝突檔案，並把有標記的檔案改寫成「去掉標記、只留我方內容」(直接改寫檔案；
#       要回到有標記的樣子可以用 git checkout -m -- 檔案)
#     之後(所有衝突檔案都已經沒有標記，但還沒git add)：跳出對話框，勾選要開啟的檔案(預設都不勾，標題列的核取方塊可以全選)；已經git add的不會列出
#       「狀態」欄：目前檔案和「衝突的地方只留我方內容」的版本不一樣就顯示「已編輯」，一樣是「未編輯」(算不出來的不顯示)
#       左邊的內容用git merge-file從衝突的三個版本重新算(衝突的地方放對方的內容)
#   -DryRun：不顯示對話框(視為全選)，只印出要傳給zed的參數，不開啟(測試用；第一次的情況仍會改寫檔案)
param(
    [switch]$DryRun
)

# termianl 執行方式：
# C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -Command "& (Join-Path $env:APPDATA 'Zed\taskScript\resolveMergeConflicts.ps1')"
# 放棄合併 執行方式(commit過的無法恢復)：
# C:\Program Files\Git\cmd\git.exe reset --merge

$git = 'C:\Program Files\Git\cmd\git.exe'
$zed = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'Programs\Zed\bin\zed.exe')
$q = [char]34
$utf8 = [System.Text.UTF8Encoding]::new($false)
# 檔案內容用Latin1(一個位元組一個字元)處理，寫回去的位元組跟原本完全一樣，不管檔案是UTF-8還是Big5
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

# 執行git並回傳標準輸出(自己指定UTF-8解碼，不依賴console編碼：Zed終端機是cp950，中文路徑會亂碼)
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

# 執行git並回傳標準輸出的位元組(原樣，不解碼)；失敗(結束碼不是0)回傳$null
function Invoke-GitBytes([string]$gitArgs, [int[]]$okExitCodes = @(0)) {
    $pi = [Diagnostics.ProcessStartInfo]::new()
    $pi.FileName = $git
    $pi.Arguments = $gitArgs
    $pi.RedirectStandardOutput = $true
    $pi.RedirectStandardError = $true
    $pi.UseShellExecute = $false
    $pi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($pi)
    $ms = [IO.MemoryStream]::new()
    $p.StandardOutput.BaseStream.CopyTo($ms)
    [void]$p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $script:gitExit = $p.ExitCode
    if ($okExitCodes -notcontains $p.ExitCode) { return $null }
    return , $ms.ToArray()
}

# 顯示訊息(從SourceGit呼叫時沒有終端機可以看，所以用訊息視窗；要用到才載入Windows Forms)
function Show-Message([string]$text, [string]$icon) {
    if ($DryRun) {
        "[$icon] $text"
        return
    }
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($text, '合併衝突', 'OK', $icon)
}

# 專案資料夾：SourceGit呼叫時的目前資料夾；再找出git專案的最上層
$start = [IO.Directory]::GetCurrentDirectory()
$top = (Invoke-Git "-C $q$start$q rev-parse --show-toplevel").Trim()
if ($script:gitExit -ne 0 -or $top -eq '') {
    Show-Message "不是git專案：`n$start" 'Error'
    exit 1
}
$top = [IO.Path]::GetFullPath($top)

# 所有還沒解決的衝突檔案(路徑相對於git專案最上層)
$conflicts = @((Invoke-Git "-C $q$top$q diff --name-only --diff-filter=U -z").Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
if ($conflicts.Count -eq 0) {
    Show-Message '目前沒有合併衝突的檔案' 'Information'
    exit 0
}

# 文字有沒有衝突標記(<<<<<<< 開頭的那一行)
function Test-HasMarkers([string]$text) {
    return [regex]::IsMatch($text, '(?m)^<{7}(?: [^\n]*)?\r?$')
}

# 取出衝突標記中指定那一邊的內容($side：ours＝我方，theirs＝對方)：標記行、另一邊的內容、diff3樣式的base內容都拿掉
function Select-ConflictSide([string]$text, [string]$side) {
    $state = 0   # 0=一般內容 1=我方 2=base(diff3) 3=對方
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $text.Split("`n")) {
        $t = $line.TrimEnd("`r")
        if ($state -eq 0) {
            if ($t -match '^<{7}( |$)') { $state = 1; continue }
        } elseif ($state -eq 1) {
            if ($t -match '^\|{7}( |$)') { $state = 2; continue }
            if ($t -eq '=======') { $state = 3; continue }
            if ($side -ne 'ours') { continue }
        } elseif ($state -eq 2) {
            if ($t -eq '=======') { $state = 3 }
            continue
        } elseif ($state -eq 3) {
            if ($t -match '^>{7}( |$)') { $state = 0; continue }
            if ($side -ne 'theirs') { continue }
        }
        $kept.Add($line)
    }
    return ($kept -join "`n")
}

# 讀每個衝突檔案的內容，看有沒有衝突標記：有任何一個有標記就是「第一次」
$texts = @{}
$isFirstTime = $false
foreach ($rel in $conflicts) {
    $abs = [IO.Path]::Combine($top, $rel.Replace('/', '\'))
    if ([IO.File]::Exists($abs)) {
        $text = $latin1.GetString([IO.File]::ReadAllBytes($abs))
        $texts[$rel] = $text
        if (Test-HasMarkers $text) { $isFirstTime = $true }
    }
}

# 暫存檔放在 %LOCALAPPDATA%\Temp\zed-compare\<隨機名稱>(不靠TEMP環境變數：Zed的task環境沒有)；比較用的暫存檔1天後清掉
$compareRoot = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'Temp\zed-compare')
$work = [IO.Path]::Combine($compareRoot, [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)

# 用git merge-file從衝突的三個版本算出「衝突的地方放指定那一邊內容」的完整內容($side：ours＝我方，theirs＝對方)；
# 算不出來(缺少我方或對方的版本、二進位檔)回傳$null
function Get-MergeFileResult([string]$rel, [string]$side) {
    $ours = Invoke-GitBytes "-C $q$top$q show $q`:2`:$rel$q"
    $theirs = Invoke-GitBytes "-C $q$top$q show $q`:3`:$rel$q"
    if ($null -eq $ours -or $null -eq $theirs) { return $null }
    # 沒有base(兩邊都新增同一個檔案)就用空檔當base
    $base = Invoke-GitBytes "-C $q$top$q show $q`:1`:$rel$q"
    if ($null -eq $base) { $base = [byte[]]@() }
    $dir = [IO.Path]::Combine($work, 'merge-file', [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($dir)
    $files = @()
    foreach ($b in @($ours, $base, $theirs)) {
        $f = [IO.Path]::Combine($dir, [string]$files.Count)
        [IO.File]::WriteAllBytes($f, [byte[]]$b)
        $files += $f
    }
    # 結束碼：衝突的數量(指定了--ours／--theirs衝突會自動解決)；錯誤是負數(255)
    $merged = Invoke-GitBytes "merge-file -p --$side $q$($files[0])$q $q$($files[1])$q $q$($files[2])$q" (0..127)
    if ($null -eq $merged) { return $null }
    return , $merged
}

# 不是第一次：對話框勾選要開啟的檔案
if (-not $isFirstTime -and -not $DryRun) {
    Add-Type -AssemblyName System.Windows.Forms
    $form = [Windows.Forms.Form]::new()
    $form.Font = [Drawing.Font]::new('Microsoft JhengHei UI', 10)
    $form.BackColor = [Drawing.Color]::White
    $form.Text = '解決合併衝突'
    $form.Size = [Drawing.Size]::new(900, 500)
    $form.StartPosition = 'CenterScreen'

    $grid = [Windows.Forms.DataGridView]::new()
    # 表格開雙緩衝：避免視窗剛出現時一格一格慢慢畫、閃一下的現象
    [void]$grid.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($grid, $true)
    $grid.Dock = 'Fill'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.AllowUserToResizeColumns = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.BackgroundColor = [Drawing.Color]::White
    $grid.BorderStyle = 'None'
    $grid.CellBorderStyle = 'SingleHorizontal'
    $grid.GridColor = [Drawing.Color]::FromArgb(230, 230, 230)
    $grid.RowTemplate.Height = 32
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersBorderStyle = 'None'
    $grid.ColumnHeadersHeight = 34
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(245, 245, 245)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(70, 70, 70)
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(245, 245, 245)
    $grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = [Drawing.Color]::FromArgb(70, 70, 70)
    $grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(232, 241, 252)
    $grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::Black

    $c1 = [Windows.Forms.DataGridViewCheckBoxColumn]::new()
    $c1.HeaderText = ''
    $c1.Width = 44
    $c1.SortMode = 'NotSortable'
    # 明確指定這欄是布林值的核取方塊，不然第一次繪製時可能把值當文字(顯示成False)
    $c1.ValueType = [bool]
    $c1.TrueValue = $true
    $c1.FalseValue = $false
    $c2 = [Windows.Forms.DataGridViewTextBoxColumn]::new()
    $c2.HeaderText = '檔案'
    $c2.ReadOnly = $true
    $c2.AutoSizeMode = 'Fill'
    $c2.SortMode = 'NotSortable'
    $c2.DefaultCellStyle.Font = [Drawing.Font]::new('Times New Roman', 11)
    $c3 = [Windows.Forms.DataGridViewTextBoxColumn]::new()
    $c3.HeaderText = '狀態'
    $c3.ReadOnly = $true
    $c3.Width = 110
    $c3.SortMode = 'NotSortable'
    $c3.DefaultCellStyle.Alignment = 'MiddleCenter'
    $c3.HeaderCell.Style.Alignment = 'MiddleCenter'
    $c4 = [Windows.Forms.DataGridViewTextBoxColumn]::new()
    $c4.HeaderText = '備註'
    $c4.ReadOnly = $true
    $c4.Width = 130
    $c4.SortMode = 'NotSortable'
    $c4.DefaultCellStyle.Alignment = 'MiddleCenter'
    $c4.HeaderCell.Style.Alignment = 'MiddleCenter'
    [void]$grid.Columns.Add($c1)
    [void]$grid.Columns.Add($c2)
    [void]$grid.Columns.Add($c3)
    [void]$grid.Columns.Add($c4)
    # 預設都不勾；狀態：目前檔案和「衝突的地方只留我方內容」的版本(git merge-file --ours)比，不一樣就是已編輯過；
    # 備註：目前檔案和「衝突的地方放對方內容」的版本(git merge-file --theirs)完全一樣，就標「與對方相同」(左右沒有差異了)
    # (換行符號不同不算：比較前拿掉\r)；算不出來(二進位檔、一邊刪除檔案)不顯示
    foreach ($x in $conflicts) {
        $status = ''
        $note = ''
        if ($texts.ContainsKey($x)) {
            $current = $texts[$x].Replace("`r", '')
            $oursOnly = Get-MergeFileResult $x 'ours'
            if ($null -ne $oursOnly) {
                $status = if ($current -ceq $latin1.GetString([byte[]]$oursOnly).Replace("`r", '')) { '未編輯' } else { '已編輯' }
            }
            $theirsOnly = Get-MergeFileResult $x 'theirs'
            if ($null -ne $theirsOnly -and $current -ceq $latin1.GetString([byte[]]$theirsOnly).Replace("`r", '')) { $note = '與對方相同' }
        }
        $rowIndex = $grid.Rows.Add([bool]$false, $x, $status, $note)
        # 已編輯用紅色、與對方相同用綠色；選取那一列時預設會變成黑色字，所以選取時的字色也要指定
        if ($status -eq '已編輯') {
            $red = [Drawing.Color]::FromArgb(210, 30, 30)
            $grid.Rows[$rowIndex].Cells[2].Style.ForeColor = $red
            $grid.Rows[$rowIndex].Cells[2].Style.SelectionForeColor = $red
        }
        if ($note -ne '') {
            $green = [Drawing.Color]::FromArgb(20, 130, 50)
            $grid.Rows[$rowIndex].Cells[3].Style.ForeColor = $green
            $grid.Rows[$rowIndex].Cells[3].Style.SelectionForeColor = $green
        }
    }
    $grid.ClearSelection()

    $panel = [Windows.Forms.FlowLayoutPanel]::new()
    $panel.Dock = 'Bottom'
    $panel.Height = 56
    $panel.FlowDirection = 'RightToLeft'
    $panel.Padding = [Windows.Forms.Padding]::new(12, 10, 12, 10)
    $panel.BackColor = [Drawing.Color]::FromArgb(245, 245, 245)
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.DialogResult = 'Cancel'
    $cancel.Size = [Drawing.Size]::new(100, 34)
    $cancel.FlatStyle = 'Flat'
    $cancel.BackColor = [Drawing.Color]::White
    $ok = [Windows.Forms.Button]::new()
    $ok.Text = '開啟'
    $ok.DialogResult = 'OK'
    $ok.Size = [Drawing.Size]::new(100, 34)
    $ok.FlatStyle = 'Flat'
    $ok.BackColor = [Drawing.Color]::FromArgb(0, 120, 212)
    $ok.ForeColor = [Drawing.Color]::White
    $ok.FlatAppearance.BorderSize = 0
    # 全選：標題列第一欄的核取方塊(蓋在標題儲存格上)，點了全部勾選／取消；每一列都勾了它就自動勾起來
    $headerCheck = [Windows.Forms.CheckBox]::new()
    $headerCheck.Size = [Drawing.Size]::new(18, 18)
    $headerCheck.Location = [Drawing.Point]::new(13, 8)
    $headerCheck.BackColor = [Drawing.Color]::FromArgb(245, 245, 245)
    $script:syncingHeader = $false
    $script:bulkChanging = $false
    $updateSelectAllText = {
        $all = $true
        foreach ($row in $grid.Rows) { if ($row.Cells[0].Value -ne $true) { $all = $false; break } }
        $script:syncingHeader = $true
        $headerCheck.Checked = $all
        $script:syncingHeader = $false
    }
    $headerCheck.Add_CheckedChanged({
        if ($script:syncingHeader) { return }
        # 目前選取的儲存格先放掉：不然它之後結束編輯時，會把舊的值寫回去(第一列沒有被勾起來)
        $checked = $headerCheck.Checked
        $grid.EndEdit()
        $grid.CurrentCell = $null
        $script:bulkChanging = $true
        foreach ($row in $grid.Rows) { $row.Cells[0].Value = $checked }
        $script:bulkChanging = $false
        $grid.Invalidate()
    })
    $grid.Controls.Add($headerCheck)
    # 點「檔案」欄：切換勾選
    $grid.Add_CellClick({
        param($sender, $e)
        if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 1) {
            $ck = $grid.Rows[$e.RowIndex].Cells[0]
            $ck.Value = -not [bool]$ck.Value
            & $updateSelectAllText
        }
    })
    # 直接點核取方塊：確定值之後更新「全選」的文字
    $grid.Add_CellValueChanged({ if (-not $script:bulkChanging) { & $updateSelectAllText } })
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty) { $grid.CommitEdit('CurrentCellChange') }
    })
    $panel.Controls.Add($cancel)
    $panel.Controls.Add($ok)
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel

    $label = [Windows.Forms.Label]::new()
    $label.Text = @(
        '1. 勾選要用 Zed 開啟比較的衝突檔案，再按「開啟」',
        '2. 比較時左＝對方、右＝自己，只顯示有衝突的地方',
        '3. 備註「與對方相同」：目前檔案和對方的版本完全一樣，已經沒有差異',
	'4. 已經 git add 的檔案不會列出'
    ) -join "`r`n"
    $label.Dock = 'Top'
    $label.Height = 84
    $label.TextAlign = 'MiddleLeft'
    $label.Padding = [Windows.Forms.Padding]::new(12, 0, 0, 0)
    $label.ForeColor = [Drawing.Color]::FromArgb(70, 70, 70)

    $form.SuspendLayout()
    $form.Controls.Add($grid)
    $form.Controls.Add($panel)
    $form.Controls.Add($label)
    $form.ResumeLayout($true)

    if ($form.ShowDialog() -ne 'OK') { exit 0 }
    $grid.EndEdit()
    $selected = @()
    foreach ($row in $grid.Rows) {
        if ($row.Cells[0].Value -eq $true) { $selected += $row.Cells[1].Value }
    }
    if ($selected.Count -eq 0) { exit 0 }
    $conflicts = $selected
}

$pairs = @()
$index = 0
foreach ($rel in $conflicts) {
    $index++
    $abs = [IO.Path]::Combine($top, $rel.Replace('/', '\'))
    $leaf = [IO.Path]::GetFileName($abs)
    $l = [IO.Path]::Combine($work, "incoming\$index\$leaf(合併衝突，對方 vs 自己)")
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($l))
    if ($texts.ContainsKey($rel)) {
        $text = $texts[$rel]
        if (Test-HasMarkers $text) {
            # 有衝突標記：左邊＝衝突的地方放對方內容；右邊＝衝突的地方只留我方內容，直接改寫檔案
            [IO.File]::WriteAllBytes($l, $latin1.GetBytes((Select-ConflictSide $text 'theirs')))
            [IO.File]::WriteAllBytes($abs, $latin1.GetBytes((Select-ConflictSide $text 'ours')))
        } else {
            # 沒有標記(之前已經處理過)：左邊用git merge-file重新算；算不出來就用對方的完整版本(:3:，對方刪除檔案時是空檔)
            $merged = Get-MergeFileResult $rel 'theirs'
            if ($null -eq $merged) {
                $merged = Invoke-GitBytes "-C $q$top$q show $q`:3`:$rel$q"
                if ($null -eq $merged) { $merged = [byte[]]@() }
            }
            [IO.File]::WriteAllBytes($l, [byte[]]$merged)
        }
        $r = $abs
    } else {
        # 我方把檔案刪掉(衝突)：右邊用空檔；左邊用對方的完整版本(對方也刪掉時是空檔)
        $theirsBlob = Invoke-GitBytes "-C $q$top$q show $q`:3`:$rel$q"
        if ($null -eq $theirsBlob) { $theirsBlob = [byte[]]@() }
        [IO.File]::WriteAllBytes($l, [byte[]]$theirsBlob)
        $r = [IO.Path]::Combine($work, "deleted\$index\$leaf(已刪除)")
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($r))
        [IO.File]::WriteAllBytes($r, [byte[]]@())
    }
    $pairs += , @($l, $r)
}

# 找出這個專案的Zed視窗(視窗標題含專案資料夾名稱，例如「專案 — 檔名」、「專案, 別的專案 — 檔名」；沒開檔案時標題就只有「專案」)
# 要用Add-Type編譯，大約要0.5秒，只有在真的要開Zed的時候才編譯
function Find-ZedProjectWindow([string]$projectName) {
    Add-Type -TypeDefinition @'
using System; using System.Text; using System.Text.RegularExpressions; using System.Collections.Generic; using System.Runtime.InteropServices;
public class ZedWin {
    public delegate bool P(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(P p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    public static long Find(uint[] pids, string pattern) {
        var ps = new HashSet<uint>(pids);
        var re = new Regex(pattern);
        long found = 0;
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (found == 0 && ps.Contains(pid) && IsWindowVisible(h)) {
                var t = new StringBuilder(512); GetWindowText(h, t, 512);
                if (t.Length > 0 && re.IsMatch(t.ToString())) found = h.ToInt64();
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
    $pids = [uint32[]]@([Diagnostics.Process]::GetProcessesByName('Zed') | ForEach-Object { $_.Id })
    if ($pids.Count -eq 0) { return 0 }
    return [ZedWin]::Find($pids, '(^|, )' + [regex]::Escape($projectName) + '(,| —|$)')
}

# 這個專案已經有Zed視窗：切到那個視窗，用-a加進去(所有衝突檔案的比較都在同一個視窗)；
# 沒有：用-n開這個專案的新視窗(工作目錄=專案資料夾，Zed會以它當專案)
$projectName = [IO.Path]::GetFileName($top.TrimEnd('\'))
$handle = Find-ZedProjectWindow $projectName
if ($handle -ne 0) {
    if ([ZedWin]::IsIconic([IntPtr]$handle)) { [void][ZedWin]::ShowWindow([IntPtr]$handle, 9) }
    [void][ZedWin]::SetForegroundWindow([IntPtr]$handle)
    $mode = '-a'
} else {
    $mode = '-n'
}
$zedArgs = @($mode)
foreach ($pair in $pairs) {
    $zedArgs += '--diff'
    $zedArgs += ($q + $pair[0] + $q)
    $zedArgs += ($q + $pair[1] + $q)
}

if ($DryRun) {
    "專案視窗($projectName): $(if ($handle -ne 0) { '找到 → 加進該視窗(-a)' } else { '沒有 → 開專案新視窗(-n)' }) | 工作目錄=$top | $(if ($isFirstTime) { '第一次(有標記，開啟全部)' } else { '之後(沒有標記，視為全選)' })"
    'zed ' + (($zedArgs | ForEach-Object { if ($_ -like "$q*") { Split-Path $_.Trim($q) -Leaf } else { $_ } }) -join ' ')
} else {
    # zed.exe是console程式，用隱藏視窗的方式啟動，避免閃一下黑色視窗；UseShellExecute=true讓它完全脫離目前的程序
    $pi = [Diagnostics.ProcessStartInfo]::new()
    $pi.FileName = $zed
    $pi.Arguments = ($zedArgs -join ' ')
    $pi.WorkingDirectory = $top
    $pi.UseShellExecute = $true
    $pi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    [void][Diagnostics.Process]::Start($pi)
}

# 開啟之後才做的清理(不拖慢開啟速度)：比較用的暫存資料夾超過1天的刪掉
foreach ($d in [IO.Directory]::GetDirectories($compareRoot)) {
    if ([IO.Directory]::GetLastWriteTime($d) -lt [DateTime]::Now.AddDays(-1)) {
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}