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
Parent process                            Child process
──────────────────                        ─────────────────────────────
1. Generate unique GUID pipe name
2. Serialise helper functions into
   a bootstrap -EncodedCommand
   (no secrets included)
3. Launch child with -EncodedCommand  →   A. Decode bootstrap, define functions
4. Start named pipe server            ←   B. Connect to pipe (3 s timeout)
5. Send secret commands over pipe     →   C. Decode + Invoke-Expression each command
6. Close pipe server                  →   D. ReadLine returns null → exit pipe loop
                                          E. Continue running interactively (-NoExit)
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

A new PowerShell window opens. After a brief moment it executes the injected commands (demo: creates a `SecureString` containing `my-secret` and prints its plain-text value). The **parent** script exits once the named pipe server has finished delivering the payload; the **child** window stays open (`-NoExit`) so you can inspect the result.

## Requirements

- PowerShell 5.1 (Windows PowerShell) **or** PowerShell 7+ (pwsh)
- Windows OS (named pipe server uses `"."` local-machine reference)
- No runtime dependencies — all APIs used ship with PowerShell
- Pester 5+ required to run the test suite (not needed to run the POC)

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
$EncodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ClientCommand))
Start-Process $ShellName -ArgumentList @('-EncodedCommand', $EncodedCommand, '-NoExit')
```

The encoded command contains only infrastructure — pipe name + function definitions. No secrets.

### 3. Secret command delivery

```powershell
Invoke-PSCmdServer $PipeName -Commands @($SecretPayload)
```

The server Base64-encodes each command string (UTF-8 bytes → Base64) and writes it as a newline-delimited line. Multiple commands can be batched in the `$Commands` array — the client reads and `Invoke-Expression`s them in order, then exits the loop when `ReadLine` returns `$null` as the pipe closes.

Using UTF-8 for pipe content and UTF-16 LE for `-EncodedCommand` keeps the two channels' encodings independent and avoids any decoding conflicts.
