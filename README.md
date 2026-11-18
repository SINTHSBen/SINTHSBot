# SINTHSBot — Windows HWID Backup & Restore

Sicheres Windows-PowerShell-CLI zum Backup und kontrollierten Restore von Hardware-IDs.
**Safe-by-default:** Restore schreibt nur bekannte Registry-Werte aus einem eigenen Backup — keine Firmware-, Disk- oder Treiber-Hacks.

## Voraussetzungen

- Windows 10/11
- PowerShell 5.1+ (mitgeliefert) oder PowerShell 7+
- **Administrator-Rechte** für Restore (und empfohlen für vollständige Backups)

## Schnellstart

In einem **als Administrator** geöffneten PowerShell-Fenster im Repo-Ordner:

```powershell
# Aktuellen Stand sichern
.\hwid.ps1 backup

# Vorhandene Backups anzeigen
.\hwid.ps1 list

# Backup oder aktuellen Stand anzeigen
.\hwid.ps1 show
.\hwid.ps1 show .\backups\hwid-2026-11-18T210000Z.json

# Restore mit Diff + Bestätigung (legt vorher automatisch einen Snapshot an)
.\hwid.ps1 restore .\backups\hwid-2026-11-18T210000Z.json

# Restore ohne interaktive Pause (Snapshot trotzdem immer)
.\hwid.ps1 restore .\backups\hwid-2026-11-18T210000Z.json -Force
```

Empfohlener Ablauf: **Backup → später Restore (Diff lesen) → bestätigen → Neustart**.

## Was wird restored?

Nur diese Registry-Werte (wenn sie im Backup vorhanden sind):

| Key | Wert |
|-----|------|
| `HKLM\SOFTWARE\Microsoft\Cryptography` | `MachineGuid` |
| `HKLM\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001` | `HwProfileGuid` |
| `HKLM\SOFTWARE\Microsoft\SQMClient` | `MachineId` (falls vorhanden) |

## Was wird nur dokumentiert (kein Restore)?

Im Backup unter `infoOnly` (nur lesen):

- ComputerName / Hostname
- BIOS UUID, BaseBoard-Serial
- Disk-Serials
- MAC-Adressen
- Windows-Build

## Was wird bewusst nie angefasst?

- SMBIOS/BIOS UUID schreiben
- Festplatten-/NVMe-Firmware-Serials
- MAC-Adressen über Treiber-Hacks
- Unsigned Kernel-Driver / Bootloader-Patches
- Volume-Serials (Formatieren wäre destruktiv)
- HWID-Spoofing auf neue Zufallswerte
- Erzwungener Reboot

## Sicherheits-Guards beim Restore

1. Admin-Check — ohne Elevation Abbruch
2. Schema- und GUID-Validierung der Backup-JSON
3. Automatischer Pre-Restore-Snapshot unter `backups\pre-restore-*.json` (auch mit `-Force`)
4. Diff der restorable Werte + Bestätigung (außer `-Force`)
5. Bei Schreibfehler: sofortiger Rollback aus dem Snapshot
6. Fehlende Keys im Backup → Skip + Warnung, kein Raten
7. Nach Erfolg: Neustart-Hinweis (kein Auto-Reboot)

## Backup-Format

```json
{
  "schemaVersion": 1,
  "createdAt": "2026-11-18T21:00:00+01:00",
  "hostname": "PC-NAME",
  "restorable": {
    "machineGuid": "...",
    "hwProfileGuid": "{...}",
    "sqmMachineId": "..."
  },
  "infoOnly": {
    "biosUuid": "...",
    "baseBoardSerial": "...",
    "diskSerials": [],
    "macAddresses": []
  }
}
```

Backups liegen in `backups\` und sind per `.gitignore` vom Commit ausgeschlossen.

## Dateien

| Datei | Rolle |
|-------|--------|
| `hwid.ps1` | CLI-Einstieg |
| `lib/Collect.ps1` | HWID einsammeln |
| `lib/Validate.ps1` | Schema/GUID/Diff |
| `lib/Restore.ps1` | Sicheres Schreiben + Rollback |
| `tests/Validate.Tests.ps1` | Fixture-Tests (ohne Windows-Registry) |

## Hinweis

Dieses Tool ändert nur die oben genannten Registry-Werte. Es ist kein Anti-Cheat-Bypass und kein generischer HWID-Spoofer. Bei Unsicherheit: nur `backup` nutzen und Restore weglassen.
