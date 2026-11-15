#if DEBUG
import AppKit
import SwiftUI

/// Gallery of the Git pieces with made-up data (no repository is read, the engine is not asked), for
/// screenshots in light and dark: BUTAKE_QA_GIT_PIECES = diff | sections | states | tree | editor |
/// graph | icons. The window is the one BUTAKE_QA_SNAPSHOT captures.
@MainActor enum GitPiecesQA {
    static func start() {
        guard StackStore.qaWindow, let scene = ProcessInfo.processInfo.environment["BUTAKE_QA_GIT_PIECES"] else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Git"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GitPiecesGallery(scene: scene).scaledText())
        window.center()
        window.makeKeyAndOrderFront(nil)
        QAHooks.panel = window
    }

    // MARK: Made-up data

    static let patch = """
    diff --git a/src/carrito/total.ts b/src/carrito/total.ts
    index 4f1a2b3..9c8d7e6 100644
    --- a/src/carrito/total.ts
    +++ b/src/carrito/total.ts
    @@ -1,14 +1,18 @@
     import { Producto } from "./producto";
    +import { descuentoPorVolumen } from "./descuentos";

     /** Suma del carrito, en pesos chilenos, con el IVA incluido. */
    -export function total(productos: Producto[]): number {
    -  const neto = productos.reduce((suma, p) => suma + p.precio * p.cantidad, 0);
    +export function total(productos: Producto[], cupon?: string): number {
    +  const neto = productos.reduce((suma, p) => suma + p.precio * p.cantidad, 0);
    +  const descuento = descuentoPorVolumen(productos.length, cupon);
       // El IVA de Chile es 19 %.
    -  return Math.round(neto * 1.19);
    +  return Math.round((neto - descuento) * 1.19);
     }

     export const MONEDA = "CLP";
    @@ -40,7 +44,9 @@ export function resumen(productos: Producto[]): string {
       const lineas = productos.map((p) => `${p.cantidad} × ${p.nombre}`);
    -  return lineas.join("\\n");
    +  /* Una línea por producto,
    +     la última con el total. */
    +  return [...lineas, `Total: ${total(productos)}`].join("\\n");
     }
    \\ No newline at end of file
    """

    static let commit = "\u{1}a1b2c3d feat(carrito): descuento por volumen\nAna Pérez · hace 2 horas\n\nAplica un descuento cuando el carrito supera los diez productos y acepta cupones.\n" + patch + """

    diff --git a/app/Descuentos/Volumen.php b/app/Descuentos/Volumen.php
    new file mode 100644
    --- /dev/null
    +++ b/app/Descuentos/Volumen.php
    @@ -0,0 +1,9 @@
    +<?php
    +
    +namespace App\\Descuentos;
    +
    +final class Volumen
    +{
    +    // Diez productos o más: 5 % de descuento.
    +    public function __invoke(int $cantidad): float { return $cantidad >= 10 ? 0.05 : 0.0; }
    +}
    diff --git a/docs/precios.md b/docs/guia/precios.md
    similarity index 100%
    rename from docs/precios.md
    rename to docs/guia/precios.md
    diff --git a/public/img/banner.png b/public/img/banner.png
    Binary files a/public/img/banner.png and b/public/img/banner.png differ
    """

