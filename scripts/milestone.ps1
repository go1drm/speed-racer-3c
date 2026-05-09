# ============================================================
#  Milestone tagging script - lock an important version with one command
# ============================================================
#  Usage:
#    .\scripts\milestone.ps1 -Version "0.1" -Name "Playable Version"
#    .\scripts\milestone.ps1 -Version "0.2" -Name "Drift Added" -Push
# ============================================================
param(
    [Parameter(Mandatory=$true)]
    [string]$Version,

    [Parameter(Mandatory=$true)]
    [string]$Name,

    [switch]$Push  # Add -Push to also push the tag to the remote
)

$ErrorActionPreference = 'Stop'
$repoRoot = git rev-parse --show-toplevel
Set-Location $repoRoot

# Ensure working tree is clean
$status = git status --porcelain
if ($status) {
    Write-Host "[ERROR] Working tree has uncommitted changes. Commit them first." -ForegroundColor Red
    git status --short
    exit 1
}

$tagName = "v$Version"
$branch = git rev-parse --abbrev-ref HEAD

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Creating milestone tag" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Tag    : $tagName" -ForegroundColor White
Write-Host "  Name   : $Name" -ForegroundColor White
Write-Host "  Branch : $branch" -ForegroundColor White
Write-Host "  Commit : $(git rev-parse --short HEAD)" -ForegroundColor White
Write-Host "========================================================" -ForegroundColor Cyan

git tag -a $tagName -m "Milestone: $Name"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to create tag (maybe $tagName already exists)" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Tag $tagName created -> $Name" -ForegroundColor Green

if ($Push) {
    git push origin $tagName
    Write-Host "[OK] Tag pushed to remote" -ForegroundColor Green
}

Write-Host ""
Write-Host "All milestones:" -ForegroundColor Yellow
git tag -l -n1
Write-Host ""
