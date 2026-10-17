# 🗑️ FORCE DELETE PRO

An advanced Windows file and folder removal utility built with **Windows Batch, PowerShell, and native Windows utilities**. FORCE DELETE PRO diagnoses why deletion fails—checking attributes, ownership, permissions, running processes, and Windows services—instead of repeatedly running the same failing command.

The project combines a console-based interface, detailed diagnostics, optional permission repair, verified service-stop workflows, controlled deletion retries, and timestamped logs in one Windows utility.

> **Important:** File and folder deletion is permanent. Always verify the target path before confirming deletion. FORCE DELETE PRO does not guarantee removal when Windows security policies, kernel drivers, antivirus software, or unresolved file locks prevent access.

---

## 📑 Table of Contents

- [Features](#-features)
- [Architecture Overview](#-architecture-overview)
- [Tech Stack](#-tech-stack)
- [Project Structure](#-project-structure)
- [How It Works](#-how-it-works)
- [Console Interface](#-console-interface)
- [Diagnostics and Permission Repair](#-diagnostics-and-permission-repair)
- [Windows Service Management](#-windows-service-management)
- [Installation](#-installation)
- [Usage](#-usage)
- [Logging and Reports](#-logging-and-reports)
- [Build and Testing](#-build-and-testing)
- [Troubleshooting](#-troubleshooting)
- [Limitations](#-limitations)
- [Privacy and Security](#-privacy-and-security)
- [Future Improvements](#-future-improvements)
- [License](#-license)
- [Author](#-author)

---

## ✨ Features

### 🗑️ Advanced File and Folder Deletion

- Removes files and folders that may resist ordinary deletion.
- Handles hidden, system, and read-only attributes.
- Supports paths containing spaces and optional quotation marks.
- Uses literal paths and extended-length path handling.
- Processes files before folders and removes directories deepest-first.
- Removes links without following their targets.
- Uses bounded retries for transient errors instead of endlessly repeating failed operations.
- Reports the final result as `SUCCESS`, `PARTIAL`, `CANCELLED`, or `FAILED`.

### 🔍 Intelligent Diagnostics

- Examines file attributes, ownership, and access-control permissions.
- Checks parent-directory permissions and explicit Deny entries.
- Identifies potential permission and file-lock problems.
- Inspects matching Windows services and their executable paths.
- Uses the Windows Restart Manager API to help identify processes holding files.
- Provides plain-English diagnostic categories such as `CONFIRMED`, `POSSIBLE`, and `INFO`.
- Reports unresolved locks and remaining files instead of falsely claiming success.

### 🔐 Controlled Permission Repair

- Offers a separate permission-repair workflow.
- Uses Windows `takeown.exe`, `icacls.exe`, and `attrib.exe`.
- Captures exit codes and verifies the resulting state.
- Requires explicit confirmation using `REPAIR`.
- Does not automatically remove explicit Deny permission entries.

### ⚙️ Windows Service Management

- Identifies services that reference the selected target.
- Displays relevant service details, including name, state, startup type, and executable path.
- Requests separate confirmation using `STOP-<SERVICENAME>`.
- Waits for the service to stop and verifies its state.
- Avoids stopping unrelated services, protected core Windows services, or services with running dependents.
- Never deletes a Windows service registration automatically.

### 📋 Detailed Logging

- Creates timestamped operation logs.
- Records diagnostic results, service information, and permission-repair results.
- Logs deleted and failed items, error codes, and remaining files.
- Records the final operation status.
- Provides a menu option to open the log directory.

### 🛡️ Safety Controls

- Requires the exact confirmation word `DELETE` before deletion.
- Allows cancellation at confirmation prompts.
- Refuses protected targets such as drive roots and critical Windows directories.
- Avoids disabling Windows Defender, antivirus software, or User Account Control.
- Limits deletion retries and rounds.
- Restricts operations to targets that pass the utility's safety checks.

---

## 🏗️ Architecture Overview

FORCE DELETE PRO consists of two primary components:

| Component | Technology | Responsibility |
|---|---|---|
| Batch launcher | Windows Batch (`.bat`) | Starts the utility, handles the console workflow, and launches PowerShell. |
| Deletion engine | Windows PowerShell 5.1 | Performs diagnostics, optional repair, service checks, deletion, verification, and logging. |

### Architecture diagram

```text
             ┌──────────────────────────┐
             │        User              │
             │ Selects Target Path      │
             └────────────┬─────────────┘
                          │
                          ▼
             ┌──────────────────────────┐
             │   FORCE DELETE PRO       │
             │   Batch Launcher         │
             │   FORCE_DELETE.bat       │
             └────────────┬─────────────┘
                          │
                          ▼
             ┌──────────────────────────┐
             │   PowerShell Engine      │
             │   ForceDelete.ps1        │
             └────────────┬─────────────┘
                          │
           ┌──────────────┼──────────────┐
           ▼              ▼              ▼
    ┌────────────┐ ┌────────────┐ ┌────────────┐
    │ Diagnostics│ │ Service and│ │ Permission │
    │ and Locks  │ │ Lock Checks│ │ Repair     │
    └─────┬──────┘ └─────┬──────┘ └─────┬──────┘
          └──────────────┼──────────────┘
                         ▼
             ┌──────────────────────────┐
             │ Confirmed Deletion       │
             │ and File Verification    │
             └────────────┬─────────────┘
                          ▼
             ┌──────────────────────────┐
             │ Timestamped Logs         │
             │ Final Operation Status   │
             └──────────────────────────┘
```

The batch launcher provides the entry point, while PowerShell performs the main diagnostic and deletion operations. The utility checks the result rather than treating a successful command exit code alone as proof that the target was completely removed.

---

## 🧰 Tech Stack

### Windows Automation

- **Windows Batch** — launcher and console workflow.
- **Windows PowerShell 5.1** — diagnostics, file operations, service checks, and logging.
- **Windows `takeown.exe`** — ownership repair.
- **Windows `icacls.exe`** — access-control inspection and repair.
- **Windows `attrib.exe`** — file attribute management.
- **Windows Restart Manager API** — process and file-lock identification.

### Platform and Development

- Windows 10 / Windows 11.
- Windows Server 2016 or newer.
- Windows PowerShell 5.1.
- Administrator privileges for operations that require elevated access.

**No Python, Node.js, or third-party runtime is required.**

---

## 📁 Project Structure

```text
FORCE_DELETE_PRO/
│
├── FORCE_DELETE.bat
├── ForceDelete.ps1
├── README.md
├── CHANGELOG.md
├── LICENSE
│
└── logs/
    └── .gitkeep
```

The `logs/` directory is a repository placeholder. Runtime logs are normally written to the user's local application-data directory.

*The exact contents may differ between releases.*

---

## ⚙️ How It Works

### 1. Target Validation

The utility accepts a file or folder path and checks whether the target exists.

It validates the target against safety restrictions, handles paths containing spaces, and gathers basic information about the selected item before proceeding.

Protected locations—including drive roots, critical Windows directories, and other restricted targets—are refused.

### 2. Read-Only Diagnostics

Before attempting deletion, the utility investigates potential causes of failure, including:

- Hidden, system, and read-only attributes.
- Ownership and access-control permissions.
- Parent-directory access.
- Explicit Deny entries.
- File locks and running processes.
- Matching Windows services.
- Relevant volume and path limitations.

The diagnostics help distinguish likely causes rather than assuming every `Access Denied` error has the same explanation.

### 3. Optional Permission Repair

When appropriate, the utility offers a separate repair operation.

After the user confirms `REPAIR`, it can use Windows ownership, permission, and attribute utilities. The result is checked and reported.

Permission repair is not guaranteed to solve a deletion failure. An active process, security policy, or another restriction may still prevent removal.

### 4. Service and Process Checks

If a Windows service references the target, the utility displays the matching information and requests a separate confirmation before attempting to stop an eligible service.

The expected confirmation format is:

```text
STOP-<SERVICENAME>
```

The utility verifies whether the service actually stopped. It does not assume that a confirmation or command invocation means the service is no longer running.

Process-lock identification is performed using Windows Restart Manager. Some handles and system-level locks may not be identifiable.

### 5. Controlled Deletion

After the target is diagnosed and the user confirms `DELETE`, the engine attempts deletion using literal paths.

The deletion workflow handles files first, then directories from deepest to shallowest. Retries are bounded and intended for transient errors rather than permanent permission failures.

### 6. Verification and Final Status

The utility checks the remaining target items and records the outcome.

- `SUCCESS` — the target was removed successfully.
- `PARTIAL` — some items could not be removed.
- `CANCELLED` — the operation was cancelled.
- `FAILED` — the operation could not complete successfully.

The final report and log provide information about failures that still need attention.

---

## 🖥️ Console Interface

FORCE DELETE PRO is designed around a practical Windows console interface.

It provides:

- A console banner and menu.
- Target-path input.
- Diagnostic summaries.
- Separate confirmation prompts.
- Progress and deletion results.
- Plain-English failure information.
- A final status and log-file location.

### Confirmation workflow

The utility keeps potentially destructive actions separate.

| Action | Confirmation |
|---|---|
| Delete the selected target | `DELETE` |
| Stop an identified service | `STOP-<SERVICENAME>` |
| Repair ownership or permissions | `REPAIR` |
| Cancel an operation | Use the cancellation option shown by the utility |

Typing `DELETE` at the service-stop prompt is not a valid service-stop confirmation.

---

## 🔍 Diagnostics and Permission Repair

A failed deletion can have multiple causes. FORCE DELETE PRO attempts to identify relevant evidence before changing permissions or deleting anything.

| Diagnostic category | Possible meaning |
|---|---|
| `AccessDenied` | Permissions, security restrictions, or an access-denied lock condition. |
| `InUse` | Another process may be holding the file open. |
| `DirectoryNotEmpty` | A child item could not be deleted or the directory is still being modified. |
| `ReadOnlyVolume` | The storage volume may be write-protected. |
| `PathTooLong` | A path-length limitation may be involved. |
| `InvalidPath` | The supplied path is invalid. |
| `Unsupported` | The operation or target is not supported. |

These categories are diagnostic guidance, not a guarantee that every underlying cause can be detected.

**Important:** Do not remove permission Deny entries or change ownership of system files just to force a deletion. Only repair permissions on files and folders you own or are authorized to administer.

---

## ⚙️ Windows Service Management

Windows services may keep executable files or DLLs open while they are running. In those cases, changing file permissions alone may not resolve the problem.

FORCE DELETE PRO checks for services that reference the target and offers an explicit stop operation when permitted.

### Service-management safeguards

- Only identified matching services are considered.
- A separate confirmation is required.
- The utility waits for and verifies the stopped state.
- Services with running dependents and protected services are not stopped.
- Unrelated processes are not killed.
- Service registrations are not removed automatically.

If a service refuses to stop, inspect its dependencies and configuration through Windows Services or `sc.exe`, and use the application's supported uninstaller where possible.

---

## 🚀 Installation

### Prerequisites

- Windows 10, Windows 11, or Windows Server 2016+.
- Windows PowerShell 5.1.
- Administrator privileges for elevated operations such as service control and ownership repair.

### Quick start

1. Clone the repository:

   ```bash
   git clone https://github.com/rsamwilson2323-cloud/FORCE_DELETE_PRO.git
   ```

2. Open the project directory:

   ```bash
   cd FORCE_DELETE_PRO
   ```

3. Run `FORCE_DELETE.bat`.

4. If required, approve the User Account Control prompt to relaunch with administrator privileges.

5. Follow the console instructions and select the target you want to inspect.

6. Review the diagnostics carefully before confirming any operation.

### Running from a different directory

You can pass a target path as an argument:

```bat
FORCE_DELETE.bat "D:\Projects\Example Folder"
```

Keep quotation marks around paths containing spaces. Use a local drive rather than a network UNC path.

If Windows marks downloaded files as blocked, review the file's Properties and unblock it only if you trust the source.

---

## 🗑️ Usage

### Example: Delete a stubborn application folder

Suppose you want to remove a folder containing application DLLs and a Windows service.

1. Start FORCE DELETE PRO.
2. Enter the full target path.
3. Review the diagnostic results and identified services.
4. Confirm the deletion operation by typing `DELETE` when requested.
5. If the utility identifies an eligible matching service, decide whether stopping it is appropriate.
6. At the service prompt, enter the exact confirmation, such as `STOP-ADBLOCKER`, only if you want to stop that service.
7. If permission repair is offered, use `REPAIR` only after reviewing the consequences.
8. Review the deletion results and final status.

Example path:

```text
D:\Projects\ExampleApplication
```

Example service confirmation:

```text
STOP-ADBLOCKER
```

The example service name is illustrative. Use the exact service name reported by the utility.

**Never confirm deletion until you have verified that the target path points to the intended files or folder.**

---

## 📋 Logging and Reports

FORCE DELETE PRO records operation details to timestamped log files.

### Default log location

```text
%LOCALAPPDATA%\ForceDeletePro\logs\
```

Log filenames use a timestamped format:

```text
ForceDelete_YYYYMMDD_HHMMSS.log
```

The utility can fall back to `%TEMP%` and supports a custom log directory through its logging configuration.

### Information recorded

- Operation start and completion.
- Selected target and administrator status.
- Diagnostic findings.
- Matching service details and stop results.
- Permission-repair results.
- Deleted and failed items.
- Relevant error codes.
- Remaining items.
- Final operation status.

Logs are intended to help troubleshoot failures and understand what happened during each operation.

---

## 🧪 Build and Testing

FORCE DELETE PRO is a Windows Batch and PowerShell utility, so it does not require a conventional compiled build.

### Validate the PowerShell syntax

Run the following command from the project directory:

```powershell
powershell -NoProfile -Command "$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\ForceDelete.ps1),[ref]$t,[ref]$e);if($e){$e}else{'Syntax OK'}"
```

A successful syntax check should report:

```text
Syntax OK
```

### Create disposable test fixtures

Run the test-fixture option in an elevated PowerShell session if required:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ForceDelete.ps1 -CreateFixtures
```

The script is designed to create disposable test data under:

```text
%TEMP%\ForceDelete Pro Test\
```

The fixtures cover scenarios such as normal deletion, nested folders, hidden and read-only items, paths with spaces, locked files, service matching, and access-denied conditions.

### Recommended test scenarios

| # | Scenario | Expected result |
|---|---|---|
| 1 | Normal file or folder | Successful deletion. |
| 2 | Nested directories | Children are handled before parent directories. |
| 3 | Hidden or read-only items | Attributes are diagnosed and handled when permitted. |
| 4 | Path containing spaces | The path is accepted correctly. |
| 5 | Invalid path | A clear error is reported without deleting another target. |
| 6 | User cancellation | The operation is reported as `CANCELLED`. |
| 7 | Access denied | Diagnostics and repair options are reported honestly. |
| 8 | File held open | The lock is identified when possible; unresolved items are reported. |
| 9 | Matching service | Service details and separate confirmation are shown. |
| 10 | Service refuses to stop | The utility reports the unresolved condition. |
| 11 | Partial deletion | Remaining items are listed and the result is `PARTIAL` when appropriate. |
| 12 | Logging | The operation details and final status are recorded. |
| 13 | Protected path | The target is refused. |

**Testing warning:** Use only disposable test data. Do not test destructive operations against Windows directories, drive roots, personal folders, or files needed by running applications. Review and clean up test services separately after service-testing scenarios.

---

## 🛠️ Troubleshooting

### Access denied

- Review the diagnostic output for ownership and ACL problems.
- Check whether a process or service is using the file.
- Consider the separate `REPAIR` option only when you are authorized to change the target's permissions.
- Check Windows Security's Protection history if security software may be blocking the operation.
- Do not assume that taking ownership will resolve every access-denied error.

### Files remain in use

- Close the application using the target.
- Check the matching services reported by the utility.
- Stop an identified eligible service only after reviewing the information and confirming the action.
- Use Microsoft Sysinternals Process Explorer to inspect open handles when necessary.

Microsoft Sysinternals: https://learn.microsoft.com/sysinternals/

### The service does not stop

- Verify its state in Windows Services.
- Inspect its dependencies and configuration.
- Check whether the application has a supported uninstall or shutdown procedure.
- Review the operation log for the reported failure.
- Do not delete service registrations or kill unrelated processes as a workaround.

### The directory is not empty

- Review the failed child items listed by the utility.
- Resolve any outstanding file locks or permission problems.
- Retry only after addressing the reported cause.

### Long paths or unsupported targets

- Verify the complete target path.
- Confirm that the filesystem and Windows configuration support the operation.
- Remember that ownership and permission utilities may still encounter long-path limitations.

### Deletion reports partial success

- Read the log to identify which items remain.
- Investigate the specific error for each item.
- Resolve the underlying problem and retry on the intended target.

---

## ⚠️ Limitations

- Deletion cannot be guaranteed for every file or folder.
- Kernel drivers, security products, and system-level restrictions may prevent removal.
- Some open handles cannot be identified through Restart Manager.
- A service may restart itself because of its recovery configuration.
- Ownership and ACL diagnostics are an approximation of Windows access checks.
- Ownership or permission repair may not resolve file locks or security-policy restrictions.
- `takeown` and `icacls` may encounter path-length limitations.
- Cloud placeholder folders and reparse points may have special behavior.
- Only a limited number of remaining items may be displayed in the console; the log can contain more details.
- Live Windows testing is necessary to validate behavior on the target system.

---

## 🔒 Privacy and Security

- The utility is designed to operate locally on Windows.
- It does not require a Python or Node.js runtime.
- It does not intentionally collect passwords or authentication tokens.
- It does not disable Windows Defender, antivirus software, or UAC.
- It does not automatically kill processes or remove Windows service registrations.
- Diagnostic logs may contain file paths, service names, and system-operation details. Review logs before sharing them publicly.
- Administrator privileges should be used only when required.

Review the source code before running the utility with elevated privileges.

**Use FORCE DELETE PRO only on files and folders you own or are authorized to administer.**

---

## 🗺️ Future Improvements

Potential development directions include:

- Improved identification of locked files and processes.
- More detailed diagnostic summaries.
- Expanded testing on supported Windows versions.
- Better reporting for permission and service-control failures.
- Enhanced long-path handling.
- More detailed operation summaries and log viewing.
- Additional disposable test fixtures.
- Improved recovery guidance for unresolved deletion failures.

---

## 📄 License

This project is released under the **MIT License**. See the [`LICENSE`](LICENSE) file for the complete license terms.

---

## 👨‍💻 Author

**R. Sam Wilson**

GitHub: https://github.com/rsamwilson2323-cloud

Repository: https://github.com/rsamwilson2323-cloud/FORCE_DELETE_PRO

---

*Built as a Windows utility focused on diagnosing file-deletion failures, handling permissions responsibly, and providing controlled, verifiable removal workflows.*
