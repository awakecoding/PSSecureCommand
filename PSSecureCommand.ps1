
<#
.SYNOPSIS
    Proof-of-concept: deliver sensitive commands to a child PowerShell process
    through a named pipe so they never appear on the command line or in history.

.DESCRIPTION
    The parent process serialises its helper functions into a bootstrap
    -EncodedCommand that contains no secrets, launches a child PowerShell
    instance with that bootstrap, then sends the real commands over a one-shot
    named pipe identified by a random GUID.

    The child receives the commands as newline-delimited Base64 (UTF-8) lines,
    decodes them, and executes each one with Invoke-Expression.
#>

# ── Helper functions ─────────────────────────────────────────────────────────

function Invoke-PSCmdClient
{
    <#
    .SYNOPSIS
        Named pipe client — receives Base64-encoded commands and executes them.
    .PARAMETER PipeName
        The name of the pipe to connect to (must match the server's pipe name).
    #>
    param(
        [Parameter(Position=0)]
        [string] $PipeName
    )

    $Pipe = $Reader = $null

    try {
        $Pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $PipeName,
            [System.IO.Pipes.PipeDirection]::In)
        $Pipe.Connect(3000)
        $Reader = [System.IO.StreamReader]::new($Pipe)
        while ($null -ne ($EncodedCommand = $Reader.ReadLine())) {
            $DecodedCommand = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedCommand))
            Invoke-Expression $DecodedCommand
        }
        $Reader.Close()
    } finally {
        if ($null -ne $Reader) {
            $Reader.Dispose()
        }
        if ($null -ne $Pipe) {
            $Pipe.Dispose()
        }
    }
}

function Invoke-PSCmdServer
{
    <#
    .SYNOPSIS
        Named pipe server — encodes commands as Base64 and writes them to the pipe.
    .PARAMETER PipeName
        The name of the pipe to create.  Must be a unique GUID-based name.
    .PARAMETER Commands
        One or more plain-text PowerShell commands to deliver to the client.
        Each command is encoded as UTF-8 Base64 and sent as a single line.
    #>
    param(
        [Parameter(Position=0)]
        [string] $PipeName,
        [Parameter(Mandatory=$true)]
        [string[]] $Commands
    )

    $Pipe = $Writer = $null

    try {
        $Pipe = [System.IO.Pipes.NamedPipeServerStream]::new($PipeName,
        [System.IO.Pipes.PipeDirection]::Out, 1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte)
        $Pipe.WaitForConnection()
        $Writer = [System.IO.StreamWriter]::new($Pipe)
        $Writer.AutoFlush = $true
        foreach ($Command in $Commands) {
            $EncodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Command))
            $Writer.WriteLine($EncodedCommand)
        }
        $Writer.Close()
    } finally {
        if ($null -ne $Writer) {
            $Writer.Dispose()
        }
        if ($null -ne $Pipe) {
            $Pipe.Dispose()
        }
    }
}

function Unprotect-SecureString
{
    <#
    .SYNOPSIS
        Converts a SecureString to plain text, compatible with PS 5.1 and PS 7+.
    .PARAMETER SecureString
        The SecureString to decrypt.
    #>
    param(
        [Parameter(Position=0)]
        [SecureString] $SecureString
    )

    if ($PSEdition -eq 'Desktop') {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } else {
        ConvertFrom-SecureString -SecureString $SecureString -AsPlainText
    }
}

function Get-FunctionDefinition
{
    <#
    .SYNOPSIS
        Serialises a loaded function to a self-contained 'function Name { ... }' string.
    .PARAMETER Name
        The name of a function already present in the current session.
    #>
    param(
        [Parameter(Position=0)]
        [string] $Name
    )

    "function $Name { $(Get-Content "function:\$Name") }"
}

# ── Phase 1: build the bootstrap (contains no secrets) ──────────────────────

# A unique GUID-based pipe name prevents collisions and limits hijack surface.
$PipeName = 'pscmd-' + (New-Guid).ToString()

# Serialise only the infrastructure functions into the bootstrap command.
# The bootstrap sets up the pipe client inside the child; no secrets are included.
$ClientCommand = @(
    $(Get-FunctionDefinition 'Unprotect-SecureString'),
    $(Get-FunctionDefinition 'Invoke-PSCmdClient'),
    "Invoke-PSCmdClient $PipeName") | Out-String

# -EncodedCommand requires UTF-16 LE (Unicode).  The pipe payload uses UTF-8 — keep them separate.
$EncodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ClientCommand))

# ── Phase 2: launch the child process ────────────────────────────────────────

# The child receives only the bootstrap via -EncodedCommand.  Its argument list
# is visible to every process on the system, but it contains no sensitive data.
$ShellName = if ($PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
Start-Process $ShellName -ArgumentList @('-EncodedCommand', $EncodedCommand, '-NoExit')

# ── Phase 3: deliver the secret commands over the named pipe ──────────────────

# Build the sensitive payload in a variable — never passed as a command-line argument,
# never written to ConsoleHost_history.txt, never visible in the process argument list.
$SecureCommand = @(
    "`$MySecret = ConvertTo-SecureString 'my-secret' -AsPlainText -Force",
    "Unprotect-SecureString `$MySecret") | Out-String

# The server accepts exactly one client, sends all commands, then closes the pipe.
Invoke-PSCmdServer $PipeName -Commands @($SecureCommand)
