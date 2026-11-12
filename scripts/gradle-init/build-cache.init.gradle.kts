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
// Skipped silently when the directory is missing or not writable (e.g.
// owned by another UID), so the build behaves as if this script were absent.

import java.io.File

val buildCacheDir: File? = System.getenv("SANDBOX_BUILD_CACHE")
    ?.trim()?.takeIf { it.isNotEmpty() }
    ?.let { File(it) }
    ?.takeIf { it.isDirectory && it.canWrite() }

if (buildCacheDir != null) {
    // Workers invoke ./gradlew directly, so there is no flag to inject;
    // enable caching here rather than requiring org.gradle.caching=true in
    // every project.
    gradle.startParameter.isBuildCacheEnabled = true
    gradle.settingsEvaluated {
        buildCache {
            local {
                isEnabled = true
                directory = buildCacheDir
            }
        }
    }
}
