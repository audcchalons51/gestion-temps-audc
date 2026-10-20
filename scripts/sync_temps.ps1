param(
    [string]$Source = 'Z:\public\gestion_temps_audc',
    [string]$Repo = 'C:\Users\a.guene\Downloads\gestion-temps-audc',
    [string]$Branch = 'main',
    [switch]$NoPush,
    [string]$LogFile = ''
)
 
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $LogFile) {
    $LogFile = Join-Path (Split-Path -Parent $Repo) 'sync_temps.log'
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Invoke-Git {
    param([string[]]$GitArgs)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        $out = & git -C $Repo @GitArgs 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($code -ne 0) {
        throw ('git {0} a échoué : {1}' -f ($GitArgs -join ' '), ($out -join ' '))
    }

    return $out
}

try {

    Write-Log 'Début de la synchronisation'

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git n'est pas installé ou introuvable dans le PATH."
    }

    if (-not (Test-Path $Source)) {
        throw "Dossier source introuvable : $Source"
    }

    if (-not (Test-Path (Join-Path $Repo '.git'))) {
        throw "Dépôt Git introuvable : $Repo"
    }

    $dataDir = Join-Path $Repo 'data'

    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

    Invoke-Git @('pull','--rebase','origin',$Branch) | Out-Null

    $valid = @()

    $candidates = Get-ChildItem -LiteralPath $Source -Filter '*.csv' -File |
        Where-Object { $_.Name -notlike '~*' -and $_.Name -notlike 'modele*' }

    foreach ($f in $candidates) {

        if ($f.Length -eq 0) {
            continue
        }

        $valid += $f
    }

    if ($valid.Count -eq 0) {
        throw "Aucun CSV trouvé dans $Source"
    }

    foreach ($f in $valid) {

        Copy-Item `
            -LiteralPath $f.FullName `
            -Destination (Join-Path $dataDir $f.Name) `
            -Force

        Write-Log "Copié : $($f.Name)"
    }

    $names = $valid.Name

    Get-ChildItem $dataDir -Filter '*.csv' -File |
    Where-Object { $names -notcontains $_.Name } |
    ForEach-Object {

        Remove-Item $_.FullName -Force
        Write-Log "Supprimé : $($_.Name)"
    }

    $people = @()

    foreach ($f in ($valid | Sort-Object Name)) {

        $people += @{
            nom     = ([IO.Path]::GetFileNameWithoutExtension($f.Namee) -replace '_',' ')
            fichier = $f.Name
        }
    }

    $indexPath = Join-Path $dataDir 'index.json'

    @{
        maj       = Get-Date -Format 'dd/MM/yyyy HH:mm'
        personnes = $people
    } | ConvertTo-Json -Depth 5 |
    Set-Content $indexPath -Encoding UTF8

    Invoke-Git @('add','data') | Out-Null

    $status = Invoke-Git @('status','--porcelain')

    if ($status.Count -eq 0) {

        Write-Log 'Aucun changement détecté'
        exit 0
    }

    $message = 'Temps : mise a jour automatique du {0}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm')

    Invoke-Git @('commit','-m',$message) | Out-Null

    if (-not $NoPush) {
        Invoke-Git @('push','origin',$Branch) | Out-Null
    }

    Write-Log 'Synchronisation terminée'

}
catch {

    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
