# test_cli.ps1
# Runs the CLI test suite in a loop until Ctrl+X is pressed.
# Creates logs in .\logs\<timestamp>\ per test (one file per test).
# Compatible with Windows PowerShell 5.1+ (no null-coalescing, etc.)

$ErrorActionPreference = 'Stop'

# ---------- Logging helpers ----------
function New-RunLogDir {
    $root = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dir = Join-Path $root $stamp
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}

function Sanitize-FileName {
    param([string]$Name)
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $safe = $Name
    foreach ($ch in $invalid) { $safe = $safe -replace ([Regex]::Escape($ch)), '_' }
    $safe = $safe -replace '\s+', '_'  # collapse spaces
    return $safe
}

function Write-LogBlock {
    param(
        [string]$Path,
        [string]$Header,
        [string[]]$BodyLines
    )
    $divider = ('-' * 78)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $lines = @()
    $lines += $divider
    $lines += "$stamp  $Header"
    $lines += $divider
    $lines += $BodyLines
    $lines += ""
    $lines | Out-File -FilePath $Path -Encoding UTF8 -Append
}

# ---------- Result parsing ----------
function Parse-Result {
    param([string[]]$Lines)

    $text = ($Lines -join "`n")

    # Try JSON (when --json used)
    $json = $null
    try { $json = $text | ConvertFrom-Json -ErrorAction Stop } catch { }

    if ($json -ne $null) {
        $summary = $json.summary
        $col = 0; $pages = 0; $dups = 0
        if ($summary -ne $null) {
            if ($summary.collected -ne $null) { $col = [int]$summary.collected }
            if ($summary.pages -ne $null)     { $pages = [int]$summary.pages }
            if ($summary.dupSkipped -ne $null){ $dups = [int]$summary.dupSkipped }
        }
        return [pscustomobject]@{
            IsJson    = $true
            Collected = $col
            Pages     = $pages
            Dups      = $dups
            Json      = $json
        }
    }

    # Fallback: parse "Collected: X | Pages: Y | Dups: Z"
    $col = 0; $pages = 0; $dups = 0
    foreach ($line in $Lines) {
        if ($line -match 'Collected:\s*(\d+)\s*\|\s*Pages:\s*(\d+)\s*\|\s*Dups:\s*(\d+)') {
            $col   = [int]$matches[1]
            $pages = [int]$matches[2]
            $dups  = [int]$matches[3]
            break
        }
    }
    return [pscustomobject]@{
        IsJson    = $false
        Collected = $col
        Pages     = $pages
        Dups      = $dups
        Json      = $null
    }
}

