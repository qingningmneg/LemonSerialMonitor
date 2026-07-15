using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Windows;
using System.Windows.Data;
using CommMonitor.Core.Formatting;

namespace CommMonitor.App.Infrastructure;

public sealed class PayloadHexConverter : IValueConverter
{
    public object Convert(
        object value,
        Type targetType,
        object parameter,
        CultureInfo culture) => value is ImmutableArray<byte> { IsDefault: false } payload
            ? ByteFormatter.Format(payload.AsSpan(), ByteFormat.HexSpaced)
            : string.Empty;

    public object ConvertBack(
        object value,
        Type targetType,
        object parameter,
        CultureInfo culture) => DependencyProperty.UnsetValue;
}

public sealed class PayloadTextConverter : IValueConverter
{
    public object Convert(
        object value,
        Type targetType,
        object parameter,
        CultureInfo culture) => value is ImmutableArray<byte> { IsDefault: false } payload
            ? Encoding.UTF8.GetString(payload.AsSpan())
            : string.Empty;

    public object ConvertBack(
        object value,
        Type targetType,
        object parameter,
        CultureInfo culture) => DependencyProperty.UnsetValue;
}
