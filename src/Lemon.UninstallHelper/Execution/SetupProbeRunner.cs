using System.Text.Json;
using Lemon.UninstallHelper.Security;

namespace Lemon.UninstallHelper.Execution;

public static class SetupProbeRunner
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = null,
        WriteIndented = false,
    };

    public static string CapturePathJson(string path) =>
        JsonSerializer.Serialize(OwnershipPathProbe.Capture(path), JsonOptions);
}
