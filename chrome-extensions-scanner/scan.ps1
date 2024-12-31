<#
.SYNOPSIS
  Scans Chrome-family extensions for certain strings and zips matched extensions.

.DESCRIPTION
  - Enumerates all Chrome-family extensions by scanning the typical Windows "Extensions" folder
    in each browser profile under each user. (Adjust paths as needed.)
  - Searches extension code & LevelDB data for specified strings, recording which patterns matched in which files.
  - Writes a JSON summary with user/browser/profile/extension + matched files -> matched strings.
  - Archives all copied extensions into a .zip, skipping if none matched.
  - Extracts the extension settings
  - Prints which strings were matched when an extension matches.
  - Also announces for each pattern if it found something or not.
  - Optional -Verb switch for logging intermediate steps.

.NOTES
  - Requires PowerShell 5+ or PowerShell Core.
  - Might need to run in an elevated prompt if scanning all users.

.EXAMPLE
  .\scan.ps1 -Verb "C:\temp\found_extensions.zip"
#>

param(
    [switch]$Verb,
    [Parameter(Mandatory = $true)]
    [string]$ZipOutputPath
)

Set-StrictMode -Version Latest

# ------------------------ CONFIGURABLE SECTION ------------------------
# Typical Chrome-based browser data paths on Windows:
# (Adjust if your environment uses different paths or additional browsers.)

$BROWSERS = @{
    "Chrome" = "AppData\Local\Google\Chrome\User Data"
    # "Brave"  = "AppData\Local\BraveSoftware\Brave-Browser\User Data"
    # "Edge"   = "AppData\Local\Microsoft\Edge\User Data"
    # "Chromium" = "AppData\Local\Chromium\User Data"
}

# The strings (and base64-encoded forms) to search for:
$SEARCH_STRINGS = @(
    "api.cyberhavenext.pro",
    "api/saveQR",
    "ads/ad_limits",
    "qr/show/code",
    "_ext_manage",
    "_ext_log",

    # base64 representations
    "YXBpLmN5YmVyaGF2ZW5leHQucHJv",
    "YXBpL3NhdmVRUg",
    "YWRzL2FkX2xpbWl0cw",
    "cXIvc2hvdy9jb2Rl",
    "ZXh0X21hbmFnZQ",
    "ZXh0X2xvZw"
)

# ------------------------ HELPER FUNCTIONS ------------------------
function Log-VerboseMsg {
    param([string]$Message)
    if ($Verb) {
        Write-Host "[VERBOSE] $Message"
    }
}

# ------------------------ MAIN SCRIPT LOGIC ------------------------

# Convert Zip path to an absolute full path:
$ZipOutputPath = (Resolve-Path $ZipOutputPath).Path

# Create a temporary working folder
$TempFolder = New-TemporaryFile
Remove-Item $TempFolder
New-Item -ItemType Directory -Path $TempFolder | Out-Null
Log-VerboseMsg "Temporary directory: $TempFolder"

$DateStr = Get-Date -Format "yyyyMMdd_HHmmss"
$TopDirName = "scan-results-$DateStr"
$CollectDir = Join-Path $TempFolder $TopDirName
New-Item -ItemType Directory -Path $CollectDir | Out-Null

# We'll store partial match info in a text file (for debugging/tracing).
$MatchesFile = Join-Path $TempFolder "found_strings.txt"
Set-Content -Path $MatchesFile -Value ""  # empty it out
Log-VerboseMsg "Matches file: $MatchesFile"

# ----------------------------------------------------
#  1) Enumerate possible extension directories,
#     and store them in a structured list of objects
#     that also contains a "Matches" dictionary.
# ----------------------------------------------------
$ExtensionEntries = New-Object System.Collections.Generic.List[PSObject]

Log-VerboseMsg "Enumerating extensions..."

$UserBaseDir = "$env:SystemDrive\Users"
Write-Host "Scanning under: $UserBaseDir"

