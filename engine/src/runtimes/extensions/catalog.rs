//! The catalog of extensions Stack can install on demand, per component. Every entry names its
//! version, its official origin, the SHA-256 the download must match and what it needs. A sum is
//! the one the project publishes next to its release (GitHub's `digest` of the release asset) or,
//! where the project only publishes an MD5 or nothing (PostGIS, pgvector), the SHA-256 of the
//! official file, pinned here after checking it against what the project does publish.
//!
//! Components today: PostgreSQL. The model (`super::Extension`) is the same for any component
//! that admits extensions (Redis and Valkey modules, MySQL plugins, PHP; see `docs/extensiones.md`).

/// A file Stack downloads: where from, what it must hash to and about how big it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Archive {
    /// Name it is saved under in the cache (also how the tests' local origin finds it).
    pub file: &'static str,
    pub url: &'static str,
    pub sha256: &'static str,
    /// Bytes, as the origin announces them (shown before installing).
    pub size: u64,
    /// The archive's single top folder is dropped when it is extracted.
    pub strip: bool,
}

/// Something an extension needs to be built: a library it links (placed with the engine) or a
/// build tool (kept in Stack's data for the next build, never in the system).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Dependency {
    pub id: &'static str,
    pub name: &'static str,
    pub version: &'static str,
    pub license: &'static str,
    pub role: Role,
    /// How a library is built (a build tool is not built).
    pub builder: Builder,
    pub archive: Archive,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Builder {
    Cmake,
    /// `configure`, `make`, `make install` in its source tree.
    Configure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// Built into the work folder; its shared libraries go with the engine.
    Library,
    /// CMake itself: Kitware's official macOS binary, kept in `build-tools/` for the next build.
    BuildTool,
}

/// How an extension is built against the engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Build {
    /// PostgreSQL's extension makefiles (`PG_CONFIG=…`): `make`, then `make install`.
    Pgxs,
    /// GMP, GEOS, PROJ and JSON-C, then PostGIS's `configure`, `make`, `make install`.
    Postgis,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Recipe {
    pub component: &'static str,
    pub id: &'static str,
    pub name: &'static str,
    pub version: &'static str,
    pub license: &'static str,
    /// Its project's page, shown as its origin.
    pub homepage: &'static str,
    pub archive: Archive,
    pub dependencies: &'static [Dependency],
    pub build: Build,
    /// What `CREATE EXTENSION` accepts once it is installed.
    pub sql_names: &'static [&'static str],
    /// Engine majors it builds for (both included).
    pub engines: (u32, u32),
    /// What the build leaves out on purpose (a translation key of the app: `ext.note.<key>`).
    pub note: Option<&'static str>,
}

impl Recipe {
    /// The steps its install reports (`core/progress`), as the app shows them.
    pub fn plan(&self) -> Vec<&'static str> {
        match self.build {
            Build::Pgxs => vec!["downloadSource", "verifySum", "build", "install"],
            Build::Postgis => vec![
                "downloadSource",
                "verifySum",
                "buildDependencies",
                "build",
                "install",
            ],
        }
    }

    /// Every file it downloads, its own first.
    pub fn archives(&self) -> Vec<Archive> {
        std::iter::once(self.archive)
            .chain(self.dependencies.iter().map(|d| d.archive))
            .collect()
    }

    pub fn download_size(&self) -> u64 {
        self.archives().iter().map(|a| a.size).sum()
    }

    pub fn supports(&self, engine_version: &str) -> bool {
        let major = engine_version
            .split('.')
            .next()
            .and_then(|m| m.parse::<u32>().ok())
            .unwrap_or(0);
        (self.engines.0..=self.engines.1).contains(&major)
    }
}

pub const CMAKE: Dependency = Dependency {
    id: "cmake",
    name: "CMake",
    version: "4.5.0",
    license: "BSD-3-Clause",
    role: Role::BuildTool,
    builder: Builder::Cmake,
    archive: Archive {
        file: "cmake-4.5.0-macos-universal.tar.gz",
        url: "https://github.com/Kitware/CMake/releases/download/v4.5.0/cmake-4.5.0-macos-universal.tar.gz",
        sha256: "a645d69fd21e521759cc0c64e7c60462d43faf0c7214ac05f75c80f7c5037dde",
        size: 92_795_915,
        strip: true,
    },
};

