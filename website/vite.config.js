import { defineConfig } from 'vite'
import { resolve } from 'path'

// 配置 Vite 相对资源路径与多页面入口 (index.html 与 changelog.html)
export default defineConfig({
  base: './',
  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        changelog: resolve(__dirname, 'changelog.html'),
      },
    },
  },
})
