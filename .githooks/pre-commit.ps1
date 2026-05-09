# Protect main / baseline branches from direct commits.
# All changes must go through feature/* or fix/* branches.
$branch = git rev-parse --abbrev-ref HEAD 2>$null
if ($branch -in @('main', 'baseline')) {
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Red
    Write-Host "  [BLOCKED] Direct commit to '$branch' is not allowed!" -ForegroundColor Red
    Write-Host "========================================================" -ForegroundColor Red
    Write-Host "  Rule: main / baseline only accept merges, not commits." -ForegroundColor Yellow
    Write-Host "  How to fix:" -ForegroundColor Yellow
    Write-Host "    git checkout -b feature/<your-feature>" -ForegroundColor Cyan
    Write-Host "    # commit on the new branch, merge back after verification" -ForegroundColor Gray
    Write-Host "========================================================" -ForegroundColor Red
    Write-Host ""
    exit 1
}
exit 0
