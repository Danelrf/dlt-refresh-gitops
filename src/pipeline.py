"""Minimal SDP pipeline: one raw ingest table + one incremental bronze table.

The full-refresh governance flow in this repo targets this pipeline.
On a normal update, `orders_bronze` processes only new data (streaming).
On a full refresh (triggered via the changelog + release workflow), the
pipeline truncates and recomputes the tables from the source.
"""

from pyspark import pipelines as dp

from transformations import transform_orders

# Adjust to your actual source (Auto Loader path, existing table, etc.)
SOURCE_PATH = "/Volumes/main/default/landing/orders"


@dp.table(comment="Raw orders ingested incrementally via Auto Loader.")
def orders_raw():
    return (
        spark.readStream.format("cloudFiles")
        .option("cloudFiles.format", "json")
        .option("cloudFiles.schemaLocation", f"{SOURCE_PATH}/_schema")
        .load(SOURCE_PATH)
    )


@dp.table(comment="Cleaned orders, incremental. Full refresh rebuilds from raw.")
@dp.expect_or_drop("valid_order_id", "order_id IS NOT NULL")
def orders_bronze():
    return transform_orders(spark.readStream.table("orders_raw"))
