// build-cache.init.gradle.kts — point Gradle's local build cache at the
// host-shared directory named by SANDBOX_BUILD_CACHE (#577), so a second
// worker compiling unchanged sources gets a cache hit instead of
// recompiling. Mounted read-only into GRADLE_USER_HOME/init.d/ by
// sandbox.sh only when SANDBOX_BUILD_CACHE is set and usable.
//
// Concurrency: Gradle's local DirectoryBuildCache writes each entry to a
// temp file and renames it into place, so concurrent containers sharing
// the directory never read a half-written entry. Cache keys are
// relocatable (they hash inputs, not absolute paths), so different
// worktrees share entries.
//
// Project settings win (#914): this runs after settings.gradle(.kts), so it
// only sets the local directory when the project left it unset and did not
// disable the local cache. It turns build caching on only when org.gradle.caching is unset.
//
// Skipped silently when the directory is missing or not writable (e.g.
// owned by another UID), so the build behaves as if this script were absent.

import java.io.File

val buildCacheDir: File? = System.getenv("SANDBOX_BUILD_CACHE")
    ?.trim()?.takeIf { it.isNotEmpty() }
    ?.let { File(it) }
    ?.takeIf { it.isDirectory && it.canWrite() }

if (buildCacheDir != null) {
    gradle.settingsEvaluated {
        // Workers invoke ./gradlew directly, so there is no flag to inject.
        // Turn caching on only when nobody has decided: a project or user
        // that set org.gradle.caching (true or false, via gradle.properties,
        // -P or -D) keeps its choice, so =false stays off and a remote cache
        // is never activated behind its back (#914).
        val cachingDecided = providers.gradleProperty("org.gradle.caching").isPresent ||
            System.getProperty("org.gradle.caching") != null
        if (!cachingDecided) {
            gradle.startParameter.isBuildCacheEnabled = true
        }
        buildCache {
            local {
                // Respect the project: a settings script that already set a
                // local directory (or disabled the local cache) wins. An unset
                // directory reads back as null; only then do we fill it in.
                if (directory == null && isEnabled) {
                    directory = buildCacheDir
                }
            }
        }
    }
}
