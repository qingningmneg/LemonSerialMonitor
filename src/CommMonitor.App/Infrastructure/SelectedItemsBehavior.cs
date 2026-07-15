using System.Collections;
using System.Windows;
using System.Windows.Controls;

namespace CommMonitor.App.Infrastructure;

public static class SelectedItemsBehavior
{
    public static readonly DependencyProperty SelectedItemsProperty =
        DependencyProperty.RegisterAttached(
            "SelectedItems",
            typeof(IList),
            typeof(SelectedItemsBehavior),
            new PropertyMetadata(default(IList), SelectedItemsOnChanged));

    public static IList? GetSelectedItems(DependencyObject target) =>
        (IList?)target.GetValue(SelectedItemsProperty);

    public static void SetSelectedItems(DependencyObject target, IList? value) =>
        target.SetValue(SelectedItemsProperty, value);

    private static void SelectedItemsOnChanged(
        DependencyObject target,
        DependencyPropertyChangedEventArgs eventArgs)
    {
        if (target is not DataGrid dataGrid)
        {
            return;
        }

        dataGrid.SelectionChanged -= DataGridOnSelectionChanged;
        if (eventArgs.NewValue is IList)
        {
            dataGrid.SelectionChanged += DataGridOnSelectionChanged;
            Synchronize(dataGrid);
        }
    }

    private static void DataGridOnSelectionChanged(
        object sender,
        SelectionChangedEventArgs eventArgs) => Synchronize((DataGrid)sender);

    private static void Synchronize(DataGrid dataGrid)
    {
        IList? target = GetSelectedItems(dataGrid);
        if (target is null)
        {
            return;
        }

        target.Clear();
        foreach (object item in dataGrid.SelectedItems)
        {
            target.Add(item);
        }
    }
}
