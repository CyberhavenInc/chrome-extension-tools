<#
.SYNOPSIS
  Wrapper script for scan.ps1, similar to scan_wrapper.sh in Bash.

.DESCRIPTION
  1. Removes any leftover .zip from previous runs.
  2. Calls scan.ps1 quietly (redirecting output to $null).
  3. If no new ZIP is found, prints green message "No extension was found."
  4. Otherwise unzips, checks the JSON for matched extensions, and prints details.

.PARAMETER ZipOutputPath
  The path to the resulting ZIP file that scan.ps1 should produce.

.EXAMPLE
  .\scan_wrapper.ps1 -ZipOutputPath 'C:\temp\found_extensions.zip'

#>

param(
    [switch]$Verb,
    [Parameter(Mandatory = $true)]
    [string]$ZipOutputPath
)

Set-StrictMode -Version Latest

# 1) Remove any stale zip
if (Test-Path $ZipOutputPath) {
    Remove-Item $ZipOutputPath -Force
}

Write-Host "Running scan.ps1 quietly, this may take a while..."
try {
    powershell -NoProfile -File .\scan.ps1 $ZipOutputPath > $null 2>&1
}
catch {
    Write-Host "Error calling scan.ps1: $($_.Exception.Message)"
    exit 1
}

# 3) Check if the zip was created
if (-not (Test-Path $ZipOutputPath)) {
    Write-Host "No extension was found." -ForegroundColor Green
    exit 0
}

# 4) If the zip exists, parse the JSON inside
$tempDir = New-TemporaryFile  # create a temp file placeholder
Remove-Item $tempDir -Force   # remove the file placeholder
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    Expand-Archive -Path $ZipOutputPath -DestinationPath $tempDir -Force
}
catch {
    Write-Host "Error unzipping '$ZipOutputPath': $($_.Exception.Message)"
    Remove-Item $tempDir -Recurse -Force
    exit 1
}

# Find scan_result.json
$scanJson = Get-ChildItem -Path $tempDir -Filter "scan_result.json" -Recurse -File | Select-Object -First 1

if (-not $scanJson) {
    Write-Host "No extension was found." -ForegroundColor Green
    Remove-Item $tempDir -Recurse -Force
    exit 0
}

# ConvertFrom-Json
try {
    $scanResult = Get-Content -Path $scanJson.FullName -Raw | ConvertFrom-Json
}
catch {
    Write-Host "Error parsing JSON from $($scanJson.FullName)."
    Remove-Item $tempDir -Recurse -Force
    exit 1
}

if (-not $scanResult.found) {
    Write-Host "No extension was found." -ForegroundColor Green
    Remove-Item $tempDir -Recurse -Force
    exit 0
}

# Count how many matched
$foundCount = $scanResult.found.Count
if ($foundCount -eq 0) {
    Write-Host "No extension was found." -ForegroundColor Green
    Remove-Item $tempDir -Recurse -Force
    exit 0
}

Write-Host "Number of extensions containing the specified strings:" $foundCount -ForegroundColor Red
Write-Host "Extensions found:"

foreach ($ext in $scanResult.found) {
    Write-Host "User:" $ext.user -ForegroundColor Red
    Write-Host "Hostname:" $scanResult.hostname -ForegroundColor Red
    Write-Host "SN:" $scanResult.serial_number -ForegroundColor Red
    Write-Host "Browser:" $ext.browser -ForegroundColor Red
    Write-Host "Profile:" $ext.profile -ForegroundColor Red
    Write-Host "Extension ID:" $ext.extensionId -ForegroundColor Red

    Write-Host "Matched Strings:" -ForegroundColor Red
    if (-not $ext.matches) {
        Write-Host "   (None listed?)"
    }
    else {
        # The JSON has an array of objects: { "file":"...", "strings":[...] }
        foreach ($m in $ext.matches) {
            $filePath = $m.file
            # strings might be an array. Let's see if we can just loop them
            $matchedStrings = $m.strings
            if (-not $matchedStrings) {
                Write-Host "   File: $filePath => (no strings?)" -ForegroundColor Red
            }
            else {
                Write-Host "   File: $filePath" -ForegroundColor Red
                foreach ($str in $matchedStrings) {
                    Write-Host "      $str" -ForegroundColor Red
                }
            }
        }
    }
}

Remove-Item $tempDir -Recurse -Force