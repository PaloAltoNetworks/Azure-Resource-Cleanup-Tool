#!/usr/bin/env bash

#====================================================================================================
# Azure Resource Cleanup Tool: Comprehensive discovery and deletion across all Azure scopes
# 
# 🎯 PURPOSE: Comprehensive Bash script automates the discovery and safe deletion of Cortex Cloud Azure onboarding resources.
# 
# 🔍 DISCOVERS: Resources, Resource Groups, Policies, Enterprise Apps/Service Principals,
#               Custom Roles, Role Assignments, Diagnostic Settings, Managed Identities
# 
# 🛡️ FEATURES: Dependency-aware deletion, dry-run mode, scope mismatch handling,
#               case-insensitive pattern matching, cross-scope coverage, exclude patterns,
#               multi-keyword search, audit logging, append log mode, exclude-service filtering
# 
# ⚡ HANDLES: 'Unknown' role assignments, orphaned resources, single/multi-subscription cleanup
#====================================================================================================

# Exit on critical errors but allow graceful handling for individual resource operations
set -o pipefail
trap 'echo "❌ Script interrupted."; exit 1' INT

# --- Style Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE=$'\033[0;35m'
ORANGE=$'\033[0;33m'
NC=$'\033[0m' # No Color

# --- Service Type Mappings ---
declare -A SERVICE_TYPE_MAP=(
    ["resources"]="regular"  # Regular Azure resources
    ["resourcegroups"]="ResourceGroup"
    ["policies"]="PolicyAssignment,PolicyRemediation"
    ["roles"]="CustomRole,RoleAssignment,UnknownRoleAssignment"
    ["diagnostics"]="DiagnosticSetting,SubscriptionDiagnosticSetting,DirectoryDiagnosticSetting"
    ["serviceprincipals"]="EnterpriseApplication"
    ["managementgroups"]="ManagementGroupRoleAssignment,ManagementGroupDeployment"
    ["subscriptions"]="SubscriptionRoleAssignment"
    ["all"]="ALL"
)

# --- Service Type Display Names ---
declare -A SERVICE_DISPLAY_NAMES=(
    ["resources"]="Regular Resources"
    ["resourcegroups"]="Resource Groups"
    ["policies"]="Policy Assignments & Remediations"
    ["roles"]="Custom Roles & Role Assignments"
    ["diagnostics"]="Diagnostic Settings"
    ["serviceprincipals"]="Service Principals/Enterprise Apps"
    ["managementgroups"]="Management Group Resources"
    ["subscriptions"]="Subscription Role Assignments"
    ["all"]="All Resource Types"
)

# --- Service Type Discovery Functions Mapping ---
declare -A SERVICE_DISCOVERY_FUNCTIONS=(
    ["resourcegroups"]="discover_resource_groups discover_resource_groups_by_tag discover_resources_in_specific_rgs"
    ["policies"]="discover_policy_assignments discover_policy_remediations"
    ["roles"]="discover_custom_roles_enhanced discover_role_assignments_for_custom_roles"
    ["diagnostics"]="discover_diagnostic_settings discover_directory_diagnostic_settings"
    ["serviceprincipals"]="discover_service_principals"
    ["managementgroups"]="discover_management_group_role_assignments discover_management_group_deployments"
    ["subscriptions"]="discover_subscription_role_assignments"
)

# --- Logging Functions ---
LOG_FILE=""
LOG_ENABLED=false

# --- Helper function to strip ANSI color codes and special characters --- 
strip_colors() {
    # Remove ANSI color codes (e.g., \033[0;34m)
    local cleaned=$(echo "$1" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
    # Remove other escape sequences
    cleaned=$(echo "$cleaned" | sed -E 's/\\033\[[0-9;]*m//g')
    echo "$cleaned"
}

# --- Function to log to file if logging is enabled --- 
log_to_file() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "$LOG_ENABLED" == true ]] && [[ -n "$LOG_FILE" ]]; then
        # Strip ANSI color codes and escape sequences before writing to log file
        local clean_message
        clean_message=$(strip_colors "$message")
        
        # Try to write to log file, but don't fail if we can't
        echo "[$timestamp] $level: $clean_message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# --- Logging functions with file logging --- 
log_info() { 
    echo -e "${BLUE}ℹ️  $*${NC}"
    log_to_file "INFO" "$*"
}
log_success() { 
    echo -e "${GREEN}✅ $*${NC}"
    log_to_file "SUCCESS" "$*"
}
log_warning() { 
    echo -e "${YELLOW}⚠️  $*${NC}"
    log_to_file "WARNING" "$*"
}
log_error() { 
    echo -e "${RED}❌ $*${NC}"
    log_to_file "ERROR" "$*"
}
log_debug() { 
    echo -e "${CYAN}ℹ️  $*${NC}"
    log_to_file "DEBUG" "$*"
}
log_special() { 
    echo -e "${PURPLE}🔐 $*${NC}"
    log_to_file "SPECIAL" "$*"
}
log_audit() {
    local message="$1"
    echo -e "${ORANGE}📊 $*${NC}"
    log_to_file "AUDIT" "$*"
}

# --- Usage Function ---
usage() {
    echo -e "${YELLOW}Description:${NC}"
    echo "  This comprehensive Bash script automates the discovery and safe deletion of Cortex Cloud Azure onboarding resources."
    echo "  It operates across all scopes—Subscription, Management Group, and Tenant—and identifies resources using name patterns and tags."
    echo "  The script includes advanced exclusion options and audit logging capabilities to ensure precise and secure resource management, saving significant time and manual effort."

    echo 
    echo -e "${YELLOW}Usage:${NC}"
    echo "  bash $0 <resource-name> [--dry-run] [--delete] [--subscription SUB_ID] [--exclude RESOURCE_NAMES] [--exclude-service SERVICE_TYPES] [--log-file FILE] [--append-log] [--help]"
    echo "  bash $0 <pattern1,pattern2,...> [--dry-run] [--delete] [--subscription SUB_ID] [--exclude RESOURCE_NAMES] [--exclude-service SERVICE_TYPES] [--log-file FILE] [--append-log]"
    echo "  bash $0 --tag KEY[=VALUE] [--dry-run] [--delete] [--subscription SUB_ID] [--exclude RESOURCE_NAMES] [--exclude-service SERVICE_TYPES] [--log-file FILE] [--append-log] [--help]"
    echo "  bash $0 --resource-group RG_NAME [--dry-run] [--delete] [--subscription SUB_ID] [--exclude RESOURCE_NAMES] [--exclude-service SERVICE_TYPES] [--log-file FILE] [--append-log] [--help]"
    echo
    echo -e "${YELLOW}Options:${NC}"
    echo "  <resource-name>         Search pattern (case-insensitive). Use commas for multiple patterns."
    echo "                          Example: \"cortex,ADSConnector,ADSGallery,ADSOutpost,monitor\" (matches ANY of these patterns)"
    echo "  --dry-run               Only show what would be deleted (default)"
    echo "  --delete                Actually delete resources (default: dry-run)"
    echo "  --tag KEY[=VALUE]       Search by tag in three ways:"
    echo "                              • KEY          - matches tag key"
    echo "                              • KEY=VALUE    - matches exact key-value pair"
    echo "                              • VALUE        - matches tag value"
    echo "  --resource-group        Target specific resource group for discovery/deletion"
    echo "                          Accepts comma-separated list of resource group names"
    echo "  --subscription          Limit search to specific subscription"
    echo "  --exclude-subscription  Exclude specific subscription(s) from search"
    echo "                          Accepts comma-separated subscription IDs"
    echo "  --exclude               Comma-separated resource names to exclude from deletion"
    echo "                          (exact match, case-sensitive, not patterns)"
    echo "  --exclude-service       Comma-separated service types to skip scanning entirely"
    echo "                          Available types: resources, resourcegroups, policies, roles,"
    echo "                          diagnostics, serviceprincipals, managementgroups, subscriptions"
    echo "  --log-file FILE         Write detailed audit log to specified file"
    echo "  --append-log            Append to existing log file instead of overwriting"
    echo "  --help                  Show this help message"
    echo
    echo -e "${YELLOW}Examples:${NC}"
    echo
    echo "  ${PURPLE}# Combined pattern and resource group targeting${NC}"
    echo "  bash $0 \"cortex,ADSConnector,ADSGallery,ADSOutpost\"  --dry-run --resource-group \"cortex-onboarding-*,cortex-m*\" --exclude-service \"serviceprincipals\" --exclude \"cortex-scan-platform,production\" --log-file \"audit.log\""
    echo
    echo "  ${PURPLE}# Help message${NC}"
    echo "  bash $0 --help"
    exit 1
}

# --- Argument Parsing with Validation ---
DELETE_MODE=false
DRY_RUN=true
SUBSCRIPTION_ID=""
EXCLUDE_SUBSCRIPTIONS=""
NAME_PATTERN=""
TAG_FILTER=""
RESOURCE_GROUPS=""
EXCLUDE_PATTERNS=""
EXCLUDE_SERVICES=""
LOG_FILE=""
APPEND_LOG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --delete)
            DELETE_MODE=true
            DRY_RUN=false
            shift
            ;;
        --dry-run)
            DELETE_MODE=false
            DRY_RUN=true
            shift
            ;;
        --subscription)
            if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                log_error "--subscription requires a value"
                usage
            fi
            SUBSCRIPTION_ID="$2"
            shift 2
            ;;
        --exclude-subscription)
            if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                log_error "--exclude-subscription requires a value"
                log_error "Usage: --exclude-subscription SUB_ID or --exclude-subscription SUB1,SUB2"
                log_error "Example: --exclude-subscription \"12345-67890\""
                log_error "Example: --exclude-subscription \"12345-67890,98765-43210\""
                exit 1
            fi
            EXCLUDE_SUBSCRIPTIONS="$2"
            shift 2
            ;;
        --tag)
            if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                log_error "--tag requires a value"
                usage
            fi
            TAG_FILTER="$2"
            shift 2
            ;;
        --resource-group)
            if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                log_error "--resource-group requires a value"
                log_error "Usage: --resource-group RG_NAME or --resource-group RG1,RG2"
                log_error "Example: --resource-group \"cortex-onboarding\""
                log_error "Example: --resource-group \"cortex-onboarding,rg-cortex-dev\""
                exit 1
            fi
            RESOURCE_GROUPS="$2"
            shift 2
            ;;
        --exclude)
            if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                log_error "--exclude requires a value"
                usage
            fi
            EXCLUDE_PATTERNS="$2"
            shift 2
            ;;
        --exclude-service)
            if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                log_error "--exclude-service requires a value"
                log_error "Usage: --exclude-service SERVICE_TYPE or --exclude-service TYPE1,TYPE2"
                log_error "Available types: resources, resourcegroups, policies, roles, diagnostics, serviceprincipals, managementgroups, subscriptions"
                log_error "Example: --exclude-service \"serviceprincipals,policies\""
                exit 1
            fi
            EXCLUDE_SERVICES="$2"
            shift 2
            ;;
        --log-file)
            if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                log_error "--log-file requires a value"
                usage
            fi
            LOG_FILE="$2"
            LOG_ENABLED=true
            shift 2
            ;;
        --append-log)
            APPEND_LOG=true
            shift
            ;;
        --help)
            usage
            ;;
        -*)
            log_error "Unknown option $1"
            usage
            ;;
        *)
            NAME_PATTERN="$1"
            shift
            ;;
    esac
done

# --- Validation --- 
if [[ -z "$NAME_PATTERN" && -z "$TAG_FILTER" && -z "$RESOURCE_GROUPS" ]]; then
    log_error "Either name pattern, tag filter, or resource group specification is required"
    usage
fi

# --- Parse multiple patterns (comma-separated) ---
declare -a NAME_PATTERNS=()
if [[ -n "$NAME_PATTERN" ]]; then
    IFS=',' read -ra NAME_PATTERNS <<< "$NAME_PATTERN"
    #  --- Trim whitespace from each pattern --- 
    for i in "${!NAME_PATTERNS[@]}"; do
        NAME_PATTERNS[$i]=$(echo "${NAME_PATTERNS[$i]}" | xargs)
    done
fi

# === Changes: Forced addition of Cortex-specific roles that are always included in the deletion list ===
if [[ ! "$NAME_PATTERN" =~ "ADSScannedAssetsRole" ]]; then
    NAME_PATTERNS+=("ADSScannedAssetsRole-")
fi
if [[ ! "$NAME_PATTERN" =~ "automationRole" ]]; then
    NAME_PATTERNS+=("automationRole-")
fi
# =================================================================

