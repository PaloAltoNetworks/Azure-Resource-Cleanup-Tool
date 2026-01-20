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
#               multi-keyword search, audit logging, append log mode
# 
# ⚡ HANDLES: 'Unknown' role assignments, orphaned resources, single/multi-subscription cleanup
#====================================================================================================

# Exit on critical errors but allow graceful handling for individual resource operations
set -u
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
    echo "  bash $0 <resource-name> [--dry-run] [--delete] [--subscription SUB_ID] [--exclude PATTERNS] [--log-file FILE] [--append-log] [--help]"
    echo "  bash $0 <pattern1,pattern2,...> [--dry-run] [--delete] [--subscription SUB_ID] [--exclude PATTERNS] [--log-file FILE] [--append-log]"
    echo "  bash $0 --tag KEY[=VALUE] [--dry-run] [--delete] [--subscription SUB_ID] [--exclude PATTERNS] [--log-file FILE] [--append-log] [--help]"
    echo
    echo -e "${YELLOW}Options:${NC}"
    echo "  <resource-name>    Search pattern (case-insensitive). Use commas for multiple patterns."
    echo "                     Example: \"cortex,ads,monitor\" (matches ANY of these patterns)"
    echo "  --dry-run          Only show what would be deleted (default)"
    echo "  --delete           Actually delete resources (default: dry-run)"
    echo "  --tag KEY[=VALUE]  Search by tag in three ways:"
    echo "                         • KEY          - matches tag key"
    echo "                         • KEY=VALUE    - matches exact key-value pair"
    echo "                         • VALUE        - matches tag value"
    echo "  --subscription     Limit search to specific subscription"
    echo "  --exclude PATTERNS Comma-separated patterns/names to exclude from deletion"
    echo "  --log-file FILE    Write detailed audit log to specified file"
    echo "  --append-log       Append to existing log file instead of overwriting"
    echo "  --help             Show this help message"
    echo
    echo -e "${YELLOW}Examples:${NC}"
    echo "  ${PURPLE}# Basic pattern search with audit log${NC}"
    echo "  bash $0 \"cortex\" --dry-run --log-file \"audit.log\""
    echo "  bash $0 \"cortex\" --delete --subscription \"12345-67890\" --log-file \"audit.log\""
    echo "  bash $0 \"cortex\" --delete --subscription \"12345-67890\" --log-file \"deletion.log\""
    echo
    echo "  ${PURPLE}# Multi-pattern search with audit log (matches ANY of the patterns)${NC}"
    echo "  bash $0 \"cortex,ads\" --dry-run --subscription \"12345-67890\" --log-file \"audit.log\""
    echo "  bash $0 \"cortex,ads\" --delete --log-file \"cleanup-\$(date +%Y%m%d-%H%M%S).log\""
    echo
    echo "  ${PURPLE}# Tag-based search with audit log${NC}"
    echo "  bash $0 --tag \"managed_by\" --dry-run --log-file \"tag-audit.log\""
    echo "  bash $0 --tag \"managed_by=paloaltonetworks\" --dry-run --log-file \"tag-audit.log\""
    echo "  bash $0 --tag \"managed_by=paloaltonetworks\" --delete --log-file \"tag-audit.log\""
    echo
    echo "  ${PURPLE}# Exclusion Patterns with audit log${NC}"
    echo "  bash $0 \"cortex,ads\" --dry-run --exclude \"cortex-scan-platform\" --log-file \"audit.log\""
    echo "  bash $0 --tag \"paloaltonetworks\" --delete --exclude \"cortex-scan-platform,production\" --log-file \"cleanup.log\""
    echo
    echo "  ${PURPLE}# Append to existing log file${NC}"
    echo "  bash $0 \"cortex\" --dry-run --log-file \"audit.log\" --append-log"
    echo "  bash $0 \"ads\" --delete --log-file \"audit.log\" --append-log"
    echo
    echo "  ${PURPLE}# Exclusion Patterns with audit log${NC}"
    echo "  bash $0 \"cortex,ads\" --dry-run --exclude \"cortex-scan-platform\""
    echo "  bash $0 \"cortex,ads\" --delete --exclude \"cortex-scan-platform,production\" --subscription \"12345-67890\" --log-file \"audit.log\""
    echo "  bash $0 --tag \"paloaltonetworks\" --delete --exclude \"cortex-scan-platform,production,backup\" --subscription \"12345-67890\" --log-file \"audit.log\""
    echo
    echo "  ${PURPLE}# Help message${NC}"
    echo "  bash $0 --help"
    exit 1
}

