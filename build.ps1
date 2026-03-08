# Build script for sarien

$Action = $Args[0]
$RemainingArgs = $Args | Select-Object -Skip 1
$GlobalCache = "C:\Projects\Zig\ZigCache"

if ($null -eq $Action) {
    $Action = "build"
}

switch ($Action) {
    "build" {
        Write-Host "Building project (Cache: $GlobalCache)..." -ForegroundColor Cyan
        zig build --cache-dir $GlobalCache --global-cache-dir $GlobalCache $RemainingArgs
    }
    "run" {
        Write-Host "Running project (Cache: $GlobalCache)..." -ForegroundColor Cyan
        zig build --cache-dir $GlobalCache --global-cache-dir $GlobalCache run -- $RemainingArgs
    }
    "release" {
        Write-Host "Building release (Cache: $GlobalCache)..." -ForegroundColor Green
        zig build --cache-dir $GlobalCache --global-cache-dir $GlobalCache -Doptimize=ReleaseFast $RemainingArgs
        
        # Create release package
        $Version = "0.8.6"
        $ReleaseDir = "sarien-$Version-win64"
        $ZipFile = "$ReleaseDir.zip"
        
        Write-Host "Packaging release as $ZipFile..." -ForegroundColor Cyan
        
        # Create release directory
        if (Test-Path $ReleaseDir) {
            Remove-Item -Path $ReleaseDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $ReleaseDir | Out-Null
        
        # Copy executable
        Copy-Item -Path "zig-out\bin\sarien.exe" -Destination $ReleaseDir
        
        # Copy config file
        Copy-Item -Path "sarien.conf" -Destination $ReleaseDir
        
        # Copy README
        Copy-Item -Path "README.md" -Destination "$ReleaseDir\README.md"
        
        # Create zip
        if (Test-Path $ZipFile) {
            Remove-Item -Path $ZipFile -Force
        }
        Compress-Archive -Path $ReleaseDir -DestinationPath $ZipFile
        
        Write-Host "Release package created: $ZipFile" -ForegroundColor Green
        Write-Host "Upload this file to GitHub releases" -ForegroundColor Yellow
        
        # Cleanup temp directory
        Remove-Item -Path $ReleaseDir -Recurse -Force
    }
    "clean" {
        Write-Host "Cleaning build artifacts..." -ForegroundColor Yellow
        Remove-Item -Path "zig-out" -Recurse -Force -ErrorAction SilentlyContinue
    }
    default {
        Write-Host "Unknown action: $Action" -ForegroundColor Red
        Write-Host "Usage: ./build.ps1 [build|run|release|clean]"
    }
}
