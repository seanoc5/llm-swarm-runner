// dep-proxy.init.gradle.kts — route Gradle's Maven Central / Gradle Plugin
// Portal resolution through the local caching proxy (#331), when one is
// reachable. Mounted read-only into GRADLE_USER_HOME/init.d/ by sandbox.sh
// when SANDBOX_DEP_PROXY_URL is set — Gradle auto-applies every init.d/
// script to every build, so no per-invocation flag is needed and no
// project's build.gradle.kts is touched.
//
// Why init.d/ and not GRADLE_OPTS: GRADLE_OPTS carries JVM options (heap
// size, system properties) to the Gradle client/daemon process — it has no
// mechanism for loading an arbitrary init script's Groovy/Kotlin body.
// GRADLE_USER_HOME/init.d/ is Gradle's own documented auto-discovery
// directory for exactly this purpose (see Gradle's "Initialization
// Scripts" docs): every *.gradle / *.gradle.kts file there is applied to
// every build automatically.
//
// Failover: Gradle does NOT fall through to a repository declared after one
// that fails at the network level (connection refused, timeout) — only a
// genuine HTTP 404 triggers the "try the next declared repository" check
// (see gradle/gradle#2853, unchanged since Gradle 4.3). So this script does
// its own up-front reachability probe (short-timeout TCP connect) and skips
// all repository rewiring entirely when the proxy doesn't answer — the
// build then resolves exactly as if this init script didn't exist, straight
// against the real upstreams. The real mavenCentral()/gradlePluginPortal()
// are still declared second (behind the proxy) wherever we do rewire, as a
// second line of defense for anything the proxy 404s on after the probe
// passed but before/during the build.

import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI

val proxyBaseUrl: String? = System.getenv("SANDBOX_DEP_PROXY_URL")?.trim()?.trimEnd('/')?.takeIf { it.isNotEmpty() }

fun isProxyReachable(baseUrl: String): Boolean {
    return try {
        val uri = URI(baseUrl)
        val host = uri.host ?: return false
        val port = if (uri.port > 0) uri.port else 80
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, port), /* timeoutMs = */ 500)
        }
        true
    } catch (e: Exception) {
        false
    }
}

if (proxyBaseUrl != null && isProxyReachable(proxyBaseUrl)) {
    val mavenProxyUrl = "$proxyBaseUrl/maven2"
    val pluginsProxyUrl = "$proxyBaseUrl/gradle-plugins"

    // Settings-level: covers the `plugins { id(...) version ... }` DSL
    // (pluginManagement.repositories) and projects using centralized
    // dependencyResolutionManagement — this is the only path that's
    // honored when a project's settings.gradle.kts sets
    // RepositoriesMode.FAIL_ON_PROJECT_REPOS, which is exactly why it's
    // done here rather than relying solely on the allprojects block below.
    gradle.beforeSettings {
        pluginManagement {
            repositories {
                maven {
                    url = uri(pluginsProxyUrl)
                    isAllowInsecureProtocol = true
                }
                gradlePluginPortal()
            }
        }
        dependencyResolutionManagement {
            repositories {
                maven {
                    url = uri(mavenProxyUrl)
                    isAllowInsecureProtocol = true
                }
                mavenCentral()
            }
        }
    }

    // Project-level: covers the common case of a project declaring its own
    // `repositories { mavenCentral() }` / `buildscript { repositories {} }`
    // rather than centralizing via dependencyResolutionManagement — under
    // Gradle's default RepositoriesMode.PREFER_PROJECT, a project's own
    // repository declarations take priority over the settings-level ones
    // above, so without this block the settings-level injection would be
    // silently ignored for such projects. Guarded: a project that *has*
    // opted into FAIL_ON_PROJECT_REPOS rejects any project-level repository
    // addition (including one added here from an init script) — in that
    // case this just no-ops and the settings-level injection above is what
    // actually takes effect.
    gradle.allprojects {
        buildscript {
            repositories {
                runCatching {
                    maven {
                        url = uri(mavenProxyUrl)
                        isAllowInsecureProtocol = true
                    }
                    mavenCentral()
                }
            }
        }
        repositories {
            runCatching {
                maven {
                    url = uri(mavenProxyUrl)
                    isAllowInsecureProtocol = true
                }
                mavenCentral()
            }
        }
    }
}
