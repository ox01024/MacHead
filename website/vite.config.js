import { defineConfig } from 'vite'

// 配置 Vite 相对资源路径，以完美兼容 GitHub Pages 子目录部署
export default defineConfig({
  base: './',
})
