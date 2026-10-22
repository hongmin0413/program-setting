[void](chcp 65001)
# 不依賴使用者的PowerShell設定檔，避免console編碼不同造成中文分支名稱亂碼
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# termianl 執行方式：
# C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -Command "& (Join-Path $env:APPDATA 'Cursor\User\taskScript\fetchRemoteGit.ps1')"

# 2026.10.21 git不一定有加到PATH，用完整路徑呼叫
$git = "C:\Program Files\Git\cmd\git.exe"

$success = $true

echo "同步本地已存在，且有連結到的遠端分支…"
# 目前所在分支
$currentBranch = & $git rev-parse --abbrev-ref HEAD
# 所有本地分支
$localBranches = & $git for-each-ref --format="%(refname:short)" refs/heads/
foreach($localBranch in $localBranches) {
	# 遠端名稱/遠端分支
	$remoteInfoStr = & $git rev-parse --abbrev-ref --symbolic-full-name "$localBranch@{upstream}" 2>$null
	# 只處理有連結到的遠端分支
	if(![string]::IsNullOrWhiteSpace($remoteInfoStr)) {
		$remoteInfoArray = $remoteInfoStr -split '/', 2
		$remoteName = $remoteInfoArray[0]
		$remoteBranchName = $remoteInfoArray[1]
		# 目前所在分支，不能用fetch更新本地分支，因此直接pull
		if($localBranch -eq $currentBranch) {
			& $git pull $remoteName $remoteBranchName
		}else {
			& $git fetch $remoteName "${remoteBranchName}:${localBranch}"
		}
		# 2026.08.06 若更新失敗，還是下載，避免不知道有更新
		if(!$?) {
			$success = $false
			echo "更新失敗，改為下載遠端分支"
			& $git fetch $remoteName $remoteBranchName
		}
	}
}
echo "同步完成"

echo "同步本地沒有，但遠端有的分支…"
& $git fetch --all
# 所有遠端分支
$remoteBranches = & $git for-each-ref --format="%(refname:short)" refs/remotes/ | Where-Object { $_ -match '/' }
foreach($remoteBranch in $remoteBranches) {
	$remoteInfoArray = $remoteBranch -split '/', 2
	$remoteName = $remoteInfoArray[0]
	$remoteBranchName = $remoteInfoArray[1]
	& $git show-ref --verify --quiet "refs/heads/$remoteBranchName"
	if(!$?) {
		& $git branch $remoteBranchName $remoteBranch
	}
}
echo "同步完成"

if(!$success) {
	exit 1
}