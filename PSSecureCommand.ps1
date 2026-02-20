
function Invoke-PSCmdClient
{
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
            $SecureCommand = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedCommand))
            Invoke-Expression $SecureCommand
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
    param(
        [Parameter(Position=0)]
        [string] $Name
    )

    "function $Name { $(Get-Content "function:\$Name") }"
}

$PipeName = "pscmd-" + (New-Guid).ToString()

$ClientCommand = @(
    $(Get-FunctionDefinition 'Unprotect-SecureString'),
    $(Get-FunctionDefinition 'Invoke-PSCmdClient'),
    "Invoke-PSCmdClient $PipeName") | Out-String

$EncodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ClientCommand))

# Launch a child PowerShell instance with an EncodedCommand that contains no sensitive data.
# Instead, the sensitive commands are passed from the parent to the child through a named pipe,
# and executed using Invoke-Expression without leaking the contents in ConsoleHost_history.txt.

$ShellName = if ($PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
Start-Process $ShellName -ArgumentList @('-EncodedCommand', $EncodedCommand, '-NoExit')

# This secure command should not appear in plain text in the parent, but rather loaded into a variable.
# While it won't be encrypted when passed to the child process over a named pipe, its contents will not
# be leaked to all processes on the system through the command-line arguments, or the console history.

$SecureCommand = @(
    "`$MySecret = ConvertTo-SecureString 'my-secret' -AsPlainText -Force",
    "Unprotect-SecureString `$MySecret") | Out-String

# Launch the named pipe server from which the child process will read the secure commands from.
# We take care of allowing only one named pipe client, and we close the named pipe server after.
Invoke-PSCmdServer $PipeName -Commands @($SecureCommand)
