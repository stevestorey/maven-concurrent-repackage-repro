# Maven 4 concurrent builder: package-branch mojo sees an empty `project.getArtifacts()`

With `-b concurrent` and more than one thread, a Maven 3 API mojo in the `package` phase can
see an empty `MavenProject.getArtifacts()`. The build still reports BUILD SUCCESS. Here the
mojo is `spring-boot:repackage`, which then builds a WAR with no `WEB-INF/lib-provided/`
entries. The WAR fails at runtime with `NoClassDefFoundError` for any `provided` class.

## Reproduce

```sh
MVN=/path/to/maven-4/bin/mvn ./check.sh -b concurrent -T1C   # RESULT: BROKEN
MVN=/path/to/maven-4/bin/mvn ./check.sh -b concurrent -T1    # RESULT: OK
MVN=/path/to/maven-4/bin/mvn ./check.sh -T1C                 # RESULT: OK (default builder)
MVN=/path/to/maven-3/bin/mvn ./check.sh -T1C                 # RESULT: OK
```

Tested with Maven 4.0.0-SNAPSHOT (a74018b) and 4.2.0-SNAPSHOT (master), Java 25. The order of
the `app` mojos in a broken run is:

```
war:war (default-war)              <- package step: resolves compile+runtime for the step
surefire:test (default-test)       <- test branch
antrun:run (package-step-1)
jacoco:report (report-after-tests) <- test branch, after:test step: no dependency requirement
antrun:run (package-step-2)
spring-boot:repackage (repackage)  <- sees resolvedArtifacts = [] and builds the wrong WAR
```

## Cause

The concurrent builder runs the `test` and `package` branches of one project in parallel. They
share one `MavenProject`, and `MojoExecutor` builds a new `DependencyContext` for each
build-plan step.

1. The `package` step's first mojo (`war:war`) resolves the scope union of the step's mojos.
   `project.setResolvedArtifacts(...)` gets the full set. Later mojos in the step see that
   `getDependencyArtifacts()` is unchanged and skip resolution, so they rely on
   `resolvedArtifacts` staying as it is.
2. On the test branch, the `after:test` step holds `jacoco:report`, which declares no
   `requiresDependencyResolution`. Its step context has empty scopes, but
   `isResolutionRequiredForCurrentProject()` is true for a fresh context. So
   `LifecycleDependencyResolver.resolveProjectDependencies` runs with no scopes and calls
   `project.setResolvedArtifacts(<empty set>)`.
3. `spring-boot:repackage` then runs in the `package` step without resolving again. It gets
   the `compile+runtime` artifact filter applied to an empty `resolvedArtifacts`, so
   `getArtifacts()` is empty.

The per-project lock (`ConcurrentProjectLock`) serialises single mojo executions. It does not
protect the step-level assumption that `resolvedArtifacts` stays stable between the mojos of
one step.

A debugger at `RepackageMojo.execute` shows:

```
this.project.getArtifacts().size() = 0
this.project.resolvedArtifacts.size() = 0
this.project.artifactFilter = CumulativeScopeArtifactFilter
```

## What changes the outcome

| Variation | Result |
| --- | --- |
| `-b concurrent -T1C` | BROKEN (3/3 runs) |
| `-b concurrent -T1C -Djacoco.skip` | BROKEN (resolution happens before the mojo skips) |
| `-b concurrent -T1` | OK |
| default builder `-T1C` (Maven 4 and 3) | OK |
| `report-after-tests` bound to `verify` instead of `after:test` | OK |

This is related to, but not the same as, apache/maven#7730 (MNG-5960). That issue is about an
aggregator mojo re-resolving the dependencies of *other* projects. Here no aggregator is
involved: two lifecycle branches of the *same* project overwrite each other's state.

The sleeps in `antrun` only make the interleaving deterministic. Mojos of one project take
turns on the project lock, so the two `package-step-*` executions give the test branch a turn
between `war:war` and `repackage`.
