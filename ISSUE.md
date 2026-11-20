# Concurrent builder: a mojo with no dependency requirement on the test branch empties `project.getArtifacts()` for later mojos in the package step

### Affected version

4.0.0-SNAPSHOT (4.0.x, 780ac40), which includes the #13590 fix (#13591, backported in #13679). Java 25 (Corretto 25.0.5.1), Linux.

### Bug description

With `-b concurrent` and more than one thread, a Maven 3 API mojo in the `package` phase can see an empty `MavenProject.getArtifacts()`. The build still reports BUILD SUCCESS. In the reproducer the affected mojo is `spring-boot:repackage`, which then builds a WAR with no `WEB-INF/lib-provided/` entries. The application fails at runtime as soon as it touches a `provided` class.

Reproducer: https://github.com/stevestorey/maven-concurrent-repackage-repro. It has a parent with two modules, `lib` (jar) and `app` (war). `app` declares:

- a `provided` dependency on `jakarta.servlet-api`;
- `jacoco:report` bound to `after:test`;
- two `antrun` sleeps in `package`, which only make the interleaving deterministic;
- `spring-boot:repackage`.

`check.sh` builds the project, counts the `lib-provided` entries in the WAR and runs it.

```sh
MVN=mvn4 ./check.sh -b concurrent -T1C   # BROKEN: 0 lib-provided entries
MVN=mvn4 ./check.sh -b concurrent -T1    # OK
MVN=mvn4 ./check.sh -T1C                 # OK (default builder)
MVN=mvn3 ./check.sh -T1C                 # OK
```

Order of the `app` mojos in a broken run:

```
war:war (default-war)              <- package step: resolves compile+runtime for the step
surefire:test (default-test)       <- test branch
antrun:run (package-step-1)
jacoco:report (report-after-tests) <- test branch, after:test step: no requiresDependencyResolution
antrun:run (package-step-2)
spring-boot:repackage (repackage)  <- sees resolvedArtifacts = [] and builds the wrong WAR
```

#### Cause

The concurrent builder runs the `test` and `package` branches of one project in parallel. They share one `MavenProject`, and `MojoExecutor` builds a new `DependencyContext` for each build-plan step.

1. The `package` step's first mojo, `war:war`, resolves the scope union of the step's mojos, and `project.setResolvedArtifacts(...)` gets the full set. Later mojos in the step see that `getDependencyArtifacts()` is unchanged and skip resolution, so they rely on `resolvedArtifacts` staying as it is.
2. On the test branch, the `after:test` step holds `jacoco:report`, which declares no `requiresDependencyResolution`. Its step context has empty scopes, but `isResolutionRequiredForCurrentProject()` is true for a fresh context. So `LifecycleDependencyResolver.resolveProjectDependencies` runs with no scopes and calls `project.setResolvedArtifacts(<empty set>)`.
3. `spring-boot:repackage` then runs in the `package` step without resolving again. It gets the `compile+runtime` artifact filter applied to an empty `resolvedArtifacts`, so `getArtifacts()` is empty.

Since #13591, the concurrent `MojoExecutor` holds a per-project lock (`ConcurrentProjectLock`) around each Maven 3 API mojo's dependency resolution and execution. That stops another step from changing the project's dependency state while one mojo is being prepared and run, which fixed #13590. It does not protect the step-level assumption that `resolvedArtifacts` stays stable between the mojos of one step: `war:war` releases the lock, `jacoco:report` takes it and empties the resolved artifacts, then `spring-boot:repackage` takes it and skips resolution because its step has already resolved.

A debugger at `RepackageMojo.execute` shows:

```
this.project.getArtifacts().size() = 0
this.project.resolvedArtifacts.size() = 0
this.project.artifactFilter = CumulativeScopeArtifactFilter
```

#### Why this is not a plugin thread-safety problem

The concurrent builder warns that the build contains goals not built with Maven 4 and asks for such issues to be reported against the plugin. Here the empty artifact set is written by Maven core. `MojoExecutor` calls `LifecycleDependencyResolver` before `jacoco:report` runs, and the result is the same with `-Djacoco.skip`, when the mojo does nothing at all. None of the mojos involved shares state across threads itself. The state that changes is the `MavenProject`'s resolved artifacts, which only Maven sets, between two mojos of the same step. Apart from `jacoco` and `spring-boot`, every plugin in the reproducer is one of Apache's own, such as `war`, `surefire` and `antrun`, and all of them use the Maven 3 API.

#### What changes the outcome

| Variation | Result |
| --- | --- |
| `-b concurrent -T1C` | broken, every run |
| `-b concurrent -T1C -Djacoco.skip` | broken: resolution happens before the mojo decides to skip |
| `-b concurrent -T1` | OK |
| default builder `-T1C`, Maven 4 and Maven 3 | OK |
| jacoco report bound to `verify` | OK, but the concurrent plan runs `verify`-bound mojos right after `initialize`, before the tests |
| jacoco report bound to `after:verify`, whose predecessors include both `test` and `package` | OK (workaround) |

#### Expected behaviour

A mojo with no dependency resolution requirement should not change the project's resolved artifacts. More generally, mojos on one lifecycle branch should not be able to change the dependency state that mojos on a parallel branch of the same project rely on.

Possible directions:

- skip `resolveProjectDependencies` when a step has no scopes to resolve or collect;
- keep the resolved artifacts per step or per execution instead of on the shared `MavenProject`, the finer alternative described in #13592;
- re-resolve when a step finds that `resolvedArtifacts` no longer matches its scopes.

#### Related

#13590 has the same mechanism with a different trigger: `flatten:flatten` running alongside `compile` replaced the project's resolved artifacts while the compiler was being configured. Its fix, #13591, makes each mojo's dependency resolution and execution atomic per project. This case remains because the artifacts are replaced between two mojos of the same step, which that lock does not cover, and the reproducer still fails on a 4.0.x build that includes the backport.

apache/maven#7730 (MNG-5960) is similar but not the same. That issue is an aggregator mojo re-resolving the dependencies of other projects. Here no aggregator is involved: two lifecycle branches of the same project overwrite each other's state.
