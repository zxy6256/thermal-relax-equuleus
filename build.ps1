# ============================================================================
# build.ps1 —— Windows 构建：跑测试 -> 打包 -> 校验 zip 结构
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
# 三个 Windows 特有的坑，这里都绕开了：
#   1) .ps1 必须存成 UTF-8 with BOM，否则 PowerShell 5.1 按 GBK 解析中文直接语法错
#   2) 原生命令往 stderr 写东西时，$ErrorActionPreference='Stop' 会把它当成致命错误，
#      所以调用 git-bash 期间临时改成 Continue
#   3) git-bash 的 MSYS2 启动信息会卡住管道，所以一次性 `$out = (& bash -lc ... 2>&1)`
#      收集结果，不接管道、不做 2> 重定向；python 校验逻辑放独立文件，不用 -c
# ============================================================================
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$root = ($PSScriptRoot -replace '\\', '/')

$py = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue) }
if (-not $py) { throw 'need python for tools/pack.py' }

Write-Host '== 1/3 host tests ==' -ForegroundColor Cyan
$bash = 'C:\Program Files\Git\usr\bin\bash.exe'
if (-not (Test-Path $bash)) { $bash = 'C:\Program Files\Git\bin\bash.exe' }
if (Test-Path $bash) {
    $cmd = "export PATH=/usr/bin:/bin; cd '$root' && sh tests/run_tests.sh"
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = (& $bash -lc $cmd 2>&1) -join "`n"
    $code = $LASTEXITCODE
    $ErrorActionPreference = $eap
    $summary = ($out -split "`n" | Select-String 'FAIL=').Line
    $failed = -1
    if ("$summary" -match 'FAIL=(\d+)') { $failed = [int]$Matches[1] }
    if ($code -ne 0 -or $failed -ne 0) {
        $out -split "`n" | Select-Object -Last 40
        throw "tests failed (exit=$code, $summary)"
    }
    Write-Host $summary
} else {
    Write-Warning 'git-bash not found, skip host tests'
}

Write-Host '== 2/3 pack ==' -ForegroundColor Cyan
& $py.Source tools/pack.py
if ($LASTEXITCODE -ne 0) { throw 'pack failed' }

Write-Host '== 3/3 verify ==' -ForegroundColor Cyan
& $py.Source tools/verify_zip.py
if ($LASTEXITCODE -ne 0) { throw 'zip verify failed' }

Write-Host ''
Write-Host 'OUT: dist/ThermalRelax-equuleus-v1.0.0.zip  ->  Magisk -> Modules -> Install from storage' -ForegroundColor Green
