# test_cli.ps1  (Windows PowerShell 5.1 compatible, ASCII only)
# - Descriptions printed before each test
# - Retries failed tests up to 3 times
# - Logs each attempt to .\logs\<timestamp>\NN_<name>_attemptX.log
# - Per-test duration + overall summary runtime
# - Compares first 100 IDs: --count=100 --json  vs  --count=150 --json (first 100)
# - Final test: node index.js --count=100 verbose

$ErrorActionPreference = "Continue"

# -------- Globals --------
$script:PassCount = 0
$script:FailCount = 0
$script:CaseSeq   = 0
$script:RunStart  = Get-Date
$PauseBetweenMs   = 500

# Logs root
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$logDir = Join-Path "." ("logs\" + $stamp)
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function New-LogPath([string]$Name, [int]$Attempt = 1) {
    $script:CaseSeq++
    $safe = ($Name -replace '[^\w\-]+','_')
    $file = "{0:D2}_{1}_attempt{2}.log" -f $script:CaseSeq, $safe, $Attempt
    return (Join-Path $logDir $file)
}

function Parse-Counts([string[]]$Lines) {
    # Prefer JSON output; fallback to human summary line
    $text = $Lines -join "`n"

    # Try JSON
    $json = $null
    try { $json = $text | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
    if ($json -ne $null -and $json.summary -ne $null) {
        $dups = 0
        if ($json.summary.PSObject.Properties.Match('dupSkipped').Count -gt 0 -and $json.summary.dupSkipped -ne $null) {
            $dups = [int]$json.summary.dupSkipped
        }
        return @{
            Collected = [int]$json.summary.collected
            Pages     = [int]$json.summary.pages
            Dups      = $dups
        }
    }

    # Fallback: "Collected: N | Pages: M | Dups: K"
    $m = [regex]::Match($text, 'Collected:\s*(\d+)\s*\|\s*Pages:\s*(\d+)\s*\|\s*Dups:\s*(\d+)', 'IgnoreCase')
    if ($m.Success) {
        return @{
            Collected = [int]$m.Groups[1].Value
            Pages     = [int]$m.Groups[2].Value
            Dups      = [int]$m.Groups[3].Value
        }
    }

    return $null
}

function Invoke-TestCase {
    <#
.SYNOPSIS
  Runs one test with retries and prints a short description.
.PARAMETER Name
  Short display name (used in logs).
.PARAMETER Description
  What is being validated.
.PARAMETER ArgumentList
  Arguments for: node index.js
.PARAMETER MaxRetries
  Number of attempts (default 3).
#>
    param(
        [string]$Name,
        [string]$Description,
        [string[]]$ArgumentList,
        [int]$MaxRetries = 3
    )

    Write-Host ("=== {0} ===" -f $Name) -ForegroundColor Cyan
    Write-Host ("- {0}" -f $Description) -ForegroundColor DarkCyan

    $attempt = 0
    $passed  = $false
    $finalCounts = $null
    $finalExit   = $null

    $caseTimer = [System.Diagnostics.Stopwatch]::StartNew()

    while (-not $passed -and ($attempt -lt $MaxRetries)) {
        $attempt++
        $logPath = New-LogPath -Name $Name -Attempt $attempt

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $output = & node index.js @ArgumentList 2>&1 | Tee-Object -FilePath $logPath
        $exit   = $LASTEXITCODE
        $sw.Stop()

        $counts = Parse-Counts $output

        if ($exit -eq 0) { $passed = $true }
        $finalExit   = $exit
        $finalCounts = $counts

        if ($passed) {
            $col = if ($counts -ne $null -and $counts.ContainsKey('Collected')) { $counts.Collected } else { -1 }
            $pag = if ($counts -ne $null -and $counts.ContainsKey('Pages'))     { $counts.Pages }     else { -1 }
            $dup = if ($counts -ne $null -and $counts.ContainsKey('Dups'))      { $counts.Dups }      else { -1 }
            Write-Host ("PASS (exit 0)  Duration: {0:N1}s  Collected:{1} Pages:{2} Dups:{3}" -f `
                $sw.Elapsed.TotalSeconds, $col, $pag, $dup) -ForegroundColor Green
            Write-Host ("Log: {0}" -f $logPath)
        } else {
            Write-Host ("Attempt {0}/{1} FAILED (exit {2}). Retrying..." -f $attempt, $MaxRetries, $exit) -ForegroundColor Yellow
            Write-Host ("Log: {0}" -f $logPath)
            Start-Sleep -Milliseconds 700
        }
    }

    $caseTimer.Stop()
    if ($passed) {
        $script:PassCount++
    } else {
        $col = if ($finalCounts -ne $null -and $finalCounts.ContainsKey('Collected')) { $finalCounts.Collected } else { -1 }
        $pag = if ($finalCounts -ne $null -and $finalCounts.ContainsKey('Pages'))     { $finalCounts.Pages }     else { -1 }
        $dup = if ($finalCounts -ne $null -and $finalCounts.ContainsKey('Dups'))      { $finalCounts.Dups }      else { -1 }
        Write-Host ("FAIL (exit {0})  Duration: {1:N1}s  Collected:{2} Pages:{3} Dups:{4}" -f `
            $finalExit, $caseTimer.Elapsed.TotalSeconds, $col, $pag, $dup) -ForegroundColor Red
        $script:FailCount++
    }

    Write-Host ""
    Start-Sleep -Milliseconds $PauseBetweenMs
}

function Invoke-CompareFirst100 {
    Write-Host "=== compare first 100: 100 vs 150 ===" -ForegroundColor Cyan
    Write-Host "- Validates that the first 100 post IDs match between the 100-post run and the 150-post run." -ForegroundColor DarkCyan

    $ok = $false
    $attempt = 0
    $max = 3
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    while (-not $ok -and ($attempt -lt $max)) {
        $attempt++
        $logA = New-LogPath "compare_A_100_json" $attempt
        $logB = New-LogPath "compare_B_150_json" $attempt

        $outA = & node index.js --count=100 --json 2>&1 | Tee-Object -FilePath $logA
        $exitA = $LASTEXITCODE
        $outB = & node index.js --count=150 --json 2>&1 | Tee-Object -FilePath $logB
        $exitB = $LASTEXITCODE

        try {
            $jsonA = ($outA -join "`n") | ConvertFrom-Json
            $jsonB = ($outB -join "`n") | ConvertFrom-Json

            $idsA = @()
            $idsB = @()
            if ($jsonA -ne $null -and $jsonA.items -ne $null) {
                $idsA = @($jsonA.items | Select-Object -First 100 | Select-Object -ExpandProperty id)
            }
            if ($jsonB -ne $null -and $jsonB.items -ne $null) {
                $idsB = @($jsonB.items | Select-Object -First 100 | Select-Object -ExpandProperty id)
            }

            if ($exitA -eq 0 -and $exitB -eq 0 -and $idsA.Count -ge 100 -and $idsB.Count -ge 100) {
                $mismatch = -1
                for ($i=0; $i -lt 100; $i++) {
                    if ($idsA[$i] -ne $idsB[$i]) { $mismatch = $i; break }
                }
                if ($mismatch -eq -1) {
                    $ok = $true
                    Write-Host ("PASS (first 100 IDs match). Attempt {0}/{1}" -f $attempt, $max) -ForegroundColor Green
                    Write-Host ("Logs: {0} , {1}" -f $logA, $logB)
                } else {
                    Write-Host ("Mismatch at index {0}: A={1} vs B={2}" -f $mismatch, $idsA[$mismatch], $idsB[$mismatch]) -ForegroundColor Yellow
                }
            } else {
                Write-Host ("One or both runs failed or returned too few items (A exit={0}, B exit={1})." -f $exitA, $exitB) -ForegroundColor Yellow
            }
        } catch {
            Write-Host "JSON parse error while comparing. Will retry..." -ForegroundColor Yellow
        }

        if (-not $ok -and $attempt -lt $max) { Start-Sleep -Milliseconds 700 }
    }

    $timer.Stop()
    if ($ok) {
        $script:PassCount++
        Write-Host ("PASS  Duration: {0:N1}s" -f $timer.Elapsed.TotalSeconds) -ForegroundColor Green
    } else {
        $script:FailCount++
        Write-Host ("FAIL  Duration: {0:N1}s" -f $timer.Elapsed.TotalSeconds) -ForegroundColor Red
    }
    Write-Host ""
    Start-Sleep -Milliseconds $PauseBetweenMs
}

# -------- Test Matrix --------

Invoke-TestCase -Name "count 50"  -Description "Collects 50 posts; headless default output." `
    -ArgumentList @("--count=50")

Invoke-TestCase -Name "count 100" -Description "Collects 100 posts; headless default output." `
    -ArgumentList @("--count=100")

Invoke-TestCase -Name "count 150" -Description "Collects 150 posts; checks deeper pagination." `
    -ArgumentList @("--count=150")

Invoke-TestCase -Name "count 200" -Description "Collects 200 posts; default max-pages=15 may be insufficient (expected to fail sometimes)." `
    -ArgumentList @("--count=200")

Invoke-TestCase -Name "json 10"   -Description "Returns JSON for 10 posts; quick JSON validation." `
    -ArgumentList @("--count=10","--json")

Invoke-TestCase -Name "json 50"   -Description "Returns JSON for 50 posts; JSON output size check." `
    -ArgumentList @("--count=50","--json")

Invoke-CompareFirst100

# Final requested run
Invoke-TestCase -Name "count 100 verbose" -Description "Runs 100 posts." `
    -ArgumentList @("--count=100")

# -------- Summary --------
$elapsed = (Get-Date) - $script:RunStart
$secs = [math]::Round($elapsed.TotalSeconds,1)
$total = $script:PassCount + $script:FailCount
Write-Host ("=== SUMMARY: {0}/{1} passed, {2} failed. Total time: {3}s ===" -f `
    $script:PassCount, $total, $script:FailCount, $secs)