# ---------- Test execution ----------
function Invoke-TestCase {
    param(
        [string]$Name,
        [string]$Description,
        [string[]]$CaseArgs,
        [string]$LogPath,
        [int]$MaxRetries = 2  # total tries = 1 + MaxRetries
    )

    Write-Host "=== $Name ===" -ForegroundColor Cyan
    if ($Description) { Write-Host "- $Description" -ForegroundColor DarkCyan }

    $attempt = 0
    $resultObj = $null

    while ($true) {
        $attempt++
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $output = & node .\index.js @CaseArgs 2>&1
        $exit   = $LASTEXITCODE
        $sw.Stop()

        # Log this attempt
        $hdr = ("{0} | args: {1} | attempt {2}" -f $Name, ($CaseArgs -join ' '), $attempt)
        Write-LogBlock -Path $LogPath -Header $hdr -BodyLines $output

        $parsed = Parse-Result -Lines $output
        $dur = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $pass = ($exit -eq 0)
        $status = if ($pass) { "PASS" } else { "FAIL" }
        $color  = if ($pass) { "Green" } else { "Red" }

        Write-Host ("{0} (exit {1})  Duration: {2}s  Collected:{3} Pages:{4} Dups:{5}" -f `
            $status, $exit, $dur, $parsed.Collected, $parsed.Pages, $parsed.Dups) -ForegroundColor $color
        Write-Host ("Log: {0}" -f $LogPath)

        $resultObj = [pscustomobject]@{
            Name      = $Name
            Attempt   = $attempt
            ExitCode  = $exit
            DurationS = $dur
            Collected = $parsed.Collected
            Pages     = $parsed.Pages
            Dups      = $parsed.Dups
            Passed    = $pass
            Output    = $output
            Json      = $parsed.Json
            Log       = $LogPath
        }

        if ($pass -or $attempt -gt $MaxRetries) { break }
        Write-Host ("Retrying (attempt {0}/{1})..." -f ($attempt+1), (1+$MaxRetries)) -ForegroundColor Yellow
    }

    Write-Host ""
    return $resultObj
}

function Compare-FirstN {
    param(
        [int]$N = 100,
        [string[]]$ArgsA = @("--count=100","--json"),
        [string[]]$ArgsB = @("--count=150","--json"),
        [string]$LogPath
    )

    $name = "compare_first_${N}_ids"
    Write-Host "=== $name ===" -ForegroundColor Cyan
    Write-Host "- Verifies first $N IDs are identical between 100 and 150 runs" -ForegroundColor DarkCyan

    $logHeader = "Comparison setup | A: {0} | B: {1}" -f ($ArgsA -join ' '), ($ArgsB -join ' ')
    Write-LogBlock -Path $LogPath -Header $logHeader -BodyLines @()

    $a = Invoke-TestCase -Name "json_100_A" -Description "JSON list for 100" -CaseArgs $ArgsA -LogPath $LogPath -MaxRetries 2
    $b = Invoke-TestCase -Name "json_150_B" -Description "JSON list for 150" -CaseArgs $ArgsB -LogPath $LogPath -MaxRetries 2

    if (-not ($a.Passed -and $b.Passed)) {
        $msg = "COMPARE: cannot compare because one or both runs failed."
        Write-Host $msg -ForegroundColor Red
        Write-LogBlock -Path $LogPath -Header "Comparison result" -BodyLines @($msg)
        return [pscustomobject]@{ Name=$name; Passed=$false; DurationS=($a.DurationS + $b.DurationS); Log=$LogPath }
    }

    $idsA = @()
    $idsB = @()
    if ($a.Json -ne $null -and $a.Json.items -ne $null) {
        $idsA = $a.Json.items | Select-Object -First $N | ForEach-Object { $_.id }
    }
    if ($b.Json -ne $null -and $b.Json.items -ne $null) {
        $idsB = $b.Json.items | Select-Object -First $N | ForEach-Object { $_.id }
    }

    $same = ($idsA.Count -eq $N -and $idsB.Count -eq $N -and ($idsA -join ',') -eq ($idsB -join ','))

    $cmpLines = @()
    $cmpLines += "A first $N: " + ($idsA -join ',')
    $cmpLines += "B first $N: " + ($idsB -join ',')
    $cmpLines += "MATCH: " + $same
    Write-LogBlock -Path $LogPath -Header "Comparison result" -BodyLines $cmpLines

    if ($same) {
    Write-Host "COMPARE: PASS – first $N IDs match." -ForegroundColor Green
    } else {
    Write-Host "COMPARE: FAIL – first $N IDs differ." -ForegroundColor Red
    }
    Write-Host ("Log: {0}" -f $LogPath)
    Write-Host ""
    return [pscustomobject]@{ Name=$name; Passed=$same; DurationS=($a.DurationS + $b.DurationS); Log=$LogPath }
}

# ---------- Suite ----------
function Invoke-TestSuite {
    param([string]$RunDir)

    # Define tests (no pacing; default max-pages=15 in index.js per your spec)
    $tests = @(
        @{ Name="count 50";   Desc="Basic run with 50 posts";     Args=@("--count=50");                 Retries=2 },
        @{ Name="count 100";  Desc="Basic run with 100 posts";    Args=@("--count=100");                Retries=2 },
        @{ Name="count 150";  Desc="Basic run with 150 posts";    Args=@("--count=150");                Retries=2 },
        @{ Name="count 200";  Desc="Basic run with 200 posts";    Args=@("--count=200");                Retries=2 },
        @{ Name="json 10";    Desc="JSON mode 10 posts";          Args=@("--count=10","--json");        Retries=2 },
        @{ Name="json 50";    Desc="JSON mode 50 posts";          Args=@("--count=50","--json");        Retries=2 },
        @{ Name="headed 100"; Desc="Visible browser (headed)";    Args=@("--count=100","--headed");     Retries=1 }
    )

    $suiteSW = [System.Diagnostics.Stopwatch]::StartNew()
    $pass = 0; $fail = 0
    $results = @()

    # Create log files per test (nn_name.log)
    for ($i=0; $i -lt $tests.Count; $i++) {
        $t = $tests[$i]
        $nn = "{0:D2}" -f ($i + 1)
        $file = "{0}_{1}.log" -f $nn, (Sanitize-FileName $t.Name)
        $t.Log = Join-Path $RunDir $file
        # Prepend header
        $hdr = "Test: {0} | Desc: {1} | Args: {2}" -f $t.Name, $t.Desc, ($t.Args -join ' ')
        Write-LogBlock -Path $t.Log -Header $hdr -BodyLines @()
    }

    # Run tests
    foreach ($t in $tests) {
        $r = Invoke-TestCase -Name $t.Name -Description $t.Desc -CaseArgs $t.Args -LogPath $t.Log -MaxRetries $t.Retries
        $results += $r
        if ($r.Passed) { $pass++ } else { $fail++ }
    }

    # Compare first 100 between 100 vs 150
    $cmpIdx = $tests.Count + 1
    $cmpFile = "{0:D2}_{1}.log" -f $cmpIdx, (Sanitize-FileName "compare first 100")
    $cmpLog  = Join-Path $RunDir $cmpFile
    $cmp = Compare-FirstN -N 100 -ArgsA @("--count=100","--json") -ArgsB @("--count=150","--json") -LogPath $cmpLog
    if ($cmp.Passed) { $pass++ } else { $fail++ }
    $results += $cmp

    $suiteSW.Stop()
    $dur = [math]::Round($suiteSW.Elapsed.TotalSeconds,1)
    $total = $pass + $fail

    # Summary to console
    Write-Host ("=== SUMMARY: {0}/{1} passed, {2} failed. Total time: {3}s ===" -f $pass,$total,$fail,$dur) -ForegroundColor Magenta

    # Summary file
    $summaryPath = Join-Path $RunDir "SUMMARY.txt"
    $summaryLines = @()
    $summaryLines += "Summary"
    $summaryLines += "======="
    $summaryLines += ("Passed: {0} / {1}, Failed: {2}, Total Seconds: {3}" -f $pass, $total, $fail, $dur)
    $summaryLines += ""
    $summaryLines += "Per-test:"
    foreach ($r in $results) {
        $summaryLines += ("- {0}: {1}, Collected={2}, Pages={3}, Dups={4}, Duration={5}s, Log={6}" -f `
            $r.Name, ($(if($r.Passed){"PASS"}else{"FAIL"})), $r.Collected, $r.Pages, $r.Dups, $r.DurationS, $r.Log)
    }
    $summaryLines | Out-File -FilePath $summaryPath -Encoding UTF8

    return [pscustomobject]@{
        Total   = $total
        Passed  = $pass
        Failed  = $fail
        Seconds = $dur
        Results = $results
        RunDir  = $RunDir
        Summary = $summaryPath
    }
}

# ---------- Main: loop until Ctrl+X ----------
while ($true) {
    $runDir = New-RunLogDir
    Write-Host ""
    Write-Host ("===== Test Run @ {0}  (logs: {1}) =====" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $runDir) -ForegroundColor White

    $suite = Invoke-TestSuite -RunDir $runDir

    Write-Host ""
    Write-Host "Press Ctrl+X to stop, or any key to run the suite again..." -NoNewline
    $k = [Console]::ReadKey($true)
    if ((($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -and ($k.Key -eq [ConsoleKey]::X)) {
        Write-Host ""
        Write-Host "Stopping on Ctrl+X." -ForegroundColor Yellow
        break
    }
    Write-Host ""
}
