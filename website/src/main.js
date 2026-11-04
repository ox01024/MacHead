/* -------------------------------------------------------------
 * MacHead Landing Page Interactivity Script (Bilingual zh-CN / en)
 * CLI Terminal typing simulation, Live Web Stats, Language Switcher,
 * and IntersectionObserver Fallback for Scroll-driven animations
 * ------------------------------------------------------------- */

import './style.css';

const IS_EN =
    (document.documentElement.lang && document.documentElement.lang.toLowerCase().startsWith('en')) ||
    window.location.pathname === '/en' ||
    window.location.pathname.startsWith('/en/');

document.addEventListener('DOMContentLoaded', () => {
    // 0a. Language Switcher Cookie Persistence (Client-side + Edge Middleware)
    document.querySelectorAll('[data-set-lang]').forEach(link => {
        link.addEventListener('click', () => {
            const targetLang = link.getAttribute('data-set-lang');
            if (targetLang === 'zh' || targetLang === 'en') {
                document.cookie = `mh_locale=${targetLang}; Path=/; Max-Age=31536000; SameSite=Lax`;
                try {
                    localStorage.setItem('mh_locale', targetLang);
                } catch (_) {
                    // Ignore storage restrictions
                }
            }
        });
    });

    // 0b. Mobile hamburger navigation
    const menuToggle = document.getElementById('nav-menu-toggle');
    const navLinks = document.getElementById('nav-links');
    if (menuToggle && navLinks) {
        const openLabel = IS_EN ? 'Open navigation menu' : '打开导航菜单';
        const closeLabel = IS_EN ? 'Close navigation menu' : '关闭导航菜单';

        const closeMenu = () => {
            navLinks.classList.remove('open');
            menuToggle.classList.remove('open');
            menuToggle.setAttribute('aria-expanded', 'false');
            menuToggle.setAttribute('aria-label', openLabel);
        };

        menuToggle.addEventListener('click', () => {
            const isOpen = navLinks.classList.toggle('open');
            menuToggle.classList.toggle('open', isOpen);
            menuToggle.setAttribute('aria-expanded', String(isOpen));
            menuToggle.setAttribute('aria-label', isOpen ? closeLabel : openLabel);
        });

        navLinks.querySelectorAll('a').forEach(link => {
            link.addEventListener('click', closeMenu);
        });

        window.addEventListener('resize', () => {
            if (window.innerWidth > 768) closeMenu();
        });
    }

    // 1. Copy Shell Command to Clipboard
    const copyBtn = document.getElementById('copy-hero-cmd');
    if (copyBtn) {
        copyBtn.addEventListener('click', () => {
            const textToCopy = copyBtn.getAttribute('data-clipboard');
            navigator.clipboard.writeText(textToCopy).then(() => {
                const originalSvg = copyBtn.innerHTML;
                copyBtn.innerHTML = `
                    <svg class="copy-icon text-emerald" viewBox="0 0 24 24" width="16" height="16" stroke="#10b981" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round">
                        <polyline points="20 6 9 17 4 12"></polyline>
                    </svg>
                `;
                copyBtn.title = IS_EN ? 'Copied' : '已复制';
                setTimeout(() => {
                    copyBtn.innerHTML = originalSvg;
                    copyBtn.title = IS_EN ? 'Copy command' : '复制安装命令';
                }, 1500);
            }).catch(err => {
                console.error('Failed to copy text: ', err);
            });
        });
    }

    // 2. Playground Tabs Switching
    const tabBtns = document.querySelectorAll('.tab-btn');
    const tabPanels = document.querySelectorAll('.tab-panel');

    tabBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            const targetTab = btn.getAttribute('data-tab');

            tabBtns.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');

            tabPanels.forEach(panel => {
                if (panel.id === `panel-${targetTab}`) {
                    panel.classList.add('active');
                } else {
                    panel.classList.remove('active');
                }
            });
        });
    });

    // 3. CLI Simulator typing & execution logic
    const cliConsole = document.getElementById('cli-console');
    const cmdButtons = document.querySelectorAll('.cli-cmd-btn[data-cmd]');
    let isTyping = false;

    const cmdOutputsZh = {
        status: `运行模式: 正常显示 (内置屏幕已点亮)\nWeb 控制台: 运行中 (http://192.168.100.131:8080)\n合盖防休眠: 未启用\n当前电源: 交流电源 (电池 100%)\n无头模式内置键鼠防误触: 已就绪`,
        enable: `MacHead: 正在启用无头模式...\nMacHead: 已通过 SkyLight 逻辑切断内置屏幕电源\nMacHead: 内置麦克风已自动静音锁定\nMacHead: 合盖防休眠电源断言已锁定\nWeb 控制台: http://192.168.100.131:8080\n运行模式: 无头服务器模式 (内置屏幕已断电)`,
        disable: `MacHead: 正在退出无头模式...\nMacHead: 内置屏幕已恢复供电与点亮\nMacHead: 内置麦克风静音已解除\nMacHead: 防休眠电源断言已释放\n运行模式: 正常显示 (内置屏幕已点亮)`,
        'sleep-prevent': `MacHead: 正在开启合盖防休眠断言...\nMacHead: 系统电源断言锁定成功 (ID: 3274)\n合盖防休眠: 已启用\n系统将在合盖状态下持续保持唤醒运行。`
    };

    const cmdOutputsEn = {
        status: `Mode: NORMAL (Active Screen)\nWebServer: RUNNING (http://192.168.100.131:8080)\nSleep Prevention: DISABLED\nPower Source: AC Power (Battery 100%)\nKeyboard/Trackpad Lockout in Headless: READY`,
        enable: `MacHead: Enabling Headless Server Mode...\nMacHead: Internal display logically powered off via SkyLight\nMacHead: Built-in microphone muted\nMacHead: Clamshell sleep prevention assertion locked\nWebServer: http://192.168.100.131:8080\nMode: HEADLESS (Internal Display powered off)`,
        disable: `MacHead: Disabling Headless Server Mode...\nMacHead: Internal display power restored\nMacHead: Built-in microphone unmuted\nMacHead: Sleep assertion released\nMode: NORMAL (Active Screen)`,
        'sleep-prevent': `MacHead: Acquiring clamshell sleep assertion...\nMacHead: IOPMAssertion locked (ID: 3274)\nSleep Prevention: ENABLED\nSystem will stay awake continuously with lid closed.`
    };

    const cmdOutputs = IS_EN ? cmdOutputsEn : cmdOutputsZh;

    function simulateTyping(cmdText, callback) {
        if (isTyping || !cliConsole) return;
        isTyping = true;

        const lastLine = cliConsole.lastElementChild;
        if (lastLine && lastLine.classList.contains('terminal-line') && lastLine.querySelector('.cursor-blink')) {
            lastLine.remove();
        }

        const inputLine = document.createElement('div');
        inputLine.className = 'terminal-line';
        inputLine.innerHTML = `<span class="prompt">$</span> <span class="input-cmd"></span><span class="cursor-blink">_</span>`;
        cliConsole.appendChild(inputLine);

        const cmdSpan = inputLine.querySelector('.input-cmd');
        let index = 0;

        function typeChar() {
            if (index < cmdText.length) {
                cmdSpan.textContent += cmdText[index];
                index++;
                setTimeout(typeChar, 40);
            } else {
                isTyping = false;
                const cursor = inputLine.querySelector('.cursor-blink');
                if (cursor) cursor.remove();
                callback();
            }
            cliConsole.scrollTop = cliConsole.scrollHeight;
        }

        typeChar();
    }

    function runCommandSimulation(cmdKey) {
        if (!cmdOutputs[cmdKey]) return;
        const displayArg = cmdKey === 'sleep-prevent' ? 'sleep prevent' : cmdKey;
        const fullCmd = `machead ${displayArg}`;
        simulateTyping(fullCmd, () => {
            const outputDiv = document.createElement('div');
            outputDiv.className = 'terminal-output';
            outputDiv.innerHTML = cmdOutputs[cmdKey].replace(/\n/g, '<br/>');
            cliConsole.appendChild(outputDiv);

            const newPrompt = document.createElement('div');
            newPrompt.className = 'terminal-line';
            newPrompt.innerHTML = `<span class="prompt">$</span> <span class="cursor-blink">_</span>`;
            cliConsole.appendChild(newPrompt);
            cliConsole.scrollTop = cliConsole.scrollHeight;
        });
    }

    cmdButtons.forEach(btn => {
        btn.addEventListener('click', () => {
            const cmdKey = btn.getAttribute('data-cmd');
            runCommandSimulation(cmdKey);
        });
    });

    // 4. Web Console Mockup Simulator (Login & Dashboard)
    const loginForm = document.getElementById('web-login-form');
    const loginPass = document.getElementById('web-login-pass');
    const loginError = document.getElementById('web-login-error');
    const loginScreen = document.getElementById('web-mockup-login');
    const dashboardScreen = document.getElementById('web-mockup-dashboard');

    const themeToggle = document.getElementById('web-mockup-theme-toggle');
    const mockupWrapper = document.getElementById('web-mockup-wrapper');
    const logoutBtn = document.getElementById('web-mockup-logout');

    const headlessToggle = document.getElementById('web-headless-toggle');
    const mockModeDot = document.getElementById('web-mode-dot');
    const mockModeText = document.getElementById('web-mode-text');
    const mockLidVal = document.getElementById('web-lid-val');
    const mockAlertBox = document.getElementById('web-mock-alert-box');

    if (themeToggle && mockupWrapper) {
        themeToggle.addEventListener('click', () => {
            const currentTheme = mockupWrapper.getAttribute('data-mock-theme');
            const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
            mockupWrapper.setAttribute('data-mock-theme', newTheme);
            if (IS_EN) {
                themeToggle.textContent = newTheme === 'dark' ? 'Light Mode' : 'Dark Mode';
            } else {
                themeToggle.textContent = newTheme === 'dark' ? '浅色模式' : '深色模式';
            }
        });
    }

    if (logoutBtn && loginScreen && dashboardScreen && loginPass && loginError) {
        logoutBtn.addEventListener('click', () => {
            dashboardScreen.style.display = 'none';
            loginScreen.style.display = 'flex';
            loginPass.value = '';
            loginError.style.display = 'none';
        });
    }

    function updateHeadlessUI() {
        if (!headlessToggle) return;
        const isHeadless = headlessToggle.checked;
        if (isHeadless) {
            if (mockModeDot) {
                mockModeDot.className = 'status-dot active';
                mockModeDot.style.backgroundColor = '#42b883';
            }
            if (mockModeText) mockModeText.textContent = IS_EN ? 'Headless Active' : '无头模式已激活';
            if (mockLidVal) mockLidVal.textContent = IS_EN ? '💻 Clamshell' : '💻 合盖状态';
            if (mockAlertBox) mockAlertBox.style.display = 'block';
        } else {
            if (mockModeDot) {
                mockModeDot.className = 'status-dot';
                mockModeDot.style.backgroundColor = '#007aff';
            }
            if (mockModeText) mockModeText.textContent = IS_EN ? 'Normal Mode' : '常规显示模式';
            if (mockLidVal) mockLidVal.textContent = IS_EN ? '💻 Screen Active' : '💻 内屏亮起';
            if (mockAlertBox) mockAlertBox.style.display = 'none';
        }
    }

    if (headlessToggle) {
        headlessToggle.addEventListener('change', updateHeadlessUI);
    }

    let attempts = 0;
    if (loginForm && loginPass && loginError && loginScreen && dashboardScreen) {
        loginForm.addEventListener('submit', (e) => {
            e.preventDefault();
            const pass = loginPass.value.trim().toLowerCase();
            if (pass === 'admin' || pass === 'machead' || pass.startsWith('mh-') || attempts >= 1) {
                loginError.style.display = 'none';
                loginScreen.style.display = 'none';
                dashboardScreen.style.display = 'block';
                drawAllSparklines();
            } else {
                attempts++;
                loginError.style.display = 'block';
                loginPass.value = '';
                loginPass.focus();
            }
        });
    }

    const webCpuVal = document.getElementById('web-cpu-val');
    const webRamVal = document.getElementById('web-ram-val');
    const webGpuVal = document.getElementById('web-gpu-val');

    const historyLimit = 30;
    const mockCpuHistory = Array.from({ length: historyLimit }, () => Math.floor(Math.random() * 10) + 15);
    const mockRamHistory = Array.from({ length: historyLimit }, () => 16);
    const mockGpuHistory = Array.from({ length: historyLimit }, () => Math.floor(Math.random() * 5) + 5);
    const mockRxHistory = Array.from({ length: historyLimit }, () => Math.floor(Math.random() * 20480) + 40960);
    const mockTxHistory = Array.from({ length: historyLimit }, () => Math.floor(Math.random() * 4096) + 2048);

    let cpuPeak = 28;
    let ramPeak = 16;
    let rxPeak = 124 * 1024;
    let txPeak = 12 * 1024;

    function formatSpeed(bytesPerSec) {
        if (bytesPerSec < 1024) return Math.round(bytesPerSec) + ' B/s';
        const kb = bytesPerSec / 1024;
        if (kb < 1024) return kb.toFixed(1) + ' KB/s';
        const mb = kb / 1024;
        return mb.toFixed(1) + ' MB/s';
    }

    function drawMockSparkline(lineId, fillId, data, maxVal, width = 160, height = 30) {
        const lineEl = document.getElementById(lineId);
        const fillEl = document.getElementById(fillId);
        if (!lineEl || data.length < 2) return;

        const stepX = width / (data.length - 1 || 1);
        let pathD = '';
        let fillD = '';

        for (let i = 0; i < data.length; i++) {
            const val = data[i];
            const x = i * stepX;
            const y = height - (val / maxVal) * (height - 4) - 2;

            if (i === 0) {
                pathD += 'M ' + x.toFixed(1) + ' ' + y.toFixed(1);
                fillD += 'M ' + x.toFixed(1) + ' ' + height + ' L ' + x.toFixed(1) + ' ' + y.toFixed(1);
            } else {
                pathD += ' L ' + x.toFixed(1) + ' ' + y.toFixed(1);
                fillD += ' L ' + x.toFixed(1) + ' ' + y.toFixed(1);
            }
        }
        fillD += ' L ' + ((data.length - 1) * stepX).toFixed(1) + ' ' + height + ' Z';
        lineEl.setAttribute('d', pathD);
        if (fillEl) fillEl.setAttribute('d', fillD);
    }

    function drawMockDoubleSparkline(rxLineId, rxFillId, txLineId, txFillId, rxData, txData) {
        const rxMax = Math.max(...rxData, 1024);
        const txMax = Math.max(...txData, 1024);
        const maxVal = Math.max(rxMax, txMax, 102400);
        const width = 320;
        const height = 35;

        const drawSingle = (lineEl, fillEl, data) => {
            if (!lineEl || data.length < 2) return;
            const stepX = width / (data.length - 1 || 1);
            let pathD = '';
            let fillD = '';
            for (let i = 0; i < data.length; i++) {
                const val = data[i];
                const x = i * stepX;
                const y = height - (val / maxVal) * (height - 4) - 2;
                if (i === 0) {
                    pathD += 'M ' + x.toFixed(1) + ' ' + y.toFixed(1);
                    fillD += 'M ' + x.toFixed(1) + ' ' + height + ' L ' + x.toFixed(1) + ' ' + y.toFixed(1);
                } else {
                    pathD += ' L ' + x.toFixed(1) + ' ' + y.toFixed(1);
                    fillD += ' L ' + x.toFixed(1) + ' ' + y.toFixed(1);
                }
            }
            fillD += ' L ' + ((data.length - 1) * stepX).toFixed(1) + ' ' + height + ' Z';
            lineEl.setAttribute('d', pathD);
            if (fillEl) fillEl.setAttribute('d', fillD);
        };

        drawSingle(document.getElementById(rxLineId), document.getElementById(rxFillId), rxData);
        drawSingle(document.getElementById(txLineId), document.getElementById(txFillId), txData);
    }

    function drawAllSparklines() {
        drawMockSparkline('web-cpu-spark-line', 'web-cpu-spark-fill', mockCpuHistory, 100);
        drawMockSparkline('web-ram-spark-line', 'web-ram-spark-fill', mockRamHistory, 100);
        drawMockSparkline('web-gpu-spark-line', 'web-gpu-spark-fill', mockGpuHistory, 100);
        drawMockDoubleSparkline('web-rx-spark-line', 'web-rx-spark-fill', 'web-tx-spark-line', 'web-tx-spark-fill', mockRxHistory, mockTxHistory);
    }

    setInterval(() => {
        if (dashboardScreen && dashboardScreen.style.display === 'none') return;

        const currentCpu = Math.floor(Math.random() * 15) + 15;
        if (webCpuVal) webCpuVal.textContent = `${currentCpu}%`;
        mockCpuHistory.push(currentCpu);
        if (mockCpuHistory.length > historyLimit) mockCpuHistory.shift();
        drawMockSparkline('web-cpu-spark-line', 'web-cpu-spark-fill', mockCpuHistory, 100);

        if (currentCpu > cpuPeak) cpuPeak = currentCpu;
        const peaksLabel = document.getElementById('web-hardware-peaks');
        if (peaksLabel) {
            peaksLabel.textContent = IS_EN
                ? `Peak - CPU: ${cpuPeak}% | RAM: ${ramPeak}%`
                : `峰值 - CPU: ${cpuPeak}% | RAM: ${ramPeak}%`;
        }

        const cpuCircle = document.getElementById('mock-cpu-circle');
        if (cpuCircle) {
            cpuCircle.style.strokeDashoffset = 175.9 - (currentCpu / 100) * 175.9;
        }
        const mockCpuTemp = (48.0 + (Math.random() * 2.0 - 1.0)).toFixed(1);
        const cpuTempEl = document.getElementById('web-cpu-temp');
        if (cpuTempEl) {
            cpuTempEl.textContent = IS_EN ? `Temp: ${mockCpuTemp} °C` : `温度: ${mockCpuTemp} °C`;
        }

        const currentRam = (Math.random() > 0.8) ? (Math.random() > 0.5 ? 17 : 15) : 16;
        if (webRamVal) webRamVal.textContent = `${currentRam}%`;
        mockRamHistory.push(currentRam);
        if (mockRamHistory.length > historyLimit) mockRamHistory.shift();
        drawMockSparkline('web-ram-spark-line', 'web-ram-spark-fill', mockRamHistory, 100);
        if (currentRam > ramPeak) ramPeak = currentRam;
        const ramCircle = document.getElementById('mock-ram-circle');
        if (ramCircle) {
            ramCircle.style.strokeDashoffset = 175.9 - (currentRam / 100) * 175.9;
        }
        const mockRamUsed = (8.1 + (Math.random() * 0.4 - 0.2)).toFixed(2);
        const ramDetailsEl = document.getElementById('web-ram-details');
        if (ramDetailsEl) {
            ramDetailsEl.textContent = IS_EN
                ? `Used: ${mockRamUsed} GB / 32.0 GB`
                : `已用: ${mockRamUsed} GB / 32.0 GB`;
        }

        const currentGpu = Math.floor(Math.random() * 8) + 4;
        if (webGpuVal) webGpuVal.textContent = `${currentGpu}%`;
        mockGpuHistory.push(currentGpu);
        if (mockGpuHistory.length > historyLimit) mockGpuHistory.shift();
        drawMockSparkline('web-gpu-spark-line', 'web-gpu-spark-fill', mockGpuHistory, 100);
        const gpuCircle = document.getElementById('mock-gpu-circle');
        if (gpuCircle) {
            gpuCircle.style.strokeDashoffset = 175.9 - (currentGpu / 100) * 175.9;
        }
        const mockVramUsed = (0.82 + (Math.random() * 0.1 - 0.05)).toFixed(2);
        const gpuVramEl = document.getElementById('web-gpu-vram');
        if (gpuVramEl) {
            gpuVramEl.textContent = IS_EN
                ? `VRAM: ${mockVramUsed} GB / 16.0 GB`
                : `显存: ${mockVramUsed} GB / 16.0 GB`;
        }

        const rxSpeed = Math.floor(Math.random() * 50 * 1024) + 50 * 1024;
        const txSpeed = Math.floor(Math.random() * 10 * 1024) + 2 * 1024;

        const netRxEl = document.getElementById('web-net-rx');
        const netTxEl = document.getElementById('web-net-tx');
        if (netRxEl) netRxEl.textContent = '↓ ' + formatSpeed(rxSpeed);
        if (netTxEl) netTxEl.textContent = '↑ ' + formatSpeed(txSpeed);

        mockRxHistory.push(rxSpeed);
        if (mockRxHistory.length > historyLimit) mockRxHistory.shift();
        mockTxHistory.push(txSpeed);
        if (mockTxHistory.length > historyLimit) mockTxHistory.shift();
        drawMockDoubleSparkline('web-rx-spark-line', 'web-rx-spark-fill', 'web-tx-spark-line', 'web-tx-spark-fill', mockRxHistory, mockTxHistory);

        if (rxSpeed > rxPeak) {
            rxPeak = rxSpeed;
            const rxPeakEl = document.getElementById('web-rx-peak');
            if (rxPeakEl) {
                rxPeakEl.textContent = IS_EN
                    ? `↓ Peak: ${formatSpeed(rxPeak)}`
                    : `↓ 峰值: ${formatSpeed(rxPeak)}`;
            }
        }
        if (txSpeed > txPeak) {
            txPeak = txSpeed;
            const txPeakEl = document.getElementById('web-tx-peak');
            if (txPeakEl) {
                txPeakEl.textContent = IS_EN
                    ? `↑ Peak: ${formatSpeed(txPeak)}`
                    : `↑ 峰值: ${formatSpeed(txPeak)}`;
            }
        }
    }, 3000);

    // 5. Scroll driven animations fallback using IntersectionObserver
    if (!CSS.supports('(animation-timeline: view()) and (animation-range: entry)')) {
        const scrollEffects = document.querySelectorAll('.scroll-effect');
        scrollEffects.forEach(el => {
            el.classList.add('no-supports-scroll-reveal');
        });

        const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('reveal-active');
                    observer.unobserve(entry.target);
                }
            });
        }, {
            threshold: 0.15
        });

        scrollEffects.forEach(el => {
            observer.observe(el);
        });
    }

    // 6. Centralized Dynamic Version Synchronizer (keeps /download self-healing gateway on links)
    function syncReleaseMetadata(version) {
        const downloadElements = document.querySelectorAll('.js-download-link, #download-header-link, #download-hero-link, #download-cta-link');
        downloadElements.forEach(el => {
            el.setAttribute('href', '/download');
        });

        const badgeElements = document.querySelectorAll('.js-version-badge, .hero-badge .badge-text');
        badgeElements.forEach(el => {
            el.textContent = IS_EN
                ? `v${version} Universal · Apple Silicon & Intel`
                : `v${version} Universal · 支持 Apple Silicon 与 Intel`;
        });

        const ctaBtn = document.getElementById('download-cta-link');
        if (ctaBtn) {
            ctaBtn.textContent = IS_EN
                ? `Download macOS Universal DMG v${version}`
                : `下载 macOS Universal DMG v${version}`;
        }

        const ldScript = document.getElementById('schema-json-ld');
        if (ldScript) {
            try {
                const schema = JSON.parse(ldScript.textContent);
                schema.softwareVersion = version;
                schema.downloadUrl = 'https://headlessmac.com/download';
                ldScript.textContent = JSON.stringify(schema, null, 2);
            } catch (e) {
                console.warn('MacHead Web: Could not update JSON-LD schema', e);
            }
        }
    }

    fetch(`/appcast.json?t=${Date.now()}`, { cache: 'no-store' })
        .then(res => res.ok ? res.json() : Promise.reject(res.status))
        .then(data => {
            if (data && data.version) {
                syncReleaseMetadata(data.version);
            }
        })
        .catch(err => {
            console.warn('MacHead Web: Using fallback release metadata due to appcast fetch status:', err);
        });
});

