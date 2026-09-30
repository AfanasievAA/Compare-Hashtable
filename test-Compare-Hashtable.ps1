<#
.SYNOPSIS
Test script for Compare-Hashtable.ps1 (synthetic data + result verification + timing).
.DESCRIPTION
Generates synthetic hashtables once at startup, then runs a series of comparison
scenarios and verifies the returned differences against expected results.
Outputs per-scenario timing for speed evaluation.
.NOTES
  Version:        1.0
  Author:         Andrew Afanasiev
  Date:           30 Sep 2026
  Contacts:       AfanasievAA@yandex.ru

#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# --- Load the function under test ---------------------------------------------------
. "$PSScriptRoot\Compare-Hashtable.ps1"

# --- Helpers -------------------------------------------------------------------------

function New-SyntheticValue {
    <# Generates one synthetic scalar/array value for a given key and mode. #>
    param([int]$Key, [string]$Mode)
    switch ($Mode) {
        'same'    { if ($Key % 3 -eq 0) { "value_$Key" } elseif ($Key % 3 -eq 1) { $Key } else { ,([byte[]](($Key % 256), (($Key + 1) % 256), (($Key + 2) % 256))) } }
        'changed' { if ($Key % 3 -eq 0) { "changed_$Key" } elseif ($Key % 3 -eq 1) { $Key + 1 } else { ,([byte[]](($Key % 256), (($Key + 128) % 256), (($Key + 130) % 256))) } }
        default   { $null }
    }
}

function New-SyntheticTable {
    <# Builds a hashtable with a given size, mutation mode and key offset. #>
    param([int]$Size, [string]$Mode, [int]$Offset = 0)
    $t = @{}
    for ($i = 0; $i -lt $Size; $i++) {
        $k = "key_$($i + $Offset)"
        $t[$k] = New-SyntheticValue -Key ($i + $Offset) -Mode $Mode
    }
    return $t
}

function Test-Scenario {
    <# Runs one comparison scenario, verifies the diff and returns timing info. #>
    param([string]$Name, [hashtable]$Left, [hashtable]$Right, [int]$ExpectedCount)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $diff = Compare-Hashtable $Left $Right
    $sw.Stop()
    $ok = $true
    if ($diff.Count -ne $ExpectedCount) { $ok = $false }
    # Verify each expected side marker is present exactly in the expected bucket
    $sides = @{}
    foreach ($d in $diff) {
        if (-not $sides.ContainsKey($d.side)) { $sides[$d.side] = 0 }
        $sides[$d.side]++
    }
    $detail = "side counts: <= $($sides['<=']) != $($sides['!=']) => $($sides['=>'])"
    [pscustomobject]@{
        Scenario = $Name
        LeftSize = $Left.Count
        RightSize = $Right.Count
        Diff     = $diff.Count
        Expected = $ExpectedCount
        Result   = if ($ok) { 'PASS' } else { 'FAIL' }
        Detail   = $detail
        Ms       = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
    }
}

# --- Synthetic data (generated once) --------------------------------------------------

$Sizes = 100, 1000, 10000, 100000
$Tables = @{}
foreach ($s in $Sizes) {
    # identical / changed / partially overlapping (10% removed + 10% added)
    $Tables["${s}_same"]    = New-SyntheticTable -Size $s -Mode 'same' -Offset 0
    $Tables["${s}_changed"] = New-SyntheticTable -Size $s -Mode 'changed' -Offset 0
    # offset s/10 -> 90% key overlap: 10% left-only, 10% right-only
    $Tables["${s}_removed"] = New-SyntheticTable -Size $s -Mode 'same' -Offset ([math]::Floor($s / 10))
}
Write-Host ('Synthetic data generated: {0} tables, sizes {1}' -f ($Tables.Count), ($Sizes -join ', ')) -ForegroundColor Cyan

# --- Correctness checks (small tables, full verification) -----------------------------

