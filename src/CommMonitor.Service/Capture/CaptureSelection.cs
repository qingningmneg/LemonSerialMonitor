namespace CommMonitor.Service.Capture;

public sealed record CaptureSelection(
    IReadOnlySet<ulong> DeviceIds,
    string SessionPath,
    string? RunId = null,
    string? SessionId = null,
    string OwnerType = "WPF",
    string OwnerSid = "LOCAL");
