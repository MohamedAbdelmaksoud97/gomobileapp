param(
    [ValidateSet("debug", "release")]
    [string]$Mode = "debug"
)

$ErrorActionPreference = "Stop"

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$workspaceRoot = Split-Path $projectRoot -Parent
$pubspecPath = Join-Path $projectRoot "pubspec.yaml"
$archiveRoot = Join-Path $workspaceRoot "mobile-releases\android"
$flutterCommand = "F:\flutter\flutter\bin\flutter.bat"

if (-not (Test-Path -LiteralPath $flutterCommand)) {
    throw "Flutter was not found at $flutterCommand"
}

$versionMatch = Select-String -LiteralPath $pubspecPath -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$'
if (-not $versionMatch) {
    throw "pubspec.yaml must contain a version such as: version: 1.0.1+2"
}

$buildName = $versionMatch.Matches[0].Groups[1].Value
$buildNumber = $versionMatch.Matches[0].Groups[2].Value
$versionId = "v$buildName+$buildNumber"
$versionDirectory = Join-Path $archiveRoot $versionId
$stagingDirectory = Join-Path $archiveRoot ".$versionId-staging"

if (Test-Path -LiteralPath $versionDirectory) {
    throw "Version $versionId is already archived. Increment version in pubspec.yaml; old versions are never overwritten."
}
if (Test-Path -LiteralPath $stagingDirectory) {
    throw "An unfinished staging directory exists: $stagingDirectory"
}

New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
New-Item -ItemType Directory -Path $stagingDirectory | Out-Null

$taskTemp = Join-Path $workspaceRoot ".codex-temp\android-versioned-build"
$gradleHome = Join-Path $workspaceRoot ".codex-temp\gradle"
New-Item -ItemType Directory -Force -Path $taskTemp, $gradleHome | Out-Null
$env:TEMP = $taskTemp
$env:TMP = $taskTemp
$env:GRADLE_USER_HOME = $gradleHome

Push-Location $projectRoot
try {
    & $flutterCommand build apk "--$Mode"
    if ($LASTEXITCODE -ne 0) { throw "Universal APK build failed." }

    $universalSource = Join-Path $projectRoot "build\app\outputs\flutter-apk\app-$Mode.apk"
    if (-not (Test-Path -LiteralPath $universalSource)) {
        throw "Universal APK was not produced at $universalSource"
    }
    $universalName = "go-fitness-$versionId-universal-$Mode.apk"
    Copy-Item -LiteralPath $universalSource -Destination (Join-Path $stagingDirectory $universalName)

    & $flutterCommand build apk "--$Mode" --split-per-abi
    if ($LASTEXITCODE -ne 0) { throw "Split APK build failed." }

    $outputDirectory = Join-Path $projectRoot "build\app\outputs\flutter-apk"
    $architectures = @("arm64-v8a", "armeabi-v7a", "x86_64")
    foreach ($architecture in $architectures) {
        $source = Join-Path $outputDirectory "app-$architecture-$Mode.apk"
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Expected split APK was not produced at $source"
        }
        $targetName = "go-fitness-$versionId-$architecture-$Mode.apk"
        Copy-Item -LiteralPath $source -Destination (Join-Path $stagingDirectory $targetName)
    }

    $commit = (git rev-parse HEAD).Trim()
    $dirty = -not [string]::IsNullOrWhiteSpace((git status --porcelain))
    $createdAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
    $recommended = "go-fitness-$versionId-arm64-v8a-$Mode.apk"
    $info = @(
        "GO Fitness Android build archive"
        "Version: $buildName"
        "Build number: $buildNumber"
        "Mode: $Mode"
        "Package: com.gofitness.app"
        "Created at: $createdAt"
        "Git commit: $commit"
        "Git worktree dirty during build: $dirty"
        "Recommended for most modern Android phones: $recommended"
        "Universal APK: $universalName"
    )
    Set-Content -LiteralPath (Join-Path $stagingDirectory "release-info.txt") -Value $info -Encoding utf8

    $checksums = Get-ChildItem -LiteralPath $stagingDirectory -Filter "*.apk" |
        Sort-Object Name |
        ForEach-Object {
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$hash  $($_.Name)"
        }
    Set-Content -LiteralPath (Join-Path $stagingDirectory "SHA256SUMS.txt") -Value $checksums -Encoding ascii

    Rename-Item -LiteralPath $stagingDirectory -NewName $versionId
    Write-Output "Archived Android $versionId at $versionDirectory"
}
finally {
    Pop-Location
}
