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
        "lib/Restore.ps1",
        "lib/Logger.ps1"
    ];

    public static string AppDataRoot { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SINTHSBot-HWID");

    public static string ScriptsRoot => Path.Combine(AppDataRoot, "scripts");
    public static string BackupsRoot => Path.Combine(AppDataRoot, "backups");
    public static string LogsRoot => Path.Combine(AppDataRoot, "logs");

    public static void EnsureExtracted()
    {
        AppLog.Ensure();
        Directory.CreateDirectory(ScriptsRoot);
        Directory.CreateDirectory(Path.Combine(ScriptsRoot, "lib"));
        Directory.CreateDirectory(BackupsRoot);
        Directory.CreateDirectory(LogsRoot);

        var asm = Assembly.GetExecutingAssembly();
        foreach (var rel in ScriptFiles)
        {
            var resourceName = "HwidGui.scripts." + rel.Replace('/', '.').Replace('\\', '.');
            var target = Path.Combine(ScriptsRoot, rel.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);

            using var stream = asm.GetManifestResourceStream(resourceName);
            if (stream is null)
            {
                var fallback = FindFallbackScript(rel);
                if (fallback is null)
                {
                    var msg = $"Script resource missing: {resourceName}";
                    AppLog.Write("ERROR", msg);
                    throw new FileNotFoundException(msg);
                }
                WriteScriptUtf8Bom(File.ReadAllText(fallback, Encoding.UTF8), target);
                AppLog.Write("INFO", $"Script fallback copy: {rel} <- {fallback}");
                continue;
            }

            // Windows PowerShell 5.1 defaults to system ANSI without BOM;
            // UTF-8 em-dashes then break string literals. Always emit UTF-8 BOM.
            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            WriteScriptUtf8Bom(reader.ReadToEnd(), target);
        }

        File.WriteAllText(Path.Combine(ScriptsRoot, "backups.path"), BackupsRoot, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        AppLog.Write("DEBUG", $"Scripts extracted to {ScriptsRoot}");
    }

    private static void WriteScriptUtf8Bom(string content, string target)
    {
        File.WriteAllText(target, content, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
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

    private static string ResolvePowerShellPath()
    {
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var candidates = new[]
        {
            Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe"),
            "powershell.exe"
        };
        foreach (var c in candidates)
        {
            try
            {
                if (c == "powershell.exe") return c;
                if (File.Exists(c)) return c;
            }
            catch { }
        }
        return "powershell.exe";
    }

    public static async Task<(int ExitCode, string Output)> RunAsync(
        string command,
        string? path = null,
        bool force = false,
        bool elevate = false,
        CancellationToken ct = default)
    {
        EnsureExtracted();
        var psExe = ResolvePowerShellPath();
        var runLog = Path.Combine(LogsRoot, "last-run.log");
        AppLog.Write("INFO", $"Run start command={command} path={path ?? "-"} force={force} elevate={elevate} ps={psExe}");

        var ps1 = Path.Combine(ScriptsRoot, "hwid.ps1");
        if (!File.Exists(ps1))
        {
            var msg = $"hwid.ps1 fehlt nach Extract: {ps1}";
            AppLog.Write("ERROR", msg);
            return (1, msg);
        }

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
            var elevatedArgs =
                "-NoProfile -ExecutionPolicy Bypass -Command \"" +
                "& { " +
                "$env:SINTHSBOT_BACKUPS='" + BackupsRoot.Replace("'", "''") + "'; " +
                "$env:SINTHSBOT_LOGS='" + LogsRoot.Replace("'", "''") + "'; " +
                "& '" + ps1.Replace("'", "''") + "' " + command +
                (string.IsNullOrWhiteSpace(path) ? "" : " '" + path.Replace("'", "''") + "'") +
                (force ? " -Force" : "") +
                " *>&1 | Tee-Object -FilePath '" + runLog.Replace("'", "''") + "' }\"";

            var elevated = new ProcessStartInfo
            {
                FileName = psExe,
                Arguments = elevatedArgs,
                WorkingDirectory = ScriptsRoot,
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden
            };

            try
            {
                using var proc = Process.Start(elevated);
                if (proc is null)
                {
                    AppLog.Write("ERROR", "Process.Start returned null (elevate)");
                    return (1, "Konnte PowerShell nicht starten.");
                }
                await proc.WaitForExitAsync(ct);
                var output = File.Exists(runLog) ? await File.ReadAllTextAsync(runLog, ct) : "(keine Ausgabe)";
                AppLog.Write(proc.ExitCode == 0 ? "INFO" : "ERROR",
                    $"Run end elevate exit={proc.ExitCode} outLen={output.Length}");
                if (proc.ExitCode != 0)
                {
                    AppLog.Write("ERROR", "PowerShell elevate failed", null);
                    File.AppendAllText(AppLog.LatestLogPath, output + Environment.NewLine, Encoding.UTF8);
                }
                return (proc.ExitCode, output);
            }
            catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
            {
                AppLog.Write("WARN", "UAC cancelled", ex);
                return (1, "Elevation abgebrochen (UAC).");
            }
            catch (Exception ex)
            {
                AppLog.Write("ERROR", "Elevate run failed", ex);
                return (1, "Elevate-Fehler: " + ex.Message);
            }
        }

        var psi = new ProcessStartInfo
        {
            FileName = psExe,
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
        psi.Environment["SINTHSBOT_LOGS"] = LogsRoot;

        try
        {
            using var proc = new Process { StartInfo = psi };
            var sb = new StringBuilder();
            proc.OutputDataReceived += (_, e) => { if (e.Data != null) sb.AppendLine(e.Data); };
            proc.ErrorDataReceived += (_, e) => { if (e.Data != null) sb.AppendLine(e.Data); };
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            await proc.WaitForExitAsync(ct);
            var output = sb.ToString();
            try { File.WriteAllText(runLog, output, Encoding.UTF8); } catch { }

            AppLog.Write(proc.ExitCode == 0 ? "INFO" : "ERROR",
                $"Run end exit={proc.ExitCode} outLen={output.Length}");
            File.AppendAllText(AppLog.LatestLogPath,
                $"--- powershell output ({command}) ---{Environment.NewLine}{output}{Environment.NewLine}",
                Encoding.UTF8);

            if (proc.ExitCode != 0)
            {
                AppLog.Write("ERROR", $"Command '{command}' failed with exit {proc.ExitCode}. Output:\n{output}");
            }

            return (proc.ExitCode, output);
        }
        catch (Exception ex)
        {
            AppLog.Write("ERROR", $"Failed to start/run PowerShell for '{command}'", ex);
            return (1, "Start-Fehler: " + ex.Message + Environment.NewLine + "Details in: " + AppLog.LatestLogPath);
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
