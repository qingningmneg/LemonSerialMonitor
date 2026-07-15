using CommMonitor.Core.Ipc;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Driver;
using CommMonitor.Service.Hosting;
using CommMonitor.Service.Ipc;
using CommMonitor.Service.Ports;
using CommMonitor.Service.Security;
using CommMonitor.Service.Sessions;
using Microsoft.Extensions.Hosting.WindowsServices;
using System.Security.Principal;

if (!OperatingSystem.IsWindows())
{
    throw new PlatformNotSupportedException(
        "The Lemon serial monitoring service requires Windows.");
}

bool consoleRequested = args.Any(
    argument => string.Equals(argument, "--console", StringComparison.OrdinalIgnoreCase));
bool aiOnlyRequested = args.Any(
    argument => string.Equals(argument, "--ai-only", StringComparison.OrdinalIgnoreCase));
bool windowsServiceMode = WindowsServiceHelpers.IsWindowsService();
bool consoleMode = consoleRequested && !windowsServiceMode;
CaptureSourceMode captureSourceMode = CaptureSourceModeSelector.Determine(
    args,
    windowsServiceMode);
string[] hostArguments = args
    .Where(argument =>
        !string.Equals(argument, "--console", StringComparison.OrdinalIgnoreCase) &&
        !string.Equals(argument, "--fake-source", StringComparison.OrdinalIgnoreCase) &&
        !string.Equals(argument, "--ai-only", StringComparison.OrdinalIgnoreCase))
    .ToArray();

HostApplicationBuilder builder = Host.CreateApplicationBuilder(hostArguments);

if (consoleMode)
{
    builder.Logging.ClearProviders();
    builder.Logging.AddSimpleConsole(options =>
    {
        options.SingleLine = true;
        options.TimestampFormat = "yyyy-MM-dd HH:mm:ss ";
    });
}
else if (windowsServiceMode)
{
    builder.Services.AddWindowsService(options =>
    {
        options.ServiceName = "Lemon Serial Monitor Capture Service";
    });
}

builder.Services.AddSingleton<ISessionStoreFactory, SessionStoreFactory>();

builder.Services.AddSingleton<PortCatalogNormalizer>(
    _ => new PortCatalogNormalizer());
builder.Services.AddSingleton<ISetupApiCalls>(_ => new SetupApiCalls());
builder.Services.AddSingleton<ISetupApiRowSource>(services =>
    new SetupApiNative(services.GetRequiredService<ISetupApiCalls>()));
builder.Services.AddSingleton<SetupApiPortCatalog>(services =>
    new SetupApiPortCatalog(
        services.GetRequiredService<ISetupApiRowSource>(),
        services.GetRequiredService<PortCatalogNormalizer>()));
builder.Services.AddSingleton<WmiPortCatalog>();
builder.Services.AddSingleton<IPortCatalog>(services =>
    new ResilientPortCatalog(
        services.GetRequiredService<SetupApiPortCatalog>(),
        services.GetRequiredService<WmiPortCatalog>(),
        services.GetRequiredService<ILogger<ResilientPortCatalog>>()));

if (captureSourceMode == CaptureSourceMode.Fake)
{
    builder.Services.AddSingleton<FakeCaptureSource>(
        _ => new FakeCaptureSource(reportKnownStatistics: true));
    builder.Services.AddSingleton<ICaptureSource>(
        services => services.GetRequiredService<FakeCaptureSource>());
    builder.Services.AddSingleton<ICaptureSourceStatusProvider>(
        services => services.GetRequiredService<FakeCaptureSource>());
}
else
{
    builder.Services.AddSingleton<IDriverDeviceFactory, WindowsDriverDeviceFactory>();
    builder.Services.AddSingleton<IQpcClock, SystemQpcClock>();
    builder.Services.AddSingleton<ICaptureDelay, SystemCaptureDelay>();
    builder.Services.AddSingleton<DriverCaptureSource>();
    builder.Services.AddSingleton<ICaptureSource>(
        services => services.GetRequiredService<DriverCaptureSource>());
    builder.Services.AddSingleton<ICaptureSourceStatusProvider>(
        services => services.GetRequiredService<DriverCaptureSource>());
}

builder.Services.AddSingleton<CaptureCoordinator>();

string managedStorageRoot = builder.Configuration["Storage:ManagedRoot"] ??
    PipeServer.DefaultStorageDirectory;
