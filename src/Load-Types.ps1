# Compiles the C# sources into this PowerShell session. Dot-sourced by watchdog.ps1, install.ps1,
# uninstall.ps1 and the tests. There is nothing to build in advance and no binary to trust.
#
# A type can only be added once per process, and install.ps1 and the installed watchdog.ps1 can share
# a console while running from different folders, so the types are only compiled if they are missing.
if (-not ('FreezeDump.Program' -as [type])) {
  $sources = @('Core', 'Config', 'Detector', 'Probe', 'Notify', 'Dump', 'Listener', 'Watchdog', 'Simulation') |
    ForEach-Object { Join-Path $PSScriptRoot "$_.cs" }

  Add-Type -Path $sources -ReferencedAssemblies @(
    'System.Collections', 'System.Collections.Concurrent', 'System.ComponentModel.Primitives', 'System.Console',
    'System.Diagnostics.Process', 'System.IO.FileSystem.AccessControl', 'System.Linq', 'System.Memory',
    'System.Net.Http', 'System.Net.Primitives', 'System.Net.Sockets', 'System.Runtime',
    'System.Runtime.InteropServices', 'System.Security.AccessControl', 'System.Security.Claims',
    'System.Security.Principal', 'System.Security.Principal.Windows', 'System.Text.Encoding.Extensions',
    'System.Text.Json', 'System.Threading', 'System.Threading.Thread', 'Microsoft.Win32.Primitives'
  )
}
