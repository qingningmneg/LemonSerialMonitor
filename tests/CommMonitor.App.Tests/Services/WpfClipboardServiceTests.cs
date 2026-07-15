using CommMonitor.App.Services;

namespace CommMonitor.App.Tests.Services;

public sealed class WpfClipboardServiceTests
{
    [Fact]
    public void SetText_marshals_the_clipboard_operation_to_an_STA_thread()
    {
        ApartmentState callbackApartment = ApartmentState.Unknown;
        string? callbackThreadName = null;
        var service = new WpfClipboardService(
            _ =>
            {
                callbackApartment = Thread.CurrentThread.GetApartmentState();
                callbackThreadName = Thread.CurrentThread.Name;
            });
        Exception? exception = null;
        var caller = new Thread(() =>
        {
            try
            {
                service.SetText("01 FF");
            }
            catch (Exception caught)
            {
                exception = caught;
            }
        });
        caller.SetApartmentState(ApartmentState.MTA);

        caller.Start();
        Assert.True(caller.Join(TimeSpan.FromSeconds(5)));

        Assert.Null(exception);
        Assert.Equal(ApartmentState.STA, callbackApartment);
        Assert.Equal("Lemon\u4E32\u53E3\u76D1\u63A7\u526A\u8D34\u677F", callbackThreadName);
    }
}
