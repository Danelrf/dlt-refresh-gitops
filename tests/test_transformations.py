from decimal import Decimal

from pyspark.testing import assertDataFrameEqual

from transformations import transform_orders

# Everything arrives as strings from the JSON landing zone.
RAW_SCHEMA = "order_id string, customer_id string, amount string, order_ts string"


def test_casts_columns_to_target_types(spark):
    raw = spark.createDataFrame(
        [("o-1", "c-1", "10.50", "2026-01-15 09:30:00")], RAW_SCHEMA
    )

    result = transform_orders(raw)

    assert dict(result.dtypes) == {
        "order_id": "string",
        "customer_id": "string",
        "amount": "decimal(18,2)",
        "order_ts": "timestamp",
        "_processed_at": "timestamp",
    }


def test_preserves_values_through_the_cast(spark):
    raw = spark.createDataFrame(
        [
            ("o-1", "c-1", "10.50", "2026-01-15 09:30:00"),
            ("o-2", "c-2", "99.99", "2026-01-15 10:00:00"),
        ],
        RAW_SCHEMA,
    )

    result = transform_orders(raw).drop("_processed_at")

    expected = spark.createDataFrame(
        [
            ("o-1", "c-1", Decimal("10.50"), "2026-01-15 09:30:00"),
            ("o-2", "c-2", Decimal("99.99"), "2026-01-15 10:00:00"),
        ],
        "order_id string, customer_id string, amount decimal(18,2), order_ts string",
    ).selectExpr(
        "order_id", "customer_id", "amount", "cast(order_ts as timestamp) as order_ts"
    )

    assertDataFrameEqual(result, expected)


def test_stamps_every_row_with_a_processed_at(spark):
    raw = spark.createDataFrame(
        [("o-1", "c-1", "10.50", "2026-01-15 09:30:00")], RAW_SCHEMA
    )

    result = transform_orders(raw)

    assert result.filter("_processed_at IS NULL").count() == 0


def test_unparseable_amount_becomes_null_rather_than_failing(spark):
    """Spark casts silently — worth pinning so a bad payload can't corrupt totals."""
    raw = spark.createDataFrame(
        [("o-1", "c-1", "not-a-number", "2026-01-15 09:30:00")], RAW_SCHEMA
    )

    result = transform_orders(raw)

    assert result.collect()[0]["amount"] is None
