#!/bin/sh
# Builds the reproducer and reports whether spring-boot:repackage saw the project's dependencies.
# Usage: ./check.sh [extra maven args...]   (MVN defaults to mvn; e.g. MVN=mvn4 ./check.sh -b concurrent -T1C)
set -u
cd "$(dirname "$0")"
MVN=${MVN:-mvn}
"$MVN" -q clean verify "$@" || exit 1
entries=$(unzip -Z1 app/target/app.war)
provided=$(printf '%s\n' "$entries" | grep -c '^WEB-INF/lib-provided/.')
lib=$(printf '%s\n' "$entries" | grep -c '^WEB-INF/lib/lib-')
echo "WEB-INF/lib-provided entries: $provided (expected 1: jakarta.servlet-api)"
echo "WEB-INF/lib/lib-*.jar entries: $lib (expected 1)"
if [ "$provided" -eq 1 ]; then
    java -jar app/target/app.war
    echo "RESULT: OK"
else
    java -jar app/target/app.war
    echo "RESULT: BROKEN - repackage saw an empty project.getArtifacts()"
    exit 2
fi
