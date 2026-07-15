using System.Runtime.ExceptionServices;
using System.Windows;

namespace CommMonitor.App.Services;

public sealed class WpfClipboardService : IClipboardService
{
    private readonly Action<string> _setText;

    public WpfClipboardService()
        : this(Clipboard.SetText)
    {
    }

    internal WpfClipboardService(Action<string> setText)
    {
        _setText = setText ?? throw new ArgumentNullException(nameof(setText));
    }

    public void SetText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA)
        {
            _setText(text);
            return;
        }

        Exception? clipboardException = null;
        var thread = new Thread(() =>
        {
            try
            {
                _setText(text);
            }
            catch (Exception exception)
            {
                clipboardException = exception;
            }
        })
        {
            IsBackground = true,
            Name = "Lemon串口监控剪贴板",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();

        if (clipboardException is not null)
        {
            ExceptionDispatchInfo.Capture(clipboardException).Throw();
        }
    }
}
