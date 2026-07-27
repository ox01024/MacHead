-- Cloudflare D1 SQL Schema for MacHead Telemetry
-- Database Binding Name: DB

CREATE TABLE IF NOT EXISTS telemetry_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event TEXT NOT NULL,                  -- 'page_view', 'click_download', 'app_heartbeat', 'app_event'
    anonymous_id TEXT,                    -- 客户端匿名 UUID
    app_version TEXT,                     -- 例如 '0.1.14'
    build_number TEXT,                    -- 例如 '18'
    os_version TEXT,                      -- macOS 系统版本
    arch TEXT,                            -- 'arm64' 或 'x86_64'
    is_headless INTEGER DEFAULT 0,        -- 是否在 Headless 无头模式 (1/0)
    is_launch_at_login INTEGER DEFAULT 0, -- 是否开启开机自启 (1/0)
    is_web_dashboard_enabled INTEGER DEFAULT 0, -- 是否开启 Web 面板 (1/0)
    auth_accessibility INTEGER DEFAULT 0, -- 是否已授辅助功能权限 (1/0)
    uptime_seconds INTEGER DEFAULT 0,     -- 系统运行时间（秒）
    utm_source TEXT,                      -- 获客来源渠道 (例如 v2ex, github, reddit)
    utm_medium TEXT,                      -- 媒介 (例如 readme, cpc)
    referrer TEXT,                        -- 来源 HTTP Referrer
    extra_action TEXT,                    -- 'enable_headless', 'battery_protection_fired' 等
    country TEXT,                         -- 国家/地区代码 (Cloudflare Edge 自动注入)
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- 高频分析索引
CREATE INDEX IF NOT EXISTS idx_event_created ON telemetry_events(event, created_at);
CREATE INDEX IF NOT EXISTS idx_anonymous_created ON telemetry_events(anonymous_id, created_at);
CREATE INDEX IF NOT EXISTS idx_utm_source ON telemetry_events(utm_source);
