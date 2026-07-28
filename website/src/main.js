/* -------------------------------------------------------------
 * MacHead Landing Page Interactivity Script
 * CLI Terminal typing simulation, Live Web Stats, Copy to Clipboard,
 * and IntersectionObserver Fallback for Scroll-driven animations
 * ------------------------------------------------------------- */

import './style.css';

document.addEventListener('DOMContentLoaded', () => {
    // 0. Mobile hamburger navigation
    const menuToggle = document.getElementById('nav-menu-toggle');
    const navLinks = document.getElementById('nav-links');
    if (menuToggle && navLinks) {
        const closeMenu = () => {
            navLinks.classList.remove('open');
            menuToggle.classList.remove('open');
            menuToggle.setAttribute('aria-expanded', 'false');
            menuToggle.setAttribute('aria-label', '打开导航菜单');
        };

        menuToggle.addEventListener('click', () => {
            const isOpen = navLinks.classList.toggle('open');
            menuToggle.classList.toggle('open', isOpen);
            menuToggle.setAttribute('aria-expanded', String(isOpen));
            menuToggle.setAttribute('aria-label', isOpen ? '关闭导航菜单' : '打开导航菜单');
        });

        // Close the dropdown after choosing a destination
        navLinks.querySelectorAll('a').forEach(link => {
            link.addEventListener('click', closeMenu);
        });

        // Reset state when resizing back to the desktop layout
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
                // Success feedback
                const originalSvg = copyBtn.innerHTML;
                copyBtn.innerHTML = `
                    <svg class="copy-icon text-emerald" viewBox="0 0 24 24" width="16" height="16" stroke="#10b981" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round">
                        <polyline points="20 6 9 17 4 12"></polyline>
                    </svg>
                `;
                copyBtn.title = "已复制";
                setTimeout(() => {
                    copyBtn.innerHTML = originalSvg;
                    copyBtn.title = "复制安装命令";
                }, 1500);
            }).catch(err => {
                console.error('Failed to copy text: ', err);
            });
        });
    }

    // 2. PlayGround Tabs Switching
    const tabBtns = document.querySelectorAll('.tab-btn');
    const tabPanels = document.querySelectorAll('.tab-panel');

    tabBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            const targetTab = btn.getAttribute('data-tab');
            
            // Toggle active buttons
            tabBtns.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');

            // Toggle active panels
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
    const cmdButtons = document.querySelectorAll('.cli-cmd-btn');
    let isTyping = false;

    const cmdOutputs = {
        status: `Mode: NORMAL (Active Screen)\nWebServer: RUNNING (http://192.168.100.131:8080)\nSleep Prevention: DISABLED\nPower Source: AC Power (Battery 100%)\nKeyboard/Trackpad auto-disable in Headless: OFF`,
        enable: `MacHead: 正在启用无头模式...\nMacHead: 已逻辑切断内置屏幕\nMacHead: 内置麦克风已自动静音\nMacHead: 已防睡眠断言锁定\nWebServer: http://192.168.100.131:8080\nMode: HEADLESS (Internal Display cut off)`,
        disable: `MacHead: 正在关闭无头模式...\nMacHead: 内置屏幕已恢复通电连接\nMacHead: 麦克风音频取消静音\nMacHead: 睡眠限制已释放\nMode: NORMAL (Active Screen)`,
        'sleep-prevent': `MacHead: 正在开启防睡眠断言...\nMacHead: 电源断言锁定成功 (ID: 3274)\nSleep Prevention: ENABLED\nSystem will stay awake under clamshell mode.`
    };

    function simulateTyping(cmdText, callback) {
        if (isTyping) return;
        isTyping = true;

        // Remove old cursor line
        const lastLine = cliConsole.lastElementChild;
        if (lastLine && lastLine.classList.contains('terminal-line') && lastLine.querySelector('.cursor-blink')) {
            lastLine.remove();
        }

        // Add input prompt line
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
                setTimeout(typeChar, 40); // Type speed
            } else {
                // Done typing
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
        const fullCmd = `machead ${cmdKey}`;
        simulateTyping(fullCmd, () => {
            // Append output
            const outputDiv = document.createElement('div');
            outputDiv.className = 'terminal-output';
            // Replace newlines with <br/>
            outputDiv.innerHTML = cmdOutputs[cmdKey].replace(/\n/g, '<br/>');
            cliConsole.appendChild(outputDiv);

            // Append a new input prompt with blinking cursor
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

    // Theme toggler for mockup
    if (themeToggle && mockupWrapper) {
        themeToggle.addEventListener('click', () => {
            const currentTheme = mockupWrapper.getAttribute('data-mock-theme');
            const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
            mockupWrapper.setAttribute('data-mock-theme', newTheme);
            themeToggle.textContent = newTheme === 'dark' ? '浅色模式' : '深色模式';
        });
    }

    // Logout action
    if (logoutBtn && loginScreen && dashboardScreen && loginPass && loginError) {
        logoutBtn.addEventListener('click', () => {
            dashboardScreen.style.display = 'none';
            loginScreen.style.display = 'flex';
            loginPass.value = '';
            loginError.style.display = 'none';
        });
    }

    // Toggle interactive mode details
    function updateHeadlessUI() {
        if (!headlessToggle) return;
        const isHeadless = headlessToggle.checked;
        if (isHeadless) {
            if (mockModeDot) {
                mockModeDot.className = 'status-dot active';
                mockModeDot.style.backgroundColor = '#42b883';
            }
            if (mockModeText) mockModeText.textContent = 'Headless 激活';
            if (mockLidVal) mockLidVal.textContent = '💻 合盖 (Clamshell)';
            if (mockAlertBox) mockAlertBox.style.display = 'block';
        } else {
            if (mockModeDot) {
                mockModeDot.className = 'status-dot';
                mockModeDot.style.backgroundColor = '#007aff';
            }
            if (mockModeText) mockModeText.textContent = 'Normal 模式';
            if (mockLidVal) mockLidVal.textContent = '💻 内屏亮起';
            if (mockAlertBox) mockAlertBox.style.display = 'none';
        }
    }

    if (headlessToggle) {
        headlessToggle.addEventListener('change', updateHeadlessUI);
    }

    // Login Form logic
    let attempts = 0;
    if (loginForm && loginPass && loginError && loginScreen && dashboardScreen) {
        loginForm.addEventListener('submit', (e) => {
            e.preventDefault();
            const pass = loginPass.value.trim().toLowerCase();
            // Accept admin, machead, or any MH- password, or if they tried once let them in anyway on 2nd attempt to be user friendly
            if (pass === 'admin' || pass === 'machead' || pass.startsWith('mh-') || attempts >= 1) {
                loginError.style.display = 'none';
                loginScreen.style.display = 'none';
                dashboardScreen.style.display = 'block';
                // Trigger drawing initial sparklines immediately
                drawAllSparklines();
            } else {
                attempts++;
                loginError.style.display = 'block';
                loginPass.value = '';
                loginPass.focus();
            }
        });
    }

    // Live web mockup stats ticking simulation with Sparklines
    const webCpuVal = document.getElementById('web-cpu-val');
    const webRamVal = document.getElementById('web-ram-val');
    const webGpuVal = document.getElementById('web-gpu-val');
    
    const historyLimit = 30;
    const mockCpuHistory = Array.from({length: historyLimit}, () => Math.floor(Math.random() * 10) + 15);
    const mockRamHistory = Array.from({length: historyLimit}, () => 16);
    const mockGpuHistory = Array.from({length: historyLimit}, () => Math.floor(Math.random() * 5) + 5);
    const mockRxHistory = Array.from({length: historyLimit}, () => Math.floor(Math.random() * 20480) + 40960); // ~40-60 KB/s
    const mockTxHistory = Array.from({length: historyLimit}, () => Math.floor(Math.random() * 4096) + 2048); // ~2-6 KB/s

    let cpuPeak = 28;
    let ramPeak = 16;
    let rxPeak = 124 * 1024;
    let txPeak = 12 * 1024;

    function formatSpeed(bytesPerSec) {
        if (bytesPerSec < 1024) return Math.round(bytesPerSec) + " B/s";
        const kb = bytesPerSec / 1024;
        if (kb < 1024) return kb.toFixed(1) + " KB/s";
        const mb = kb / 1024;
        return mb.toFixed(1) + " MB/s";
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

    // Setup Ticker Interval (Ticking every 3 seconds)
    setInterval(() => {
        // Only run ticker if dashboard mockup is visible to save CPU
        if (dashboardScreen && dashboardScreen.style.display === 'none') return;

        // CPU ticks
        const currentCpu = Math.floor(Math.random() * 15) + 15; // 15% to 30%
        if (webCpuVal) webCpuVal.textContent = `${currentCpu}%`;
        mockCpuHistory.push(currentCpu);
        if (mockCpuHistory.length > historyLimit) mockCpuHistory.shift();
        drawMockSparkline('web-cpu-spark-line', 'web-cpu-spark-fill', mockCpuHistory, 100);
        
        if (currentCpu > cpuPeak) {
            cpuPeak = currentCpu;
        }
        const peaksLabel = document.getElementById('web-hardware-peaks');
        if (peaksLabel) {
            peaksLabel.textContent = `峰值 - CPU: ${cpuPeak}% | RAM: ${ramPeak}%`;
        }

        const cpuCircle = document.getElementById('mock-cpu-circle');
        if (cpuCircle) {
            cpuCircle.style.strokeDashoffset = 175.9 - (currentCpu / 100) * 175.9;
        }
        const mockCpuTemp = (48.0 + (Math.random() * 2.0 - 1.0)).toFixed(1);
        const cpuTempEl = document.getElementById('web-cpu-temp');
        if (cpuTempEl) cpuTempEl.textContent = `温度: ${mockCpuTemp} °C`;

        // RAM ticks
        const currentRam = (Math.random() > 0.8) ? (Math.random() > 0.5 ? 17 : 15) : 16;
        if (webRamVal) webRamVal.textContent = `${currentRam}%`;
        mockRamHistory.push(currentRam);
        if (mockRamHistory.length > historyLimit) mockRamHistory.shift();
        drawMockSparkline('web-ram-spark-line', 'web-ram-spark-fill', mockRamHistory, 100);
        if (currentRam > ramPeak) {
            ramPeak = currentRam;
        }
        const ramCircle = document.getElementById('mock-ram-circle');
        if (ramCircle) {
            ramCircle.style.strokeDashoffset = 175.9 - (currentRam / 100) * 175.9;
        }
        const mockRamUsed = (8.1 + (Math.random() * 0.4 - 0.2)).toFixed(2);
        const ramDetailsEl = document.getElementById('web-ram-details');
        if (ramDetailsEl) ramDetailsEl.textContent = `已用: ${mockRamUsed} GB / 32.0 GB`;

        // GPU ticks
        const currentGpu = Math.floor(Math.random() * 8) + 4; // 4% to 12%
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
        if (gpuVramEl) gpuVramEl.textContent = `显存: ${mockVramUsed} GB / 16.0 GB`;

        // Network ticks
        const rxSpeed = Math.floor(Math.random() * 50 * 1024) + 50 * 1024; // 50-100 KB/s
        const txSpeed = Math.floor(Math.random() * 10 * 1024) + 2 * 1024;  // 2-12 KB/s
        
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
            if (rxPeakEl) rxPeakEl.textContent = `↓ 峰值: ${formatSpeed(rxPeak)}`;
        }
        if (txSpeed > txPeak) {
            txPeak = txSpeed;
            const txPeakEl = document.getElementById('web-tx-peak');
            if (txPeakEl) txPeakEl.textContent = `↑ 峰值: ${formatSpeed(txPeak)}`;
        }

        // Battery temp ticks
        const baseTemp = 36.5;
        const drift = (Math.random() * 0.4) - 0.2; // -0.2 to +0.2
        const currentTemp = (baseTemp + drift).toFixed(1);
        const tempEl = document.getElementById('web-battery-temp');
        if (tempEl) tempEl.textContent = `${currentTemp} °C`;
        
        // Randomly drift battery capacity slightly (e.g. 87-89% to show it's alive)
        const capEl = document.getElementById('web-battery-cap');
        if (capEl) {
            const currentCap = (Math.random() > 0.95) ? (Math.random() > 0.5 ? 89 : 87) : 88;
            capEl.textContent = `${currentCap}%`;
        }
    }, 3000);

    // 5. Scroll driven animations fallback using IntersectionObserver
    // Checks if the browser natively supports View Timeline
    if (!CSS.supports('(animation-timeline: view()) and (animation-range: entry)')) {
        console.log("MacHead Web: Native View Timeline unsupported, falling back to IntersectionObserver");
        
        // Add fallback CSS style to all scroll-effect items
        const scrollEffects = document.querySelectorAll('.scroll-effect');
        scrollEffects.forEach(el => {
            el.classList.add('no-supports-scroll-reveal');
        });

        const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('reveal-active');
                    // Once animated, we can unobserve if we only want entry effect
                    observer.unobserve(entry.target);
                }
            });
        }, {
            threshold: 0.15 // Trigger when 15% of element is in view
        });

        scrollEffects.forEach(el => {
            observer.observe(el);
        });
    } else {
        console.log("MacHead Web: Native CSS View Timeline supported.");
    }

    // 6. Centralized Dynamic Version & Download Link Synchronizer
    function syncReleaseMetadata(version, downloadUrl) {
        // Update all download buttons (by class .js-download-link or known IDs)
        const downloadElements = document.querySelectorAll('.js-download-link, #download-header-link, #download-hero-link, #download-cta-link');
        downloadElements.forEach(el => {
            el.setAttribute('href', downloadUrl);
        });

        // Update all version badge text elements
        const badgeElements = document.querySelectorAll('.js-version-badge, .hero-badge .badge-text');
        badgeElements.forEach(el => {
            el.textContent = `v${version} Universal 支持 Apple Silicon / Intel`;
        });

        // Update CTA download button text
        const ctaBtn = document.getElementById('download-cta-link');
        if (ctaBtn) {
            ctaBtn.textContent = `下载 macOS Universal DMG v${version}`;
        }

        // Update JSON-LD Structured Data for SEO
        const ldScript = document.getElementById('schema-json-ld');
        if (ldScript) {
            try {
                const schema = JSON.parse(ldScript.textContent);
                schema.softwareVersion = version;
                schema.downloadUrl = downloadUrl;
                ldScript.textContent = JSON.stringify(schema, null, 2);
            } catch (e) {
                console.warn('MacHead Web: Could not update JSON-LD schema', e);
            }
        }
    }

    fetch('/appcast.json')
        .then(res => res.ok ? res.json() : Promise.reject(res.status))
        .then(data => {
            if (data && data.url && data.version) {
                syncReleaseMetadata(data.version, data.url);
                console.log(`MacHead Web: Centralized release metadata synced (v${data.version})`);
            }
        })
        .catch(err => {
            console.warn('MacHead Web: Using fallback release metadata due to appcast fetch status:', err);
        });
});
