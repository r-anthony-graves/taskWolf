# test_cli.ps1
# Windows PowerShell test harness for index.js

param(
    [switch]$Loop   # optional: run the whole suite repeatedly until key press
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
    if (-not $Lines) { return $result }
    $line = $Lines | Where-Object { $_ -match 'Collected:\s*\d+\s*\|\s*Pages:\s*\d+\s*\|\s*Dups:\s*\d+' } | Select-Object -Last 1
    if ($line) {
        if ($line -match 'Collected:\s*(\d+)') { $result.Collected = [int]$Matches[1] }
        if ($line -match 'Pages:\s*(\d+)')     { $result.Pages     = [int]$Matches[1] }
        if ($line -match 'Dups:\s*(\d+)')      { $result.Dups      = [int]$Matches[1] }
    }
    return $result
}

function Format-Duration([TimeSpan]$ts) {
    if ($ts.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}.{3:000}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds, $ts.Milliseconds)
    } else {
        return ('{0:00}:{1:00}.{2:000}' -f $ts.Minutes, $ts.Seconds, $ts.Milliseconds)
    }
}

# Reliable non-blocking keypress check with timeout
function Wait-Or-Stop([int]$TimeoutMs = 2000) {
    try {
        if ([System.Console]::IsInputRedirected) {
            Start-Sleep -Milliseconds $TimeoutMs
            return $false
        }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ([System.Console]::KeyAvailable) {
                [void][System.Console]::ReadKey($true) # consume the key
                return $true
            }
            Start-Sleep -Milliseconds 50
        }
        return $false
    } catch {
        Start-Sleep -Milliseconds $TimeoutMs
        return $false
    }
}

function Invoke-TestCase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $Name,
        [Parameter(Mandatory)] [string]   $Description,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $CliArgs,
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
        $lines = $null
        try {
            $lines = & node index.js @CliArgs 2>&1
            $exit  = $LASTEXITCODE
        } catch {
            $lines = @("EXCEPTION: $($_.Exception.Message)")
            $exit  = 1
        }
        $sw.Stop()

        Set-Content -Path $log -Value (($lines | ForEach-Object { "$_" }) -join [Environment]::NewLine)

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
    try {
        $lines = & node index.js @CliArgs 2>&1
        $exit  = $LASTEXITCODE
    } catch {
        return @()
    }
    if ($exit -ne 0 -or -not $lines) { return @() }
    try {
        $json = $lines -join "`n" | ConvertFrom-Json
        if ($null -eq $json) { return @() }
        $items = if ($json.PSObject.Properties.Name -contains 'items') { $json.items }
        elseif ($json.PSObject.Properties.Name -contains 'data') { $json.data }
        else { @() }
        $ids = @($items | ForEach-Object { $_.id } | Where-Object { $_ -ne $null })
        return $ids
    } catch { return @() }
}

function Compare-FirstN(
        [int]$N,
        [string[]]$ArgsA,
        [string[]]$ArgsB,
        [string]$LogDir,
        [ref]$PassRef,
        [ref]$FailRef,
        [ref]$IndexRef
) {
    $IndexRef.Value++
    $idx = '{0:D2}' -f $IndexRef.Value
    $log = Join-Path $LogDir ("{0}_compare_first_{1}.log" -f $idx, $N)

    Write-Host ("=== compare first {0} (A vs B) ===" -f $N) -ForegroundColor Cyan

    $idsA = @(Get-IdsFromJsonRun $ArgsA)
    $idsB = @(Get-IdsFromJsonRun $ArgsB)
    if ($null -eq $idsA) { $idsA = @() }
    if ($null -eq $idsB) { $idsB = @() }

    $cmpCount = [Math]::Min($N, [Math]::Min($idsA.Count, $idsB.Count))
    $same = $true
    for ($i = 0; $i -lt $cmpCount; $i++) {
        if ($idsA[$i] -ne $idsB[$i]) { $same = $false; break }
    }
    if ($cmpCount -lt $N) { $same = $false }

    $cmpLines = @()
    $cmpLines += ("A count: {0}" -f $idsA.Count)
    $cmpLines += ("B count: {0}" -f $idsB.Count)

    if ($idsA.Count -gt 0) {
        $aEnd = [Math]::Min($N, $idsA.Count) - 1
        $cmpLines += ("A first {0}: {1}" -f ([Math]::Min($N, $idsA.Count)), ($idsA[0..$aEnd] -join ','))
    } else { $cmpLines += ("A first {0}: " -f $N) }

    if ($idsB.Count -gt 0) {
        $bEnd = [Math]::Min($N, $idsB.Count) - 1
        $cmpLines += ("B first {0}: {1}" -f ([Math]::Min($N, $idsB.Count)), ($idsB[0..$bEnd] -join ','))
    } else { $cmpLines += ("B first {0}: " -f $N) }

    if ($same) {
        Write-Host ("COMPARE: PASS - first {0} IDs match." -f $N) -ForegroundColor Green
        $PassRef.Value++
    } else {
        Write-Host ("COMPARE: FAIL - first {0} IDs differ or insufficient items." -f $N) -ForegroundColor Red
        $FailRef.Value++
    }

    Set-Content -Path $log -Value ($cmpLines -join [Environment]::NewLine)
    Write-Host ("Log: {0}" -f $log)
}

