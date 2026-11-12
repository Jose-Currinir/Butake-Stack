// Copia las capturas de docs/presentacion y la marca al sitio, sin duplicarlas en el repo.
import { cpSync, mkdirSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
const raiz = new URL('../..', import.meta.url).pathname
const destino = new URL('../public/img', import.meta.url).pathname
mkdirSync(destino, { recursive: true })
for (const archivo of readdirSync(join(raiz, 'docs/presentacion'))) {
  if (archivo.endsWith('.png')) cpSync(join(raiz, 'docs/presentacion', archivo), join(destino, archivo))
}
cpSync(join(raiz, 'native/Sources/ButakeStack/Resources/ButakeLogo.png'), join(destino, 'logo.png'))
console.log('imágenes listas')
