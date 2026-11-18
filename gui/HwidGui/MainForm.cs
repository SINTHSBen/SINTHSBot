using System.Diagnostics;

namespace HwidGui;

public sealed class MainForm : Form
{
    private readonly ListBox _backupList = new();
    private readonly TextBox _log = new();
    private readonly Label _status = new();
    private readonly Button _btnBackup = new();
    private readonly Button _btnRefresh = new();
    private readonly Button _btnVerify = new();
    private readonly Button _btnRestore = new();
    private readonly Button _btnAmide = new();
    private readonly Button _btnOpenFolder = new();
    private readonly Button _btnShow = new();
    private bool _busy;

    public MainForm()
    {
        Text = "SINTHSBot HWID Backup";
        Width = 820;
        Height = 560;
        MinimumSize = new Size(720, 480);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9.75f);
        BackColor = Color.FromArgb(24, 26, 28);
        ForeColor = Color.FromArgb(230, 230, 230);

        var title = new Label
        {
            Text = "SINTHSBot  ·  Hardware-ID Backup & Restore",
            AutoSize = false,
            Dock = DockStyle.Top,
            Height = 44,
            TextAlign = ContentAlignment.MiddleLeft,
            Padding = new Padding(16, 0, 0, 0),
            Font = new Font("Segoe UI Semibold", 13f),
            ForeColor = Color.FromArgb(245, 245, 245),
            BackColor = Color.FromArgb(18, 19, 20)
        };

        var hint = new Label
        {
            Text = "Nur Backup geht ohne Admin. Restore braucht UAC. UEFI nur über generate-amide-restore (Original-Serials).",
            Dock = DockStyle.Top,
            Height = 28,
            TextAlign = ContentAlignment.MiddleLeft,
            Padding = new Padding(16, 0, 0, 0),
            ForeColor = Color.FromArgb(160, 160, 160),
            BackColor = Color.FromArgb(18, 19, 20)
        };

