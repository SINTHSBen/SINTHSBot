# Tutorial — SINTHSBot HWID Backup & Restore

Ziel: **Original-Hardware-ID sichern**, nach einem Spoof (z. B. Nebel) wieder zurück.

Wenn du unsicher bist: **nur Backup** nutzen. Restore und AMIDE erst, wenn du wirklich zurück willst.

---

## 1. Tool holen

**Empfohlen (ohne Extra-Installation):**  
https://gofile.io/d/4zW2FqjC → `SINTHSBot-HWID.exe` runterladen

**Oder klein aus dem Repo:** `dist\SINTHSBot-HWID.exe`  
(braucht [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0))

EXE starten. Fertig — kein Installer.

---

## 2. Der kurze Überblick

| Was du willst | Button / Befehl | Admin? |
|---------------|-----------------|--------|
| Nur sichern | **Backup** | Nein |
| Prüfen ob noch Original | **Verify** | Nein |
| Registry + MAC-Override zurück | **Safe Restore** | Ja (UAC) |
| UEFI-Serials zurück (Nebel Permanent Spoof) | **AMIDE-Skript** | Danach ja, manuell |

Backups landen hier:

`%LocalAppData%\SINTHSBot-HWID\backups\`

Über **Ordner** in der GUI öffnen.

---

## 3. Standard-Ablauf (wichtigste Reihenfolge)

### Schritt A — VOR dem Spoof (Pflicht)

1. EXE starten  
2. **Backup** klicken  
3. In der Liste erscheint eine Datei wie `hwid-2026-….json`  
4. Optional: Datei zusätzlich woanders kopieren (USB / Cloud)

Ohne dieses Backup gibt’s später **kein Original** zum Zurückspielen.

### Schritt B — Spoof machen

Jetzt erst Nebel / was auch immer. Tool zu.

### Schritt C — Nach dem Spoof: Stand checken

1. EXE wieder öffnen  
2. Dein Backup in der Liste markieren  
3. **Verify** klicken  

Ausgabe lesen:

- `OK` / Match → schon wieder Original (oder nie gespooft)  
- `MISMATCH` / Abweichungen → Spoof sitzt noch → weiter mit Restore

### Schritt D — Safe Restore (Registry + NetworkAddress)

1. Backup markieren  
2. **Safe Restore** → Ja bestätigen → UAC erlauben  
3. PC **neu starten** (empfohlen)  
4. Nochmal **Verify**

Das stellt u. a. wieder her:

- MachineGuid, HwProfileGuid, SQM/SusClient IDs  
- Registry-`NetworkAddress` (einfacher MAC-Spoof)

Das stellt **nicht** automatisch wieder her:

- UEFI/SMBIOS (Nebel „Permanent Spoof“)  
- EEPROM-MAC (MACX)  
- TPM über BIOS-Flash  

### Schritt E — UEFI Original (nur wenn Permanent Spoof war)

1. Backup markieren  
2. **AMIDE-Skript** klicken  
3. Im Backup-Ordner unter `amide-restore\` die `.bat` + `.txt` öffnen  
4. Werte in der `.txt` prüfen (das sind **deine** Original-Serials)  
5. `AMIDEWINx64.EXE` + Treiber (`.sys`) in **denselben Ordner** legen  
6. `.bat` **als Administrator** starten  
7. `RESTORE-ORIGINAL` tippen (nicht einfach Enter)  
8. PC neu starten  
9. **Verify**

Falsche Werte können die Firmware killen — Skript immer vorher lesen.  
`/SU auto` wird hier **nie** benutzt (das wäre ein neuer UUID = Spoof).

### Schritt F — EEPROM-MAC (nur wenn MACX genutzt wurde)

Safe Restore reicht dafür nicht. Original-MAC steht im Backup unter `infoOnly.macAddresses`.  
Die schreibst du mit dem NIC-Tool (z. B. MACX) **manuell** zurück, dann Cold Boot wie im Nebel-Guide.

---

## 4. Nur Backup — ohne Restore

Reicht völlig, wenn du erstmal nur absichern willst:

1. EXE → **Backup**  
2. Fertig  

Du kannst das jederzeit wiederholen (neue Timestamp-Datei). Alte Backups bleiben liegen.

---

## 5. CLI (optional, gleiche Logik)

PowerShell im Repo-Ordner:

```powershell
.\hwid.ps1 backup
.\hwid.ps1 list
.\hwid.ps1 verify .\backups\hwid-….json
.\hwid.ps1 restore .\backups\hwid-….json
.\hwid.ps1 generate-amide-restore .\backups\hwid-….json
```

`restore` ohne `-Force` fragt nach `YES`.

---

## 6. Typische Fehler

| Problem | Lösung |
|---------|--------|
| „Backup ungültig“ / Schema | Neues Backup mit aktueller EXE machen |
| Restore bricht ab / UAC weg | Nochmal, UAC mit Ja |
| Verify noch MISMATCH nach Safe Restore | Permanent Spoof / MACX → AMIDE-Skript bzw. EEPROM manuell |
| AMIDE-Skript findet EXE nicht | `AMIDEWINx64.EXE` in denselben Ordner wie die `.bat` |
| Backup-Liste leer | Falsche Windows-User-Session / Ordner-Button checken |

---

## 7. Merksatz

```text
Backup VORHER  →  Spoof  →  Verify  →  Safe Restore  →  (AMIDE nur bei UEFI)  →  Reboot  →  Verify
```

Nur Backup = safe.  
Safe Restore = Registry/Netz.  
AMIDE = Firmware, bewusst manuell und mit Bestätigung.
