using System.Security.AccessControl;
using System.Security.Principal;
using Lemon.UninstallHelper.Execution;

namespace Lemon.UninstallHelper.Tests;

public sealed class ProtectedStateAclValidatorTests
{
    private static readonly SecurityIdentifier SystemSid =
        new(WellKnownSidType.LocalSystemSid, domainSid: null);
    private static readonly SecurityIdentifier AdministratorsSid =
        new(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null);

    [Fact]
    public void Accepts_only_a_protected_SYSTEM_and_Administrators_descriptor()
    {
        FileSecurity security = TrustedDescriptor();

        ProtectedStateAclValidator.Validate(security);
    }

    [Fact]
    public void Rejects_an_untrusted_owner()
    {
        FileSecurity security = TrustedDescriptor();
        security.SetOwner(new SecurityIdentifier(
            WellKnownSidType.BuiltinUsersSid,
            domainSid: null));

        Assert.Throws<UnauthorizedAccessException>(() =>
            ProtectedStateAclValidator.Validate(security));
    }

    [Fact]
    public void Rejects_an_inheriting_descriptor()
    {
        FileSecurity security = TrustedDescriptor();
        security.SetAccessRuleProtection(isProtected: false, preserveInheritance: true);

        Assert.Throws<UnauthorizedAccessException>(() =>
            ProtectedStateAclValidator.Validate(security));
    }

    [Fact]
    public void Rejects_any_allow_rule_for_an_untrusted_principal()
    {
        FileSecurity security = TrustedDescriptor();
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, domainSid: null),
            FileSystemRights.Read,
            AccessControlType.Allow));

        Assert.Throws<UnauthorizedAccessException>(() =>
            ProtectedStateAclValidator.Validate(security));
    }

    [Fact]
    public void Rejects_a_missing_trusted_full_control_rule()
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(AdministratorsSid);
        security.AddAccessRule(new FileSystemAccessRule(
            AdministratorsSid,
            FileSystemRights.FullControl,
            AccessControlType.Allow));

        Assert.Throws<UnauthorizedAccessException>(() =>
            ProtectedStateAclValidator.Validate(security));
    }

    [Fact]
    public void Rejects_deny_or_partial_rules_even_for_trusted_principals()
    {
        FileSecurity denied = TrustedDescriptor();
        denied.AddAccessRule(new FileSystemAccessRule(
            AdministratorsSid,
            FileSystemRights.Delete,
            AccessControlType.Deny));
        var partial = new FileSecurity();
        partial.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        partial.SetOwner(AdministratorsSid);
        partial.AddAccessRule(new FileSystemAccessRule(
            AdministratorsSid,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        partial.AddAccessRule(new FileSystemAccessRule(
            SystemSid,
            FileSystemRights.Read,
            AccessControlType.Allow));

        Assert.Throws<UnauthorizedAccessException>(() =>
            ProtectedStateAclValidator.Validate(denied));
        Assert.Throws<UnauthorizedAccessException>(() =>
            ProtectedStateAclValidator.Validate(partial));
    }

    private static FileSecurity TrustedDescriptor()
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(AdministratorsSid);
        security.AddAccessRule(new FileSystemAccessRule(
            AdministratorsSid,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            SystemSid,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        return security;
    }
}
