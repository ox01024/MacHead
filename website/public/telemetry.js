// MacHead Landing Page Telemetry Script (Privacy-first)
(function() {
  try {
    const urlParams = new URLSearchParams(window.location.search);
    const utmSource = urlParams.get('utm_source') || 'direct';
    const utmMedium = urlParams.get('utm_medium') || '';
    const utmCampaign = urlParams.get('utm_campaign') || '';

    // 1. 发送 Page View 事件
    fetch('/api/telemetry', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        event: 'page_view',
        utm_source: utmSource,
        utm_medium: utmMedium,
        utm_campaign: utmCampaign,
        referrer: document.referrer || ''
      })
    }).catch(function(err) {
      console.debug('Telemetry PV failed', err);
    });

    // 2. 监听并捕获所有 DMG 下载按钮与 GitHub 点击事件
    document.addEventListener('DOMContentLoaded', function() {
      document.addEventListener('click', function(e) {
        const target = e.target.closest('a');
        if (!target) return;
        const href = target.getAttribute('href') || '';

        if (href.includes('.dmg')) {
          fetch('/api/telemetry', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              event: 'click_download',
              download_url: href,
              utm_source: utmSource
            })
          }).catch(function() {});
        } else if (href.includes('github.com')) {
          fetch('/api/telemetry', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              event: 'click_github',
              target_url: href,
              utm_source: utmSource
            })
          }).catch(function() {});
        }
      });
    });
  } catch (e) {
    console.error('Telemetry script error', e);
  }
})();