string sessionStorageRoot = builder.Configuration["Storage:SessionRoot"] ??
    PipeServer.DefaultSessionDirectory;
string exportStorageRoot = builder.Configuration["Storage:ExportRoot"] ??
    PipeServer.DefaultExportDirectory;
string authorizedUserSid = builder.Configuration[
    $"{InstallSecurityOptions.SectionName}:AuthorizedUserSid"] ??
    (OperatingSystem.IsWindows()
        ? WindowsIdentity.GetCurrent().User?.Value
        : null) ??
    throw new InvalidOperationException("The authorized AI user SID is not configured.");
var installSecurityOptions = new InstallSecurityOptions
{
    CoreRootMetadataPath = builder.Configuration[
        $"{InstallSecurityOptions.SectionName}:CoreRootMetadataPath"] ??
        Path.Combine(managedStorageRoot, "Metadata"),
    AuthorizedUserSid = authorizedUserSid,
    AuthorizedClientImagePath = builder.Configuration[
        $"{InstallSecurityOptions.SectionName}:AuthorizedClientImagePath"],
    AuthorizedClientSha256 = builder.Configuration[
        $"{InstallSecurityOptions.SectionName}:AuthorizedClientSha256"],
};
installSecurityOptions.Validate();
builder.Services.AddSingleton(installSecurityOptions);
builder.Services.AddSingleton(_ => ServiceStorageBoundary.Open(
    managedStorageRoot,
    sessionStorageRoot,
    exportStorageRoot));
if (captureSourceMode == CaptureSourceMode.Fake)
{
    builder.Services.AddSingleton<IProtectedKeyRing, EphemeralProtectedKeyRing>();
}
else
{
    builder.Services.AddSingleton<IProtectedKeyRing, ProtectedKeyRing>();
}
builder.Services.AddSingleton<SessionCatalog>();
builder.Services.AddSingleton<CursorProtector>();
builder.Services.AddSingleton<CaptureLeaseManager>();
builder.Services.AddSingleton<CaptureCommitNotificationSource>();
builder.Services.AddSingleton<ICommitNotificationSource>(
    services => services.GetRequiredService<CaptureCommitNotificationSource>());
builder.Services.AddSingleton<CaptureAuthority>();
builder.Services.AddSingleton<AiSessionService>();
builder.Services.AddSingleton<IPipeClientIdentityProvider, WindowsPipeClientIdentityProvider>();
builder.Services.AddSingleton<AiCommandDispatcher>();
#pragma warning disable CA1416 // Process startup is guarded by OperatingSystem.IsWindows above.
builder.Services.AddSingleton<IAiCommandDispatcher>(
    services => services.GetRequiredService<AiCommandDispatcher>());
builder.Services.AddSingleton<AiPipeServer>();

if (!aiOnlyRequested)
{
    builder.Services.AddSingleton<PipeServer>(services => new PipeServer(
        services.GetRequiredService<CaptureCoordinator>(),
        services.GetRequiredService<IPortCatalog>(),
        services.GetRequiredService<ICaptureSourceStatusProvider>(),
        services.GetRequiredService<ILogger<PipeServer>>(),
        PipeProtocol.PipeName,
        sessionStorageRoot,
        exportStorageRoot));
    builder.Services.AddHostedService(services => services.GetRequiredService<PipeServer>());
}
builder.Services.AddHostedService(services => services.GetRequiredService<AiPipeServer>());
#pragma warning restore CA1416

IHost host = builder.Build();
ILogger logger = host.Services
    .GetRequiredService<ILoggerFactory>()
    .CreateLogger("Lemon.SerialMonitor.Service.Startup");
CaptureAuthority authority = host.Services.GetRequiredService<CaptureAuthority>();
await CaptureServiceStartup.InitializeAsync(
    authority.InitializeAsync,
    logger,
    CancellationToken.None);
CaptureSourceStatus sourceStatus = await host.Services
    .GetRequiredService<ICaptureSourceStatusProvider>()
    .GetStatusAsync(CancellationToken.None);
if (sourceStatus.Kind == CaptureSourceStatusKind.Ready)
{
    logger.LogInformation("{CaptureSourceStatus}", sourceStatus.Message);
}
else
{
    logger.LogWarning(
        "Capture source status {CaptureSourceStatusKind}: {CaptureSourceStatus}",
        sourceStatus.Kind,
        sourceStatus.Message);
}

await host.RunAsync();
