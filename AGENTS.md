# AGENTS.md — AI Agent Guidance for PSSecureCommand

This file is addressed to AI coding agents working in this repository.  It
describes the codebase layout, the design intent, the conventions to follow,
and the pitfalls to avoid.

---

## Repository purpose

PSSecureCommand is a **single-file proof-of-concept** (`pscmd.ps1`).  Its sole
purpose is to demonstrate how a parent PowerShell process can pass sensitive
commands to a child PowerShell process through a Windows named pipe, so those
commands never appear in the process argument list or in `ConsoleHost_history.txt`.

Do **not** refactor this into a module, split it into multiple files, or add
a build pipeline unless the user explicitly requests it.  The single-file
structure is intentional.

---

## File inventory

| File | Role | Touch? |
|------|------|--------|
| `pscmd.ps1` | Reference POC — do not change without explicit instruction | Only on direct user request |
| `pscmd.Tests.ps1` | Pester 5 test suite | Edit freely to improve test coverage |
| `README.md` | Human-facing documentation | Keep in sync with any code changes |
| `AGENTS.md` | This file — AI agent guidance | Update when repo structure changes |

---

## Architecture overview

```
pscmd.ps1 (main body runs once at script entry)
│
├── Get-FunctionDefinition   - Serialises a loaded PS function to source text
├── Unprotect-SecureString   - SecureString → plain text (cross-edition)
│
├── Invoke-PSCmdServer       - Named pipe server (parent side)
│   └── Writes Base64-encoded UTF-8 command lines; closes after all sent
│
└── Invoke-PSCmdClient       - Named pipe client (child side, injected via -EncodedCommand)
    └── Reads Base64 lines; Invoke-Expression each one; exits when pipe closes
```

### Data flow

```
Parent                          Named pipe                    Child
──────                          ──────────                    ─────
Unique GUID pipe name ──────────────────────────────────────► pipe name in bootstrap

Bootstrap = {                                                 pwsh -EncodedCommand <bootstrap>
  fn:Unprotect-SecureString                                   │
  fn:Invoke-PSCmdClient                                       └─► Invoke-PSCmdClient <pipeName>
  Invoke-PSCmdClient <pipeName>                                     │
}                                                                   │ Connect(3000 ms timeout)
                                                                    │
Invoke-PSCmdServer <pipeName>                                       │
  WaitForConnection ◄─────────────────────────────────────────────-┘
  foreach command:                                            foreach ReadLine:
    Base64(UTF8(cmd)) ──────────────────────────────────────► UTF8(FromBase64) → Invoke-Expression
  Close ──────────────────────────────────────────────────► ReadLine = null → exit loop
```

---

## Named pipe protocol

- **Direction:** Out (server → client only)
- **Transmission mode:** `Byte`
- **Framing:** newline-delimited; one Base64-encoded command per line
- **Encoding:** command text → UTF-8 bytes → Base64 string
- **Max clients:** 1 (the server is one-shot)
- **Client timeout:** 3 000 ms (`Connect(3000)`)
- **Server blocks until:** the client connects (`WaitForConnection`)

The `-EncodedCommand` bootstrap uses **UTF-16 LE** (Unicode) because that is
what PowerShell's `-EncodedCommand` flag requires.  The pipe payload uses
**UTF-8** — keep these two encodings separate.

---

## Coding conventions

- **PowerShell edition compatibility:** all code must run on both
  `PowerShell 5.1` (Desktop) and `PowerShell 7+` (Core).  Where behaviour
  differs, branch on `$PSEdition`.  See `Unprotect-SecureString` for the
  canonical pattern.
- **No external dependencies:** do not import modules other than those that
  ship with PowerShell.
- **Dispose pattern:** every `Stream` / `Pipe` object is created in a
  `$x = $null` pre-initialisation block and disposed in a `finally` block.
  Follow this pattern in any new pipe-handling code.
- **No Write-Host in library functions:** `Invoke-PSCmdServer` and
  `Invoke-PSCmdClient` must remain side-effect-free except for the pipe I/O
  and the `Invoke-Expression` call in the client.
