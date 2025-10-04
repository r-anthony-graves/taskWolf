# test_cli.ps1
# Windows PowerShell test harness for index.js

param(
    [switch]$Loop   # optional: run the whole suite repeatedly until Ctrl+C
)

$ErrorActionPreference = "Stop"

# ---------------- util ----------------
function New-LogRoot {
    $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $root  = Join-Path -Path $PSScriptRoot -ChildPath ("logs\{0}" -f $stamp)
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

function Get-CountsFromOutput([string[]]$Lines) {
    # Try to parse "Collected: X | Pages: Y | Dups: Z"
    $result = @{ Collected = 0; Pages = 0; Dups = 0 }
    $line = $Lines | Where-Object { $_ -match 'Collected:\s*\d+\s*\|\s*Pages:\s*\d+\s*\|\s*Dups:\s*\d+' } | Select-Object -Last 1
    if ($line) {
        if ($line -match 'Collected:\s*(\d+)') { $result.Collected = [int]$Matches[1] }
        if ($line -match 'Pages:\s*(\d+)')     { $result.Pages     = [int]$Matches[1] }
        if ($line -match 'Dups:\s*(\d+)')      { $result.Dups      = [int]$Matches[1] }
    }
    return $result
}

function Invoke-TestCase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $Name,
        [Parameter(Mandatory)] [string]   $Description,
        [Parameter(Mandatory)] [string[]] $CliArgs,
        [int] $MaxRetries = 5,
        [ref] $PassRef,
        [ref] $FailRef,
        [ref] $IndexRef,
        [string] $LogDir
    )
    $IndexRef.Value++
    $idx = '{0:D2}' -f $IndexRef.Value
    $log = Join-Path $LogDir ("{0}_{1}.log" -f $idx, ($Name -replace '\s+','_'))

    Write-Host ("=== {0} ===" -f $Name) -ForegroundColor Cyan
    Write-Host ("- {0}" -f $Description) -ForegroundColor DarkCyan

    $attempt = 0
    $ok = $false
    $counts = @{ Collected = 0; Pages = 0; Dups = 0 }
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()

    while ($attempt -lt $MaxRetries -and -not $ok) {
        $attempt++
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lines = & node index.js @CliArgs 2>&1
        $exit  = $LASTEXITCODE
        $sw.Stop()

        Set-Content -Path $log -Value ($lines -join [Environment]::NewLine)

        $counts = Get-CountsFromOutput $lines
        $ok = ($exit -eq 0)

        $status = if ($ok) { "PASS" } else { "FAIL" }
        $color  = if ($ok) { "Green" } else { "Red" }
        Write-Host ("{0} (try {1}/{2})  Duration: {3}s  Collected:{4} Pages:{5} Dups:{6}" -f `
      $status, $attempt, $MaxRetries, [math]::Round($sw.Elapsed.TotalSeconds,1), $counts.Collected, $counts.Pages, $counts.Dups) -ForegroundColor $color

        if (-not $ok -and $attempt -lt $MaxRetries) {
            Start-Sleep -Milliseconds 800
        }
    }

    $swTotal.Stop()
    Write-Host ("Log: {0}" -f $log)
    if ($ok) { $PassRef.Value++ } else { $FailRef.Value++ }
    return @{ Ok = $ok; Counts = $counts; Log = $log; Seconds = [math]::Round($swTotal.Elapsed.TotalSeconds,1) }
}

function Get-IdsFromJsonRun([string[]]$CliArgs) {
    $lines = & node index.js @CliArgs 2>&1
    $exit = $LASTEXITCODE
    if ($exit -ne 0) { return @() }
    try {
        $json = $lines -join "`n" | ConvertFrom-Json
        if ($json.items) {
            return @($json.items | ForEach-Object { $_.id })
        }
    } catch { }
    return @()
}

