"""Scratch SDP pipeline: dummy in-memory rows + one derived bronze table.

Deliberately has no external source. The rows are built in-process with
`spark.createDataFrame`, so a deploy is runnable immediately — nothing has to be
landed in the volume first. Swap `orders_raw` back to Auto Loader when this
stops being a playground.

The full-refresh governance flow in this repo targets this pipeline; both tables
are batch, so every update recomputes them from the literals below.
"""

from pyspark import pipelines as dp

from transformations import transform_orders

# Nullable order_id on purpose: the last row is what makes the expectation on
# `orders_bronze` visibly drop something instead of passing vacuously.
ORDERS = [
    (1, "cust-001", "42.50", "2026-08-01 09:15:00"),
    (2, "cust-002", "17.99", "2026-08-01 11:42:00"),
    (3, "cust-001", "128.00", "2026-08-02 08:03:00"),
    # try_cast in transform_orders turns this into a null amount rather than
    # failing the update — worth keeping to see that behaviour.
    (4, "cust-003", "not-a-number", "2026-08-02 14:20:00"),
    (None, "cust-004", "99.99", "2026-08-02 16:58:00"),
]

# Column names and types are what transform_orders selects on. Everything is a
# string here for the same reason the real source is JSON: the casts in
# transformations.py are part of what this pipeline is meant to exercise.
ORDERS_SCHEMA = (
    "order_id INT, customer_id STRING, amount STRING, order_ts STRING"
)


@dp.table(comment="Dummy orders built in-process. Stands in for Auto Loader.")
def orders_raw():
    return spark.createDataFrame(ORDERS, ORDERS_SCHEMA)


@dp.table(comment="Cleaned orders. Full refresh rebuilds from raw.")
@dp.expect_or_drop("valid_order_id", "order_id IS NOT NULL")
def orders_bronze():
    return transform_orders(spark.read.table("orders_raw"))