# --- Argument Parsing ---
DELETE_MODE=false
DRY_RUN=true
SUBSCRIPTION_ID=""
NAME_PATTERN=""
TAG_FILTER=""
EXCLUDE_PATTERNS=""
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
            SUBSCRIPTION_ID="$2"
            shift 2
            ;;
        --tag)
            TAG_FILTER="$2"
            shift 2
            ;;
        --exclude)
            EXCLUDE_PATTERNS="$2"
            shift 2
            ;;
        --log-file)
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
            local sub_name=$(az account show --subscription "$SUBSCRIPTION_ID" --query 'name' -o tsv 2>/dev/null || echo "$SUBSCRIPTION_ID")
            echo "Subscription     : $SUBSCRIPTION_ID ($sub_name)" >> "$LOG_FILE"
        else
            echo "Subscription     : All enabled subscriptions" >> "$LOG_FILE"
        fi
        
        echo "Mode             : $([[ "$DRY_RUN" == true ]] && echo "DRY-RUN" || echo "DELETE")" >> "$LOG_FILE"
        echo "Log Mode         : $([[ "$APPEND_LOG" == true ]] && echo "APPEND" || echo "OVERWRITE")" >> "$LOG_FILE"
        
        if [[ -n "$TAG_FILTER" ]]; then
            echo "Search Type      : Tag Filter" >> "$LOG_FILE"
            echo "Tag Filter       : $TAG_FILTER" >> "$LOG_FILE"
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

# --- Validation --- 
if [[ -z "$NAME_PATTERN" && -z "$TAG_FILTER" ]]; then
    log_error "Either name pattern or tag filter is required"
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
    log_special "Azure Resource Cleanup Tool"
    log_to_file "INFO" "Parsed ${#NAME_PATTERNS[@]} search pattern(s): ${NAME_PATTERNS[*]}"
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

