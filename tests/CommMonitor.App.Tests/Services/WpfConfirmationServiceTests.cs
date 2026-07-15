using System.Windows;
using CommMonitor.App.Services;

namespace CommMonitor.App.Tests.Services;

public sealed class WpfConfirmationServiceTests
{
    [Theory]
    [InlineData(MessageBoxResult.Yes, true)]
    [InlineData(MessageBoxResult.No, false)]
    public void Clear_confirmation_requires_an_explicit_Yes(
        MessageBoxResult result,
        bool expected)
    {
        MessageBoxButton? button = null;
        MessageBoxImage? image = null;
        var service = new WpfConfirmationService((message, caption, requestedButton, requestedImage) =>
        {
            Assert.Contains("无法撤销", message, StringComparison.Ordinal);
            Assert.Contains("清空", caption, StringComparison.Ordinal);
            button = requestedButton;
            image = requestedImage;
            return result;
        });

        Assert.Equal(expected, service.ConfirmClearSession());
        Assert.Equal(MessageBoxButton.YesNo, button);
        Assert.Equal(MessageBoxImage.Warning, image);
    }
}
