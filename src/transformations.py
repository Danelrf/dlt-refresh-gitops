"""Reusable transformation logic for orders pipeline."""

from pyspark.sql import DataFrame
from pyspark.sql import functions as F


def transform_orders(df: DataFrame) -> DataFrame:
    """
    Apply standard transformations to raw orders data.

    Args:
        df: Raw orders DataFrame

    Returns:
        Transformed DataFrame with typed columns and processing timestamp
    """
    return (
        df.select(
            F.col("order_id").cast("string"),
            F.col("customer_id").cast("string"),
            F.expr("try_cast(amount as decimal(18,2))").alias("amount"),
            F.col("order_ts").cast("timestamp"),
        )
        .withColumn("_processed_at", F.current_timestamp())
    )
