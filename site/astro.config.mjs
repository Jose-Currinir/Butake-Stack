import { defineConfig } from 'astro/config'

// GitHub Pages sirve el sitio del proyecto en /Butake-Stack/.
export default defineConfig({
  site: 'https://jose-currinir.github.io',
  base: '/Butake-Stack',
  trailingSlash: 'ignore',
  build: { assets: 'assets' },
})