// 7. Landing Page Changelog Minimalist Feed Renderer (Bilingual)
const CHANGELOG_DATA_ZH = [
    {
        version: '0.1.27',
        date: '2026-10-25',
        title: 'MacHead Cloud 云端控制台、三轨 E2EE 远程终端与全链路安全加固',
        bullets: [
            '新增 MacHead Cloud 云端远程控制台 (dash.headlessmac.com)，支持 GitHub / Google 账号 PKCE 安全绑定与免码一键直连。',
            '新增 Happy Eyeballs 三轨自适应传输引擎：本机 Loopback 零延迟直连、局域网 WebRTC P2P 直连、跨网 Tailcat WireGuard E2EE 端到端加密隧道。',
            '新增多标签 Web 远程终端、远程文件管理器（拖拽上传与 UTF-8/GB18030 在线代码编辑）及远程硬件遥测与无头模式控制看板。',
            '全链路安全加固：云端 D1 隧道地址启用 AES-256-GCM 信封加密落库，内置 Go 原生终端口令门禁（防信号中断绕过），客户端令牌升级为 AES-GCM 硬件派生加密保险箱（0600 权限）。'
        ]
    },
    {
        version: '0.1.25',
        date: '2026-10-14',
        title: '重启或退出后开机自动进入无头模式修复',
        bullets: [
            '修复重启系统或重新打开应用后无法自动恢复无头模式屏蔽内屏的问题。',
            '优化开机自启与显示器状态接管时序。'
        ]
    },
    {
        version: '0.1.23',
        date: '2026-09-23',
        title: 'Web 控制台自定义端口与原生远程管理状态感知',
        bullets: [
            '局域网 Web 控制面板支持自定义服务端口，并提供特权端口与范围实时校验提示。',
            '偏好设置面板与快捷菜单栏动态显示实际运行的访问地址与一键复制链接。',
            'Microsoft Dev Tunnels 与 FRP 内网穿透服务规则自动联动同步自定义 Web 端口。',
            '新增 macOS 原生远程管理感知：秒级检测本机 SSH (22)、屏幕共享 VNC (5900)、文件共享 SMB (445) 服务端口状态。',
            '提供专属快捷命令与一键复制功能（如 ssh user@ip、vnc://ip、smb://ip），并支持一键直达系统共享设置面板。'
        ]
    },
    {
        version: '0.1.22',
        date: '2026-09-23',
        title: '全景电池管理、智能 UPS 守护与防鼓包限充',
        bullets: [
            '偏好设置新增独立「电池」专区，对齐 macOS 原生设计规范与图标体系。',
            '全景电气与健康指标：实时充放电功率 (W)、母线电压/电流、充电适配器规格、最大可用容量与原厂设计容量对比。',
            '智能 UPS 模式：市电中断时自动推算剩余续航倒计时，并增强 Bark / Telegram / 系统级断电预警。',
            '防鼓包充电上限 (Charge Limit)：支持 50%~90% 调节与 Sailing Mode 回充死区；老系统专属 SMC 守护，新系统协同原生固件限充。',
            '静默无感控充：重构特权授权通道，支持一次性免密配置，彻底消除后台弹窗打扰。',
            '远程 Web 控制台同步：支持远程查看实时电气指标并在线调节充电上限。'
        ]
    },
    {
        version: '0.1.21',
        date: '2026-09-21',
        title: '外屏断开自动恢复内屏修复',
        bullets: [
            '修复断开外屏后内屏无法自动恢复的问题，系统虚拟屏不再被误判为外接显示器。',
            '恢复可靠性增强：显示器配置事务完成后统一决策、恢复失败自动重试、重复操作幂等跳过。',
            '偏好设置与菜单栏的外接显示器列表口径统一。'
        ]
    },
    {
        version: '0.1.20',
        date: '2026-09-19',
        title: '内网穿透独立分区与遥测开关',
        bullets: [
            '内网穿透独立分区：Dev Tunnels / Cloudflare Tunnel / FRP 三套方案统一管理。',
            'devtunnel 支持应用内一键安装，无需手动下载配置。',
            '新增「匿名使用统计」开关，可一键关闭遥测。',
            '若干稳定性与体验优化。'
        ]
    },
    {
        version: '0.1.19',
        date: '2026-08-09',
        title: '原生集成 FRP 内网穿透与后台线程重载',
        bullets: [
            '原生集成 FRP 内网穿透 (frpc) 客户端，支持多隧道端口与自定义域名映射。',
            '新增快捷图形配置与自定义 TOML/INI 配置文件双模式支持。',
            '全面重构各监控服务重载机制为后台异步线程，消除配置测试时的界面卡顿。',
            '优化配置测试按钮逻辑，支持一键保存、测试与自动使能生效。'
        ]
    },
    {
        version: '0.1.18',
        date: '2026-07-31',
        title: '哪吒 Agent 自更新死锁修复与临时锁清理',
        bullets: [
            '修复哪吒监控 Agent 自动更新锁导致的死锁无法建立连接问题。',
            '增加启动前的临时锁目录自动清理逻辑。'
        ]
    },
    {
        version: '0.1.17',
        date: '2026-07-31',
        title: '全新菜单栏状态面板与自适应动画',
        bullets: [
            '新增全新菜单栏状态控制面板，支持一键无头模式切换与硬件状态实时卡片。',
            '优化非无头 MacBook 用户的初始默认预设，避免首次启动误切。',
            '优化浮窗自适应动画与平滑交互。'
        ]
    },
    {
        version: '0.1.16',
        date: '2026-07-28',
        title: '哪吒监控实时连接指示器与错误诊断',
        bullets: [
            '增加哪吒监控实时连接状态指示器与智能错误诊断。',
            '修复哪吒配置弹窗尺寸偏小被遮挡的问题。',
            '优化配置修改体验，防止编辑输入时频繁断连重启。'
        ]
    },
    {
        version: '0.1.15',
        date: '2026-07-27',
        title: '隐私优先的遥测机制与 Cloudflare D1 分析',
        bullets: [
            '全面上线隐私优先的核心指标遥测与心跳机制。',
            '优化了 Headless 模式与电池保护事件的统计记录。',
            '接入 Cloudflare D1 数据库支撑全栈数据分析。'
        ]
    },
    {
        version: '0.1.14',
        date: '2026-07-13',
        title: '合盖防休眠守护与 Apple Silicon 传感器修复',
        bullets: [
            '实现了全新的“合盖后仍然保持运行”功能（防休眠与合盖守护）。',
            '完美修复 Apple Silicon (M系列) 芯片下温度显示 0.0°C 以及物理风扇状态误报的 Bug。',
            '重构输入设备保护页面为横向多选对齐卡片，移除全局设置冗余副标题描述。'
        ]
    },
    {
        version: '0.1.12',
        date: '2026-07-10',
        title: '局域网 Web 控制面板与物理性能看板',
        bullets: [
            '新增安全的局域网远程管理控制台，全面升级安全 Cookie 会话隔离鉴权与登录页。',
            '物理性能看板升级，引入 CPU 核心物理温度、真实物理内存（RAM）使用量与 GPU 显存负载细节监控。'
        ]
    },
    {
        version: '0.1.0',
        date: '2026-07-01',
        title: 'MacHead 首次发版发布',
        bullets: [
            'MacHead 首次发布！支持一键开启 macOS 无头 (Headless) 模式。',
            '内置防休眠、按键与触控板物理防护。',
            '提供 CLI 命令行工具与局域网 Web 控制台。'
        ]
    }
];

