import os
import re
from pathlib import Path

import pytest

MIN_JAVA = 17  # Spark 4.x refuses to start on anything older.


def _java_major(java_home: Path) -> int | None:
    """Read the JDK's version from its `release` file, avoiding a subprocess."""
    release = java_home / "release"
    if not release.is_file():
        return None
    match = re.search(r'JAVA_VERSION="(\d+)', release.read_text())
    return int(match.group(1)) if match else None


def _candidate_java_homes():
    if current := os.environ.get("JAVA_HOME"):
        yield Path(current)
    # Unpacked tarballs (Adoptium et al.) and system-registered JDKs.
    yield from sorted(Path.home().glob(".jdks/*/Contents/Home"), reverse=True)
    yield from sorted(Path.home().glob(".jdks/*"), reverse=True)
    yield from sorted(
        Path("/Library/Java/JavaVirtualMachines").glob("*/Contents/Home"), reverse=True
    )


def _resolve_java_home() -> Path:
    for home in _candidate_java_homes():
        if home.is_dir() and (major := _java_major(home)) and major >= MIN_JAVA:
            return home
    raise RuntimeError(
        f"No JDK {MIN_JAVA}+ found, which PySpark 4 requires. Install one with:\n"
        "  curl -L -o /tmp/jdk21.tar.gz "
        "'https://api.adoptium.net/v3/binary/latest/21/ga/mac/x64/jdk/hotspot/normal/eclipse'\n"
        "  mkdir -p ~/.jdks && tar xzf /tmp/jdk21.tar.gz -C ~/.jdks"
    )


def pytest_configure(config):
    """Point Spark at a usable JVM before any test imports pyspark."""
    os.environ["JAVA_HOME"] = str(_resolve_java_home())
    # A SPARK_HOME left over from an old install silently shadows the pip
    # -installed pyspark, so drop it unless it actually points somewhere.
    if (spark_home := os.environ.get("SPARK_HOME")) and not Path(spark_home).is_dir():
        del os.environ["SPARK_HOME"]


@pytest.fixture(scope="session")
def spark():
    from pyspark.sql import SparkSession

    session = (
        SparkSession.builder.appName("dlt-refresh-gitops-tests")
        .master("local[2]")
        .config("spark.sql.shuffle.partitions", "1")
        .config("spark.ui.enabled", "false")
        .getOrCreate()
    )
    yield session
    session.stop()
