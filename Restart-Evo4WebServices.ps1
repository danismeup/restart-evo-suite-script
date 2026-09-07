#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Restart automatico di servizi Evo4Web con logging strutturato.

.DESCRIPTION
    Controlla lo stato dei servizi Evo4Web specificati nel file di configurazione
    JSON e li riavvia se non sono in esecuzione. Scrive log giornalieri nella
    cartella configurata.

    Pensato per essere eseguito da Task Scheduler con privilegi elevati.

.PARAMETER ConfigPath
    Percorso al file JSON di configurazione. Default: stesso percorso dello
    script con estensione .config.json.

.EXAMPLE
    .\Restart-Evo4WebServices.ps1

.EXAMPLE
    .\Restart-Evo4WebServices.ps1 -ConfigPath 'D:\configs\evo4b2b.json'

.NOTES
    Autore  : Daniele Oppezzo
    Versione: 1.1
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,

    # Modalita' di output su console/stdout.
    #   Auto  : stampa su console solo se la sessione e' interattiva (TTY).
    #           Da Task Scheduler stdout viene catturato ma senza colori.
    #   On    : forza scrittura su stdout (utile se redirigi tu l'output).
    #   Off   : niente output su stdout, solo file di log.
    [ValidateSet('Auto','On','Off')]
    [string]$ConsoleOutput = 'Auto',

    # Disabilita i colori ANSI (utile in ambienti non-TTY / log strani).
    [switch]$NoColor
)

# --- Configurazione interna ------------------------------------------------
$ErrorActionPreference = 'Stop'
$script:LogFile = $null

# Determina se scrivere a stdout e se colorare
$script:StdoutEnabled = $true
$script:ColorEnabled = $false

switch ($ConsoleOutput) {
    'On'  { $script:StdoutEnabled = $true; $script:ColorEnabled = -not $NoColor }
    'Off' { $script:StdoutEnabled = $false }
    'Auto' {
        # Se c'e' una TTY interattiva collegata, coloriamo
        try {
            $isInteractive = [Environment]::UserInteractive -and [Console]::IsOutputRedirected -eq $false
        } catch {
            $isInteractive = [Environment]::UserInteractive
        }
        $script:StdoutEnabled = $true   # scriviamo comunque su stdout: Task Scheduler lo cattura
        $script:ColorEnabled  = $isInteractive -and (-not $NoColor)
    }
}

# --- Funzioni --------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line      = "{0} [{1}] {2}" -f $timestamp, $Level, $Message

    # 1) File di log SEMPRE
    if ($script:LogFile) {
        try {
            Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
        } catch {
            Write-Warning "Impossibile scrivere nel log '$($script:LogFile)': $($_.Exception.Message)"
        }
    }

    # 2) STDOUT condizionato (per Task Scheduler) con colori opzionali
    if (-not $script:StdoutEnabled) { return }

    if ($script:ColorEnabled) {
        switch ($Level) {
            'ERROR'   { Write-Host $line -ForegroundColor Red    ; return }
            'WARN'    { Write-Host $line -ForegroundColor Yellow ; return }
            'SUCCESS' { Write-Host $line -ForegroundColor Green  ; return }
        }
        Write-Host $line
    } else {
        # Write-Output va su STDOUT (catturato dal task scheduler), senza colori
        Write-Output $line
    }
}

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-LogRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # Espande variabili d'ambiente tipo %ProgramData%
    $resolved = [Environment]::ExpandEnvironmentVariables($Path)
    return $resolved
}

function Read-Config {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File di configurazione non trovato: $Path"
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    } catch {
        throw "Impossibile leggere il file di configurazione '$Path': $($_.Exception.Message)"
    }

    try {
        $cfg = $raw | ConvertFrom-Json
    } catch {
        throw "JSON di configurazione non valido in '$Path': $($_.Exception.Message)"
    }

    # Validazione minima
    if (-not $cfg.logRoot)           { throw "Configurazione non valida: campo 'logRoot' mancante." }
    if (-not $cfg.PSObject.Properties['services'] -or $cfg.services.Count -eq 0) {
        throw "Configurazione non valida: campo 'services' vuoto o mancante."
    }
    if (-not $cfg.PSObject.Properties['maxLogAgeDays'])   { $cfg | Add-Member -NotePropertyName maxLogAgeDays   -NotePropertyValue 30   }
    if (-not $cfg.PSObject.Properties['logPrefix'])       { $cfg | Add-Member -NotePropertyName logPrefix       -NotePropertyValue 'Evo4WebServices' }
    if (-not $cfg.PSObject.Properties['serviceStartTimeoutSeconds']) {
        $cfg | Add-Member -NotePropertyName serviceStartTimeoutSeconds -NotePropertyValue 30
    }

    return $cfg
}

