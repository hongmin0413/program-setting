# 2026.10.21 取消 skip-worktree 的對話框：列出目前被skip-worktree的檔案，勾選後按「確定」取消；點「比較」欄的圖示用Zed比較(左=index版本、右=目前檔案)
#   由SourceGit的自訂動作呼叫(工作目錄是專案資料夾)；Zed開啟方式：這個專案已經有Zed視窗就加進那個視窗，沒有就開這個專案的新視窗
#   -DryRun：不顯示對話框，只印出第一個檔案的比較要用的zed參數(測試用)
param(
    [switch]$DryRun
)

# termianl 執行方式：
# C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -STA -Command "& (Join-Path $env:APPDATA 'Zed\taskScript\skipWorktreePick.ps1')"

Add-Type -AssemblyName System.Windows.Forms
$git = 'C:\Program Files\Git\cmd\git.exe'
$zed = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'Programs\Zed\bin\zed.exe')
$q = [char]34
$utf8 = [System.Text.UTF8Encoding]::new($false)
$wd = [IO.Directory]::GetCurrentDirectory()
$projectName = [IO.Path]::GetFileName($wd.TrimEnd('\'))

# 執行git並回傳標準輸出(自己指定UTF-8解碼，不依賴console編碼)
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
    $p = [Diagnostics.Process]::Start($pi)
    $out = $p.StandardOutput.ReadToEnd()
    [void]$p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return $out
}

# skip-worktree的檔案：git ls-files -v 以「S 」開頭的
$files = @((Invoke-Git '-c core.quotepath=false ls-files -v').Split("`n") | Where-Object { $_ -match '^S ' } | ForEach-Object { $_.Substring(2).TrimEnd("`r") })
if ($files.Count -eq 0) {
    [void][Windows.Forms.MessageBox]::Show('目前沒有 skip-worktree 的檔案', '取消 skip-worktree')
    return
}

# 找出這個專案的Zed視窗(視窗標題含專案資料夾名稱，例如「專案 — 檔名」、「專案, 別的專案 — 檔名」；沒開檔案時標題就只有「專案」)
# 要用Add-Type編譯，大約要0.5秒，所以第一次按「比較」才編譯
$script:winHelperLoaded = $false
function Find-ZedProjectWindow {
    if (-not $script:winHelperLoaded) {
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
        $script:winHelperLoaded = $true
    }
    $pids = [uint32[]]@([Diagnostics.Process]::GetProcessesByName('Zed') | ForEach-Object { $_.Id })
    if ($pids.Count -eq 0) { return 0 }
    return [ZedWin]::Find($pids, '(^|, )' + [regex]::Escape($projectName) + '(,| —|$)')
}

# 用Zed比較：左=index版本(暫存複本，標籤放在左邊的檔名，右邊的檔名保持原樣Zed才會上色)、右=目前檔案(可編輯)
$compareRoot = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'Temp\zed-compare')
$work = [IO.Path]::Combine($compareRoot, [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
function Open-Compare([string]$x) {
    $leaf = [IO.Path]::GetFileName($x)
    $left = [IO.Path]::Combine($work, [guid]::NewGuid().ToString('N').Substring(0, 8), "$leaf(index)")
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($left))
    $pi = [Diagnostics.ProcessStartInfo]::new()
    $pi.FileName = $git
    $pi.Arguments = "show $q`:./$x$q"
    $pi.WorkingDirectory = $wd
    $pi.RedirectStandardOutput = $true
    $pi.RedirectStandardError = $true
    $pi.UseShellExecute = $false
    $pi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($pi)
    $ms = [IO.MemoryStream]::new()
    $p.StandardOutput.BaseStream.CopyTo($ms)
    [void]$p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { $ms.SetLength(0) }
    [IO.File]::WriteAllBytes($left, $ms.ToArray())
    $right = [IO.Path]::Combine($wd, $x.Replace('/', '\'))
    # 這個專案已經有Zed視窗：切到那個視窗，用-a加進去；沒有：用-n開這個專案的新視窗(工作目錄=專案資料夾)
    $handle = Find-ZedProjectWindow
    if ($handle -ne 0) {
        if ([ZedWin]::IsIconic([IntPtr]$handle)) { [void][ZedWin]::ShowWindow([IntPtr]$handle, 9) }
        [void][ZedWin]::SetForegroundWindow([IntPtr]$handle)
        $mode = '-a'
    } else {
        $mode = '-n'
    }
    $zedArgs = "$mode --diff $q$left$q $q$right$q"
    if ($DryRun) {
        "專案視窗: $(if ($handle -ne 0) { '找到 → 加進該視窗(-a)' } else { '沒有 → 開專案新視窗(-n)' }) | 工作目錄=$wd | zed $mode --diff $([IO.Path]::GetFileName($left)) $([IO.Path]::GetFileName($right))"
        return
    }
    $pi = [Diagnostics.ProcessStartInfo]::new()
    $pi.FileName = $zed
    $pi.Arguments = $zedArgs
    $pi.WorkingDirectory = $wd
    # UseShellExecute=true加Hidden：完全脫離目前的程序，而且不會閃黑視窗
    $pi.UseShellExecute = $true
    $pi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    [void][Diagnostics.Process]::Start($pi)
}

if ($DryRun) {
    Open-Compare $files[0]
    return
}

# 對話框
$form = [Windows.Forms.Form]::new()
$form.Font = [Drawing.Font]::new('Microsoft JhengHei UI', 10)
$form.BackColor = [Drawing.Color]::White
$form.Text = '取消 skip-worktree'
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
$cNote = [Windows.Forms.DataGridViewTextBoxColumn]::new()
$cNote.HeaderText = '備註'
$cNote.ReadOnly = $true
$cNote.Width = 150
$cNote.SortMode = 'NotSortable'
$cNote.DefaultCellStyle.Alignment = 'MiddleCenter'
$cNote.HeaderCell.Style.Alignment = 'MiddleCenter'
$c3 = [Windows.Forms.DataGridViewButtonColumn]::new()
$c3.HeaderText = '比較'
$c3.Text = [char]::ConvertFromUtf32(0x1F50D)
$c3.UseColumnTextForButtonValue = $true
$c3.Width = 70
$c3.SortMode = 'NotSortable'
$c3.FlatStyle = 'Flat'
$c3.DefaultCellStyle.Font = [Drawing.Font]::new('Segoe UI Emoji', 11)
$c3.DefaultCellStyle.Alignment = 'MiddleCenter'
$c3.HeaderCell.Style.Alignment = 'MiddleCenter'
[void]$grid.Columns.Add($c1)
[void]$grid.Columns.Add($c2)
[void]$grid.Columns.Add($cNote)
[void]$grid.Columns.Add($c3)

# index版本的內容(位元組)；取不到(結束碼不是0)回傳$null
function Get-IndexBytes([string]$x) {
    $pi = [Diagnostics.ProcessStartInfo]::new()
    $pi.FileName = $git
    $pi.Arguments = "show $q`:./$x$q"
    $pi.WorkingDirectory = $wd
    $pi.RedirectStandardOutput = $true
    $pi.RedirectStandardError = $true
    $pi.UseShellExecute = $false
    $pi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($pi)
    $ms = [IO.MemoryStream]::new()
    $p.StandardOutput.BaseStream.CopyTo($ms)
    [void]$p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { return $null }
    return , $ms.ToArray()
}

# 預設都不勾；備註：目前檔案和index版本完全一樣(換行符號不同不算：比較前拿掉\r)就標「與index相同」，取消skip-worktree不會有差異
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$green = [Drawing.Color]::FromArgb(20, 130, 50)
foreach ($x in $files) {
    $note = ''
    $abs = [IO.Path]::Combine($wd, $x.Replace('/', '\'))
    if ([IO.File]::Exists($abs)) {
        $indexBytes = Get-IndexBytes $x
        if ($null -ne $indexBytes) {
            $current = $latin1.GetString([IO.File]::ReadAllBytes($abs)).Replace("`r", '')
            if ($current -ceq $latin1.GetString([byte[]]$indexBytes).Replace("`r", '')) { $note = '與index相同' }
        }
    }
    $rowIndex = $grid.Rows.Add([bool]$false, $x, $note)
    # 與index相同用綠色；選取那一列時預設會變成黑色字，所以選取時的字色也要指定
    if ($note -ne '') {
        $grid.Rows[$rowIndex].Cells[2].Style.ForeColor = $green
        $grid.Rows[$rowIndex].Cells[2].Style.SelectionForeColor = $green
    }
}
$grid.ClearSelection()

# 點「檔案」欄：切換勾選
$grid.Add_CellClick({
    param($sender, $e)
    if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 1) {
        $ck = $grid.Rows[$e.RowIndex].Cells[0]
        $ck.Value = -not [bool]$ck.Value
    }
})
# 點「比較」欄的圖示：用Zed比較
$grid.Add_CellContentClick({
    param($sender, $e)
    if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) {
        try {
            Open-Compare $grid.Rows[$e.RowIndex].Cells[1].Value
        } catch {
            [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, '比較失敗')
        }
    }
})

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
$ok.Text = '確定'
$ok.DialogResult = 'OK'
$ok.Size = [Drawing.Size]::new(100, 34)
$ok.FlatStyle = 'Flat'
$ok.BackColor = [Drawing.Color]::FromArgb(0, 120, 212)
$ok.ForeColor = [Drawing.Color]::White
$ok.FlatAppearance.BorderSize = 0
$panel.Controls.Add($cancel)
$panel.Controls.Add($ok)
$form.AcceptButton = $ok
$form.CancelButton = $cancel

$label = [Windows.Forms.Label]::new()
$label.Text = @(
    '1. 勾選要取消 skip-worktree 的檔案，再按「確定」',
    '2. 備註「與index相同」：目前檔案和 index 版本完全一樣，取消後不會有差異',
    '3. 點「比較」欄的圖示，可用 Zed 開啟該檔案與 index 版本的比較'
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

if ($form.ShowDialog() -eq 'OK') {
    $grid.EndEdit()
    foreach ($row in $grid.Rows) {
        if ($row.Cells[0].Value -eq $true) {
            [void](Invoke-Git "update-index --no-skip-worktree -- $q$($row.Cells[1].Value)$q")
        }
    }
}

# 清掉超過1天的暫存資料夾
foreach ($d in [IO.Directory]::GetDirectories($compareRoot)) {
    if ([IO.Directory]::GetLastWriteTime($d) -lt [DateTime]::Now.AddDays(-1)) {
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}