    static let changes: [GitChange] = {
        func change(_ path: String, _ kind: GitChangeKind = .modified, _ add: Int, _ del: Int, _ inclusion: GitInclusion = .none, from: String? = nil) -> GitChange {
            GitChange(path: path, kind: kind, originalPath: from, stats: GitLineStats(additions: add, deletions: del), inclusion: inclusion)
        }
        return [
            change("src/carrito/total.ts", .modified, 6, 3, .full),
            change("src/carrito/descuentos.ts", .added, 42, 0, .full),
            change("src/carrito/producto.ts", .modified, 2, 1, .partial),
            change("src/pago/webpay.ts", .modified, 12, 8),
            change("src/pago/transferencia.ts", .conflict, 0, 0),
            change("app/Descuentos/Volumen.php", .added, 9, 0, .full),
            change("app/Http/Controllers/CarritoController.php", .modified, 14, 2),
            change("app/Http/Controllers/PagoController.php", .modified, 3, 3),
            change("app/Models/Pedido.php", .modified, 1, 1),
            change("resources/views/carrito/index.blade.php", .modified, 20, 11),
            change("resources/views/emails/pedido.blade.php", .deleted, 0, 37),
            change("docs/guia/precios.md", .moved, 0, 0, from: "docs/precios.md"),
            change("database/migrations/2026_11_14_000000_crear_cupones.php", .added, 28, 0),
            change("public/img/banner.png", .modified, 0, 0),
            change("tests/Feature/CarritoTest.php", .modified, 31, 4, .full),
            change("composer.json", .modified, 1, 1),
            change("package.json", .modified, 2, 1),
            change(".env.example", .modified, 1, 0),
            change("README.md", .modified, 5, 2),
        ].map { var copy = $0; if copy.path.hasSuffix(".png") { copy.stats = GitLineStats() }; return copy }
    }()

    static let editorText = """
    import Foundation

    /// Precio con IVA de un producto, redondeado al peso.
    struct Precio: Hashable, Sendable {
        let neto: Int
        static let iva = 0.19

        /* El total se redondea al final,
           nunca línea por línea. */
        var total: Int { Int((Double(neto) * (1 + Self.iva)).rounded()) }

        func conDescuento(_ porcentaje: Double) -> Precio {
            guard porcentaje > 0 else { return self }
            return Precio(neto: Int(Double(neto) * (1 - porcentaje)))
        }
    }

    let carrito = [Precio(neto: 12_990), Precio(neto: 4_500)]
    print(carrito.map(\\.total).reduce(0, +)) // 20 813
    """

    static let commits: [(GitGraphCommit, String, String)] = [
        (GitGraphCommit(hash: "c10", parents: ["c09", "f03"], refs: "HEAD -> develop, origin/develop"), "Combina la rama del carrito", "Ana Pérez"),
        (GitGraphCommit(hash: "f03", parents: ["f02"], refs: "feature/carrito"), "Descuento por volumen", "Ana Pérez"),
        (GitGraphCommit(hash: "c09", parents: ["c08"]), "Corrige el texto del correo de pedido", "Tomás Fuentes"),
        (GitGraphCommit(hash: "f02", parents: ["f01"]), "Cupones en el resumen", "Ana Pérez"),
        (GitGraphCommit(hash: "c08", parents: ["c07", "h01"]), "Combina el arreglo del pago", "Camila Rojas"),
        (GitGraphCommit(hash: "h01", parents: ["c07"], refs: "hotfix/pago"), "El pago no se duplica al recargar", "Camila Rojas"),
        (GitGraphCommit(hash: "f01", parents: ["c06"]), "Prepara el cálculo del total", "Ana Pérez"),
        (GitGraphCommit(hash: "c07", parents: ["c06"], refs: "tag: v1.4.0"), "Versión 1.4.0", "Tomás Fuentes"),
        (GitGraphCommit(hash: "c06", parents: ["c05"]), "Migra los pedidos a la nueva tabla", "Tomás Fuentes"),
        (GitGraphCommit(hash: "c05", parents: []), "Primer commit", "Tomás Fuentes"),
    ]

    static let iconPaths = ["Package.swift", "main.swift", "index.ts", "App.tsx", "app.js", "styles.scss", "index.html", "Kernel.php",
                            "welcome.blade.php", "main.py", "Cargo.toml", "lib.rs", "main.go", "build.gradle.kts", "Main.kt", "Program.cs",
                            "schema.sql", "config.yaml", "settings.json", ".env", ".gitignore", "README.md", "LICENSE", "Makefile",
                            "logo.svg", "foto.png", "informe.pdf", "datos.csv", "deploy.sh", "archivo.desconocido"]