foreach ($userDir in Get-ChildItem -Path $UserBaseDir -Directory -ErrorAction SilentlyContinue) {
    $userName = $userDir.BaseName

    foreach ($browserName in $BROWSERS.Keys) {
        $browserRelPath = $BROWSERS[$browserName]
        $fullBrowserPath = Join-Path $userDir.FullName $browserRelPath
        if (-Not (Test-Path $fullBrowserPath)) {
            Log-VerboseMsg "Skipping: $fullBrowserPath (doesn't exist)"
            continue
        }

        # For Chrome-like browsers, profiles are typically "Default", "Profile 1", "Profile 2", etc.
        $candidateProfiles = @(
            "Default"
            "Profile *"
        )

        foreach ($profileGlob in $candidateProfiles) {
            foreach ($profileDir in (Get-ChildItem -Path $fullBrowserPath -Filter $profileGlob -Directory -ErrorAction SilentlyContinue)) {
                $profileName = $profileDir.BaseName
                $extensionsDir = Join-Path $profileDir.FullName "Extensions"
                if (-Not (Test-Path $extensionsDir)) {
                    Log-VerboseMsg "Skipping: $extensionsDir (doesn't exist)"
                    continue
                }

                $dataDir = Join-Path $profileDir.FullName "Local Extension Settings"
                $prefsSrc = Join-Path $profileDir.FullName "Preferences"

                # Each folder in "Extensions" is named by extension ID
                foreach ($extIdDir in (Get-ChildItem -Path $extensionsDir -Directory -ErrorAction SilentlyContinue)) {
                    $extId = $extIdDir.BaseName
                    $codePath = $extIdDir.FullName

                    $localExtSubdir = Join-Path $dataDir $extId
                    $dataPath = if (Test-Path $localExtSubdir) { $localExtSubdir } else { $null }

                    $ExtensionEntries.Add(
                        [PSCustomObject]@{
                            UserName        = $userName
                            BrowserName     = $browserName
                            ProfileName     = $profileName
                            ExtensionId     = $extId
                            CodePath        = $codePath
                            DataPath        = $dataPath
                            PreferencesFile = $prefsSrc

                            # We'll store matches as a dictionary: filePath -> set of patterns found
                            Matches         = New-Object 'System.Collections.Generic.Dictionary[String,System.Collections.Generic.HashSet[String]]'
                        }
                    ) | Out-Null
                }
            }
        }
    }
}

$extensionCount = $ExtensionEntries.Count
Write-Host "Number of extension directories to scan: $extensionCount"

if ($extensionCount -eq 0) {
    Write-Host "No extensions found to scan."
    Remove-Item $TempFolder -Recurse -Force
    exit 0
}

# ----------------------------------------------------
#  2) For each pattern, do a single pass across the
#     union of all code/data paths.
#     We record which files matched in the "Matches" dict.
# ----------------------------------------------------
$patternCount = $SEARCH_STRINGS.Count
$patternIndex = 0

$allScanDirs =
    ($ExtensionEntries | ForEach-Object { $_.CodePath }) +
    ($ExtensionEntries | ForEach-Object { $_.DataPath }) |
    Where-Object { $_ -ne $null } |
    Select-Object -Unique

foreach ($s in $SEARCH_STRINGS) {
    $patternIndex++
    Write-Host "[$patternIndex/$patternCount] Searching for pattern: $s"

    $patternMatches = New-Object System.Collections.Generic.List[string]

    foreach ($scanDir in $allScanDirs) {
        if (-not (Test-Path $scanDir)) { continue }

        try {
            $fileHits = Get-ChildItem -Path $scanDir -File -Recurse -ErrorAction SilentlyContinue |
                        Select-String -Pattern $s -SimpleMatch -List -ErrorAction SilentlyContinue

            foreach ($hit in $fileHits) {
                $patternMatches.Add($hit.Path) | Out-Null
                Add-Content -Path $MatchesFile -Value ("{0}:::{1}" -f $hit.Path, $s)

                # Figure out which extension "owns" this file
                $owner = $ExtensionEntries | Where-Object {
                    ($_.CodePath -and $hit.Path -like "$($_.CodePath)*") -or
                    ($_.DataPath -and $hit.Path -like "$($_.DataPath)*")
                } | Select-Object -First 1

                if ($null -ne $owner) {
                    if (-not $owner.Matches.ContainsKey($hit.Path)) {
                        $owner.Matches[$hit.Path] = New-Object 'System.Collections.Generic.HashSet[String]'
                    }
                    $owner.Matches[$hit.Path].Add($s) | Out-Null
                }

                if ($Verb) {
                    Write-Host "[VERBOSE] Matched '$s' in $($hit.Path)"
                }
            }
        } catch {
            # Swallow errors from locked/inaccessible files
        }
    }

    if ($patternMatches.Count -gt 0) {
        Write-Host "   => Found $($patternMatches.Count) file(s) containing '$s'"
        if ($Verb) {
            $patternMatches | ForEach-Object { Write-Host "      $_" }
        }
    }
    else {
        Write-Host "   => No matches for '$s'"
    }
}

# If no lines in $MatchesFile, skip zipping
if ((Get-Item $MatchesFile).Length -eq 0) {
    Write-Host "No matching extensions found. Not creating zip."
    Remove-Item $TempFolder -Recurse -Force
    exit 0
}

# ----------------------------------------------------
#  3) Copy extension code and data if it had a match.
#     Extract the settings of the extension from the
#     Preferences file
# ----------------------------------------------------
Log-VerboseMsg "Final pass: building JSON and copying matched extensions..."