        var top = new Panel { Dock = DockStyle.Top, Height = 72, BackColor = Color.FromArgb(18, 19, 20) };
        top.Controls.Add(hint);
        top.Controls.Add(title);

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 52,
            Padding = new Padding(12, 10, 12, 8),
            BackColor = Color.FromArgb(24, 26, 28)
        };

        StyleButton(_btnBackup, "Backup", Color.FromArgb(46, 125, 90));
        StyleButton(_btnRefresh, "Aktualisieren", Color.FromArgb(55, 60, 66));
        StyleButton(_btnShow, "Anzeigen", Color.FromArgb(55, 60, 66));
        StyleButton(_btnVerify, "Verify", Color.FromArgb(55, 60, 66));
        StyleButton(_btnRestore, "Safe Restore", Color.FromArgb(140, 70, 50));
        StyleButton(_btnAmide, "AMIDE-Skript", Color.FromArgb(55, 60, 66));
        StyleButton(_btnOpenFolder, "Ordner", Color.FromArgb(55, 60, 66));

        buttons.Controls.AddRange([_btnBackup, _btnRefresh, _btnShow, _btnVerify, _btnRestore, _btnAmide, _btnOpenFolder]);

        _backupList.Dock = DockStyle.Left;
        _backupList.Width = 320;
        _backupList.BackColor = Color.FromArgb(32, 34, 36);
        _backupList.ForeColor = Color.FromArgb(230, 230, 230);
        _backupList.BorderStyle = BorderStyle.None;
        _backupList.IntegralHeight = false;

        _log.Multiline = true;
        _log.ReadOnly = true;
        _log.Dock = DockStyle.Fill;
        _log.BackColor = Color.FromArgb(16, 17, 18);
        _log.ForeColor = Color.FromArgb(210, 210, 210);
        _log.BorderStyle = BorderStyle.None;
        _log.ScrollBars = ScrollBars.Both;
        _log.Font = new Font("Consolas", 9.5f);
        _log.WordWrap = false;

        _status.Dock = DockStyle.Bottom;
        _status.Height = 28;
        _status.TextAlign = ContentAlignment.MiddleLeft;
        _status.Padding = new Padding(12, 0, 0, 0);
        _status.BackColor = Color.FromArgb(18, 19, 20);
        _status.ForeColor = Color.FromArgb(170, 170, 170);
        _status.Text = "Bereit";

        var split = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12, 0, 12, 8) };
        var leftWrap = new Panel { Dock = DockStyle.Left, Width = 328, Padding = new Padding(0, 0, 8, 0) };
        var listLabel = new Label
        {
            Text = "Backups",
            Dock = DockStyle.Top,
            Height = 24,
            ForeColor = Color.FromArgb(180, 180, 180)
        };
        leftWrap.Controls.Add(_backupList);
        leftWrap.Controls.Add(listLabel);
        _backupList.BringToFront();

        var rightWrap = new Panel { Dock = DockStyle.Fill };
        var logLabel = new Label
        {
            Text = "Ausgabe",
            Dock = DockStyle.Top,
            Height = 24,
            ForeColor = Color.FromArgb(180, 180, 180)
        };
        rightWrap.Controls.Add(_log);
        rightWrap.Controls.Add(logLabel);
        _log.BringToFront();

        split.Controls.Add(rightWrap);
        split.Controls.Add(leftWrap);

        Controls.Add(split);
        Controls.Add(buttons);
        Controls.Add(_status);
        Controls.Add(top);

        _btnBackup.Click += async (_, _) => await RunBackupAsync();
        _btnRefresh.Click += (_, _) => RefreshList();
        _btnShow.Click += async (_, _) => await RunSelectedAsync("show", elevate: false, force: false);
        _btnVerify.Click += async (_, _) => await RunSelectedAsync("verify", elevate: false, force: false);
        _btnRestore.Click += async (_, _) => await RunRestoreAsync();
        _btnAmide.Click += async (_, _) => await RunSelectedAsync("generate-amide-restore", elevate: false, force: false);
        _btnOpenFolder.Click += (_, _) =>
        {
            ScriptHost.EnsureExtracted();
            Process.Start(new ProcessStartInfo
            {
                FileName = ScriptHost.BackupsRoot,
                UseShellExecute = true
            });
        };

        Load += (_, _) =>
        {
            try
            {
                ScriptHost.EnsureExtracted();
                AppendLog($"Scripts: {ScriptHost.ScriptsRoot}");
                AppendLog($"Backups: {ScriptHost.BackupsRoot}");
                RefreshList();
            }
            catch (Exception ex)
            {
                AppendLog("Init-Fehler: " + ex.Message);
            }
        };
    }

    private static void StyleButton(Button btn, string text, Color bg)
    {
        btn.Text = text;
        btn.AutoSize = true;
        btn.Height = 32;
        btn.Padding = new Padding(10, 4, 10, 4);
        btn.FlatStyle = FlatStyle.Flat;
        btn.FlatAppearance.BorderSize = 0;
        btn.BackColor = bg;
        btn.ForeColor = Color.White;
        btn.Cursor = Cursors.Hand;
        btn.Margin = new Padding(0, 0, 8, 0);
    }

    private void RefreshList()
    {
        _backupList.Items.Clear();
        foreach (var f in ScriptHost.ListBackupFiles())
        {
            _backupList.Items.Add(Path.GetFileName(f));
        }
        _status.Text = $"{_backupList.Items.Count} Backup(s) · {ScriptHost.BackupsRoot}";
    }

    private string? SelectedBackupPath()
    {
        if (_backupList.SelectedItem is not string name) return null;
        return Path.Combine(ScriptHost.BackupsRoot, name);
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        foreach (Control c in new Control[] { _btnBackup, _btnRefresh, _btnShow, _btnVerify, _btnRestore, _btnAmide, _btnOpenFolder })
        {
            c.Enabled = !busy;
        }
        UseWaitCursor = busy;
        _status.Text = busy ? "Läuft…" : "Bereit";
    }

    private void AppendLog(string text)
    {
        if (InvokeRequired)
        {
            BeginInvoke(() => AppendLog(text));
            return;
        }
        _log.AppendText(text.TrimEnd() + Environment.NewLine);
    }

    private async Task RunBackupAsync()
    {
        if (_busy) return;
        SetBusy(true);
        try
        {
            AppendLog(">>> backup");
            var (code, output) = await ScriptHost.RunAsync("backup");
            AppendLog(output);
            AppendLog(code == 0 ? "OK" : $"Exit {code}");
            RefreshList();
        }
        catch (Exception ex)
        {
            AppendLog("Fehler: " + ex.Message);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task RunSelectedAsync(string command, bool elevate, bool force)
    {
        if (_busy) return;
        var path = SelectedBackupPath();
        if (path is null && command is not "backup" and not "list")
        {
            MessageBox.Show(this, "Bitte zuerst ein Backup in der Liste auswählen.", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        SetBusy(true);
        try
        {
            AppendLog($">>> {command} {(path is null ? "" : Path.GetFileName(path))}");
            var (code, output) = await ScriptHost.RunAsync(command, path, force, elevate);
            AppendLog(output);
            AppendLog(code == 0 ? "OK" : $"Exit {code}");
            if (command is "backup" or "restore" or "generate-amide-restore") RefreshList();
        }
        catch (Exception ex)
        {
            AppendLog("Fehler: " + ex.Message);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task RunRestoreAsync()
    {
        if (_busy) return;
        var path = SelectedBackupPath();
        if (path is null)
        {
            MessageBox.Show(this, "Bitte ein Backup auswählen.", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        var confirm = MessageBox.Show(
            this,
            "Safe Restore schreibt Registry-IDs und NetworkAddress zurück.\n" +
            "UEFI/SMBIOS und EEPROM-MAC werden NICHT geändert.\n\n" +
            "Pre-Restore-Snapshot wird automatisch angelegt.\n" +
            "Fortfahren? (UAC erscheint)",
            "Safe Restore bestätigen",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning);

        if (confirm != DialogResult.Yes) return;

        await RunSelectedAsync("restore", elevate: true, force: true);
    }
}
