using System.Diagnostics;
using System.Reflection;
using System.Text;

namespace HwidGui;

internal static class ScriptHost
{
    private static readonly string[] ScriptFiles =
    [
        "hwid.ps1",
        "lib/Collect.ps1",
        "lib/Validate.ps1",
        "lib/Restore.ps1"
    ];

    public static string AppDataRoot { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SINTHSBot-HWID");

    public static string ScriptsRoot => Path.Combine(AppDataRoot, "scripts");
    public static string BackupsRoot => Path.Combine(AppDataRoot, "backups");

    public static void EnsureExtracted()
    {
        Directory.CreateDirectory(ScriptsRoot);
        Directory.CreateDirectory(Path.Combine(ScriptsRoot, "lib"));
        Directory.CreateDirectory(BackupsRoot);

        var asm = Assembly.GetExecutingAssembly();
        foreach (var rel in ScriptFiles)
        {
            var resourceName = "HwidGui.scripts." + rel.Replace('/', '.').Replace('\\', '.');
            var target = Path.Combine(ScriptsRoot, rel.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);

            using var stream = asm.GetManifestResourceStream(resourceName);
            if (stream is null)
            {
                // Fallback: copy from repo-relative path when running from source/publish folder
                var fallback = FindFallbackScript(rel);
                if (fallback is null)
                {
                    throw new FileNotFoundException($"Script resource missing: {resourceName}");
                }
                File.Copy(fallback, target, overwrite: true);
                continue;
            }

            using var fs = File.Create(target);
            stream.CopyTo(fs);
        }

        // Point backups at AppData by patching a tiny sidecar env file the GUI passes
        File.WriteAllText(Path.Combine(ScriptsRoot, "backups.path"), BackupsRoot, Encoding.UTF8);
    }

    private static string? FindFallbackScript(string rel)
    {
        var baseDir = AppContext.BaseDirectory;
        var candidates = new[]
        {
            Path.Combine(baseDir, rel),
            Path.Combine(baseDir, "scripts", rel),
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "..", rel)),
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "..", "..", rel)),
        };
        return candidates.FirstOrDefault(File.Exists);
    }

    public static async Task<(int ExitCode, string Output)> RunAsync(
        string command,
        string? path = null,
        bool force = false,
        bool elevate = false,
        CancellationToken ct = default)
    {
        EnsureExtracted();

        var ps1 = Path.Combine(ScriptsRoot, "hwid.ps1");
        var args = new StringBuilder();
        args.Append("-NoProfile -ExecutionPolicy Bypass -File ");
        args.Append('"').Append(ps1).Append('"');
        args.Append(' ').Append(command);
        if (!string.IsNullOrWhiteSpace(path))
        {
            args.Append(' ').Append('"').Append(path).Append('"');
        }
        if (force)
        {
            args.Append(" -Force");
        }

        if (elevate)
        {
            var log = Path.Combine(BackupsRoot, "last-gui-run.log");
            var elevatedArgs =
                "-NoProfile -ExecutionPolicy Bypass -Command \"" +
                "& { $env:SINTHSBOT_BACKUPS='" + BackupsRoot.Replace("'", "''") + "'; " +
                "& '" + ps1.Replace("'", "''") + "' " + command +
                (string.IsNullOrWhiteSpace(path) ? "" : " '" + path.Replace("'", "''") + "'") +
                (force ? " -Force" : "") +
                " *>&1 | Tee-Object -FilePath '" + log.Replace("'", "''") + "' }\"";

            var elevated = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = elevatedArgs,
                WorkingDirectory = ScriptsRoot,
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden
            };

            try
            {
                using var proc = Process.Start(elevated);
                if (proc is null) return (1, "Konnte PowerShell nicht starten.");
                await proc.WaitForExitAsync(ct);
                var output = File.Exists(log) ? await File.ReadAllTextAsync(log, ct) : "(keine Ausgabe)";
                return (proc.ExitCode, output);
            }
            catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
            {
                return (1, "Elevation abgebrochen (UAC).");
            }
        }

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = args.ToString(),
            WorkingDirectory = ScriptsRoot,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        psi.Environment["SINTHSBOT_BACKUPS"] = BackupsRoot;

        using (var proc = new Process { StartInfo = psi })
        {
            var sb = new StringBuilder();
            proc.OutputDataReceived += (_, e) => { if (e.Data != null) sb.AppendLine(e.Data); };
            proc.ErrorDataReceived += (_, e) => { if (e.Data != null) sb.AppendLine(e.Data); };
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            await proc.WaitForExitAsync(ct);
            return (proc.ExitCode, sb.ToString());
        }
    }

    public static string[] ListBackupFiles()
    {
        EnsureExtracted();
        if (!Directory.Exists(BackupsRoot)) return [];
        return Directory.GetFiles(BackupsRoot, "*.json")
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .ToArray();
    }
}
