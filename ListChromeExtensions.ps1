param (
    [string]$userProfileArg # Specify a single user profile to scan, if empty the script will try to list all user profiles
)

function ListExtensionsInProfile {
    param ([string]$profil)

    ListExtensionsInFile -profilPath "$profil" -file "Preferences"
    # ListExtensionsInFile -profilPath "$profil" -file "Secure Preferences" # Uncomment to scan "Secure Preferences" file too, if necessary
}

function ListExtensionsInFile {
    param ([string]$profilPath, [string]$file)

    $path = "$profilPath\" + "$file"
    echo "Checking profile $path"

    if (![System.IO.File]::Exists($path)) {
        return
    }

    $jsonPrefs = Get-Content $path | ConvertFrom-Json
    foreach ($ext in $jsonPrefs.extensions.settings.PSObject.Properties) {
        $id = $ext.Name
        $name = $ext.value.manifest.name
        $version = $ext.value.manifest.version
        $enabled = "False"
        if ($ext.value.state -ne 0) {
            $enabled = "True"
        }

        $extPath = $ext.value.path
        # If path is not rooted, assume it's under Extensions
        if (![System.IO.Path]::IsPathRooted($extPath)) {
            $extPath = "$profilPath\Extensions\$extPath"
        }

        if (![System.IO.Directory]::Exists($extPath)) {
            continue
        }

        echo " *** $id - $name - $version - Enabled? $enabled - Full path: $extPath"
    }
}

function ListExtensionsInUserProfile {
    param ([string]$userProfile)

    $chromeDirectory = "$userProfile\AppData\Local\Google\Chrome\User Data"
    if (![System.IO.Directory]::Exists($chromeDirectory)) {
        return
    }

    echo "Checking chrome directory $chromeDirectory"

    # List default profile
    $defaultProfile = "$chromeDirectory\Default"
    ListExtensionsInProfile -profil "$defaultProfile"

    # List guest profile
    $guestProfile = "$chromeDirectory\Guest Profile"
    ListExtensionsInProfile -profil "$guestProfile"

    # List all other profiles
    Get-ChildItem "$chromeDirectory" -Filter "Profile *" -Directory | % { ListExtensionsInProfile -profil $_.FullName }
}

if ($userProfileArg -ne "") {
    ListExtensionsInUserProfile -userProfile $userProfileArg
} else {
    foreach ($profil in Get-childItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' | % {Get-ItemProperty $_.pspath } | Select ProfileImagePath, FullProfile) {
        if ($profil.FullProfile -eq 1) {
            ListExtensionsInUserProfile -userProfile $profil.profileImagePath
        }
    }
}