/// PostGIS 3.7 requires GMP (exact arithmetic). GMP publishes GPG signatures only: this SHA-256 is
/// the one both official origins (gmplib.org and the GNU project's ftp.gnu.org) served, identical.
/// The download uses the GNU origin, which keeps up with large files.
pub const GMP: Dependency = Dependency {
    id: "gmp",
    name: "GMP",
    version: "6.3.0",
    license: "LGPL-3.0",
    role: Role::Library,
    builder: Builder::Configure,
    archive: Archive {
        file: "gmp-6.3.0.tar.xz",
        url: "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz",
        sha256: "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898",
        size: 2_094_196,
        strip: true,
    },
};

pub const GEOS: Dependency = Dependency {
    id: "geos",
    name: "GEOS",
    version: "3.15.0",
    license: "LGPL-2.1",
    role: Role::Library,
    builder: Builder::Cmake,
    archive: Archive {
        file: "geos-3.15.0.tar.bz2",
        url: "https://github.com/libgeos/geos/releases/download/3.15.0/geos-3.15.0.tar.bz2",
        sha256: "d5e5192a686d065eaed082de14dd26244c5c8e02bff16b2c6cce3265f648e00e",
        size: 7_120_409,
        strip: true,
    },
};

pub const PROJ: Dependency = Dependency {
    id: "proj",
    name: "PROJ",
    version: "9.9.0",
    license: "MIT",
    role: Role::Library,
    builder: Builder::Cmake,
    archive: Archive {
        file: "proj-9.9.0.tar.gz",
        url: "https://github.com/OSGeo/PROJ/releases/download/9.9.0/proj-9.9.0.tar.gz",
        sha256: "791a0610547eeabb17006cfd49cdbd2034f3240f47ed5e88a1031811f4e2bcf3",
        size: 6_048_023,
        strip: true,
    },
};

pub const JSON_C: Dependency = Dependency {
    id: "json-c",
    name: "JSON-C",
    version: "0.19",
    license: "MIT",
    role: Role::Library,
    builder: Builder::Cmake,
    archive: Archive {
        file: "json-c-0.19-nodoc.tar.gz",
        url: "https://github.com/json-c/json-c/releases/download/json-c-0.19-20260627/json-c-0.19-nodoc.tar.gz",
        sha256: "704927172443309a8efeb162060bb215548e1286e5568514007dd2cc35a0a164",
        size: 232_738,
        strip: true,
    },
};

/// Extensions of the catalog, every component.
pub const RECIPES: &[Recipe] = &[
    Recipe {
        component: "postgres",
        id: "postgis",
        name: "PostGIS",
        version: "3.7.0",
        license: "GPL-2.0",
        homepage: "https://postgis.net",
        // Official origin; the project publishes an MD5 next to it (dc4a19f6…), checked before
        // pinning this SHA-256.
        archive: Archive {
            file: "postgis-3.7.0.tar.gz",
            url: "https://download.osgeo.org/postgis/source/postgis-3.7.0.tar.gz",
            sha256: "832bbf50f2b6f57fab053bc9676b3bfe641e5bf966cdcb28c7926f8d4b3c5e04",
            size: 15_991_154,
            strip: true,
        },
        dependencies: &[CMAKE, GMP, GEOS, PROJ, JSON_C],
        build: Build::Postgis,
        sql_names: &["postgis", "postgis_topology", "postgis_tiger_geocoder"],
        engines: (14, 19),
        note: Some("postgisWithout"),
    },
    Recipe {
        component: "postgres",
        id: "pgvector",
        name: "pgvector",
        version: "0.8.7",
        license: "PostgreSQL",
        homepage: "https://github.com/pgvector/pgvector",
        // The project publishes tags only: the archive GitHub serves for v0.8.7, pinned.
        archive: Archive {
            file: "pgvector-0.8.7.tar.gz",
            url: "https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.7.tar.gz",
            sha256: "cac0b10c360f05b2d521200105ba3697e773d4cd3731f5a915a7e37ebe0bea85",
            size: 133_025,
            strip: true,
        },
        dependencies: &[],
        build: Build::Pgxs,
        sql_names: &["vector"],
        engines: (13, 19),
        note: None,
    },
];

pub fn recipe(component: &str, id: &str) -> Option<&'static Recipe> {
    RECIPES
        .iter()
        .find(|r| r.component == component && r.id == id)
}

/// The catalog entry that provides `sql_name` (`vector` → pgvector).
pub fn providing(component: &str, sql_name: &str) -> Option<&'static Recipe> {
    RECIPES
        .iter()
        .find(|r| r.component == component && r.sql_names.contains(&sql_name))
}