if [[ ${#NAME_PATTERNS[@]} -gt 0 ]]; then
    log_special "Azure Resource Cleanup Tool"
    log_to_file "INFO" "Parsed ${#NAME_PATTERNS[@]} search pattern(s): ${NAME_PATTERNS[*]}"
fi

# --- Parse resource groups (comma-separated) ---
declare -a RESOURCE_GROUP_ARRAY=()
if [[ -n "$RESOURCE_GROUPS" ]]; then
    IFS=',' read -ra RESOURCE_GROUP_ARRAY <<< "$RESOURCE_GROUPS"
    # Trim whitespace from each resource group name
    for i in "${!RESOURCE_GROUP_ARRAY[@]}"; do
        RESOURCE_GROUP_ARRAY[$i]=$(echo "${RESOURCE_GROUP_ARRAY[$i]}" | xargs)
    done
    log_to_file "INFO" "Parsed ${#RESOURCE_GROUP_ARRAY[@]} resource group(s): ${RESOURCE_GROUP_ARRAY[*]}"
fi

# --- Parse exclude subscriptions ---
declare -a EXCLUDE_SUBSCRIPTION_ARRAY=()
if [[ -n "$EXCLUDE_SUBSCRIPTIONS" ]]; then
    IFS=',' read -ra EXCLUDE_SUBSCRIPTION_ARRAY <<< "$EXCLUDE_SUBSCRIPTIONS"
    # Trim whitespace from each subscription ID
    for i in "${!EXCLUDE_SUBSCRIPTION_ARRAY[@]}"; do
        EXCLUDE_SUBSCRIPTION_ARRAY[$i]=$(echo "${EXCLUDE_SUBSCRIPTION_ARRAY[$i]}" | xargs)
    done
    log_to_file "INFO" "Parsed ${#EXCLUDE_SUBSCRIPTION_ARRAY[@]} exclude subscription(s): ${EXCLUDE_SUBSCRIPTION_ARRAY[*]}"
    
    # Validate exclude subscriptions don't conflict with include subscription
    if [[ -n "$SUBSCRIPTION_ID" ]]; then
        for exclude_sub in "${EXCLUDE_SUBSCRIPTION_ARRAY[@]}"; do
            if [[ "$exclude_sub" == "$SUBSCRIPTION_ID" ]]; then
                log_error "Conflict: Subscription $SUBSCRIPTION_ID cannot be both included (--subscription) and excluded (--exclude-subscription)"
                exit 1
            fi
        done
    fi
fi

# --- Parse exclude services ---
declare -a EXCLUDE_SERVICE_ARRAY=()
declare -a EXCLUDED_RESOURCE_TYPES=()
if [[ -n "$EXCLUDE_SERVICES" ]]; then
    IFS=',' read -ra EXCLUDE_SERVICE_ARRAY <<< "$EXCLUDE_SERVICES"
    # Trim whitespace and convert to lowercase
    for i in "${!EXCLUDE_SERVICE_ARRAY[@]}"; do
        EXCLUDE_SERVICE_ARRAY[$i]=$(echo "${EXCLUDE_SERVICE_ARRAY[$i]}" | tr '[:upper:]' '[:lower:]' | xargs)
        
        # Skip empty strings
        if [[ -z "${EXCLUDE_SERVICE_ARRAY[$i]}" ]]; then
            log_warning "Found empty service type in --exclude-service, skipping"
            continue
        fi
        
        # Validate service type - REMOVE 'local' keyword here
        service_type="${EXCLUDE_SERVICE_ARRAY[$i]}"
        if [[ -z "${SERVICE_TYPE_MAP[$service_type]}" ]]; then
            log_error "Invalid service type: $service_type"
            log_error "Available types: ${!SERVICE_TYPE_MAP[@]}"
            exit 1
        fi
        
        # Map to resource types
        if [[ "$service_type" == "all" ]]; then
            # Exclude all service-specific types
            EXCLUDED_RESOURCE_TYPES=("ResourceGroup" "PolicyAssignment" "PolicyRemediation" 
                                     "CustomRole" "RoleAssignment" "UnknownRoleAssignment"
                                     "DiagnosticSetting" "SubscriptionDiagnosticSetting" "DirectoryDiagnosticSetting"
                                     "EnterpriseApplication" "ManagementGroupRoleAssignment" 
                                     "ManagementGroupDeployment" "SubscriptionRoleAssignment")
            log_info "Excluding ALL service-specific discovery"
        else
            # Add resource types for this service
            IFS=',' read -ra resource_types <<< "${SERVICE_TYPE_MAP[$service_type]}"
            for rt in "${resource_types[@]}"; do
                if [[ ! " ${EXCLUDED_RESOURCE_TYPES[@]} " =~ " ${rt} " ]]; then
                    EXCLUDED_RESOURCE_TYPES+=("$rt")
                fi
            done
        fi
    done
    
    log_to_file "INFO" "Parsed ${#EXCLUDE_SERVICE_ARRAY[@]} exclude service(s): ${EXCLUDE_SERVICE_ARRAY[*]}"
    log_to_file "INFO" "Excluding resource types: ${EXCLUDED_RESOURCE_TYPES[*]}"
fi

#  --- Sanitize name pattern for JSON queries --- 
SANITIZED_PATTERN=""
if [[ ${#NAME_PATTERNS[@]} -gt 0 ]]; then
    SANITIZED_PATTERN=$(printf '%s' "${NAME_PATTERNS[0]}" | sed "s/'/''/g")
fi

# --- Parse exclude patterns ---
declare -a EXCLUDE_ARRAY=()
if [[ -n "$EXCLUDE_PATTERNS" ]]; then
    IFS=',' read -ra EXCLUDE_ARRAY <<< "$EXCLUDE_PATTERNS"
    # Trim whitespace from each pattern
    for i in "${!EXCLUDE_ARRAY[@]}"; do
        EXCLUDE_ARRAY[$i]=$(echo "${EXCLUDE_ARRAY[$i]}" | xargs)
    done
fi

# --- Pre-flight Checks ---
check_dependency() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "$1 not found. Please install it."
        exit 1
    fi
}

check_dependency az
check_dependency jq

if ! az account show >/dev/null 2>&1; then
    log_error "Not logged into Azure. Please run 'az login' first."
    exit 1
fi

log_success "Azure login confirmed"

# --- Performance Configuration ---
MAX_PARALLEL=${MAX_PARALLEL:-20}  # Max parallel background jobs for diagnostic settings

# --- Subscription Name Cache ---
declare -A SUB_NAME_CACHE=()

cache_subscription_names() {
    log_debug "Caching subscription names..."
    local subs_json
    subs_json=$(az account list --query '[?state==`Enabled`].{id:id, name:name}' -o json 2>/dev/null || echo '[]')
    while IFS=$'\t' read -r sub_id sub_name; do
        [[ -z "$sub_id" ]] && continue
        SUB_NAME_CACHE["$sub_id"]="$sub_name"
    done < <(echo "$subs_json" | jq -r '.[] | "\(.id)\t\(.name)"')
    log_debug "Cached ${#SUB_NAME_CACHE[@]} subscription names"
}

get_sub_name() {
    local sub="$1"
    if [[ -n "${SUB_NAME_CACHE[$sub]+_}" ]]; then
        echo "${SUB_NAME_CACHE[$sub]}"
    else
        local name
        name=$(az account show --subscription "$sub" --query 'name' -o tsv 2>/dev/null || echo "Unknown")
        SUB_NAME_CACHE["$sub"]="$name"
        echo "$name"
    fi
}

# --- Initialize Arrays ---
declare -a ALL_IDS=()
declare -a SUMMARY_ROWS=()
declare -a EXCLUDED_IDS=()
declare -a EXCLUDED_RESOURCE_DETAILS=()  # New: Store details of excluded resources
declare -a EXCLUDED_SUMMARY_ROWS=()      # New: Store summary rows of excluded resources
declare -a RESOURCE_TYPES=()
declare -a RG_SUBSCRIPTION=()
declare -a RESOURCE_DETAILS=()
declare -a RG_EXCLUDED_RESOURCES=()  # Track excluded resources in resource groups

#  --- Track if we found any resources --- 
RESOURCES_FOUND=false

# --- Helper Functions ---
normalize() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

#  --- Clean display name for output (handles edge cases where role names contain literal color codes) --- 
clean_display_name() {
    local text="$1"
    echo "$text"
}

# --- Check if service type should be excluded ---
is_service_excluded() {
    local service_type="$1"
    
    # Check if 'all' is excluded
    if [[ " ${EXCLUDE_SERVICE_ARRAY[@]} " =~ " all " ]]; then
        return 0
    fi
    
    # Check if specific service is excluded
    if [[ " ${EXCLUDE_SERVICE_ARRAY[@]} " =~ " ${service_type} " ]]; then
        return 0
    fi
    
    return 1
}

# --- Check if resource type should be excluded from discovery ---
is_resource_type_excluded() {
    local resource_type="$1"
    
    # If no exclusions, include everything
    [[ ${#EXCLUDED_RESOURCE_TYPES[@]} -eq 0 ]] && return 1
    
    # Check if this resource type is in excluded list
    for excluded_type in "${EXCLUDED_RESOURCE_TYPES[@]}"; do
        if [[ "$resource_type" == "$excluded_type" ]]; then
            return 0
        fi
    done
    
    return 1
}

#  --- Simple highlight function that only highlights if no suspicious sequences are found --- 
safe_highlight() {
    local text="$1"
    local pattern="$2"
    
    #  --- If the text contains what looks like color codes or escape sequences, don't attempt highlighting --- 
    if [[ "$text" =~ [\x00-\x1F] ]] || [[ "$text" =~ 033\[ ]]; then
        echo "$text"
    else
        if [[ "$(normalize "$text")" == *"$(normalize "$pattern")"* ]]; then
            local esc_pattern=$(echo "$pattern" | sed 's/[]\/$*.^|[]/\\&/g')
            echo "$text" | sed -E "s/($esc_pattern)/${YELLOW}\1${NC}/Ig"
        else
            echo "$text"
        fi
    fi
}

#  --- Multi-pattern highlighting --- 
highlight_matches() {
    local text="$1"
    local result="$text"
    
    #  --- If the text contains what looks like color codes, don't attempt highlighting --- 
    if [[ "$text" =~ [\x00-\x1F] ]] || [[ "$text" =~ 033\[ ]]; then
        echo "$text"
        return
    fi
    
    #  --- Highlight all matching patterns --- 
    for pattern in "${NAME_PATTERNS[@]}"; do
        if [[ "$(normalize "$result")" == *"$(normalize "$pattern")"* ]]; then
            local esc_pattern=$(echo "$pattern" | sed 's/[]\/$*.^|[]/\\&/g')
            result=$(echo "$result" | sed -E "s/($esc_pattern)/${YELLOW}\1${NC}/Ig")
        fi
    done
    
    echo "$result"
}

# --- Multi-pattern matching helper --- 
matches_any_pattern() {
    local text="$1"
    local text_lower="$(normalize "$text")"
    
    #  --- If in pure tag mode or resource group mode (no name patterns), skip pattern matching --- 
    if [[ (-n "$TAG_FILTER" && ${#NAME_PATTERNS[@]} -eq 0) || (-n "$RESOURCE_GROUPS" && ${#NAME_PATTERNS[@]} -eq 0) ]]; then
        return 1
    fi
    
    #  --- If no patterns, return false --- 
    [[ ${#NAME_PATTERNS[@]} -eq 0 ]] && return 1
    
    #  --- Check if text matches any of the patterns --- 
    for pattern in "${NAME_PATTERNS[@]}"; do
        if [[ "$text_lower" == *"$(normalize "$pattern")"* ]]; then
            echo "$pattern"  # Return the matching pattern for logging
            return 0
        fi
    done
    
    return 1
}

# --- Resource Group Pattern Matching ---
matches_resource_group() {
    local resource_group="$1"
    local rg_lower="$(normalize "$resource_group")"
    
    #  --- If no resource group filter specified, return false (don't match everything) --- 
    [[ ${#RESOURCE_GROUP_ARRAY[@]} -eq 0 ]] && return 1
    
    #  --- Check if resource group matches any of the specified patterns --- 
    for rg_pattern in "${RESOURCE_GROUP_ARRAY[@]}"; do
        local pattern_lower="$(normalize "$rg_pattern")"
        
        # Support wildcard matching for resource groups
        if [[ "$rg_pattern" == *"*"* ]]; then
            # Convert wildcard pattern to regex
            local regex_pattern=$(echo "$pattern_lower" | sed 's/\*/.*/g')
            if [[ "$rg_lower" =~ ^${regex_pattern}$ ]]; then
                echo "$rg_pattern"  # Return the matching pattern for logging
                return 0
            fi
        else
            # Exact or partial match
            if [[ "$rg_lower" == *"$pattern_lower"* ]]; then
                echo "$rg_pattern"
                return 0
            fi
        fi
    done
    
    return 1
}

# --- Exact Match Exclude Checking Function ---
should_exclude() {
    local resource_name="$1"
    local resource_type="$2"
    local resource_id="$3"
    
    #  --- If no exclude patterns, don't exclude anything --- 
    [[ -z "$EXCLUDE_PATTERNS" ]] && return 1
    
    #  --- Check each exclude pattern --- 
    for exclude_name in "${EXCLUDE_ARRAY[@]}"; do
        #  --- Trim whitespace --- 
        exclude_name=$(echo "$exclude_name" | xargs)
        
        #  --- Skip empty patterns --- 
        [[ -z "$exclude_name" ]] && continue
        
        # --- EXACT MATCH (case-sensitive) --- 
        if [[ "$resource_name" == "$exclude_name" ]]; then
            log_warning "Excluding resource: $resource_name ($resource_type) - exact match with exclude name: $exclude_name"
            
            # Check if this resource is inside a resource group
            if [[ "$resource_id" == */resourceGroups/* ]]; then
                # Extract resource group name from resource ID
                local rg_name
                if [[ "$resource_id" =~ /resourceGroups/([^/]+)/ ]]; then
                    rg_name="${BASH_REMATCH[1]}"
                    
                    # Check if already tracked
                    local already_tracked=false
                    for item in "${RG_EXCLUDED_RESOURCES[@]}"; do
                        if [[ "$item" == "$rg_name|$resource_name|$resource_type" ]]; then
                            already_tracked=true
                            break
                        fi
                    done
                    
                    if [[ "$already_tracked" == false ]]; then
                        RG_EXCLUDED_RESOURCES+=("$rg_name|$resource_name|$resource_type")
                        log_warning "  ↳ Resource is in Resource Group: $rg_name"
                    fi
                fi
            fi
            
            return 0  # Should exclude
        fi
        
        #  --- Also check resource ID for exact matches --- 
        local resource_basename=$(basename "$resource_id" 2>/dev/null || echo "")
        if [[ "$resource_basename" == "$exclude_name" ]]; then
            log_warning "Excluding resource: $resource_name ($resource_type) - exact match with exclude name in ID: $exclude_name"
            
            # Check if this resource is inside a resource group
            if [[ "$resource_id" == */resourceGroups/* ]]; then
                # Extract resource group name from resource ID
                local rg_name
                if [[ "$resource_id" =~ /resourceGroups/([^/]+)/ ]]; then
                    rg_name="${BASH_REMATCH[1]}"
                    
                    # Check if already tracked
                    local already_tracked=false
                    for item in "${RG_EXCLUDED_RESOURCES[@]}"; do
                        if [[ "$item" == "$rg_name|$resource_name|$resource_type" ]]; then
                            already_tracked=true
                            break
                        fi
                    done
                    
                    if [[ "$already_tracked" == false ]]; then
                        RG_EXCLUDED_RESOURCES+=("$rg_name|$resource_name|$resource_type")
                        log_warning "  ↳ Resource is in Resource Group: $rg_name"
                    fi
                fi
            fi
            
            return 0  # Should exclude
        fi
    done
    
    return 1  # Should not exclude
}

#  --- Helper functions for older Bash versions --- 
get_resource_type() {
    local id="$1"
    for item in "${RESOURCE_TYPES[@]}"; do
        if [[ "$item" == "$id|"* ]]; then
            echo "${item#*|}"
            return 0
        fi
    done
    echo ""
}

get_resource_details() {
    local id="$1"
    for item in "${RESOURCE_DETAILS[@]}"; do
        if [[ "$item" == "$id|"* ]]; then
            echo "${item#*|}"
            return 0
        fi
    done
    echo ""
}

get_rg_subscription() {
    local id="$1"
    for item in "${RG_SUBSCRIPTION[@]}"; do
        if [[ "$item" == "$id|"* ]]; then
            echo "${item#*|}"
            return 0
        fi
    done
    echo ""
}

# --- Subscription Handling ---
get_subscriptions() {
    if [[ -n "$SUBSCRIPTION_ID" ]]; then
        log_info "Limiting search to subscription: $SUBSCRIPTION_ID"
        echo "$SUBSCRIPTION_ID"
    else
        log_info "Getting all enabled subscriptions..."
        local subs
        subs=$(az account list --query '[?state==`Enabled`].id' -o tsv 2>/dev/null || echo "")
        if [[ -z "$subs" ]]; then
            log_error "No enabled subscriptions found or unable to list subscriptions"
            exit 1
        fi
        
        # Apply exclude subscriptions filter if specified
        if [[ ${#EXCLUDE_SUBSCRIPTION_ARRAY[@]} -gt 0 ]]; then
            local filtered_subs=""
            while IFS= read -r sub; do
                [[ -z "$sub" ]] && continue
                
                local should_exclude=false
                for exclude_sub in "${EXCLUDE_SUBSCRIPTION_ARRAY[@]}"; do
                    if [[ "$sub" == "$exclude_sub" ]]; then
                        should_exclude=true
                        log_debug "Excluding subscription: $sub (matches exclude pattern: $exclude_sub)"
                        break
                    fi
                done
                
                if [[ "$should_exclude" == false ]]; then
                    filtered_subs+="$sub"$'\n'
                fi
            done <<< "$subs"
            
            subs="$filtered_subs"
            
            if [[ -z "$subs" ]]; then
                log_error "All subscriptions were excluded. Nothing to search."
                exit 1
            fi
            
            log_info "Excluded ${#EXCLUDE_SUBSCRIPTION_ARRAY[@]} subscription(s) from search"
        fi
        
        echo "$subs"
    fi
}

# --- Resource Group Discovery ---
discover_resource_groups() {
    local sub="$1"
    local sub_name="$2"
    
    # Skip if resource groups are excluded
    if is_service_excluded "resourcegroups"; then
        log_debug "Skipping resource group discovery (excluded via --exclude-service)"
        return
    fi
    
    log_debug "Searching for resource groups in subscription: $sub_name"
    
    local rgs
    rgs=$(az group list --subscription "$sub" -o json 2>/dev/null || echo '[]')
    
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        
        local name id tags location
        name=$(jq -r '.name // ""' <<< "$row")
        id=$(jq -r '.id // ""' <<< "$row")
        tags=$(jq -r '.tags // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' <<< "$row")
        location=$(jq -r '.location // ""' <<< "$row")
        
        local should_include=false
        
        # Different logic based on search mode
        if [[ ${#RESOURCE_GROUP_ARRAY[@]} -gt 0 ]]; then
            # Resource group mode: include if RG matches specified patterns
            if matches_resource_group "$name" >/dev/null; then
                should_include=true
            fi
        elif [[ ${#NAME_PATTERNS[@]} -gt 0 ]]; then
            # Name pattern mode: include if RG name matches search patterns
            if matches_any_pattern "$name" >/dev/null; then
                should_include=true
            fi
        else
            # No filters (shouldn't happen due to validation)
            continue
        fi
        
        if [[ "$should_include" == false ]]; then
            continue
        fi
        
        # Check for duplicates BEFORE adding
        if [[ " ${ALL_IDS[@]} " =~ " ${id} " ]]; then
            log_debug "Skipping duplicate resource group: $name (already discovered)"
            continue
        fi
        
        echo "  → Found Resource Group: $(highlight_matches "$name") (Location: $location)"
        log_to_file "FOUND" "Resource Group: $name in subscription: $sub_name, Location: $location"
        SUMMARY_ROWS+=("$name|ResourceGroup|$sub_name|Location: $location, Tags: $tags")
        ALL_IDS+=("$id")
        RESOURCE_TYPES+=("$id|ResourceGroup")
        RG_SUBSCRIPTION+=("$id|$sub")
        RESOURCE_DETAILS+=("$id|$name|ResourceGroup|$sub_name|$location")
        RESOURCES_FOUND=true
    done < <(jq -c '.[]' <<< "$rgs")
}

# --- Fast Resource Discovery via Azure Resource Graph ---
# Replaces per-subscription az resource list with a single cross-subscription query
discover_resources_via_graph() {
    if is_service_excluded "resources"; then
        log_debug "Skipping resource discovery (excluded via --exclude-service)"
        return 0
    fi

    # Check if az graph extension is available
    if ! az graph query -q "Resources | limit 1" --first 1 &>/dev/null 2>&1; then
        log_warning "Azure Resource Graph not available. Install with: az extension add --name resource-graph"
        log_warning "Falling back to per-subscription discovery (slower)..."
        return 1
    fi

    log_info "Searching resources across all subscriptions using Resource Graph (fast mode)..."

    # Build KQL name filter from patterns
    local kql_conditions=""
    for pattern in "${NAME_PATTERNS[@]}"; do
        local escaped_pattern=$(printf '%s' "$pattern" | sed "s/'/''/g")
        if [[ -n "$kql_conditions" ]]; then
            kql_conditions="$kql_conditions or name contains '$escaped_pattern'"
        else
            kql_conditions="name contains '$escaped_pattern'"
        fi
    done

    [[ -z "$kql_conditions" ]] && return 1

    # Build subscription scope args
    local sub_args=""
    if [[ -n "$SUBSCRIPTION_ID" ]]; then
        sub_args="--subscriptions $SUBSCRIPTION_ID"
    fi

    # --- Query regular resources ---
    local query="Resources | where $kql_conditions | where type !contains 'microsoft.authorization/roledefinitions' | project name, type, id, resourceGroup, subscriptionId, tags, location"
    local results
    results=$(az graph query -q "$query" --first 1000 $sub_args -o json 2>/dev/null || echo '{"data":[]}')

    local data
    data=$(echo "$results" | jq -c '.data // .[] // []' 2>/dev/null)

    while IFS= read -r row; do
        [[ -z "$row" || "$row" == "null" ]] && continue

        local name type id rg sub_id tags
        name=$(jq -r '.name // ""' <<< "$row")
        type=$(jq -r '.type // ""' <<< "$row")
        id=$(jq -r '.id // ""' <<< "$row")
        rg=$(jq -r '.resourceGroup // ""' <<< "$row")
        sub_id=$(jq -r '.subscriptionId // ""' <<< "$row")
        tags=$(jq -r 'if .tags then (.tags | to_entries | map("\(.key)=\(.value)") | join(", ")) else "" end' <<< "$row")

        # Apply exclude subscription filter
        if [[ ${#EXCLUDE_SUBSCRIPTION_ARRAY[@]} -gt 0 ]]; then
            local skip=false
            for excl in "${EXCLUDE_SUBSCRIPTION_ARRAY[@]}"; do
                [[ "$sub_id" == "$excl" ]] && skip=true && break
            done
            [[ "$skip" == true ]] && continue
        fi

        # Apply resource group filter if specified
        if [[ ${#RESOURCE_GROUP_ARRAY[@]} -gt 0 ]] && [[ -n "$rg" ]]; then
            if ! matches_resource_group "$rg" >/dev/null; then
                continue
            fi
        fi

        # Skip duplicates
        if [[ " ${ALL_IDS[@]} " =~ " ${id} " ]]; then
            continue
        fi

        local sub_name=$(get_sub_name "$sub_id")

        echo "  → Found Resource: $(highlight_matches "$name") ($type) in RG: $rg"
        log_to_file "FOUND" "Resource: $name ($type) in subscription: $sub_name, RG: $rg"
        SUMMARY_ROWS+=("$name|$type|$sub_name|RG: $rg, Tags: $tags")
        ALL_IDS+=("$id")
        RESOURCE_TYPES+=("$id|$type")
        RESOURCE_DETAILS+=("$id|$name|$type|$sub_name|$rg")
        RESOURCES_FOUND=true
    done < <(jq -c '.[]' <<< "$data" 2>/dev/null)

    # --- Query resource groups ---
    if ! is_service_excluded "resourcegroups"; then
        local rg_query="ResourceContainers | where type =~ 'microsoft.resources/subscriptions/resourcegroups' | where $kql_conditions | project name, id, subscriptionId, tags, location"
        local rg_results
        rg_results=$(az graph query -q "$rg_query" --first 1000 $sub_args -o json 2>/dev/null || echo '{"data":[]}')

        local rg_data
        rg_data=$(echo "$rg_results" | jq -c '.data // .[] // []' 2>/dev/null)

        while IFS= read -r row; do
            [[ -z "$row" || "$row" == "null" ]] && continue

            local name id sub_id tags location
            name=$(jq -r '.name // ""' <<< "$row")
            id=$(jq -r '.id // ""' <<< "$row")
            sub_id=$(jq -r '.subscriptionId // ""' <<< "$row")
            tags=$(jq -r 'if .tags then (.tags | to_entries | map("\(.key)=\(.value)") | join(", ")) else "" end' <<< "$row")
            location=$(jq -r '.location // ""' <<< "$row")

            # Apply exclude subscription filter
            if [[ ${#EXCLUDE_SUBSCRIPTION_ARRAY[@]} -gt 0 ]]; then
                local skip=false
                for excl in "${EXCLUDE_SUBSCRIPTION_ARRAY[@]}"; do
                    [[ "$sub_id" == "$excl" ]] && skip=true && break
                done
                [[ "$skip" == true ]] && continue
            fi

            # Apply resource group filter
            if [[ ${#RESOURCE_GROUP_ARRAY[@]} -gt 0 ]]; then
                if ! matches_resource_group "$name" >/dev/null; then
                    continue
                fi
            fi

            if [[ " ${ALL_IDS[@]} " =~ " ${id} " ]]; then
                continue
            fi

            local sub_name=$(get_sub_name "$sub_id")

            echo "  → Found Resource Group: $(highlight_matches "$name") (Location: $location)"
            log_to_file "FOUND" "Resource Group: $name in subscription: $sub_name, Location: $location"
            SUMMARY_ROWS+=("$name|ResourceGroup|$sub_name|Location: $location, Tags: $tags")
            ALL_IDS+=("$id")
            RESOURCE_TYPES+=("$id|ResourceGroup")
            RG_SUBSCRIPTION+=("$id|$sub_id")
            RESOURCE_DETAILS+=("$id|$name|ResourceGroup|$sub_name|$location")
            RESOURCES_FOUND=true
        done < <(jq -c '.[]' <<< "$rg_data" 2>/dev/null)
    fi

    log_success "Resource Graph discovery completed"
    return 0
}

# --- Resource Discovery Functions ---
discover_resources() {
    local sub="$1"
    local sub_name="$2"
    
    # Skip regular resources if excluded
    if is_service_excluded "resources"; then
        log_debug "Skipping regular resource discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Searching resources in subscription: $sub_name"
    
    # --- Resources in resource groups --- 
    local resources
    resources=$(az resource list --subscription "$sub" -o json 2>/dev/null || echo '[]')
    
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        
        local name type id tags resource_group
        name=$(jq -r '.name // ""' <<< "$row")
        type=$(jq -r '.type // ""' <<< "$row")
        id=$(jq -r '.id // ""' <<< "$row")
        tags=$(jq -r '.tags // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' <<< "$row")
        
        # Extract resource group from resource ID
        if [[ "$id" =~ /resourceGroups/([^/]+)/ ]]; then
            resource_group="${BASH_REMATCH[1]}"
        else
            resource_group=""
        fi
        
        # --- Check if resource actually belongs to this subscription ---
        local resource_sub
        if [[ "$id" =~ /subscriptions/([^/]+)/ ]]; then
            resource_sub="${BASH_REMATCH[1]}"
            if [[ "$resource_sub" != "$sub" ]]; then
                log_debug "Skipping resource $name - belongs to subscription $resource_sub, not $sub"
                continue
            fi
        fi
        
        # --- Skip if resource group filtering is enabled and doesn't match --- 
        if [[ ${#RESOURCE_GROUP_ARRAY[@]} -gt 0 ]] && [[ -n "$resource_group" ]]; then
            if ! matches_resource_group "$resource_group"; then
                continue
            fi
        fi
        
        # --- Skip role definitions (handled separately) --- 
        [[ "$type" == *"Microsoft.Authorization/roleDefinitions"* ]] && continue
        
        # --- Multi-pattern matching ---
        local matched_pattern
        if matched_pattern=$(matches_any_pattern "$name"); then
            # --- CHECK FOR DUPLICATES BEFORE ADDING ---
            if [[ ! " ${ALL_IDS[@]} " =~ " ${id} " ]]; then
                echo "  → Found Resource: $(highlight_matches "$name") ($type) in RG: $resource_group"
                log_to_file "FOUND" "Resource: $name ($type) in subscription: $sub_name, RG: $resource_group"
                SUMMARY_ROWS+=("$name|$type|$sub_name|RG: $resource_group, Tags: $tags")
                ALL_IDS+=("$id")
                RESOURCE_TYPES+=("$id|$type")
                RESOURCE_DETAILS+=("$id|$name|$type|$sub_name|$resource_group")
                RESOURCES_FOUND=true
            else
                log_debug "Skipping duplicate resource: $name ($id)"
            fi
        fi
    done < <(jq -c '.[]' <<< "$resources")
    
    # --- Resource Groups --- 
    discover_resource_groups "$sub" "$sub_name"
}

# --- Resource Discovery Functions by TAGS ---
discover_resources_by_tag() {
    local tag_filter="$1"
    
    # Skip regular resources if excluded
    if is_service_excluded "resources"; then
        log_debug "Skipping tag-based resource discovery (excluded via --exclude-service)"
        return
    fi
    
    # --- Parse tag filter (key=value or just key or just value) --- 
    local tag_key tag_value
    if [[ "$tag_filter" == *"="* ]]; then
        tag_key="${tag_filter%=*}"
        tag_value="${tag_filter#*=}"
        log_info "Searching for resources with tag: $tag_key=$tag_value"
    else
        tag_key="$tag_filter"
        log_info "Searching for resources with tag key or value: $tag_key"
    fi
    
    local subscriptions
    subscriptions=$(get_subscriptions)
    
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        
        local sub_name
        sub_name=$(get_sub_name "$sub")
        
        log_info "Searching tagged resources in subscription: $sub_name"
        
        # --- Find resources with the specified tag --- 
        local resources
        if [[ "$tag_filter" == *"="* ]]; then
            resources=$(az resource list --subscription "$sub" --query "[?tags.$tag_key=='$tag_value']" -o json 2>/dev/null || echo '[]')
        else
            resources=$(az resource list --subscription "$sub" --query "[?contains(keys(tags), '$tag_key') || contains(values(tags), '$tag_key')]" -o json 2>/dev/null || echo '[]')
        fi
        
        # Debug: Check resource count
        local resource_count=$(echo "$resources" | jq -r 'length // 0' 2>/dev/null || echo 0)
        log_debug "Found $resource_count resources with tag filter '$tag_filter' in subscription $sub_name"
        
        while IFS= read -r resource; do
            [[ -z "$resource" ]] || [[ "$resource" == "null" ]] && continue
            
            local name type id tags location resource_group
            name=$(jq -r '.name // ""' <<< "$resource")
            type=$(jq -r '.type // ""' <<< "$resource")
            id=$(jq -r '.id // ""' <<< "$resource")
            tags=$(jq -r '.tags // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' <<< "$resource")
            location=$(jq -r '.location // ""' <<< "$resource")
            
            # Extract resource group from resource ID
            if [[ "$id" =~ /resourceGroups/([^/]+)/ ]]; then
                resource_group="${BASH_REMATCH[1]}"
            else
                resource_group=""
            fi
            
            # --- Skip if resource group filtering is enabled and doesn't match --- 
            if [[ ${#RESOURCE_GROUP_ARRAY[@]} -gt 0 ]] && [[ -n "$resource_group" ]]; then
                if ! matches_resource_group "$resource_group"; then
                    continue
                fi
            fi
            
            echo "  → Found Tagged Resource: $name ($type)"
            echo "    ↳ Location: $location, Tags: $tags"
            log_to_file "FOUND" "Tagged Resource: $name ($type) in $sub_name"
            log_to_file "DETAILS" "  Location: $location, Tags: $tags"
            
            SUMMARY_ROWS+=("$name|$type|$sub_name|Tags: $tags")
            ALL_IDS+=("$id")
            
            RESOURCE_TYPES+=("$id|$type")
            RESOURCE_DETAILS+=("$id|$name|$type|$sub_name|$tags")
            
            RESOURCES_FOUND=true
            
        done < <(jq -c '.[]' <<< "$resources" 2>/dev/null || echo "")
        
        discover_resource_groups_by_tag "$sub" "$sub_name" "$tag_filter"
        
    done <<< "$subscriptions"
    
    if [[ "$RESOURCES_FOUND" == false ]] && [[ -n "$tag_filter" ]]; then
        log_debug "No resources found with tag filter: $tag_filter"
    fi
}

# --- Resource Group Discovery Functions by TAGS ---
discover_resource_groups_by_tag() {
    local sub="$1" sub_name="$2" tag_filter="$3"
    
    # Skip if resource groups are excluded
    if is_service_excluded "resourcegroups"; then
        log_debug "Skipping tagged resource group discovery (excluded via --exclude-service)"
        return
    fi
    
    # Skip if no subscription or empty subscription
    if [[ -z "$sub" ]] || [[ -z "$sub_name" ]] || [[ "$sub_name" == "Unknown" ]]; then
        log_debug "Skipping resource group discovery for empty/invalid subscription"
        return
    fi
    
    log_debug "Searching for tagged resource groups in subscription: $sub_name"
    
    local rgs
    if [[ "$tag_filter" == *"="* ]]; then
        local tag_key="${tag_filter%=*}"
        local tag_value="${tag_filter#*=}"
        rgs=$(az group list --subscription "$sub" --query "[?tags.$tag_key=='$tag_value']" -o json 2>/dev/null || echo '[]')
    else
        rgs=$(az group list --subscription "$sub" --query "[?contains(keys(tags), '$tag_filter') || contains(values(tags), '$tag_filter')]" -o json 2>/dev/null || echo '[]')
    fi
    
    # # Debug: Check RG count
    # local rg_count=$(echo "$rgs" | jq -r 'length // 0' 2>/dev/null || echo 0)
    # log_debug "Found $rg_count resource groups with tag filter '$tag_filter' in subscription $sub_name"
    
    while IFS= read -r rg; do
        [[ -z "$rg" ]] || [[ "$rg" == "null" ]] && continue
        
        local name id tags location
        name=$(jq -r '.name // ""' <<< "$rg")
        id=$(jq -r '.id // ""' <<< "$rg")
        tags=$(jq -r '.tags // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' <<< "$rg")
        location=$(jq -r '.location // ""' <<< "$rg")
        
        # --- Check if resource group matches the filter --- 
        local matched_rg_pattern
        if [[ ${#RESOURCE_GROUP_ARRAY[@]} -gt 0 ]] && ! matches_resource_group "$name"; then
            continue
        fi
        
        # Check if we already have this resource group in our list
        if [[ " ${ALL_IDS[@]} " =~ " ${id} " ]]; then
            log_debug "Skipping duplicate resource group: $name (already discovered)"
            continue
        fi
        
        echo "  → Found Tagged Resource Group: $name"
        echo "    ↳ Location: $location, Tags: $tags"
        log_to_file "FOUND" "Tagged Resource Group: $name in $sub_name"
        log_to_file "DETAILS" "  Location: $location, Tags: $tags"
        
        SUMMARY_ROWS+=("$name|ResourceGroup|$sub_name|Tags: $tags")
        ALL_IDS+=("$id")
        
        RESOURCE_TYPES+=("$id|ResourceGroup")
        RG_SUBSCRIPTION+=("$id|$sub")
        RESOURCE_DETAILS+=("$id|$name|ResourceGroup|$sub_name|$tags")
        
        RESOURCES_FOUND=true
        
        discover_all_resources_in_rg "$sub" "$sub_name" "$name" "$id"
        
    done < <(jq -c '.[]' <<< "$rgs" 2>/dev/null || echo "")
}

# --- Resource Group Specific Discovery (for --resource-group mode) ---
discover_resources_in_specific_rgs() {
    # Skip if resource groups are excluded
    if is_service_excluded "resourcegroups"; then
        log_debug "Skipping specific resource group discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Searching resources in specific resource groups: ${RESOURCE_GROUP_ARRAY[*]}"
    
    local subscriptions
    subscriptions=$(get_subscriptions)
    
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        
        local sub_name
        sub_name=$(get_sub_name "$sub")
        
        log_info "Checking subscription: $sub_name"
        
        # Get all resource groups in subscription
        local all_rgs
        all_rgs=$(az group list --subscription "$sub" --query '[].name' -o tsv 2>/dev/null || echo "")
        
        for rg_name in $all_rgs; do
            [[ -z "$rg_name" ]] && continue
            
            # Check if this RG matches our filter
            if ! matches_resource_group "$rg_name"; then
                continue
            fi
            
            # Check if RG exists
            if ! az group show --name "$rg_name" --subscription "$sub" &>/dev/null; then
                log_warning "Resource group not found or no access: $rg_name in subscription $sub"
                continue
            fi
            
            echo "  → Found Resource Group: $rg_name"
            log_to_file "FOUND" "Resource Group: $rg_name in subscription: $sub_name"
            
            # Add resource group to deletion list
            local rg_id="/subscriptions/$sub/resourceGroups/$rg_name"
            SUMMARY_ROWS+=("$rg_name|ResourceGroup|$sub_name|Targeted RG")
            ALL_IDS+=("$rg_id")
            RESOURCE_TYPES+=("$rg_id|ResourceGroup")
            RG_SUBSCRIPTION+=("$rg_id|$sub")
            RESOURCE_DETAILS+=("$rg_id|$rg_name|ResourceGroup|$sub_name")
            RESOURCES_FOUND=true
            
            # Discover all resources in this RG
            discover_all_resources_in_rg "$sub" "$sub_name" "$rg_name" "$rg_id"
        done
    done <<< "$subscriptions"
}

discover_all_resources_in_rg() {
    local sub="$1" sub_name="$2" rg_name="$3" rg_id="$4"
    
    # Skip regular resources if excluded
    if is_service_excluded "resources"; then
        log_debug "Skipping resource discovery in RG $rg_name (excluded via --exclude-service)"
        return
    fi
    
    log_debug "Discovering ALL resources in resource group: $rg_name"
    
    local resources
    resources=$(az resource list --subscription "$sub" --resource-group "$rg_name" -o json 2>/dev/null || echo '[]')
    
    while IFS= read -r resource; do
        [[ -z "$resource" ]] && continue
        
        local name type id tags
        name=$(jq -r '.name // ""' <<< "$resource")
        type=$(jq -r '.type // ""' <<< "$resource")
        id=$(jq -r '.id // ""' <<< "$resource")
        tags=$(jq -r '.tags // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' <<< "$resource")
        
        if [[ ! " ${ALL_IDS[@]} " =~ " ${id} " ]]; then
            # --- In resource group mode, include ALL resources in the RG --- 
            if [[ ${#NAME_PATTERNS[@]} -gt 0 ]]; then
                # If name patterns specified, check for matches
                local matched_pattern
                if ! matched_pattern=$(matches_any_pattern "$name"); then
                    continue
                fi
            fi
            
            echo "    ↳ Found Resource in RG: $name ($type)"
            log_to_file "FOUND" "Resource in RG: $name ($type) in RG: $rg_name"
            
            SUMMARY_ROWS+=("$name|$type|$sub_name|In RG: $rg_name")
            ALL_IDS+=("$id")
            
            RESOURCE_TYPES+=("$id|$type")
            RESOURCE_DETAILS+=("$id|$name|$type|$sub_name|$rg_id")
        fi
        
    done < <(jq -c '.[]' <<< "$resources")
}

discover_management_group_role_assignments() {
    # Skip if management groups are excluded
    if is_service_excluded "managementgroups"; then
        log_debug "Skipping management group role assignments discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Searching for management group role assignments..."
    
    local mgs
    mgs=$(az account management-group list --query '[].name' -o tsv 2>/dev/null || echo "")
    
    if [[ -z "$mgs" ]]; then
        log_debug "No management groups found or access denied"
        return
    fi
    
    for mg in $mgs; do
        log_debug "Checking management group: $mg"
        local assignments
        assignments=$(az role assignment list --scope "/providers/Microsoft.Management/managementGroups/$mg" -o json 2>/dev/null || echo '[]')
        
        while IFS= read -r assignment; do
            [[ -z "$assignment" ]] && continue
            
            local principal_name principal_id assignment_id principal_type scope
            principal_name=$(jq -r '.principalName // ""' <<< "$assignment")
            principal_id=$(jq -r '.principalId // ""' <<< "$assignment")
            assignment_id=$(jq -r '.id // ""' <<< "$assignment")
            principal_type=$(jq -r '.principalType // ""' <<< "$assignment")
            scope=$(jq -r '.scope // ""' <<< "$assignment")
            
            # --- Multi-pattern matching ---
            local matched_pattern
            if matched_pattern=$(matches_any_pattern "$principal_name"); then
                echo "  → Found Management Group Role Assignment: $(highlight_matches "$principal_name") ($principal_type on $mg)"
                log_to_file "FOUND" "Management Group Role Assignment: $principal_name ($principal_type on $mg)"
                SUMMARY_ROWS+=("$principal_name|ManagementGroupRoleAssignment|$mg|Scope: $scope")
                ALL_IDS+=("$assignment_id")
                RESOURCE_TYPES+=("$assignment_id|ManagementGroupRoleAssignment")
                RESOURCE_DETAILS+=("$assignment_id|$principal_name|ManagementGroupRoleAssignment|$mg")
                RESOURCES_FOUND=true
            fi
        done < <(jq -c '.[]' <<< "$assignments")
    done
}

discover_diagnostic_settings() {
    # Skip if diagnostics are excluded
    if is_service_excluded "diagnostics"; then
        log_debug "Skipping diagnostic settings discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Searching for diagnostic settings (parallel mode, max ${MAX_PARALLEL} concurrent)..."
    
    local subscriptions
    subscriptions=$(get_subscriptions)
    
    # --- Phase 1: Resource-level diagnostic settings (PARALLELIZED) ---
    local diag_tmp
    diag_tmp=$(mktemp -d)
    
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        
        local sub_name
        sub_name=$(get_sub_name "$sub")
        
        log_debug "Checking diagnostic settings in subscription: $sub_name"
        
        local resources
        resources=$(az resource list --subscription "$sub" --query '[].id' -o tsv 2>/dev/null || echo "")
        
        [[ -z "$resources" ]] && continue
        
        # Pre-filter resources by resource group (in parent shell, before spawning jobs)
        local filtered_resources=()
        while IFS= read -r resource_id; do
            [[ -z "$resource_id" ]] && continue
            
            local resource_group=""
            if [[ "$resource_id" =~ /resourceGroups/([^/]+)/ ]]; then
                resource_group="${BASH_REMATCH[1]}"
            fi
            
            if [[ ${#RESOURCE_GROUP_ARRAY[@]} -gt 0 ]] && [[ -n "$resource_group" ]]; then
                if ! matches_resource_group "$resource_group" >/dev/null; then
                    continue
                fi
            fi
            
            filtered_resources+=("$resource_id")
        done <<< "$resources"
        
        [[ ${#filtered_resources[@]} -eq 0 ]] && continue
        
        log_debug "Checking ${#filtered_resources[@]} resources for diagnostic settings in $sub_name (${MAX_PARALLEL} parallel)..."
        
        # Process in parallel batches
        local batch_count=0
        for resource_id in "${filtered_resources[@]}"; do
            (
                local my_pid=$BASHPID
                local diag_settings
                diag_settings=$(az monitor diagnostic-settings list --resource "$resource_id" -o json 2>/dev/null || echo '[]')
                
                # Extract matching settings and write to temp file
                echo "$diag_settings" | jq -c --arg rid "$resource_id" --arg sname "$sub_name" \
                    '.[]? | {name: .name, id: .id, resourceId: $rid, subName: $sname}' \
                    2>/dev/null > "$diag_tmp/r_${my_pid}.jsonl"
            ) &
            
            ((batch_count++))
            if [[ $batch_count -ge $MAX_PARALLEL ]]; then
                wait
                batch_count=0
            fi
        done
        wait  # Wait for remaining jobs in this subscription
    done <<< "$subscriptions"
    
    # Merge results from all parallel jobs
    local diag_found=0
    for result_file in "$diag_tmp"/r_*.jsonl; do
        [[ -f "$result_file" ]] || continue
        [[ -s "$result_file" ]] || continue  # Skip empty files
        
        while IFS= read -r setting; do
            [[ -z "$setting" || "$setting" == "null" ]] && continue
            
            local name id target_resource sub_name
            name=$(jq -r '.name // ""' <<< "$setting")
            id=$(jq -r '.id // ""' <<< "$setting")
            target_resource=$(jq -r '.resourceId // ""' <<< "$setting")
            sub_name=$(jq -r '.subName // ""' <<< "$setting")
            
            [[ -z "$name" || -z "$id" ]] && continue
            
            # Multi-pattern matching
            local matched_pattern
            if matched_pattern=$(matches_any_pattern "$name"); then
                if [[ ! " ${ALL_IDS[@]} " =~ " ${id} " ]]; then
                    echo "  → Found Diagnostic Setting: $(highlight_matches "$name") (Resource: $(basename "$target_resource"))"
                    log_to_file "FOUND" "Diagnostic Setting: $name (Resource: $(basename "$target_resource"))"
                    SUMMARY_ROWS+=("$name|DiagnosticSetting|$sub_name|Target: $(basename "$target_resource")")
                    ALL_IDS+=("$id")
                    RESOURCE_TYPES+=("$id|DiagnosticSetting")
                    RESOURCE_DETAILS+=("$id|$name|DiagnosticSetting|$sub_name|$target_resource")
                    RESOURCES_FOUND=true
                    ((diag_found++))
                fi
            fi
        done < "$result_file"
    done
    
    rm -rf "$diag_tmp"
    log_debug "Found $diag_found resource-level diagnostic settings"
    
    # --- Phase 2: Subscription-level diagnostic settings (fast, no parallelism needed) ---
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        
        local sub_name
        sub_name=$(get_sub_name "$sub")
        
        log_debug "Checking subscription-level diagnostic settings: $sub_name"
        
        local subscription_diagnostics
        subscription_diagnostics=$(az monitor diagnostic-settings subscription list --subscription "$sub" -o json 2>/dev/null || echo '[]')
        
        if ! jq -e '. | type == "array"' <<< "$subscription_diagnostics" >/dev/null 2>&1; then
            continue
        fi
        
        while IFS= read -r setting; do
            [[ -z "$setting" ]] && continue
            
            local name id
            name=$(jq -r '.name // ""' <<< "$setting")
            id=$(jq -r '.id // ""' <<< "$setting")
            
            [[ -z "$name" || -z "$id" ]] && continue
            
            # --- Multi-pattern matching ---
            local matched_pattern
            if matched_pattern=$(matches_any_pattern "$name"); then
                echo "  → Found Subscription Diagnostic Setting: $(highlight_matches "$name")"
                log_to_file "FOUND" "Subscription Diagnostic Setting: $name"
                SUMMARY_ROWS+=("$name|SubscriptionDiagnosticSetting|$sub_name|")
                ALL_IDS+=("$id")
                RESOURCE_TYPES+=("$id|SubscriptionDiagnosticSetting")
                RESOURCE_DETAILS+=("$id|$name|SubscriptionDiagnosticSetting|$sub_name")
                RESOURCES_FOUND=true
            fi
        done < <(jq -c '.[]?' <<< "$subscription_diagnostics")
    done <<< "$subscriptions"
}

discover_directory_diagnostic_settings() {
    # Skip if diagnostics are excluded
    if is_service_excluded "diagnostics"; then
        log_debug "Skipping directory diagnostic settings discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Discovering AAD tenant-level diagnostic settings..."
    
    local SETTINGS
    SETTINGS=$(az rest --method get \
        --url "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01-preview" \
        -o json 2>/dev/null || echo '{"value": []}')

    # --- Multi-pattern matching ---
    local FILTERED=""
    for pattern in "${NAME_PATTERNS[@]}"; do
        local matches
        matches=$(echo "$SETTINGS" | jq --arg kw "$pattern" -r '.value[] | select(.name | test($kw; "i")) | "\(.name)\t\(.id)"')
        if [[ -n "$matches" ]]; then
            FILTERED+="$matches"$'\n'
        fi
    done

    if [[ -z "$FILTERED" ]]; then
        log_debug "No AAD tenant-level diagnostic settings found for patterns: ${NAME_PATTERNS[*]}"
        return
    fi

    while IFS=$'\t' read -r name id; do
        [[ -z "$name" ]] && continue
        
        echo "  → Found Azure AD Diagnostic Setting: $(highlight_matches "$name") (Default Directory)"
        log_to_file "FOUND" "Azure AD Diagnostic Setting: $name (Default Directory)"
        SUMMARY_ROWS+=("$name|DirectoryDiagnosticSetting|Tenant|AAD Diagnostic")
        ALL_IDS+=("$id")
        
        RESOURCE_TYPES+=("$id|DirectoryDiagnosticSetting")
        RESOURCE_DETAILS+=("$id|$name|DirectoryDiagnosticSetting|Tenant|$id")
        
        RESOURCES_FOUND=true
    done <<< "$FILTERED"
}

discover_subscription_role_assignments() {
    local sub="$1"
    local sub_name="$2"
    
    # Skip if subscriptions are excluded
    if is_service_excluded "subscriptions"; then
        log_debug "Skipping subscription role assignments discovery (excluded via --exclude-service)"
        return
    fi
    
    log_debug "Checking role assignments in subscription: $sub_name"
    
    local assignments
    assignments=$(az role assignment list --subscription "$sub" -o json 2>/dev/null || echo '[]')
    
    while IFS= read -r assignment; do
        [[ -z "$assignment" ]] && continue
        
        local principal_name principal_id assignment_id principal_type scope
        principal_name=$(jq -r '.principalName // ""' <<< "$assignment")
        principal_id=$(jq -r '.principalId // ""' <<< "$assignment")
        assignment_id=$(jq -r '.id // ""' <<< "$assignment")
        principal_type=$(jq -r '.principalType // ""' <<< "$assignment")
        scope=$(jq -r '.scope // ""' <<< "$assignment")
        
        # --- Multi-pattern matching ---
        local matched_pattern
        if matched_pattern=$(matches_any_pattern "$principal_name"); then
            echo "  → Found Subscription Role Assignment: $(highlight_matches "$principal_name") ($principal_type in $sub_name)"
            log_to_file "FOUND" "Subscription Role Assignment: $principal_name ($principal_type in $sub_name)"
            SUMMARY_ROWS+=("$principal_name|SubscriptionRoleAssignment|$sub_name|Scope: $scope")
            ALL_IDS+=("$assignment_id")
            RESOURCE_TYPES+=("$assignment_id|SubscriptionRoleAssignment")
            RESOURCE_DETAILS+=("$assignment_id|$principal_name|SubscriptionRoleAssignment|$sub_name")
            RESOURCES_FOUND=true
        fi
    done < <(jq -c '.[]' <<< "$assignments")
}

discover_policy_assignments() {
    # Skip if policies are excluded
    if is_service_excluded "policies"; then
        log_debug "Skipping policy assignments discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Searching for policy assignments..."
    
    local mgs
    mgs=$(az account management-group list --query '[].name' -o tsv 2>/dev/null || echo "")
    
    for mg in $mgs; do
        log_debug "Checking policy assignments in management group: $mg"
        local mg_assignments
        mg_assignments=$(az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/$mg" -o json 2>/dev/null || echo '[]')
        
        while IFS= read -r assignment; do
            [[ -z "$assignment" ]] && continue
            
            local displayName name scope id
            displayName=$(jq -r '.displayName // ""' <<< "$assignment")
            name=$(jq -r '.name // ""' <<< "$assignment")
            scope=$(jq -r '.scope // ""' <<< "$assignment")
            id=$(jq -r '.id // ""' <<< "$assignment")
            
            # --- Multi-pattern matching ---
            local matched_pattern
            if matched_pattern=$(matches_any_pattern "$displayName") || matched_pattern=$(matches_any_pattern "$name"); then
                echo "  → Found Management Group Policy Assignment: $(highlight_matches "$displayName") (Scope: $scope)"
                log_to_file "FOUND" "Management Group Policy Assignment: $displayName (Scope: $scope)"
                SUMMARY_ROWS+=("$displayName|PolicyAssignment|$scope|Name: $name")
                ALL_IDS+=("$id")
                RESOURCE_TYPES+=("$id|PolicyAssignment")
                RESOURCE_DETAILS+=("$id|$displayName|PolicyAssignment|$scope|$name")
                RESOURCES_FOUND=true
            fi
        done < <(jq -c '.[]' <<< "$mg_assignments")
    done
    
    local subscriptions
    subscriptions=$(get_subscriptions)
    
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        
        local sub_name
        sub_name=$(get_sub_name "$sub")
        
        log_debug "Checking policy assignments in subscription: $sub_name"
        local sub_assignments
        sub_assignments=$(az policy assignment list --subscription "$sub" -o json 2>/dev/null || echo '[]')
        
        while IFS= read -r assignment; do
            [[ -z "$assignment" ]] && continue
            
            local displayName name scope id
            displayName=$(jq -r '.displayName // ""' <<< "$assignment")
            name=$(jq -r '.name // ""' <<< "$assignment")
            scope=$(jq -r '.scope // ""' <<< "$assignment")
            id=$(jq -r '.id // ""' <<< "$assignment")
            
            # --- Multi-pattern matching ---
            local matched_pattern
            if matched_pattern=$(matches_any_pattern "$displayName") || matched_pattern=$(matches_any_pattern "$name"); then
                echo "  → Found Subscription Policy Assignment: $(highlight_matches "$displayName") (Scope: $scope)"
                log_to_file "FOUND" "Subscription Policy Assignment: $displayName (Scope: $scope)"
                SUMMARY_ROWS+=("$displayName|PolicyAssignment|$sub_name|Name: $name")
                ALL_IDS+=("$id")
                RESOURCE_TYPES+=("$id|PolicyAssignment")
                RESOURCE_DETAILS+=("$id|$displayName|PolicyAssignment|$scope|$name")
                RESOURCES_FOUND=true
            fi
        done < <(jq -c '.[]' <<< "$sub_assignments")
    done <<< "$subscriptions"
}

discover_policy_remediations() {
    # Skip if policies are excluded
    if is_service_excluded "policies"; then
        log_debug "Skipping policy remediations discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Searching for policy remediations..."
    
    local subscriptions
    subscriptions=$(get_subscriptions)
    
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        
        local sub_name
        sub_name=$(get_sub_name "$sub")
        
        local remediations
        remediations=$(az policy remediation list --subscription "$sub" -o json 2>/dev/null || echo '[]')
        
        while IFS= read -r remediation; do
            [[ -z "$remediation" ]] && continue
            
            local name id
            name=$(jq -r '.name // ""' <<< "$remediation")
            id=$(jq -r '.id // ""' <<< "$remediation")
            
            # --- Multi-pattern matching ---
            local matched_pattern
            if matched_pattern=$(matches_any_pattern "$name"); then
                echo "  → Found Policy Remediation: $(highlight_matches "$name") ($sub_name)"
                log_to_file "FOUND" "Policy Remediation: $name ($sub_name)"
                SUMMARY_ROWS+=("$name|PolicyRemediation|$sub_name|")
                ALL_IDS+=("$id")
                RESOURCE_TYPES+=("$id|PolicyRemediation")
                RESOURCE_DETAILS+=("$id|$name|PolicyRemediation|$sub_name")
                RESOURCES_FOUND=true
            fi
        done < <(jq -c '.[]' <<< "$remediations")
    done <<< "$subscriptions"
}

discover_management_group_deployments() {
    # Skip if management groups are excluded
    if is_service_excluded "managementgroups"; then
        log_debug "Skipping management group deployments discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Searching for management group deployments..."
    
    local mgs
    mgs=$(az account management-group list --query '[].name' -o tsv 2>/dev/null || echo "")
    
    if [[ -z "$mgs" ]]; then
        log_debug "No management groups found or access denied"
        return
    fi
    
    for mg in $mgs; do
        local deployments
        deployments=$(az deployment mg list --management-group-id "$mg" -o json 2>/dev/null || echo '[]')
        
        while IFS= read -r deployment; do
            [[ -z "$deployment" ]] && continue
            
            local name id
            name=$(jq -r '.name // ""' <<< "$deployment")
            id=$(jq -r '.id // ""' <<< "$deployment")
            
            # --- Multi-pattern matching ---
            local matched_pattern
            if matched_pattern=$(matches_any_pattern "$name"); then
                echo "  → Found Management Group Deployment: $(highlight_matches "$name") (MG: $mg)"
                log_to_file "FOUND" "Management Group Deployment: $name (MG: $mg)"
                SUMMARY_ROWS+=("$name|ManagementGroupDeployment|$mg|")
                ALL_IDS+=("$id")
                RESOURCE_TYPES+=("$id|ManagementGroupDeployment")
                RESOURCE_DETAILS+=("$id|$name|ManagementGroupDeployment|$mg")
                RESOURCES_FOUND=true
            fi
        done < <(jq -c '.[]' <<< "$deployments")
    done
}

discover_service_principals() {
    # Skip if service principals are excluded
    if is_service_excluded "serviceprincipals"; then
        log_debug "Skipping service principals discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Searching for service principals..."

    # --- Fetch all SPs once --- 
    local all_sps
    all_sps=$(az ad sp list --all --query "[].[displayName,id,appId,publisherName]" -o tsv 2>/dev/null)

    if [[ -z "$all_sps" ]]; then
        log_debug "No service principals returned from Azure"
        return
    fi

    local found=""

    while IFS=$'\t' read -r spName spId appId publisher; do
        [[ -z "$spName" ]] && continue

        # --- Exclude known Microsoft system SPs --- 
        case "$spName" in
            Microsoft*|Azure*|Bot*|Office* )
                continue
                ;;
            *)
                [[ "$publisher" == "Microsoft Services" ]] && continue
                ;;
        esac

        # --- Match against user-defined patterns (case-insensitive) --- 
        for pattern in "${NAME_PATTERNS[@]}"; do
            if [[ "$(normalize "$spName")" == *"$(normalize "$pattern")"* ]]; then
                echo "  → Found Service Principal: $(highlight_matches "$spName") (ObjectID: $spId)"
                log_to_file "FOUND" "Service Principal: $spName (ObjectID: $spId)"
                SUMMARY_ROWS+=("$spName|EnterpriseApplication|Tenant|AppID: $appId")
                ALL_IDS+=("$spId")
                RESOURCE_TYPES+=("$spId|EnterpriseApplication")
                RESOURCE_DETAILS+=("$spId|$spName|EnterpriseApplication|Tenant|$spId")
                RESOURCES_FOUND=true
                found="yes"
            fi
        done
    done <<< "$all_sps"

    [[ -z "$found" ]] && log_debug "No matching resources found"
}

discover_custom_roles_enhanced() {
    # Skip if roles are excluded
    if is_service_excluded "roles"; then
        log_debug "Skipping custom roles discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Searching for custom roles..."
    
    # --- Build query for multi-pattern support ---
    local roles=""
    for pattern in "${NAME_PATTERNS[@]}"; do
        local matches
        matches=$(az role definition list --custom-role-only true -o json | jq -r ".[] | select((.roleName|test(\"$pattern\";\"i\"))) | [.roleName,.name,(.assignableScopes|length)] | @tsv")
        if [[ -n "$matches" ]]; then
            roles+="$matches"$'\n'
        fi
    done
    
    if [[ -z "$roles" ]]; then
        log_debug "No custom roles found matching patterns: ${NAME_PATTERNS[*]}"
        return
    fi
    
    while IFS=$'\t' read -r roleName roleId scope_count; do
        [[ -z "$roleName" ]] && continue
        
        local clean_roleName=$(echo "$roleName" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
        
        local displayed_name
        displayed_name=$(highlight_matches "$clean_roleName")
        
        echo "  → Found Custom Role: $displayed_name ($roleId)"
        log_to_file "FOUND" "Custom Role: $clean_roleName ($roleId)"
        
        SUMMARY_ROWS+=("$clean_roleName|CustomRole|Tenant|Scopes: $scope_count")
        ALL_IDS+=("$roleId")
        RESOURCE_TYPES+=("$roleId|CustomRole")
        RESOURCE_DETAILS+=("$roleId|$clean_roleName|CustomRole|Tenant|$roleId")
        RESOURCES_FOUND=true
    done <<< "$roles"
}

discover_role_assignments_for_custom_roles() {
    # Skip if roles are excluded
    if is_service_excluded "roles"; then
        log_debug "Skipping role assignments discovery (excluded via --exclude-service)"
        return
    fi
    
    log_info "Discovering role assignments for custom roles..."
    
    # --- Get custom roles matching any of our patterns ---
    local custom_roles=""
    for pattern in "${NAME_PATTERNS[@]}"; do
        local matches
        matches=$(az role definition list --custom-role-only true -o json 2>/dev/null | jq -r ".[] | select(.roleName | test(\"$pattern\"; \"i\")) | .name")
        if [[ -n "$matches" ]]; then
            custom_roles+="$matches"$'\n'
        fi
    done
    
    if [[ -z "$custom_roles" ]]; then
        log_debug "No custom roles found for patterns: ${NAME_PATTERNS[*]}"
        return
    fi
    
    for role_id in $custom_roles; do
        [[ -z "$role_id" ]] && continue
        
        local role_info
        role_info=$(az role definition show --name "$role_id" -o json 2>/dev/null || echo "{}")
        local role_name
        role_name=$(echo "$role_info" | jq -r '.roleName // ""')
        
        if [[ -z "$role_name" ]]; then
            continue
        fi
        
        log_debug "Checking assignments for role: $role_name"
        
        local assignments
        assignments=$(az role assignment list --all --query "[?contains(roleDefinitionId, '$role_id')]" -o json 2>/dev/null || echo '[]')
        
        while IFS= read -r assignment; do
            [[ -z "$assignment" ]] && continue
            
            local principal_name principal_id assignment_id principal_type scope
            principal_name=$(jq -r '.principalName // ""' <<< "$assignment")
            principal_id=$(jq -r '.principalId // ""' <<< "$assignment")
            assignment_id=$(jq -r '.id // ""' <<< "$assignment")
            principal_type=$(jq -r '.principalType // ""' <<< "$assignment")
            scope=$(jq -r '.scope // ""' <<< "$assignment")
            
            # --- Multi-pattern matching ---
            local matched_pattern
            if matched_pattern=$(matches_any_pattern "$principal_name"); then
                echo "  → Found Role Assignment: $(highlight_matches "$principal_name") ($principal_type for $role_name)"
                log_to_file "FOUND" "Role Assignment: $principal_name ($principal_type for $role_name)"
                SUMMARY_ROWS+=("$principal_name|RoleAssignment|$scope|Role: $role_name")
                ALL_IDS+=("$assignment_id")
                RESOURCE_TYPES+=("$assignment_id|RoleAssignment")
                RESOURCE_DETAILS+=("$assignment_id|$principal_name|RoleAssignment|$scope|$role_name")
                RESOURCES_FOUND=true
            fi
        done < <(jq -c '.[]' <<< "$assignments")
        
        local unknown_assignments
        unknown_assignments=$(az role assignment list --all -o json 2>/dev/null | jq -r ".[] | select(.roleDefinitionName==\"Unknown\" and (.roleDefinitionId|contains(\"$role_id\"))) | .id" 2>/dev/null || echo "")
        
        for assignment_id in $unknown_assignments; do
            [[ -z "$assignment_id" ]] && continue
            
            if [[ ! " ${ALL_IDS[@]} " =~ " ${assignment_id} " ]]; then
                echo "  → Found Unknown Role Assignment: $role_name (Orphaned)"
                log_to_file "FOUND" "Unknown Role Assignment: $role_name (Orphaned)"
                SUMMARY_ROWS+=("$role_name|UnknownRoleAssignment|Orphaned|Role: $role_name")
                ALL_IDS+=("$assignment_id")
                RESOURCE_TYPES+=("$assignment_id|UnknownRoleAssignment")
                RESOURCE_DETAILS+=("$assignment_id|$role_name|UnknownRoleAssignment|Orphaned|$role_name")
                RESOURCES_FOUND=true
            fi
        done
    done
}

# --- Enhanced Role Assignment Deletion ---
delete_role_assignment_enhanced() {
    local ROLE_ID="$1"
    local ROLE_NAME="$2"

    log_info "Checking for role assignments linked to role: ${ROLE_NAME} (${ROLE_ID})"

    local ASSIGNMENTS
    ASSIGNMENTS=$(az role assignment list --all --query "[?contains(roleDefinitionId,'${ROLE_ID}')]" -o json | jq -r '.[]?.id // empty')

    if [[ -z "$ASSIGNMENTS" ]]; then
        log_info "No direct matches found. Checking for Unknown-type role assignments..."
        ASSIGNMENTS=$(az role assignment list --all -o json | jq -r ".[] | select(.roleDefinitionName==\"Unknown\" and (.roleDefinitionId|contains(\"${ROLE_ID}\"))) | .id")
    fi

    if [[ -z "$ASSIGNMENTS" ]]; then
        log_info "No role assignments existed for ${ROLE_NAME}."
        return
    fi

    log_info "Found assignments:"
    echo "$ASSIGNMENTS"

    while read -r ASSIGN_ID; do
        [[ -z "$ASSIGN_ID" ]] && continue
        log_info "Deleting role assignment: ${ASSIGN_ID}"
        az role assignment delete --ids "$ASSIGN_ID" || log_warning "Failed to delete $ASSIGN_ID (might be orphaned)"
    done <<< "$ASSIGNMENTS"

    local REMAINING
    REMAINING=$(az role assignment list --all --query "[?contains(roleDefinitionId,'${ROLE_ID}')]" -o tsv)
    if [[ -z "$REMAINING" ]]; then
        log_success "All role assignments for ${ROLE_NAME} deleted successfully"
    else
        log_error "Some role assignments still remain for ${ROLE_NAME}"
    fi
}

delete_directory_diagnostic_setting() {
    local setting_id="$1"
    local setting_name="$2"
    
    log_special "Deleting Azure AD Diagnostic Setting: $setting_name (Default Directory)"
    
    local result
    result=$(az rest --method delete \
        --url "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${setting_name}?api-version=2017-04-01-preview" \
        2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "Successfully deleted Azure AD Diagnostic Setting: $setting_name"
        return 0
    else
        log_debug "Checking if AAD diagnostic setting was actually deleted..."
        local check_result
        check_result=$(az rest --method get \
            --url "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${setting_name}?api-version=2017-04-01-preview" \
            2>&1)
        
        if [[ "$check_result" == *"NotFound"* ]] || [[ "$check_result" == *"ResourceNotFound"* ]]; then
            log_success "Azure AD Diagnostic Setting deleted successfully (verified): $setting_name"
            return 0
        else
            log_error "❌ Failed to delete Azure AD Diagnostic Setting: $setting_name"
            log_error "Error: $result"
            
            if [[ "$result" == *"Permission"* ]] || [[ "$result" == *"authorized"* ]]; then
                log_error "🔐 Insufficient permissions to delete Azure AD diagnostic settings."
                log_error "Required permission: microsoft.aadiam/diagnosticSettings/delete"
                log_error "Contact your Azure administrator for the required permissions."
            elif [[ "$result" == *"not found"* ]]; then
                log_warning "⚠️  Azure AD diagnostic setting not found (may have been deleted already)"
                return 0
            fi
            
            return 1
        fi
    fi
}

delete_custom_role_enhanced() {
    local role_id="$1"
    local role_name="$2"
    
    log_info "Attempting to delete Custom Role: $role_name (ID: $role_id)"
    
    local role_info
    role_info=$(az role definition list --custom-role-only true --query "[?name=='$role_id'] | [0]" -o json 2>/dev/null || echo "{}")
    
    if [[ "$role_info" == "{}" || "$role_info" == "null" ]]; then
        log_warning "Custom Role not found: $role_name (ID: $role_id)"
        return 1
    fi
    
    local actual_role_name
    actual_role_name=$(echo "$role_info" | jq -r '.roleName // ""')
    local role_scope
    role_scope=$(echo "$role_info" | jq -r '.assignableScopes[0] // ""')
    
    if [[ -z "$actual_role_name" ]]; then
        log_error "Could not retrieve role information for ID: $role_id"
        return 1
    fi
    
    log_info "Found Custom Role: $actual_role_name (Scope: $role_scope)"
    
    local result
    local exit_code
    
    if [[ -n "$role_scope" && "$role_scope" != "null" ]]; then
        log_info "Deleting role using scope: $role_scope"
        result=$(az role definition delete --name "$role_id" --scope "$role_scope" 2>&1)
        exit_code=$?
    else
        result=$(az role definition delete --name "$role_id" 2>&1) || true
        exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
            local current_sub
            current_sub=$(az account show --query id -o tsv)
            role_scope="/subscriptions/$current_sub"
            log_info "Retrying with subscription scope: $role_scope"
            result=$(az role definition delete --name "$role_id" --scope "$role_scope" 2>&1)
            exit_code=$?
        fi
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "Successfully deleted Custom Role: $actual_role_name"
        return 0
    else
        log_error "Failed to delete Custom Role: $actual_role_name"
        log_warning "Error: $result"
        
        if [[ "$result" == *"scope"* ]]; then
            log_info "Trying alternative role deletion approach..."
            try_alternative_role_deletion "$role_id" "$role_name"
        fi
    fi
}

try_alternative_role_deletion() {
    local role_id="$1"
    local role_name="$2"
    
    log_info "Trying alternative method to delete role: $role_name"
    
    local all_custom_roles
    all_custom_roles=$(az role definition list --custom-role-only true -o json 2>/dev/null || echo "[]")
    
    local role_info
    role_info=$(echo "$all_custom_roles" | jq -r ".[] | select(.name == \"$role_id\")")
    
    if [[ -z "$role_info" || "$role_info" == "null" ]]; then
        log_warning "Role not found in custom roles list: $role_name"
        return 1
    fi
    
    local scopes
    scopes=$(echo "$role_info" | jq -r '.assignableScopes[]?')
    
    if [[ -z "$scopes" ]]; then
        log_error "No assignable scopes found for role: $role_name"
        return 1
    fi
    
    local deleted=false
    while IFS= read -r scope; do
        [[ -z "$scope" ]] && continue
        log_info "Trying to delete with scope: $scope"
        local result
        result=$(az role definition delete --name "$role_id" --scope "$scope" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            log_success "Successfully deleted Custom Role: $role_name using scope: $scope"
            deleted=true
            break
        else
            log_warning "Failed to delete with scope $scope: $result"
        fi
    done <<< "$scopes"
    
    if [[ "$deleted" == true ]]; then
        return 0
    else
        log_error "All deletion attempts failed for role: $role_name"
        return 1
    fi
}

# --- Deletion Functions ---
delete_with_retry() {
    local id="$1"
    local type="$2"
    local max_retries=3
    local retry_delay=10
    
    for ((retry=1; retry<=max_retries; retry++)); do
        if az resource delete --ids "$id" --no-wait 2>/dev/null; then
            log_success "Delete command issued for $type: $(basename "$id")"
            return 0
        else
            log_warning "Attempt $retry failed for $type: $(basename "$id")"
            if [[ $retry -eq $max_retries ]]; then
                log_error "Failed to delete $type after $max_retries attempts: $(basename "$id")"
                return 1
            fi
            sleep $retry_delay
        fi
    done
}

delete_management_group_role_assignment() {
    local assignment_id="$1"
    local assignment_name="$2"
    
    log_special "Deleting Management Group Role Assignment: $assignment_name"
    
    if az role assignment delete --ids "$assignment_id" 2>/dev/null; then
        log_success "Deleted Management Group Role Assignment: $assignment_name"
        return 0
    else
        log_error "Failed to delete Management Group Role Assignment: $assignment_name"
        return 1
    fi
}

delete_subscription_role_assignment() {
    local assignment_id="$1"
    local assignment_name="$2"
    
    log_special "Deleting Subscription Role Assignment: $assignment_name"
    
    if az role assignment delete --ids "$assignment_id" 2>/dev/null; then
        log_success "Deleted Subscription Role Assignment: $assignment_name"
        return 0
    else
        log_error "Failed to delete Subscription Role Assignment: $assignment_name"
        return 1
    fi
}

delete_policy_assignment() {
    local assignment_id="$1"
    local assignment_name="$2"
    local assignment_scope="$3"
    
    log_special "Deleting Policy Assignment: $assignment_name (Scope: $assignment_scope)"
    
    local result
    result=$(az policy assignment delete --name "$(basename "$assignment_id")" --scope "$assignment_scope" 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "Successfully deleted Policy Assignment: $assignment_name"
        return 0
    else
        log_error "❌ Failed to delete Policy Assignment: $assignment_name"
        log_error "Exit code: $exit_code"
        log_error "Error output: $result"
        
        if [[ "$result" == *"Permission"* ]] || [[ "$result" == *"authorized"* ]] || [[ "$result" == *"access"* ]]; then
            log_error "🔐 Insufficient permissions to delete policy assignment."
            log_error "Required permission: Microsoft.Authorization/policyAssignments/delete"
            log_error "Contact your Azure administrator for the required permissions."
        elif [[ "$result" == *"not found"* ]]; then
            log_warning "⚠️  Policy assignment not found (may have been deleted by another process)"
            return 0
        else
            log_error "💥 Unknown error occurred. Please check the error message above."
        fi
        
        return 1
    fi
}

delete_policy_remediation() {
    local remediation_id="$1"
    local remediation_name="$2"
    
    log_special "Deleting Policy Remediation: $remediation_name"
    
    if az policy remediation delete --ids "$remediation_id" 2>/dev/null; then
        log_success "Deleted Policy Remediation: $remediation_name"
        return 0
    else
        log_error "Failed to delete Policy Remediation: $remediation_name"
        return 1
    fi
}

delete_management_group_deployment() {
    local deployment_id="$1"
    local deployment_name="$2"
    local mg_id="$3"
    
    log_special "Deleting Management Group Deployment: $deployment_name"
    
    if az deployment mg delete --name "$deployment_name" --management-group-id "$mg_id" 2>/dev/null; then
        log_success "Deleted Management Group Deployment: $deployment_name"
        return 0
    else
        log_error "Failed to delete Management Group Deployment: $deployment_name"
        return 1
    fi
}

delete_service_principal() {
    local sp_id="$1"
    local sp_name="$2"
    
    log_info "Processing Service Principal: $sp_name"
    
    if ! az ad sp show --id "$sp_id" &>/dev/null; then
        log_success "Service Principal already deleted: $sp_name"
        return 0
    fi
    
    local assignment_count=0
    while IFS= read -r assignment_id; do
        [[ -z "$assignment_id" ]] && continue
        ((assignment_count++))
        log_debug "Removing role assignment: $assignment_id"
        az role assignment delete --ids "$assignment_id" 2>/dev/null || true
    done < <(az role assignment list --assignee "$sp_id" --query "[].id" -o tsv 2>/dev/null)
    
    if [[ $assignment_count -gt 0 ]]; then
        log_success "Removed $assignment_count role assignments from $sp_name"
    fi
    
    local app_id
    app_id=$(az ad sp show --id "$sp_id" --query "appId" -o tsv 2>/dev/null || echo "")
    if [[ -n "$app_id" ]]; then
        log_debug "Attempting to delete associated application: $app_id"
        if az ad app delete --id "$app_id" 2>/dev/null; then
            log_success "Deleted associated application: $app_id"
            sleep 5
        fi
    fi
    
    if az ad sp delete --id "$sp_id" 2>/dev/null; then
        log_success "Deleted Service Principal: $sp_name"
    else
        log_error "Failed to delete Service Principal: $sp_name"
        return 1
    fi
}

delete_resource_group() {
    local rg_id="$1"
    local rg_name="$2"
    local sub_id="$3"
    
    log_warning "Resource Group detected: $rg_name (contains ALL resources within it)"
    
    # --- Check if this resource group contains any excluded resources --- 
    local has_excluded=false
    local excluded_list=""
    
    for item in "${RG_EXCLUDED_RESOURCES[@]}"; do
        if [[ "$item" == "$rg_name|"* ]]; then
            has_excluded=true
            IFS="|" read -r _ excluded_resource excluded_type <<< "$item"
            if [[ -z "$excluded_list" ]]; then
                excluded_list="$excluded_resource ($excluded_type)"
            else
                excluded_list+=", $excluded_resource ($excluded_type)"
            fi
        fi
    done
    
    if [[ "$has_excluded" == true ]]; then
        log_warning "   SKIPPING Resource Group deletion: $rg_name"
        log_warning "   Reason: Contains excluded resources: $excluded_list"
        log_warning "   Delete the excluded resources first or remove them from exclude patterns"
        return 0
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN: Would delete resource group: $rg_name"
        return 0
    fi
    
    if [[ "$DELETE_MODE" == true ]]; then
        read -p "Delete this resource group and ALL its contents? (yes/no): " rg_confirm
        if [[ "$rg_confirm" != "yes" ]]; then
            log_warning "Skipped deletion of Resource Group: $rg_name"
            return 0
        fi
    fi
    
    if az group delete --name "$rg_name" --subscription "$sub_id" --yes --no-wait 2>/dev/null; then
        log_success "Delete command issued for Resource Group: $rg_name"
        return 0
    else
        log_error "Failed to delete Resource Group: $rg_name"
        return 1
    fi
}

# --- Initialize Logging ---
init_logging() {
    if [[ "$LOG_ENABLED" == true ]] && [[ -n "$LOG_FILE" ]]; then
        # Create directory if it doesn't exist
        local log_dir=$(dirname "$LOG_FILE")
        if [[ ! -d "$log_dir" ]] && [[ "$log_dir" != "." ]] && [[ -n "$log_dir" ]]; then
            mkdir -p "$log_dir" 2>/dev/null || {
                log_warning "Cannot create log directory: $log_dir. Using current directory."
                LOG_FILE=$(basename "$LOG_FILE")
            }
        fi
        
        # Check if we can write to the log file
        if [[ "$APPEND_LOG" == true ]] && [[ -f "$LOG_FILE" ]]; then
            # Append mode: check if we can append
            if [[ ! -w "$LOG_FILE" ]]; then
                log_warning "Cannot write to log file: $LOG_FILE. Disabling logging."
                LOG_ENABLED=false
                LOG_FILE=""
                return
            fi
        else
            # Overwrite mode or new file: check if we can create/write
            if ! touch "$LOG_FILE" 2>/dev/null; then
                log_warning "Cannot write to log file: $LOG_FILE. Disabling logging."
                LOG_ENABLED=false
                LOG_FILE=""
                return
            fi
        fi
        
        # --- Write header based on mode --- 
        if [[ "$APPEND_LOG" == true ]] && [[ -f "$LOG_FILE" ]]; then
            # Append mode: add separator and new execution header
            echo "" >> "$LOG_FILE"
            echo "==================================================================================" >> "$LOG_FILE"
            echo "NEW EXECUTION - APPENDED LOG" >> "$LOG_FILE"
            echo "==================================================================================" >> "$LOG_FILE"
            log_audit "Appending to existing log file: $LOG_FILE"
        else
            # Overwrite mode (default): create new log file
            echo "==================================================================================" > "$LOG_FILE"
            echo "AZURE RESOURCE CLEANUP AUDIT LOG" >> "$LOG_FILE"
            echo "==================================================================================" >> "$LOG_FILE"
        fi
        
        # --- Common header information --- 
        echo "Execution Start  : $(date '+%Y-%m-%d %H:%M:%S %Z')" >> "$LOG_FILE"
        echo "User             : $(whoami)@$(hostname)" >> "$LOG_FILE"
        
        # --- Get Azure user info --- 
        local az_user=$(az account show --query 'user.name' -o tsv 2>/dev/null || echo "Unknown")
        echo "Azure User       : $az_user" >> "$LOG_FILE"
        
        local tenant_id=$(az account show --query 'tenantId' -o tsv 2>/dev/null || echo "Unknown")
        echo "Tenant ID        : $tenant_id" >> "$LOG_FILE"
        
        if [[ -n "$SUBSCRIPTION_ID" ]]; then
            local sub_name=$(get_sub_name "$SUBSCRIPTION_ID")
            echo "Subscription     : $SUBSCRIPTION_ID ($sub_name)" >> "$LOG_FILE"
        else
            echo "Subscription     : All enabled subscriptions" >> "$LOG_FILE"
        fi
        
        # Add exclude subscription info
        if [[ -n "$EXCLUDE_SUBSCRIPTIONS" ]]; then
            echo "Exclude Subs     : $EXCLUDE_SUBSCRIPTIONS" >> "$LOG_FILE"
            echo "Exclude Count    : ${#EXCLUDE_SUBSCRIPTION_ARRAY[@]}" >> "$LOG_FILE"
        else
            echo "Exclude Subs     : None" >> "$LOG_FILE"
        fi
        
        echo "Mode             : $([[ "$DRY_RUN" == true ]] && echo "DRY-RUN" || echo "DELETE")" >> "$LOG_FILE"
        echo "Log Mode         : $([[ "$APPEND_LOG" == true ]] && echo "APPEND" || echo "OVERWRITE")" >> "$LOG_FILE"
        
        if [[ -n "$TAG_FILTER" ]]; then
            echo "Search Type      : Tag Filter" >> "$LOG_FILE"
            echo "Tag Filter       : $TAG_FILTER" >> "$LOG_FILE"
        elif [[ -n "$RESOURCE_GROUPS" ]]; then
            echo "Search Type      : Resource Group Filter" >> "$LOG_FILE"
            echo "Resource Groups  : $RESOURCE_GROUPS" >> "$LOG_FILE"
        elif [[ -n "$NAME_PATTERN" ]]; then
            echo "Search Type      : Name Pattern" >> "$LOG_FILE"
            echo "Patterns         : $NAME_PATTERN" >> "$LOG_FILE"
        fi
        
        if [[ -n "$EXCLUDE_PATTERNS" ]]; then
            echo "Exclude Patterns : $EXCLUDE_PATTERNS" >> "$LOG_FILE"
        else
            echo "Exclude Patterns : None" >> "$LOG_FILE"
        fi
        
        echo "Log File         : $LOG_FILE" >> "$LOG_FILE"
        echo "==================================================================================" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        
        log_audit "Audit logging enabled: $LOG_FILE ($([[ "$APPEND_LOG" == true ]] && echo "APPEND" || echo "OVERWRITE") mode)"
        log_to_file "INFO" "Logging initialized"
    fi
}

# --- Check Log File Accessibility ---
check_log_file_access() {
    local log_file="$1"
    local mode="$2"  # "append" or "overwrite"
    
    if [[ "$mode" == "append" ]]; then
        if [[ -f "$log_file" ]]; then
            if [[ ! -w "$log_file" ]]; then
                return 1  # Cannot append
            fi
        else
            # File doesn't exist, check if we can create it
            local log_dir=$(dirname "$log_file")
            if [[ ! -d "$log_dir" ]] && [[ "$log_dir" != "." ]] && [[ -n "$log_dir" ]]; then
                mkdir -p "$log_dir" 2>/dev/null || return 1
            fi
            touch "$log_file" 2>/dev/null || return 1
        fi
    else
        # Overwrite mode
        local log_dir=$(dirname "$log_file")
        if [[ ! -d "$log_dir" ]] && [[ "$log_dir" != "." ]] && [[ -n "$log_dir" ]]; then
            mkdir -p "$log_dir" 2>/dev/null || return 1
        fi
        touch "$log_file" 2>/dev/null || return 1
    fi
    
    return 0
}

# --- Helper function to apply exclude filters ---
apply_exclude_filters() {
    local original_count=${#ALL_IDS[@]}
    declare -a FILTERED_IDS=()
    declare -a FILTERED_SUMMARY_ROWS=()
    
    # Create arrays to track excluded resources with their details
    declare -a NEW_EXCLUDED_IDS=()
    declare -a NEW_EXCLUDED_DETAILS=()
    declare -a NEW_EXCLUDED_SUMMARY_ROWS=()
    
    # Start with existing excluded IDs if any
    if [[ ${#EXCLUDED_IDS[@]} -gt 0 ]]; then
        NEW_EXCLUDED_IDS=("${EXCLUDED_IDS[@]}")
        # Try to preserve existing excluded details if available
        if [[ ${#EXCLUDED_RESOURCE_DETAILS[@]} -gt 0 ]]; then
            NEW_EXCLUDED_DETAILS=("${EXCLUDED_RESOURCE_DETAILS[@]}")
        fi
        if [[ ${#EXCLUDED_SUMMARY_ROWS[@]} -gt 0 ]]; then
            NEW_EXCLUDED_SUMMARY_ROWS=("${EXCLUDED_SUMMARY_ROWS[@]}")
        fi
    fi
    
    for i in "${!ALL_IDS[@]}"; do
        local id="${ALL_IDS[$i]}"
        local row="${SUMMARY_ROWS[$i]}"
        
        # Get resource details
        local resource_type=""
        local resource_name=""
        local resource_details=""
        
        # Try to get from RESOURCE_TYPES
        for item in "${RESOURCE_TYPES[@]}"; do
            if [[ "$item" == "$id|"* ]]; then
                resource_type="${item#*|}"
                break
            fi
        done
        
        # Try to get from RESOURCE_DETAILS
        for item in "${RESOURCE_DETAILS[@]}"; do
            if [[ "$item" == "$id|"* ]]; then
                IFS="|" read -r _ name _ _ _ <<< "$item"
                resource_name="$name"
                resource_details="$item"
                break
            fi
        done
        
        # Clean resource name for comparison
        clean_resource_name=$(echo "$resource_name" | sed -E 's/\x1B\[[0-9;]*[mGK]//g' | xargs)
        
        # Check if already excluded (from previous runs)
        local already_excluded=false
        for excluded_id in "${NEW_EXCLUDED_IDS[@]}"; do
            if [[ "$id" == "$excluded_id" ]]; then
                already_excluded=true
                break
            fi
        done
        
        if [[ "$already_excluded" == true ]]; then
            # Already excluded, keep it excluded
            continue
        fi
        
        # Check if should be excluded now
        if should_exclude "$clean_resource_name" "$resource_type" "$id"; then
            NEW_EXCLUDED_IDS+=("$id")
            if [[ -n "$resource_details" ]]; then
                NEW_EXCLUDED_DETAILS+=("$resource_details")
            fi
            NEW_EXCLUDED_SUMMARY_ROWS+=("$row")
            
            # Track for resource groups
            if [[ "$id" == */resourceGroups/* ]]; then
                local rg_name
                if [[ "$id" =~ /resourceGroups/([^/]+)/ ]]; then
                    rg_name="${BASH_REMATCH[1]}"
                    
                    local already_tracked=false
                    for item in "${RG_EXCLUDED_RESOURCES[@]}"; do
                        if [[ "$item" == "$rg_name|$clean_resource_name|$resource_type" ]]; then
                            already_tracked=true
                            break
                        fi
                    done
                    
                    if [[ "$already_tracked" == false ]]; then
                        RG_EXCLUDED_RESOURCES+=("$rg_name|$clean_resource_name|$resource_type")
                    fi
                fi
            fi
        else
            FILTERED_IDS+=("$id")
            FILTERED_SUMMARY_ROWS+=("$row")
        fi
    done
    
    # Filter resource details arrays to match filtered IDs
    declare -a FILTERED_RESOURCE_DETAILS=()
    for id in "${FILTERED_IDS[@]}"; do
        for detail in "${RESOURCE_DETAILS[@]}"; do
            if [[ "$detail" == "$id|"* ]]; then
                FILTERED_RESOURCE_DETAILS+=("$detail")
                break
            fi
        done
    done
    
    # Calculate how many NEW exclusions were added
    local previous_excluded_count=${#EXCLUDED_IDS[@]}
    local new_exclusions_count=$((${#NEW_EXCLUDED_IDS[@]} - ${#EXCLUDED_IDS[@]}))
    
    # Update global arrays
    ALL_IDS=("${FILTERED_IDS[@]}")
    SUMMARY_ROWS=("${FILTERED_SUMMARY_ROWS[@]}")
    EXCLUDED_IDS=("${NEW_EXCLUDED_IDS[@]}")
    EXCLUDED_RESOURCE_DETAILS=("${NEW_EXCLUDED_DETAILS[@]}")
    EXCLUDED_SUMMARY_ROWS=("${NEW_EXCLUDED_SUMMARY_ROWS[@]}")
    RESOURCE_DETAILS=("${FILTERED_RESOURCE_DETAILS[@]}")
    
    local remaining_count=${#ALL_IDS[@]}
    local total_excluded_count=${#EXCLUDED_IDS[@]}
    
    if [[ $new_exclusions_count -gt 0 ]]; then
        log_info "Excluded $new_exclusions_count additional resource(s)"
    fi
    
    log_info "Total excluded resources: $total_excluded_count"
    log_info "Remaining resources to delete: $remaining_count"
}

# --- Helper function to show updated summary ---
show_updated_summary() {
    echo
    echo "========================================================="
    echo "               ${PURPLE}Updated Summary Table${NC}               "
    echo "========================================================="
    
    log_success "Found ${#ALL_IDS[@]} matching resource(s) for deletion"
    if [[ ${#EXCLUDED_IDS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠️  Total excluded resources: ${#EXCLUDED_IDS[@]}${NC}"
    fi
    
    echo
    printf "%-55s %-50s %-25s %-40s\n" "-------------------------------------------------------" "--------------------------------------------------" "-------------------------" "----------------------------------------"
    printf "%-55s %-50s %-25s %-40s\n" "NAME" "TYPE" "SCOPE" "DETAILS"
    printf "%-55s %-50s %-25s %-40s\n" "-------------------------------------------------------" "--------------------------------------------------" "-------------------------" "----------------------------------------"
    
    for row in "${SUMMARY_ROWS[@]}"; do
        IFS="|" read -r name type scope details <<< "$row"
        clean_name=$(echo "$name" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
        printf "%-55s %-50s %-25s %-40s\n" "$clean_name" "$type" "$scope" "$details"
    done
    
    if [[ ${#RG_EXCLUDED_RESOURCES[@]} -gt 0 ]]; then
        echo ""
        echo "========================================================="
        echo "      Resource Groups with Excluded Resources            "
        echo "========================================================="
        
        declare -a unique_rgs=()
        for item in "${RG_EXCLUDED_RESOURCES[@]}"; do
            IFS="|" read -r rg_name _ _ <<< "$item"
            if [[ ! " ${unique_rgs[@]} " =~ " ${rg_name} " ]]; then
                unique_rgs+=("$rg_name")
            fi
        done
        
        for rg_name in "${unique_rgs[@]}"; do
            echo -e "${YELLOW}⚠️  Resource Group: $rg_name${NC}"
            echo "   Contains excluded resources:"
            
            declare -a shown_resources=()
            for item in "${RG_EXCLUDED_RESOURCES[@]}"; do
                if [[ "$item" == "$rg_name|"* ]]; then
                    IFS="|" read -r _ excluded_resource excluded_type <<< "$item"
                    
                    local resource_key="$excluded_resource|$excluded_type"
                    if [[ ! " ${shown_resources[@]} " =~ " ${resource_key} " ]]; then
                        echo "    • $excluded_resource ($excluded_type)"
                        shown_resources+=("$resource_key")
                    fi
                fi
            done
            echo ""
        done
    fi
    echo "========================================================="
}


# --- Enhanced Confirmation Function with Exclusion Prompt ---
confirm_delete() {
    echo
    log_warning "${RED}WARNING: You are about to DELETE ${#ALL_IDS[@]} resource(s)${NC}"
    log_warning "${RED}This operation cannot be undone!${NC}"
    echo
    
    # --- Get actual matched exclude names from excluded resources ---
    declare -a ACTUAL_EXCLUDED_NAMES=()
    
    # First try to get names from EXCLUDED_RESOURCE_DETAILS
    for detail in "${EXCLUDED_RESOURCE_DETAILS[@]}"; do
        IFS="|" read -r _ name _ _ _ <<< "$detail"
        if [[ -n "$name" ]]; then
            clean_name=$(echo "$name" | sed -E 's/\x1B\[[0-9;]*[mGK]//g' | xargs)
            if [[ -n "$clean_name" ]]; then
                # Check if not already in array
                local already_listed=false
                for item in "${ACTUAL_EXCLUDED_NAMES[@]}"; do
                    if [[ "$item" == "$clean_name" ]]; then
                        already_listed=true
                        break
                    fi
                done
                
                if [[ "$already_listed" == false ]]; then
                    ACTUAL_EXCLUDED_NAMES+=("$clean_name")
                fi
            fi
        fi
    done
    
    # If we couldn't get names from details, try from EXCLUDED_SUMMARY_ROWS
    if [[ ${#ACTUAL_EXCLUDED_NAMES[@]} -eq 0 ]] && [[ ${#EXCLUDED_SUMMARY_ROWS[@]} -gt 0 ]]; then
        for row in "${EXCLUDED_SUMMARY_ROWS[@]}"; do
            IFS="|" read -r name _ _ _ <<< "$row"
            if [[ -n "$name" ]]; then
                clean_name=$(echo "$name" | sed -E 's/\x1B\[[0-9;]*[mGK]//g' | xargs)
                if [[ -n "$clean_name" ]]; then
                    # Check if not already in array
                    local already_listed=false
                    for item in "${ACTUAL_EXCLUDED_NAMES[@]}"; do
                        if [[ "$item" == "$clean_name" ]]; then
                            already_listed=true
                            break
                        fi
                    done
                    
                    if [[ "$already_listed" == false ]]; then
                        ACTUAL_EXCLUDED_NAMES+=("$clean_name")
                    fi
                fi
            fi
        done
    fi
    
    # --- Prompt for additional exclusions ---
    echo -e "${YELLOW}📋 Currently excluded resources (exact matches):${NC}"
    if [[ ${#ACTUAL_EXCLUDED_NAMES[@]} -gt 0 ]]; then
        for i in "${!ACTUAL_EXCLUDED_NAMES[@]}"; do
            echo "  $((i+1)). ${ACTUAL_EXCLUDED_NAMES[$i]}"
        done
        echo -e "${YELLOW}  Total: ${#ACTUAL_EXCLUDED_NAMES[@]} resource(s) excluded${NC}"
    else
        echo "  (No resources excluded yet)"
    fi
    
    # Show unused exclude patterns if any
    if [[ -n "$EXCLUDE_PATTERNS" ]]; then
        declare -a UNUSED_EXCLUDES=()
        IFS=',' read -ra ALL_EXCLUDES <<< "$EXCLUDE_PATTERNS"
        
        for exclude_name in "${ALL_EXCLUDES[@]}"; do
            exclude_name=$(echo "$exclude_name" | xargs)
            [[ -z "$exclude_name" ]] && continue
            
            local found=false
            
            for actual_name in "${ACTUAL_EXCLUDED_NAMES[@]}"; do
                if [[ "$exclude_name" == "$actual_name" ]]; then
                    found=true
                    break
                fi
            done
            
            if [[ "$found" == false ]]; then
                UNUSED_EXCLUDES+=("$exclude_name")
            fi
        done
        
        if [[ ${#UNUSED_EXCLUDES[@]} -gt 0 ]]; then
            echo
            echo -e "${YELLOW}📝 Unused exclude names (no matches found):${NC}"
            for unused in "${UNUSED_EXCLUDES[@]}"; do
                echo "  • $unused"
            done
        fi
    fi
    
    echo
    
    read -p "Do you want to add more resources to exclude? (yes/no): " add_exclude
    
    if [[ "$add_exclude" == "yes" || "$add_exclude" == "y" ]]; then
        echo -e "${CYAN}Enter additional resource names to exclude (comma-separated, exact match):${NC}"
        echo -e "${CYAN}Examples:${NC}"
        echo -e "  • cortex-backup,prod-database"
        echo -e "  • specific-vm-name,storage-account-name"
        echo -e "${CYAN}Note: Only exact name matches will be excluded${NC}"
        echo -e "${CYAN}Leave empty to keep current excludes:${NC}"
        
        read -p "Additional resource names to exclude: " additional_excludes
        
        if [[ -n "$additional_excludes" ]]; then
            # Clean up the input
            additional_excludes=$(echo "$additional_excludes" | xargs)
            
            # Append to existing excludes
            if [[ -n "$EXCLUDE_PATTERNS" ]]; then
                EXCLUDE_PATTERNS="$EXCLUDE_PATTERNS,$additional_excludes"
            else
                EXCLUDE_PATTERNS="$additional_excludes"
            fi
            
            # Update exclude array
            IFS=',' read -ra EXCLUDE_ARRAY <<< "$EXCLUDE_PATTERNS"
            # Trim whitespace from each pattern
            for i in "${!EXCLUDE_ARRAY[@]}"; do
                EXCLUDE_ARRAY[$i]=$(echo "${EXCLUDE_ARRAY[$i]}" | xargs)
            done
            
            echo -e "${GREEN}✅ Updated exclude names: $EXCLUDE_PATTERNS${NC}"
            
            # Re-apply exclude filtering
            echo -e "${YELLOW}Re-applying exclude filters...${NC}"
            apply_exclude_filters
            
            if [[ ${#ALL_IDS[@]} -eq 0 ]]; then
                log_success "All resources would be excluded. Nothing to delete."
                exit 0
            fi
            
            # Show updated summary
            show_updated_summary
        else
            echo -e "${YELLOW}No additional exclusions added.${NC}"
        fi
    elif [[ "$add_exclude" == "no" || "$add_exclude" == "n" ]]; then
        echo -e "${YELLOW}Proceeding with current exclusions.${NC}"
    else
        echo -e "${YELLOW}Invalid input. Proceeding with current exclusions.${NC}"
    fi
    
    echo
    log_warning "${RED}FINAL CONFIRMATION: You are about to DELETE ${#ALL_IDS[@]} resource(s)${NC}"
    log_warning "${RED}This operation cannot be undone!${NC}"
    echo
    
    read -p "Are you absolutely sure you want to proceed? (type 'DELETE' to confirm): " confirmation
    
    if [[ "$confirmation" != "DELETE" ]]; then
        log_warning "Deletion aborted"
        echo
        exit 0
    fi
}


    # --- Deduplicate Resources Function ---
deduplicate_resources() {
    log_debug "Deduplicating resource list..."
    
    declare -a UNIQUE_IDS=()
    declare -a UNIQUE_SUMMARY_ROWS=()
    declare -a UNIQUE_RESOURCE_TYPES=()
    declare -a UNIQUE_RESOURCE_DETAILS=()
    declare -a UNIQUE_RG_SUBSCRIPTION=()
    
    # Create associative arrays for tracking
    declare -A seen_ids
    declare -A seen_summary_rows
    
    for i in "${!ALL_IDS[@]}"; do
        local id="${ALL_IDS[$i]}"
        local summary_row="${SUMMARY_ROWS[$i]}"
        
        # Skip if we've already seen this ID
        if [[ -n "${seen_ids[$id]}" ]]; then
            log_debug "Removing duplicate resource ID: $id"
            continue
        fi
        
        # Also check for duplicate summary rows (same name/type/scope)
        if [[ -n "${seen_summary_rows[$summary_row]}" ]]; then
            log_debug "Removing duplicate summary row: $summary_row"
            continue
        fi
        
        # Mark as seen
        seen_ids[$id]=1
        seen_summary_rows[$summary_row]=1
        
        # Add to unique arrays
        UNIQUE_IDS+=("$id")
        UNIQUE_SUMMARY_ROWS+=("$summary_row")
        
        # Find and add corresponding entries from other arrays
        for j in "${!RESOURCE_TYPES[@]}"; do
            if [[ "${RESOURCE_TYPES[$j]}" == "$id|"* ]]; then
                UNIQUE_RESOURCE_TYPES+=("${RESOURCE_TYPES[$j]}")
                break
            fi
        done
        
        for j in "${!RESOURCE_DETAILS[@]}"; do
            if [[ "${RESOURCE_DETAILS[$j]}" == "$id|"* ]]; then
                UNIQUE_RESOURCE_DETAILS+=("${RESOURCE_DETAILS[$j]}")
                break
            fi
        done
        
        for j in "${!RG_SUBSCRIPTION[@]}"; do
            if [[ "${RG_SUBSCRIPTION[$j]}" == "$id|"* ]]; then
                UNIQUE_RG_SUBSCRIPTION+=("${RG_SUBSCRIPTION[$j]}")
                break
            fi
        done
    done
    
    # Update global arrays
    ALL_IDS=("${UNIQUE_IDS[@]}")
    SUMMARY_ROWS=("${UNIQUE_SUMMARY_ROWS[@]}")
    RESOURCE_TYPES=("${UNIQUE_RESOURCE_TYPES[@]}")
    RESOURCE_DETAILS=("${UNIQUE_RESOURCE_DETAILS[@]}")
    RG_SUBSCRIPTION=("${UNIQUE_RG_SUBSCRIPTION[@]}")
    
    log_debug "After deduplication: ${#ALL_IDS[@]} unique resources"
}

# --- Log Summary Function ---
log_summary() {
    if [[ "$LOG_ENABLED" == true ]] && [[ -n "$LOG_FILE" ]]; then
        local end_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
        
        # For append mode, we need to find the start time from this execution's header
        local start_time
        if [[ "$APPEND_LOG" == true ]] && [[ -f "$LOG_FILE" ]]; then
            # Look for the most recent "Execution Start" in the file
            # Try different methods to get the last matching line
            if command -v tac >/dev/null 2>&1; then
                # Use tac if available (Linux)
                start_time=$(tac "$LOG_FILE" | grep -m1 "Execution Start" | cut -d':' -f2- | sed 's/^ *//')
            else
                # Use tail and grep (macOS/BSD compatible)
                start_time=$(tail -r "$LOG_FILE" 2>/dev/null | grep -m1 "Execution Start" | cut -d':' -f2- | sed 's/^ *//')
                if [[ -z "$start_time" ]]; then
                    # Fallback to awk if tail -r doesn't work
                    start_time=$(awk '/Execution Start/ {line=$0} END {print line}' "$LOG_FILE" | cut -d':' -f2- | sed 's/^ *//')
                fi
            fi
        else
            # For overwrite mode, get from the first line
            start_time=$(grep "Execution Start" "$LOG_FILE" | head -1 | cut -d':' -f2- | sed 's/^ *//')
        fi
        
        echo "" >> "$LOG_FILE"
        echo "==================================================================================" >> "$LOG_FILE"
        echo "EXECUTION SUMMARY" >> "$LOG_FILE"
        echo "==================================================================================" >> "$LOG_FILE"
        echo "Start Time      : $start_time" >> "$LOG_FILE"
        echo "End Time        : $end_time" >> "$LOG_FILE"
        
        # Calculate duration
        local start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo 0)
        local end_epoch=$(date -d "$end_time" +%s 2>/dev/null || echo 0)
        if [[ $start_epoch -gt 0 ]] && [[ $end_epoch -gt 0 ]]; then
            local duration=$((end_epoch - start_epoch))
            local hours=$((duration / 3600))
            local minutes=$(((duration % 3600) / 60))
            local seconds=$((duration % 60))
            echo "Duration        : $(printf "%02d:%02d:%02d" $hours $minutes $seconds)" >> "$LOG_FILE"
        fi
        
        echo "Mode            : $([[ "$DRY_RUN" == true ]] && echo "DRY-RUN" || echo "DELETE")" >> "$LOG_FILE"
        echo "Log Mode        : $([[ "$APPEND_LOG" == true ]] && echo "APPEND" || echo "OVERWRITE")" >> "$LOG_FILE"
        echo "Search Type     : " >> "$LOG_FILE"
        if [[ -n "$TAG_FILTER" ]]; then
            echo "                : Tag Filter: $TAG_FILTER" >> "$LOG_FILE"
        elif [[ -n "$RESOURCE_GROUPS" ]]; then
            echo "                : Resource Group(s): $RESOURCE_GROUPS" >> "$LOG_FILE"
        elif [[ -n "$NAME_PATTERN" ]]; then
            echo "                : Name Pattern(s): $NAME_PATTERN" >> "$LOG_FILE"
        fi
        
        if [[ -n "$EXCLUDE_SUBSCRIPTIONS" ]]; then
            echo "Exclude Subs     : $EXCLUDE_SUBSCRIPTIONS" >> "$LOG_FILE"
        fi
        
        echo "Resources Found     : $((${#ALL_IDS[@]} + ${#EXCLUDED_IDS[@]}))" >> "$LOG_FILE"
        echo "Resources Deleted   : ${#ALL_IDS[@]}" >> "$LOG_FILE"
        echo "Resources Excluded  : ${#EXCLUDED_IDS[@]}" >> "$LOG_FILE"
        
        # Count resource groups with excluded resources
        declare -a unique_rgs=()
        for item in "${RG_EXCLUDED_RESOURCES[@]}"; do
            IFS="|" read -r rg_name _ _ <<< "$item"
            if [[ ! " ${unique_rgs[@]} " =~ " ${rg_name} " ]]; then
                unique_rgs+=("$rg_name")
            fi
        done
        echo "Resource Groups Skipped : ${#unique_rgs[@]} (contained excluded resources)" >> "$LOG_FILE"
        
        # Count failed deletions
        if [[ "$DRY_RUN" != true ]] && [[ "$DELETE_MODE" == true ]]; then
            # This is a placeholder - you should track failed deletions during the deletion phase
            local failed_count=0
            echo "Resources Failed      : $failed_count" >> "$LOG_FILE"
        fi
        
        echo "==================================================================================" >> "$LOG_FILE"
        
        # For append mode, add a separator for the next execution
        if [[ "$APPEND_LOG" == true ]]; then
            echo "" >> "$LOG_FILE"
            echo "==================================================================================" >> "$LOG_FILE"
            echo "END OF EXECUTION" >> "$LOG_FILE"
            echo "==================================================================================" >> "$LOG_FILE"
        fi
    fi
}

# --- Main Execution ---
main() {
    # Initialize logging
    init_logging
    
    log_info "Mode: $([[ "$DRY_RUN" == true ]] && echo ${YELLOW}"DRY-RUN"${NC} || echo ${YELLOW}"DELETE"${NC})"
    
    # Add log mode info
    if [[ "$LOG_ENABLED" == true ]]; then
        log_info "Log Mode: $([[ "$APPEND_LOG" == true ]] && echo ${YELLOW}"APPEND"${NC} || echo ${YELLOW}"OVERWRITE"${NC})"
    fi
    echo
    
    # Display excluded services
    if [[ ${#EXCLUDE_SERVICE_ARRAY[@]} -gt 0 ]]; then
        log_info "Excluding service types from discovery:"
        for service in "${EXCLUDE_SERVICE_ARRAY[@]}"; do
            local display_name="${SERVICE_DISPLAY_NAMES[$service]:-$service}"
            log_info "  • ${YELLOW}$display_name${NC}"
        done
    fi
    
    if [[ -n "$TAG_FILTER" ]]; then
        log_info "Searching for resources with tag: ${YELLOW}$TAG_FILTER${NC}"
        if [[ ${#RESOURCE_GROUP_ARRAY[@]} -gt 0 ]]; then
            log_info "Filtering to specific resource groups: ${YELLOW}${RESOURCE_GROUPS}${NC}"
        fi
    elif [[ -n "$RESOURCE_GROUPS" ]]; then
        log_info "Searching for resource group(s):"
        for rg in "${RESOURCE_GROUP_ARRAY[@]}"; do
            log_info "  • ${YELLOW}$rg${NC}"
        done
        if [[ ${#NAME_PATTERNS[@]} -gt 0 ]]; then
            log_info "And searching for resources matching ANY of these patterns:"
            for pattern in "${NAME_PATTERNS[@]}"; do
                log_info "  • ${YELLOW}$pattern${NC}"
            done
        fi
    elif [[ ${#NAME_PATTERNS[@]} -gt 1 ]]; then
        log_info "Searching for resources matching ANY of these patterns:"
        for pattern in "${NAME_PATTERNS[@]}"; do
            log_info "  • ${YELLOW}$pattern${NC}"
        done
    else
        log_info "Searching for resources containing: ${YELLOW}${NAME_PATTERN}${NC}"
    fi
    
    if [[ -n "$EXCLUDE_SUBSCRIPTIONS" ]]; then
        log_info "Excluding subscription(s):"
        for sub in "${EXCLUDE_SUBSCRIPTION_ARRAY[@]}"; do
            log_info "  • ${YELLOW}$sub${NC}"
        done
    fi
    
    if [[ -n "$EXCLUDE_PATTERNS" ]]; then
        log_info "Exclude matching resources:"
        for pattern in "${EXCLUDE_ARRAY[@]}"; do
            log_info "  • ${YELLOW}$pattern${NC}"
        done
    fi

    echo "--------------------------------------------------------"
    log_to_file "INFO" "--------------------------------------------------------"
    # Get current subscription context
    CURRENT_SUB=$(az account show --query id -o tsv)
    log_to_file "INFO" "Current subscription ID: $CURRENT_SUB"
    
    # Cache subscription names upfront (avoids repeated az account show calls)
    cache_subscription_names
    
    # Get subscriptions
    local subscriptions
    subscriptions=$(get_subscriptions)
    if [[ -z "$subscriptions" ]]; then
        log_error "No subscriptions found"
        exit 1
    fi
    
    if [[ -n "$TAG_FILTER" ]]; then
        discover_resources_by_tag "$TAG_FILTER"
    elif [[ -n "$RESOURCE_GROUPS" ]]; then
        # Resource group specific mode - scan within specified RGs
        log_info "Resource Group Mode: Scanning within specified resource group(s)"
        discover_resources_in_specific_rgs
        
        # Skip regular resource discovery in subscription loop
        SKIP_REGULAR_DISCOVERY=true
    else
        # Try fast Resource Graph discovery first, fall back to per-subscription
        local use_graph=false
        if [[ ${#NAME_PATTERNS[@]} -gt 0 ]]; then
            if discover_resources_via_graph; then
                use_graph=true
            fi
        fi
        
        if [[ "$use_graph" == true ]]; then
            # Graph handled resources and RGs; still need per-sub role assignments
            while IFS= read -r sub; do
                [[ -z "$sub" ]] && continue
                local sub_name
                sub_name=$(get_sub_name "$sub")
                discover_subscription_role_assignments "$sub" "$sub_name"
            done <<< "$subscriptions"
        else
            # Fallback: per-subscription discovery (original behavior)
            while IFS= read -r sub; do
                if [[ -z "$sub" ]]; then
                    continue
                fi
                
                if az account set --subscription "$sub" >/dev/null 2>&1; then
                    local sub_name
                    sub_name=$(get_sub_name "$sub")
                    log_to_file "INFO" "Switched to subscription: $sub ($sub_name)"
                    discover_resources "$sub" "$sub_name"
                    discover_subscription_role_assignments "$sub" "$sub_name"
                else
                    log_info "Accessed subscription: $sub"
                fi
            done <<< "$subscriptions"
        fi
        SKIP_REGULAR_DISCOVERY=false
    fi
    
    az account set --subscription "$CURRENT_SUB" >/dev/null 2>/dev/null
    log_to_file "INFO" "Switched back to original subscription: $CURRENT_SUB"
    
    # ALWAYS run tenant/management group level discoveries (unless excluded)
    # But skip if 'all' is excluded
    if ! is_service_excluded "all"; then
        # Only run discovery functions for services that aren't excluded
        for service in "${!SERVICE_DISCOVERY_FUNCTIONS[@]}"; do
            if ! is_service_excluded "$service"; then
                local functions="${SERVICE_DISCOVERY_FUNCTIONS[$service]}"
                for func in $functions; do
                    if type "$func" &>/dev/null; then
                        # Skip resource group specific functions if we already ran them
                        if [[ "$func" == "discover_resources_in_specific_rgs" ]] && [[ -n "$RESOURCE_GROUPS" ]]; then
                            log_debug "Skipping $func (already executed in resource group mode)"
                            continue
                        fi
                        $func
                    fi
                done
            else
                log_debug "Skipping $service discovery functions (excluded via --exclude-service)"
            fi
        done
    else
        log_info "Skipping all service-specific discovery (--exclude-service all)"
    fi
    
    echo ""
    log_to_file "INFO" "Discovery phase completed"
    
    if [[ -n "$EXCLUDE_PATTERNS" ]]; then
        log_info "Applying exclude patterns: $EXCLUDE_PATTERNS"
        apply_exclude_filters
        
        if [[ ${#EXCLUDED_IDS[@]} -gt 0 ]]; then
            log_info "Excluded ${#EXCLUDED_IDS[@]} resource(s) from deletion"
        else
            log_info "No resources matched exclude patterns"
        fi
    fi
    # --- Added deduplication step here ---
    deduplicate_resources
    

    
    # --- Log info about resource groups with excluded resources (already tracked in should_exclude) --- 
    if [[ ${#RG_EXCLUDED_RESOURCES[@]} -gt 0 ]]; then
        log_info "Found ${#RG_EXCLUDED_RESOURCES[@]} excluded resource(s) in resource groups"
    fi
    
    if [[ ${#ALL_IDS[@]} -eq 0 ]]; then
        RESOURCES_FOUND=false
    fi
    
    if [[ "$RESOURCES_FOUND" == "false" ]]; then
        log_success "No matching resources found"
        echo "========================================================="
        echo ""
        log_summary
        exit 0
    fi
    
    if [[ -n "$EXCLUDE_PATTERNS" && ${#EXCLUDED_IDS[@]} -gt 0 ]]; then
        log_warning "Excluded ${#EXCLUDED_IDS[@]} resource(s) matching patterns: $EXCLUDE_PATTERNS"
    fi
    echo
    echo "========================================================="
    echo "                      ${PURPLE}Summary Table${NC}                      "
    echo "========================================================="
    
    log_success "Found ${#ALL_IDS[@]} matching resource(s) for deletion"
    if [[ ${#EXCLUDED_IDS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠️  Excluded ${#EXCLUDED_IDS[@]} resource(s)${NC}"
    fi
    
    echo
    printf "%-55s %-50s %-25s %-40s\n" "-------------------------------------------------------" "--------------------------------------------------" "-------------------------" "----------------------------------------"
    printf "%-55s %-50s %-25s %-40s\n" "NAME" "TYPE" "SCOPE" "DETAILS"
    printf "%-55s %-50s %-25s %-40s\n" "-------------------------------------------------------" "--------------------------------------------------" "-------------------------" "----------------------------------------"
    
    for row in "${SUMMARY_ROWS[@]}"; do
        IFS="|" read -r name type scope details <<< "$row"
        clean_name=$(echo "$name" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
        printf "%-55s %-50s %-25s %-40s\n" "$clean_name" "$type" "$scope" "$details"
        log_to_file "SUMMARY" "$clean_name | $type | $scope | $details"
    done
    
    # --- Display warning for resource groups that won't be deleted due to excluded resources --- 
    if [[ ${#RG_EXCLUDED_RESOURCES[@]} -gt 0 ]]; then
        echo ""
        echo "========================================================="
        echo "      Resource Groups with Excluded Resources            "
        echo "========================================================="
        
        # Get unique resource groups
        declare -a unique_rgs=()
        for item in "${RG_EXCLUDED_RESOURCES[@]}"; do
            IFS="|" read -r rg_name _ _ <<< "$item"
            if [[ ! " ${unique_rgs[@]} " =~ " ${rg_name} " ]]; then
                unique_rgs+=("$rg_name")
            fi
        done
        
        for rg_name in "${unique_rgs[@]}"; do
            echo -e "${YELLOW}⚠️  Resource Group: $rg_name${NC}"
            echo "   Contains excluded resources:"
            
            # Show unique resources for this RG
            declare -a shown_resources=()
            for item in "${RG_EXCLUDED_RESOURCES[@]}"; do
                if [[ "$item" == "$rg_name|"* ]]; then
                    IFS="|" read -r _ excluded_resource excluded_type <<< "$item"
                    
                    # Check if we've already shown this resource
                    local resource_key="$excluded_resource|$excluded_type"
                    if [[ ! " ${shown_resources[@]} " =~ " ${resource_key} " ]]; then
                        echo "    • $excluded_resource ($excluded_type)"
                        shown_resources+=("$resource_key")
                    fi
                fi
            done
            echo ""
        done
        echo -e "These resource groups ${YELLOW}$rg_name${NC} will NOT be deleted because of excluded resources, as those are present in Resource Groups."
        echo "Remove the excluded resources first or adjust your exclude patterns."
        echo "========================================================="
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        echo
        log_info "Dry-run completed. No resources were deleted."
        log_info "Use --delete to actually delete these resources."
        echo
        echo -e "${YELLOW}Example:${NC}"
        log_info "$0 cortex,ADSConnector,ADSGallery,ADSOutpost --resource-group cortex-onboarding-* --delete"
        echo
        echo -e "${YELLOW}Run with --help for more details${NC}"
        log_info "$0 --help"
        log_summary
        exit 0
    fi
    
    # Enhanced confirmation with exclusion prompt
    confirm_delete
    
    log_info "Starting ordered deletion process..."
    
    local deleted_count=0
    local failed_count=0
    
    # --- Phase 1: Management Group Deployments --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" == "ManagementGroupDeployment" ]]; then
            local details=$(get_resource_details "$id")
            IFS="|" read -r name type scope <<< "$details"
            if delete_management_group_deployment "$id" "$name" "$scope"; then
                ((deleted_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    # --- Phase 2: Policy Remediations --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" == "PolicyRemediation" ]]; then
            local details=$(get_resource_details "$id")
            IFS="|" read -r name type scope <<< "$details"
            if delete_policy_remediation "$id" "$name"; then
                ((deleted_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    # --- Phase 3: Policy Assignments --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" == "PolicyAssignment" ]]; then
            local details=$(get_resource_details "$id")
            IFS="|" read -r name type scope assignment_name <<< "$details"
            if delete_policy_assignment "$id" "$name" "$scope"; then
                ((deleted_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    # --- Phase 4: Management Group Role Assignments --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" == "ManagementGroupRoleAssignment" ]]; then
            local details=$(get_resource_details "$id")
            IFS="|" read -r name type scope <<< "$details"
            if delete_management_group_role_assignment "$id" "$name"; then
                ((deleted_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    # --- Phase 5: Azure AD Diagnostic Settings --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" == "DirectoryDiagnosticSetting" ]]; then
            local details=$(get_resource_details "$id")
            IFS="|" read -r name type scope <<< "$details"
            if delete_directory_diagnostic_setting "$id" "$name"; then
                ((deleted_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    # --- Phase 6: Subscription Role Assignments --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" == "SubscriptionRoleAssignment" ]]; then
            local details=$(get_resource_details "$id")
            IFS="|" read -r name type scope <<< "$details"
            if delete_subscription_role_assignment "$id" "$name"; then
                ((deleted_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    # --- Phase 7: Role Assignments --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" == "RoleAssignment" || "$resource_type" == "UnknownRoleAssignment" ]]; then
            local details=$(get_resource_details "$id")
            IFS="|" read -r name type scope role_name <<< "$details"
            log_special "Deleting Role Assignment: $name for role $role_name"
            if az role assignment delete --ids "$id" 2>/dev/null; then
                log_success "Deleted Role Assignment: $name"
                ((deleted_count++))
            else
                log_error "Failed to delete Role Assignment: $name"
                ((failed_count++))
            fi
        fi
    done
    
    # --- Phase 8: Custom Roles --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" == "CustomRole" ]]; then
            local details=$(get_resource_details "$id")
            IFS="|" read -r name type scope extra <<< "$details"
            delete_role_assignment_enhanced "$id" "$name"
            if delete_custom_role_enhanced "$id" "$name"; then
                ((deleted_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    # --- Phase 9: Regular Resources --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" != "ResourceGroup" && \
              "$resource_type" != "CustomRole" && \
              "$resource_type" != "EnterpriseApplication" && \
              "$resource_type" != "ServicePrincipal" && \
              "$resource_type" != "ManagementGroupRoleAssignment" && \
              "$resource_type" != "SubscriptionRoleAssignment" && \
              "$resource_type" != "RoleAssignment" && \
              "$resource_type" != "UnknownRoleAssignment" && \
              "$resource_type" != "PolicyAssignment" && \
              "$resource_type" != "PolicyRemediation" && \
              "$resource_type" != "ManagementGroupDeployment" && \
              "$resource_type" != "DirectoryDiagnosticSetting" ]]; then    
            local details=$(get_resource_details "$id")
            IFS="|" read -r name type sub <<< "$details"
            log_info "Deleting Resource: $name ($type)"
            if delete_with_retry "$id" "$type"; then
                ((deleted_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    # --- Phase 10: Service Principals --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" == "EnterpriseApplication" ]]; then
            local details=$(get_resource_details "$id")
            IFS="|" read -r name type scope <<< "$details"
            if delete_service_principal "$id" "$name"; then
                ((deleted_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    # --- Phase 11: Resource Groups --- 
    for id in "${ALL_IDS[@]}"; do
        local resource_type=$(get_resource_type "$id")
        if [[ "$resource_type" == "ResourceGroup" ]]; then
            local rg_name=$(echo "$id" | awk -F/ '{print $NF}')
            local sub_id=$(get_rg_subscription "$id")
            if delete_resource_group "$id" "$rg_name" "$sub_id"; then
                ((deleted_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    echo
    if [[ $failed_count -eq 0 ]]; then
        echo "========================================================="
        log_success "Successfully deletion completed for $deleted_count resource(s)"
        echo "========================================================="
    else
        log_warning "Deletion completed with $failed_count failure(s)"
        log_success "Successfully processed $deleted_count resource(s)"
    fi
    
    if [[ ${#EXCLUDED_IDS[@]} -gt 0 ]]; then
        log_info "${#EXCLUDED_IDS[@]} resource(s) were excluded from deletion"
    fi
    
    log_warning "Note: Some deletions may run asynchronously. Check Azure Portal for final status or rerun it again after 30 seconds"
    echo ""
    
    # --- Write summary to log file --- 
    log_summary
}

# --- Run main function --- 
main "$@"
