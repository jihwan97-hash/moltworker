#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# Cache bust: 2026-02-04-v9-openclaw-native-config
# This script:
# 1. Restores config from R2 backup if available
# 2. Configures openclaw from environment variables
# 3. Starts a background sync to backup config to R2
# 4. Starts the gateway

set -e

# Check if openclaw gateway is already running - bail early if so
if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

# Paths - use new OpenClaw native paths
CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
BACKUP_DIR="/data/moltbot"

# Also keep legacy path for migration
LEGACY_CONFIG_DIR="/root/.clawdbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

# Create config directory
mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================
# Check if R2 backup exists by looking for clawdbot.json
# The BACKUP_DIR may exist but be empty if R2 was just mounted
# Note: backup structure is $BACKUP_DIR/clawdbot/ and $BACKUP_DIR/skills/

# Helper function to check if R2 backup is newer than local
should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"

    # If no R2 sync timestamp, don't restore
    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi

    # If no local sync timestamp, restore from R2
    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi

    # Compare timestamps
    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)

    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"

    # Convert to epoch seconds for comparison
    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")

    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

# Check for OpenClaw native config backup first, then legacy
if [ -f "$BACKUP_DIR/openclaw/openclaw.json" ]; then
    if should_restore_from_r2; then
        echo "Restoring from R2 backup at $BACKUP_DIR/openclaw..."
        cp -a "$BACKUP_DIR/openclaw/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup (openclaw format)"
    fi
