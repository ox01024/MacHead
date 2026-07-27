/**
 * Cloudflare Pages Function: /api/telemetry
 * Handles incoming web and app telemetry events and writes them to Cloudflare D1.
 */
export async function onRequestPost(context) {
  const { request, env } = context;
  
  // 设置 CORS Header
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Content-Type': 'application/json'
  };

  try {
    const payload = await request.json();
    const country = request.cf?.country || 'Unknown';

    // 如果未绑定 D1 数据库 (env.DB)，降级为 Console 日志记录（防报错）
    if (!env.DB) {
      console.log('[Telemetry Log]', JSON.stringify({ country, ...payload }));
      return new Response(JSON.stringify({ status: 'ok', mode: 'log_only' }), {
        status: 200,
        headers: corsHeaders
      });
    }

    // 写入 Cloudflare D1 数据库
    await env.DB.prepare(`
      INSERT INTO telemetry_events (
        event, anonymous_id, app_version, build_number, os_version, arch,
        is_headless, is_launch_at_login, is_web_dashboard_enabled,
        auth_accessibility, uptime_seconds, utm_source, utm_medium,
        referrer, extra_action, country
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      payload.event || 'unknown',
      payload.anonymous_id || null,
      payload.app_version || null,
      payload.build_number || null,
      payload.os_version || null,
      payload.arch || null,
      payload.is_headless ? 1 : 0,
      payload.is_launch_at_login ? 1 : 0,
      payload.is_web_dashboard_enabled ? 1 : 0,
      payload.auth_accessibility ? 1 : 0,
      payload.uptime_seconds || 0,
      payload.utm_source || null,
      payload.utm_medium || null,
      payload.referrer || null,
      payload.action || payload.extra_action || null,
      country
    ).run();

    return new Response(JSON.stringify({ status: 'ok' }), {
      status: 200,
      headers: corsHeaders
    });
  } catch (err) {
    console.error('Telemetry Handler Error:', err);
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: corsHeaders
    });
  }
}

export async function onRequestOptions() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type'
    }
  });
}
