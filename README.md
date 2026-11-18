# SINTHSBot — Windows HWID Backup & Restore

Sicheres Windows-PowerShell-CLI, um die **originale Hardware-Identität vor einem Spoof** zu sichern und danach wiederherzustellen.

Getestet gegen das Verhalten von **Nebel Spoofer** (AMIDEWIN SMBIOS, NetworkAddress-MAC, MACX EEPROM, NdisMacChanger) — ohne den Spoofer mitzuliefern und ohne Zufalls-Serials zu erzeugen.

## Wichtiger Ablauf

```text
1. VOR dem Spoof:   .\hwid.ps1 backup
2. Spoof passiert   (Nebel Permanent Spoof / Kernel MAC / …)
3. Danach:          .\hwid.ps1 verify <backup.json>
4. Safe restore:    .\hwid.ps1 restore <backup.json>
5. UEFI original:   .\hwid.ps1 generate-amide-restore <backup.json>
                    → Skript prüfen → AMIDEWINx64.EXE daneben → als Admin
6. Neu starten →    .\hwid.ps1 verify <backup.json>
```

## Voraussetzungen

- Windows 10/11, PowerShell 5.1+ oder 7+
- **Administrator** für `restore`
- Für UEFI-Zurückschreiben: eigenes `AMIDEWINx64.EXE` (+ Treiber) — wird **nicht** mitgeliefert

## Befehle

```powershell
.\hwid.ps1 backup
.\hwid.ps1 list
.\hwid.ps1 show [file]
.\hwid.ps1 verify <file>
.\hwid.ps1 restore <file>          # Diff + YES-Bestätigung + Pre-Snapshot
.\hwid.ps1 restore <file> -Force   # ohne Pause, Snapshot trotzdem
.\hwid.ps1 generate-amide-restore <file>
```

## Was `restore` (safe) zurückschreibt

| Ziel | Werte |
|------|--------|
| Registry | `MachineGuid`, `HwProfileGuid`, `SQMClient\MachineId`, `SusClientId`, `ComputerHardwareId` |
| Network | `NetworkAddress` unter Netz-Class `{4d36e972-…}` — auf Backup setzen oder entfernen (Hardware-MAC) |

Guards: Admin-Check, Schema/GUID-Validierung, Pre-Restore-Snapshot, Diff+YES, Rollback bei Fehler.

## Was `generate-amide-restore` macht

Erzeugt unter `backups\amide-restore\` ein `.bat` + `.txt` mit den **Original-Serials aus deinem Backup**:

```text
AMIDEWINx64.EXE /SU <original-uuid>    # nie "auto" (das wäre neuer UUID = Spoof)
AMIDEWINx64.EXE /BS <original-baseboard>
AMIDEWINx64.EXE /CS <original-chassis>
AMIDEWINx64.EXE /SS <original-system>
AMIDEWINx64.EXE /BT <original-tag>
```

Du musst `RESTORE-ORIGINAL` tippen. Falsche Werte können Firmware killen — Skript vorher lesen.

## Was bewusst nicht auto-gemacht wird

| Nebel-Aktion | Warum nicht auto |
|--------------|------------------|
| Permanent Spoof (AMIDEWIN UEFI) | Firmware-Schreiben → nur generiertes Original-Skript |
| MACX EEPROM/EFUSE MAC | NIC-Flash → manuell mit Original-MAC aus `infoOnly.macAddresses` |
| NdisMacChanger Kernel-MAC | Startup-Treiber → deinstallieren/Nebel-Revert; Registry-MAC clear macht safe restore |
| TPM via BIOS-Flash | BIOS-Version zurückflashen (nicht dieses Tool) |
| Zufällige neue Serials | Das wäre Spoofen — hier verboten |

## Backup-Inhalt (schema v2)

- `restorable.*` — Registry + NetworkAddress
- `smbios.*` — Original UUID / BaseBoard / Chassis / System (für AMIDEWIN-Restore)
- `infoOnly.*` — Disk-Serials, MAC-Fingerprints, Build (Verify)

## Dateien

| Datei | Rolle |
|-------|--------|
| `hwid.ps1` | CLI |
| `lib/Collect.ps1` | Einsammeln |
| `lib/Validate.ps1` | Schema/Diff/Verify |
| `lib/Restore.ps1` | Safe restore + AMIDE-Skript |
| `tests/Validate.Tests.ps1` | Fixture-Tests |

## Hinweis

Kein Anti-Cheat-Bypass und kein Spoofer. Ziel: **Original sichern und nach einem Spoof wiederherstellen**, ohne den PC mutwillig zu ruinieren.
