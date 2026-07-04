/* -------------------------------------------------------------
 * MacHead Landing Page Interactivity Script
 * CLI Terminal typing simulation, Live Web Stats, Copy to Clipboard,
 * and IntersectionObserver Fallback for Scroll-driven animations
 * ------------------------------------------------------------- */

import './style.css';

document.addEventListener('DOMContentLoaded', () => {
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

    // 4. Live web mockup stats gauges ticking simulation
    const webCpuVal = document.getElementById('web-cpu-val');
    const webRamVal = document.getElementById('web-ram-val');

    if (webCpuVal && webRamVal) {
        setInterval(() => {
            // CPU ticks dynamically
            const targetCpu = Math.floor(Math.random() * 15) + 15; // 15% to 30%
            webCpuVal.textContent = `${targetCpu}%`;
            
            const mockCpuCircle = document.getElementById('mock-cpu-circle');
            if (mockCpuCircle) {
                const radius = 28;
                const circumference = radius * 2 * Math.PI;
                const offset = circumference - (targetCpu / 100 * circumference);
                mockCpuCircle.style.strokeDashoffset = offset;
            }

            // RAM stays relatively static
            const targetRam = (Math.random() > 0.8) ? (Math.random() > 0.5 ? 17 : 15) : 16;
            webRamVal.textContent = `${targetRam}%`;
            
            const mockRamCircle = document.getElementById('mock-ram-circle');
            if (mockRamCircle) {
                const radius = 28;
                const circumference = radius * 2 * Math.PI;
                const offset = circumference - (targetRam / 100 * circumference);
                mockRamCircle.style.strokeDashoffset = offset;
            }
        }, 3000);
    }

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
});