- **AutoFlush = $true** on the `StreamWriter` — do not remove this; without
  it the client may block indefinitely waiting for data.

---

## Test suite conventions (`pscmd.Tests.ps1`)

### Loading the POC functions

The test file uses the **PowerShell AST** to load only `FunctionDefinitionAst`
nodes from `pscmd.ps1`.  This avoids executing the script body (which would
launch a child process).  Never dot-source `pscmd.ps1` directly in tests.

```powershell
# Correct pattern — used in BeforeAll
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, ...)
$ast.FindAll({ ... -is [FunctionDefinitionAst] }, $false) | ForEach-Object {
    Invoke-Expression $_.Extent.Text
}
```

### Integration tests (named pipe round-trips)

- Use `Start-Job` for the **server** side so it can block on `WaitForConnection`
  concurrently with the client running in the test's own runspace.
- Pass function definitions into the job via `Script:Get-SerializedFunction`
  (defined in `BeforeAll`) — jobs run in a separate process and cannot see the
  current session's functions.
- Pre-generate a unique pipe name per test in `BeforeEach`.
- Clean up jobs in `AfterEach`.

### Side effects in integration tests

`Invoke-PSCmdClient` calls `Invoke-Expression`, which runs in the caller's
scope.  Integration test commands use `$global:` variables to signal results
back to the `It` block.  Always clean up (`Remove-Variable -Scope Global`)
after asserting.

### Test categories

| Describe block | What it tests |
|---|---|
| `AST loading` | All four functions are present; file has no parse errors |
| `Unprotect-SecureString` | Plain text, empty string, Unicode, pipeline input |
| `Get-FunctionDefinition` | Keyword presence, name, re-executability, round-trip |
| `Base64 / UTF-8 encoding` | Encoding round-trip correctness, newline-safety |
| `Named pipe integration` | Single command, multi-command ordering, no-server timeout, SecureString scenario |
| `Security properties` | GUID pipe name, max-clients=1, finite timeout, encoding choices |

---

## What to check before editing `pscmd.ps1`

1. Run `Invoke-Pester .\pscmd.Tests.ps1 -Output Detailed` — all tests should
   pass before and after your change.
2. Confirm the edited script still runs end-to-end:  
   `pwsh -File .\pscmd.ps1` (or `powershell -File .\pscmd.ps1` for 5.1)  
   A new window should appear, and after ~1 second the plain-text value
   `my-secret` should be printed in it.
3. Verify that `$EncodedCommand` (the `-EncodedCommand` argument) does **not**
   contain the string `my-secret` when decoded:  
   ```powershell
   [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($EncodedCommand))
   ```

---

## Common pitfalls

| Pitfall | Why it matters |
|---|---|
| Dot-sourcing `pscmd.ps1` in tests | Executes the main body; launches a real child process and hangs waiting for the pipe client |
| Using UTF-8 for `-EncodedCommand` | PowerShell only accepts UTF-16 LE for `-EncodedCommand`; UTF-8 will produce garbage or no output |
| Using UTF-16 LE on the pipe | The pipe protocol uses UTF-8; mixing them breaks the Base64 decode |
| Forgetting `$Writer.AutoFlush = $true` | The client's `ReadLine` blocks indefinitely; the test times out |
| Not disposing the pipe in `finally` | Pipe handle leak; the next test that reuses the name may fail to connect |
| Setting `maxNumberOfServerInstances > 1` | A race attacker on the same machine could connect to the pipe before the legitimate child |
| Using a static pipe name | Replay / hijack attacks across test runs; always use a GUID-based name |

---

## Extending the POC

If a user asks to extend the mechanism (e.g., add encryption, support multiple
command batches, or wrap it in a module), keep `pscmd.ps1` as the untouched
reference and create new files.  Document the relationship in README.md.

If a user asks to add Pester tests for new functionality, follow the existing
test conventions above: AST-load the function definitions, use `Start-Job` for
concurrent pipe tests, and clean up global side effects.
