using CommMonitor.Core.Sessions;

namespace CommMonitor.Service.Capture;

public interface ISessionStoreFactory
{
    ISessionStore Create(string path);
}

internal sealed class SessionStoreFactory : ISessionStoreFactory
{
    public ISessionStore Create(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        string fullPath = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(fullPath) ??
            throw new ArgumentException("The session path must include a parent directory.", nameof(path));
        Directory.CreateDirectory(directory);
        return new SessionStore(fullPath);
    }
}
