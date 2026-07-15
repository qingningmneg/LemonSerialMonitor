using System.Windows;

namespace CommMonitor.App.Services;

public sealed class WpfConfirmationService : IConfirmationService
{
    private readonly Func<string, string, MessageBoxButton, MessageBoxImage, MessageBoxResult>
        _showMessage;

    public WpfConfirmationService()
        : this(MessageBox.Show)
    {
    }

    internal WpfConfirmationService(
        Func<string, string, MessageBoxButton, MessageBoxImage, MessageBoxResult> showMessage)
    {
        _showMessage = showMessage ?? throw new ArgumentNullException(nameof(showMessage));
    }

    public bool ConfirmClearSession() =>
        _showMessage(
            "清空会永久删除当前会话中的全部捕获记录，且无法撤销。是否继续？",
            "确认清空会话",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning) == MessageBoxResult.Yes;
}