$small = @{ a = 1; b = 2; c = 3; f = $null; g = 6 }
$smallR = @{ b = 2; c = 4; e = 5; f = $null; g = $null }
$r = Compare-Hashtable $small $smallR
$correct = ($r.Count -eq 4) -and
    ($r | Where-Object { $_.key -eq 'a' -and $_.side -eq '<=' -and $_.lvalue -eq 1 }) -and
    ($r | Where-Object { $_.key -eq 'c' -and $_.side -eq '!=' -and $_.lvalue -eq 3 -and $_.rvalue -eq 4 }) -and
    ($r | Where-Object { $_.key -eq 'e' -and $_.side -eq '=>' -and $_.rvalue -eq 5 }) -and
    ($r | Where-Object { $_.key -eq 'g' -and $_.side -eq '!=' -and $_.rvalue -eq $null })
Write-Host ("Doc example: " + $(if ($correct) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($correct) { 'Green' } else { 'Red' })

# case-insensitive strings / numeric unification / mixed types
$eq = (Compare-Hashtable @{ s = 'AbC'; n = 3 } @{ s = 'abc'; n = 3.0 }).Count -eq 0
$ne = (Compare-Hashtable @{ x = 1 } @{ x = '1' }).Count -eq 1
Write-Host ("Equality rules (string case, 3 -eq 3.0, 1 -ne '1'): " + $(if ($eq -and $ne) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($eq -and $ne) { 'Green' } else { 'Red' })

# --- Timed scenarios ------------------------------------------------------------------

$results = foreach ($s in $Sizes) {
    $del = [math]::Floor($s / 10)
    # expected: identical -> 0; fully changed -> s; overlap (90% shared, values equal) -> 2 * 10% keys
    Test-Scenario -Name "Identical_$s"       -Left $Tables["${s}_same"]    -Right $Tables["${s}_same"]    -ExpectedCount 0
    Test-Scenario -Name "FullyChanged_$s"    -Left $Tables["${s}_same"]    -Right $Tables["${s}_changed"] -ExpectedCount $s
    Test-Scenario -Name "Overlap_${s}_10pct" -Left $Tables["${s}_same"]    -Right $Tables["${s}_removed"] -ExpectedCount (2 * $del)
}

# --- Large-table stress test (single comparison of the biggest tables) ------------------

$bigL = New-SyntheticTable -Size 500000 -Mode 'same'
$bigR = New-SyntheticTable -Size 500000 -Mode 'changed'
$bigExpected = 500000
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$bigDiff = Compare-Hashtable $bigL $bigR
$sw.Stop()
$results += [pscustomobject]@{
    Scenario = 'Stress_500000'
    LeftSize = $bigL.Count
    RightSize = $bigR.Count
    Diff     = $bigDiff.Count
    Expected = $bigExpected
    Result   = if ($bigDiff.Count -eq $bigExpected) { 'PASS' } else { 'FAIL' }
    Detail   = 'fully changed tables'
    Ms       = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
}
Remove-Variable bigL, bigR, bigDiff

# --- Timing benchmark: same comparison repeated N times ---------------------------------

$benchL = $Tables['100000_same']
$benchR = $Tables['100000_changed']
$iters = 5
$bench = for ($i = 1; $i -le $iters; $i++) {
    $sw.Restart()
    $null = Compare-Hashtable $benchL $benchR
    $sw.Stop()
    [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
}
$avg = [math]::Round(($bench | Measure-Object -Average).Average, 3)
Write-Host ("Benchmark 100k fully changed, $iters runs: avg ${avg} ms (runs: " + ($bench -join ', ') + ' ms)') -ForegroundColor Cyan

# --- Summary -----------------------------------------------------------------------------

$results | Format-Table Scenario, LeftSize, RightSize, Diff, Expected, Result, Ms -AutoSize
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' })
if ($failed.Count -gt 0) {
    Write-Host ("FAILED scenarios: " + ($failed.Scenario -join ', ')) -ForegroundColor Red
    exit 1
} else {
    Write-Host 'All scenarios passed.' -ForegroundColor Green
    exit 0
}