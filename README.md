# Evo4Web Services Monitor

Script PowerShell schedulato che controlla lo stato dei servizi Windows
`Evo4Web - Engine*` e li riavvia automaticamente quando non sono in esecuzione.
Scrive log giornalieri con rotazione automatica.

---

## File inclusi

| File | Ruolo |
|------|-------|
| `Restart-Evo4WebServices.ps1` | Lo script vero e proprio. |
| `Restart-Evo4WebServices.config.json` | Configurazione (servizi, log path, retention). Deve risiedere nella stessa cartella dello script. |

> Niente altro è richiesto: la cartella dei log viene creata automaticamente
> al primo avvio.

---

## Installazione

1. Copia i due file in una cartella dedicata sulla macchina target, ad esempio:

   ```
   C:\Scripts\Evo4Web\
   ```

2. Verifica che l'utente che eseguirà il task abbia i diritti di:
   - Amministratore locale (per `#Requires -RunAsAdministrator`)
   - Avvio/arresto dei servizi `Evo4Web - Engine*`

3. Apri **Task Scheduler** (`taskschd.msc`).

---

## Configurazione

Modifica `Restart-Evo4WebServices.config.json` secondo le tue esigenze.

```json
{
  "logRoot": "%ProgramData%\\smeup\\evo4b2b\\services\\restart\\logs",
  "logPrefix": "Evo4WebServices",
  "maxLogAgeDays": 30,
  "serviceStartTimeoutSeconds": 30,
  "services": [
    "Evo4Web - EngineB2B",
    "Evo4Web - EnginePaNotifiche",
    "Evo4Web - EngineReceive"
  ]
}
```

| Campo | Descrizione |
|-------|-------------|
| `logRoot` | Cartella dei log. Supporta variabili d'ambiente (`%ProgramData%`, `%SystemDrive%`, …). |
| `logPrefix` | Prefisso dei file di log. Verranno creati file `Evo4WebServices-YYYYMMDD.log`. |
| `maxLogAgeDays` | Giorni di retention. I log più vecchi vengono eliminati a fine esecuzione. |
| `serviceStartTimeoutSeconds` | Attesa massima prima di dichiarare fallito l'avvio di un servizio. |
| `services` | Elenco dei nomi di servizio Windows da monitorare. Modificalo se sulla macchina sono presenti altri engine. |

> Tutti i campi tranne `logRoot` e `services` hanno un default sensato se omessi.

---

## Creazione del Task in Task Scheduler

### Opzione A — GUI

1. **Task Scheduler** → *Create Task…*

   **Tab General**
   - Name: `Evo4Web Services Monitor`
   - ☑ Run with highest privileges
   - ☑ Run whether user is logged on or not
   - Configure for: `Windows Server 2019` o la versione del tuo OS

2. **Tab Triggers** → *New…*
   - Es. *Daily*, repeat every **5 minutes** for a duration of **1 day**
   - Oppure un trigger orario secondo la tua cadenza

3. **Tab Actions** → *New…*
   - Program/script: `powershell.exe`
   - Add arguments:
     ```
     -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Evo4Web\Restart-Evo4WebServices.ps1"
     ```
   - Start in: `C:\Scripts\Evo4Web`

4. **Tab Settings**
   - ☑ Allow task to be run on demand
   - ☑ If the task fails, restart every **1 minute**, up to **3 times**
   - ☑ Stop the task if it runs longer than **5 minutes** (i servizi non dovrebbero metterci così tanto)

5. **Tab Conditions**
   - ☐ *Start the task only if the computer is on AC power* → disattiva se la macchina è un server sempre acceso

6. Click **OK** e inserisci la password dell'utente.

### Opzione B — PowerShell

```powershell
$action  = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Evo4Web\Restart-Evo4WebServices.ps1"' `
    -WorkingDirectory 'C:\Scripts\Evo4Web'

$trigger = New-ScheduledTaskTrigger `
    -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 365)

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask `
    -TaskName 'Evo4Web Services Monitor' `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Controlla e riavvia i servizi Evo4Web Engine*' `
    -Force
```

> Sostituisci `SYSTEM` con un utente admin reale se i servizi richiedono
> credenziali specifiche. Con `SYSTEM` i log di startup appariranno sotto
> `SYSTEM` in `Event Viewer`.

---

## Utilizzo manuale

Da una shell **PowerShell elevata** (Run as Administrator):

```powershell
cd C:\Scripts\Evo4Web
.\Restart-Evo4WebServices.ps1
```

### Parametri utili

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| `-ConfigPath <path>` | stessa cartella dello script | Percorso alternativo al JSON di configurazione. |
| `-ConsoleOutput Auto\|On\|Off` | `Auto` | `Auto` stampa su stdout solo se la sessione è interattiva. `Off` silenzia completamente la console (solo file di log). `On` forza la scrittura su stdout. |
| `-NoColor` | off | Disabilita i colori ANSI su stdout. |

Esempi:

```powershell
# Test rapido con output colorato
.\Restart-Evo4WebServices.ps1

