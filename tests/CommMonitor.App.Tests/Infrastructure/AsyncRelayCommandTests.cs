using CommMonitor.App.Infrastructure;

namespace CommMonitor.App.Tests.Infrastructure;

public sealed class AsyncRelayCommandTests
{
    [Fact]
    public async Task ExecuteAsync_disables_reentry_until_the_operation_completes()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        int callCount = 0;
        var command = new AsyncRelayCommand(async () =>
        {
            callCount++;
            entered.SetResult();
            await release.Task;
        });

        Task first = command.ExecuteAsync();
        await entered.Task;
        Task second = command.ExecuteAsync();

        Assert.False(command.CanExecute(parameter: null));
        Assert.Equal(1, callCount);
        release.SetResult();
        await Task.WhenAll(first, second);
        Assert.True(command.CanExecute(parameter: null));
    }
}