elif [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    # Legacy backup - copy to legacy dir, openclaw will migrate
    if should_restore_from_r2; then
        echo "Restoring from legacy R2 backup at $BACKUP_DIR/clawdbot..."
        mkdir -p "$LEGACY_CONFIG_DIR"
        cp -a "$BACKUP_DIR/clawdbot/." "$LEGACY_CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$LEGACY_CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup (legacy format, will be migrated)"
    fi
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore skills from R2 backup if available (only if R2 is newer)
SKILLS_DIR="/root/clawd/skills"
if [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring skills from $BACKUP_DIR/skills..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"
        echo "Restored skills from R2 backup"
    fi
fi

# If config file still doesn't exist, create from template
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        # Create minimal config if template doesn't exist
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
else
    echo "Using existing config"
fi

# ============================================================
# SETUP OAUTH AUTH PROFILE (if Claude Max token provided)
# ============================================================
if [ -n "$CLAUDE_ACCESS_TOKEN" ]; then
    echo "Setting up Claude Max OAuth auth profile..."
    OPENCLAW_DIR="/root/.openclaw"
    AUTH_PROFILE_DIR="$OPENCLAW_DIR/credentials"
    mkdir -p "$AUTH_PROFILE_DIR"

    # Create oauth.json with the token
    cat > "$AUTH_PROFILE_DIR/oauth.json" << EOFAUTH
{
  "anthropic": {
    "accessToken": "$CLAUDE_ACCESS_TOKEN",
    "refreshToken": "${CLAUDE_REFRESH_TOKEN:-}",
    "expiresAt": 9999999999999
  }
}
EOFAUTH
    echo "OAuth profile created at $AUTH_PROFILE_DIR/oauth.json"

    # Also create auth-profiles.json for the default agent
    AGENT_AUTH_DIR="$OPENCLAW_DIR/agents/default/agent"
    mkdir -p "$AGENT_AUTH_DIR"
    cat > "$AGENT_AUTH_DIR/auth-profiles.json" << EOFAGENTAUTH
{
  "anthropic": {
    "type": "oauth",
    "accessToken": "$CLAUDE_ACCESS_TOKEN",
    "refreshToken": "${CLAUDE_REFRESH_TOKEN:-}"
  }
}
EOFAGENTAUTH
    echo "Agent auth profile created at $AGENT_AUTH_DIR/auth-profiles.json"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << EOFNODE
const fs = require('fs');

// OpenClaw native path (newer versions)
const configPath = '/root/.openclaw/openclaw.json';
const legacyConfigPath = '/root/.clawdbot/clawdbot.json';

// Ensure config directory exists
const configDir = '/root/.openclaw';
if (!fs.existsSync(configDir)) {
    fs.mkdirSync(configDir, { recursive: true });
}

console.log('Updating config at:', configPath);
let config = {};

try {
    // Try new path first, then legacy
    if (fs.existsSync(configPath)) {
        config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    } else if (fs.existsSync(legacyConfigPath)) {
        config = JSON.parse(fs.readFileSync(legacyConfigPath, 'utf8'));
        console.log('Loaded from legacy config, will save to new path');
    }
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Clean up any broken provider configs from previous runs
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}

// Clean up invalid 'dm' key from telegram config (should be 'dmPolicy')
if (config.channels?.telegram?.dm !== undefined) {
    console.log('Removing invalid dm key from telegram config');
    delete config.channels.telegram.dm;
}

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    // Use 'open' policy in dev mode to bypass pairing, otherwise use configured policy
    if (process.env.CLAWDBOT_DEV_MODE === 'true') {
        config.channels.telegram.dmPolicy = 'open';
        config.channels.telegram.allowFrom = ['*'];
    } else {
        config.channels.telegram.dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    }
    // Group chat configuration
    config.channels.telegram.groupPolicy = 'open';      // 'open', 'allowlist', or 'disabled'
    config.channels.telegram.groupAllowFrom = ['*'];    // Allow all senders in groups
    config.channels.telegram.groups = config.channels.telegram.groups || {};
    config.channels.telegram.groups['*'] = {            // Global defaults for all groups
        requireMention: false                           // Respond to ALL messages (no mention needed)
    };
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = process.env.DISCORD_DM_POLICY || 'pairing';
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// ============================================================
// PLUGINS CONFIGURATION (required to enable channels)
// ============================================================
config.plugins = config.plugins || {};
config.plugins.entries = config.plugins.entries || {};

if (process.env.TELEGRAM_BOT_TOKEN) {
    config.plugins.entries.telegram = { enabled: true };
}
if (process.env.DISCORD_BOT_TOKEN) {
    config.plugins.entries.discord = { enabled: true };
}
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.plugins.entries.slack = { enabled: true };
}

// ============================================================
// MODEL PROVIDER CONFIGURATION
// ============================================================
// Priority: Claude Max OAuth > AI Gateway > Direct API

config.models = config.models || {};
config.models.providers = config.models.providers || {};

// Check for Claude Max OAuth token (uses subscription instead of API credits)
if (process.env.CLAUDE_ACCESS_TOKEN) {
    console.log('Configuring Claude Max OAuth authentication (subscription-based)');

    // Use anthropic provider with OAuth token
    // OAuth tokens (sk-ant-oat) work with standard Anthropic API endpoint
    config.models.providers.anthropic = {
        baseUrl: 'https://api.anthropic.com',
        api: 'anthropic-messages',
        apiKey: process.env.CLAUDE_ACCESS_TOKEN,
        models: [
            { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
            { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
            { id: 'claude-sonnet-4-20250514', name: 'Claude Sonnet 4', contextWindow: 200000 },
            { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
        ]
    };

    // Add models to the allowlist
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
    config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
    config.agents.defaults.models['anthropic/claude-sonnet-4-20250514'] = { alias: 'Sonnet 4' };
    config.agents.defaults.models['anthropic/claude-haiku-4-5-20251001'] = { alias: 'Haiku 4.5' };

    // Use Claude Max as default
    config.agents.defaults.model.primary = 'anthropic/claude-sonnet-4-5-20250929';

} else {
    // Fallback to API key authentication
    const baseUrl = (process.env.AI_GATEWAY_BASE_URL || process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');
    const isOpenAI = baseUrl.endsWith('/openai');

    if (isOpenAI) {
        console.log('Configuring OpenAI provider with base URL:', baseUrl);
        config.models.providers.openai = {
            baseUrl: baseUrl,
            api: 'openai-responses',
            models: [
                { id: 'gpt-5.2', name: 'GPT-5.2', contextWindow: 200000 },
                { id: 'gpt-5', name: 'GPT-5', contextWindow: 200000 },
                { id: 'gpt-4.5-preview', name: 'GPT-4.5 Preview', contextWindow: 128000 },
            ]
        };
        config.agents.defaults.models = config.agents.defaults.models || {};
        config.agents.defaults.models['openai/gpt-5.2'] = { alias: 'GPT-5.2' };
        config.agents.defaults.models['openai/gpt-5'] = { alias: 'GPT-5' };
        config.agents.defaults.models['openai/gpt-4.5-preview'] = { alias: 'GPT-4.5' };
        config.agents.defaults.model.primary = 'openai/gpt-5.2';
    } else if (baseUrl) {
        console.log('Configuring Anthropic provider with base URL:', baseUrl);
        const providerConfig = {
            baseUrl: baseUrl,
            api: 'anthropic-messages',
            models: [
                { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
                { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
                { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
            ]
        };
        if (process.env.ANTHROPIC_API_KEY) {
            providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
        }
        config.models.providers.anthropic = providerConfig;
        config.agents.defaults.models = config.agents.defaults.models || {};
        config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
        config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
        config.agents.defaults.models['anthropic/claude-haiku-4-5-20251001'] = { alias: 'Haiku 4.5' };
        config.agents.defaults.model.primary = 'anthropic/claude-sonnet-4-5-20250929';
    } else {
        console.log('Configuring Anthropic provider for direct API access');
        const providerConfig = {
            baseUrl: 'https://api.anthropic.com',
            api: 'anthropic-messages',
            models: [
                { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
                { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
                { id: 'claude-sonnet-4-20250514', name: 'Claude Sonnet 4', contextWindow: 200000 },
                { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
            ]
        };
        if (process.env.ANTHROPIC_API_KEY) {
            providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
        }
        config.models.providers.anthropic = providerConfig;
        config.agents.defaults.models = config.agents.defaults.models || {};
        config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
        config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
        config.agents.defaults.models['anthropic/claude-sonnet-4-20250514'] = { alias: 'Sonnet 4' };
        config.agents.defaults.models['anthropic/claude-haiku-4-5-20251001'] = { alias: 'Haiku 4.5' };
        config.agents.defaults.model.primary = 'anthropic/claude-sonnet-4-5-20250929';
    }
}

// Web search configuration (Brave Search API)
if (process.env.BRAVE_API_KEY) {
    console.log('Configuring Brave Search API');
    config.tools = config.tools || {};
    config.tools.web = config.tools.web || {};
    config.tools.web.search = config.tools.web.search || {};
    config.tools.web.search.apiKey = process.env.BRAVE_API_KEY;
}

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config:', JSON.stringify(config, null, 2));
EOFNODE

# ============================================================
# START GATEWAY
# ============================================================
# Note: R2 backup sync is handled by the Worker's cron trigger
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"
echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}, Bind mode: $BIND_MODE"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE"
fi
