# PSSecureCommand

A PowerShell proof-of-concept for launching a child PowerShell process and injecting sensitive commands into it **without exposing those commands on the command line or in console history**.

## The Problem

When you launch a PowerShell (or any) process with sensitive data embedded in its arguments — for example, `-Command "Invoke-Something -Token 's3cr3t'"` — that data is visible to:

- Every other process on the system via the Windows process list (`Get-Process`, Task Manager, tools like Process Explorer, Sysinternals, etc.)
- The `ConsoleHost_history.txt` file on the parent side
- ETW tracing, audit logging, and similar telemetry that captures command-line arguments

The standard mitigation is `-EncodedCommand`, but Base64 encoding is trivially reversible and provides no real security — the full command is still in the argument list.

## The Solution

PSSecureCommand decouples the **bootstrap** command (what appears on the command line) from the **sensitive** command (what actually runs), by routing the latter through a **Windows named pipe** that only the two involved PowerShell processes can access.

```
Parent process                          Child process
──────────────────                      ─────────────────────────────
1. Generate unique pipe name            
2. Build bootstrap command that         
   only sets up the pipe client         
3. Encode + launch child with           4. Child decodes bootstrap, defines
   -EncodedCommand <safe payload>  →       Invoke-PSCmdClient, connects to pipe
4. Start named pipe server              5. Reads base64-encoded commands from pipe
5. Write secret commands →  pipe   →    6. Decodes and Invoke-Expression each command
6. Close pipe server                    7. Continues running (-NoExit)
```

The sensitive commands never appear in any process argument list. They travel over an IPC channel that is:

- Local-machine only (`"."` server)
- Single-client (`maxNumberOfServerInstances = 1`)
- Ephemeral (server closes after delivery)
- Identified by a randomly generated GUID pipe name

## Repository Layout

```
PSSecureCommand.ps1       # Reference proof-of-concept (single self-contained script)
PSSecureCommand.Tests.ps1 # Pester 5 test suite (33 tests)
README.md                 # This file
AGENTS.md                 # AI-agent guidance for working with this repo
```

## Key Functions

| Function | Role |
|---|---|
| `Invoke-PSCmdServer` | Named pipe server — waits for one client, writes Base64-encoded commands, closes |
| `Invoke-PSCmdClient` | Named pipe client — connects, reads Base64 lines, `Invoke-Expression` each one |
| `Unprotect-SecureString` | Cross-edition helper to convert `SecureString` → plain text |
| `Get-FunctionDefinition` | Serialises a loaded function's source so it can be injected into another process |

## How to Run

```powershell
# From the repo root
.\PSSecureCommand.ps1
```

A new PowerShell window opens. After a brief moment it will execute the injected secure commands (demo: creates a `SecureString` containing `my-secret` and prints its plain-text value). The parent process exits cleanly once the named pipe server has delivered the payload.

## Requirements

- PowerShell 5.1 (Windows PowerShell) **or** PowerShell 7+ (pwsh)
- Windows OS (named pipe server uses `"."` local-machine reference)
- No external module dependencies

## Running the Tests

```powershell
# Install Pester if not already present
Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser

# Run all tests
Invoke-Pester .\PSSecureCommand.Tests.ps1 -Output Detailed
```

## Security Considerations

**What this protects against:**

- Command-line snooping by other processes (the sensitive payload is never an argument)
- `ConsoleHost_history.txt` exposure on the parent side (commands are built programmatically)
- Casual inspection of process command lines in Task Manager / Process Explorer

**What this does NOT protect against:**

- A privileged process intercepting named pipe traffic (e.g., kernel-level monitoring)
- An adversary who already has the same user context (they could connect to the pipe before the child process does — the 3-second `Connect(3000)` timeout provides a small race mitigation but is not a security boundary)
- The commands themselves executing in the child process (they are still `Invoke-Expression`'d in plain text in memory)
- ETW / Script Block Logging, which captures all executed script blocks at the PowerShell engine level regardless of how they were delivered

This is a **proof of concept** demonstrating the delivery mechanism, not a hardened production security control.

## How It Works — Deep Dive

### 1. Bootstrap command construction

```powershell
$ClientCommand = @(
    $(Get-FunctionDefinition 'Unprotect-SecureString'),
    $(Get-FunctionDefinition 'Invoke-PSCmdClient'),
    "Invoke-PSCmdClient $PipeName") | Out-String
```

`Get-FunctionDefinition` reads the function body from the PowerShell function provider (`function:\<Name>`), wrapping it back into a `function Name { ... }` string. This self-serialisation means no external files are needed in the child process.

### 2. Child process launch

```powershell
$EncodedCommand = [Convert]::ToBase64String(
    [System.Text.Encoding]::Unicode.GetBytes($ClientCommand))
Start-Process $ShellName -ArgumentList @('-EncodedCommand', $EncodedCommand, '-NoExit')
```

The encoded command contains only infrastructure — pipe name + function definitions. No secrets.

### 3. Secure command delivery

```powershell
Invoke-PSCmdServer $PipeName -Commands @($SecureCommand)
```

The server Base64-encodes each command (UTF-8) and writes it as a newline-delimited stream. The client Base64-decodes and `Invoke-Expression`s each line. Using a separate encoding (UTF-8 for pipe content, UTF-16LE for `-EncodedCommand`) avoids conflicts.
