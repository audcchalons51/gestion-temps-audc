<#
.SYNOPSIS
    Synchronise les fichiers CSV de gestion du temps (dossier partagé du serveur) vers le dépôt Git, puis publie.

.DESCRIPTION
    Sens unique : serveur -> Git. Le dossier du serveur est la référence ; le dépôt n'en est qu'une copie
    pour l'affichage sur le site. Le script :
      1. met à jour la copie locale du dépôt (git pull) ;
      2. contrôle les CSV du serveur (non vides, avec une colonne DATES) ;
      3. les copie dans docs/temps/data et retire ceux qui ont disparu du serveur ;
      4. régénère docs/temps/data/index.json (la liste des onglets) ;
      5. crée un commit et le pousse sur GitHub, uniquement s'il y a un changement.
    Chaque exécution est notée dans un fichier journal.

.PARAMETER Source
    Dossier du serveur qui contient un CSV par personne (ex. Prenom_NOM.csv).
    Par défaut : Z:\public\gestion_temps_audc

.PARAMETER Repo
    Copie locale du dépôt Git (dossier qui contient .git).

.PARAMETER Branch
    Branche à publier (main par défaut).

.PARAMETER NoPush
    Crée le commit mais ne l'envoie pas (pour tester).

.PARAMETER LogFile
    Fichier journal. Par défaut : sync_temps.log, à côté du dépôt (hors du dépôt).

.EXAMPLE
    .\sync_temps.ps1

.EXAMPLE
    .\sync_temps.ps1 -Source '\\SERVEUR\public\gestion_temps_audc' -NoPush
#>
[CmdletBinding()]
param(
    [string]$Source = 'Z:\public\gestion_temps_audc',
    [string]$Repo = 'C:\git\methodes_travaux_audc51',
    [string]$Branch = 'main',
    [switch]$NoPush,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $LogFile) { $LogFile = Join-Path (Split-Path -Parent $Repo) 'sync_temps.log' }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Invoke-Git {
    param([string[]]$GitArgs)
    # Git écrit sa progression sur stderr : avec 'Stop', Windows PowerShell 5.1 y verrait une erreur.
    # On se fie donc uniquement au code de sortie.
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

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git n'est pas installé ou introuvable dans le PATH." }
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Dossier source introuvable : $Source (un lecteur mappé comme Z: n'existe pas en tâche planifiée : utiliser le chemin UNC \\SERVEUR\...)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { throw "Dépôt Git introuvable : $Repo" }

    $dataDir = Join-Path $Repo 'docs/temps/data'
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

    # 1. Dernière version du dépôt (évite les conflits au moment du push)
    Invoke-Git @('pull', '--rebase', '--autostash', 'origin', $Branch) | Out-Null

    # 2. CSV valides sur le serveur
    $valid = @()
    $candidates = @(Get-ChildItem -LiteralPath $Source -Filter '*.csv' -File |
        Where-Object { $_.Name -notlike '~*' -and $_.Name -notlike 'modele*' })
    foreach ($f in $candidates) {
        if ($f.Length -eq 0 -or $f.Length -gt 5MB) {
            Write-Log "Ignoré (vide ou trop volumineux) : $($f.Name)" 'WARN'
            continue
        }
        $first = Get-Content -LiteralPath $f.FullName -TotalCount 1 -Encoding UTF8
        if (-not $first -or $first -notmatch '(?i)date') {
            Write-Log "Ignoré (pas de colonne DATES dans l'en-tête) : $($f.Name)" 'WARN'
            continue
        }
        $valid += $f
    }

    # Garde-fou : un serveur indisponible ou un dossier vide ne doit jamais vider le site
    if ($valid.Count -eq 0) { throw "Aucun CSV valide dans $Source : synchronisation annulée, rien n'a été supprimé." }

    # 3. Copie, puis suppression de ce qui a disparu du serveur
    foreach ($f in $valid) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dataDir $f.Name) -Force
    }
    $names = @($valid | ForEach-Object { $_.Name })
    $obsolete = @(Get-ChildItem -LiteralPath $dataDir -Filter '*.csv' -File | Where-Object { $names -notcontains $_.Name })
    foreach ($o in $obsolete) {
        Remove-Item -LiteralPath $o.FullName -Force
        Write-Log "Retiré du dépôt (absent du serveur) : $($o.Name)"
    }

    # 4. Liste des onglets : nom affiché = nom du fichier, '_' remplacé par un espace
    $people = @($valid | Sort-Object Name | ForEach-Object {
        [ordered]@{
            nom     = ([IO.Path]::GetFileNameWithoutExtension($_.Name) -replace '_+', ' ').Trim()
            fichier = $_.Name
        }
    })
    $newList = @($people | ForEach-Object { '{0}|{1}' -f $_.nom, $_.fichier })

    $indexPath = Join-Path $dataDir 'index.json'
    $oldList = @()
    if (Test-Path -LiteralPath $indexPath) {
        try {
            $old = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($old.PSObject.Properties.Name -contains 'personnes') {
                $oldList = @($old.personnes | ForEach-Object { '{0}|{1}' -f $_.nom, $_.fichier })
            }
        }
        catch {
            Write-Log "index.json illisible, il sera régénéré : $($_.Exception.Message)" 'WARN'
        }
    }

    # Rien à publier ?
    $changedFiles = @(Invoke-Git @('status', '--porcelain', '--', 'docs/temps/data') | Where-Object { $_ })
    $sameList = (@(Compare-Object -ReferenceObject $oldList -DifferenceObject $newList).Count -eq 0)
    if ($changedFiles.Count -eq 0 -and $sameList) {
        Write-Log 'Aucun changement : rien à publier.'
        exit 0
    }

    $manifest = [ordered]@{
        maj       = (Get-Date -Format 'dd/MM/yyyy HH:mm')
        personnes = $people
    }
    $json = $manifest | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($indexPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    # 5. Commit et push
    Invoke-Git @('add', '--', 'docs/temps/data') | Out-Null
    $msg = 'Temps : mise a jour automatique du {0}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm')
    Invoke-Git @('commit', '-m', $msg) | Out-Null
    Write-Log ("Commit créé : {0} fichier(s) CSV, {1} personne(s)" -f $valid.Count, $people.Count)

    if ($NoPush) {
        Write-Log 'Push non demandé (-NoPush).'
        exit 0
    }
    Invoke-Git @('push', 'origin', $Branch) | Out-Null
    Write-Log 'Publié sur GitHub : le site sera mis à jour après le déploiement.'
    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
