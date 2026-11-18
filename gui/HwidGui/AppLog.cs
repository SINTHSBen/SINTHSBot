using System.Text;

namespace HwidGui;

internal static class AppLog
{
    public static string LogsRoot => Path.Combine(ScriptHost.AppDataRoot, "logs");
    public static string LatestLogPath => Path.Combine(LogsRoot, "latest.log");
    public static string LatestErrorPath => Path.Combine(LogsRoot, "latest-error.txt");

    public static void Ensure()
    {
        Directory.CreateDirectory(LogsRoot);
        if (!File.Exists(LatestLogPath))
        {
            File.WriteAllText(LatestLogPath, "", Encoding.UTF8);
        }
    }

    public static void Write(string level, string message, Exception? ex = null)
    {
        try
        {
            Ensure();
            var stamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff");
            var sb = new StringBuilder();
            sb.Append('[').Append(stamp).Append("] [").Append(level).Append("] ").Append(message);
            if (ex is not null)
            {
                sb.AppendLine();
                sb.Append("  Exception: ").Append(ex);
            }
            var line = sb.ToString();
            File.AppendAllText(LatestLogPath, line + Environment.NewLine, Encoding.UTF8);
            File.AppendAllText(
                Path.Combine(LogsRoot, $"session-{DateTime.Now:yyyyMMdd}.log"),
                line + Environment.NewLine,
                Encoding.UTF8);

            if (level is "ERROR" or "FATAL")
            {
                var body =
                    "SINTHSBot HWID — letzter Fehler" + Environment.NewLine +
                    "Zeit: " + stamp + Environment.NewLine +
                    "Message: " + message + Environment.NewLine +
                    Environment.NewLine +
                    line + Environment.NewLine +
                    Environment.NewLine +
                    "Log-Ordner: " + LogsRoot + Environment.NewLine +
                    "Schick latest.log oder latest-error.txt, dann kann ich's direkt lesen." + Environment.NewLine;
                File.WriteAllText(LatestErrorPath, body, Encoding.UTF8);
            }
        }
        catch
        {
            // never throw from logger
        }
    }

    public static string ReadLatest(int maxChars = 200_000)
    {
        Ensure();
        if (!File.Exists(LatestLogPath)) return "(noch kein Log)";
        var text = File.ReadAllText(LatestLogPath, Encoding.UTF8);
        if (text.Length <= maxChars) return text;
        return text[^maxChars..];
    }

    public static string ReadLatestError()
    {
        Ensure();
        if (File.Exists(LatestErrorPath))
        {
            return File.ReadAllText(LatestErrorPath, Encoding.UTF8);
        }
        return ReadLatest(20_000);
    }
}
