// MacHead Landing Page Telemetry Script (Privacy-first)
(function() {
  try {
    const urlParams = new URLSearchParams(window.location.search);
    const utmSource = urlParams.get('utm_source') || 'direct';
    const utmMedium = urlParams.get('utm_medium') || '';
    const utmCampaign = urlParams.get('utm_campaign') || '';
    // 脚本加载时捕获一次来源 Referrer，供后续所有事件归因使用
    const pageReferrer = document.referrer || '';

    // 统一上报函数：所有事件均携带完整渠道归因字段
    function sendTelemetry(payload) {
      return fetch('/api/telemetry', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(Object.assign({
          utm_source: utmSource,
          utm_medium: utmMedium,
          utm_campaign: utmCampaign,
          referrer: pageReferrer
        }, payload))
      }).catch(function(err) {
        console.debug('Telemetry failed', payload.event, err);
      });
    }

    // 1. 发送 Page View 事件
    sendTelemetry({ event: 'page_view' });

    // 2. 监听并捕获所有 DMG 下载按钮与 GitHub 点击事件
    document.addEventListener('DOMContentLoaded', function() {
      document.addEventListener('click', function(e) {
        const target = e.target.closest('a');
        if (!target) return;
        const href = target.getAttribute('href') || '';

        if (href.includes('.dmg') || href === '/download' || href.endsWith('/download')) {
          sendTelemetry({
            event: 'click_download',
            download_url: href
          });
        } else if (href.includes('github.com')) {
          sendTelemetry({
            event: 'click_github',
            target_url: href
          });
        }
      });
    });
  } catch (e) {
    console.error('Telemetry script error', e);
  }
})();
