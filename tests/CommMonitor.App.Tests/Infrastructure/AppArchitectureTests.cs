using System.Diagnostics;
using System.Reflection;
using System.Reflection.PortableExecutable;
using CommMonitor.App.ViewModels;

namespace CommMonitor.App.Tests.Infrastructure;

public sealed class AppArchitectureTests
{
    [Fact]
    public void App_assembly_uses_the_Lemon_publish_identity_without_renaming_its_namespace()
    {
        Type appType = typeof(global::CommMonitor.App.App);
        Assembly assembly = appType.Assembly;

        Assert.Equal("Lemon.SerialMonitor", assembly.GetName().Name);
        Assert.Equal("CommMonitor.App", appType.Namespace);
        Assert.Equal(
            "Lemon\u4E32\u53E3\u76D1\u63A7",
            assembly.GetCustomAttribute<AssemblyProductAttribute>()?.Product);
        Assert.Equal(
            "Lemon\u4E32\u53E3\u76D1\u63A7",
            assembly.GetCustomAttribute<AssemblyTitleAttribute>()?.Title);
        Assert.Equal(
            "\u4E0D\u5360\u7528\u4E32\u53E3\u7684\u4E32\u53E3\u901A\u4FE1\u76D1\u63A7\u5DE5\u5177",
            assembly.GetCustomAttribute<AssemblyDescriptionAttribute>()?.Description);
        Assert.Equal(
            "0.1.0",
            assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
                .InformationalVersion);

        FileVersionInfo versionInfo = FileVersionInfo.GetVersionInfo(assembly.Location);
        Assert.Equal("Lemon\u4E32\u53E3\u76D1\u63A7", versionInfo.ProductName);
        Assert.Equal("Lemon\u4E32\u53E3\u76D1\u63A7", versionInfo.FileDescription);
        Assert.Equal("0.1.0.0", versionInfo.FileVersion);
        Assert.Equal("0.1.0", versionInfo.ProductVersion);
    }

    [Fact]
    public void App_assembly_targets_x64()
    {
        using FileStream stream = File.OpenRead(typeof(MainViewModel).Assembly.Location);
        using var reader = new PEReader(stream);

        Assert.Equal(Machine.Amd64, reader.PEHeaders.CoffHeader.Machine);
    }
}
