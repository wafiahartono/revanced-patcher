[CmdletBinding()]
Param(
    [Parameter(Mandatory)]
    [ArgumentCompleter(
        {
            Param($cmd, $param, $word, $ast, $fbParams)
            return Get-ChildItem $PSScriptRoot -Directory -Name -Filter "$word*" |
                Where-Object { $_ -match "\w+\.[\w\.]+" }
        }
    )]
    [string] $Package,
    [ArgumentCompleter(
        {
            Param($cmd, $param, $word, $ast, $fbParams)
            return Get-ChildItem "$PSScriptRoot\$($fbParams.Package)" -Filter "$word*.apk" |
                Select-Object -ExpandProperty BaseName
        }
    )]
    [string] $Version,
    [switch] $ForceUpdate,
    [switch] $ListPatches,
    [switch] $DryRun,
    [switch] $ForceBuild
)

function ConvertTo-HashTable($json) {
    $map = @{}
    foreach ($property in $json.PSObject.Properties) {
        $map[$property.Name] = $property.value
    }
    return $map
}

$lastLocation = Get-Location
Set-Location $PSScriptRoot

if ($Verbose) {
    $lastVerbosePref = $VerbosePreference
    $VerbosePreference = "Continue"
}

function Reset-Environment {
    Set-Location $lastLocation

    if ($Verbose) {
        $VerbosePreference = $lastVerbosePref
    }
}

$resourcePath = ".\resources"
$packagePath = ".\$Package"

$resourcePath, "$resourcePath\cache", $packagePath | ForEach-Object {
    if (!(Test-Path $_)) {
        New-Item -ItemType Directory $_ | Out-Null
    }
}

$assets = @{}

if ($options = Get-Content "$packagePath\build-options.json" -ErrorAction Ignore) {
    $options = ConvertTo-HashTable ($options | ConvertFrom-Json)
}
else {
    $options = @{}
}

function Get-GitHubAsset($name, $repo, $assetNamePattern) {
    Write-Verbose "Getting resource: $name"

    $cachedReleaseInfoPath = "$resourcePath\cache\$($repo -replace "/", ".").release.json"
    if (
        !($ForceUpdate) -and
        ($cache = Get-Item $cachedReleaseInfoPath -ErrorAction Ignore) -and
        (New-TimeSpan $cache.LastWriteTime).Days -lt 3
    ) {
        $releaseInfo = Get-Content $cachedReleaseInfoPath
    }
    else {
        $releaseInfo = Invoke-Expression "gh api repos/$repo/releases/latest"

        Set-Content $cachedReleaseInfoPath $releaseInfo
    }

    $releaseInfo = $releaseInfo | ConvertFrom-Json

    $asset = $releaseInfo.assets | Where-Object name -Match $assetNamePattern

    $assets.$name = @{
        path = "$resourcePath\$($asset.name)" -replace "(.+)\.(.+)", "`$1.$($releaseInfo.tag_name).`$2"
    }

    if ((Test-Path $assets.$name.path) -and !$ForceUpdate) {
        return
    }

    & curl.exe @($asset.browser_download_url, "--location" , "--output", $assets.$name.path, "--silent")
}

Get-GitHubAsset "cli" "revanced/revanced-cli" "revanced-cli-.+\.jar"
Get-GitHubAsset "patches" "revanced/revanced-patches" "revanced-patches-.+\.jar"
Get-GitHubAsset "patches-json" "revanced/revanced-patches" "patches\.json"
Get-GitHubAsset "integrations" "revanced/revanced-integrations" "revanced-integrations-.+\.apk"

$patches = (Get-Content $assets."patches-json".path | ConvertFrom-Json) | Where-Object {
    if ($_.compatiblePackages.Length -eq 0) { return $true }
    foreach ($compatiblePackage in $_.compatiblePackages) {
        if ($compatiblePackage.name -eq $Package) { return $true }
    }
}

if ($ListPatches) {
    $patches | ForEach-Object {
        Write-Host $_.name -ForegroundColor Blue

        if ($_.description) {
            Write-Host $_.description
        }

        if ($_.compatiblePackages.Length -eq 0) {
            Write-Host
            return
        }

        foreach ($compatiblePackage in $_.compatiblePackages) {
            Write-Host $compatiblePackage.name -ForegroundColor DarkGreen -NoNewline

            if ($compatiblePackage.versions.Length -eq 0) {
                Write-Host "`n"
                return
            }

            Write-Host ": $($compatiblePackage.versions -join ", ")`n" -ForegroundColor Gray
        }
    }
    Reset-Environment
    return $patches
}

if (!$Version) {
    $versions = $patches | Select-Object @{label = 'versions'; expression = { $_.compatiblePackages.versions } } |
        Select-Object -ExpandProperty versions -Unique

    if ($versions.Count -eq 0) {
        $Version = "app"
    }
    else {
        $Version = $versions[-1]
    }
}

$apkPath = "$packagePath\$Version.apk"
$outApkPath = "$packagePath\$Version-revanced.apk"

if (!$DryRun -and !(Test-Path $apkPath)) {
    Write-Error "The input file $apkPath doesn't exist."

    $url = (Get-Content "./download-urls.json" | ConvertFrom-Json).$Package -replace "\`$version", ($Version -replace "\.", "-")
    Write-Host "Try download the APK from $url"

    Reset-Environment
    return
}

if (!$DryRun -and !$ForceBuild -and (Test-Path $outApkPath)) {
    Write-Error "The output file $outApkPath exist."

    Reset-Environment
    return
}

$arguments = `
    "-jar", $assets.cli.path, `
    "patch", $apkPath , `
    "--out", $outApkPath, `
    "--patch-bundle", $assets.patches.path, `
    "--merge", $assets.integrations.path, `
    "--purge"

$keystorePath = "$packagePath\revanced.keystore"
if (Test-Path $keystorePath) {
    $arguments += "--keystore", $keystorePath
}

if ($options.patches) {
    $arguments += "--exclusive"
    foreach ($patch in $options.patches) {
        $arguments += "--include", "`"$patch`""
    }
}

$optionsPath = "$packagePath\revanced-options.json"
if (Test-Path $optionsPath) {
    $arguments += "--options", $optionsPath
}

$command = "java.exe $($arguments -join " ")"

if ($DryRun) {
    Write-Host $command
    Reset-Environment
    return
}

Write-Verbose $command
& java.exe $arguments

# $options | ConvertTo-Json | Out-File "$packagePath\build-options.json"

Reset-Environment
