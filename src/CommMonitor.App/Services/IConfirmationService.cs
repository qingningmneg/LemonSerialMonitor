namespace CommMonitor.App.Services;

public interface IConfirmationService
{
    bool ConfirmClearSession();
}

internal sealed class AlwaysConfirmService : IConfirmationService
{
    public static AlwaysConfirmService Instance { get; } = new();

    public bool ConfirmClearSession() => true;
}