function Compare-FirstN([int]$N, [string[]]$ArgsA, [string[]]$ArgsB, [string]$LogDir, [ref]$PassRef, [ref]$FailRef, [ref]$IndexRef) {
    $IndexRef.Value++
    $idx = '{0:D2}' -f $IndexRef.Value
    $log = Join-Path $LogDir ("{0}_compare_first_{1}.log" -f $idx, $N)

    Write-Host ("=== compare first {0} (100 vs 150) ===" -f $N) -ForegroundColor Cyan
    $idsA = Get-IdsFromJsonRun $ArgsA
    $idsB = Get-IdsFromJsonRun $ArgsB

    $same = $true
    for ($i=0; $i -lt $N; $i++) {
        if ($idsA[$i] -ne $idsB[$i]) { $same = $false; break }
    }

    $cmpLines = @()
    $cmpLines += ("A count: {0}" -f $idsA.Count)
    $cmpLines += ("B count: {0}" -f $idsB.Count)
    $cmpLines += ("A first {0}: {1}" -f $N, ($idsA[0..([Math]::Min($N,$idsA.Count)-1)] -join ','))
    $cmpLines += ("B first {0}: {1}" -f $N, ($idsB[0..([Math]::Min($N,$idsB.Count)-1)] -join ','))

    if ($same) {
        Write-Host ("COMPARE: PASS - first {0} IDs match." -f $N) -ForegroundColor Green
        $PassRef.Value++
    } else {
        Write-Host ("COMPARE: FAIL - first {0} IDs differ." -f $N) -ForegroundColor Red
        $FailRef.Value++
    }
    Set-Content -Path $log -Value ($cmpLines -join [Environment]::NewLine)
    Write-Host ("Log: {0}" -f $log)
}

# --------------- suite ---------------
$logRoot = New-LogRoot
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$passed = 0; $failed = 0; $testIdx = 0

do {
    # 1
    Invoke-TestCase -Name "count 50"  `
                  -Description "Collect first 50 posts" `
                  -CliArgs @("--count=50") `
                  -PassRef ([ref]$passed) -FailRef ([ref]$failed) -IndexRef ([ref]$testIdx) -LogDir $logRoot | Out-Null

    # 2
    Invoke-TestCase -Name "count 100" `
                  -Description "Collect first 100 posts" `
                  -CliArgs @("--count=100") `
                  -PassRef ([ref]$passed) -FailRef ([ref]$failed) -IndexRef ([ref]$testIdx) -LogDir $logRoot | Out-Null

    # 3
    Invoke-TestCase -Name "count 150" `
                  -Description "Collect first 150 posts" `
                  -CliArgs @("--count=150") `
                  -PassRef ([ref]$passed) -FailRef ([ref]$failed) -IndexRef ([ref]$testIdx) -LogDir $logRoot | Out-Null

    # 4
    Invoke-TestCase -Name "count 200" `
                  -Description "Collect first 200 posts" `
                  -CliArgs @("--count=200") `
                  -PassRef ([ref]$passed) -FailRef ([ref]$failed) -IndexRef ([ref]$testIdx) -LogDir $logRoot | Out-Null

    # 5
    Invoke-TestCase -Name "json 10" `
                  -Description "JSON mode, 10 items" `
                  -CliArgs @("--count=10","--json") `
                  -PassRef ([ref]$passed) -FailRef ([ref]$failed) -IndexRef ([ref]$testIdx) -LogDir $logRoot | Out-Null

    # 6
    Invoke-TestCase -Name "json 50" `
                  -Description "JSON mode, 50 items" `
                  -CliArgs @("--count=50","--json") `
                  -PassRef ([ref]$passed) -FailRef ([ref]$failed) -IndexRef ([ref]$testIdx) -LogDir $logRoot | Out-Null

    # 7 compare first 100 between 100 vs 150 (both JSON)
    Compare-FirstN -N 100 `
                 -ArgsA @("--count=100","--json") `
                 -ArgsB @("--count=150","--json") `
                 -LogDir $logRoot `
                 -PassRef ([ref]$passed) -FailRef ([ref]$failed) -IndexRef ([ref]$testIdx)

    # 8 FINAL: plain run MUST be last (your request)
    Invoke-TestCase -Name "final count 100" `
                  -Description "Final simple run: index.js --count=100" `
                  -CliArgs @("") `
                  -PassRef ([ref]$passed) -FailRef ([ref]$failed) -IndexRef ([ref]$testIdx) -LogDir $logRoot | Out-Null

    if ($Loop) {
        Write-Host "Suite complete. Press Ctrl+C to stop, or any key to rerun..." -NoNewline
        $null = [Console]::ReadKey($true)
        Write-Host ""
    }
} while ($Loop)

$totalSw.Stop()
Write-Host ("`n=== SUMMARY: {0}/{1} passed, {2} failed. Total time: {3}s ===" -f `
  $passed, $testIdx, $failed, [math]::Round($totalSw.Elapsed.TotalSeconds,1))