# --- Pre-flight ------------------------------------------------------------
if (-not (Test-IsElevated)) {
    Write-Error "Lo script richiede privilegi di amministratore. Eseguire da Task Scheduler con 'Run with highest privileges' oppure da shell elevata."
    exit 1
}

if (-not $ConfigPath) {
    $scriptFull = $MyInvocation.MyCommand.Path
    $scriptDir  = if ($scriptFull) { Split-Path -Parent $scriptFull } else { (Get-Location).Path }
    $ConfigPath = Join-Path $scriptDir 'Restart-Evo4WebServices.config.json'
}

try {
    $config = Read-Config -Path $ConfigPath
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

$logRoot   = Resolve-LogRoot -Path $config.logRoot
$logPrefix = [string]$config.logPrefix
$maxDays   = [int]$config.maxLogAgeDays
$timeout   = [int]$config.serviceStartTimeoutSeconds
$services  = @($config.services)

# Prepara cartella log
try {
    if (-not (Test-Path -LiteralPath $logRoot)) {
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    }
} catch {
    Write-Error "Impossibile creare la cartella log '$logRoot': $($_.Exception.Message)"
    exit 1
}

$script:LogFile = Join-Path $logRoot ("{0}-{1}.log" -f $logPrefix, (Get-Date -Format 'yyyyMMdd'))

Write-Log -Level INFO    -Message "Modalita' output: ConsoleOutput=$ConsoleOutput ColorEnabled=$($script:ColorEnabled)"
Write-Log -Level INFO    -Message "==== Avvio ciclo di monitoraggio servizi Evo4Web ===="
Write-Log -Level INFO    -Message "Config letto da: $ConfigPath"
Write-Log -Level INFO    -Message "Log file: $script:LogFile"
Write-Log -Level INFO    -Message "Servizi configurati: $($services -join ', ')"

# --- Loop principale -------------------------------------------------------
$restarted = 0
$failed    = 0
$skipped   = 0

foreach ($svc in $services) {
    $service = Get-Service -Name $svc -ErrorAction SilentlyContinue

    if (-not $service) {
        Write-Log -Level ERROR -Message "Servizio '$svc' non trovato su questa macchina."
        $failed++
        continue
    }

    if ($service.Status -eq 'Running') {
        Write-Log -Level INFO -Message "Servizio '$svc' gia' in esecuzione (stato: $($service.Status)). Nessuna azione."
        $skipped++
        continue
    }

    Write-Log -Level WARN -Message "Servizio '$svc' non in esecuzione (stato attuale: $($service.Status)). Tentativo di restart..."

    try {
        if ($service.Status -eq 'Stopped') {
            Start-Service -Name $svc -ErrorAction Stop
            $action = 'avviato'
        } else {
            Restart-Service -Name $svc -Force -ErrorAction Stop
            $action = 'riavviato'
        }

        $wait = New-TimeSpan -Seconds $timeout
        $service.WaitForStatus('Running', $wait) | Out-Null
        $service.Refresh()

        if ($service.Status -eq 'Running') {
            Write-Log -Level SUCCESS -Message "Servizio '$svc' $action con successo. Stato finale: $($service.Status)."
            $restarted++
        } else {
            Write-Log -Level ERROR -Message "Servizio '$svc' $action ma lo stato finale non e' Running: $($service.Status)."
            $failed++
        }
    } catch {
        Write-Log -Level ERROR -Message "Errore durante il restart di '$svc': $($_.Exception.Message)"
        $failed++
    }
}

Write-Log -Level INFO -Message "==== Ciclo terminato. Riavviati=$restarted Gia'Running=$skipped Falliti=$failed ===="

# --- Retention log ---------------------------------------------------------
try {
    $cutoff = (Get-Date).AddDays(-1 * $maxDays)
    Get-ChildItem -LiteralPath $logRoot -Filter ($logPrefix + '-*.log') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force
            Write-Log -Level INFO -Message "Rimosso log vecchio: $($_.Name)"
        }
} catch {
    Write-Log -Level WARN -Message "Pulizia retention fallita: $($_.Exception.Message)"
}

if ($failed -gt 0) { exit 2 } else { exit 0 }