    /// A made-up picture: a gradient with a few circles, drawn into a bitmap of the given size.
    static func picture(_ width: Int, _ height: Int, hue: CGFloat) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1), ending: NSColor(hue: hue + 0.12, saturation: 0.7, brightness: 0.6, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 35)
        NSColor.white.withAlphaComponent(0.35).setFill()
        for index in 0..<4 { NSBezierPath(ovalIn: NSRect(x: 30 + index * 70, y: 40 + (index % 2) * 50, width: 60, height: 60)).fill() }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}

/// The scenes of the gallery.
private struct GitPiecesGallery: View {
    let scene: String
    @State private var selection: String? = "src/carrito/total.ts"
    @State private var collapsed: Set<Int> = []
    @State private var text = GitPiecesQA.editorText

    var body: some View {
        Group {
            switch scene {
            case "sections":
                GitDiffSectionsView(sections: GitDiffSection.split(GitPiecesQA.commit), collapsed: collapsed, toggle: { id in
                    if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                }, onStageHunk: { _, _ in })
            case "states":
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    GridRow {
                        GitDiffView(content: .binary, path: "public/img/banner.png")
                        GitDiffView(content: .image(before: GitPiecesQA.picture(320, 200, hue: 0.55), after: GitPiecesQA.picture(320, 200, hue: 0.08)), path: "public/img/banner.png")
                    }
                    GridRow {
                        GitDiffView(content: .patch(String(repeating: "+línea\n", count: GitDiffView.largeLineLimit + 1)))
                        GitDiffView(content: .unchanged)
                    }
                }
                .background(Color(nsColor: .separatorColor))
            case "tree":
                HStack(spacing: 0) {
                    GitChangeTreeView(changes: GitPiecesQA.changes, selection: $selection, onInclude: { _, _ in }, onResolve: { _ in }) { change in
                        Button { } label: { Label(L("common.copy"), systemImage: Symbols.copy) }
                            .help(change.path)
                    }
                    .frame(width: 400)
                    Divider()
                    GitDiffView(content: .patch(GitPiecesQA.patch), path: selection, onStageHunk: { _ in })
                }
            case "editor":
                CodeEditor(text: $text, path: "Sources/Precio.swift")
            case "graph":
                graph
            case "icons":
                icons
            default:
                GitDiffView(content: .patch(GitPiecesQA.patch), path: "src/carrito/total.ts", search: "descuento", onStageHunk: { _ in })
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var graph: some View {
        let model = GitCommitGraph(commits: GitPiecesQA.commits.map(\.0), localBranches: ["develop", "feature/carrito", "hotfix/pago"])
        return List(Array(GitPiecesQA.commits.enumerated()), id: \.offset) { index, item in
            HStack(spacing: 10) {
                GitCommitGraphCell(row: model.rows[index], selected: index == 1, lanes: model.width)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.1).font(.uiBody)
                    HStack(spacing: 6) {
                        ForEach(GitCommitReference.parse(item.0.refs, localBranches: ["develop", "feature/carrito", "hotfix/pago"])) { reference in
                            Chip(text: reference.name, symbol: reference.kind == .tag ? Symbols.tags : Symbols.git)
                        }
                        Text(item.2).font(.uiCaption).foregroundStyle(.secondary)
                    }
                }
            }
            // Rows of one height with nothing between them: the cells join into one graph.
            .frame(height: 48)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 48)
    }

    private var icons: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 14) {
                ForEach(GitPiecesQA.iconPaths, id: \.self) { path in
                    HStack(spacing: 10) {
                        FileTypeIcon(path: path, size: 24)
                        Text(path).font(.uiBody.monospaced())
                    }
                }
            }
            .padding(24)
        }
    }
}
#endif