# Da Task Scheduler: solo log su file
.\Restart-Evo4WebServices.ps1 -ConsoleOutput Off

# Configurazione alternativa
.\Restart-Evo4WebServices.ps1 -ConfigPath 'D:\Configs\evo4b2b.json'
```

---

## Log

### Dove

```
%ProgramData%\smeup\evo4b2b\services\restart\logs\
```

Un file al giorno:

```
Evo4WebServices-20260907.log
Evo4WebServices-20260908.log
...
```

### Formato

```
2026-09-07 14:32:00 [INFO]    ==== Avvio ciclo di monitoraggio servizi Evo4Web ====
2026-09-07 14:32:00 [INFO]    Servizi configurati: Evo4Web - EngineB2B, Evo4Web - EnginePaNotifiche, ...
2026-09-07 14:32:01 [WARN]    Servizio 'Evo4Web - EngineB2B' non in esecuzione (stato: Stopped). Tentativo di restart...
2026-09-07 14:32:04 [SUCCESS] Servizio 'Evo4Web - EngineB2B' avviato con successo. Stato finale: Running.
2026-09-07 14:32:05 [INFO]    ==== Ciclo terminato. Riavviati=1 Gia'Running=2 Falliti=0 ====
```

### Livelli

| Livello | Significato |
|---------|-------------|
| `INFO` | Evento normale. |
| `WARN` | Situazione anomala ma gestita (es. servizio trovato non running). |
| `ERROR` | Servizio non riavviato, non trovato o errore di I/O. |
| `SUCCESS` | Servizio riavviato/avviato correttamente. |

### Exit code

| Codice | Significato |
|--------|-------------|
| `0` | Tutti i servizi monitorati sono in `Running` oppure sono stati riavviati con successo. |
| `1` | Lo script non è stato eseguito come amministratore. |
| `2` | Almeno un servizio non è stato riavviato (o non esiste). Visibile come *Last Run Result* in Task Scheduler. |

### Retention

A fine esecuzione i file `.log` più vecchi di `maxLogAgeDays` vengono
eliminati automaticamente.

---

## Test

### Test funzionale

1. Apri `services.msc`.
2. Ferma manualmente uno dei servizi `Evo4Web - Engine*`.
3. Da Task Scheduler, click destro sul task → **Run**.
4. Verifica che:
   - Il servizio torni in `Running`.
   - Nel file di log del giorno corrente ci sia un blocco `WARN` → `SUCCESS`.

### Test da riga di comando

```powershell
# Esecuzione dry-like (verifica che config e log path siano raggiungibili)
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Evo4Web\Restart-Evo4WebServices.ps1" -ConsoleOutput Off
```

Il file di log creato sarà:

```
%ProgramData%\smeup\evo4b2b\services\restart\logs\Evo4WebServices-YYYYMMDD.log
```

---

## Troubleshooting

### Lo script termina subito con exit code 1

Causa: non eseguito come amministratore.

Soluzione: in Task Scheduler verifica che *Run with highest privileges* sia
abilitato. Da riga di comando apri PowerShell con *Run as Administrator*.

### `Servizio 'XYZ' non trovato su questa macchina`

Il nome del servizio nel JSON non corrisponde a quello registrato su
quella macchina. Apri `services.msc`, cerca il servizio e copia il
*Service name* esatto.

> ⚠ Il **Service name** è diverso dal *Display name*. Il JSON vuole il
> Service name. Esempio:
> - Display name: `Evo4Web - EngineB2B`
> - Service name: identico solo per coincidenza; in generale possono differire.

### I log non vengono scritti

- L'utente che esegue il task deve avere diritti di scrittura su
  `%ProgramData%\smeup\evo4b2b\services\restart\logs`.
- Verifica manualmente creando un file di prova in quella cartella.
- Se la cartella risiede su un percorso di rete, valuta di spostarla
  localmente.

### Lo script parte ma i servizi restano fermi

- Controlla la riga `[ERROR]` nel log del giorno.
- Verifica che l'account di esecuzione del task abbia i diritti sui servizi:
  `sc sdshow <ServiceName>` mostra i diritti correnti.

---

## Limitazioni note

- Lo script esegue un singolo controllo puntuale per esecuzione. Non è un
  watchdog continuo: più trigger frequenti = più controlli ravvicinati.
- Non distingue tra *crash* e *arresto intenzionale*: riavvia comunque.
  Se vuoi escludere alcuni servizi dal restart automatico, toglili dal
  JSON.
- Se tutti i servizi si spengono in contemporanea e dipendono l'uno
  dall'altro, l'avvio potrebbe richiedere più di un'esecuzione. In quel
  caso abbassa l'intervallo del trigger (es. 1-2 minuti).

---

## Autore

daniele.oppezzo_smeu — SmeUp