# --- Initialize Arrays ---
declare -a ALL_IDS=()
declare -a SUMMARY_ROWS=()
declare -a EXCLUDED_IDS=()
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
    
    #  --- If in pure tag mode (no name patterns), skip pattern matching --- 
    if [[ -n "$TAG_FILTER" && ${#NAME_PATTERNS[@]} -eq 0 ]]; then
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

# --- Exclude Checking Function ---
should_exclude() {
    local resource_name="$1"
    local resource_type="$2"
    local resource_id="$3"
    
    #  --- If no exclude patterns, don't exclude anything --- 
    [[ -z "$EXCLUDE_PATTERNS" ]] && return 1
    
    #  --- Check each exclude pattern --- 
    for pattern in "${EXCLUDE_ARRAY[@]}"; do
        #  --- Trim whitespace --- 
        pattern=$(echo "$pattern" | xargs)
        
        #  --- Skip empty patterns --- 
        [[ -z "$pattern" ]] && continue
        
        # --- Check if resource name contains the pattern (case-insensitive) --- 
        if [[ "$(normalize "$resource_name")" == *"$(normalize "$pattern")"* ]]; then
            log_warning "Excluding resource: $resource_name ($resource_type) - matches exclude pattern: $pattern"
            
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
        if [[ "$resource_id" == *"$pattern"* ]]; then
            log_warning "Excluding resource: $resource_name ($resource_type) - matches exclude pattern in ID: $pattern"
            
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
        echo "$subs"
    fi
}

# --- Resource Discovery Functions ---
discover_resources() {
    local sub="$1"
    local sub_name="$2"
    
    log_info "Searching resources in subscription: $sub_name"
    
    # --- Resources in resource groups --- 
    local resources
    resources=$(az resource list --subscription "$sub" -o json 2>/dev/null || echo '[]')
    
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        
        local name type id tags
        name=$(jq -r '.name // ""' <<< "$row")
        type=$(jq -r '.type // ""' <<< "$row")
        id=$(jq -r '.id // ""' <<< "$row")
        tags=$(jq -r '.tags // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' <<< "$row")
        
        # --- Skip role definitions (handled separately) --- 
        [[ "$type" == *"Microsoft.Authorization/roleDefinitions"* ]] && continue
        
        # --- Multi-pattern matching ---
        local matched_pattern
        if matched_pattern=$(matches_any_pattern "$name"); then
            echo "  → Found Resource: $(highlight_matches "$name") ($type)"
            log_to_file "FOUND" "Resource: $name ($type) in subscription: $sub_name"
            SUMMARY_ROWS+=("$name|$type|$sub_name|$tags")
            ALL_IDS+=("$id")
            RESOURCE_TYPES+=("$id|$type")
            RESOURCE_DETAILS+=("$id|$name|$type|$sub_name")
            RESOURCES_FOUND=true
        fi
    done < <(jq -c '.[]' <<< "$resources")
    
    # --- Resource Groups --- 
    local rgs
    rgs=$(az group list --subscription "$sub" -o json 2>/dev/null || echo '[]')
    
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        
        local name id tags
        name=$(jq -r '.name // ""' <<< "$row")
        id=$(jq -r '.id // ""' <<< "$row")
        tags=$(jq -r '.tags // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' <<< "$row")
        
        # --- UPDATED: Multi-pattern matching ---
        local matched_pattern
        if matched_pattern=$(matches_any_pattern "$name"); then
            echo "  → Found Resource Group: $(highlight_matches "$name")"
            log_to_file "FOUND" "Resource Group: $name in subscription: $sub_name"
            SUMMARY_ROWS+=("$name|ResourceGroup|$sub_name|$tags")
            ALL_IDS+=("$id")
            RESOURCE_TYPES+=("$id|ResourceGroup")
            RG_SUBSCRIPTION+=("$id|$sub")
            RESOURCE_DETAILS+=("$id|$name|ResourceGroup|$sub_name")
            RESOURCES_FOUND=true
        fi
    done < <(jq -c '.[]' <<< "$rgs")
}

# --- Resource Discovery Functions by TAGS ---
discover_resources_by_tag() {
    local tag_filter="$1"
    
    # --- Parse tag filter (key=value or just key or just value) --- 
    local tag_key tag_value tag_query
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
        sub_name=$(az account show --subscription "$sub" --query 'name' -o tsv 2>/dev/null || echo "Unknown")
        if [[ "$sub_name" == "Unknown" ]]; then
            sub_name=$(az account list --query "[?id=='$sub'].name | [0]" -o tsv 2>/dev/null || echo "Subscription-$sub")
        fi
        
        log_info "Searching tagged resources in subscription: $sub_name"
        
        # --- Find resources with the specified tag - use different approaches --- 
        local resources
        if [[ "$tag_filter" == *"="* ]]; then
            resources=$(az resource list --subscription "$sub" --query "[?tags.$tag_key=='$tag_value']" -o json 2>/dev/null || echo '[]')
        else
            resources=$(az resource list --subscription "$sub" --query "[?contains(keys(tags), '$tag_key') || contains(values(tags), '$tag_key')]" -o json 2>/dev/null || echo '[]')
        fi
        
        while IFS= read -r resource; do
            [[ -z "$resource" ]] && continue
            
            local name type id tags location
            name=$(jq -r '.name // ""' <<< "$resource")
            type=$(jq -r '.type // ""' <<< "$resource")
            id=$(jq -r '.id // ""' <<< "$resource")
            tags=$(jq -r '.tags // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' <<< "$resource")
            location=$(jq -r '.location // ""' <<< "$resource")
            
            echo "  → Found Tagged Resource: $name ($type)"
            echo "    ↳ Location: $location, Tags: $tags"
            log_to_file "FOUND" "Tagged Resource: $name ($type) in $sub_name"
            log_to_file "DETAILS" "  Location: $location, Tags: $tags"
            
            SUMMARY_ROWS+=("$name|$type|$sub_name|Tags: $tags")
            ALL_IDS+=("$id")
            
            RESOURCE_TYPES+=("$id|$type")
            RESOURCE_DETAILS+=("$id|$name|$type|$sub_name|$tags")
            
            RESOURCES_FOUND=true
            
        done < <(jq -c '.[]' <<< "$resources")
        
        discover_resource_groups_by_tag "$sub" "$sub_name" "$tag_filter"
        
    done <<< "$subscriptions"
}

# --- Resource Group Discovery Functions by TAGS ---
discover_resource_groups_by_tag() {
    local sub="$1" sub_name="$2" tag_filter="$3"
    
    log_debug "Searching for tagged resource groups in subscription: $sub_name"
    
    local rgs
    if [[ "$tag_filter" == *"="* ]]; then
        local tag_key="${tag_filter%=*}"
        local tag_value="${tag_filter#*=}"
        rgs=$(az group list --subscription "$sub" --query "[?tags.$tag_key=='$tag_value']" -o json 2>/dev/null || echo '[]')
    else
        rgs=$(az group list --subscription "$sub" --query "[?contains(keys(tags), '$tag_filter') || contains(values(tags), '$tag_filter')]" -o json 2>/dev/null || echo '[]')
    fi
    
    while IFS= read -r rg; do
        [[ -z "$rg" ]] && continue
        
        local name id tags location
        name=$(jq -r '.name // ""' <<< "$rg")
        id=$(jq -r '.id // ""' <<< "$rg")
        tags=$(jq -r '.tags // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' <<< "$rg")
        location=$(jq -r '.location // ""' <<< "$rg")
        
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
        
    done < <(jq -c '.[]' <<< "$rgs")
}

discover_all_resources_in_rg() {
    local sub="$1" sub_name="$2" rg_name="$3" rg_id="$4"
    
    log_debug "Discovering ALL resources in tagged resource group: $rg_name"
    
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
            echo "    ↳ Found Resource in Tagged RG: $name ($type)"
            log_to_file "FOUND" "Resource in Tagged RG: $name ($type) in RG: $rg_name"
            
            SUMMARY_ROWS+=("$name|$type|$sub_name|In RG: $rg_name")
            ALL_IDS+=("$id")
            
            RESOURCE_TYPES+=("$id|$type")
            RESOURCE_DETAILS+=("$id|$name|$type|$sub_name|$rg_id")
        fi
        
    done < <(jq -c '.[]' <<< "$resources")
}

discover_management_group_role_assignments() {
    if [[ -n "$TAG_FILTER" && -z "$NAME_PATTERN" ]]; then
        log_debug "Skipping management group role assignments discovery in pure tag mode"
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
    if [[ -n "$TAG_FILTER" && -z "$NAME_PATTERN" ]]; then
        log_debug "Skipping diagnostic settings discovery in pure tag mode"
        return
    fi
    
    log_info "Searching for diagnostic settings..."
    
    local subscriptions
    subscriptions=$(get_subscriptions)
    
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        
        local sub_name
        sub_name=$(az account show --subscription "$sub" --query 'name' -o tsv 2>/dev/null || echo "Unknown")
        if [[ "$sub_name" == "Unknown" ]]; then
            sub_name=$(az account list --query "[?id=='$sub'].name | [0]" -o tsv 2>/dev/null || echo "Subscription-$sub")
        fi
        
        log_debug "Checking diagnostic settings in subscription: $sub_name"
        
        local resources
        resources=$(az resource list --subscription "$sub" --query '[].id' -o tsv 2>/dev/null || echo "")
        
        for resource_id in $resources; do
            [[ -z "$resource_id" ]] && continue
            
            local diagnostic_settings
            diagnostic_settings=$(az monitor diagnostic-settings list --resource "$resource_id" -o json 2>/dev/null || echo '[]')
            
            if ! jq -e '. | type == "array"' <<< "$diagnostic_settings" >/dev/null 2>&1; then
                continue
            fi
            
            while IFS= read -r setting; do
                [[ -z "$setting" ]] && continue
                
                local name id target_resource
                name=$(jq -r '.name // ""' <<< "$setting")
                id=$(jq -r '.id // ""' <<< "$setting")
                target_resource=$(jq -r '.resourceId // ""' <<< "$setting")
                
                [[ -z "$name" || -z "$id" ]] && continue
                
                # --- Multi-pattern matching ---
                local matched_pattern
                if matched_pattern=$(matches_any_pattern "$name"); then
                    echo "  → Found Diagnostic Setting: $(highlight_matches "$name") (Resource: $(basename "$target_resource"))"
                    log_to_file "FOUND" "Diagnostic Setting: $name (Resource: $(basename "$target_resource"))"
                    SUMMARY_ROWS+=("$name|DiagnosticSetting|$sub_name|Target: $(basename "$target_resource")")
                    ALL_IDS+=("$id")
                    RESOURCE_TYPES+=("$id|DiagnosticSetting")
                    RESOURCE_DETAILS+=("$id|$name|DiagnosticSetting|$sub_name|$target_resource")
                    RESOURCES_FOUND=true
                fi
            done < <(jq -c '.[]?' <<< "$diagnostic_settings")
        done
    done <<< "$subscriptions"
    
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        
        local sub_name
        sub_name=$(az account show --subscription "$sub" --query 'name' -o tsv 2>/dev/null || echo "Unknown")
        if [[ "$sub_name" == "Unknown" ]]; then
            sub_name=$(az account list --query "[?id=='$sub'].name | [0]" -o tsv 2>/dev/null || echo "Subscription-$sub")
        fi
        
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
            
            # --- UPDATED: Multi-pattern matching ---
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
    if [[ -n "$TAG_FILTER" && -z "$NAME_PATTERN" ]]; then
        log_debug "Skipping directory diagnostic settings discovery in pure tag mode"
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
    if [[ -n "$TAG_FILTER" && -z "$NAME_PATTERN" ]]; then
        log_debug "Skipping policy assignments discovery in pure tag mode"
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
        sub_name=$(az account show --subscription "$sub" --query 'name' -o tsv 2>/dev/null)
        if [[ $? -ne 0 ]] || [[ -z "$sub_name" ]]; then
            sub_name=$(az account list --query "[?id=='$sub'].name | [0]" -o tsv 2>/dev/null)
            if [[ $? -ne 0 ]] || [[ -z "$sub_name" ]]; then
                sub_name="Subscription ($sub)"
            fi
        fi
        
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
            
            # --- UPDATED: Multi-pattern matching ---
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
    if [[ -n "$TAG_FILTER" && -z "$NAME_PATTERN" ]]; then
        log_debug "Skipping policy remediations discovery in pure tag mode"
        return
    fi
    
    log_info "Searching for policy remediations..."
    
    local subscriptions
    subscriptions=$(get_subscriptions)
    
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        
        local sub_name
        sub_name=$(az account show --subscription "$sub" --query 'name' -o tsv 2>/dev/null || echo "Unknown")
        
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
    if [[ -n "$TAG_FILTER" && -z "$NAME_PATTERN" ]]; then
        log_debug "Skipping management group deployments discovery in pure tag mode"
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
    if [[ -n "$TAG_FILTER" ]]; then
        log_debug "Skipping service principals discovery in tag mode"
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
    if [[ -n "$TAG_FILTER" ]]; then
        log_debug "Skipping custom roles discovery in tag mode"
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
    if [[ -n "$TAG_FILTER" ]]; then
        log_debug "Skipping role assignments discovery in tag mode"
        return
    fi
    
    log_info "Discovering role assignments for custom roles..."
    
    # --- Get custom roles matching any of our patterns ---
    local custom_roles=""
    for pattern in "${NAME_PATTERNS[@]}"; do
        local sanitized_pattern=$(printf '%s' "$pattern" | sed "s/'/''/g")
        local matches
        matches=$(az role definition list --custom-role-only true --query "[?contains(roleName, '$sanitized_pattern')].name" -o tsv 2>/dev/null || echo "")
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

# --- Confirmation Function ---
confirm_delete() {
    echo
    log_warning "${RED}WARNING: You are about to DELETE ${#ALL_IDS[@]} resource(s)${NC}"
    log_warning "${RED}This operation cannot be undone!${NC}"
    echo
    
    read -p "Are you absolutely sure you want to proceed? (type 'DELETE' to confirm): " confirmation
    
    if [[ "$confirmation" != "DELETE" ]]; then
        log_warning "Deletion aborted"
        echo
        exit 0
    fi
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
    # Initialize logging early - pass all arguments
    init_logging "$@"
    
    log_info "Mode: $([[ "$DRY_RUN" == true ]] && echo ${YELLOW}"DRY-RUN"${NC} || echo ${YELLOW}"DELETE"${NC})"
    
    # Add log mode info
    if [[ "$LOG_ENABLED" == true ]]; then
        log_info "Log Mode: $([[ "$APPEND_LOG" == true ]] && echo ${YELLOW}"APPEND"${NC} || echo ${YELLOW}"OVERWRITE"${NC})"
    fi
    echo
    
    if [[ -n "$TAG_FILTER" ]]; then
        log_info "Searching for resources with tag: ${YELLOW}$TAG_FILTER${NC}"
    elif [[ ${#NAME_PATTERNS[@]} -gt 1 ]]; then
        log_info "Searching for resources matching ANY of these patterns:"
        for pattern in "${NAME_PATTERNS[@]}"; do
            log_info "  • ${YELLOW}$pattern${NC}"
        done
    else
        log_info "Searching for resources containing: ${YELLOW}${NAME_PATTERN}${NC}"
    fi
    
    if [[ -n "$EXCLUDE_PATTERNS" ]]; then
        log_info "Exclude patterns/resources:"
        for pattern in "${EXCLUDE_ARRAY[@]}"; do
            log_info "  • ${YELLOW}$pattern${NC}"
        done
    fi

    echo "--------------------------------------------------------"
    log_to_file "INFO" "--------------------------------------------------------"
    # Get current subscription context
    CURRENT_SUB=$(az account show --query id -o tsv)
    log_to_file "INFO" "Current subscription ID: $CURRENT_SUB"
    # Get subscriptions
    local subscriptions
    subscriptions=$(get_subscriptions)
    if [[ -z "$subscriptions" ]]; then
        log_error "No subscriptions found"
        exit 1
    fi
    
    if [[ -n "$TAG_FILTER" ]]; then
        discover_resources_by_tag "$TAG_FILTER"
    else
        while IFS= read -r sub; do
            if [[ -z "$sub" ]]; then
                continue
            fi
            
            if az account set --subscription "$sub" >/dev/null 2>&1; then
                local sub_name
                sub_name=$(az account show --subscription "$sub" --query 'name' -o tsv 2>/dev/null || echo "Unknown")
                log_to_file "INFO" "Switched to subscription: $sub ($sub_name)"
                discover_resources "$sub" "$sub_name"
                discover_subscription_role_assignments "$sub" "$sub_name"
            else
                log_info "Accessed subscription: $sub"
            fi
        done <<< "$subscriptions"
    fi
    
    az account set --subscription "$CURRENT_SUB" >/dev/null 2>&1
    log_to_file "INFO" "Switched back to original subscription: $CURRENT_SUB"
    
    discover_management_group_role_assignments
    discover_management_group_deployments
    discover_policy_assignments
    discover_policy_remediations
    discover_diagnostic_settings
    discover_directory_diagnostic_settings
    discover_custom_roles_enhanced
    discover_role_assignments_for_custom_roles
    discover_service_principals 
    
    echo ""
    log_to_file "INFO" "Discovery phase completed"
    
    if [[ -n "$EXCLUDE_PATTERNS" ]]; then
        log_info "Applying exclude patterns: $EXCLUDE_PATTERNS"
        declare -a FILTERED_IDS
        
        for id in "${ALL_IDS[@]}"; do
            local resource_type=$(get_resource_type "$id")
            local details=$(get_resource_details "$id")
            IFS="|" read -r resource_name _ _ <<< "$details"
            
            clean_resource_name=$(echo "$resource_name" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
            
            if should_exclude "$clean_resource_name" "$resource_type" "$id"; then
                EXCLUDED_IDS+=("$id")
            else
                FILTERED_IDS+=("$id")
            fi
        done
        
        if [[ ${#EXCLUDED_IDS[@]} -gt 0 ]]; then
            log_info "Excluded ${#EXCLUDED_IDS[@]} resource(s) from deletion"
            ALL_IDS=("${FILTERED_IDS[@]}")
        else
            log_info "No resources matched exclude patterns"
        fi
    fi
    
    # --- Log info about resource groups with excluded resources (already tracked in should_exclude) --- 
    if [[ ${#RG_EXCLUDED_RESOURCES[@]} -gt 0 ]]; then
        log_info "Found ${#RG_EXCLUDED_RESOURCES[@]} excluded resource(s) in resource groups"
    fi
    
    if [[ ${#EXCLUDED_IDS[@]} -gt 0 ]]; then
        declare -a FILTERED_SUMMARY_ROWS
        for row in "${SUMMARY_ROWS[@]}"; do
            IFS="|" read -r name _ _ <<< "$row"
            clean_name=$(echo "$name" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
            
            local excluded=false
            for excluded_id in "${EXCLUDED_IDS[@]}"; do
                local details=$(get_resource_details "$excluded_id")
                IFS="|" read -r excluded_name _ _ <<< "$details"
                clean_excluded_name=$(echo "$excluded_name" | sed -E 's/\x1B\[[0-9;]*[mGK]//g')
                
                if [[ "$clean_name" == "$clean_excluded_name" ]]; then
                    excluded=true
                    break
                fi
            done
            
            if [[ "$excluded" == false ]]; then
                FILTERED_SUMMARY_ROWS+=("$row")
            fi
        done
        SUMMARY_ROWS=("${FILTERED_SUMMARY_ROWS[@]}")
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
    #  --- log_to_file "INFO" "========================================================="
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
        log_info "$0 cortex,ads --delete"
        echo
        echo -e "${YELLOW}Run with --help for more details${NC}"
        log_info "$0 cortex,ads --help"
        log_summary
        exit 0
    fi
    
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