# --------------- suite ---------------
$logRoot = New-LogRoot
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$passed = 0; $failed = 0; $testIdx = 0

$continueLoop = $true
$loopIdx = 0

while ($continueLoop) {
    $loopIdx++
    $loopSw = [System.Diagnostics.Stopwatch]::StartNew()

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

    # 7.5 headed mode test
    Invoke-TestCase -Name "headed 100" `
                  -Description "Headed mode (visible browser), 100 items" `
                  -CliArgs @("--count=100","--head") `
                  -PassRef ([ref]$passed) -FailRef ([ref]$failed) -IndexRef ([ref]$testIdx) -LogDir $logRoot | Out-Null

    # 8 FINAL: plain run MUST be last
    Write-Host ("=== final count 100 ===") -ForegroundColor Cyan
    Write-Host ("- Final simple run: index.js with no switches") -ForegroundColor DarkCyan

    $attempt = 0
    $maxRetries = 5
    $finalOk = $false

    while ($attempt -lt $maxRetries -and -not $finalOk) {
        $attempt++
        $lines = & node index.js 2>&1
        $exit = $LASTEXITCODE

        $lines | ForEach-Object { Write-Host $_ }

        $counts = Get-CountsFromOutput $lines
        $finalOk = ($exit -eq 0 -and $counts.Collected -ge 100)

        $status = if ($finalOk) { "PASS" } else { "FAIL" }
        $color = if ($finalOk) { "Green" } else { "Red" }
        Write-Host ("{0} (try {1}/{2})  Collected:{3}" -f $status, $attempt, $maxRetries, $counts.Collected) -ForegroundColor $color

        if (-not $finalOk -and $attempt -lt $maxRetries) { Start-Sleep -Milliseconds 800 }
    }

    if ($finalOk) { $passed++ } else { $failed++ }
    $testIdx++

    # ---- per-loop runtime ----
    $loopSw.Stop()
    $loopTime = Format-Duration $loopSw.Elapsed
    Write-Host ("`n*** Loop #{0} runtime: {1} ***" -f $loopIdx, $loopTime) -ForegroundColor Magenta

    # ---- LOOP CONTROL ----
    if (-not $Loop) {
        $continueLoop = $false
    } else {
        Write-Host "`n--- Loop iteration complete. Press any key to stop, or wait 2 seconds for next iteration ---" -ForegroundColor Yellow
        $stop = Wait-Or-Stop -TimeoutMs 2000
        if ($stop) { Write-Host "Key pressed. Stopping loop..." -ForegroundColor Yellow }
        $continueLoop = -not $stop
    }
}

$totalSw.Stop()
$totalMinutes = [math]::Floor($totalSw.Elapsed.TotalMinutes)
$totalSeconds = $totalSw.Elapsed.Seconds
$timeString = $totalMinutes.ToString("00") + ":" + $totalSeconds.ToString("00")
Write-Host ("`n=== SUMMARY: {0}/{1} passed, {2} failed. Total time: {3} ===" -f `
  $passed, $testIdx, $failed, $timeString)
