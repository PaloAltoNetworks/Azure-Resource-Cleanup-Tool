# Azure Resource Cleanup Tool

![Azure](https://img.shields.io/badge/Azure-Cloud-blue?logo=microsoftazure)
![Bash](https://img.shields.io/badge/Bash-Script-green?logo=gnubash)
![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20WSL-lightgrey)
![Status](https://img.shields.io/badge/Status-Production%20Ready-success)

> 🚀 **Enterprise-grade Azure resource management with advanced discovery, batch operations, and comprehensive safety features**

## 🎯 Purpose

This comprehensive Bash script automates the discovery and safe deletion of Cortex Cloud Azure onboarding resources. It operates across all scopes—Subscription, Management Group, and Tenant—and identifies resources using name patterns and tags. The script includes advanced exclusion options and audit logging capabilities to ensure precise and secure resource management, saving significant time and manual effort.

## 🚀 Features

- **🔍 Multi-Scope Discovery**: Resources across Subscriptions, Management Groups, and Tenant
- **🏷️ Enhanced Tag Search**: Flexible tag-based discovery in three modes
- **🔍 Comprehensive Discovery**: Searches across all Azure scopes for resources matching name patterns
- **🛡️ Safety First**: Dry-run mode by default with explicit confirmation prompts
- **🛡️ Smart Exclusion**: Protect critical resources from accidental deletion
- **🗑️ Safe Deletion**: Dependency-aware deletion order to prevent conflicts
- **🎯 Multi-Resource Support**: Handles 15+ Azure resource types
- **⚡ Edge Case Handling**: Manages 'Unknown' role assignments, scope mismatches, and orphaned resources
- **⚡ Performance Optimizations**: Faster discovery across large environments
- **🔍 Advanced Resource Group Targeting**: Supports with/without wildcard-based resource group targeting with enhanced exclusion logic
- **⚙️ Service Type Exclusion Control**: Exclude entire categories of resources from discovery
- **🔄 Subscription Filtering Enhancements**: Skip specific subscriptions from discovery
- **🛡️ Enhanced Exclusion System** Automatically skips entire resource groups if they contain excluded resources and add new exclusions during confirmation prompts without restarting
- **📊 Audit Logging**: Comprehensive logging for compliance and troubleshooting

## 📋 Supported Resource Types

| Resource Type                     | Discovery | Deletion |
| --------------------------------- | --------- | -------- |
| Resources & Resource Groups       | ✅        | ✅       |
| Custom Roles & Role Assignments   | ✅        | ✅       |
| Policy Assignments & Definitions  | ✅        | ✅       |
| Policy Remediations               | ✅        | ✅       |
| Enterprise Applications           | ✅        | ✅       |
| Service Principals                | ✅        | ✅       |
| Managed Identities                | ✅        | ✅       |
| Diagnostic Settings (All levels)  | ✅        | ✅       |
| Management Group Deployments      | ✅        | ✅       |
| Management Group Role Assignments | ✅        | ✅       |

## 🛠️ Prerequisites

### System Requirements

- **Bash**: Version 4.0 or higher (5.0+ recommended)
- **Azure Cloud Shell-Bash** or (**Azure CLI**: Version 2.0 or higher)
- **jq**: JSON processor
- **column**: Table formatting utility (usually pre-installed)

### Installation Commands

#### Ubuntu/Debian

```bash
sudo apt-get update
sudo apt-get install -y jq bash
```

#### macOS

```bash
brew install jq
# Bash 5+ comes with modern macOS
```

#### RHEL/CentOS

```bash
sudo yum install -y jq

# Or for newer versions:
sudo dnf install -y jq
```

### Azure Permissions

#### Required Azure Roles

- **Owner** role is required on the Root Level

#### Azure Entra Permissions

- **Application Administrator** or **Global Administrator** (for Service Principals & Enterprise Apps)

## 📥 Installation

1. **Download the script**:

```bash
curl -fsslO https://raw.githubusercontent.com/PaloAltoNetworks/Azure-Resource-Cleanup-Tool/refs/heads/main/azure-cleanup-tool.sh && chmod +x azure-cleanup-tool.sh
```

2. **Verify prerequisites**:

```bash
# Check Bash version (If your Bash version is old, scroll down to "Troubleshooting" for installation instructions.)
bash --version
# Should show: GNU bash, version 4.x or 5.x

# Check Azure CLI (Skip this if using Azure Cloud Shell-Bash)
az version
# Should show Azure CLI version 2.x+

# Check jq
jq --version
# Should show: jq-1.6 or similar

# Check column utility on MAC (different methods for different systems)
echo "test1 test2" | column -t 2>/dev/null && echo "✅ column is working" || echo "❌ column not functioning"

# Verify Azure login
az account show
```

3. **Login to Azure**:

```bash
az login

# If using specific tenant:
az login --tenant <your-tenant-id>
```

## 🎯 Usage

### **Example:**

```bash
  bash azure-cleanup-tool.sh <resource-name> [--dry-run] [--delete] [--subscription SUB_ID] [--exclude RESOURCE_NAMES] [--log-file FILE] [--append-log] [--help]
  bash azure-cleanup-tool.sh <pattern1,pattern2,...> [--dry-run] [--delete] [--subscription SUB_ID] [--exclude RESOURCE_NAMES] [--log-file FILE] [--append-log]
  bash azure-cleanup-tool.sh --tag KEY[=VALUE] [--dry-run] [--delete] [--subscription SUB_ID] [--exclude RESOURCE_NAMES] [--log-file FILE] [--append-log] [--help]
```

| Option                   | Purpose                                                               | Example / Behavior                                                                                                                                |
| ------------------------ | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `<resource-name>`        | Search pattern (case-insensitive). Supports comma-separated patterns. | `"cortex,ADSConnector,ADSGallery,ADSOutpost,monitor"` matches ANY listed pattern                                                                  |
| `--dry-run`              | Preview resources that would be deleted (default mode).               | Safe, non-destructive execution                                                                                                                   |
| `--delete`               | Perform actual deletion of matched resources.                         | Executes real cleanup (disables dry-run)                                                                                                          |
| `--tag KEY[=VALUE]`      | Filter by tag key, exact key-value pair, or value.                    | `env` - matches tag key, `env=prod` - matches exact key-value pair, `prod` - matches tag value                                                    |
| `--resource-group`       | Limit discovery/deletion to specific resource group(s).               | Comma-separated RG names                                                                                                                          |
| `--subscription`         | Restrict search to specific subscriptions.                           | Targets one/multiple Azure subscription                                                                                                                    |
| `--exclude-subscription` | Exclude one or more subscriptions from scanning.                      | Comma-separated subscription IDs                                                                                                                  |
| `--exclude`              | Skip specific resource names (exact match, case-sensitive).           | Protect critical resources                                                                                                                        |
| `--exclude-service`      | Skip scanning specific Azure service categories entirely.             | Available types: `resources`, `resourcegroups`, `policies`, `roles`, `diagnostics`, `serviceprincipals`, `managementgroups`, `subscriptions` etc. |
| `--log-file FILE`        | Write detailed audit logs to a specified output file.                 | Supports compliance & traceability                                                                                                                |
| `--append-log`           | Append logs instead of overwriting existing file.                     | Preserve historical cleanup logs                                                                                                                  |
| `--help`                 | Display CLI help message and exit.                                    | Show usage reference                                                                                                                              |

**📌 Command Scenarios**

| Scenario                                      | Example Command                                                                                                              | Outcome                                                          |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Preview cleanup by single name                | `bash azure-cleanup-tool.sh "cortex"`                                                                                        | Lists resources that match the name pattern (dry-run by default) |
| Preview cleanup with explicit dry-run         | `bash azure-cleanup-tool.sh "cortex" --dry-run`                                                                              | Shows what would be deleted without making changes               |
| Target a specific subscription                | `bash azure-cleanup-tool.sh "cortex" --subscription "12345-67890" --dry-run`                                                   | Limits scanning to one Azure subscription                        |
| Exclude specific subscription(s)              | `bash azure-cleanup-tool.sh "cortex" --exclude-subscription "1111-2222,3333-4444" --dry-run`                                   | Skips scanning excluded subscriptions                            |
| Limit cleanup to specific resource group(s)   | `bash azure-cleanup-tool.sh "cortex" --resource-group "rg-prod,rg-dev" --dry-run`                                            | Restricts discovery and deletion to selected RGs                 |
| Delete resources by name                      | `bash azure-cleanup-tool.sh "cortex" --delete`                                                                               | Permanently deletes matching resources                           |
| Multi-pattern name search (ANY match)         | `bash azure-cleanup-tool.sh "cortex,ADSConnector,ADSGallery,ADSOutpost"`                                                     | Matches any of the provided patterns                             |
| Multi-pattern dry-run                         | `bash azure-cleanup-tool.sh "cortex,ADSConnector,ADSGallery,ADSOutpost" --dry-run`                                           | Previews matched resources                                       |
| Delete resources using multiple patterns      | `bash azure-cleanup-tool.sh "cortex,ADSConnector,ADSGallery,ADSOutpost" --delete`                                            | Deletes resources matching any pattern                           |
| Filter by tag key                             | `bash azure-cleanup-tool.sh --tag "managed_by" --dry-run`                                                                    | Finds resources with the given tag key                           |
| Filter by tag key-value                       | `bash azure-cleanup-tool.sh --tag "managed_by=paloaltonetworks" --dry-run`                                                   | Finds resources with exact tag match                             |
| Filter by tag value only                      | `bash azure-cleanup-tool.sh --tag "paloaltonetworks" --dry-run`                                                              | Finds resources matching tag value                               |
| Delete tagged resources                       | `bash azure-cleanup-tool.sh --tag "paloaltonetworks" --delete`                                                               | Deletes resources based on tag filters                           |
| Exclude specific resource names (exact match) | `bash azure-cleanup-tool.sh "cortex,ADSConnector,ADSGallery,ADSOutpost" --dry-run --exclude "cortex-scan-platform"`            | Prevents deletion of protected resources                         |
| Exclude multiple resource names               | `bash azure-cleanup-tool.sh "cortex,ADSConnector,ADSGallery,ADSOutpost" --dry-run --exclude "cortex-scan-platform,production"` | Protects multiple critical resources                             |
| Exclude Azure service categories              | `bash azure-cleanup-tool.sh "cortex" --exclude-service "resources,resourcegroups,roles"`                                       | Skips scanning selected service types                            |
| Exclude governance & identity services        | `bash azure-cleanup-tool.sh "cortex" --exclude-service "serviceprincipals"`                                                    | Avoids scanning governance-related resources                     |
| Write audit logs to a file                    | `bash azure-cleanup-tool.sh "cortex" --dry-run --log-file "audit.log"`                                                       | Saves cleanup activity for compliance                            |
| Append logs instead of overwriting            | `bash azure-cleanup-tool.sh "cortex" --dry-run --log-file "audit.log" --append-log`                                          | Preserves historical cleanup records                             |
| Display CLI help                              | `bash azure-cleanup-tool.sh --help`                                                                                          | Shows help and usage documentation                               |

### **🚀 Advanced Example — All Features Combined**

```bash
# Advanced pattern matching with all features
bash azure-cleanup-tool.sh "cortex,ADSConnector,ADSGallery,ADSOutpost" --dry-run --resource-group "cortex-onboarding-*,cortex-m*" --exclude-service "serviceprincipals"  --exclude "cortex-scan-platform,production" --log-file "audit.log"
```

## 🔧 How It Works

### Discovery Process

1. **Subscription Enumeration**: Discovers all accessible subscriptions
2. **Multi-Scope Search**: Searches resources at Resource, Subscription, Management Group, and Tenant levels
3. **Pattern Matching**: Case-insensitive search across all resource types
4. **Dependency Mapping**: Identifies relationships between resources

### Deletion Order

The script deletes resources in dependency order to prevent failures:

1. 🎯 Management Group Deployments
2. 🔧 Policy Remediations
3. 📋 Policy Assignments
4. 👥 Role Assignments
5. 🏷️ Custom Roles
6. 📊 Diagnostic Settings
7. 🔑 Enterprise Applications
8. ⚙️ Service Principals
9. 🗂️ Regular Resources
10. 📦 Resource Groups (last)

## 🛡️ Safety Features

- **Dry-run by default**: No accidental deletions
- **Explicit confirmation**: Required for destructive operations
- **Exclusion Patterns**: Protect critical resources from accidental deletion
- **Color-coded output**: Easy to understand status
- **Formatted tables**: Clear resource summaries
- **Error handling**: Comprehensive error messages with guidance
- **Retry logic**: Automatic retries for transient failures

## 📊 Output Example

```bash
🔐 Azure Resource Cleanup Tool
✅ Azure login confirmed
ℹ️  Mode: DRY-RUN

ℹ️  Searching for resources matching ANY of these patterns:
ℹ️    • cortex
ℹ️    • ads
--------------------------------------------------------
  → Found Resource: cortex-storage (Microsoft.Storage/storageAccounts)
  → Found Resource: ads-processor (Microsoft.Web/sites)
  → Found Resource Group: cortex-dev-rg
  → Found Custom Role: cortex-operator (a1b2c3d4-e5f6-7890-abcd-ef1234567890)

ℹ️  Applying exclude patterns: Cortex-Cloud-SSO
ℹ️  Excluded 1 resource(s) from deletion
⚠️  Excluded 1 resource(s) matching patterns: Cortex-Cloud-SSO
=========================================================
                      Summary Table
=========================================================
✅ Found 4 matching resource(s) for deletion
⚠️  Excluded 1 resource(s)

----------------------- ---------------------------- ------------------------- ----------------------------------------
NAME                    TYPE                          SCOPE                     DETAILS
----------------------- ---------------------------- ------------------------- ----------------------------------------
cortex-storage          Microsoft.Storage/storageAccounts Subscription A        tags: env=test
ads-processor           Microsoft.Web/sites           Subscription B
cortex-dev-rg           ResourceGroup                 Subscription A
cortex-operator         CustomRole                    Tenant                    Scopes: 1

ℹ️  Dry-run completed. No resources were deleted.
ℹ️  Use --delete to actually delete these resources.
```

## 📊 Logging & Auditing

Output Example:

```bash
==================================================================================
AZURE RESOURCE CLEANUP AUDIT LOG
==================================================================================
Execution Start  : 2024-01-15 14:30:25 UTC
User             : naveed@hostname
Azure User       : naveed.khan@company.com
Tenant ID        : 12345678-1234-1234-1234-123456789012
Subscription     : All enabled subscriptions
Mode             : DRY-RUN
Log Mode         : OVERWRITE
Search Type      : Tag Filter
Patterns         : paloaltonetworks
Exclude Patterns : Cortex-Cloud-SSO,cortex-scan-platform-1001222230132-prod-us
Log File         : audit.log
==================================================================================
==================================================================================

[2025-12-08 14:27:23] AUDIT: Audit logging enabled: debug1.log (APPEND mode)
[2025-12-08 14:27:23] INFO: Logging initialized
[2025-12-08 14:27:23] INFO: Mode: DELETE
[2025-12-08 14:27:23] INFO: Log Mode: APPEND
[2025-12-08 14:27:23] INFO: Searching for resources with tag: paloaltonetworks
[2025-12-08 14:27:23] INFO: Exclude patterns/resources:
[2025-12-08 14:27:23] INFO:   • Cortex-Cloud-SSO
[2025-12-08 14:27:23] INFO:   • cortex-scan-platform-1001222230132-prod-us
[2025-12-08 14:27:23] INFO: --------------------------------------------------------
[2025-12-08 14:27:23] INFO: Current subscription ID: 12345678-1234-1234-1234-123456789012
[2025-12-08 14:27:23] INFO: Getting all enabled subscriptions...
[2025-12-08 14:27:24] INFO: Searching for resources with tag key or value: paloaltonetworks
[2025-12-08 14:27:24] INFO: Getting all enabled subscriptions...
[2025-12-08 14:27:25] INFO: Searching tagged resources in subscription:
[2025-12-08 14:27:25] DEBUG: Searching for tagged resource groups in subscription:
[2025-12-08 14:27:26] INFO: Searching tagged resources in subscription: Azure subscription 1
[2025-12-08 14:27:27] DEBUG: Searching for tagged resource groups in subscription: Azure subscription 1
[2025-12-08 14:27:28] INFO: Searching tagged resources in subscription: Subscription 2
[2025-12-08 14:27:29] DEBUG: Searching for tagged resource groups in subscription: Subscription 2
[2025-12-08 14:27:30] INFO: Searching tagged resources in subscription: Azure subscription 1
[2025-12-08 14:27:32] DEBUG: Searching for tagged resource groups in subscription: Azure subscription 1
[2025-12-08 14:27:33] INFO: Searching tagged resources in subscription: Subscription 2
[2025-12-08 14:27:33] DEBUG: Searching for tagged resource groups in subscription: Subscription 2
[2025-12-08 14:27:35] INFO: Switched back to original subscription: 7144b1a5-f22f-4e30-a29a-93727748d60e
[2025-12-08 14:27:35] DEBUG: Skipping management group role assignments discovery in pure tag mode
[2025-12-08 14:27:35] DEBUG: Skipping management group deployments discovery in pure tag mode
[2025-12-08 14:27:35] DEBUG: Skipping policy assignments discovery in pure tag mode
[2025-12-08 14:27:35] DEBUG: Skipping policy remediations discovery in pure tag mode
[2025-12-08 14:27:35] DEBUG: Skipping diagnostic settings discovery in pure tag mode
[2025-12-08 14:27:35] DEBUG: Skipping directory diagnostic settings discovery in pure tag mode
[2025-12-08 14:27:35] DEBUG: Skipping custom roles discovery in tag mode
[2025-12-08 14:27:35] DEBUG: Skipping role assignments discovery in tag mode
[2025-12-08 14:27:35] DEBUG: Skipping service principals discovery in tag mode
[2025-12-08 14:27:35] INFO: Discovery phase completed
[2025-12-08 14:27:35] INFO: Applying exclude patterns: Cortex-Cloud-SSO,cortex-scan-platform-1001222230132-prod-us
[2025-12-08 14:27:35] INFO: No resources matched exclude patterns
[2025-12-08 14:27:35] SUCCESS: No matching resources found

==================================================================================
EXECUTION SUMMARY
==================================================================================
Start Time      : 2025-12-08 14:27:22 CST
End Time        : 2025-12-08 14:27:35 CST
Mode            : DELETE
Log Mode        : APPEND
Resources Found     : 0
Resources Deleted   : 0
Resources Excluded  : 0
Resource Groups Skipped : 0 (contained excluded resources)
Resources Failed      : 0
==================================================================================

==================================================================================
END OF EXECUTION
==================================================================================

```

## 🐛 Troubleshooting

### Common Issues

**"Either name pattern or tag filter is required"**

```bash
# ❌ Wrong - missing search criteria
bash azure-cleanup-tool.sh --dry-run

# ✅ Correct - provide search criteria
bash azure-cleanup-tool.sh "cortex" --dry-run
bash azure-cleanup-tool.sh --tag "environment=dev" --dry-run
```

**"Subscription not found"**

```bash
# Verify subscription access
az account list --output table
az account set --subscription "Your-Subscription-Name"
```

**"Insufficient permissions"**

```bash
# Check current permissions
az role assignment list --assignee $(az account show --query user.name -o tsv)
```

**Missing jq**:

```bash
# Ubuntu/Debian
sudo apt-get install jq

# macOS
brew install jq

# Windows (WSL)
choco install jq
```

**Missing column**:

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y bsdmainutils

# macOS
# column should be pre-installed, but if missing:
brew install util-linux

# RHEL/CentOS
sudo yum install -y util-linux-ng
```

**Bash Version Too Old**:

```bash
# macOS
brew install bash
echo '/usr/local/bin/bash' >> /etc/shells
```

### Debug Mode

For detailed debugging, run with:

```bash
bash -x azure-cleanup-tool.sh "<resource-name>" --dry-run
```

## 🤝 Contributing

We welcome contributions! Please feel free to submit issues, feature requests, or pull requests.

## ⚠️ Disclaimer

This tool performs destructive operations. Always:

1. Run with `--dry-run` first
2. Review the discovered resources
3. Ensure you have appropriate backups
4. Test in non-production environments first

The authors are not responsible for any data loss or unintended deletions.

---

**Happy Cleaning! 🧹**
