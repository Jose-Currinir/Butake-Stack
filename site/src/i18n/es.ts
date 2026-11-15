import VERSION from '../../../VERSION?raw'
// Textos de la página. Un solo idioma por ahora; todo texto visible vive aquí.
export const repo = 'https://github.com/Jose-Currinir/Butake-Stack'
export const descarga = `${repo}/releases/latest/download/Butake-Stack.dmg`
// La versión sale de VERSION, en la raíz del repositorio: la misma que lee scripts/build-native.sh.
export const version = VERSION.trim()

export const t = {
  titulo: 'Stack, de Butake · Desarrollo local nativo para Mac',
  descripcion: 'Sitios .test con HTTPS y HTTP/3; PHP, Node, Python, Java, Rust y Swift con varias versiones a la vez; MySQL, PostgreSQL y Redis corriendo directo en tu Mac, desde la barra de menús. Sin gestores de paquetes ni contenedores, en español.',
  nav: { capas: 'Capas', app: 'La app', funciones: 'Funciones', nunca: 'Seguridad', instalar: 'Instalar', github: 'GitHub', descargar: 'Descargar' },
  menu: { abrir: 'Abrir menú', cerrar: 'Cerrar menú' },
  tema: { titulo: 'Tema', sistema: 'Sistema', claro: 'Claro', oscuro: 'Oscuro' },

  hero: {
    etiqueta: `v${version}`,
    etiquetaTexto: 'Gratis · Código abierto · Apache 2.0',
    titulo: ['Tu Mac,', 'listo para', 'servir.'],
    texto: 'Stack es el entorno de desarrollo local que vive en tu barra de menús. Sitios .test con HTTPS y HTTP/3, cada lenguaje en la versión que pide cada proyecto y los motores corriendo directo en el Mac. Sin contenedores. Sin contraseña. Sin tocar el sistema.',
    descargar: 'Descargar para Mac',
    github: 'Ver el código',
    requisitos: 'macOS 15+ · Apple Silicon',
    imagen: 'Inicio de Stack: cinco proyectos en línea, agrupados por carpeta',
    direcciones: ['tienda.test', 'blog.test', 'api.test', 'feature-reportes.panel.test'],
    fichas: [
      { titulo: 'tienda.test', detalle: 'Laravel · PHP 8.4', estado: 'HTTP/3' },
      { titulo: 'MySQL 8.4', detalle: 'puerto 3306', estado: 'activo' },
      { titulo: 'Node 22', detalle: 'por .nvmrc', estado: 'LTS' },
    ],
  },

  tecnologias: ['PHP', 'Node.js', 'Python', 'Java', 'Rust', 'Swift', 'Caddy', 'MySQL', 'PostgreSQL', 'MongoDB', 'Redis', 'Valkey', 'Meilisearch', 'Typesense', 'RustFS'],

  capas: {
    rotulo: 'Cómo funciona',
    titulo: 'Tres capas. Una sola app.',
    texto: 'Cada petición a tu sitio baja por la misma pila. Stack arma cada capa, la mantiene viva y te muestra qué pasa en ella.',
    lista: [
      { id: 'sitios', numero: '01', nombre: 'Sitios', detalle: 'Caddy · HTTPS · HTTP/3', titulo: 'Cada proyecto, en su propio .test', texto: 'Los sitios parten apagados y se encienden con un interruptor. Caddy los sirve con TLS 1.3, HTTP/2 y HTTP/3 en los puertos que entrega macOS, y sus procesos —colas, Reverb, Vite— arrancan solos.', puntos: ['Dominios .test con certificado local', 'Worktrees como <rama>.<sitio>.test', 'Registros en vivo por sitio'] },
      { id: 'lenguajes', numero: '02', nombre: 'Lenguajes', detalle: 'PHP · Node · Python · Java', titulo: 'La versión que pide cada proyecto', texto: 'Instala varias versiones a la vez, elige una global y deja que cada proyecto guarde la suya en el archivo estándar de su ecosistema. Rust y Swift, con rustup y swiftly.', puntos: ['.nvmrc, .java-version, .python-version', 'Python con .venv por proyecto', 'Ciclo de soporte de cada versión'] },
      { id: 'motores', numero: '03', nombre: 'Motores', detalle: 'MySQL · PostgreSQL · Redis', titulo: 'Bases de datos y caché, nativas', texto: 'MySQL, PostgreSQL, MongoDB, Redis, Valkey, Meilisearch, Typesense y RustFS, descargados de su fuente oficial a la carpeta de Stack. Cada uno con su puerto, sus datos y los sitios que lo usan.', puntos: ['Varias versiones lado a lado', 'Encender y apagar con un clic', 'Datos importados por clon APFS'] },
    ],
  },

  recorrido: {
    rotulo: 'La app',
    titulo: 'Nativa de verdad.',
    tituloAcento: 'Sin WebView.',
    texto: 'SwiftUI y AppKit, vidrio de macOS, modo claro y oscuro, todo en español. Recórrela.',
    pausar: 'Pausar recorrido',
    reanudar: 'Reanudar recorrido',
    pestanas: [
      { id: 'inicio', icono: 'home-5-line', titulo: 'Inicio', texto: 'Tus proyectos por carpeta, con su tecnología, su rama y su estado.', imagen: 'inicio.png' },
      { id: 'sitio', icono: 'global-line', titulo: 'Proyecto', texto: 'Dirección, carpeta, versiones, servicios que usa y Git, en una sola página.', imagen: 'sitio.png' },
      { id: 'bases', icono: 'database-2-line', titulo: 'Bases de datos', texto: 'Cada motor con su versión, su puerto y los proyectos que lo usan.', imagen: 'bases-de-datos.png' },
      { id: 'cache', icono: 'flashlight-line', titulo: 'Caché y colas', texto: 'Redis y Valkey lado a lado, encendidos o detenidos con un clic.', imagen: 'cache.png' },
      { id: 'php', icono: 'code-s-slash-line', titulo: 'PHP', texto: 'Varias líneas a la vez, una global, Xdebug por versión y su ciclo de soporte.', imagen: 'lenguajes.png' },
      { id: 'node', icono: 'javascript-line', titulo: 'Node.js', texto: 'Cada proyecto fija la suya en .nvmrc; la global puede quedar en la terminal.', imagen: 'node.png' },
    ],
  },

  funciones: {
    rotulo: 'Funciones',
    titulo: 'Todo tu entorno,',
    tituloAcento: 'a un clic.',
    celdas: [
      { id: 'proyectos', tam: 'grande', icono: 'add-box-line', titulo: 'Proyectos nuevos con la versión que corresponde', texto: 'Laravel, Astro, Next.js, Vite, EmDash, Django, FastAPI, Rust, Swift y React Native con sus generadores oficiales. Sólo puedes elegir versiones del framework que corren con tu PHP o tu Python.', imagen: 'nuevo-proyecto.png' },
      { id: 'git', tam: 'alta', icono: 'git-branch-line', titulo: 'Tu rama, junto al sitio', texto: 'Rama y cambios pendientes en cada sitio. Al cambiar de rama, Stack avisa si hay dependencias o migraciones nuevas.', codigo: ['develop', 'feature/reportes', 'fix/checkout'] },
      { id: 'preparar', tam: 'ancha', icono: 'checkbox-multiple-line', titulo: 'Un Mac nuevo, listo en minutos', texto: 'Marcas con qué trabajas —web, nativo, multiplataforma— y «Preparar Stack» te muestra sólo lo que falta. «Mi entorno» restaura tu configuración de otro Mac, sin secretos.', imagen: 'preparar.png' },
      { id: 'barra', tam: 'panel', icono: 'menu-line', titulo: 'Siempre en la barra de menús', texto: 'Enciende un proyecto, abre su sitio o detén un motor sin abrir la ventana.', imagen: 'panel.png' },
      { id: 'teclado', tam: 'chica', icono: 'command-line', titulo: '⌘K', texto: 'Paleta para ir, encender y abrir.' },
      { id: 'temas', tam: 'chica', icono: 'palette-line', titulo: 'Temas', texto: 'Butake, Drácula o el tuyo.' },
      { id: 'agentes', tam: 'chica', icono: 'accessibility-line', titulo: 'Accesible', texto: 'Operable por VoiceOver y agentes de IA.' },
    ],
  },

  nunca: {
    rotulo: 'Seguridad',
    titulo: 'Lo que Stack',
    tituloAcento: 'nunca hace.',
    texto: 'Stack asume que en tu Mac hay proyectos y datos reales. Por eso hay cosas que, sencillamente, no hace.',
    lista: [
      { no: 'Pedir tu contraseña', si: 'macOS entrega los puertos 53, 80 y 443 al agente de sesión. Sin root.' },
      { no: 'Tocar /etc', si: 'El DNS de .test es interno. Todo vive en la carpeta de Stack.' },
      { no: 'Leer tus secretos', si: 'Los valores del .env de tus proyectos no se leen; las claves propias van al Llavero.' },
      { no: 'Pasar por un shell', si: 'Cada programa recibe argumentos separados; rutas, dominios y puertos validados.' },
      { no: 'Descargar a ciegas', si: 'Sólo HTTPS, verificado con SHA-256, firma del fabricante o compilado desde el código.' },
      { no: 'Actualizarse sin pruebas', si: 'Cada versión trae SHA-256, Developer ID de Butake SpA y notarización de Apple.' },
    ],
  },

  cifras: [
    { valor: '0', texto: 'contraseñas para servir .test' },
    { valor: '3', texto: 'protocolos: HTTP/1.1, 2 y 3' },
    { valor: '10', texto: 'motores y servidores listos' },
    { valor: '1', texto: 'clic para encender un sitio' },
  ],

  instalar: {
    rotulo: 'Empezar',
    titulo: 'Tres pasos.',
    tituloAcento: 'Ningún sudo.',
    pasos: [
      { titulo: 'Descarga', texto: 'Baja Butake-Stack.dmg desde la última versión.' },
      { titulo: 'Arrastra', texto: 'Abre el .dmg y lleva Stack a Aplicaciones.' },
      { titulo: 'Prepara', texto: '«Preparar Stack» te guía con lo que falta en tu Mac.' },
    ],
    aviso: 'Firmada con Developer ID de Butake SpA y notarizada por Apple.',
    codigoTitulo: 'O compílala desde el código',
    codigo: ['git clone https://github.com/Jose-Currinir/Butake-Stack.git', 'cd Butake-Stack', './scripts/install-native.sh'],
    copiar: 'Copiar',
    copiado: 'Copiado',
  },

  faq: {
    rotulo: 'Preguntas',
    titulo: 'Lo que suelen preguntar.',
    items: [
      { p: '¿Es gratis?', r: 'Sí. Stack es de código abierto bajo licencia Apache 2.0. Puedes usarlo, estudiarlo y proponer mejoras.' },
      { p: '¿En qué Mac funciona?', r: 'En Mac con Apple Silicon y macOS 15 o superior.' },
      { p: '¿Es segura de instalar?', r: 'Sí. Está firmada con el certificado Developer ID de Butake SpA y notarizada por Apple, así que macOS la abre sin advertencias. La suma SHA-256 se publica junto a cada versión.' },
      { p: '¿Necesito un gestor de paquetes o contenedores?', r: 'No. PHP, Node, Python, Java, Caddy y los motores se descargan de su fuente oficial a la carpeta de Stack y corren directo en el Mac. Rust, swiftly, gh y Wrangler se instalan en tu carpeta personal con sus instaladores oficiales, verificados. Nada en /usr/local y sin sudo.' },
      { p: '¿Puedo tener varias versiones de un lenguaje?', r: 'Sí. Instalas las que quieras de PHP, Node, Java y Python, eliges una global y cada proyecto guarda la suya en su archivo estándar: .nvmrc, .java-version, .python-version o rust-toolchain.toml. Si quieres, la versión global queda en la terminal como enlace al binario real.' },
      { p: '¿Pide mi contraseña o cambia /etc?', r: 'No. macOS entrega los puertos 53, 80 y 443 al agente de sesión de Stack; el DNS de .test es interno. Activarlo pide tu confirmación, no tu contraseña.' },
      { p: '¿Cómo se actualiza?', r: 'La app busca versiones nuevas en GitHub y se actualiza sola tras verificar la suma SHA-256, la firma de Butake SpA y la notarización de Apple.' },
      { p: '¿Puedo contribuir?', r: 'Sí: haz un fork y abre un pull request hacia develop. El equipo lo revisa antes de integrarlo. Para cambios grandes, abre antes un issue.' },
    ],
  },

  cierre: {
    titulo: ['Tu próximo sitio', 'está a un clic.'],
    texto: 'Descarga Stack y deja tu entorno local listo en minutos.',
  },

  pieColumnas: [
    { titulo: 'Producto', enlaces: [['Capas', '#capas'], ['La app', '#app'], ['Seguridad', '#nunca'], ['Instalar', '#instalar']] },
    { titulo: 'Recursos', enlaces: [['Versiones', '/releases'], ['Arquitectura', '/blob/develop/docs/architecture.md'], ['Documentación', '/tree/develop/docs'], ['Butake Git', 'https://jose-currinir.github.io/Butake-Git/']] },
    { titulo: 'Proyecto', enlaces: [['Código', ''], ['Licencia', '/blob/develop/LICENSE'], ['Reportar un problema', '/issues/new'], ['Butake Design', 'https://github.com/Jose-Currinir/Butake-Design']] },
  ],
  pie: {
    licencia: 'Código bajo licencia Apache 2.0.',
    marca: 'Butake y su logo son marcas de Butake SpA y no se incluyen en la licencia.',
    copyright: '© 2026 Butake SpA',
    arriba: 'Volver arriba',
  },
}
