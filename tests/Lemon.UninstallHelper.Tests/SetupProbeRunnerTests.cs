using System.Text.Json;
using Lemon.UninstallHelper.Execution;

namespace Lemon.UninstallHelper.Tests;

public sealed class SetupProbeRunnerTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "LemonSetupProbeRunnerTests",
        Guid.NewGuid().ToString("N"));

    public SetupProbeRunnerTests()
    {
        Directory.CreateDirectory(_root);
    }

    [Fact]
    public void Emits_one_strict_json_document_for_PowerShell()
    {
        string json = SetupProbeRunner.CapturePathJson(_root);

        using JsonDocument document = JsonDocument.Parse(json);
        JsonElement root = document.RootElement;
        Assert.Equal("FileSystem", root.GetProperty("Provider").GetString());
        Assert.Equal("Fixed", root.GetProperty("VolumeKind").GetString());
        Assert.True(root.GetProperty("Exists").GetBoolean());
        Assert.Equal(JsonValueKind.Array, root.GetProperty("Ancestors").ValueKind);
        Assert.Equal(JsonValueKind.Object, root.GetProperty("AclProfile").ValueKind);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }
}