const CHANGELOG_DATA_EN = [
    {
        version: '0.1.27',
        date: '2026-10-25',
        title: 'MacHead Cloud Console, 3-Track E2EE Remote Terminal & Full-Stack Security Hardening',
        bullets: [
            'Launched MacHead Cloud Console (dash.headlessmac.com) with GitHub / Google OAuth PKCE account binding and zero-code one-click terminal access.',
            'Added Happy Eyeballs 3-track adaptive transport engine: zero-latency local Loopback, LAN WebRTC P2P data channels, and cross-network Tailcat WireGuard E2EE tunnels.',
            'Built multi-tab web terminal, remote file manager (drag-and-drop uploads plus online UTF-8/GB18030 code editor), and live hardware telemetry & headless mode controls.',
            'End-to-end security hardening: AES-256-GCM envelope encryption for tunnel coordinates in Cloudflare D1, native Go password gate in tailcat (immune to SIGINT bypass), and hardware-derived AES-GCM encrypted token vault on macOS.'
        ]
    },
    {
        version: '0.1.25',
        date: '2026-10-14',
        title: 'Auto-Restore Headless Mode on Reboot & App Relaunch',
        bullets: [
            'Fixed an issue where Headless Mode did not automatically re-disable the internal display after a macOS reboot or app relaunch.',
            'Improved launch-at-login display takeover sequencing.'
        ]
    },
    {
        version: '0.1.23',
        date: '2026-09-23',
        title: 'Custom Web Console Port & Native macOS Remote Service Detection',
        bullets: [
            'Added custom port configuration for the LAN Web Console with real-time privileged port and range validation.',
            'Synced custom Web Console port automatically with Microsoft Dev Tunnels and FRP (frpc) rules.',
            'Added real-time detection for native macOS SSH (22), Screen Sharing VNC (5900), and File Sharing SMB (445) services with one-click copyable connection URIs.'
        ]
    },
    {
        version: '0.1.22',
        date: '2026-09-23',
        title: 'Panoramic Battery Health, Smart UPS Guard & Charge Limit (50%–90%)',
        bullets: [
            'Added a dedicated Battery tab in Preferences aligned with native macOS system styling.',
            'Real-time electrical telemetry: charge/discharge wattage (W), bus voltage/amperage, adapter rating, and design vs. maximum capacity.',
            'Smart Charge Limit (50%–90%) with Sailing Mode hysteresis to prevent battery swelling on 24/7 AC power, plus passwordless privileged helper setup.',
            'Smart UPS Guard: calculates remaining runtime during AC power outages and dispatches Bark, Telegram, and native macOS notifications.'
        ]
    },
    {
        version: '0.1.21',
        date: '2026-09-21',
        title: 'Reliable Internal Display Recovery on External Monitor Disconnect',
        bullets: [
            'Fixed internal display recovery when external monitors are unplugged by excluding virtual displays from physical external monitor checks.',
            'Enhanced display transaction reliability with automatic retries and idempotent state transitions.'
        ]
    },
    {
        version: '0.1.20',
        date: '2026-09-19',
        title: 'Dedicated Tunneling Hub & Opt-Out Telemetry Switch',
        bullets: [
            'Unified Dev Tunnels, Cloudflare Tunnel, and FRP into a dedicated Tunneling section.',
            'Added one-click in-app installation for Microsoft devtunnel.',
            'Added an explicit opt-out switch for anonymous usage telemetry in Preferences.'
        ]
    },
    {
        version: '0.1.19',
        date: '2026-08-09',
        title: 'Built-In FRP Client & Asynchronous Service Reloading',
        bullets: [
            'Integrated native FRP (frpc) client supporting multi-port tunnels, custom domains, and GUI or custom TOML/INI modes.',
            'Refactored service reloads onto background queues for lag-free configuration testing.'
        ]
    },
    {
        version: '0.1.14',
        date: '2026-07-13',
        title: 'Clamshell Keep-Awake Guard & Apple Silicon Thermal Sensor Fix',
        bullets: [
            'Added continuous clamshell sleep prevention when the MacBook lid is closed.',
            'Fixed Apple Silicon (M-series) CPU temperature sensor readings and fan telemetry.'
        ]
    },
    {
        version: '0.1.0',
        date: '2026-07-01',
        title: 'Initial Public Release of MacHead',
        bullets: [
            'First public release of MacHead with one-click macOS Headless Mode.',
            'Built-in sleep prevention, keyboard/trackpad lockout, CLI tool, and LAN Web Console.'
        ]
    }
];

const feedContainer = document.getElementById('changelog-feed');
if (feedContainer) {
    const activeChangelog = IS_EN ? CHANGELOG_DATA_EN : CHANGELOG_DATA_ZH;
    const isHomepage = !window.location.pathname.includes('changelog');
    const itemsToDisplay = isHomepage ? activeChangelog.slice(0, 2) : activeChangelog;

    const html = itemsToDisplay.map(item => `
        <article class="changelog-entry">
            <div class="changelog-meta">
                <time class="changelog-date">${item.date}</time>
                <span class="changelog-version-tag">v${item.version}</span>
            </div>
            <div class="changelog-body">
                <h3 class="changelog-title">${item.title}</h3>
                <ul class="changelog-bullets">
                    ${item.bullets.map(b => `<li>${b}</li>`).join('')}
                </ul>
            </div>
        </article>
    `).join('');

    feedContainer.innerHTML = html;
}