$foundAny = $false

foreach ($entry in $ExtensionEntries) {
    # If extension has zero matches, skip
    if ($entry.Matches.Count -eq 0) { continue }

    $foundAny = $true
    $userName    = $entry.UserName
    $browserName = $entry.BrowserName
    $profileName = $entry.ProfileName
    $extId       = $entry.ExtensionId
    $codePath    = $entry.CodePath
    $dataPath    = $entry.DataPath
    $prefsSrc    = $entry.PreferencesFile

    Write-Host "=> Matched extension: $extId (user=$userName, browser=$browserName, profile=$profileName)"

    # For printing: gather all unique patterns
    $allPatterns = New-Object System.Collections.Generic.HashSet[string]
    foreach ($filePath in $entry.Matches.Keys) {
        $allPatterns.UnionWith($entry.Matches[$filePath]) | Out-Null
    }
    $uniqueStrings = $allPatterns | Sort-Object
    Write-Host "   Matched strings: [$(($uniqueStrings) -join ', ')]"

    # Copy extension to $CollectDir
    $destDir = Join-Path (Join-Path (Join-Path (Join-Path $CollectDir $userName) $browserName) $profileName) $extId
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null

    # Copy extension code
    if (Test-Path $codePath) {
        $extCodeDest = Join-Path $destDir "extension_code"
        New-Item -ItemType Directory -Path $extCodeDest -Force | Out-Null
        Copy-Item -Path (Join-Path $codePath '*') -Destination $extCodeDest -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Copy extension data
    if ($dataPath -and (Test-Path $dataPath)) {
        $extDataDest = Join-Path $destDir "extension_data"
        New-Item -ItemType Directory -Path $extDataDest -Force | Out-Null
        Copy-Item -Path (Join-Path $dataPath '*') -Destination $extDataDest -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Extract only extension.settings from Preferences
    $extensionSettingsJson = "{}"
    if (Test-Path $prefsSrc) {
        try {
            $prefsObj = Get-Content -Path $prefsSrc -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($prefsObj.extensions -and $prefsObj.extensions.settings) {
                $extensionSettingsJson = $prefsObj.extensions.settings | ConvertTo-Json -Depth 20
            }
        } catch {
            # If parsing fails, keep it as "{}"
        }
        Set-Content -Path (Join-Path $destDir "extension_settings.json") -Value $extensionSettingsJson
    }
}

if (-not $foundAny) {
    Write-Host "No matching extensions found after final check. Not creating zip."
    Remove-Item $TempFolder -Recurse -Force
    exit 0
}

# -------------- Build Final JSON --------------
# Create recap JSON with all the matches.
# ----------------------------------------------
$JsonArray = $ExtensionEntries |
    Where-Object { $_.Matches.Count -gt 0 } |
    ForEach-Object {
        # Convert .Matches to a PSCustomObject array
        $matchObjs = @()
        foreach ($filePath in $_.Matches.Keys) {
            $arr = '[ "' + ($_.Matches[$filePath] -join '", "') + '" ]'
            $matchObjs += [PSCustomObject]@{
                file    = $filePath
                strings = $arr
            }
        }

        # Return a PSCustomObject that includes everything we want
        [PSCustomObject]@{
            user         = $_.UserName
            browser      = $_.BrowserName
            profile      = $_.ProfileName
            extensionId  = $_.ExtensionId
            matches      = $matchObjs
        }
    }

try {
    $serialNumber = (Get-WmiObject -class win32_bios).SerialNumber # (wmic bios get serialnumber | Select-Object -Skip 1 | Select-Object -First 1).Trim()
} catch {
    $serialNumber = ""
}
$hostname = $env:COMPUTERNAME
$timestamp = (Get-Date).ToUniversalTime().ToString("o")

$finalObject = [PSCustomObject]@{
    timestamp     = $timestamp
    serial_number = $serialNumber
    hostname      = $hostname
    found         = $JsonArray
}

$jsonString = $finalObject | ConvertTo-Json -Depth 20
$jsonFile = Join-Path $CollectDir "scan_result.json"
Set-Content -Path $jsonFile -Value $jsonString -Encoding UTF8

Write-Host "Wrote JSON summary to: $jsonFile"

Write-Host "Creating zip at: $ZipOutputPath"
Push-Location $TempFolder
try {
    Compress-Archive -Path $TopDirName -DestinationPath $ZipOutputPath -Force
    Write-Host "Successfully created zip: $ZipOutputPath"
} catch {
    Write-Host "Error creating zip: $($_.Exception.Message)"
}
Pop-Location

Remove-Item $TempFolder -Recurse -Force
Write-Host "Removed temp directory: $TempFolder"
Write-Host "Done."