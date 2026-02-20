#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
.SYNOPSIS
    Pester 5 tests for pscmd.ps1.

.DESCRIPTION
    Loads only the function definitions from pscmd.ps1 using the PowerShell AST
    so that the script's main body (which launches child processes) is never
    executed during testing.  Integration tests for the named pipe transport use
    PowerShell background jobs so the server and client sides can run concurrently
    within the test process.
#>

BeforeAll {
    # ── Load function definitions only ────────────────────────────────────────
    # Parse the reference POC with the PS AST and extract every FunctionDefinition
    # node.  This avoids dot-sourcing the file (which would run the main body and
    # spin up a child process).
    $Script:SourcePath = Join-Path $PSScriptRoot 'pscmd.ps1'

    $tokens = $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Script:SourcePath, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors.Count -gt 0) {
        throw "AST parse errors in pscmd.ps1: $($parseErrors -join '; ')"
    }

    $functionAsts = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $false)

    foreach ($fnAst in $functionAsts) {
        Invoke-Expression $fnAst.Extent.Text
    }

    # ── Helper: serialise a function so it can be sent to a job ──────────────
    function Script:Get-SerializedFunction {
        param([string] $Name)
        "function $Name { $(Get-Content "function:\$Name") }"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'AST loading' {
    It 'loads all four expected functions from pscmd.ps1' {
        $expectedFunctions = @(
            'Invoke-PSCmdClient',
            'Invoke-PSCmdServer',
            'Unprotect-SecureString',
            'Get-FunctionDefinition'
        )
        foreach ($name in $expectedFunctions) {
            Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty -Because "function '$name' should be defined after loading"
        }
    }

    It 'pscmd.ps1 has no parse errors' {
        $t = $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $Script:SourcePath, [ref]$t, [ref]$e) | Out-Null
        $e.Count | Should -Be 0
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Unprotect-SecureString' {
    It 'returns the original plain-text value from a SecureString' {
        $plain = 'SuperSecret123!'
        $secure = ConvertTo-SecureString $plain -AsPlainText -Force
        Unprotect-SecureString $secure | Should -BeExactly $plain
    }

    It 'handles special characters and Unicode' {
        $plain = 'P@$$w0rd!£€¥—😀'
        $secure = ConvertTo-SecureString $plain -AsPlainText -Force
        Unprotect-SecureString $secure | Should -BeExactly $plain
    }

    It 'can be called with the SecureString passed as a positional argument' {
        # The parameter is declared [Parameter(Position=0)] without ValueFromPipeline,
        # so positional (non-pipeline) invocation is the intended calling convention.
        $plain = 'positional-test'
        $secure = ConvertTo-SecureString $plain -AsPlainText -Force
        $result = Unprotect-SecureString $secure
        $result | Should -BeExactly $plain
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Get-FunctionDefinition' {
    It 'returns a string that starts with the "function" keyword' {
        $def = Get-FunctionDefinition 'Unprotect-SecureString'
        $def.TrimStart() | Should -Match '^function\s+'
    }

    It 'includes the requested function name in the returned definition' {
        $def = Get-FunctionDefinition 'Invoke-PSCmdClient'
        $def | Should -Match 'Invoke-PSCmdClient'
    }

    It 'produces a definition that is valid, re-executable PowerShell' {
        # Serialise a known simple function and re-define it; the redefined version
        # should still produce the correct output.
        $def = Get-FunctionDefinition 'Unprotect-SecureString'
        { Invoke-Expression $def } | Should -Not -Throw
    }

    It 'round-trips: re-defined function behaves identically to the original' {
        $def = Get-FunctionDefinition 'Unprotect-SecureString'
        Invoke-Expression $def   # overwrite in current scope – same body

        $plain = 'round-trip-test'
        $secure = ConvertTo-SecureString $plain -AsPlainText -Force
        Unprotect-SecureString $secure | Should -BeExactly $plain
    }

    It 'includes the function body (non-empty content between braces)' {
        $def = Get-FunctionDefinition 'Invoke-PSCmdServer'
        # Body should reference the pipe type
        $def | Should -Match 'NamedPipeServerStream'
    }

    It 'raises an error for a non-existent function name' {
        # Get-Content emits a non-terminating error when the function path does not
        # exist.  Setting $ErrorActionPreference = 'Stop' inside the script block
        # promotes that to a terminating error that Should -Throw can catch.
        {
            $ErrorActionPreference = 'Stop'
            Get-FunctionDefinition 'NonExistentFunction_XYZ'
        } | Should -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Base64 / UTF-8 encoding (pipe payload round-trip)' {
    # The pipe protocol: UTF8 bytes → Base64 string → UTF8 bytes → original string
    # Mirrors exactly what Invoke-PSCmdServer / Invoke-PSCmdClient do.

    It 'encodes and decodes a simple ASCII command round-trip' {
        $original = 'Write-Host "Hello, World!"'
        $encoded  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($original))
        $decoded  = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        $decoded | Should -BeExactly $original
    }

    It 'encodes and decodes a multi-line command block round-trip' {
        $original = "`$x = 1`n`$y = 2`n`$x + `$y"
        $encoded  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($original))
        $decoded  = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        $decoded | Should -BeExactly $original
    }

    It 'produces different Base64 output for different inputs' {
        $a = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('CommandA'))
        $b = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('CommandB'))
        $a | Should -Not -BeExactly $b
    }

    It 'encoded output contains no whitespace (safe for WriteLine / ReadLine)' {
        $encoded = [Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes('Some-Command -Param value'))
        $encoded | Should -Not -Match '\s'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Invoke-PSCmdServer / Invoke-PSCmdClient (named pipe integration)' {
    BeforeEach {
        # Each test gets its own unique pipe to avoid collisions
        $Script:PipeName = 'pscmd-test-' + (New-Guid).ToString()
    }

    AfterEach {
        # Clean up any lingering jobs
        if ($Script:ServerJob) {
            Remove-Job -Job $Script:ServerJob -Force -ErrorAction SilentlyContinue
            $Script:ServerJob = $null
        }
    }

    It 'client receives and executes a single command sent by the server' {
        $pipeName   = $Script:PipeName
        $serverFnDef = Script:Get-SerializedFunction 'Invoke-PSCmdServer'

        # Run the server in a background job
        $Script:ServerJob = Start-Job -ScriptBlock {
            param($fn, $pipe, $cmds)
            Invoke-Expression $fn
            Invoke-PSCmdServer -PipeName $pipe -Commands $cmds
        } -ArgumentList $serverFnDef, $pipeName, @('$global:PipeTestResult = "delivered"')

        # Run the client in the current session (blocks until server disconnects)
        Invoke-PSCmdClient -PipeName $pipeName

        $global:PipeTestResult | Should -BeExactly 'delivered'
        Remove-Variable -Name PipeTestResult -Scope Global -ErrorAction SilentlyContinue
    }

    It 'client executes multiple commands in order' {
        $pipeName    = $Script:PipeName
        $serverFnDef = Script:Get-SerializedFunction 'Invoke-PSCmdServer'
        $commands    = @(
            '$global:OrderTest = [System.Collections.Generic.List[int]]::new()',
            '$global:OrderTest.Add(1)',
            '$global:OrderTest.Add(2)',
            '$global:OrderTest.Add(3)'
        )

        $Script:ServerJob = Start-Job -ScriptBlock {
            param($fn, $pipe, $cmds)
            Invoke-Expression $fn
            Invoke-PSCmdServer -PipeName $pipe -Commands $cmds
        } -ArgumentList $serverFnDef, $pipeName, $commands

        Invoke-PSCmdClient -PipeName $pipeName

        $global:OrderTest | Should -HaveCount 3
        $global:OrderTest[0] | Should -Be 1
        $global:OrderTest[1] | Should -Be 2
        $global:OrderTest[2] | Should -Be 3
        Remove-Variable -Name OrderTest -Scope Global -ErrorAction SilentlyContinue
    }

    It 'client handles a command that produces output without throwing' {
        $pipeName    = $Script:PipeName
        $serverFnDef = Script:Get-SerializedFunction 'Invoke-PSCmdServer'

        $Script:ServerJob = Start-Job -ScriptBlock {
            param($fn, $pipe, $cmds)
            Invoke-Expression $fn
            Invoke-PSCmdServer -PipeName $pipe -Commands $cmds
        } -ArgumentList $serverFnDef, $pipeName, @('"output-test"')

        { Invoke-PSCmdClient -PipeName $pipeName } | Should -Not -Throw
    }

    It 'client throws when the server is not available within the timeout' {
        # Use a pipe name for which no server will ever start
        $phantom = 'pscmd-phantom-' + (New-Guid).ToString()
        { Invoke-PSCmdClient -PipeName $phantom } | Should -Throw
    }

    It 'server sends commands that survive a SecureString round-trip via the pipe' {
        $pipeName    = $Script:PipeName
        $serverFnDef = Script:Get-SerializedFunction 'Invoke-PSCmdServer'
        $unprotectFnDef = Script:Get-SerializedFunction 'Unprotect-SecureString'

        $commands = @(
            $unprotectFnDef,
            "`$global:SecurePipeResult = Unprotect-SecureString (ConvertTo-SecureString 'piped-secret' -AsPlainText -Force)"
        )

        $Script:ServerJob = Start-Job -ScriptBlock {
            param($fn, $pipe, $cmds)
            Invoke-Expression $fn
            Invoke-PSCmdServer -PipeName $pipe -Commands $cmds
        } -ArgumentList $serverFnDef, $pipeName, $commands

        Invoke-PSCmdClient -PipeName $pipeName

        $global:SecurePipeResult | Should -BeExactly 'piped-secret'
        Remove-Variable -Name SecurePipeResult -Scope Global -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Security properties' {
    It 'pipe name is not a static string (uses a GUID component)' {
        # Read the raw source to verify the GUID generation is present
        $source = Get-Content $Script:SourcePath -Raw
        $source | Should -Match 'New-Guid'
    }

    It 'server limits connections to one client (maxNumberOfServerInstances = 1)' {
        $source = Get-Content $Script:SourcePath -Raw
        # The NamedPipeServerStream constructor call should pass 1 as maxInstances
        $source | Should -Match 'NamedPipeServerStream'
        # The literal value 1 for max instances appears in the constructor arguments
        $source | Should -Match '\bOut\b.*\b1\b|\b1\b.*\bOut\b'
    }

    It 'client connection uses a finite timeout (not Timeout.Infinite)' {
        $source = Get-Content $Script:SourcePath -Raw
        # Connect(3000) – a finite millisecond value, not -1
        $source | Should -Match '\.Connect\(\d+'
    }

    It 'the bootstrap EncodedCommand is Unicode (UTF-16LE) as required by PowerShell' {
        $source = Get-Content $Script:SourcePath -Raw
        $source | Should -Match 'Encoding\]::Unicode'
    }

    It 'pipe payload encoding is UTF-8 (distinct from the bootstrap encoding)' {
        $source = Get-Content $Script:SourcePath -Raw
        $source | Should -Match 'Encoding\]::UTF8'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Shell selection' {
    It 'source selects powershell.exe on Desktop edition and pwsh on Core' {
        $source = Get-Content $Script:SourcePath -Raw
        # The ternary assignment should reference both edition names
        $source | Should -Match "PSEdition\s*-eq\s*'Desktop'"
        $source | Should -Match "'powershell'"
        $source | Should -Match "'pwsh'"
    }

    It 'the shell expected for the current edition is available on this system' {
        $expected = if ($PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }
        $cmd = Get-Command $expected -CommandType Application -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty -Because "$expected must be on PATH for pscmd.ps1 to launch the child process"
    }

    It 'the other edition shell (if present) is also a valid executable' {
        # This is informational — not a hard failure if the other shell is absent,
        # but if it IS present it must be a real executable.
        $other = if ($PSEdition -eq 'Desktop') { 'pwsh' } else { 'powershell' }
        $cmd = Get-Command $other -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            $cmd.Source | Should -Match '\.exe$'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'End-to-end child process' {
    BeforeEach {
        $Script:E2EPipeName = 'pscmd-e2e-' + (New-Guid).ToString()
        $Script:E2EOutFile  = Join-Path $env:TEMP ('pscmd-e2e-' + (New-Guid).ToString() + '.txt')
    }

    AfterEach {
        Remove-Item $Script:E2EOutFile -Force -ErrorAction SilentlyContinue
    }

    It 'injected command actually executes in the child process (confirmed via sentinel file)' {
        $pipeName = $Script:E2EPipeName
        $outFile  = $Script:E2EOutFile

        # Build the bootstrap the same way pscmd.ps1's main body does.
        $clientCmd = @(
            (Get-FunctionDefinition 'Unprotect-SecureString'),
            (Get-FunctionDefinition 'Invoke-PSCmdClient'),
            "Invoke-PSCmdClient $pipeName"
        ) | Out-String

        $encoded   = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($clientCmd))
        $shellName = if ($PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }

        # The injected (secret) command writes a sentinel value to a temp file.
        # Single-quoting $outFile at construction time bakes in the literal path.
        $injected = "'e2e-success' | Set-Content -LiteralPath '$outFile'"

        # Launch the child — no -NoExit so it exits once the pipe closes.
        $proc = Start-Process $shellName `
            -ArgumentList @('-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded) `
            -PassThru

        try {
            # Server blocks until child connects, sends the injected command, then closes.
            Invoke-PSCmdServer -PipeName $pipeName -Commands @($injected)

            # Give the child up to 10 s to finish executing and exit.
            $exited = $proc.WaitForExit(10000)
            $exited | Should -BeTrue -Because 'the child process should exit cleanly after the pipe closes'

            # The sentinel file must exist and contain the value written by the injected command.
            Test-Path $outFile | Should -BeTrue -Because 'the injected command should have created the output file'
            Get-Content $outFile -Raw | Should -Match 'e2e-success'
        } finally {
            if (-not $proc.HasExited) { $proc.Kill() }
            $proc.Dispose()
        }
    }

    It 'correct shell executable is used for the current edition' {
        $pipeName  = $Script:E2EPipeName
        $outFile   = $Script:E2EOutFile
        $shellName = if ($PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }

        $clientCmd = @(
            (Get-FunctionDefinition 'Unprotect-SecureString'),
            (Get-FunctionDefinition 'Invoke-PSCmdClient'),
            "Invoke-PSCmdClient $pipeName"
        ) | Out-String

        $encoded  = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($clientCmd))

        # The injected command writes the child's $PSVersionTable.PSEdition to the file,
        # letting us confirm we launched the right shell.
        $injected = '$PSVersionTable.PSEdition | Set-Content -LiteralPath ' + "'$outFile'"

        $proc = Start-Process $shellName `
            -ArgumentList @('-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded) `
            -PassThru

        try {
            Invoke-PSCmdServer -PipeName $pipeName -Commands @($injected)
            $proc.WaitForExit(10000) | Out-Null

            $edition = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue) -replace '\s'
            if ($PSEdition -eq 'Desktop') {
                $edition | Should -BeExactly 'Desktop'
            } else {
                $edition | Should -BeExactly 'Core'
            }
        } finally {
            if (-not $proc.HasExited) { $proc.Kill() }
            $proc.Dispose()
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe 'Command secrecy — no leakage to command line or history' {
    BeforeEach {
        $Script:SecrecyPipeName = 'pscmd-secrecy-' + (New-Guid).ToString()
        $Script:SecrecyOutFile  = Join-Path $env:TEMP ('pscmd-secrecy-' + (New-Guid).ToString() + '.txt')
        # A unique sentinel that is recognisable if it ever leaks somewhere it should not.
        $Script:SecretPayload   = 'TOP-SECRET-' + (New-Guid).ToString()
    }

    AfterEach {
        Remove-Item $Script:SecrecyOutFile -Force -ErrorAction SilentlyContinue
    }

    It 'the -EncodedCommand bootstrap (decoded) does not contain the secret payload' {
        $pipeName = $Script:SecrecyPipeName
        $secret   = $Script:SecretPayload

        # Build exactly the same bootstrap that pscmd.ps1 builds.
        $clientCmd = @(
            (Get-FunctionDefinition 'Unprotect-SecureString'),
            (Get-FunctionDefinition 'Invoke-PSCmdClient'),
            "Invoke-PSCmdClient $pipeName"
        ) | Out-String

        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($clientCmd))

        # The secret hasn't been mentioned yet — confirm neither the raw Base64
        # nor its decoded form contain it.
        $encoded | Should -Not -Match [regex]::Escape($secret) `
            -Because 'the raw Base64 argument must not contain the secret'

        $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $decoded | Should -Not -Match [regex]::Escape($secret) `
            -Because 'the decoded -EncodedCommand must not contain the secret payload'
    }

    It 'the child process command-line (visible to other OS processes) does not contain the secret' {
        $pipeName  = $Script:SecrecyPipeName
        $outFile   = $Script:SecrecyOutFile
        $secret    = $Script:SecretPayload
        $shellName = if ($PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }

        $clientCmd = @(
            (Get-FunctionDefinition 'Unprotect-SecureString'),
            (Get-FunctionDefinition 'Invoke-PSCmdClient'),
            "Invoke-PSCmdClient $pipeName"
        ) | Out-String

        $encoded     = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($clientCmd))
        $injected    = "'$secret' | Set-Content -LiteralPath '$outFile'"
        $serverFnDef = Script:Get-SerializedFunction 'Invoke-PSCmdServer'

        # Run the pipe server in a job — this lets the main thread query CIM
        # while the child process is alive and blocked connecting to the pipe.
        $serverJob = Start-Job -ScriptBlock {
            param($fn, $pipe, $cmds)
            Invoke-Expression $fn
            Invoke-PSCmdServer -PipeName $pipe -Commands $cmds
        } -ArgumentList $serverFnDef, $pipeName, @($injected)

        $proc = Start-Process $shellName `
            -ArgumentList @('-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded) `
            -PassThru

        try {
            # Retry briefly: the process must start before it appears in CIM.
            $cmdLine = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while ($null -eq $cmdLine -and [DateTime]::UtcNow -lt $deadline) {
                $cmdLine = (Get-CimInstance Win32_Process `
                    -Filter "ProcessId = $($proc.Id)" `
                    -ErrorAction SilentlyContinue).CommandLine
                if ($null -eq $cmdLine) { Start-Sleep -Milliseconds 100 }
            }

            $cmdLine | Should -Not -BeNullOrEmpty `
                -Because 'could not retrieve the child process command line from CIM'
            $cmdLine | Should -Not -Match [regex]::Escape($secret) `
                -Because 'the secret must not appear in the child process command-line arguments'

            $proc.WaitForExit(10000) | Out-Null
            Wait-Job $serverJob -Timeout 5 | Out-Null
        } finally {
            Remove-Job $serverJob -Force -ErrorAction SilentlyContinue
            if (-not $proc.HasExited) { $proc.Kill() }
            $proc.Dispose()
        }
    }

    It 'the PSReadLine history file is not updated with the secret after child execution' {
        $pipeName  = $Script:SecrecyPipeName
        $outFile   = $Script:SecrecyOutFile
        $secret    = $Script:SecretPayload
        $shellName = if ($PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' }

        # Locate the PSReadLine history file used by this session.
        $histPath = $null
        if (Get-Module PSReadLine -ErrorAction SilentlyContinue) {
            $histPath = (Get-PSReadLineOption).HistorySavePath
        }

        $clientCmd = @(
            (Get-FunctionDefinition 'Unprotect-SecureString'),
            (Get-FunctionDefinition 'Invoke-PSCmdClient'),
            "Invoke-PSCmdClient $pipeName"
        ) | Out-String

        $encoded  = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($clientCmd))
        $injected = "'$secret' | Set-Content -LiteralPath '$outFile'"

        # Snapshot the history file before launching the child.
        $histBefore = if ($histPath -and (Test-Path $histPath)) {
            Get-Content $histPath -Raw -ErrorAction SilentlyContinue
        } else { '' }

        $proc = Start-Process $shellName `
            -ArgumentList @('-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded) `
            -PassThru

        try {
            Invoke-PSCmdServer -PipeName $pipeName -Commands @($injected)
            $proc.WaitForExit(10000) | Out-Null

            if ($histPath -and (Test-Path $histPath)) {
                $histAfter = Get-Content $histPath -Raw -ErrorAction SilentlyContinue

                # Any lines added after our snapshot should not contain the secret.
                $newLines = $histAfter -replace [regex]::Escape($histBefore), ''
                $newLines | Should -Not -Match [regex]::Escape($secret) `
                    -Because 'commands executed via named pipe must not appear in ConsoleHost_history.txt'
            } else {
                Set-ItResult -Skipped -Because 'PSReadLine history file does not exist on this system'
            }
        } finally {
            if (-not $proc.HasExited) { $proc.Kill() }
            $proc.Dispose()
        }
    }
}
